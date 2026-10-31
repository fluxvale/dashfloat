defmodule DashFloat.UpdateStandin do
  @moduledoc """
  A loopback standin for GitHub's release API and release downloads
  ([ADR 0026](../../docs/decisions/0026-update-command.md)'s hermetic suite):
  raw `:gen_tcp` HTTP/1.1, one connection at a time, `Connection: close` on
  every answer. `set_release/2` arms what the
  `/repos/fluxvale/dashfloat/releases/latest` route serves — a release map
  (encoded as JSON) or `{:status, code, headers}` for failure arms — and
  `serve/3` registers a download body under a path. Nothing beyond
  127.0.0.1, no new dependencies (the
  [ADR 0005](../../docs/decisions/0005-llm-streaming-engine.md) loopback
  shape).
  """

  use GenServer

  @api_path "/repos/fluxvale/dashfloat/releases/latest"

  @doc "Starts the standin."
  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, nil)

  @doc "The standin's base URL, e.g. `http://127.0.0.1:53211`."
  @spec base(GenServer.server()) :: String.t()
  def base(server), do: "http://127.0.0.1:#{port(server)}"

  @doc "The ephemeral port the standin listens on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc """
  Arms the API route: a map is served as a 200 JSON release record;
  `{:status, code, headers}` serves an empty body with that status (the
  rate-limit and not-found arms); `{:status, 200, headers, body}` serves raw
  bytes (the undecodable-body arm).
  """
  @spec set_release(
          GenServer.server(),
          map()
          | {:status, pos_integer(), [{String.t(), String.t()}]}
          | {:status, 200, [{String.t(), String.t()}], binary()}
        ) :: :ok
  def set_release(server, release), do: GenServer.call(server, {:set_release, release})

  @doc "Registers the body served for `GET path` (any status-armed route wins)."
  @spec serve(GenServer.server(), String.t(), binary()) :: :ok
  def serve(server, path, body), do: GenServer.call(server, {:serve, path, body})

  @impl GenServer
  def init(_arg) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    # The listener dies with the GenServer (its owner), so a linked test
    # process tears the standin down with itself. The acceptor routes by
    # calling this server — no global name, so async tests each own one.
    srv = self()
    spawn(fn -> accept_forever(listen, srv) end)
    {:ok, %{listen: listen, port: port, release: nil, files: %{}}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:set_release, release}, _from, state),
    do: {:reply, :ok, %{state | release: release}}

  def handle_call({:serve, path, body}, _from, state),
    do: {:reply, :ok, %{state | files: Map.put(state.files, path, body)}}

  # The acceptor is dumb; routing lives here, one call per request.
  def handle_call({:route, path}, _from, state) do
    case {path, state.release, Map.fetch(state.files, path)} do
      {@api_path, {:status, code, headers, body}, _fetched} ->
        {:reply, {:ok, code, headers, body}, state}

      {@api_path, {:status, code, headers}, _fetched} ->
        {:reply, {:ok, code, headers, ""}, state}

      {@api_path, release, _fetched} when is_map(release) ->
        body = Jason.encode!(release)
        {:reply, {:ok, 200, [{"content-type", "application/json"}], body}, state}

      {_path, _release, {:ok, body}} ->
        {:reply, {:ok, 200, [{"content-type", "application/octet-stream"}], body}, state}

      _miss ->
        {:reply, {:ok, 404, [], ""}, state}
    end
  end

  defp accept_forever(listen, srv) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve_conn(listen, srv, socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_conn(listen, srv, socket) do
    case read_head(socket, "") do
      {:ok, head} ->
        [request_line | _header_lines] = String.split(head, "\r\n")
        [method, path | _rest] = String.split(request_line, " ")

        if method == "GET" do
          {:ok, code, headers, body} = GenServer.call(srv, {:route, path})
          :gen_tcp.send(socket, response(code, headers, body))
        end

        :gen_tcp.close(socket)

      :closed ->
        :ok
    end

    accept_forever(listen, srv)
  end

  defp response(code, headers, body) do
    reason = %{200 => "OK", 403 => "Forbidden", 404 => "Not Found", 429 => "Too Many Requests"}
    status = Map.get(reason, code, "Status")

    [
      "HTTP/1.1 #{code} #{status}\r\n",
      Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _rest] ->
        {:ok, head}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_head(socket, acc <> data)
          {:error, _reason} -> :closed
        end
    end
  end
end

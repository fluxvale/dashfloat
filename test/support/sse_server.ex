defmodule DashFloat.SSEServer do
  @moduledoc """
  A one-shot loopback HTTP server for deterministic streaming tests.

  Listens on `127.0.0.1` at an ephemeral port and replays a scripted list of
  steps for every connection: `{:send, iodata}`, `{:sleep, ms}`, `:close`,
  `:reset`, or `{:wait_close, timeout}`. The request is forwarded to the
  owner as `{:sse_request, method, path, headers, body}`; `{:wait_close, _}`
  reports `{:sse_closed}` once the client hangs up. Raw `:gen_tcp`, no new
  dependencies, no external network (ADR 0005).
  """

  use GenServer

  @type step ::
          {:send, iodata()}
          | {:sleep, non_neg_integer()}
          | :close
          | :reset
          | {:wait_close, non_neg_integer()}

  @doc "Starts a server that replays `script` for every connection."
  @spec start_link([step()]) :: GenServer.on_start()
  def start_link(script) when is_list(script) do
    GenServer.start_link(__MODULE__, {script, self()})
  end

  @doc "The ephemeral port the server listens on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc ~S(The server's base URL, e.g. "http://127.0.0.1:53211".)
  @spec base_url(GenServer.server()) :: String.t()
  def base_url(server), do: "http://127.0.0.1:#{port(server)}"

  @impl true
  def init({script, owner}) do
    ip = {127, 0, 0, 1}

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: ip])

    {:ok, port} = :inet.port(listen)
    spawn(fn -> accept_forever(listen, script, owner) end)

    {:ok, %{listen: listen, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  ## Acceptor

  # The listen socket is owned by the GenServer, so it closes when the server
  # dies (a test's on_exit, or the owner test process dying and taking its
  # linked server with it); accept/1 then errors out and this process exits.
  defp accept_forever(listen, script, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, script, owner)
        accept_forever(listen, script, owner)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, script, owner) do
    case read_request(socket, "") do
      {head, rest} ->
        {method, path, headers} = parse_head(head)
        body = read_request_body(socket, headers, rest)
        send(owner, {:sse_request, method, path, headers, body})
        run_script(socket, script, owner)
        :gen_tcp.close(socket)

      :closed ->
        :ok
    end
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_incomplete] ->
        case recv(socket) do
          {:ok, data} -> read_request(socket, acc <> data)
          :closed -> :closed
        end
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path | _] = String.split(request_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {method, path, headers}
  end

  defp read_request_body(socket, headers, acc) do
    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    read_body(socket, length, acc)
  end

  defp read_body(_socket, length, acc) when byte_size(acc) >= length,
    do: binary_part(acc, 0, length)

  defp read_body(socket, length, acc) do
    case recv(socket) do
      {:ok, data} -> read_body(socket, length, acc <> data)
      :closed -> acc
    end
  end

  defp recv(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> :closed
    end
  end

  ## Script

  defp run_script(_socket, [], _owner), do: :ok

  defp run_script(socket, [{:send, data} | rest], owner) do
    :gen_tcp.send(socket, data)
    run_script(socket, rest, owner)
  end

  defp run_script(socket, [{:sleep, ms} | rest], owner) do
    Process.sleep(ms)
    run_script(socket, rest, owner)
  end

  # `:reset` closes with an RST (linger 0): the client sees an error, not a
  # graceful EOF.
  defp run_script(socket, [:reset | _rest], _owner) do
    :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end

  defp run_script(socket, [:close | _rest], _owner), do: :gen_tcp.close(socket)

  defp run_script(socket, [{:wait_close, timeout} | rest], owner) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:error, :closed} ->
        send(owner, {:sse_closed})
        run_script(socket, rest, owner)

      {:ok, _data} ->
        run_script(socket, [{:wait_close, timeout} | rest], owner)

      {:error, _other} ->
        :ok
    end
  end
end

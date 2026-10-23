defmodule DashFloat.LLM.ChatStream do
  @moduledoc """
  The Phase 2 producer: streams an OpenAI-compatible chat completion into the
  UI over the ADR-0002 message contract (`{:token, _}`, `{:phase, _}`,
  `{:entry, _, _}`).

  `run/4` is a Task body started by the TUI on submit under
  `DashFloat.StreamSupervisor`. It performs all network I/O — the UI process
  stays pure. Every exit path sends its own terminal `{:phase, _}` first, so
  the UI's monitor is only a safety net. Architecture and the error taxonomy
  are settled in ADR 0004.
  """

  alias DashFloat.LLM.SSE

  @default_idle_timeout 60_000
  @drain_limit 64 * 1024
  @drain_timeout 5_000
  # finch's socket `receive_timeout` and the stream loop's own `after` share
  # one deadline. Whichever fires, the entry is the same timeout message; the
  # socket timeout is the backstop for a wedged socket process, and it keeps
  # finch's 15 s default from cutting a healthy stream first.
  @timeout_grace 1_000

  @doc """
  Streams a completion for `prompt` to `ui`.

  Options:

    * `:idle_timeout` — milliseconds without stream data before aborting
      (default #{@default_idle_timeout}).
  """
  @spec run(pid(), DashFloat.Config.t(), String.t(), keyword()) :: :ok
  def run(ui, %DashFloat.Config{} = provider, prompt, opts \\ [])
      when is_pid(ui) and is_binary(prompt) do
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)

    case request_url(provider) do
      {:error, message} ->
        fail(ui, "[llm: connection failed: " <> message <> "]")

      {:ok, url} ->
        post(url, provider, prompt, idle_timeout)
        |> handle_response(ui, provider, idle_timeout)
    end
  end

  # An unusable base_url (no scheme, embedded whitespace, bad host/port) makes
  # Req raise — or finch exit(:badarg) before any request exists — so pre-flight
  # it: a config typo must degrade to a chat entry, not a crashed producer.
  defp request_url(provider) do
    base = String.trim_trailing(provider.base_url, "/")
    uri = URI.parse(base)

    cond do
      whitespace?(base) ->
        {:error, "base_url contains whitespace"}

      uri.scheme not in ["http", "https"] ->
        {:error, "base_url must be an http(s) URL"}

      uri.host in [nil, ""] ->
        {:error, "base_url must include a host"}

      not printable_ascii?(uri.host) ->
        # finch cannot resolve a non-ASCII host: Mint raises (or exits :badarg)
        # before a request exists.
        {:error, "base_url must have an ASCII host"}

      uri.port not in 1..65_535 ->
        {:error, "base_url has an invalid port"}

      not printable_ascii?(provider.api_key) ->
        # Mint would raise with the header value quoted — and its escaping
        # varies (inspect, binary form), so no scrub can catch every case.
        # Refuse the key instead of ever handing it to a message.
        {:error, "api_key must be printable ASCII"}

      true ->
        {:ok, base <> "/chat/completions"}
    end
  end

  defp whitespace?(string), do: Regex.match?(~r/\s/, string)

  defp printable_ascii?(string), do: Regex.match?(~r/\A[\x20-\x7E]*\z/, string)

  defp post(url, provider, prompt, idle_timeout) do
    Req.post(
      url,
      json: %{
        model: provider.model,
        stream: true,
        messages: [%{role: "user", content: prompt}]
      },
      headers: [
        {"authorization", "Bearer " <> provider.api_key},
        {"accept", "text/event-stream"}
      ],
      into: :self,
      # A streaming completions POST is not resumable: a retry or a followed
      # redirect would duplicate generation and billing (ADR 0004).
      retry: false,
      redirect: false,
      # Shares the stream loop's deadline (see @timeout_grace).
      receive_timeout: idle_timeout + @timeout_grace
    )
  rescue
    exception -> {:error, exception}
  end

  defp handle_response({:error, exception}, ui, provider, _idle_timeout) do
    if cancelled?() do
      terminal(ui, "[cancelled]")
    else
      message = Exception.message(exception)
      fail(ui, "[llm: connection failed: " <> scrub(message, provider.api_key) <> "]")
    end
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, ui, _provider, idle_timeout)
       when status in 200..299 do
    if cancelled?(), do: cancel(ui, resp), else: stream(ui, resp, idle_timeout, SSE.new())
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, ui, provider, _timeout) do
    drain(ui, resp, status, "", provider.api_key)
  end

  # Esc may arrive while the request is still waiting for headers; nothing
  # reads the mailbox inside Req, so check once the call returns.
  defp cancelled? do
    receive do
      :cancel -> true
    after
      0 -> false
    end
  end

  # Failure text and provider-supplied error bodies can quote the offending
  # header value; the key never reaches the chat log (ADR 0004). Mint renders
  # header values with inspect, so the escaped form is redacted too.
  defp scrub(message, key) do
    needles =
      [key, key |> inspect() |> String.slice(1..-2//1)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    Enum.reduce(needles, message, fn needle, acc ->
      String.replace(acc, needle, "[redacted]")
    end)
  end

  ## Streaming

  defp stream(ui, resp, timeout, parser) do
    receive do
      :cancel -> cancel(ui, resp)
      message -> handle_stream_message(ui, resp, timeout, parser, message)
    after
      timeout + @timeout_grace ->
        cancel_and_fail(ui, resp, "[llm: timed out waiting for stream data]")
    end
  end

  defp handle_stream_message(ui, resp, timeout, parser, message) do
    case Req.parse_message(resp, message) do
      {:ok, [data: bytes]} -> handle_frames(ui, resp, timeout, parser, bytes)
      {:ok, [:done]} -> cancel_and_fail(ui, resp, "[llm: stream ended without completion]")
      {:ok, [trailers: _trailers]} -> stream(ui, resp, timeout, parser)
      {:error, reason} -> cancel_and_fail(ui, resp, stream_error(reason))
      :unknown -> stream(ui, resp, timeout, parser)
    end
  end

  # finch's socket `receive_timeout` shares the stream loop's deadline; it is
  # still "no data for :idle_timeout" (ADR 0004), so it reads as a timeout,
  # never a lost connection.
  defp stream_error(%{reason: :timeout}), do: "[llm: timed out waiting for stream data]"
  defp stream_error(_reason), do: "[llm: connection lost mid-stream]"

  defp handle_frames(ui, resp, timeout, parser, bytes) do
    {frames, parser} = SSE.feed(parser, bytes)

    case emit_frames(ui, resp, frames) do
      :cont -> stream(ui, resp, timeout, parser)
      :done -> :ok
      {:error, message} -> cancel_and_fail(ui, resp, message)
    end
  end

  # [DONE] is the ONLY happy terminal — it finalizes the reply via the idle
  # phase and closes the connection so no pool slot lingers. Frames after it
  # are ignored.
  defp emit_frames(ui, resp, [%{data: "[DONE]"} | _rest]) do
    Req.cancel_async_response(resp)
    send(ui, {:phase, :idle})
    :done
  end

  defp emit_frames(ui, resp, [%{data: data} | rest]) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        emit_content(ui, decoded)
        emit_frames(ui, resp, rest)

      # A data frame that is not JSON is a broken stream, not a keepalive.
      {:error, _} ->
        {:error, "[llm: malformed SSE data frame — stream aborted]"}
    end
  end

  defp emit_frames(_ui, _resp, []), do: :cont

  # Role-only frames, empty choices, and usage frames are shape misses: skip
  # them silently (ADR 0004).
  defp emit_content(ui, %{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when is_binary(content) and content != "" do
    send(ui, {:token, content})
    :ok
  end

  defp emit_content(_ui, _decoded), do: :ok

  defp cancel(ui, resp) do
    Req.cancel_async_response(resp)
    terminal(ui, "[cancelled]")
  end

  defp cancel_and_fail(ui, resp, message) do
    Req.cancel_async_response(resp)
    terminal(ui, message)
  end

  ## Non-2xx: drain a bounded body, then report the provider's message
  #
  # Both bounds are absolute from the moment the drain starts: a server that
  # trickles bytes cannot extend it (@drain_timeout total, @drain_limit bytes).

  defp drain(ui, resp, status, acc, key) do
    drain(ui, resp, status, acc, deadline(), key)
  end

  defp drain(ui, resp, status, acc, deadline, key) do
    receive do
      :cancel ->
        cancel(ui, resp)

      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: bytes]} ->
            drain(ui, resp, status, append_bounded(acc, bytes), deadline, key)

          {:ok, [trailers: _trailers]} ->
            drain(ui, resp, status, acc, deadline, key)

          {:ok, [:done]} ->
            finish_drain(ui, resp, status, acc, key)

          {:error, _reason} ->
            finish_drain(ui, resp, status, acc, key)

          :unknown ->
            drain(ui, resp, status, acc, deadline, key)
        end
    after
      remaining(deadline) -> finish_drain(ui, resp, status, acc, key)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @drain_timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Keep consuming past the cap so the connection still closes cleanly, but
  # never accumulate more than the limit.
  defp append_bounded(acc, bytes) do
    room = @drain_limit - byte_size(acc)

    if room > 0 do
      acc <> binary_part(bytes, 0, min(byte_size(bytes), room))
    else
      acc
    end
  end

  defp finish_drain(ui, resp, status, body, key) do
    Req.cancel_async_response(resp)

    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        fail(ui, "[llm: HTTP #{status} — #{scrub(message, key)}]")

      _other ->
        fail(ui, "[llm: HTTP #{status}]")
    end
  end

  ## Terminal

  defp fail(ui, message), do: terminal(ui, message)

  # One exit path: the explanation, then the terminal idle phase which
  # finalizes any partial reply (ADR 0004 fixes this order).
  defp terminal(ui, message) do
    send(ui, {:entry, :system, message})
    send(ui, {:phase, :idle})
    :ok
  end
end

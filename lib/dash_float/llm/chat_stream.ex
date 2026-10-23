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
  # finch's socket `receive_timeout` is the idle timeout: it bounds the header
  # wait and reports a silent body first. The stream loop's own timer sits
  # just behind it as a backstop for a wedged socket process.
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

    # `Req.post` raises for a bad base_url (no scheme, stray space) — a config
    # typo must still degrade to a chat entry, never a crashed producer.
    try do
      post(provider, prompt, idle_timeout)
    rescue
      exception -> {:error, exception}
    end
    |> handle_response(ui, provider, idle_timeout)
  end

  defp handle_response({:error, exception}, ui, provider, _idle_timeout) do
    if cancelled?() do
      terminal(ui, "[cancelled]")
    else
      fail(ui, "[llm: connection failed: " <> scrub(exception, provider) <> "]")
    end
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, ui, _provider, idle_timeout)
       when status in 200..299 do
    if cancelled?(), do: cancel(ui, resp), else: stream(ui, resp, idle_timeout, SSE.new())
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, ui, _provider, _timeout) do
    drain(ui, resp, status, "")
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

  # Connection-failure text can quote the offending header value; the key
  # never reaches the chat log (ADR 0004). Config guarantees a non-blank key.
  defp scrub(exception, provider) do
    String.replace(Exception.message(exception), provider.api_key, "[redacted]")
  end

  # A streaming completions POST is not resumable: `retry: false` and no
  # redirect following — either one could duplicate generation and billing.
  # `receive_timeout` shares the stream's idle timeout: finch's 15 s default
  # would otherwise cut a healthy but slow stream early, and both timers must
  # agree so a quiet stream is reported as a timeout, not a lost connection.
  defp post(provider, prompt, idle_timeout) do
    Req.post(
      String.trim_trailing(provider.base_url, "/") <> "/chat/completions",
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
      retry: false,
      redirect: false,
      receive_timeout: idle_timeout
    )
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

  # finch reports its idle `receive_timeout` as a socket error; that IS "no
  # data for :idle_timeout" (ADR 0004), so it reads as a timeout, not a lost
  # connection.
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

  defp drain(ui, resp, status, acc) do
    drain(ui, resp, status, acc, deadline())
  end

  defp drain(ui, resp, status, acc, deadline) do
    receive do
      :cancel ->
        cancel(ui, resp)

      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: bytes]} ->
            drain(ui, resp, status, append_bounded(acc, bytes), deadline)

          {:ok, [trailers: _trailers]} ->
            drain(ui, resp, status, acc, deadline)

          {:ok, [:done]} ->
            finish_drain(ui, resp, status, acc)

          {:error, _reason} ->
            finish_drain(ui, resp, status, acc)

          :unknown ->
            drain(ui, resp, status, acc, deadline)
        end
    after
      remaining(deadline) -> finish_drain(ui, resp, status, acc)
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

  defp finish_drain(ui, resp, status, body) do
    Req.cancel_async_response(resp)

    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        fail(ui, "[llm: HTTP #{status} — #{message}]")

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

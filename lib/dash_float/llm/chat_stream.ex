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

    case post(provider, prompt) do
      {:error, exception} ->
        fail(ui, "[llm: connection failed: " <> Exception.message(exception) <> "]")

      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        stream(ui, resp, idle_timeout, SSE.new())

      {:ok, %Req.Response{status: status} = resp} ->
        drain(ui, resp, status, "")
    end
  end

  # A streaming completions POST is not resumable: `retry: false` — a retry
  # would duplicate generation and billing (ADR 0004).
  defp post(provider, prompt) do
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
      retry: false
    )
  end

  ## Streaming

  defp stream(ui, resp, timeout, parser) do
    receive do
      :cancel -> cancel(ui, resp)
      message -> handle_stream_message(ui, resp, timeout, parser, message)
    after
      timeout -> cancel_and_fail(ui, resp, "[llm: timed out waiting for stream data]")
    end
  end

  defp handle_stream_message(ui, resp, timeout, parser, message) do
    case Req.parse_message(resp, message) do
      {:ok, [data: bytes]} -> handle_frames(ui, resp, timeout, parser, bytes)
      {:ok, [:done]} -> fail(ui, "[llm: stream ended without completion]")
      {:ok, [trailers: _trailers]} -> stream(ui, resp, timeout, parser)
      {:error, _reason} -> fail(ui, "[llm: connection lost mid-stream]")
      :unknown -> stream(ui, resp, timeout, parser)
    end
  end

  defp handle_frames(ui, resp, timeout, parser, bytes) do
    {frames, parser} = SSE.feed(parser, bytes)

    case emit_frames(ui, frames) do
      :cont -> stream(ui, resp, timeout, parser)
      :done -> :ok
      {:error, message} -> cancel_and_fail(ui, resp, message)
    end
  end

  # [DONE] is the ONLY happy terminal — it finalizes the reply via the idle
  # phase. Frames after it are ignored.
  defp emit_frames(ui, [%{data: "[DONE]"} | _rest]) do
    send(ui, {:phase, :idle})
    :done
  end

  defp emit_frames(ui, [%{data: data} | rest]) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        emit_content(ui, decoded)
        emit_frames(ui, rest)

      # A data frame that is not JSON is a broken stream, not a keepalive.
      {:error, _} ->
        {:error, "[llm: malformed SSE data frame — stream aborted]"}
    end
  end

  defp emit_frames(_ui, []), do: :cont

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
    send(ui, {:entry, :system, "[cancelled]"})
    send(ui, {:phase, :idle})
    :ok
  end

  defp cancel_and_fail(ui, resp, message) do
    Req.cancel_async_response(resp)
    fail(ui, message)
  end

  ## Non-2xx: drain a bounded body, then report the provider's message

  defp drain(ui, resp, status, acc) do
    receive do
      :cancel ->
        cancel(ui, resp)

      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: bytes]} ->
            drain(ui, resp, status, append_bounded(acc, bytes))

          {:ok, [trailers: _trailers]} ->
            drain(ui, resp, status, acc)

          {:ok, [:done]} ->
            finish_drain(ui, status, acc)

          {:error, _reason} ->
            finish_drain(ui, status, acc)

          :unknown ->
            drain(ui, resp, status, acc)
        end
    after
      @drain_timeout ->
        Req.cancel_async_response(resp)
        finish_drain(ui, status, acc)
    end
  end

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

  defp finish_drain(ui, status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        fail(ui, "[llm: HTTP #{status} — #{message}]")

      _other ->
        fail(ui, "[llm: HTTP #{status}]")
    end
  end

  ## Terminal

  defp fail(ui, message) do
    send(ui, {:entry, :system, message})
    send(ui, {:phase, :idle})
    :ok
  end
end

defmodule DashFloat.LLM.ChatStream do
  @moduledoc """
  The streaming producer ([ADR 0005](0005-llm-streaming-engine.md)): streams an
  OpenAI-compatible chat completion, now with the full conversation history and
  the tool catalogue (ADR 0007). It reports to the **agent** — never the UI —
  over a plain-message contract:

    * `{:token, text}` — one message per SSE data frame's content delta
    * `{:usage, map}` — a usage frame (the agent decides what reaches the UI)
    * `{:stream_failed, text, partial_content}` — the ADR-0005 error taxonomy,
      engine-authored text, with whatever content streamed before the failure
    * `{:stream_done, %{content:, tool_calls:, cancelled:}}` — the terminal
      report: assembled tool calls ([ADR 0007](0007-tool-calls-and-execution.md))
      and the episode's full content; `cancelled` marks a user interrupt

  `run/4` is a Task body started by `DashFloat.Agent` under
  `DashFloat.TaskSupervisor`. Every exit path sends its own terminal report or
  failure first, so the agent's monitor is only a safety net.
  """

  alias DashFloat.LLM.SSE
  alias DashFloat.LLM.ToolCalls

  @default_idle_timeout 60_000
  @drain_limit 64 * 1024
  # A single SSE frame that never completes would grow the parser buffer until
  # the node dies: cap it (the parser itself stays pure and unbounded).
  @frame_limit 1024 * 1024
  @drain_timeout 5_000
  # finch's socket `receive_timeout` is the primary idle detector (it is
  # strictly shorter than the stream loop's timer, so its error arrives first);
  # the loop's `after` is the backstop for a wedged socket process.
  @timeout_grace 1_000

  @doc """
  Streams one completion episode for `messages` (the whole conversation) with
  `tools` (the catalogue) and reports to `agent`.

  Options:

    * `:idle_timeout` — milliseconds without stream data before aborting
      (default #{@default_idle_timeout}).
  """
  @spec run(pid(), DashFloat.Config.t() | {:error, String.t()}, [map()], [map()], keyword()) ::
          :ok
  def run(agent, provider, messages, tools, opts \\ []) when is_pid(agent) do
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)

    case request_url(provider) do
      {:error, message} ->
        fail(agent, "[llm: connection failed: " <> message <> "]", "")

      {:ok, url} ->
        response = post(url, provider, messages, tools, idle_timeout)
        handle_response(response, agent, provider, idle_timeout)
    end
  end

  # An unusable base_url (no scheme, embedded whitespace, bad host/port) makes
  # Req raise — or finch exit(:badarg) before any request exists — so pre-flight
  # it: a config typo must degrade to a failure report, not a crashed producer.
  # An {:error, _} provider (no config) degrades the same way.
  defp request_url({:error, _message} = error), do: error

  defp request_url({:ok, %DashFloat.Config{} = provider}), do: check_url(provider)

  defp check_url(provider) do
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

  defp post(url, {:ok, provider}, messages, tools, idle_timeout) do
    Req.post(
      url,
      json: %{
        model: provider.model,
        stream: true,
        stream_options: %{include_usage: true},
        messages: messages,
        tools: tools
      },
      headers: [
        {"authorization", "Bearer " <> provider.api_key},
        {"accept", "text/event-stream"}
      ],
      into: :self,
      # A streaming completions POST is not resumable: a retry or a followed
      # redirect would duplicate generation and billing (ADR 0005).
      retry: false,
      redirect: false,
      # The idle detector; the stream loop's `after` sits @timeout_grace behind.
      receive_timeout: idle_timeout
    )
  end

  defp handle_response({:error, exception}, agent, {:ok, provider}, _idle_timeout) do
    if cancelled?() do
      terminal_cancel(agent, "")
    else
      message = Exception.message(exception)
      fail(agent, "[llm: connection failed: " <> scrub(message, provider.api_key) <> "]", "")
    end
  end

  defp handle_response({:ok, %Req.Response{status: status} = resp}, agent, provider, idle_timeout)
       when status in 200..299 do
    if cancelled?(),
      do: terminal_cancel(agent, ""),
      else:
        stream(agent, provider, resp, idle_timeout, %{
          parser: SSE.new(),
          tool_calls: ToolCalls.new(),
          content: ""
        })
  end

  defp handle_response(
         {:ok, %Req.Response{status: status} = resp},
         agent,
         {:ok, provider},
         _timeout
       ) do
    drain(agent, provider, resp, status, "")
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
  # header value; the key never reaches a report (ADR 0005). Mint renders
  # header values with inspect, so the escaped form is redacted too.
  defp scrub(message, key) do
    escaped =
      key
      |> inspect()
      |> String.slice(1..-2//1)

    needles =
      [key, escaped]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    Enum.reduce(needles, message, fn needle, acc ->
      String.replace(acc, needle, "[redacted]")
    end)
  end

  ## Streaming

  defp stream(agent, provider, resp, timeout, acc) do
    receive do
      :cancel ->
        Req.cancel_async_response(resp)
        terminal_cancel(agent, acc.content)

      message ->
        handle_stream_message(agent, provider, resp, timeout, acc, message)
    after
      timeout + @timeout_grace ->
        Req.cancel_async_response(resp)
        fail(agent, "[llm: timed out waiting for stream data]", acc.content)
    end
  end

  defp handle_stream_message(agent, provider, resp, timeout, acc, message) do
    case Req.parse_message(resp, message) do
      {:ok, [data: bytes]} ->
        handle_frames(agent, provider, resp, timeout, acc, bytes)

      {:ok, [:done]} ->
        Req.cancel_async_response(resp)
        fail(agent, "[llm: stream ended without completion]", acc.content)

      {:ok, [trailers: _trailers]} ->
        stream(agent, provider, resp, timeout, acc)

      # A finch socket `receive_timeout` is the primary idle detector (see
      # @timeout_grace); it still means "no data for :idle_timeout" (ADR 0005).
      {:error, reason} ->
        Req.cancel_async_response(resp)

        if match?(%{reason: :timeout}, reason) do
          fail(agent, "[llm: timed out waiting for stream data]", acc.content)
        else
          fail(agent, "[llm: connection lost mid-stream]", acc.content)
        end

      :unknown ->
        stream(agent, provider, resp, timeout, acc)
    end
  end

  defp handle_frames(agent, provider, resp, timeout, acc, bytes) do
    {frames, parser} = SSE.feed(acc.parser, bytes)
    acc = %{acc | parser: parser}

    if byte_size(parser.buffer) > @frame_limit do
      Req.cancel_async_response(resp)
      fail(agent, "[llm: SSE frame exceeded 1 MiB — stream aborted]", acc.content)
    else
      case emit_frames(agent, provider, resp, frames, acc) do
        {:cont, acc} -> stream(agent, provider, resp, timeout, acc)
        :done -> :ok
        {:error, message} -> fail(agent, message, acc.content)
      end
    end
  end

  # [DONE] is the ONLY happy terminal — it closes the connection so no pool
  # slot lingers. Frames after it are ignored.
  defp emit_frames(agent, _provider, _resp, [%{data: "[DONE]"} | _rest], acc) do
    send(
      agent,
      {:stream_done,
       %{content: acc.content, tool_calls: ToolCalls.finish(acc.tool_calls), cancelled: false}}
    )

    :done
  end

  defp emit_frames(agent, provider, resp, [%{data: data} | rest], acc) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        acc = emit_content(agent, decoded, acc)
        acc = emit_tool_calls(acc, decoded)
        emit_usage(agent, decoded, acc)
        emit_frames(agent, provider, resp, rest, acc)

      # A data frame that is not JSON is a broken stream, not a keepalive.
      {:error, _error} ->
        {:error, "[llm: malformed SSE data frame — stream aborted]"}
    end
  end

  defp emit_frames(_agent, _provider, _resp, [], acc), do: {:cont, acc}

  # Usage arrives in the stream's final chunk (often with empty choices):
  # forward it as data; a malformed usage object is ignored, never an error.
  defp emit_usage(agent, %{"usage" => usage}, acc) when is_map(usage) do
    case usage do
      %{"prompt_tokens" => prompt, "completion_tokens" => completion, "total_tokens" => total}
      when is_integer(prompt) and is_integer(completion) and is_integer(total) and
             prompt >= 0 and completion >= 0 and total >= 0 ->
        send(
          agent,
          {:usage, %{prompt_tokens: prompt, completion_tokens: completion, total_tokens: total}}
        )

        acc

      # Non-integer or negative counts are a broken frame, not accounting data.
      _other ->
        acc
    end
  end

  defp emit_usage(_agent, _decoded, acc), do: acc

  # Role-only frames, empty choices, and other shape misses are skipped
  # silently (ADR 0005); content accumulates for the terminal report.
  defp emit_content(agent, %{"choices" => [%{"delta" => %{"content" => content}} | _rest]}, acc)
       when is_binary(content) and content != "" do
    send(agent, {:token, content})
    %{acc | content: acc.content <> content}
  end

  defp emit_content(_agent, _decoded, acc), do: acc

  # Tool-call fragments merge incrementally by index; arguments concatenate as
  # binaries and parse once, at the end (ADR 0007 §1).
  defp emit_tool_calls(acc, %{"choices" => [%{"delta" => %{"tool_calls" => deltas}} | _rest]})
       when is_list(deltas) do
    %{acc | tool_calls: ToolCalls.feed(acc.tool_calls, deltas)}
  end

  defp emit_tool_calls(acc, _decoded), do: acc

  ## Non-2xx: drain a bounded body, then report the provider's message
  #
  # Both bounds are absolute from the moment the drain starts: a server that
  # trickles bytes cannot extend it (@drain_timeout total, @drain_limit bytes).

  defp drain(agent, provider, resp, status, acc) do
    drain(agent, provider, resp, status, acc, deadline())
  end

  defp drain(agent, provider, resp, status, acc, deadline) do
    receive do
      :cancel ->
        Req.cancel_async_response(resp)
        terminal_cancel(agent, "")

      message ->
        case Req.parse_message(resp, message) do
          {:ok, [data: bytes]} ->
            drain(agent, provider, resp, status, append_bounded(acc, bytes), deadline)

          {:ok, [trailers: _trailers]} ->
            drain(agent, provider, resp, status, acc, deadline)

          {:ok, [:done]} ->
            finish_drain(agent, provider, resp, status, acc)

          {:error, _reason} ->
            finish_drain(agent, provider, resp, status, acc)

          :unknown ->
            drain(agent, provider, resp, status, acc, deadline)
        end
    after
      remaining(deadline) -> finish_drain(agent, provider, resp, status, acc)
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

  defp finish_drain(agent, {:ok, provider}, resp, status, body) do
    Req.cancel_async_response(resp)

    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        fail(agent, "[llm: HTTP #{status} — #{scrub(message, provider.api_key)}]", "")

      _other ->
        fail(agent, "[llm: HTTP #{status}]", "")
    end
  end

  ## Terminal

  defp fail(agent, message, partial) do
    send(agent, {:stream_failed, message, partial})
    :ok
  end

  # A user interrupt keeps the partial content; partial tool fragments are
  # dropped (an assistant message with truncated tool_calls must never enter
  # the conversation — ADR 0007 §4).
  defp terminal_cancel(agent, partial) do
    send(agent, {:stream_done, %{content: partial, tool_calls: [], cancelled: true}})
    :ok
  end
end

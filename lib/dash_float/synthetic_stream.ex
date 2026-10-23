defmodule DashFloat.SyntheticStream do
  @moduledoc """
  The Phase 1 demo producer: drives the stream message contract
  (`{:token, _}`, `{:phase, _}`, `{:entry, _, _}` — see ADR 0002) with a
  canned reply, so the UI's responsiveness is provable before any LLM exists.

  Runs as a Task under `DashFloat.StreamSupervisor`; its only effects are
  `send/2` and `:timer.sleep`. Phase 2 replaces this module with the real
  stream handler, which sends the same messages.
  """

  @default_interval_ms 25

  @reply_sentences [
    "sure — here is a synthetic reply that streams into the log one word at a time,",
    "pushed through the same message contract the real streaming engine will use in phase two,",
    "while the input box below stays fully responsive: keep typing while tokens land."
  ]

  @tool_entry "[tool] list_directory(\".\") → (simulated) src, test, mix.exs"

  @doc """
  Emits a synthetic stream to `ui` in reply to `prompt`.

  Options:

    * `:interval_ms` — delay between tokens (default #{@default_interval_ms}).
      Tests pass `1` to finish in milliseconds.
    * `:sentences` — reply sentences before the tool interlude (default all).
  """
  @spec emit(pid(), String.t(), keyword()) :: :ok
  def emit(ui, prompt, opts \\ []) when is_pid(ui) and is_binary(prompt) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    sentences = Keyword.get(opts, :sentences, length(@reply_sentences))

    opening = "re: " <> prompt <> " —"

    {before_tool, after_tool} = Enum.split(@reply_sentences, max(sentences, 0))

    send_tokens(ui, [opening | before_tool], interval)
    send(ui, {:phase, :executing_tool})
    send(ui, {:entry, :tool, @tool_entry})
    send(ui, {:phase, :streaming})
    send_tokens(ui, after_tool, interval)
    send(ui, {:phase, :idle})
    :ok
  end

  defp send_tokens(ui, sentences, interval) do
    Enum.each(sentences, fn sentence ->
      Enum.each(String.split(sentence, " "), fn word ->
        send(ui, {:token, word <> " "})
        :timer.sleep(interval)
      end)

      send(ui, {:token, "\n"})
    end)
  end
end

defmodule DashFloat.Agent do
  @moduledoc """
  The Agent Manager ([ADR 0001](0001-founding-stack-and-architecture.md)): owns the
  conversation, runs the episode loop (stream → tools → stream → … → idle), gates
  mutations behind confirmations, and is the single voice speaking the display
  contract into the UI. ChatStream and the tool runners report here as plain
  messages; the agent forwards, renders, and orchestrates. It holds no timers —
  timeouts live in ChatStream and the runner Tasks. See ADR 0007.
  """

  use GenServer

  alias DashFloat.LLM.ChatStream
  alias DashFloat.Tools
  alias DashFloat.Tools.Preview
  alias DashFloat.Tools.Runner

  @default_exec_timeout 30_000
  # Display excerpt for tool-result rows; the model gets the bounded full result.
  @display_lines 30

  # P2-3 (hostile review): the no-provider notice CARRIES the actual error —
  # an unknown --profile hard error or a migration refusal is the user's
  # real remedy, and a static setup hint is a support dead-end. The message
  # is provider vocabulary (paths, profile names), never values.
  @no_provider_prefix "[llm: no provider configured — "

  @no_provider_suffix " | set up profiles in ~/.config/dashfloat/settings.json5 or " <>
                        "DASHFLOAT_BASE_URL/DASHFLOAT_MODEL/DASHFLOAT_API_KEY]"

  @enforce_keys [:provider, :cwd, :supervisor]
  defstruct [
    :provider,
    :cwd,
    :supervisor,
    :exec_timeout,
    :ui,
    # :idle | :streaming | :tools
    status: :idle,
    messages: [],
    episode_content: "",
    pending_usage: nil,
    stream_ref: nil,
    stream_pid: nil,
    calls: [],
    call_index: 0,
    results: %{},
    # :none | {:running, reference(), pid(), map()}
    # | {:running_cancelled, reference(), pid(), map()}
    # | {:confirming, reference(), map()}
    tool_slot: :none
  ]

  @doc """
  Starts the agent. Options:

    * `:provider` (required) — `DashFloat.Config.load/0`'s result
    * `:cwd` — the working directory every tool path is scoped to
      (default: the process cwd)
    * `:exec_timeout` — execute_command timeout in ms (default #{@default_exec_timeout})
    * `:supervisor` — the Task.Supervisor for stream/runner tasks
      (default: `DashFloat.TaskSupervisor`)
    * `:name` — GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    init_args = {
      Keyword.fetch!(opts, :provider),
      Keyword.get(opts, :cwd) || File.cwd!(),
      Keyword.get(opts, :supervisor, DashFloat.TaskSupervisor),
      Keyword.get(opts, :exec_timeout, @default_exec_timeout)
    }

    GenServer.start_link(__MODULE__, init_args, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init({provider, cwd, supervisor, exec_timeout}) do
    {:ok,
     %__MODULE__{
       provider: provider,
       cwd: cwd,
       supervisor: supervisor,
       exec_timeout: exec_timeout
     }}
  end

  ## UI messages (plain sends; the UI process is the sender)

  @impl GenServer
  def handle_info({:prompt, ui, text}, %__MODULE__{status: :idle} = state)
      when is_pid(ui) and is_binary(text) do
    case state.provider do
      {:error, message} ->
        display(ui, {:entry, :system, no_provider_text(message)})
        display(ui, {:phase, :idle})
        {:noreply, state}

      {:ok, _config} ->
        state = %{state | ui: ui, messages: state.messages ++ [%{role: "user", content: text}]}
        start_episode(state)
    end
  end

  # A prompt while busy is a UI bug (the UI gates on phase): ignore, never crash.
  def handle_info({:prompt, _ui, _text}, state), do: {:noreply, state}

  # The startup phase's handoff (ADR 0009): the agent boots with the boot-time
  # classification (an error while the wizard/modal runs); once setup
  # completes, the UI delivers the resolved provider here — the agent is the
  # single voice, so the config it streams with must be this one message old
  # at most.
  def handle_info({:set_provider, provider}, state) do
    {:noreply, %{state | provider: provider}}
  end

  def handle_info(
        {:confirm_decision, ref, decision},
        %__MODULE__{tool_slot: {:confirming, ref, call}} = state
      )
      when decision in [:approved, :rejected] do
    state = %{state | tool_slot: :none}

    if decision == :approved do
      dispatch_runner(state, call)
    else
      rejected = %{ok: false, rejected: true}
      display(state.ui, {:tool_result, tool_result_msg(call, rejected)})
      record_and_continue(state, call, rejected)
    end
  end

  # A stale decision (its confirmation was superseded) is ignored.
  def handle_info({:confirm_decision, _ref, _decision}, state), do: {:noreply, state}

  # Esc always interrupts (ADR 0007 §4). A running tool is CANCELLED BY
  # MESSAGE, not killed: the exec loop reaps the command's process group on
  # cancel (a bare :kill would close the port and leak the OS process), and a
  # mid-flight file tool simply finishes — it was approved seconds ago — before
  # the batch aborts. A pending confirmation is answered by the UI's own
  # Esc→reject decision, so a raw cancel there is a no-op.
  def handle_info({:cancel}, %__MODULE__{status: :streaming} = state) do
    if state.stream_pid, do: send(state.stream_pid, :cancel)
    {:noreply, state}
  end

  def handle_info({:cancel}, %__MODULE__{tool_slot: {:running, ref, pid, call}} = state) do
    if pid, do: send(pid, :cancel)
    {:noreply, %{state | tool_slot: {:running_cancelled, ref, pid, call}}}
  end

  def handle_info({:cancel}, state), do: {:noreply, state}

  ## Stream messages (from ChatStream)

  def handle_info({:token, text}, %__MODULE__{status: :streaming} = state) when is_binary(text) do
    display(state.ui, {:token, text})
    {:noreply, %{state | episode_content: state.episode_content <> text}}
  end

  def handle_info({:token, _text}, state), do: {:noreply, state}

  def handle_info({:usage, usage}, %__MODULE__{status: :streaming} = state),
    do: {:noreply, %{state | pending_usage: usage}}

  def handle_info({:usage, _usage}, state), do: {:noreply, state}

  def handle_info({:stream_failed, text, partial}, %__MODULE__{status: :streaming} = state)
      when is_binary(text) do
    state =
      state
      |> finalize_episode(partial)
      |> reset_turn()

    display(state.ui, {:entry, :system, text})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  def handle_info({:stream_failed, _text, _partial}, state), do: {:noreply, state}

  def handle_info(
        {:stream_done, %{content: content, tool_calls: calls, cancelled: cancelled}},
        %__MODULE__{status: :streaming} = state
      ) do
    state = %{state | stream_ref: nil, stream_pid: nil}

    cond do
      cancelled -> end_turn_cancelled(state, content)
      calls == [] -> end_turn_final(state, content)
      true -> begin_tool_batch(state, content, calls)
    end
  end

  def handle_info({:stream_done, _report}, state), do: {:noreply, state}

  ## Runner messages

  # A result arriving after the user cancelled aborts the rest of the batch —
  # the completed call keeps its real result, the queue does not continue.
  def handle_info(
        {:tool_done, id, result},
        %__MODULE__{tool_slot: {:running_cancelled, _ref, _pid, call}} = state
      )
      when call.id == id do
    cleared = %{state | tool_slot: :none}
    display(cleared.ui, {:tool_result, tool_result_msg(call, result)})

    recorded = %{
      cleared
      | results: Map.put(cleared.results, call.id, result),
        call_index: cleared.call_index + 1
    }

    abort_tool_run(recorded, nil)
  end

  def handle_info(
        {:tool_done, id, result},
        %__MODULE__{tool_slot: {:running, _ref, _pid, call}} = state
      )
      when call.id == id do
    state = %{state | tool_slot: :none}
    display(state.ui, {:tool_result, tool_result_msg(call, result)})
    record_and_continue(state, call, result)
  end

  def handle_info({:tool_done, _id, _result}, state), do: {:noreply, state}

  ## Monitors

  # A runner dying after the user cancelled (however it died): abort the batch
  # with a cancelled result for the announced call. The monitor ref is matched
  # so a stale DOWN from an unrelated monitor cannot abort a live batch.
  def handle_info(
        {:DOWN, ref, :process, _down_pid, _reason},
        %__MODULE__{tool_slot: {:running_cancelled, ref, _pid, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    abort_tool_run(state, call)
  end

  # An externally killed runner task: the announced call gets a cancelled
  # result and the whole batch aborts (ADR 0007 §4).
  def handle_info(
        {:DOWN, ref, :process, _down_pid, :killed},
        %__MODULE__{tool_slot: {:running, ref, _pid, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    abort_tool_run(state, call)
  end

  # A runner dead before its monitor went up (the spawn window in
  # dispatch_runner/2): Process.monitor/1 on an already-dead pid fires with
  # reason :noproc. The runner self-reports every death its body can observe
  # (the try/rescue in dispatch_runner/2), so a :noproc reaching a
  # still-{:running} slot means the body never reported — it never started,
  # or died to a kill the body could not catch — the same deaths the :killed
  # clause already reports as cancelled (ADR 0012).
  def handle_info(
        {:DOWN, ref, :process, _down_pid, :noproc},
        %__MODULE__{tool_slot: {:running, ref, _pid, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    abort_tool_run(state, call)
  end

  def handle_info(
        {:DOWN, ref, :process, _down_pid, reason},
        %__MODULE__{tool_slot: {:running, ref, _pid, call}} = state
      ) do
    # A runner crash is a result, never a node crash (ADR 0001).
    state = %{state | tool_slot: :none}
    crashed = %{ok: false, error: "tool crashed: " <> inspect_slice(reason)}
    display(state.ui, {:tool_result, tool_result_msg(call, crashed)})
    record_and_continue(state, call, crashed)
  end

  # A stream task going down while still streaming: the producer-of-record rule
  # from ADR 0002 moves here — finalize the partial content, explain, idle. A
  # :normal DOWN can only mean the contract was broken (a reporting task
  # clears stream_ref first); it gets the same degradation.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %__MODULE__{status: :streaming, stream_ref: ref} = state
      ) do
    state =
      state
      |> finalize_episode(state.episode_content)
      |> reset_turn()

    display(state.ui, {:entry, :system, "[stream failed: #{inspect_slice(reason)}]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  ## Episode loop

  defp start_episode(state) do
    display(state.ui, {:phase, :streaming})
    agent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(
        state.supervisor,
        fn ->
          ChatStream.run(agent, state.provider, state.messages, Tools.schema())
        end,
        restart: :temporary
      )

    {:noreply,
     %{
       state
       | status: :streaming,
         stream_pid: pid,
         stream_ref: Process.monitor(pid),
         episode_content: "",
         pending_usage: nil
     }}
  end

  # The turn's end without tools: bank the (final-episode-only) usage, finalize,
  # idle (ADR 0007 §5 amends ADR 0006: intermediate episodes' usage is dropped).
  defp end_turn_final(state, content) do
    if content == "" do
      display(state.ui, {:entry, :system, "[model returned nothing]"})
    end

    state =
      state
      |> finalize_episode(content)
      |> reset_turn()

    if state.pending_usage, do: display(state.ui, {:usage, state.pending_usage})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp end_turn_cancelled(state, content) do
    state =
      state
      |> finalize_episode(content)
      |> reset_turn()

    display(state.ui, {:entry, :system, "[cancelled]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp begin_tool_batch(state, content, calls) do
    assistant = %{
      role: "assistant",
      content: if(content == "", do: nil, else: content),
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: Jason.encode!(call.args || %{})}
          }
        end)
    }

    state = %{
      state
      | messages: state.messages ++ [assistant],
        status: :tools,
        calls: calls,
        call_index: 0,
        results: %{},
        tool_slot: :none
    }

    display(state.ui, {:phase, :executing_tool})
    next_call(state)
  end

  defp next_call(%__MODULE__{call_index: index, calls: calls} = state)
       when index >= length(calls) do
    flush_tool_messages(state)
  end

  defp next_call(%__MODULE__{call_index: index} = state) do
    call = Enum.at(state.calls, index)

    case classify(call) do
      {:error, error} ->
        display(state.ui, {:tool_call, %{id: call.id, name: call.name, args: call.args}})
        display(state.ui, {:tool_result, tool_result_msg(call, error)})
        record_and_continue(state, call, error)

      # Normalized args (defaults filled) flow to preview, display, and runner.
      {:ok, args} ->
        call = %{call | args: args}
        display(state.ui, {:tool_call, %{id: call.id, name: call.name, args: args}})
        dispatch_validated(state, call)
    end
  end

  # A stream-level error (malformed JSON arguments) short-circuits validation;
  # otherwise validation itself is the gate.
  defp classify(%{error: error}) when is_binary(error), do: {:error, %{ok: false, error: error}}

  defp classify(call) do
    case Tools.validate(call.name, call.args || %{}) do
      {:error, message} -> {:error, %{ok: false, error: message}}
      {:ok, args} -> {:ok, args}
    end
  end

  defp dispatch_validated(state, call) do
    if automatic?(call.name) do
      dispatch_runner(state, call)
    else
      case Preview.build(call.name, call.args, state.cwd) do
        {:error, result} ->
          display(state.ui, {:tool_result, tool_result_msg(call, result)})
          record_and_continue(state, call, result)

        {:ok, preview} ->
          ref = make_ref()

          preview = %{id: call.id, name: call.name, args: call.args, lines: preview.lines}

          display(state.ui, {:confirm, ref, preview})
          {:noreply, %{state | tool_slot: {:confirming, ref, call}}}
      end
    end
  end

  defp automatic?("read_file"), do: true
  defp automatic?("list_directory"), do: true
  defp automatic?(_mutation), do: false

  # The mutating runner starts ONLY after the approval keypress (ADR 0007 §4).
  # Re-announcing :executing_tool here keeps the activity line truthful for the
  # whole execution (the confirmation phase would otherwise linger while the
  # command runs) and re-arms Esc's interrupt. The monitor goes up after
  # start_child returns; the runner self-reports its own crash before dying,
  # so a death inside that window still reaches the agent as a result and the
  # monitor clauses only ever see what the body could not report (ADR 0012).
  defp dispatch_runner(state, call) do
    display(state.ui, {:phase, :executing_tool})
    agent = self()
    args = call.args
    cwd = state.cwd
    opts = [exec_timeout: state.exec_timeout]

    # A crash is reported by the dying process itself, as a result — the
    # monitor's DOWN reason carries no information about whether the body
    # ran, and a crash in the spawn window would otherwise surface as :noproc
    # and be misreported (ADR 0012). Deaths the body cannot observe (an
    # external kill) still take the DOWN clauses.
    {:ok, pid} =
      Task.Supervisor.start_child(
        state.supervisor,
        fn ->
          try do
            send(agent, {:tool_done, call.id, Runner.run(call.name, args, cwd, opts)})
          rescue
            # Belt over Runner.run's own rescue (runner.ex): reachable only
            # if that inner rescue is stripped — the crash-report shape was
            # probe-verified in review, not suite-reachable.
            # coveralls-ignore-start
            reason ->
              send(
                agent,
                {:tool_done, call.id,
                 %{ok: false, error: "tool crashed: " <> inspect_slice(reason)}}
              )

              # coveralls-ignore-stop
          end
        end,
        restart: :temporary
      )

    {:noreply, %{state | tool_slot: {:running, Process.monitor(pid), pid, call}}}
  end

  defp record_and_continue(state, call, result) do
    state = %{
      state
      | results: Map.put(state.results, call.id, result),
        call_index: state.call_index + 1
    }

    next_call(state)
  end

  # One tool message per announced call, in call order — a transcript with
  # dangling tool_calls is an API error waiting to happen (ADR 0007 §1).
  defp flush_tool_messages(state) do
    tool_messages =
      Enum.map(state.calls, fn call ->
        %{
          role: "tool",
          tool_call_id: call.id,
          content: Jason.encode!(state.results[call.id] || %{ok: false, error: "no result"})
        }
      end)

    start_episode(%{state | messages: state.messages ++ tool_messages})
  end

  # Abort the batch: unresolved calls (from the current index on) get cancelled
  # results so the transcript stays round-trippable; no model re-prompt.
  # `current == nil` means the current call already recorded its own result —
  # both paths fill every remaining call (a nil result would encode as the
  # string "null" in the tool message).
  defp abort_tool_run(state, nil) do
    fill_cancelled(%{state | tool_slot: :none})
  end

  defp abort_tool_run(state, current) do
    display(state.ui, {:tool_result, tool_result_msg(current, %{ok: false, cancelled: true})})
    fill_cancelled(%{state | tool_slot: :none})
  end

  defp fill_cancelled(state) do
    cancelled = %{ok: false, cancelled: true}

    results =
      state.calls
      |> Enum.drop(state.call_index)
      |> Enum.reduce(state.results, &Map.put(&2, &1.id, cancelled))

    tool_messages =
      Enum.map(state.calls, fn call ->
        %{role: "tool", tool_call_id: call.id, content: Jason.encode!(results[call.id])}
      end)

    state = %{
      state
      | status: :idle,
        messages: state.messages ++ tool_messages,
        results: results,
        call_index: length(state.calls)
    }

    display(state.ui, {:entry, :system, "[tool run cancelled]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp finalize_episode(state, content) do
    if content != "" do
      %{state | messages: state.messages ++ [%{role: "assistant", content: content}]}
    else
      state
    end
  end

  defp reset_turn(state) do
    %{
      state
      | status: :idle,
        calls: [],
        call_index: 0,
        results: %{},
        tool_slot: :none,
        stream_ref: nil,
        stream_pid: nil,
        episode_content: ""
    }
  end

  ## Display helpers

  defp display(ui, message) when is_pid(ui), do: send(ui, message)

  defp tool_result_msg(call, result) do
    %{
      id: call.id,
      name: call.name,
      ok: result[:ok] == true,
      status: result_status(result),
      output: display_excerpt(result)
    }
  end

  defp result_status(%{rejected: true}), do: "rejected"
  defp result_status(%{cancelled: true}), do: "cancelled"
  defp result_status(%{ok: true}), do: "ok"

  defp result_status(%{error: error}) when is_binary(error),
    do: "error: " <> String.slice(error, 0, 160)

  defp result_status(_other), do: "error"

  # The model receives the bounded full result; the log row gets ≤ 30 lines.
  defp display_excerpt(result) do
    case result[:output] || result[:content] do
      nil ->
        nil

      body ->
        lines = String.split(body, "\n")

        if length(lines) <= @display_lines do
          body
        else
          lines
          |> Enum.take(@display_lines)
          |> Enum.join("\n")
        end
    end
  end

  defp inspect_slice(reason) do
    reason
    |> inspect()
    |> String.slice(0, 120)
  end

  # The error message rides the notice (P2-3): the user sees WHY — a typo'd
  # --profile, a migration refusal, an unfinished wizard — not a static hint.
  defp no_provider_text(message),
    do: @no_provider_prefix <> message <> @no_provider_suffix
end

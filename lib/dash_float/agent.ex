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

  alias DashFloat.Config
  alias DashFloat.LLM.ChatStream
  alias DashFloat.Session
  alias DashFloat.Tools
  alias DashFloat.Tools.Preview
  alias DashFloat.Tools.Runner

  require Logger

  @default_exec_timeout 30_000

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
    # Session identity (ADR 0014 §5): a nil session_dir means persistence is
    # off; the rest are minted at the first save or adopted from :resume.
    :session_dir,
    :session_id,
    :session_pin,
    :session_created_at,
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
    * `:session_dir` — the sessions directory; transcript persistence stays
      off unless it is set (default: nil — deliberate, ADR 0014 §5)
    * `:resume` — `%{id: _, pin: _, messages: _}` from `DashFloat.Session.load/2`,
      optionally with the session's `:created_at`; the agent adopts them
      (default: nil)
    * `:name` — GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    init_args = {
      Keyword.fetch!(opts, :provider),
      Keyword.get(opts, :cwd) || File.cwd!(),
      Keyword.get(opts, :supervisor, DashFloat.TaskSupervisor),
      Keyword.get(opts, :exec_timeout, @default_exec_timeout),
      Keyword.get(opts, :session_dir),
      Keyword.get(opts, :resume)
    }

    GenServer.start_link(__MODULE__, init_args, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init({provider, cwd, supervisor, exec_timeout, session_dir, resume}) do
    # A resumed agent adopts the loaded session's id, pin, created_at, and
    # history in one move: the first prompt streams the restored transcript
    # and the next save rewrites the same file under the same id (ADR 0014 §6).
    {session_id, session_pin, session_created_at, messages} =
      case resume do
        %{id: id, pin: pin, messages: messages} ->
          {id, pin, Map.get(resume, :created_at), messages}

        nil ->
          {nil, nil, nil, []}
      end

    {:ok,
     %__MODULE__{
       provider: provider,
       cwd: cwd,
       supervisor: supervisor,
       exec_timeout: exec_timeout,
       session_dir: session_dir,
       session_id: session_id,
       session_pin: session_pin,
       session_created_at: session_created_at,
       messages: messages
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
        # Persist before the episode starts: a kill mid-stream must lose at
        # most the reply, never the question (ADR 0014 §5).
        state = persist(state)
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
    calls = dedup_ids(calls)

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

    # The deliberately-dangling write (ADR 0014 §5): the batch is on disk
    # before any tool runs, so a kill mid-batch leaves the repairable shape.
    state =
      persist(%{
        state
        | messages: state.messages ++ [assistant],
          status: :tools,
          calls: calls,
          call_index: 0,
          results: %{},
          tool_slot: :none
      })

    display(state.ui, {:phase, :executing_tool})
    next_call(state)
  end

  # Id uniqueness is owned at the batch boundary (ADR 0014 §4): persistence
  # makes ids load-bearing across processes, and `state.results` is keyed by
  # call id, so a repeated id would serve one call's answer to two calls.
  # Each repeat after its first use renames in place (id, id-2, id-3, …)
  # BEFORE the assistant message is built, so the assistant `tool_calls`, the
  # dispatch, the results map, and the flushed tool messages all carry the
  # renamed ids consistently.
  defp dedup_ids(calls) do
    {renamed, _counts} =
      Enum.map_reduce(calls, %{}, fn %{id: id} = call, counts ->
        n = Map.get(counts, id, 0) + 1
        call = if n == 1, do: call, else: %{call | id: "#{id}-#{n}"}
        {call, Map.put(counts, id, n)}
      end)

    renamed
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
            # coveralls-ignore-start
            # Belt over Runner.run's own rescue (runner.ex): reachable only
            # if that inner rescue is stripped — the crash-report shape was
            # probe-verified in review, not suite-reachable.
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

    state = persist(%{state | messages: state.messages ++ tool_messages})
    start_episode(state)
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
    display(state.ui, {:tool_result, tool_result_msg(current, Tools.cancelled_result())})
    fill_cancelled(%{state | tool_slot: :none})
  end

  defp fill_cancelled(state) do
    cancelled = Tools.cancelled_result()

    results =
      state.calls
      |> Enum.drop(state.call_index)
      |> Enum.reduce(state.results, &Map.put(&2, &1.id, cancelled))

    tool_messages =
      Enum.map(state.calls, fn call ->
        %{role: "tool", tool_call_id: call.id, content: Jason.encode!(results[call.id])}
      end)

    state =
      persist(%{
        state
        | status: :idle,
          messages: state.messages ++ tool_messages,
          results: results,
          call_index: length(state.calls)
      })

    display(state.ui, {:entry, :system, "[tool run cancelled]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp finalize_episode(state, content) do
    if content != "" do
      persist(%{state | messages: state.messages ++ [%{role: "assistant", content: content}]})
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

  ## Session persistence

  # A full-file rewrite at every message-list mutation, opt-in via
  # :session_dir — the nil default keeps tests and embedded starters off the
  # user's XDG dir. A failed save degrades to a warning plus one system
  # entry; the turn continues — persistence never joins the episode loop
  # (ADR 0014 §5).
  defp persist(%__MODULE__{session_dir: nil} = state), do: state

  # Id, pin, and created_at are minted once, at the first save. An error
  # provider never reaches a persist (the prompt arm guards it), so the pin
  # always reads off an {:ok, config}.
  defp persist(%__MODULE__{session_id: nil} = state) do
    persist(%{
      state
      | session_id: Session.new_id(),
        session_created_at: now_iso8601_utc(),
        session_pin: session_pin(state.provider)
    })
  end

  # A hand-built resume map may carry no created_at; the first save stamps it.
  defp persist(%__MODULE__{session_created_at: nil} = state) do
    persist(%{state | session_created_at: now_iso8601_utc()})
  end

  defp persist(
         %__MODULE__{
           ui: ui,
           session_dir: dir,
           session_id: id,
           session_created_at: created_at,
           session_pin: pin,
           messages: messages
         } = state
       ) do
    session = %{version: 1, id: id, created_at: created_at, pin: pin, messages: messages}

    case Session.save(dir, session) do
      :ok ->
        state

      {:error, message} ->
        Logger.warning(message)
        display(ui, {:entry, :system, "[session not saved: " <> message <> "]"})
        state
    end
  end

  defp now_iso8601_utc, do: DateTime.to_iso8601(DateTime.utc_now())

  # Picked field-by-field off the effective provider config — never the
  # struct — so api_key has no path into the session file (ADR 0014 §3).
  defp session_pin({:ok, %Config{profile: profile, model: model, base_url: base_url}}) do
    %{profile: profile, model: model, base_url: base_url}
  end

  ## Display helpers

  defp display(ui, message) when is_pid(ui), do: send(ui, message)

  defp tool_result_msg(call, result) do
    %{
      id: call.id,
      name: call.name,
      ok: result[:ok] == true,
      status: Tools.display_status(result),
      output: Tools.display_excerpt(result)
    }
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

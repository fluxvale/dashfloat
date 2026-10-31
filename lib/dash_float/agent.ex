defmodule DashFloat.Agent do
  @moduledoc """
  The Agent Manager ([ADR 0001](0001-founding-stack-and-architecture.md)): owns the
  conversation, runs the episode loop (stream → tools → stream → … → idle), gates
  tool calls through the session mode (ADR 0016), and is the single voice speaking
  the display contract into the UI. ChatStream and the tool runners report here as plain
  messages; the agent forwards, renders, and orchestrates. It holds no timers —
  timeouts live in ChatStream and the runner Tasks. See ADR 0007.
  """

  use GenServer

  alias DashFloat.Accounting
  alias DashFloat.Config
  alias DashFloat.Config.Presets
  alias DashFloat.Images
  alias DashFloat.LLM.ChatStream
  alias DashFloat.Mode
  alias DashFloat.ProjectInstructions
  alias DashFloat.Session
  alias DashFloat.Session.Title
  alias DashFloat.Synthetic
  alias DashFloat.SystemPrompt
  alias DashFloat.Tools
  alias DashFloat.Tools.Preview
  alias DashFloat.Tools.Runner

  require Logger

  @default_exec_timeout 30_000
  @default_vet_timeout 10_000

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
    # The session title (#80): the boot/resume/rename-adopted value, the
    # in-flight guard ref, and the side-request's fetcher seam for tests —
    # with the one-shot auto-title latch, false until the request fires.
    :session_title,
    :title_ref,
    :title_fetcher,
    title_fired?: false,
    # :idle | :streaming | :tools
    status: :idle,
    messages: [],
    episode_content: "",
    # The episode's accumulated reasoning (issue #78): every {:reasoning, _}
    # delta appends here, mirroring episode_content — the failure/cancel
    # paths persist from this accumulation while the stream_done report is
    # the truth of record on the happy path.
    episode_reasoning: "",
    pending_usage: nil,
    stream_ref: nil,
    stream_pid: nil,
    calls: [],
    call_index: 0,
    results: %{},
    # :none | {:running, reference(), pid(), map()}
    # | {:running_cancelled, reference(), pid(), map()}
    # | {:confirming, reference(), map()}
    # | {:vetting, reference(), reference(), pid(), map(), map()} — the
    #   check ref the vetter's report must carry, then the monitor ref
    # | {:vetting_cancelled, reference(), reference(), pid(), map()}
    # | {:asking, reference(), map()} — the question tool's pending ask
    #   (#134, ADR 0028): the ref the decision must echo
    tool_slot: :none,
    # Context accounting (ADR 0022): the usage-frame anchor, the eviction
    # history, and the current episode's request message count — the count
    # that completes the anchor when the episode's frame lands.
    anchor: nil,
    compactions: [],
    request_len: 0,
    # The session mode and the AUTO safety check (ADR 0016): the agent owns
    # the gate; :vetter is the injectable check module.
    mode: :build,
    vetter: DashFloat.Tools.Vetter,
    vet_timeout: @default_vet_timeout,
    # The Synthetic context (ADR 0021 §2) — discovered from the provider
    # config, or pinned by the :synthetic opt (the loopback test seam);
    # pinned means {:set_provider, _} must not re-resolve it.
    synthetic: nil,
    synthetic_pinned?: false
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
      optionally with the session's `:created_at` plus the ADR 0022 §6
      diagnostics `:context` (the persisted anchor) and `:compactions` (the
      eviction history); the agent adopts them (default: nil). A `:title`
      entry — the loaded session's title (#80) — is adopted the same way
    * `:title` — a boot-normalized session title, adopted verbatim into
      `session_title` (default: nil)
    * `:title_fetcher` — the auto-title side-request's fetcher (an `{m, f}`
      MFA or fun/2; default `{DashFloat.Session.Title, :request}`; the
      injection seam for tests)
    * `:mode` — the interaction mode (ADR 0016): `:plan`, `:build`, `:auto`,
      or `:unchained` (default: `:build`; anything else raises `ArgumentError`)
    * `:vetter` — the AUTO safety-check module implementing `verdict/4`
      (default: `DashFloat.Tools.Vetter`; the injection seam for tests)
    * `:vet_timeout` — the safety check's hard timeout in ms
      (default: #{@default_vet_timeout})
    * `:synthetic` — the Synthetic context (ADR 0021 §2): `:discover`
      (the default) resolves it from the provider config (and again on every
      `{:set_provider, _}`); a `DashFloat.Synthetic` struct pins that context
      verbatim and nil turns the features off — both pinned forms survive a
      provider swap (the loopback test seam)
    * `:name` — GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    mode = Keyword.get(opts, :mode, :build)

    Mode.valid?(mode) ||
      raise ArgumentError, "unknown mode: #{inspect(mode)} (plan, build, auto, unchained)"

    init_args = {
      Keyword.fetch!(opts, :provider),
      Keyword.get(opts, :cwd) || File.cwd!(),
      Keyword.get(opts, :supervisor, DashFloat.TaskSupervisor),
      Keyword.get(opts, :exec_timeout, @default_exec_timeout),
      Keyword.get(opts, :session_dir),
      Keyword.get(opts, :resume),
      mode,
      Keyword.get(opts, :vetter, DashFloat.Tools.Vetter),
      Keyword.get(opts, :vet_timeout, @default_vet_timeout),
      Keyword.get(opts, :title),
      Keyword.get(opts, :title_fetcher),
      Keyword.get(opts, :synthetic, :discover)
    }

    GenServer.start_link(__MODULE__, init_args, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(
        {provider, cwd, supervisor, exec_timeout, session_dir, resume, mode, vetter, vet_timeout,
         title, title_fetcher, synthetic_opt}
      ) do
    # A resumed agent adopts the loaded session's id, pin, created_at, and
    # history in one move: the first prompt streams the restored transcript
    # and the next save rewrites the same file under the same id (ADR 0014 §6).
    # The ADR 0022 §6 diagnostics ride the same map: the persisted context
    # shape converts to the accounting anchor at this boundary, and the
    # eviction history is adopted verbatim. The title too (#80) — a resume
    # without one stays nil.
    {session_id, session_pin, session_created_at, messages, anchor, compactions, resumed_title} =
      case resume do
        %{id: id, pin: pin, messages: messages} ->
          {id, pin, Map.get(resume, :created_at), messages,
           anchor_from_context(Map.get(resume, :context), messages),
           list_or_empty(Map.get(resume, :compactions)), Map.get(resume, :title)}

        nil ->
          {nil, nil, nil, [], nil, [], nil}
      end

    # The Synthetic context (ADR 0021 §2): :discover reads the provider
    # config once here; a struct pins the injected context (the loopback test
    # seam); an explicit nil (or anything else) is off, pinned.
    {synthetic, synthetic_pinned?} =
      case synthetic_opt do
        :discover -> {Synthetic.context(provider), false}
        %Synthetic{} = ctx -> {ctx, true}
        _other -> {nil, true}
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
       session_title: title || resumed_title,
       title_fetcher: title_fetcher,
       messages: initial_messages(cwd, resume, messages),
       anchor: anchor,
       compactions: compactions,
       mode: mode,
       vetter: vetter,
       vet_timeout: vet_timeout,
       synthetic: synthetic,
       synthetic_pinned?: synthetic_pinned?
     }}
  end

  ## UI messages (plain sends; the UI process is the sender)

  @impl GenServer
  def handle_info({:prompt, ui, text, paths}, %__MODULE__{status: :idle} = state)
      when is_pid(ui) and is_binary(text) and is_list(paths) do
    case state.provider do
      {:error, message} ->
        display(ui, {:entry, :system, no_provider_text(message)})
        display(ui, {:phase, :idle})
        {:noreply, state}

      {:ok, config} ->
        case user_message(config, text, paths) do
          {:ok, message} ->
            state = %{state | ui: ui, messages: state.messages ++ [message]}

            # Compact and persist before the episode starts: a kill mid-stream
            # must lose at most the reply, never the question (ADR 0014 §5), and
            # compaction rides the same seam — after the append, before the
            # episode, the one point every request passes through (ADR 0022 §5).
            # One persist per prompt, so a failed save shows one notice (m4).
            state = maybe_compact(state)
            start_episode(state)

          {:error, refusal} ->
            # The image gate's visible refusal (ADR 0018 §4): nothing is
            # appended, nothing is sent, and the UI returns to idle.
            display(ui, {:entry, :system, refusal})
            display(ui, {:phase, :idle})
            {:noreply, state}
        end
    end
  end

  # A prompt while busy is a UI bug (the UI gates on phase): ignore, never crash.
  def handle_info({:prompt, _ui, _text, _paths}, state), do: {:noreply, state}

  # /compact (issue #92; ADR 0022's amendment): the same eviction the
  # prompt-time hook runs, on demand — never a second implementation. The
  # same ~80% trigger governs: below it the command is a no-op that reports
  # where the estimate stands, because drop-oldest below the trigger
  # discards context nothing is at risk to reclaim. The window is the
  # resolved chain (issue #111: configured, else seeded, else the
  # documented default WITH the note naming the remedy — never a bare
  # refusal and never silent).
  def handle_info(
        {:compact, ui},
        %__MODULE__{status: :idle, provider: {:ok, %Config{} = config}} = state
      )
      when is_pid(ui) do
    {window, source} = Config.context_window(config)

    case eviction_pass(%{state | ui: ui}, window, source) do
      {state, nil} ->
        usage = Accounting.usage(state.messages, state.anchor, window)

        display(ui, {:entry, :system, below_trigger_text(usage, source)})

        {:noreply, state}

      {state, _plan} ->
        {:noreply, state}
    end
  end

  # No resolved provider: nothing compacts and nothing is guessed (ADR 0022
  # §2) — the command says so, naming the remedy (issue #111), never silence.
  def handle_info({:compact, ui}, %__MODULE__{status: :idle} = state) when is_pid(ui) do
    display(
      ui,
      {:entry, :system,
       "[context: no context window resolved — nothing to compact; " <>
         "set context on the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS]"}
    )

    {:noreply, state}
  end

  # A /compact while a turn is open is a UI race (the TUI gates commands
  # idle, like submit): ignore like a busy prompt — the message list is only
  # mutated where it is stable (ADR 0022 §5).
  def handle_info({:compact, _ui}, state), do: {:noreply, state}

  # The mode seam (ADR 0016 §7): the UI sends, the agent validates, the echo
  # updates the chrome. Accepted in any phase — the gate reads per call at
  # dispatch, and a pending confirmation is left standing untouched.
  def handle_info({:set_mode, ui, mode}, %__MODULE__{mode: old} = state) when is_pid(ui) do
    if Mode.valid?(mode) do
      state = %{state | ui: ui, mode: mode}
      display(ui, {:mode, mode})
      display(ui, {:entry, :system, "[mode: #{Mode.label(old)} → #{Mode.label(mode)}]"})
      {:noreply, state}
    else
      display(
        ui,
        {:entry, :system, "unknown mode: #{inspect(mode)} (plan, build, auto, unchained)"}
      )

      {:noreply, state}
    end
  end

  # The startup phase's handoff (ADR 0009): the agent boots with the boot-time
  # classification (an error while the wizard/modal runs); once setup
  # completes, the UI delivers the resolved provider here — the agent is the
  # single voice, so the config it streams with must be this one message old
  # at most.
  def handle_info({:set_provider, provider}, %__MODULE__{synthetic_pinned?: false} = state) do
    # Post-wizard handoff: the config swapped, so the discoverable Synthetic
    # context re-reads with it. A pinned context (ADR 0021 §2) never moves.
    {:noreply, %{state | provider: provider, synthetic: Synthetic.context(provider)}}
  end

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

  # The question tool's answer (#134, ADR 0028): matched by the per-ask ref
  # (the stale-decision discipline). An answer — including the explicit
  # dismissed one — records the result and continues the batch; the model
  # always receives an answer, never a silent drop.
  def handle_info(
        {:question_decision, ref, {:answered, labels}},
        %__MODULE__{tool_slot: {:asking, ref, call}} = state
      )
      when is_list(labels) do
    state = %{state | tool_slot: :none}
    answered = %{ok: true, answers: labels}
    display(state.ui, {:tool_result, tool_result_msg(call, answered)})
    record_and_continue(state, call, answered)
  end

  def handle_info(
        {:question_decision, ref, :dismissed},
        %__MODULE__{tool_slot: {:asking, ref, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    dismissed = %{ok: false, cancelled: true}
    display(state.ui, {:tool_result, tool_result_msg(call, dismissed)})
    record_and_continue(state, call, dismissed)
  end

  # A stale question decision (its ask was superseded) is ignored.
  def handle_info({:question_decision, _ref, _decision}, state), do: {:noreply, state}

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

  # Esc during a check cancels BY MESSAGE (ADR 0016 §6): the vetter cancels
  # its stream child and reports or dies — a vetter that never checks its
  # mailbox still dies at its own deadline. The batch aborts then, exactly
  # like a cancelled running tool.
  def handle_info(
        {:cancel},
        %__MODULE__{tool_slot: {:vetting, check_ref, mon_ref, pid, call, _preview}} = state
      ) do
    if pid, do: send(pid, :cancel)
    {:noreply, %{state | tool_slot: {:vetting_cancelled, check_ref, mon_ref, pid, call}}}
  end

  def handle_info({:cancel}, state), do: {:noreply, state}

  ## Stream messages (from ChatStream)

  def handle_info({:token, text}, %__MODULE__{status: :streaming} = state) when is_binary(text) do
    display(state.ui, {:token, text})
    {:noreply, %{state | episode_content: state.episode_content <> text}}
  end

  def handle_info({:token, _text}, state), do: {:noreply, state}

  # Reasoning deltas (issue #78): forwarded to the UI (the thinking block's
  # live growth) and accumulated for the finalize paths' persistence.
  def handle_info({:reasoning, text}, %__MODULE__{status: :streaming} = state)
      when is_binary(text) do
    display(state.ui, {:reasoning, text})
    {:noreply, %{state | episode_reasoning: state.episode_reasoning <> text}}
  end

  def handle_info({:reasoning, _text}, state), do: {:noreply, state}

  # The episode's usage frame completes the anchor minted at episode start
  # (ADR 0022 §1): its prompt_tokens measured over the request's message
  # count. Display forwarding of pending_usage is unchanged (last frame wins
  # at turn end, ADR 0007 §5). The refreshed anchor rides a context push —
  # the footer's span re-reads the measured estimate (ADR 0015 §2
  # amendment).
  def handle_info({:usage, usage}, %__MODULE__{status: :streaming} = state),
    do:
      {:noreply,
       push_context(%{
         state
         | pending_usage: usage,
           anchor: %{tokens: usage.prompt_tokens, index: state.request_len}
       })}

  def handle_info({:usage, _usage}, state), do: {:noreply, state}

  def handle_info({:stream_failed, text, partial}, %__MODULE__{status: :streaming} = state)
      when is_binary(text) do
    state =
      state
      |> finalize_episode(partial, state.episode_reasoning)
      |> reset_turn()

    display(state.ui, {:entry, :system, text})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  def handle_info({:stream_failed, _text, _partial}, state), do: {:noreply, state}

  def handle_info(
        {:stream_done,
         %{content: content, reasoning: reasoning, tool_calls: calls, cancelled: cancelled}},
        %__MODULE__{status: :streaming} = state
      )
      when is_binary(reasoning) do
    state = %{state | stream_ref: nil, stream_pid: nil}

    cond do
      cancelled -> end_turn_cancelled(state, content, reasoning)
      calls == [] -> end_turn_final(state, content, reasoning)
      true -> begin_tool_batch(state, content, reasoning, calls)
    end
  end

  # A report without the reasoning key is an older producer shape — read as
  # no thinking (hand-built sends, a future regression); never a crash.
  def handle_info(
        {:stream_done, %{content: content, tool_calls: calls, cancelled: cancelled}},
        %__MODULE__{status: :streaming} = state
      ) do
    state = %{state | stream_ref: nil, stream_pid: nil}

    cond do
      cancelled -> end_turn_cancelled(state, content, "")
      calls == [] -> end_turn_final(state, content, "")
      true -> begin_tool_batch(state, content, "", calls)
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

  ## Vetter messages (AUTO's safety check, ADR 0016 §6)

  # A report matching the live check resolves through the RE-READ gate: a
  # mode switch mid-check re-resolves the call under the current mode, and
  # the verdict decides only while that gate is still :vet (ADR 0016 §3).
  def handle_info(
        {:vet_done, check_ref, _id, verdict},
        %__MODULE__{tool_slot: {:vetting, check_ref, _mon_ref, _pid, call, preview}} = state
      ) do
    state = %{state | tool_slot: :none}
    resolve_vet(state, call, preview, verdict)
  end

  # A report from a check the user already Esc'd aborts the batch exactly
  # like a cancelled running tool — no re-gate: the user cancelled it.
  def handle_info(
        {:vet_done, check_ref, _id, _verdict},
        %__MODULE__{tool_slot: {:vetting_cancelled, check_ref, _mon_ref, _pid, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    abort_tool_run(state, call)
  end

  # A stale vet report (its check was superseded) is ignored — the same
  # discipline as a stale confirm decision, matched by the per-check ref:
  # a call id alone could match a late report from an earlier batch that
  # reused the id.
  def handle_info({:vet_done, _ref, _id, _verdict}, state), do: {:noreply, state}

  ## Session title (#80)

  # The auto-title proposal lands. The guard ref matches the live request
  # (the stale-straggler discipline); a nil text is a spent one-shot; a
  # title that arrived while in flight wins — that check is the entire
  # user-intent-wins precedence.
  def handle_info({:title_proposal, ref, text}, %__MODULE__{title_ref: ref} = state) do
    cond do
      is_nil(text) ->
        {:noreply, %{state | title_ref: nil}}

      is_binary(state.session_title) ->
        {:noreply, %{state | title_ref: nil}}

      true ->
        adopt_title(state, text)
    end
  end

  # A stale proposal (its guard ref was superseded) is ignored, never a crash.
  def handle_info({:title_proposal, _ref, _text}, state), do: {:noreply, state}

  # The rename seam: the UI sends, the agent validates against the same
  # rules the store enforces, resolves a holder, persists. A non-pid ui or
  # a non-binary title is a UI bug: ignored, never a crash.
  def handle_info({:set_title, ui, title}, state) when is_pid(ui) and is_binary(title) do
    case Title.normalize(title) do
      {:ok, cleaned} ->
        resolve_title(%{state | ui: ui}, cleaned)

      {:error, :empty} ->
        # The refusal rides the dialog too (issue #106): the display-only
        # push and the entry carry the same human text.
        display(ui, {:title_refused, "may not be empty"})
        display(ui, {:entry, :system, "[title not set: may not be empty]"})
        {:noreply, state}

      {:error, :too_long} ->
        display(ui, {:title_refused, "may not exceed 80 characters"})
        display(ui, {:entry, :system, "[title not set: may not exceed 80 characters]"})
        {:noreply, state}

      {:error, :reserved} ->
        display(ui, {:title_refused, "may not look like a session id"})
        display(ui, {:entry, :system, "[title not set: may not look like a session id]"})
        {:noreply, state}
    end
  end

  def handle_info({:set_title, _ui, _title}, state), do: {:noreply, state}

  # The /resume picker's session switch (issue #128): the loaded session
  # replaces the live one in a single move — init's resume adoption
  # (ADR 0014 §6), mid-process. The transcript is adopted VERBATIM, its
  # leading system message included — never re-seeded (ADR 0019 §1) — the
  # pin/created_at/title follow the file, the context anchor re-derives from
  # the persisted diagnostics, and the auto-title latch re-arms: the target
  # session's next settled exchange is its own first chance at a title. No
  # immediate persist — the file is the load's own bytes; a dangling-repair
  # rewrite converges on the next save (ADR 0014 §4).
  def handle_info(
        {:adopt_session, ui, %{id: id} = session},
        %__MODULE__{status: :idle} = state
      )
      when is_pid(ui) and is_binary(id) do
    messages = Map.get(session, :messages, [])

    {:noreply,
     %{
       state
       | ui: ui,
         session_id: id,
         session_pin: Map.get(session, :pin),
         session_created_at: Map.get(session, :created_at),
         session_title: Map.get(session, :title),
         title_fired?: false,
         title_ref: nil,
         messages: messages,
         anchor: anchor_from_context(Map.get(session, :context), messages),
         compactions: list_or_empty(Map.get(session, :compactions))
     }}
  end

  # An adopt while a turn is open is a UI race (the picker is idle-gated,
  # like submit): ignore, never crash — the message list is only mutated
  # where it is stable.
  def handle_info({:adopt_session, _ui, _session}, state), do: {:noreply, state}

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

  # A vetter death its body could not report (:killed/:noproc per ADR 0012,
  # or any unreported exit) is a failed check — the fail-safe direction —
  # resolved through the same re-read gate as a verdict.
  def handle_info(
        {:DOWN, mon_ref, :process, _down_pid, _reason},
        %__MODULE__{tool_slot: {:vetting, _check_ref, mon_ref, _pid, call, preview}} = state
      ) do
    state = %{state | tool_slot: :none}
    resolve_vet(state, call, preview, {:error, :vetter_died})
  end

  # A cancelled vetter dying before it could report aborts the batch like its
  # running-tool counterpart.
  def handle_info(
        {:DOWN, mon_ref, :process, _down_pid, _reason},
        %__MODULE__{tool_slot: {:vetting_cancelled, _check_ref, mon_ref, _pid, call}} = state
      ) do
    state = %{state | tool_slot: :none}
    abort_tool_run(state, call)
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
      |> finalize_episode(state.episode_content, state.episode_reasoning)
      |> reset_turn()

    display(state.ui, {:entry, :system, "[stream failed: #{inspect_slice(reason)}]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  ## The prompt's image gate (ADR 0018 §4/§6)

  # The submit-time user message (ADR 0018 §2): a plain turn keeps the string
  # content; a turn carrying paths is gated on the selected model's capability
  # and on re-reading each file — the agent owns the bytes at submit. A
  # refusal names the model or the path and lands as an `[images: …]` entry.
  defp user_message(_config, text, []), do: {:ok, %{role: "user", content: text}}

  defp user_message(%Config{images: false} = config, _text, _paths) do
    {:error, "[images: model #{model_name(config)} does not accept images — attach refused]"}
  end

  defp user_message(_config, text, paths) do
    with {:ok, urls} <- data_urls(paths) do
      {:ok, %{role: "user", content: text_parts(text) ++ image_parts(urls)}}
    end
  end

  defp data_urls(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, urls} ->
      case Images.data_url(path) do
        {:ok, url} -> {:cont, {:ok, urls ++ [url]}}
        {:error, reason} -> {:halt, {:error, "[images: " <> reason <> "]"}}
      end
    end)
  end

  # The text part leads, omitted when the prompt is empty — an image-only
  # turn is a legal submit (ADR 0018 §2).
  defp text_parts(""), do: []
  defp text_parts(text), do: [%{type: "text", text: text}]

  defp image_parts(urls), do: Enum.map(urls, &%{type: "image_url", image_url: %{url: &1}})

  # The refusal names the model — the nickname, else the id (ADR 0018 §4).
  defp model_name(%Config{nickname: nil, model: model}), do: model
  defp model_name(%Config{nickname: nickname}), do: nickname

  ## Episode loop

  defp start_episode(state) do
    display(state.ui, {:phase, :streaming})
    agent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(
        state.supervisor,
        fn ->
          ChatStream.run(agent, state.provider, state.messages, Tools.schema(state.synthetic),
            synthetic: state.synthetic
          )
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
         episode_reasoning: "",
         pending_usage: nil,
         request_len: length(state.messages)
     }}
  end

  # The turn's end without tools: bank the (final-episode-only) usage, finalize,
  # idle (ADR 0007 §5 amends ADR 0006: intermediate episodes' usage is dropped).
  # The auto-title side-request (#80) fires here and only here — the first
  # settled assistant turn — before the idle display and never on its critical
  # path: fetch_async returns as soon as the task starts.
  defp end_turn_final(state, content, reasoning) do
    if content == "" do
      display(state.ui, {:entry, :system, "[model returned nothing]"})
    end

    state =
      state
      |> finalize_episode(content, reasoning)
      |> reset_turn()
      |> maybe_fire_title(content)

    if state.pending_usage, do: display(state.ui, {:usage, state.pending_usage})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp end_turn_cancelled(state, content, reasoning) do
    state =
      state
      |> finalize_episode(content, reasoning)
      |> reset_turn()

    display(state.ui, {:entry, :system, "[cancelled]"})
    display(state.ui, {:phase, :idle})
    {:noreply, state}
  end

  defp begin_tool_batch(state, content, reasoning, calls) do
    calls = dedup_ids(calls)

    base = %{
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

    assistant = assistant_with_reasoning(base, reasoning)

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
  # Renames are decided against a used-id set — the original ids and every
  # rename so far — so a colliding original can never re-create a rename:
  # [a, a, a-2] becomes [a, a-2, a-3], not [a, a-2, a-2]. Applied BEFORE the
  # assistant message is built, so the assistant `tool_calls`, the dispatch,
  # the results map, and the flushed tool messages all carry the renamed ids
  # consistently.
  defp dedup_ids(calls) do
    {renamed, _used} =
      Enum.map_reduce(calls, MapSet.new(), fn %{id: id} = call, used ->
        id = if MapSet.member?(used, id), do: next_free_id(id, used), else: id
        {%{call | id: id}, MapSet.put(used, id)}
      end)

    renamed
  end

  # The first unused "#{id}-#{n}", n >= 2 — except when `id` itself is a
  # taken "<base>-<n>" rename of an also-used base, where the sequence
  # continues on the base (a-2 taken beside a → a-3, not a-2-2).
  defp next_free_id(id, used) do
    case renamed_form(id) do
      {base, n} when is_integer(n) ->
        if MapSet.member?(used, base) do
          free_suffix(base, n + 1, used)
        else
          free_suffix(id, 2, used)
        end

      _not_a_rename ->
        free_suffix(id, 2, used)
    end
  end

  defp free_suffix(base, n, used) do
    candidate = "#{base}-#{n}"

    if MapSet.member?(used, candidate), do: free_suffix(base, n + 1, used), else: candidate
  end

  defp renamed_form(id) do
    case Regex.run(~r/\A(.*)-(\d+)\z/, id) do
      [_full, base, n] -> {base, String.to_integer(n)}
      nil -> :error
    end
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
        pre_tool_use(state, call)
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

  # The PreToolUse seam (ADR 0016 §5): validation has passed; the mode gate
  # reads per call, here, at the one interception point in the tool path.
  # Safe tools dispatch with no preview, ever; mutating and risky calls build
  # their preview first in every mode (ADR 0016 §4) and the gate outcome
  # decides what follows it.
  #
  # The question tool (#134, ADR 0028) is intercepted BEFORE the gate: it is
  # not an action to gate but a question to ask — safe in every mode, and in
  # AUTO precisely the sanctioned way the model reaches the human.
  defp pre_tool_use(state, %{name: "question"} = call), do: ask_user(state, call)

  defp pre_tool_use(state, call) do
    class = Tools.class(call.name)

    case {class, Mode.gate(state.mode, class)} do
      {:safe, :run} -> dispatch_runner(state, call)
      {_class, outcome} -> with_preview(state, call, outcome)
    end
  end

  # The ask-user seam (#134, ADR 0028): the choice widget replaces the
  # composer (the {:confirm, _} arm's mirror — one widget, two askers), the
  # slot parks on the asker's ref, and the batch waits for the decision.
  # Herdr reports blocked with the question text (ADR 0024's amendment).
  defp ask_user(state, call) do
    %{"question" => question, "options" => options, "multiple" => multiple} = call.args
    ref = make_ref()

    display(state.ui, {:phase, :asking})

    display(
      state.ui,
      {:question, ref, %{question: question, options: options, multiple: multiple}}
    )

    {:noreply, %{state | tool_slot: {:asking, ref, call}}}
  end

  defp with_preview(state, call, outcome) do
    case Preview.build(call.name, call.args, state.cwd) do
      # A preview error stays the error result it is today, in every mode.
      {:error, result} ->
        display(state.ui, {:tool_result, tool_result_msg(call, result)})
        record_and_continue(state, call, result)

      {:ok, preview} ->
        preview = %{id: call.id, name: call.name, args: call.args, lines: preview.lines}

        case outcome do
          :run -> run_with_receipt(state, call, preview)
          gate -> resolve_gate(state, call, gate, preview)
        end
    end
  end

  # :confirm — BUILD's keypress boundary (ADR 0007 §4), unchanged.
  defp resolve_gate(state, call, :confirm, preview) do
    ref = make_ref()
    display(state.ui, {:confirm, ref, preview})
    {:noreply, %{state | tool_slot: {:confirming, ref, call}}}
  end

  # :propose — PLAN: the change is previewed, never executed, and the model
  # is told the mode blocked it — no human said no (ADR 0016 §4).
  defp resolve_gate(state, call, :propose, preview) do
    display(state.ui, {:tool_preview, preview})
    proposed = %{ok: false, blocked: "plan"}
    display(state.ui, {:tool_result, tool_result_msg(call, proposed)})
    record_and_continue(state, call, proposed)
  end

  # :vet — AUTO: the safety check decides run-vs-confirm per call (ADR 0016 §6).
  defp resolve_gate(state, call, :vet, preview), do: start_vet(state, call, preview)

  # :run — UNCHAINED (any no-keypress run): no confirm, no check; the preview
  # entry is the execution receipt (ADR 0016 §4).
  defp run_with_receipt(state, call, preview) do
    display(state.ui, {:tool_preview, preview})
    dispatch_runner(state, call)
  end

  # The check runs as a temporary task under the supervisor (a crash is a
  # report, never a node crash — ADR 0001), its hard timeout owned inside the
  # vetter (timers live in tasks — ADR 0001/0007). The body self-reports
  # every death it can observe (ADR 0012); the monitor placed after spawn
  # catches the rest as a failed check. The phase names the pause (:checking)
  # so the user sees why dispatch is holding.
  defp start_vet(state, call, preview) do
    display(state.ui, {:phase, :checking})
    agent = self()
    vetter = state.vetter
    provider = state.provider
    vet_timeout = state.vet_timeout
    lines = preview.lines
    # The check's identity: minted once, captured by the task closure, and
    # stored in the slot — the report must carry it, so a late report from a
    # previous batch (even over a reused call id) can never match.
    check_ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(
        state.supervisor,
        fn ->
          try do
            send(
              agent,
              {:vet_done, check_ref, call.id,
               vetter.verdict(provider, call, lines, vet_timeout: vet_timeout)}
            )
          rescue
            # coveralls-ignore-start
            # Belt over the vetter's never-raise contract (vetter.ex):
            # reachable only if a vetter misbehaves — an injected module, a
            # future regression.
            reason ->
              send(
                agent,
                {:vet_done, check_ref, call.id,
                 {:error, "safety check crashed: " <> inspect_slice(reason)}}
              )

              # coveralls-ignore-stop
          end
        end,
        restart: :temporary
      )

    {:noreply,
     %{state | tool_slot: {:vetting, check_ref, Process.monitor(pid), pid, call, preview}}}
  end

  # A deferred check resolves here — a report's verdict, or a DOWN
  # synthesized as the error verdict — and the gate is RE-READ: a mode switch
  # mid-check re-resolves the call under the current mode, and no deferred
  # resolution may execute what the current mode forbids (ADR 0016 §3).
  defp resolve_vet(state, call, preview, verdict) do
    case Mode.gate(state.mode, Tools.class(call.name)) do
      # Switched to unchained mid-check: dispatch regardless of the verdict.
      :run -> run_with_receipt(state, call, preview)
      # Switched to plan mid-check: the change is proposed, never executed —
      # exactly the plan path in resolve_gate (ADR 0016 §4).
      :propose -> resolve_gate(state, call, :propose, preview)
      # Switched to build mid-check: the confirm arms regardless of the
      # verdict, with an entry truthful to what happened — the mode is BUILD
      # now, so a prompt is correct (ADR 0016 §3's re-read rule).
      :confirm -> vet_confirm(state, call, preview, vet_entry(verdict))
      # The gate is still :vet (AUTO): the verdict resolves binary —
      # allow runs, everything else auto-rejects (ADR 0028's 0016 amendment).
      :vet -> resolve_verdict(state, call, preview, verdict)
    end
  end

  # AUTO resolves binary (#135, ADR 0016's 0028 amendment): an allow runs,
  # everything else — an ask verdict, a failed check, an out-of-contract
  # verdict — AUTO-REJECTS with a visible reason. No resolution of a live
  # :vet gate may arm a prompt; the owner's spec is binary by construction.
  defp resolve_verdict(state, call, preview, {:allow}), do: run_with_receipt(state, call, preview)

  defp resolve_verdict(state, call, preview, {:ask, reason}),
    do: auto_reject(state, call, preview, reason_text(reason))

  defp resolve_verdict(state, call, preview, {:error, reason}),
    do: auto_reject(state, call, preview, "safety check unavailable — " <> reason_text(reason))

  defp resolve_verdict(state, call, preview, _out_of_contract),
    do: auto_reject(state, call, preview, "safety check returned an unusable verdict")

  # The vetter seam is injectable: a reason that is not a binary (or a
  # verdict the contract never promised) must still render, never crash the
  # GenServer mid-batch.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(other), do: inspect(other)

  # The AUTO-reject (#135, ADR 0028): the preview lands as the receipt of
  # what was refused, a system entry carries the reason, and the model
  # receives `{"ok":false,"blocked":"auto","reason":…}` so it can adapt —
  # recorded in the transcript (the tool message persists) and visible in
  # the log, never a prompt.
  defp auto_reject(state, call, preview, reason) do
    display(state.ui, {:tool_preview, preview})
    display(state.ui, {:entry, :system, "[auto: rejected #{call.name} — #{reason}]"})

    rejected = %{ok: false, blocked: "auto", reason: reason}
    display(state.ui, {:tool_result, tool_result_msg(call, rejected)})
    record_and_continue(state, call, rejected)
  end

  # The confirm-arming entry names what actually happened. These shapes are
  # reachable ONLY on a mid-check re-gate to :confirm (the user switched to
  # BUILD while the check was in flight — a prompt is correct there): under
  # a live :vet gate every non-allow verdict takes auto_reject above.
  defp vet_entry({:allow}), do: nil
  defp vet_entry({:ask, _reason}), do: "[safety check: needs confirmation]"

  defp vet_entry({:error, _reason}),
    do: "[safety check unavailable — confirming]"

  # Fail-safe for an out-of-contract verdict — an injected or regressed
  # vetter — confirms instead of crashing the batch mid-check.
  defp vet_entry(_other), do: "[safety check unavailable — confirming]"

  # Ask, failure, and a mid-check switch to build all arm BUILD's confirm on
  # the already-built preview — the human answers on exactly the evidence
  # the check saw (ADR 0016 §6).
  defp vet_confirm(state, call, preview, entry) do
    if entry, do: display(state.ui, {:entry, :system, entry})

    ref = make_ref()
    display(state.ui, {:confirm, ref, preview})
    {:noreply, %{state | tool_slot: {:confirming, ref, call}}}
  end

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
    opts = [exec_timeout: state.exec_timeout, search: search_opts(state.synthetic)]

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

  # The web_search seam (ADR 0021 §6): the tool's POST target and key derive
  # from the Synthetic context; nil — or an unusable one, whose fields would
  # only crash or mis-dial — means WebSearch reports "not configured" and the
  # turn continues.
  defp search_opts(%Synthetic{base_url: base_url, api_key: api_key} = ctx)
       when is_binary(base_url) and is_binary(api_key),
       do: %{url: Synthetic.search_url(ctx), api_key: api_key}

  defp search_opts(_other), do: nil

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

  # Reasoning persists ONLY beside content (issue #78): a thinking-only
  # episode (cancelled before any answer token) is display-only — an
  # assistant message of nil content and no tool_calls is a degenerate wire
  # shape no provider needs, so the block lives and dies with the live view.
  defp finalize_episode(state, content, reasoning)
       when is_binary(content) and is_binary(reasoning) do
    if content != "" do
      message = assistant_with_reasoning(%{role: "assistant", content: content}, reasoning)
      persist(%{state | messages: state.messages ++ [message]})
    else
      state
    end
  end

  # The thinking rides the assistant message as `reasoning_content` — the
  # provider's own field name, transcript truth (ADR 0006's persistence
  # amendment); the key is omitted entirely when empty so non-reasoning
  # sessions stay byte-identical.
  defp assistant_with_reasoning(assistant, reasoning) when reasoning != "",
    do: Map.put(assistant, :reasoning_content, reasoning)

  defp assistant_with_reasoning(assistant, _empty), do: assistant

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
        episode_content: "",
        episode_reasoning: ""
    }
  end

  ## Context accounting (ADR 0022)

  # The compaction hook (ADR 0022 §5): prompt time, after the user message is
  # appended, before the episode starts. The window is the resolved chain
  # (issue #111: configured, else seeded, else the documented default) —
  # only an unresolved provider skips the pass. One persist per prompt
  # either way, so a failed save shows one notice (m4): the pass persists
  # when it dropped turns, this hook when it did not — the just-appended
  # question must land, oversize warning or not.
  defp maybe_compact(%__MODULE__{provider: {:ok, %Config{} = config}} = state) do
    {window, source} = Config.context_window(config)

    case eviction_pass(state, window, source) do
      {state, %{dropped: dropped}} when dropped > 0 -> state
      {state, _no_drop} -> persist(state)
    end
  end

  # The below-trigger no-op's reply (issue #92's amendment): where the
  # estimate stands, with the window's origin (issue #111) — a window no
  # source knows is the documented default, and the note names the remedy
  # instead of refusing.
  defp below_trigger_text(usage, :default) do
    "[context: at or under the 80% trigger — nothing to compact " <>
      "(est #{usage.used} of #{usage.window}, #{usage.percent}%) — window assumed: no source " <>
      "knows this model, using the #{Presets.default_window()}-token default; set context on " <>
      "the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS to override]"
  end

  defp below_trigger_text(usage, _known_window) do
    "[context: at or under the 80% trigger — nothing to compact (est #{usage.used} of #{usage.window}, #{usage.percent}%)]"
  end

  # The drop entry's assumption suffix (issue #111, hostile review F1): the
  # most destructive action must disclose the most — dropping turns against
  # the documented default names the assumption like every other surface.
  defp assumed_suffix(:default),
    do:
      " — window assumed, set context on the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS"

  defp assumed_suffix(_known_window), do: ""

  # The eviction both entry points run (ADR 0022 §4-§6; the /compact
  # amendment, issue #92): plan the drop; when something changes, mutate,
  # record, and announce. A drop persists immediately — the file and the
  # announcement agree — while an oversize-only pass changed nothing
  # file-worthy and leaves saving to the caller: the prompt hook saves for
  # the question; /compact saves nothing (the amendment's §3, no phantom
  # mint). Returns {state, plan}; a nil plan means the estimate sat at or
  # under the trigger with no oversize survivor — nothing changed.
  defp eviction_pass(state, window, source) do
    plan = Accounting.compact(state.messages, state.anchor, window)

    if plan.dropped == 0 and not plan.oversize do
      {state, nil}
    else
      before = Accounting.estimate(state.messages, state.anchor)
      after_estimate = Accounting.estimate(plan.kept, plan.anchor)

      state =
        with_compaction_record(
          %{state | messages: plan.kept, anchor: plan.anchor},
          plan,
          window,
          before,
          after_estimate
        )

      state = if plan.dropped > 0, do: persist(state), else: state

      if plan.dropped > 0 do
        display(
          state.ui,
          {:entry, :system,
           "[context: dropped #{plan.dropped} oldest turn(s) — est #{before}→#{after_estimate} of #{window}#{assumed_suffix(source)}]"}
        )
      end

      if plan.oversize do
        display(
          state.ui,
          {:entry, :system,
           "[context: the remaining turn alone exceeds the 80% window budget — kept whole]"}
        )
      end

      {state, plan}
    end
  end

  # One chronological record per dropping compact (ADR 0022 §6); an
  # oversize-only pass appends nothing.
  defp with_compaction_record(state, %{dropped: 0}, _window, _before, _after), do: state

  defp with_compaction_record(state, plan, window, before, after_estimate) do
    record = %{
      "at" => now_iso8601_utc(),
      "turns" => plan.dropped,
      "window" => window,
      "estimate_before" => before,
      "estimate_after" => after_estimate
    }

    %{state | compactions: state.compactions ++ [record]}
  end

  # The persisted anchor shape (%{prompt_tokens:, messages:}, ADR 0022 §6)
  # converts to the accounting anchor (%{tokens:, index:}) at the resume
  # boundary. Anything that is not two non-negative integers is no anchor —
  # a hand-built resume map may carry anything (hostile review B1) — and so
  # is an index past the message list: a legitimate anchor can never claim
  # more messages than exist, so that shape is hand damage and must not
  # silently defeat the trigger by estimating over an empty tail (M1).
  defp anchor_from_context(%{prompt_tokens: prompt_tokens, messages: messages}, list)
       when is_integer(prompt_tokens) and prompt_tokens >= 0 and is_integer(messages) and
              messages >= 0 and messages <= length(list) do
    %{tokens: prompt_tokens, index: messages}
  end

  defp anchor_from_context(_other, _list), do: nil

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_other), do: []

  # A fresh session opens with the assembled system prompt as its first
  # message (ADR 0019); a resumed one adopts its transcript verbatim — the
  # persisted messages already carry the system message the original
  # session start built.
  defp initial_messages(cwd, nil, []),
    do: [
      %{
        role: "system",
        content: SystemPrompt.build(cwd, project_instructions: ProjectInstructions.load(cwd))
      }
    ]

  defp initial_messages(_cwd, _resume, messages), do: messages

  ## Session persistence

  # The auto-title trigger (#80): the first settled turn with content,
  # persistence on, no title yet, the one-shot unspent, and the tri-state
  # not opted out. A failed task start just doesn't fire — fail-open.
  defp maybe_fire_title(
         %__MODULE__{
           session_dir: dir,
           session_title: nil,
           title_fired?: false,
           title_fetcher: fetcher,
           supervisor: supervisor,
           messages: messages,
           provider: {:ok, %Config{auto_title: auto_title} = config}
         } = state,
         content
       )
       when content != "" and not is_nil(dir) and auto_title != false do
    ref = make_ref()

    # The task rides the agent's own supervisor (the :supervisor opt's
    # constituency — embedded starters — must not depend on the global
    # name), and fetch_async catches the cannot-start exit: a supervisor
    # that cannot start the task is a miss, never a crash (ADR 0023 §8).
    case Title.fetch_async(config, first_exchange_context(messages),
           ref: ref,
           fetcher: fetcher,
           supervisor: supervisor
         ) do
      {:ok, _pid} ->
        %{state | title_fired?: true, title_ref: ref}

      # coveralls-ignore-start
      # A supervisor that could not start the task (dead, absent, full) —
      # the latch stays unarmed, the next settled turn retries. The failure
      # class is unit-proven (Title.fetch_async's bogus-supervisor test);
      # this arm is the pattern match consuming it, and forcing it here
      # needs a supervisor dead between the stream's end and the settle —
      # a race, not a test.
      {:error, _reason} ->
        state
        # coveralls-ignore-stop
    end
  end

  defp maybe_fire_title(state, _content), do: state

  # The first exchange: the first user message's content and the first
  # assistant REPLY's content (a tool_calls-only announcement carries nil —
  # the common first assistant message in a coding harness — so the find
  # skips to the first message with real content) — atom-keyed in-session,
  # string-keyed after a resume. A missing side reads "" (the instruction
  # alone can still title).
  defp first_exchange_context(messages) do
    %{
      user: first_content(messages, "user"),
      assistant: first_content(messages, "assistant")
    }
  end

  defp first_content(messages, role) do
    case Enum.find(messages, fn
           %{role: ^role, content: content} when is_binary(content) and content != "" ->
             true

           %{"role" => ^role, "content" => content} when is_binary(content) and content != "" ->
             true

           _other ->
             false
         end) do
      %{content: content} when is_binary(content) ->
        content

      %{"content" => content} when is_binary(content) ->
        content

      # coveralls-ignore-start
      # Unreachable in a settled exchange (the trigger fires only after the
      # assistant content was appended, and the user message precedes it);
      # the belt exists for hand-shaped transcripts.
      _other ->
        ""
        # coveralls-ignore-stop
    end
  end

  # Collision resolution: the proposal, else the proposal truncated under
  # the display cap plus " (n)" — first candidate no other session holds
  # wins; after 8, give up silently (the title is a courtesy, fail-open).
  # coveralls-ignore-start
  # The nil-dir arm is unreachable through the trigger (it fires only with a
  # session_dir); belt over a future trigger regression — a landing must
  # never raise.
  defp adopt_title(%__MODULE__{session_dir: nil} = state, _proposal) do
    {:noreply, %{state | title_ref: nil}}
  end

  # coveralls-ignore-stop
  defp adopt_title(%__MODULE__{session_dir: dir, session_id: id} = state, proposal) do
    n = Enum.find(1..8, fn n -> is_nil(Title.title_holder(dir, candidate(proposal, n), id)) end)

    case n do
      nil ->
        {:noreply, %{state | title_ref: nil}}

      n ->
        title = candidate(proposal, n)
        new_state = persist(%{state | session_title: title, title_ref: nil})
        display(new_state.ui, {:title, title})
        display(new_state.ui, {:entry, :system, "[session titled: #{title}]"})
        {:noreply, new_state}
    end
  end

  # Candidate 1 is the proposal; candidate n>1 fits " (n)" under the cap.
  defp candidate(proposal, 1), do: proposal

  defp candidate(proposal, n) do
    suffix = " (#{n})"
    String.slice(proposal, 0, Title.display_cap() - String.length(suffix)) <> suffix
  end

  # The normalized title: a holder names itself, a free title sets, persists,
  # and confirms. Persistence off — or no session yet — still normalizes,
  # sets, and confirms; persist just has no file to rewrite.
  defp resolve_title(%__MODULE__{session_dir: nil} = state, cleaned) do
    new_state = persist_if_started(%{state | session_title: cleaned})
    display(state.ui, {:title, cleaned})
    display(state.ui, {:entry, :system, "[session titled: #{cleaned}]"})
    {:noreply, new_state}
  end

  defp resolve_title(%__MODULE__{session_dir: dir, session_id: id} = state, cleaned) do
    case Title.title_holder(dir, cleaned, id) do
      nil ->
        new_state = persist_if_started(%{state | session_title: cleaned})
        display(state.ui, {:title, cleaned})
        display(state.ui, {:entry, :system, "[session titled: #{cleaned}]"})
        {:noreply, new_state}

      holder ->
        display(
          state.ui,
          {:title_refused, ~s("#{cleaned}" is already taken by session #{holder})}
        )

        display(
          state.ui,
          {:entry, :system,
           ~s([title not set: "#{cleaned}" is already taken by session #{holder}])}
        )

        {:noreply, state}
    end
  end

  # A title set before the first prompt has no file to rewrite: the id is
  # minted at the first save (ADR 0014 §5 — a launch that never prompts
  # leaves nothing), so the title waits in state for that save.
  defp persist_if_started(%__MODULE__{session_id: nil} = state), do: state
  defp persist_if_started(state), do: persist(state)

  # A full-file rewrite at every message-list mutation, opt-in via
  # :session_dir — the nil default keeps tests and embedded starters off the
  # user's XDG dir. A failed save degrades to a warning plus one system
  # entry; the turn continues — persistence never joins the episode loop
  # (ADR 0014 §5). The context push rides the same seam: every transcript
  # mutation passes through here (title adoptions ride along too — one
  # idempotent push on a user-paced rename), and the footer's span re-reads
  # off the snapshot even with persistence off (ADR 0015 §2 amendment).
  defp persist(state), do: write_session(push_context(state))

  defp write_session(%__MODULE__{session_dir: nil} = state), do: state

  defp write_session(%__MODULE__{session_id: nil} = state) do
    id = Session.new_id()

    # Recurse through write_session, not persist: the minted-id rewrite is
    # the same transcript mutation the outer persist already pushed for.
    # The id is announced to the UI only once the save attempt has run —
    # the Herdr reporter publishes a resume command off it (ADR 0024 §5);
    # a first save that fails leaves no file, and the announcement still
    # fires because a later turn retries under the SAME in-memory id.
    saved =
      write_session(%{
        state
        | session_id: id,
          session_created_at: now_iso8601_utc(),
          session_pin: session_pin(state.provider)
      })

    display(state.ui, {:session_id, id})
    saved
  end

  # A hand-built resume map may carry no created_at; the first save stamps it.
  defp write_session(%__MODULE__{session_created_at: nil} = state) do
    write_session(%{state | session_created_at: now_iso8601_utc()})
  end

  defp write_session(
         %__MODULE__{
           ui: ui,
           session_dir: dir,
           session_id: id,
           session_created_at: created_at,
           session_pin: pin,
           messages: messages
         } = state
       ) do
    session =
      %{version: 1, id: id, created_at: created_at, pin: pin, messages: messages}
      |> put_title(state.session_title)
      |> put_context(state.anchor)
      |> put_compactions(state.compactions)

    case Session.save(dir, session) do
      :ok ->
        state

      {:error, message} ->
        Logger.warning(message)
        display(ui, {:entry, :system, "[session not saved: " <> message <> "]"})
        state
    end
  end

  # The additive v1 fields (ADR 0022 §6): written only once they exist — no
  # anchor / empty history keeps the pre-compaction file shape exactly.
  defp put_context(session, nil), do: session

  defp put_context(session, %{tokens: tokens, index: index}) do
    Map.put(session, :context, %{prompt_tokens: tokens, messages: index})
  end

  defp put_compactions(session, []), do: session
  defp put_compactions(session, compactions), do: Map.put(session, :compactions, compactions)

  # The title rides every full-file rewrite once it exists (#80) — nil keeps
  # the pre-title file shape exactly (Session's drop-nil normalize).
  defp put_title(session, nil), do: session
  defp put_title(session, title), do: Map.put(session, :title, title)

  defp now_iso8601_utc, do: DateTime.to_iso8601(DateTime.utc_now())

  # Picked field-by-field off the effective provider config — never the
  # struct — so api_key has no path into the session file (ADR 0014 §3).
  defp session_pin({:ok, %Config{profile: profile, model: model, base_url: base_url}}) do
    %{profile: profile, model: model, base_url: sanitize_base_url(base_url)}
  end

  # pin.base_url is endpoint identity, not a credential store (ADR 0014 §3):
  # scheme://host[:port]/path — userinfo, query, and fragment dropped, so a
  # URL-carried key never sits in our metadata. A string without a parsable
  # scheme//host stays raw rather than mangling a working endpoint.
  defp sanitize_base_url(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{
          scheme: scheme,
          host: host,
          port: uri.port,
          path: uri.path
        })

      _unparsable ->
        base_url
    end
  end

  ## Display helpers

  defp display(ui, message) when is_pid(ui), do: send(ui, message)

  # The stage-2 footer seam (ADR 0022 §7 binding, ADR 0015 §2 amendment):
  # the {messages, anchor} snapshot the footer's Accounting.usage/3 read
  # computes from, pushed at every transcript mutation (persist) and at each
  # usage frame (the anchor's own refresh). Pure data — the TUI owns the
  # display window and the render-time read.
  defp push_context(%__MODULE__{ui: ui} = state) do
    display(ui, {:context, %{messages: state.messages, anchor: state.anchor}})
    state
  end

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

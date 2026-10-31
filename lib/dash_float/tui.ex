defmodule DashFloat.TUI do
  @moduledoc """
  The DashFloat terminal UI: a thin `ExRatatui.App` whose state logic lives in
  `DashFloat.TUI.State` and rendering in `DashFloat.TUI.View`. Process shape,
  key bindings, and teardown guarantees are settled in ADR 0002. Submits,
  cancels, confirmation decisions, and mode switches (ADR 0016) are plain
  sends to the agent (ADR 0007) — the agent is the single voice streaming
  back into the UI, and this
  process starts no tasks. The activity tick (ADR 0006) and the idle
  cursor blink (issue #104; ADR 0006's 2026-10-31 amendment — the first
  sanctioned REPEATING idle timer) are the repeating timers this process
  owns — the tick only while work is in flight, the blink only while idle.

  Run with `mix run --no-halt`. Quit with Ctrl+Q, or a double Ctrl+C: the
  first press shows a prompt, the second within two seconds exits
  (issue #28; ADR 0006 amendment).
  """

  # No `use ExRatatui.App`: it injects a :transient child_spec that would
  # shadow ours. A crashed UI must exit the application instead of bouncing
  # back blank (ADR 0002). The behaviour form is documented as equivalent.
  @behaviour ExRatatui.App

  alias DashFloat.Config
  alias DashFloat.Config.Catalog
  alias DashFloat.Config.Onboarding
  alias DashFloat.Herdr
  alias DashFloat.Session
  alias DashFloat.TUI.Selection
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Suggest
  alias DashFloat.TUI.View

  require Logger

  @tick :dashfloat_tick
  @tick_ms 125
  # The idle cursor blink (issue #104; ADR 0006's 2026-10-31 amendment):
  # a dedicated slow timer — riding the 125 ms activity tick would draw
  # 8 frames/s idle; this draws 2. Sanctioned exception #5, the first
  # REPEATING idle timer: bounded, honest, and recorded in the ADR with
  # its measured rate.
  @blink :dashfloat_blink
  @blink_ms 500
  @exit_guard :dashfloat_exit_guard
  @suggest :dashfloat_suggest

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts
    # Mouse capture is the TUI's own policy (issue #21; ADR 0006 amendment):
    # without it terminals emulate the wheel as arrow keys and the input
    # history eats them. A default here — not an Application opt — so the
    # connect-span test can pin it for every starter.
    |> Keyword.put_new(:mouse_capture, true)
    # Focus reporting is the TUI's own policy too (ADR 0015 §1) — the same
    # pattern as mouse capture (issue #21): it gates the composer's cursor,
    # and terminals that ignore the request send nothing, so the state
    # stays focused — the status quo ante.
    |> Keyword.put_new(:focus_events, true)
    |> Keyword.put(:mod, __MODULE__)
    |> ExRatatui.App.dispatch_start()
  end

  @impl ExRatatui.App
  def mount(opts) do
    # The agent monitor lives in this process, not State.new/1 — State stays
    # free of side effects (ADR 0007). The standing catalog refresh starts
    # here too (ADR 0009): supervised, unlinked, fail-open — live runs use
    # the real HTTP path, tests inject `catalog_fetcher:`.
    opts
    |> State.new()
    |> State.claim_agent()
    |> maybe_start_catalog()
    |> herdr_report()
    |> schedule_blink()
    |> then(&{:ok, &1})
  end

  defp maybe_start_catalog(%State{provider: {:ok, %Config{providers: [_head | _tail]}}} = state) do
    if state.live? or state.catalog_fetcher do
      start_catalog(state)
    else
      state
    end
  end

  defp maybe_start_catalog(%State{} = state), do: state

  defp start_catalog(%State{} = state) do
    opts = if state.catalog_fetcher, do: [fetch: state.catalog_fetcher], else: []
    {:ok, config} = state.provider
    _result = Catalog.refresh_async(config.providers, opts)
    state
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.render(state, frame)

  @impl ExRatatui.App
  def handle_event(%ExRatatui.Event.Key{kind: kind} = key, state)
      when kind in ["press", "repeat"] do
    {state, action} = State.handle_key(state, key.code, key.modifiers)

    case action do
      :quit -> {:stop, state}
      nil -> schedule(state)
      {:set_mode, mode} -> schedule(set_mode(mode, state))
      _setup_action -> setup_action(action, state)
    end
  end

  # kitty-protocol terminals also report key releases; ignore them.
  def handle_event(%ExRatatui.Event.Key{}, state), do: schedule(state)

  # The wheel always addresses the log view — never the input draft — so
  # scrolling works while typing (issue #21; ADR 0006 amendment). Mouse
  # capture is enabled at startup (Application), so terminals report real
  # wheel events instead of emulating arrow keys.
  def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_up"}, state),
    do: schedule(State.wheel_scroll(state, :up))

  def handle_event(%ExRatatui.Event.Mouse{kind: "scroll_down"}, state),
    do: schedule(State.wheel_scroll(state, :down))

  # Left-button selection over the log (issue #28; ADR 0006 amendment):
  # down anchors, drag extends, up copies via OSC 52 — one bounded write on
  # a user-paced release, live runs only. Shift+left is inert here: Shift
  # is the terminal's native-selection bypass, and the app must not
  # select/copy underneath it.
  def handle_event(
        %ExRatatui.Event.Mouse{kind: kind, button: "left", x: x, y: y, modifiers: mods},
        state
      )
      when kind in ["down", "drag", "up"] do
    {state, action} = State.select_mouse(state, kind, x, y, mods)
    write_clipboard(state, action)
    schedule(state)
  end

  # Every other mouse event (motion without a button, other buttons, stray
  # scroll axes) is inert and renders nothing: a pointer wandering over an
  # idle UI must not draw frames.
  def handle_event(%ExRatatui.Event.Mouse{}, state),
    do: {:noreply, state, %{render?: false}}

  # Confirmation mode swallows pastes too — nothing may reach the draft
  # mid-decision (ADR 0007).
  def handle_event(%ExRatatui.Event.Paste{}, %{confirm: pending} = state) when pending != nil,
    do: schedule(state)

  # The startup phase owns PASTE as well as keys (P1-2, hostile review): the
  # key step's own copy says "paste it", and a paste routed to the hidden
  # composer would leave the credential as pending chat text — then submit
  # it to the provider on the first post-setup Enter. Setup pastes feed the
  # wizard's draft; the forced-selection modal has no text step, so pastes
  # there are inert.
  def handle_event(%ExRatatui.Event.Paste{content: content}, %State{setup: setup} = state)
      when setup != nil,
      do: schedule(State.setup_paste(state, content))

  # The /title dialog (issue #106) takes pastes into its draft too — the
  # attach prompt's rule (ADR 0018 §5); the composer stays untouched.
  def handle_event(%ExRatatui.Event.Paste{content: content}, %State{title_dialog: %{}} = state),
    do: schedule(State.title_paste(state, content))

  # The attach prompt (ADR 0018 §5) takes pastes into its path draft too —
  # a pasted path is the supported shape; the composer stays untouched.
  def handle_event(%ExRatatui.Event.Paste{content: content}, %State{attach: %{}} = state),
    do: schedule(State.attach_paste(state, content))

  def handle_event(%ExRatatui.Event.Paste{content: content}, state),
    do: schedule(State.paste(state, content))

  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state),
    do: schedule(State.resize(state, w, h))

  # Focus events gate the composer's cursor artifact (ADR 0015 §1): an
  # unfocused pane shows no cursor, so a multiplexer glance shows which
  # pane holds focus. User-paced events — they may draw a frame, like keys.
  def handle_event(%ExRatatui.Event.FocusGained{}, state),
    do: schedule(%{state | focused?: true})

  def handle_event(%ExRatatui.Event.FocusLost{}, state),
    do: schedule(%{state | focused?: false})

  def handle_event(_event, state), do: schedule(state)

  # The startup phase's actions (ADR 0009) — the chat actions stay above.
  # One wizard keypress can carry several ordered actions (issue #64: an
  # accepted key writes, then its fetch fires); each runs on the state the
  # previous left. A refused write bounces the wizard with its error set
  # (issue #39): the actions behind it belong to the step the wizard just
  # left, so the list stops there.
  defp setup_action([], state), do: schedule(state)

  defp setup_action([action | rest], state) do
    state = run_action(action, state)

    if write_refused?(state), do: schedule(state), else: setup_action(rest, state)
  end

  defp setup_action(action, state), do: schedule(run_action(action, state))

  defp run_action({:submit, prompt, paths}, state), do: prompt_agent(prompt, paths, state)
  defp run_action({:confirm, decision}, state), do: confirm_decision(decision, state)
  defp run_action(:cancel, state), do: cancel_agent(state)
  defp run_action({:select_profile, name}, state), do: resolve_setup(state, name)
  defp run_action(:setup_finish, state), do: resolve_setup(state, nil)

  defp run_action({:write_key, {profile, base_url, value}}, state),
    do: write_wizard_key(state, profile, base_url, value)

  defp run_action({:fetch_models, {base_url, raw_key}}, state),
    do: fetch_wizard_models(state, base_url, raw_key)

  defp run_action({:write_settings, doc}, state),
    do: write_wizard_settings(state, doc)

  # The command surface's deliveries (ADR 0020). /title rides ADR 0023 §7's
  # rename seam — the agent owns normalization, uniqueness, and persistence
  # after the send.
  defp run_action({:set_title, title}, state) do
    send(state.agent, {:set_title, self(), title})
    state
  end

  # /compact (issue #92): a plain send — the agent runs ADR 0022's eviction
  # pass and owns every feedback entry; the command path is idle-gated like
  # submit.
  defp run_action(:compact, state) do
    send(state.agent, {:compact, self()})
    state
  end

  # /model's switch is a plain send and NOTHING else: the agent reads its
  # provider per episode, so the swap lands on the NEXT request; no local
  # change (State already swapped its provider copy) and no catalog restart
  # (same provider set — the sweep stays).
  defp run_action({:switch_model, classification}, state) do
    send(state.agent, {:set_provider, classification})
    state
  end

  # /profile's list: a fast local read of settings.json5; profiles_arrived
  # opens the picker or warns when there is nothing to list (ADR 0020).
  defp run_action(:list_profiles, state),
    do: State.profiles_arrived(state, Config.profile_names(state.config_dir))

  # /resume's list (issue #128): the /profile precedent — one fast local
  # read of the sessions store (a fail-open scan, never a write), the rows
  # landing through sessions_arrived. The heavier full load happens only on
  # the picked row's Enter.
  defp run_action(:list_sessions, %State{} = state) do
    State.sessions_arrived(
      state,
      Session.summaries(state.sessions_dir),
      System.system_time(:second)
    )
  end

  # The /resume picker's Enter (issue #128): one load, two consumers — the
  # boot's own rule (ADR 0014 §6). The agent adopts the loaded session
  # through the {:adopt_session, _} seam; the TUI replays the same load's
  # transcript with the boot's pin compare (Application.pin_note — the one
  # implementation of the mismatch warning, reused) riding as the resume
  # note. A load refusal lands as one system entry and the current session
  # is untouched — Enter merely failed; ESC-cancel's guarantee holds.
  defp run_action({:resume_session, id}, %State{} = state) do
    case Session.load(state.sessions_dir, id) do
      {:ok, session} ->
        send(state.agent, {:adopt_session, self(), session})

        State.session_adopted(
          state,
          session,
          DashFloat.Application.pin_note(session, state.provider)
        )

      {:error, message} ->
        State.session_refused(state, message)
    end
  end

  # The refusal detection the list-stop keys on: the bounce leaves the
  # wizard's error set (issue #39).
  defp write_refused?(%State{setup: %Onboarding{error: error}}) when error != nil, do: true
  defp write_refused?(%State{}), do: false

  @impl ExRatatui.App
  def handle_info(@tick, state) do
    if stale_tick?(state) do
      # A stale tick carries no state change, so it must not draw a frame
      # either — the 3-tuple return suppresses the post-message render the
      # Server would otherwise perform (idle never renders on a timer,
      # ADR 0006).
      {:noreply, state, %{render?: false}}
    else
      {ticked, verdict} = State.tick(state, System.monotonic_time(:millisecond))
      cleared = %{ticked | tick_ref: nil}

      case verdict do
        # A halting tick ends the animation with nothing new to draw.
        :cont -> schedule(cleared)
        :halt -> {:noreply, cleared, %{render?: false}}
      end
    end
  end

  # The idle cursor blink (issue #104; ADR 0006 amendment — sanctioned
  # exception #5): staleness first (the tick's exact rule), then toggle and
  # re-arm through the choke point — one frame per toggle, 2 frames/s at
  # the 500 ms cadence, and nothing while active (the tick animates the
  # active cursor) or in setup (no composer to blink over).
  def handle_info(@blink, state) do
    if stale_blink?(state) do
      {:noreply, state, %{render?: false}}
    else
      state
      |> State.blink()
      |> Map.put(:blink_ref, nil)
      |> schedule()
    end
  end

  # The exit-guard expiry (issue #28; ADR 0006 amendment — sanctioned
  # exception #3): a ONE-SHOT timer armed only by an explicit Ctrl+C. It
  # clears the transient prompt the moment the window dies — at most one
  # frame, never a loop; the idle discipline holds everywhere else.
  def handle_info(@exit_guard, state) do
    if stale_guard?(state) do
      {:noreply, state, %{render?: false}}
    else
      # The Herdr hook rides here too (ADR 0024): the prompt's expiry is a
      # blocked→idle transition this path returns without passing schedule/1.
      {:noreply, herdr_report(%{state | exit_guard_at: nil, exit_guard_ref: nil})}
    end
  end

  # The suggest debounce fired (ADR 0015 §3 — sanctioned exception #4):
  # staleness first, exactly like the tick's, then the one-shot dispatch —
  # render-suppressed, there is nothing to draw until a result lands.
  def handle_info(@suggest, state) do
    if stale_suggest?(state) do
      {:noreply, state, %{render?: false}}
    else
      {:noreply, dispatch_suggest(state), %{render?: false}}
    end
  end

  # A suggestion landed (ADR 0015 §3): the text arrives ALREADY normalized —
  # fetch_async/3 normalizes inside the supervised task, so the UI process
  # never touches the raw body. Accepted only while its epoch is current, the
  # UI is idle, the draft is empty, suggestions are on, and the ghost is
  # non-blank — "" is a truthy binary and would blank the composer's
  # placeholder. A stale epoch is dropped with the state UNTOUCHED — a newer
  # request may still be in flight, and clearing its task here would orphan
  # it.
  def handle_info({:suggestion, epoch, _text}, state) when epoch != state.suggest_epoch,
    do: {:noreply, state, %{render?: false}}

  def handle_info({:suggestion, epoch, text}, state) do
    # The visible-remainder test is the module's own normalize: it refuses
    # not just blank but INVISIBLE ghosts (soft hyphen, word joiner, bare
    # combining marks) — anything that would blank the placeholder or
    # materialize an unseen submit on Tab.
    if accept_suggestion?(state, epoch) and is_binary(text) and
         Suggest.normalize({:ok, text}) != nil do
      {:noreply, %{state | suggestion: text, suggest_task: nil}}
    else
      {:noreply, %{state | suggest_task: nil}, %{render?: false}}
    end
  end

  def handle_info({:entry, _kind, _text} = msg, state),
    do: schedule(State.stream_message(state, msg))

  def handle_info({kind, _payload} = msg, state)
      when kind in [
             :token,
             :phase,
             :usage,
             :context,
             :tool_call,
             :tool_result,
             :mode,
             :tool_preview,
             # The display-only title pushes (issue #106).
             :title,
             :title_refused
           ],
      do: schedule(State.stream_message(state, msg))

  def handle_info({:confirm, _ref, _payload} = msg, state),
    do: schedule(State.stream_message(state, msg))

  # A fresh session's id was minted at first save (ADR 0023/0024): the agent
  # is the single voice; the reporter re-reports with the resume command
  # attached once the id is known.
  def handle_info({:session_id, id}, state) when is_binary(id),
    do: schedule(%{state | session_id: id})

  # The standing catalog refresh landed (ADR 0009): in-memory merge, the
  # context denominator fills in, nothing else changes.
  def handle_info({:catalog, results}, state),
    do: schedule(State.catalog_arrived(state, results))

  # The wizard's /models fetch landed (ADR 0009): feeds the picker; any
  # failure already degraded to manual entry by the fetch's fail-open.
  def handle_info({:wizard_models, result}, state),
    do: schedule(State.models_arrived(state, result))

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {state, _verdict} = State.agent_down(state, ref, reason)
    schedule(state)
  end

  def handle_info(_msg, state), do: schedule(state)

  # A tick is stale when no timer of ours is pending (a timer cancelled after
  # its message was already queued) or when the tracked timer has not fired yet
  # (a message left over from an earlier timer). Dropping it keeps the invariant
  # at exactly one pending timer and keeps a stale tick from affecting state at
  # idle (ADR 0006); the render-suppressing return keeps it from drawing too.
  defp stale_tick?(%{tick_ref: nil}), do: true
  defp stale_tick?(%{tick_ref: ref}), do: Process.read_timer(ref) != false

  # Same staleness rule for the exit-guard timer: a message from a cancelled
  # or superseded window's timer must not clear a live one.
  defp stale_guard?(%{exit_guard_ref: nil}), do: true

  defp stale_guard?(%{exit_guard_ref: ref}), do: Process.read_timer(ref) != false

  # Same staleness rule for the suggest debounce (ADR 0015 §3): a message
  # from a cancelled or superseded timer must be inert.
  defp stale_suggest?(%{suggest_ref: nil}), do: true
  defp stale_suggest?(%{suggest_ref: ref}), do: Process.read_timer(ref) != false

  # Same staleness rule for the blink timer (issue #104): no tracked
  # timer, or one still pending, means the message is an orphan from a
  # cancelled or superseded arm — dropped without a frame.
  defp stale_blink?(%{blink_ref: nil}), do: true

  defp stale_blink?(%{blink_ref: ref}), do: Process.read_timer(ref) != false

  # The debounce fired for real: clear the ref, then resolve the model
  # config and start the supervised side-request on the reply tail.
  defp dispatch_suggest(state) do
    case state.provider do
      {:ok, %Config{suggest: false}} -> %{state | suggest_ref: nil}
      {:ok, config} -> start_suggest(state, config)
      _other -> %{state | suggest_ref: nil}
    end
  end

  defp start_suggest(state, config) do
    epoch = state.suggest_epoch + 1

    # A dead task supervisor EXITS the start call instead of returning an
    # error tuple — caught here, because the side-request is fail-open
    # absolutely (ADR 0015 §3): a missing ghost, never a UI crash.
    result =
      try do
        Suggest.fetch_async(config, Suggest.tail(state.entries),
          send_to: self(),
          epoch: epoch,
          fetcher: state.suggest_fetcher
        )
      catch
        :exit, _reason -> :error
      end

    case result do
      {:ok, pid} -> %{state | suggest_ref: nil, suggest_task: pid, suggest_epoch: epoch}
      _no_task -> %{state | suggest_ref: nil}
    end
  end

  defp accept_suggestion?(state, epoch) do
    epoch == state.suggest_epoch and state.phase == :idle and
      State.input_text(state) == "" and
      match?({:ok, %Config{suggest: suggest}} when suggest != false, state.provider)
  end

  # The single tick choke point (ADR 0006): any active phase keeps exactly one
  # timer pending; idle always cancels it — and, since issue #104, keeps
  # exactly one blink timer pending instead (bounded, never both). The
  # sanctioned one-shot exceptions: the user-armed exit guard (issue #28)
  # and the suggest debounce (sanctioned exception #4, ADR 0015 §3).
  defp schedule(state) do
    state =
      state
      |> schedule_tick()
      |> schedule_blink()
      |> schedule_guard(System.monotonic_time(:millisecond))
      |> suggest_reap()
      |> suggest_arm()
      |> herdr_report()

    {:noreply, state}
  end

  # The Herdr reporter's choke point (ADR 0024): every event return threads
  # through schedule/1, so one change-detected report here covers phase
  # flips, confirm arms/clears, exit-guard arming, setup completion, and
  # provider switches. nil context — outside Herdr — is the cheap no-op.
  defp herdr_report(%State{herdr: nil} = state), do: state

  defp herdr_report(%State{} = state) do
    {profile, model} =
      case state.provider do
        {:ok, %Config{profile: p, model: m}} -> {p, m}
        _unresolved -> {nil, nil}
      end

    shot = %{
      phase: state.phase,
      confirm: if(state.confirm, do: state.confirm.name),
      exit_prompt: state.exit_guard_at != nil,
      setup: state.setup != nil,
      session_id: state.session_id,
      profile: profile,
      model: model
    }

    %{state | herdr: Herdr.report(state.herdr, shot)}
  end

  defp schedule_tick(state) do
    cond do
      State.needs_tick?(state) ->
        %{state | tick_ref: Process.send_after(self(), @tick, @tick_ms)}

      state.phase == :idle and state.tick_ref != nil ->
        Process.cancel_timer(state.tick_ref)
        %{state | tick_ref: nil}

      true ->
        state
    end
  end

  # The idle blink's arm (issue #104; ADR 0006 amendment — sanctioned
  # exception #5): exactly one pending timer while the chat UI is idle —
  # cancelled on every exit from idle (the active cursor rides the tick),
  # re-armed on every return, the phase reset visible so the first idle
  # frame always draws the cursor. Arming is live-only by default: the
  # hermetic suite never arms one (the suggest-arm pattern); an injected
  # `blink_ms:` opts a test in at its own cadence. A fired-but-undrained
  # timer is left alone — its message drains through the staleness check.
  defp schedule_blink(%{blink_ref: nil} = state) do
    if blinkable?(state), do: arm_blink(state), else: reset_blink(state)
  end

  defp schedule_blink(%{blink_ref: ref} = state) when is_reference(ref) do
    if blinkable?(state) do
      # Pending or fired-but-not-yet-drained: either way the tracked arm
      # owns the next toggle (a fired one's message drains through the
      # staleness check) — leave it exactly as it is.
      state
    else
      Process.cancel_timer(ref)
      reset_blink(%{state | blink_ref: nil})
    end
  end

  defp blinkable?(%{live?: false, blink_ms: nil}), do: false

  defp blinkable?(%{setup: nil, phase: :idle}), do: true

  defp blinkable?(_state), do: false

  defp arm_blink(%{blink_ms: ms} = state),
    do: %{state | blink_ref: Process.send_after(self(), @blink, ms || @blink_ms)}

  defp reset_blink(%{blink_on: true} = state), do: state

  defp reset_blink(state), do: %{state | blink_on: true}

  # Exactly one expiry timer per armed window: disarm cancels a pending
  # timer, arming schedules one when none is live, a fired-but-undrained
  # timer (its message still queued) is replaced — the staleness check in
  # handle_info drops the orphaned message — and a live timer is left
  # alone, so incidental events never disturb a pending expiry.
  defp schedule_guard(state, now) do
    cond do
      state.exit_guard_at == nil ->
        if state.exit_guard_ref != nil, do: Process.cancel_timer(state.exit_guard_ref)
        %{state | exit_guard_ref: nil}

      state.exit_guard_ref == nil ->
        arm_guard(state, now)

      Process.read_timer(state.exit_guard_ref) == false ->
        arm_guard(state, now)

      true ->
        state
    end
  end

  defp arm_guard(state, now) do
    delay = State.exit_guard_delay(state, now)
    %{state | exit_guard_ref: Process.send_after(self(), @exit_guard, delay)}
  end

  # The suggest reap (ADR 0015 §3): a dismiss intent cancels the pending
  # debounce and kills an in-flight task (the socket dies mid-request); the
  # epoch bump orphans any already-queued straggler result. One choke point,
  # like the tick's.
  defp suggest_reap(%{suggest_reap: false} = state), do: state

  defp suggest_reap(state) do
    if is_reference(state.suggest_ref), do: Process.cancel_timer(state.suggest_ref)
    if is_pid(state.suggest_task), do: Process.exit(state.suggest_task, :kill)

    %{
      state
      | suggest_reap: false,
        suggest_ref: nil,
        suggest_task: nil,
        suggest_epoch: state.suggest_epoch + 1
    }
  end

  # The suggest arm (ADR 0015 §3 — sanctioned timer #4): the one-shot
  # debounce send, turn-paced and render-suppressed at dispatch. Live runs
  # use the real HTTP path; tests inject `suggest_fetcher:` (the
  # catalog_fetcher pattern) — the default suite stays hermetic: no
  # fetcher, no timer, no network.
  defp suggest_arm(%{suggest_arm: false} = state), do: state

  defp suggest_arm(state) do
    if state.live? or state.suggest_fetcher do
      # No orphan-kill at the arm: a pending debounce/task was already reaped
      # by suggest_reap/1 earlier in this pipeline; the ordering is the
      # guarantee.
      arm_suggest_debounce(state)
    else
      %{state | suggest_arm: false}
    end
  end

  defp arm_suggest_debounce(state) do
    %{
      state
      | suggest_arm: false,
        suggest_ref: Process.send_after(self(), @suggest, state.suggest_debounce_ms)
    }
  end

  @impl ExRatatui.App
  def terminate(reason, state) do
    # Standalone runs (`mix run --no-halt`, release binary) exit the VM when
    # the TUI quits so the shell prompt comes back. Only an explicit quit is a
    # success — a supervisor-driven or failing shutdown reports 1 (ADR 0002).
    # Test-mode instances own no real terminal and must not stop the test VM.
    # The Herdr release is the one synchronous report (ADR 0024 §6): every
    # deliberate exit funnels here, and the release must land before the VM
    # stops — Herdr's idle-prompt self-clear is only the safety net.
    _released = Herdr.release(state.herdr)
    code = exit_code(reason)

    # The exit print (issue #127): a CLEAN deliberate exit — every one of
    # them funnels here (Ctrl+Q, the confirmed double Ctrl+C, /quit, the
    # palette's quit) — names the command that reopens the session. The
    # terminal is already restored by the time this callback runs (the
    # server's teardown leaves the alt screen first), so the bytes land on
    # the normal screen, after the release, before the VM stops.
    write_exit_message(code, state)

    if state.live?, do: System.stop(code)

    :ok
  end

  defp write_exit_message(0, %State{} = state) do
    case exit_message(state) do
      nil -> :ok
      message -> IO.binwrite(:stdio, message)
    end
  end

  defp write_exit_message(_crash, _state), do: :ok

  @doc """
  The command that reopens this session (issue #127), or nil when there is
  nothing persisted to reopen: a lead-in line plus `dashfloat --resume`
  with the session's stored TITLE when the file carries one (double-quoted
  and shell-escaped so a multi-word title pastes verbatim) and its UUIDv7
  id otherwise — the id path needs no quoting. The gate is the store
  itself, read once at exit: the session file must exist and decode, and
  the title comes from ITS bytes — the exact truth the next boot's
  resolution reads — never from live state, so a title whose save failed
  (ADR 0023 §5's accepted fail-open) prints the id form instead of a
  command that would refuse. A session that never persisted
  (launch-and-quit) or whose file is unreadable prints nothing.
  """
  @spec exit_message(State.t()) :: String.t() | nil
  def exit_message(%State{session_id: id, sessions_dir: dir})
      when is_binary(id) and is_binary(dir) do
    path = Path.join(dir, id <> ".json")

    case stored_title(path) do
      :none -> nil
      {:title, title} -> "resume this session with:\ndashfloat --resume " <> quoted(title) <> "\n"
      :untitled -> "resume this session with:\ndashfloat --resume #{id}\n"
    end
  end

  def exit_message(%State{}), do: nil

  # The stored title, or :untitled when the file carries none — the
  # `--resume` title path's own truth — and :none when nothing safely
  # resumable exists (no file, unreadable, or not session-shaped JSON).
  defp stored_title(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      case Map.get(decoded, "title") do
        title when is_binary(title) and title != "" -> {:title, title}
        _no_title -> :untitled
      end
    else
      _unreadable -> :none
    end
  end

  # The title form is the human-shaped handle; the id always resolves. A
  # quoted title keeps multi-word names a single argv word — `"` `\` `$` and
  # backtick escaped, the four characters POSIX double quotes treat as
  # special — so the printed line pastes verbatim into any POSIX shell.
  # An on-disk duplicate title (the ADR 0023 §4 race) refuses loudly at the
  # next boot with both ids named — the accepted posture, never silent.
  defp quoted(title),
    do: "\"" <> String.replace(title, ["\"", "\\", "$", "`"], &("\\" <> &1)) <> "\""

  @doc """
  Exit status for a standalone run: `0` only for a user quit (`:normal`),
  `1` for anything else — supervisor shutdowns, crashes, failures.
  """
  @spec exit_code(term()) :: 0 | 1
  def exit_code(:normal), do: 0
  def exit_code(_reason), do: 1

  # The agent seam (ADR 0007): plain sends, both directions — fake agents in
  # tests are plain processes receiving these. `paths` carries the pending
  # attachments (ADR 0018 §6); the agent owns the bytes.
  defp prompt_agent(prompt, paths, state) do
    send(state.agent, {:prompt, self(), prompt, paths})
    state
  end

  # The mode switch (ADR 0016 §7) rides the same seam: a plain send, no local
  # change — the agent's {:mode, _} echo updates the chrome.
  defp set_mode(mode, state) do
    send(state.agent, {:set_mode, self(), mode})
    state
  end

  # Sanctioned one-write exception (ADR 0006 amendment, issue #28): a
  # bounded OSC 52 sequence on a user-paced release. IO.binwrite completes
  # before the post-event frame draws, so bytes never interleave mid-frame;
  # terminals without OSC 52 ignore it silently. Never in test mode. An
  # over-cap selection drops with a log line — the highlight stays, the
  # clipboard write does not happen.
  defp write_clipboard(%State{live?: true}, {:copy, text}) do
    IO.binwrite(:standard_io, Selection.osc52(text))
  end

  defp write_clipboard(_state, {:copy_too_large, bytes}) do
    Logger.warning(
      "selection copy dropped: #{bytes} bytes exceeds the clipboard cap — the selection stays highlighted"
    )
  end

  defp write_clipboard(_state, _no_copy), do: :ok

  # A cancelled stream; the seam contract is plain sends both directions.
  defp cancel_agent(state) do
    send(state.agent, {:cancel})
    state
  end

  ## The startup phase's side effects (ADR 0009 — the sanctioned exception
  ## to "the UI performs no file I/O", scoped exactly to setup): the wizard's
  ## writes and fetches run through the config layer's atomic machinery and
  ## the supervised task pool, never inline rendering paths.

  # A profile was chosen (modal) or the wizard finished: re-load through the
  # Application's resolver and deliver the outcome to the agent and the
  # catalog refresh.
  defp resolve_setup(%State{} = state, name) do
    case state.resolve do
      nil ->
        {cleared, _action} = State.provider_resolved(state, {:error, "no provider configured"})
        cleared

      resolve ->
        # P2-3 (hostile review): the handoff normalizes at the boundary —
        # the agent's provider is ALWAYS {:ok, _} | {:error, msg}. A raw
        # :onboard / {:select, _} classification (a failed settings write
        # leaving zero profiles, say) used to reach the agent's case and
        # crash it on the first prompt; now it becomes a human-readable
        # error the agent DISPLAYS.
        provider = for_agent(safe_resolve(resolve, name))
        {resolved, {:agent_provider, provider}} = State.provider_resolved(state, provider)

        send(state.agent, {:set_provider, provider})
        restart_catalog(resolved, provider)
    end
  end

  defp for_agent({:ok, _config} = ok), do: ok
  defp for_agent({:error, _message} = error), do: error

  defp for_agent(:onboard),
    do: {:error, "first-run setup is incomplete — finish the wizard, or configure by hand"}

  defp for_agent({:select, names}),
    do: {:error, "no profile selected — choose one of: " <> Enum.join(names, ", ")}

  # A resolved working config restarts the standing catalog refresh under
  # the new provider set (ADR 0009).
  defp restart_catalog(%State{} = resolved, {:ok, %Config{providers: [_head | _tail]}}),
    do: maybe_start_catalog(resolved)

  defp restart_catalog(%State{} = resolved, _classification), do: resolved

  # The resolver reads files and runs migrations; its failure mode is the
  # classification's own error arm, never a crash in the UI process.
  defp safe_resolve(resolve, name) do
    resolve.(name)
  rescue
    _reason -> {:error, "config could not be loaded"}
  end

  defp write_wizard_key(%State{} = state, profile, base_url, value) do
    case Config.write_keys_entry(state.config_dir, profile, base_url, value) do
      :ok ->
        state

      {:error, message} ->
        Logger.warning(message)
        State.setup_write_failed(state, message)
    end
  end

  defp write_wizard_settings(%State{} = state, document) do
    case Config.write_settings(state.config_dir, document) do
      :ok ->
        state

      {:error, message} ->
        Logger.warning(message)
        State.setup_write_failed(state, message)
    end
  end

  # The wizard's /models fetch: a supervised task so a 5 s timeout never
  # blocks the UI; the result lands as `{:wizard_models, _}`. A `$ENV_VAR`
  # key resolves here — the wizard stores references verbatim.
  defp fetch_wizard_models(%State{} = state, base_url, raw_key) do
    parent = self()
    key = resolve_wizard_key(raw_key)

    Task.Supervisor.start_child(DashFloat.TaskSupervisor, fn ->
      send(parent, {:wizard_models, Catalog.fetch(base_url, key)})
    end)

    state
  end

  defp resolve_wizard_key("$" <> var) when byte_size(var) > 0, do: System.get_env(var)
  defp resolve_wizard_key(literal) when is_binary(literal), do: literal

  defp confirm_decision(decision, %{confirm: %{ref: ref}} = state) do
    send(state.agent, {:confirm_decision, ref, decision})
    State.confirm_decided(state)
  end
end

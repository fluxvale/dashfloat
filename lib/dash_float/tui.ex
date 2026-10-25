defmodule DashFloat.TUI do
  @moduledoc """
  The DashFloat terminal UI: a thin `ExRatatui.App` whose state logic lives in
  `DashFloat.TUI.State` and rendering in `DashFloat.TUI.View`. Process shape,
  key bindings, and teardown guarantees are settled in ADR 0002. Submits,
  cancels, and confirmation decisions are plain sends to the agent (ADR 0007)
  — the agent is the single voice streaming back into the UI, and this
  process starts no tasks. The activity tick (ADR 0006) is the one timer this
  process owns — scheduled only while work is in flight.

  Run with `mix run --no-halt`. Quit with Ctrl+Q, or a double Ctrl+C: the
  first press shows a prompt, the second within two seconds exits
  (issue #28; ADR 0006 amendment).
  """

  # No `use ExRatatui.App`: it injects a :transient child_spec that would
  # shadow ours. A crashed UI must exit the application instead of bouncing
  # back blank (ADR 0002). The behaviour form is documented as equivalent.
  @behaviour ExRatatui.App

  alias DashFloat.TUI.Selection
  alias DashFloat.TUI.State
  alias DashFloat.TUI.View

  require Logger

  @tick :dashfloat_tick
  @tick_ms 125
  @exit_guard :dashfloat_exit_guard

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
    |> Keyword.put(:mod, __MODULE__)
    |> ExRatatui.App.dispatch_start()
  end

  @impl ExRatatui.App
  def mount(opts) do
    # The agent monitor lives in this process, not State.new/1 — State stays
    # free of side effects (ADR 0007).
    state = State.new(opts)
    {:ok, State.claim_agent(state)}
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.render(state, frame)

  @impl ExRatatui.App
  def handle_event(%ExRatatui.Event.Key{kind: kind} = key, state)
      when kind in ["press", "repeat"] do
    {state, action} = State.handle_key(state, key.code, key.modifiers)

    case action do
      :quit -> {:stop, state}
      {:submit, prompt} -> schedule(prompt_agent(prompt, state))
      {:confirm, decision} -> schedule(confirm_decision(decision, state))
      :cancel -> schedule(cancel_agent(state))
      nil -> schedule(state)
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

  def handle_event(%ExRatatui.Event.Paste{content: content}, state),
    do: schedule(State.paste(state, content))

  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state),
    do: schedule(State.resize(state, w, h))

  def handle_event(_event, state), do: schedule(state)

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

  # The exit-guard expiry (issue #28; ADR 0006 amendment — sanctioned
  # exception #3): a ONE-SHOT timer armed only by an explicit Ctrl+C. It
  # clears the transient prompt the moment the window dies — at most one
  # frame, never a loop; the idle discipline holds everywhere else.
  def handle_info(@exit_guard, state) do
    if stale_guard?(state) do
      {:noreply, state, %{render?: false}}
    else
      {:noreply, %{state | exit_guard_at: nil, exit_guard_ref: nil}}
    end
  end

  def handle_info({:entry, _kind, _text} = msg, state),
    do: schedule(State.stream_message(state, msg))

  def handle_info({kind, _payload} = msg, state)
      when kind in [:token, :phase, :usage, :tool_call, :tool_result],
      do: schedule(State.stream_message(state, msg))

  def handle_info({:confirm, _ref, _payload} = msg, state),
    do: schedule(State.stream_message(state, msg))

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

  # The single tick choke point (ADR 0006): any active phase keeps exactly one
  # timer pending; idle always cancels it. Idle => no timers => no renders
  # (the exit guard's one-shot is the sole, user-armed exception).
  defp schedule(state) do
    state =
      state
      |> schedule_tick()
      |> schedule_guard(System.monotonic_time(:millisecond))

    {:noreply, state}
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

  @impl ExRatatui.App
  def terminate(reason, state) do
    # Standalone runs (`mix run --no-halt`, future burrito binary) exit the VM
    # when the TUI quits so the shell prompt comes back. Only an explicit quit
    # is a success — a supervisor-driven or failing shutdown reports 1 (ADR
    # 0002). Test-mode instances own no real terminal and must not stop the
    # test VM.
    code = exit_code(reason)
    if state.live?, do: System.stop(code)

    :ok
  end

  @doc """
  Exit status for a standalone run: `0` only for a user quit (`:normal`),
  `1` for anything else — supervisor shutdowns, crashes, failures.
  """
  @spec exit_code(term()) :: 0 | 1
  def exit_code(:normal), do: 0
  def exit_code(_reason), do: 1

  # The agent seam (ADR 0007): plain sends, both directions — fake agents in
  # tests are plain processes receiving these.
  defp prompt_agent(prompt, state) do
    send(state.agent, {:prompt, self(), prompt})
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

  defp cancel_agent(state) do
    send(state.agent, {:cancel})
    state
  end

  defp confirm_decision(decision, %{confirm: %{ref: ref}} = state) do
    send(state.agent, {:confirm_decision, ref, decision})
    State.confirm_decided(state)
  end
end

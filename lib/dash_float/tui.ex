defmodule DashFloat.TUI do
  @moduledoc """
  The DashFloat terminal UI: a thin `ExRatatui.App` whose state logic lives in
  `DashFloat.TUI.State` and rendering in `DashFloat.TUI.View`. Process shape,
  key bindings, and teardown guarantees are settled in ADR 0002; the producer
  started on submit is the SSE adapter from ADR 0005. The activity tick
  (ADR 0006) is the one timer this process owns — scheduled only while work is
  in flight.

  Run with `mix run --no-halt`. Quit with Ctrl+Q or Ctrl+C.
  """

  # No `use ExRatatui.App`: it injects a :transient child_spec that would
  # shadow ours. A crashed UI must exit the application instead of bouncing
  # back blank (ADR 0002). The behaviour form is documented as equivalent.
  @behaviour ExRatatui.App

  alias DashFloat.LLM.ChatStream
  alias DashFloat.TUI.State
  alias DashFloat.TUI.View

  @tick :dashfloat_tick
  @tick_ms 125

  @no_provider "[llm: no provider configured — set base_url/model/api_key in " <>
                 "~/.config/dashfloat/config.json or " <>
                 "DASHFLOAT_BASE_URL/DASHFLOAT_MODEL/DASHFLOAT_API_KEY]"

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
    |> Keyword.put(:mod, __MODULE__)
    |> ExRatatui.App.dispatch_start()
  end

  @impl ExRatatui.App
  def mount(opts) do
    {:ok, State.new(opts)}
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.render(state, frame)

  @impl ExRatatui.App
  def handle_event(%ExRatatui.Event.Key{kind: kind} = key, state)
      when kind in ["press", "repeat"] do
    {state, action} = State.handle_key(state, key.code, key.modifiers)

    case action do
      :quit -> {:stop, state}
      {:submit, prompt} -> schedule(start_stream(prompt, state))
      :cancel -> schedule(cancel_stream(state))
      nil -> schedule(state)
    end
  end

  # kitty-protocol terminals also report key releases; ignore them.
  def handle_event(%ExRatatui.Event.Key{}, state), do: schedule(state)

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

  def handle_info({:entry, _kind, _text} = msg, state),
    do: schedule(State.stream_message(state, msg))

  def handle_info({kind, _payload} = msg, state) when kind in [:token, :phase, :usage],
    do: schedule(State.stream_message(state, msg))

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {state, _verdict} = State.task_down(state, ref, reason)
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

  # The single tick choke point (ADR 0006): any active phase keeps exactly one
  # timer pending; idle always cancels it. Idle => no timers => no renders.
  defp schedule(state) do
    state =
      cond do
        State.needs_tick?(state) ->
          %{state | tick_ref: Process.send_after(self(), @tick, @tick_ms)}

        state.phase == :idle and state.tick_ref != nil ->
          Process.cancel_timer(state.tick_ref)
          %{state | tick_ref: nil}

        true ->
          state
      end

    {:noreply, state}
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

  defp start_stream(prompt, %{provider: {:ok, provider}} = state) do
    ui = self()

    case Task.Supervisor.start_child(
           DashFloat.StreamSupervisor,
           fn -> ChatStream.run(ui, provider, prompt) end,
           restart: :temporary
         ) do
      {:ok, pid} -> State.claim_task(state, pid, Process.monitor(pid))
      {:error, reason} -> State.stream_failed(state, reason)
    end
  end

  # Spec-mandated: both "no config at all" and "config unreadable" degrade to
  # the setup instructions; the Config error text is deliberately not surfaced
  # (values are never echoed either way).
  defp start_stream(_prompt, state), do: State.stream_failed(state, @no_provider)

  defp cancel_stream(state) do
    if is_pid(state.task_pid), do: send(state.task_pid, :cancel)
    state
  end
end

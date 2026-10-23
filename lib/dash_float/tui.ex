defmodule DashFloat.TUI do
  @moduledoc """
  The DashFloat terminal UI: a thin `ExRatatui.App` whose state logic lives in
  `DashFloat.TUI.State` and rendering in `DashFloat.TUI.View`. Process shape,
  key bindings, and teardown guarantees are settled in ADR 0002; the producer
  started on submit is the SSE adapter from ADR 0004.

  Run with `mix run --no-halt`. Quit with Ctrl+Q or Ctrl+C.
  """

  # No `use ExRatatui.App`: it injects a :transient child_spec that would
  # shadow ours. A crashed UI must exit the application instead of bouncing
  # back blank (ADR 0002). The behaviour form is documented as equivalent.
  @behaviour ExRatatui.App

  alias DashFloat.LLM.ChatStream
  alias DashFloat.TUI.{State, View}

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
      {:submit, prompt} -> {:noreply, start_stream(prompt, state)}
      :cancel -> {:noreply, cancel_stream(state)}
      nil -> {:noreply, state}
    end
  end

  # kitty-protocol terminals also report key releases; ignore them.
  def handle_event(%ExRatatui.Event.Key{}, state), do: {:noreply, state}

  def handle_event(%ExRatatui.Event.Paste{content: content}, state),
    do: {:noreply, State.paste(state, content)}

  def handle_event(%ExRatatui.Event.Resize{width: w, height: h}, state),
    do: {:noreply, State.resize(state, w, h)}

  def handle_event(_event, state), do: {:noreply, state}

  @impl ExRatatui.App
  def handle_info({:entry, _kind, _text} = msg, state),
    do: {:noreply, State.stream_message(state, msg)}

  def handle_info({kind, _payload} = msg, state) when kind in [:token, :phase],
    do: {:noreply, State.stream_message(state, msg)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {state, _verdict} = State.task_down(state, ref, reason)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

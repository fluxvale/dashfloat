defmodule DashFloat.TUITest do
  @moduledoc """
  App-level tests under `test_mode`: supervised lifecycle, teardown paths
  (including crashes), the real streaming producer, and the responsiveness
  proof. Not async: they measure timing, share telemetry handlers, and open
  real loopback sockets.
  """

  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.SSEServer
  alias DashFloat.TUI
  alias DashFloat.TUI.State
  alias DashFloat.TUI.View
  alias ExRatatui.Runtime

  @opts [test_mode: {80, 24}, name: nil]

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  defp start_tui(opts \\ []) do
    opts = Keyword.merge(@opts, opts)

    # A real supervisor, mirroring the Application wiring (restart: :temporary).
    {:ok, sup} =
      Supervisor.start_link(
        [%{id: TUI, start: {TUI, :start_link, [opts]}, type: :worker, restart: :temporary}],
        strategy: :one_for_one
      )

    # Unlink: the supervisor must outlive the test process so on_exit can
    # stop it (and the TUI) deterministically.
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    # A torn-down TUI can leave its producer running for a few ms; later tests
    # assert on the app-wide supervisor's children, so drain before they run.
    on_exit(fn -> await_no_tasks(200) end)

    [{TUI, pid, :worker, _modules}] = Supervisor.which_children(sup)
    {:ok, pid}
  end

  defp await_no_tasks(tries) do
    cond do
      Task.Supervisor.children(DashFloat.StreamSupervisor) == [] -> :ok
      tries > 0 -> Process.sleep(10) && await_no_tasks(tries - 1)
      true -> :ok
    end
  end

  defp provider(base_url) do
    {:ok, %Config{base_url: base_url, model: "test-model", api_key: "test-key-123"}}
  end

  defp start_server(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  defp press(pid, code, modifiers \\ []) do
    Runtime.inject_event(pid, %ExRatatui.Event.Key{
      code: code,
      modifiers: modifiers,
      kind: "press"
    })
  end

  defp type(pid, text) do
    text
    |> String.codepoints()
    |> Enum.each(&press(pid, &1))
  end

  defp submit(pid, text) do
    type(pid, text)
    press(pid, "enter")
  end

  # The runtime's own state carries our user_state; no test backdoor needed.
  defp get_state(pid) do
    runtime_state = :sys.get_state(pid)
    Map.get(runtime_state, :user_state)
  end

  defp eventually(pid, fun, tries \\ 200) do
    state = get_state(pid)

    if fun.(state) do
      state
    else
      true = tries > 0
      Process.sleep(15)
      eventually(pid, fun, tries - 1)
    end
  end

  defp system_entries(state), do: for({:system, text} <- state.entries, do: text)

  test "supervised start renders, typed input accumulates, and a real stream lands" do
    server =
      start_server([
        {:send, [@headers, frame("Hello")]},
        {:sleep, 200},
        {:send, frame(" from the engine")},
        {:sleep, 200},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))
    assert Runtime.snapshot(pid).render_count >= 1

    type(pid, "hello tui")
    typed = get_state(pid)
    assert State.input_text(typed) == "hello tui"

    press(pid, "enter")

    # Mid-stream: the reply grows in flight (one token per frame) and is not
    # finalized until the idle phase.
    streaming = eventually(pid, fn s -> s.in_flight == "Hello" end)
    assert streaming.phase == :streaming
    assert {:user, "hello tui"} in streaming.entries

    grown = eventually(pid, fn s -> s.in_flight == "Hello from the engine" end)
    assert grown.phase == :streaming

    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    assert {:assistant, "Hello from the engine"} in state.entries
    assert state.history == ["hello tui"]
    assert system_entries(state) == []
    assert state.task_ref == nil

    # The status bar names the configured model (ADR 0005).
    assert State.provider_model(state) == "test-model"
    assert status_text(state) =~ "model: test-model"
  end

  test "Esc cancels mid-stream: partial reply kept, [cancelled] logged, input usable" do
    server =
      start_server([
        {:send, [@headers, frame("partial")]},
        {:sleep, 1_000},
        {:send, frame(" late")},
        {:sleep, 100},
        {:wait_close, 3_000}
      ])

    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))
    submit(pid, "cancel me")

    eventually(pid, fn s -> s.in_flight == "partial" end)
    press(pid, "esc")

    state =
      eventually(pid, fn s ->
        s.phase == :idle and "[cancelled]" in system_entries(s)
      end)

    assert {:assistant, "partial"} in state.entries
    refute Enum.any?(state.entries, fn {_kind, text} -> text =~ "late" end)

    # Input is usable again.
    submit(pid, "again")
    eventually(pid, fn s -> s.phase == :streaming and State.input_text(s) == "" end)
  end

  test "a mid-stream server disconnect degrades to idle with an explanation" do
    server = start_server([{:send, [@headers, frame("partial")]}, :close])
    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))

    submit(pid, "drop")

    state =
      eventually(pid, fn s ->
        s.phase == :idle and
          "[llm: stream ended without completion]" in system_entries(s)
      end)

    assert {:assistant, "partial"} in state.entries

    # Still typeable.
    type(pid, "next")
    typed_again = get_state(pid)
    assert State.input_text(typed_again) == "next"
  end

  test "without a provider, submit degrades to setup instructions and stays usable" do
    {:ok, pid} = start_tui()
    submit(pid, "hello")

    state =
      eventually(pid, fn s ->
        entries = system_entries(s)

        s.phase == :idle and
          Enum.any?(entries, &String.contains?(&1, "[llm: no provider configured"))
      end)

    assert {:user, "hello"} in state.entries
    assert State.provider_model(state) == nil
    assert status_text(state) =~ "model: —"

    type(pid, "again")
    typed_again = get_state(pid)
    assert State.input_text(typed_again) == "again"
  end

  test "quit keys stop the supervised app with reason :normal" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)
    press(pid, "q", ["ctrl"])

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_receive {:transport_disconnect, :normal}, 1_000
  end

  @tag :capture_log
  test "a crashing message tears the app down through the terminal-restore path" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)

    # {:phase, :bogus} violates the stream contract; State.stream_message/2 has
    # no clause for it, so the callback raises like any real bug would.
    bogus = :bogus
    send(pid, {:phase, bogus})

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason != :normal

    # The disconnect telemetry fires from ExRatatui.Server.terminate/2 — the
    # same path that restores the terminal and reattaches the BEAM reader.
    assert_receive {:transport_disconnect, _crash_reason}, 1_000
  end

  test "history is reachable through real key events" do
    {:ok, pid} = start_tui()
    submit(pid, "first")
    eventually(pid, &(&1.phase == :idle))
    submit(pid, "second")
    eventually(pid, &(&1.phase == :idle))

    press(pid, "up")
    latest = get_state(pid)
    assert State.input_text(latest) == "second"
    press(pid, "up")
    oldest = get_state(pid)
    assert State.input_text(oldest) == "first"
    press(pid, "down")
    press(pid, "down")
    restored = get_state(pid)
    assert State.input_text(restored) == ""
  end

  @tag :capture_log
  test "a dead producer degrades to idle instead of bricking input" do
    server =
      start_server([
        {:send, [@headers, frame("slow")]},
        {:sleep, 1_000},
        {:send, frame(" later")},
        {:sleep, 100},
        {:wait_close, 3_000}
      ])

    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))
    submit(pid, "hello")

    eventually(pid, fn s -> s.in_flight == "slow" end)
    [task] = Task.Supervisor.children(DashFloat.StreamSupervisor)
    Process.exit(task, :kill)

    state =
      eventually(pid, fn s ->
        entries = system_entries(s)
        s.phase == :idle and Enum.any?(entries, &String.contains?(&1, "stream failed"))
      end)

    assert state.task_ref == nil
    assert state.task_pid == nil
    assert {:user, "hello"} in state.entries

    # Input is usable again: submit works (the server replays its script).
    submit(pid, "again")
    eventually(pid, fn s -> s.phase == :streaming and State.input_text(s) == "" end)
  end

  @tag :capture_log
  test "a fast completed stream never logs spurious stream failures (noproc race)" do
    server = start_server([{:send, [@headers, "data: [DONE]\n\n"]}, :close])
    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))

    Enum.each(1..3, fn i ->
      submit(pid, "q#{i}")
      eventually(pid, fn s -> s.phase == :idle and s.task_ref == nil end)
    end)

    state = get_state(pid)
    assert state.task_ref == nil

    refute Enum.any?(state.entries, fn {kind, text} ->
             kind == :system and String.contains?(text, "stream failed")
           end)
  end

  @tag :capture_log
  test "the UI stays responsive while a stream lands at cadence into a large log" do
    {:ok, pid} = start_tui()

    # Preload a log far beyond the viewport (400 lines).
    Enum.each(1..400, fn i -> send(pid, {:entry, :system, "warm #{i}"}) end)
    eventually(pid, &(State.log_line_count(&1) == 400))

    # Burst coalescing with a big log: hundreds of messages, few frames.
    burst = Enum.map(1..300, &"b#{&1} ")
    burst_text = IO.iodata_to_binary(burst)
    before = Runtime.snapshot(pid).render_count
    Enum.each(burst, &send(pid, {:token, &1}))
    eventually(pid, &(&1.in_flight == burst_text))
    assert Runtime.snapshot(pid).render_count - before < 50

    # Cadence phase: tokens every 2ms while the user keeps typing.
    cadence_count = 200

    cadence =
      spawn(fn ->
        Enum.each(1..cadence_count, fn _i ->
          send(pid, {:token, "c"})
          Process.sleep(2)
        end)
      end)

    timings_ms =
      Enum.map(1..5, fn _i ->
        {micros, :ok} = :timer.tc(fn -> press(pid, "z") end)
        div(micros, 1000)
      end)

    max_ms = Enum.max(timings_ms)
    assert max_ms < 100, "input round-trips #{inspect(timings_ms)}ms while streaming at cadence"

    ref = Process.monitor(cadence)
    assert_receive {:DOWN, ^ref, :process, ^cadence, :normal}, 2_000

    # Exact count: every burst and cadence token landed, and every keystroke
    # was kept — a single dropped message fails this.
    expected = burst_text <> String.duplicate("c", cadence_count)

    state =
      eventually(pid, &(String.length(&1.in_flight || "") >= String.length(expected)))

    assert state.in_flight == expected
    assert State.input_text(state) == "zzzzz"
  end

  @tag :capture_log
  test "keystroke round-trips stay fast while the real engine streams at cadence" do
    frames = Enum.map(1..40, &frame("t#{&1} "))

    script =
      [{:send, @headers}] ++
        Enum.flat_map(frames, &[{:send, &1}, {:sleep, 10}]) ++
        [{:send, "data: [DONE]\n\n"}, :close]

    server = start_server(script)
    {:ok, pid} = start_tui(provider: provider(SSEServer.base_url(server)))

    submit(pid, "drip")

    eventually(pid, fn s -> s.in_flight != nil end)

    timings_ms =
      Enum.map(1..5, fn _i ->
        {micros, :ok} = :timer.tc(fn -> press(pid, "z") end)
        div(micros, 1000)
      end)

    assert Enum.max(timings_ms) < 100,
           "input round-trips #{inspect(timings_ms)}ms while the engine streams"

    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    expected = Enum.map_join(1..40, "", &"t#{&1} ")
    assert {:assistant, expected} in state.entries
    assert State.input_text(state) == "zzzzz"
  end

  test "an unreadable or invalid config still degrades to the setup instructions" do
    # {:error, _} and nil both land on the same guidance: the TUI stays usable
    # and never echoes the file contents or values.
    {:ok, pid} = start_tui(provider: {:error, "invalid JSON in /x/config.json"})
    submit(pid, "hello")

    state =
      eventually(pid, fn s ->
        entries = system_entries(s)

        s.phase == :idle and
          Enum.any?(entries, &String.contains?(&1, "[llm: no provider configured"))
      end)

    entries = system_entries(state)
    refute Enum.any?(entries, &String.contains?(&1, "/x/config.json"))
  end

  test "paste, resize, key releases, unknown events, and stray messages are handled" do
    {:ok, pid} = start_tui()

    inject(pid, %ExRatatui.Event.Paste{content: "pasted text"})
    pasted = get_state(pid)
    assert State.input_text(pasted) == "pasted text"

    inject(pid, %ExRatatui.Event.Resize{width: 100, height: 30})
    assert get_state(pid).size == {100, 30}

    # Key releases are ignored (kitty protocol).
    inject(pid, %ExRatatui.Event.Key{code: "x", modifiers: [], kind: "release"})
    released = get_state(pid)
    assert State.input_text(released) == "pasted text"

    # Events and messages we do not use are dropped, not crashes.
    inject(pid, %ExRatatui.Event.Mouse{kind: "down"})
    send(pid, :stray_message)
    after_stray = get_state(pid)
    assert State.input_text(after_stray) == "pasted text"
  end

  test "child_spec/1 is temporary and a worker" do
    spec = TUI.child_spec([])
    assert spec.type == :worker
    assert spec.restart == :temporary
  end

  test "exit_code/1 maps only an explicit quit to success" do
    assert TUI.exit_code(:normal) == 0
    assert TUI.exit_code(:shutdown) == 1
    assert TUI.exit_code({:error, :boom}) == 1
  end

  test "the TUI is absent from the application supervision tree in test env" do
    children = Supervisor.which_children(DashFloat.Supervisor)
    child_ids = Enum.map(children, &elem(&1, 0))
    # the stream supervisor is up; the TUI is gated out of :test
    assert DashFloat.StreamSupervisor in child_ids
    refute TUI in child_ids
  end

  defp inject(pid, event) do
    GenServer.call(pid, {:ex_ratatui_runtime_inject_event, event})
  end

  defp status_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> List.first()

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp attach_disconnect_listener do
    handler_id = {:disconnect_test, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ex_ratatui, :transport, :disconnect],
      fn _event, _measurements, %{reason: reason}, _config ->
        # Runs inside the TUI process; send to the captured test pid.
        send(test_pid, {:transport_disconnect, reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

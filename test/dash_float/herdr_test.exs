defmodule DashFloat.HerdrTest do
  @moduledoc """
  Unit tests for the Herdr integration (ADR 0024): env detection and the
  out-of-Herdr no-op guarantee, the phase-to-state map, the strictly
  increasing seq, the sanitized resume argv, the deduped fire-and-forget
  requests, and the bounded release. The `runner` fun on the context is the
  test seam (the suggest_fetcher pattern); the real delivery path is
  exercised against a local stand-in of Herdr's newline-JSON socket. A nil
  context is inert everywhere.
  """

  use ExUnit.Case, async: true

  alias DashFloat.Herdr

  defp herdr(runner \\ nil) do
    %Herdr{pane: "wA:p1", socket: "/tmp/opencode/herdr-test.sock", runner: runner}
  end

  # One report through a fresh wiring context: builds the runner-backed
  # context, reports the snapshot, and returns the advanced context.
  defp report_once(overrides) do
    test = self()
    runner = fn request -> send(test, {:herdr, request}) end
    snapshot = shot(overrides)
    ctx = herdr(runner)
    Herdr.report(ctx, snapshot)
  end

  defp shot(overrides \\ []) do
    Map.merge(
      %{
        phase: :idle,
        confirm: nil,
        exit_prompt: false,
        setup: false,
        session_id: nil,
        profile: nil,
        model: nil
      },
      Map.new(overrides)
    )
  end

  describe "detect/1" do
    test "a Herdr pane yields a context" do
      env = %{
        "HERDR_ENV" => "1",
        "HERDR_PANE_ID" => "wB:p2",
        "HERDR_SOCKET_PATH" => "/sock/herdr.sock"
      }

      assert %Herdr{pane: "wB:p2", socket: "/sock/herdr.sock"} = Herdr.detect(env)
    end

    test "missing or non-1 HERDR_ENV is permanently inert (nil)" do
      pane = %{"HERDR_PANE_ID" => "wB:p2", "HERDR_SOCKET_PATH" => "/sock/herdr.sock"}
      disabled = Map.put(pane, "HERDR_ENV", "0")
      refute Herdr.detect(disabled)

      absent = Map.delete(pane, "HERDR_ENV")
      refute Herdr.detect(absent)
      refute Herdr.detect(%{})
    end

    test "an empty pane id or socket path is not a Herdr pane" do
      no_pane = %{"HERDR_ENV" => "1", "HERDR_PANE_ID" => "", "HERDR_SOCKET_PATH" => "/s"}
      refute Herdr.detect(no_pane)

      no_socket = %{"HERDR_ENV" => "1", "HERDR_PANE_ID" => "wB:p2", "HERDR_SOCKET_PATH" => ""}
      refute Herdr.detect(no_socket)
    end
  end

  describe "the phase-to-state map (ADR 0024 §2)" do
    test "the idle composer reports idle" do
      assert Herdr.phase_state(:idle) == :idle
      assert Herdr.state_for(shot()) == {:idle, nil}
    end

    test "a busy agent reports working — streaming, executing tools, safety check running" do
      assert Herdr.phase_state(:streaming) == :working
      assert Herdr.phase_state(:executing_tool) == :working
      assert Herdr.phase_state(:checking) == :working

      busy = shot(phase: :executing_tool)
      assert Herdr.state_for(busy) == {:working, nil}
      checking = shot(phase: :checking)
      assert Herdr.state_for(checking) == {:working, nil}
    end

    test "a pending confirm reports blocked, naming the tool decision" do
      assert Herdr.phase_state(:confirming) == :blocked

      confirm = shot(phase: :confirming, confirm: "bash")
      assert Herdr.state_for(confirm) == {:blocked, "approve bash"}
    end

    test "the armed exit prompt reports blocked with its message" do
      exit_prompt = shot(exit_prompt: true)
      assert Herdr.state_for(exit_prompt) == {:blocked, "exit? press Ctrl+C again"}
    end

    test "the startup setup questions report blocked — a decision awaits the user" do
      setup = shot(setup: true)
      assert {:blocked, "first-run setup: choose a provider"} = Herdr.state_for(setup)
    end

    test "precedence: the pending confirm outranks the exit prompt and setup" do
      pending = shot(phase: :confirming, confirm: "edit", exit_prompt: true, setup: true)
      assert {:blocked, "approve edit"} = Herdr.state_for(pending)

      guard_only = shot(exit_prompt: true, setup: true)
      assert {:blocked, "exit? press Ctrl+C again"} = Herdr.state_for(guard_only)
    end

    test "the post-decision confirming gap (no pending confirm) stays blocked for its blink" do
      gap = shot(phase: :confirming)
      assert Herdr.state_for(gap) == {:blocked, nil}
    end
  end

  describe "next_seq/2" do
    test "is the wall clock, forced strictly increasing" do
      assert Herdr.next_seq(1_000, 0) == 1_000
      assert Herdr.next_seq(1_000, 900) == 1_000
      assert Herdr.next_seq(1_000, 1_000) == 1_001
      assert Herdr.next_seq(1_000, 2_000) == 2_001
    end

    test "same-millisecond bursts still order" do
      now = System.system_time(:millisecond)

      seqs =
        for _burst <- 1..5, reduce: 0 do
          seq -> Herdr.next_seq(now, seq)
        end

      assert seqs > now
      assert Herdr.next_seq(now, seqs) > seqs
    end
  end

  describe "resume_argv/3" do
    test "the plain PATH command, the resume id, then what resume alone does not restore" do
      assert Herdr.resume_argv("01923f8e-6b1e-7abc-8def-123456789abc", "work", "glm-4.7") == [
               "dashfloat",
               "--resume",
               "01923f8e-6b1e-7abc-8def-123456789abc",
               "--profile",
               "work",
               "--model",
               "glm-4.7"
             ]
    end

    test "profile and model are omitted when absent" do
      assert Herdr.resume_argv("id", nil, nil) == ["dashfloat", "--resume", "id"]

      assert Herdr.resume_argv("id", nil, "glm-4.7") == [
               "dashfloat",
               "--resume",
               "id",
               "--model",
               "glm-4.7"
             ]
    end

    test "values an apostrophe would poison are dropped, not the whole command" do
      assert Herdr.resume_argv("id", "tim's", "glm-4.7") == [
               "dashfloat",
               "--resume",
               "id",
               "--model",
               "glm-4.7"
             ]
    end

    test "control characters are dropped the same way" do
      assert Herdr.resume_argv("id", "a\nb", nil) == ["dashfloat", "--resume", "id"]
      assert Herdr.resume_argv("id", "a\x7fb", nil) == ["dashfloat", "--resume", "id"]
      # Non-binary values (a hand-broken config) drop, never crash.
      assert Herdr.resume_argv("id", :atom, nil) == ["dashfloat", "--resume", "id"]
    end
  end

  describe "report/2" do
    test "a nil context never fires (the out-of-Herdr no-op)" do
      assert Herdr.report(nil, shot(phase: :streaming)) == nil
      refute_receive {:herdr, _request}, 50
    end

    test "the first report sends the pane.report_agent request" do
      ctx = report_once(phase: :streaming)

      assert_receive {:herdr, %{method: "pane.report_agent", params: params}}

      assert params == %{
               pane_id: "wA:p1",
               source: "dashfloat",
               agent: "dashfloat",
               state: "working",
               seq: ctx.seq
             }

      assert ctx.seq > 0
    end

    test "the message rides the params" do
      report_once(confirm: "bash")

      assert_receive {:herdr, %{method: "pane.report_agent", params: params}}
      assert params.state == "blocked"
      assert params.message == "approve bash"
    end

    test "a named session follows with the resume command as its own request" do
      id = "01923f8e-6b1e-7abc-8def-123456789abc"
      ctx = report_once(session_id: id, profile: "work")

      assert_receive {:herdr, %{method: "pane.report_agent", params: state_params}}
      assert state_params.seq > 0
      state_seq = state_params.seq

      assert_receive {:herdr, %{method: "pane.report_agent_session", params: session_params}}

      assert session_params == %{
               pane_id: "wA:p1",
               source: "dashfloat",
               agent: "dashfloat",
               agent_session_id: id,
               seq: state_seq + 1,
               resume_argv: ["dashfloat", "--resume", id, "--profile", "work"]
             }

      assert ctx.seq == state_seq + 1
    end

    test "an unchanged signature reports nothing — token spam never reaches Herdr" do
      ctx = report_once(phase: :streaming)
      assert_receive {:herdr, _request}

      same = Herdr.report(ctx, shot(phase: :streaming))
      assert same.seq == ctx.seq
      assert same.sig == ctx.sig
      refute_receive {:herdr, _request}, 50
    end

    test "a changed signature fires again with a strictly higher seq" do
      ctx = report_once(phase: :streaming)
      assert_receive {:herdr, %{params: %{seq: seq1}}}

      idle = shot(phase: :idle)
      next = Herdr.report(ctx, idle)
      assert_receive {:herdr, %{params: %{seq: seq2}}}

      assert seq2 > seq1
      assert next.seq == seq2
    end

    test "a spawn failure leaves the signature uncommitted — the next event retries" do
      # A supervisor name nothing answers to: the spawn exits, the caller
      # hears :error, and the SAME state must fire again on the next event
      # (ADR 0024 §4 — a transient failure is retried, not swallowed).
      test = self()
      dead = Herdr.TestDeadSupervisor
      context = %Herdr{pane: "wA:p1", socket: "/tmp/opencode/herdr-test.sock", supervisor: dead}
      streaming = shot(phase: :streaming)
      failed = Herdr.report(context, streaming)
      refute_receive {:herdr, _request}, 50
      assert failed.sig == nil and failed.seq == 0

      working = %Herdr{failed | runner: fn request -> send(test, {:herdr, request}) end}
      _retried = Herdr.report(working, streaming)
      assert_receive {:herdr, %{params: %{state: "working"}}}
    end

    test "a resume command Herdr would reject is dropped, not the state report" do
      # Over Herdr's 8 KiB argv budget: the state report still fires, the
      # session request is silently omitted.
      huge = String.duplicate("m", 9_000)
      ctx = report_once(session_id: "id", model: huge)

      assert_receive {:herdr, %{method: "pane.report_agent", params: params}}
      assert params.state == "idle"
      refute_receive {:herdr, %{method: "pane.report_agent_session"}}, 50
      assert ctx.seq > 0
    end
  end

  describe "release/1" do
    test "a nil context releases nothing" do
      assert Herdr.release(nil) == :ok
      refute_receive {:herdr, _request}, 50
    end

    test "the release request names the source and agent" do
      test = self()
      runner = fn request -> send(test, {:herdr, request}) end
      ctx = herdr(runner)
      :ok = Herdr.release(ctx)

      assert_receive {:herdr, request}
      seq = request.params.seq

      assert request == %{
               method: "pane.release_agent",
               params: %{pane_id: "wA:p1", source: "dashfloat", agent: "dashfloat", seq: seq}
             }

      assert seq > 0
    end
  end

  describe "the real delivery path (Herdr's newline-JSON socket)" do
    # A stand-in Herdr server: accepts one connection per request, answers
    # the ack line, and forwards what it heard to the test. Each socket
    # owns a short UNIQUE directory, created right here: nothing else in
    # the suite makes /tmp/opencode, so deriving a path inside it without
    # creating the directory raced the whole suite on a fresh runner
    # (issue #121, ADR 0025). Paths stay short — the OS caps a unix socket
    # path at ~107 bytes, and ExUnit's tmp_dir names are longer than that.
    defp short_socket(name) do
      dir = "/tmp/opencode/herdr-#{name}-#{System.unique_integer([:positive])}"
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      Path.join(dir, "s.sock")
    end

    defp start_herdr_standin(path, reply? \\ true) do
      test = self()
      # A killed earlier run can leak its socket at the same unique path.
      File.rm(path)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

      spawn_link(fn -> standin_accept(listen, test, reply?) end)
      listen
    end

    defp standin_accept(listen, test, reply?) do
      {:ok, sock} = :gen_tcp.accept(listen, 10_000)
      :inet.setopts(sock, active: true)
      send(test, {:standin_socket, sock})
      standin_serve(sock, test, reply?)
      standin_accept(listen, test, reply?)
    end

    defp standin_serve(sock, test, reply?) do
      receive do
        {:tcp, ^sock, line} ->
          send(test, {:standin_line, line})

          if reply?,
            do: :gen_tcp.send(sock, "{\"id\":\"dashfloat\",\"result\":{\"type\":\"ok\"}}\n")

        {:tcp_closed, ^sock} ->
          :ok
      after
        5_000 -> :ok
      end
    end

    test "the standin owns its socket directory: created fresh, unique per socket" do
      # Issue #121: the helper must create the directory itself — nothing
      # else in the suite guarantees /tmp/opencode exists on a fresh
      # runner — and every socket gets its own directory, never a shared
      # parent another test could be mid-way through using.
      a = short_socket("hermetic-a")
      b = short_socket("hermetic-b")
      dir_a = Path.dirname(a)
      dir_b = Path.dirname(b)

      assert File.dir?(dir_a)
      assert dir_a != dir_b
    end

    test "a report connects, sends the JSON line, and reads one reply" do
      path = short_socket("report")
      _listen = start_herdr_standin(path)

      streaming = shot(phase: :streaming)
      ctx = %Herdr{herdr() | socket: path, runner: nil}
      reported = Herdr.report(ctx, streaming)

      assert_receive {:standin_line, line}, 1_000
      assert {:ok, %{"method" => "pane.report_agent", "params" => params}} = Jason.decode(line)
      assert params["state"] == "working"
      assert params["source"] == "dashfloat"
      assert params["seq"] == reported.seq
    end

    test "a hung Herdr server is abandoned at the timeout" do
      path = short_socket("hung")
      _listen = start_herdr_standin(path, false)

      started = System.monotonic_time(:millisecond)
      ctx = %Herdr{herdr() | socket: path, runner: nil, timeout_ms: 100, seq: 5}

      # release/1 is the synchronous-bounded path — the same sender the
      # async report task uses — so its deadline is observable directly.
      assert Herdr.release(ctx) == :ok
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 1_000
    end

    test "a missing socket fails open, silently" do
      ctx = %Herdr{herdr() | socket: short_socket("missing"), runner: nil}
      assert Herdr.report(ctx, shot(phase: :idle)).seq > 0
      assert Herdr.release(ctx) == :ok
    end
  end
end

defmodule DashFloat.AgentTest do
  @moduledoc false
  # The Phase 3 end-to-end suite: a scripted tool-calling stream through the
  # real agent, against a sandbox tree and the loopback SSE server. The test
  # process plays the UI (it receives the display contract and answers
  # confirmations); the server's forwarded request bodies prove what the model
  # sees on the next episode. Not async: real sockets and shared supervisors.
  #
  # See ADR 0007.

  use ExUnit.Case, async: false

  alias DashFloat.Agent
  alias DashFloat.Config
  alias DashFloat.Session
  alias DashFloat.SSEServer
  alias DashFloat.TUI.State

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  defp usage_frame(total) do
    ~s(data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":#{total}}}\n\n)
  end

  # A streamed tool call: the id/name frame first, then argument fragments.
  defp tool_frames(id, name, arg_fragments) do
    opening =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)

    rest =
      for frag <- arg_fragments do
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
      end

    [opening | rest]
  end

  # A second, parallel call on index 1.
  defp tool_frames_1(id, name, arg_fragments) do
    opening =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)

    rest =
      for frag <- arg_fragments do
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
      end

    [opening | rest]
  end

  defp call_tool_episode(id, name, args, opts \\ []) do
    frames = tool_frames(id, name, [Jason.encode!(args)])
    prefix = Keyword.get(opts, :prefix, [])
    suffix = if usage = opts[:usage], do: [usage_frame(usage)], else: []

    [{:send, [@headers | prefix ++ frames ++ suffix]}, {:send, "data: [DONE]\n\n"}, :close]
  end

  defp final_episode(text \\ "All done.", opts \\ []) do
    prefix = Keyword.get(opts, :prefix, [])
    suffix = if usage = opts[:usage], do: [usage_frame(usage)], else: []

    [{:send, [@headers | prefix ++ [frame(text)] ++ suffix]}, {:send, "data: [DONE]\n\n"}, :close]
  end

  defp start_server(scripts) do
    {:ok, server} = SSEServer.start_link(:per_connection, scripts)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp provider(server) do
    {:ok,
     %Config{base_url: SSEServer.base_url(server), model: "test-model", api_key: "test-key-123"}}
  end

  defp start_agent(server, cwd, opts \\ []) do
    # A per-test supervisor: the agent's stream/runner tasks land here, so
    # tests can enumerate them without leftovers from other tests.
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider: provider(server),
        cwd: cwd,
        exec_timeout: Keyword.get(opts, :exec_timeout, 500),
        supervisor: sup,
        session_dir: Keyword.get(opts, :session_dir),
        resume: Keyword.get(opts, :resume),
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    {agent, sup}
  end

  # The id of the single session file in a test's sessions dir.
  defp session_id(dir) do
    [file] = File.ls!(dir)
    Path.rootname(file)
  end

  defp read_session(dir) do
    dir
    |> Path.join(session_id(dir) <> ".json")
    |> File.read!()
  end

  # Decodes the messages array of a forwarded request body.
  defp request_messages(body) do
    body
    |> Jason.decode!()
    |> Map.fetch!("messages")
  end

  defp tool_result_of(body, id) do
    body
    |> request_messages()
    |> tool_result_message(id)
  end

  defp read_sandbox(ctx, relative) do
    ctx.tmp_dir
    |> Path.join(relative)
    |> File.read!()
  end

  defp write_sandbox(ctx, relative, content) do
    ctx.tmp_dir
    |> Path.join(relative)
    |> File.write!(content)
  end

  defp sandbox_exists?(ctx, relative) do
    ctx.tmp_dir
    |> Path.join(relative)
    |> File.exists?()
  end

  defp sandbox_parent_file?(ctx, name) do
    ctx.tmp_dir
    |> Path.dirname()
    |> Path.join(name)
    |> File.exists?()
  end

  defp tool_result_message(messages, id) do
    Enum.find(messages, &match?(%{"role" => "tool", "tool_call_id" => ^id}, &1))
  end

  ## The end-to-end round trip

  @tag :tmp_dir
  test "round trip: stream a write_file call, confirm it, execute, feed the result back", ctx do
    args = %{"path" => "out/hello.txt", "content" => "hi there"}

    server =
      start_server([
        call_tool_episode("call_1", "write_file", args),
        final_episode("wrote it")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "create the file"})
    assert_receive {:sse_request, "POST", _, _, _first_body}, 2_000

    # The confirmation carries engine-built preview content (ADR 0007 §4).
    assert_receive {:confirm, ref, %{id: "call_1", name: "write_file", lines: lines}}, 2_000
    assert Enum.any?(lines, &String.starts_with?(&1, "+")), inspect(lines)
    assert Enum.any?(lines, &String.contains?(&1, "hello.txt")), inspect(lines)

    # NO mutation lands without the keypress — the file does not exist yet.
    refute sandbox_exists?(ctx, "out/hello.txt")

    send(agent, {:confirm_decision, ref, :approved})

    assert_receive {:tool_result, %{id: "call_1", name: "write_file", ok: true, status: "ok"}},
                   2_000

    assert read_sandbox(ctx, "out/hello.txt") == "hi there"

    # The model sees the outcome: request 2 carries the assistant tool_calls
    # message and the tool result, in protocol shape.
    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    messages = request_messages(second_body)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => [assistant_call]},
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => result_json}
           ] = messages

    assert assistant_call["id"] == "call_1"
    assert assistant_call["function"]["name"] == "write_file"
    assert Jason.decode!(assistant_call["function"]["arguments"]) == args

    assert %{"ok" => true, "bytes" => 8, "created" => true} = Jason.decode!(result_json)

    # The final episode streams into the log and returns the UI to idle.
    assert_receive {:token, "wrote it"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "rejection: Esc reports the refusal to the model and mutates nothing", ctx do
    args = %{"path" => "nope.txt", "content" => "x"}

    server =
      start_server([
        call_tool_episode("call_r", "write_file", args),
        final_episode("understood")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "write it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "write_file"}}, 2_000
    send(agent, {:confirm_decision, ref, :rejected})

    assert_receive {:tool_result, %{name: "write_file", ok: false, status: "rejected"}}, 2_000

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} =
             tool_result_of(second_body, "call_r")

    assert Jason.decode!(result_json) == %{"ok" => false, "rejected" => true}
    refute sandbox_exists?(ctx, "nope.txt")
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "reads are automatic: read_file executes with no confirmation", ctx do
    write_sandbox(ctx, "notes.md", "line one\nline two\n")

    server =
      start_server([
        call_tool_episode("call_read", "read_file", %{"path" => "notes.md"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "read it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_call, %{id: "call_read", name: "read_file", args: args}}, 2_000
    assert args["path"] == "notes.md"
    assert args["offset"] == 1

    assert_receive {:tool_result, %{name: "read_file", ok: true, output: output}}, 2_000
    assert output =~ "line two"

    refute_received {:confirm, _ref, _preview}

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} =
             tool_result_of(second_body, "call_read")

    assert %{"ok" => true, "content" => "line one\nline two", "truncated" => false} =
             Jason.decode!(result_json)

    assert_receive {:phase, :idle}, 2_000
  end

  ## Safety policy at the agent level

  @tag :tmp_dir
  test "a path escape on a read is rejected AND logged to the chat", ctx do
    server =
      start_server([
        call_tool_episode("call_esc", "read_file", %{"path" => "../../etc/passwd"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "read outside"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{name: "read_file", ok: false, status: status}}, 2_000
    assert status =~ "escape"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} =
             tool_result_of(second_body, "call_esc")

    assert %{"ok" => false, "error" => error} = Jason.decode!(result_json)
    assert error =~ "escape"
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a mutation outside the working directory is refused before confirmation", ctx do
    args = %{"path" => "../outside.txt", "content" => "nope"}

    server =
      start_server([
        call_tool_episode("call_w", "write_file", args),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "write outside"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    # The policy runs while building the preview: an escaping mutation never
    # even reaches the user (ADR 0007 §3 — rejections are results, not modals).
    refute_received {:confirm, _ref, _preview}

    assert_receive {:tool_result, %{name: "write_file", ok: false, status: status}}, 2_000
    assert status =~ "escape"

    refute sandbox_parent_file?(ctx, "outside.txt")
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "an ambiguous edit never reaches the user: straight error to the model", ctx do
    write_sandbox(ctx, "dup.txt", "alpha\nalpha\n")

    server =
      start_server([
        call_tool_episode("call_e", "edit_file", %{
          "path" => "dup.txt",
          "search_block" => "alpha",
          "replace_block" => "beta"
        }),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "edit it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    refute_received {:confirm, _ref, _preview}

    assert_receive {:tool_result, %{name: "edit_file", ok: false, status: status}}, 2_000
    assert status =~ "match"

    assert read_sandbox(ctx, "dup.txt") == "alpha\nalpha\n"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} =
             tool_result_of(second_body, "call_e")

    assert %{"ok" => false, "error" => error} = Jason.decode!(result_json)
    assert error =~ "match"
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "unknown tools and malformed arguments become error results, not crashes", ctx do
    server =
      start_server([
        call_tool_episode("call_u", "explode", %{"path" => "x"}),
        call_tool_episode("call_m", "read_file", %{}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "misbehave"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_u", status: status_u}}, 2_000
    assert status_u =~ "unknown tool"

    assert_receive {:tool_result, %{id: "call_m", status: status_m}}, 2_000
    assert status_m =~ "path"

    # Episode 2's request carries the first error; episode 3's carries both.
    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    assert %{"content" => json_u} = tool_result_of(second_body, "call_u")
    assert %{"ok" => false, "error" => "unknown tool \"explode\""} = Jason.decode!(json_u)

    assert_receive {:sse_request, "POST", _, _, third_body}, 4_000
    messages = request_messages(third_body)

    assert %{"content" => json_m} = tool_result_message(messages, "call_m")
    assert %{"ok" => false, "error" => error_m} = Jason.decode!(json_m)
    assert error_m =~ "path"
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "streamed invalid JSON arguments become an error result to the model", ctx do
    frames = tool_frames("call_bad", "read_file", ["{\"path\": "])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "call it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_bad", ok: false, status: status}}, 2_000
    assert status =~ "invalid JSON arguments"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    messages = request_messages(second_body)

    assert %{"role" => "assistant", "tool_calls" => [call]} = Enum.at(messages, -2)
    assert call["function"]["arguments"] == "{}"

    assert %{"content" => result_json} = tool_result_message(messages, "call_bad")
    assert Jason.decode!(result_json) == %{"ok" => false, "error" => "invalid JSON arguments"}

    # The turn's display messages (including the nil-args tool_call) must
    # render in the real UI state, never crash it (hostile-review P1-1).
    Process.sleep(100)
    log = display_log()
    assert {:phase, :idle} in log
    assert contract_survives?(log)
  end

  ## Multiple calls and usage gating

  @tag :tmp_dir
  test "a multi-call batch: automatic read then confirmed write, results in call order", ctx do
    write_sandbox(ctx, "src.txt", "seed\n")
    # Parallel indices: read on 0, write on 1.
    frames =
      tool_frames("call_rd", "read_file", [~s({"path":"src.txt"})]) ++
        tool_frames_1("call_wr", "write_file", [~s({"path":"dst.txt","content":"made"})])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "copy it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_rd", ok: true}}, 2_000
    assert_receive {:confirm, ref, %{id: "call_wr"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})

    assert_receive {:tool_result, %{id: "call_wr", ok: true}}, 2_000
    assert read_sandbox(ctx, "dst.txt") == "made"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    messages = request_messages(second_body)

    tool_messages = Enum.filter(messages, &(&1["role"] == "tool"))
    assert Enum.map(tool_messages, & &1["tool_call_id"]) == ["call_rd", "call_wr"]
    assert_receive {:phase, :idle}, 2_000
  end

  test "only the final episode's usage reaches the UI" do
    server =
      start_server([
        call_tool_episode("call_1", "list_directory", %{"path" => "."}, usage: 100),
        final_episode("done", usage: 500)
      ])

    {agent, _sup} = start_agent(server, System.tmp_dir!())
    send(agent, {:prompt, self(), "list"})

    assert_receive {:phase, :idle}, 4_000

    assert_received {:usage, %{total_tokens: 500}}
    refute_received {:usage, %{total_tokens: 100}}
  end

  @tag :tmp_dir
  test "a long tool output is excerpted to 30 lines in the log row (the model sees more)", ctx do
    write_sandbox(ctx, "long.txt", Enum.map_join(1..60, &"line #{&1}\n"))

    server =
      start_server([
        call_tool_episode("call_l", "read_file", %{"path" => "long.txt"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "read it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{name: "read_file", ok: true, output: output}}, 2_000

    excerpt_lines =
      output
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))

    assert length(excerpt_lines) == 30
    assert List.first(excerpt_lines) == "line 1"
    assert List.last(excerpt_lines) == "line 30"
  end

  ## Interrupts

  test "Esc during streaming keeps the partial reply and logs [cancelled]" do
    server =
      start_server([
        [{:send, [@headers, frame("partial")]}, {:sleep, 60_000}, {:wait_close, 1_000}]
      ])

    {agent, _sup} = start_agent(server, System.tmp_dir!())
    send(agent, {:prompt, self(), "hello"})

    assert_receive {:token, "partial"}, 2_000
    send(agent, {:cancel})

    assert_receive {:entry, :system, "[cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "Esc during a running command kills it, aborts the batch, and stays round-trippable",
       ctx do
    server =
      start_server([
        call_tool_episode("call_x", "execute_command", %{"command" => "sleep 5"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})

    # The phase flips back to executing on approval: the activity line must
    # not keep asking "Approve this change?" while the command runs (P1-2).
    assert_receive {:phase, :executing_tool}, 1_000

    assert_receive {:tool_call, %{id: "call_x"}}, 2_000
    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_x", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # Aborted: no second request re-prompts the model with a dead command.
    refute_receive {:sse_request, "POST", _, _, _second}, 300
  end

  @tag :tmp_dir
  test "an externally killed runner aborts the batch with a cancelled result", ctx do
    server =
      start_server([
        call_tool_episode("call_k", "execute_command", %{"command" => "sleep 5"}),
        final_episode()
      ])

    {agent, sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    runner = await_task(sup)
    Process.exit(runner, :kill)

    assert_receive {:tool_result, %{id: "call_k", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute_receive {:sse_request, "POST", _, _, _second}, 300
  end

  @tag :tmp_dir
  test "an aborted batch never sends literal null tool results to the model", ctx do
    # Two calls: a long command (cancelled mid-run by message) and a queued
    # read that never runs. Every announced call must carry real JSON.
    frames =
      tool_frames("call_run", "execute_command", [~s({"command":"sleep 10"})]) ++
        tool_frames_1("call_read", "read_file", [~s({"path":"never.txt"})])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close]
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 30_000)
    send(agent, {:prompt, self(), "go"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, run_ref, %{id: "call_run"}}, 2_000
    send(agent, {:confirm_decision, run_ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    # Cancel while the command runs: Exec reaps it and reports cancelled; the
    # queued read is filled cancelled by the abort — never a dangling "null".
    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_run", status: "cancelled"}}, 3_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    state = :sys.get_state(agent)

    tool_messages =
      state
      |> Map.fetch!(:messages)
      |> Enum.filter(&(&1.role == "tool"))

    assert length(tool_messages) == 2
    assert Enum.all?(tool_messages, &(&1.content != "null"))

    for id <- ["call_run", "call_read"] do
      assert %{"ok" => false, "cancelled" => true} =
               tool_messages
               |> Enum.find(&(&1.tool_call_id == id))
               |> Map.fetch!(:content)
               |> Jason.decode!()
    end
  end

  @tag :tmp_dir
  test "a runner dying between cancel and completion aborts the same way", ctx do
    server =
      start_server([
        call_tool_episode("call_d", "execute_command", %{"command" => "sleep 5"}),
        final_episode()
      ])

    {agent, sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})

    runner = await_task(sup)
    send(agent, {:cancel})
    Process.exit(runner, :boom)

    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute_receive {:sse_request, "POST", _, _, _second}, 300
  end

  @tag :tmp_dir
  test "a runner dying before its monitor is placed reports cancelled, not crashed", ctx do
    # The spawn window in dispatch_runner/2: the monitor goes up after
    # start_child returns, and Process.monitor/1 on a pid that already died
    # fires immediately with reason :noproc. Forged here with the slot's real
    # ref and the real runner pid — the live window is scheduler-dependent —
    # and the equivalence holds post-ADR-0012: the runner self-reports every
    # death its body can observe (the try/rescue in dispatch_runner/2), so a
    # :noproc DOWN reaching a still-{:running} slot means the body never
    # reported: it never started, or died to an external kill — both are the
    # deaths the :killed clause already reports as cancelled.
    server =
      start_server([
        call_tool_episode("call_w", "execute_command", %{"command" => "sleep 5"}),
        final_episode()
      ])

    {agent, sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    runner = await_task(sup)
    state = :sys.get_state(agent)
    {:running, mon_ref, ^runner, _call} = state.tool_slot

    send(agent, {:DOWN, mon_ref, :process, runner, :noproc})

    assert_receive {:tool_result, %{id: "call_w", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute_receive {:sse_request, "POST", _, _, _second}, 300

    # The still-live runner's eventual death is stray, never a second result.
    Process.exit(runner, :kill)
  end

  @tag :tmp_dir
  test "a crashed runner degrades to an error result and the loop continues", ctx do
    server =
      start_server([
        call_tool_episode("call_c", "execute_command", %{"command" => "sleep 5"}),
        final_episode("continued")
      ])

    {agent, sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    assert_receive {:tool_call, %{id: "call_c"}}, 2_000

    runner = await_task(sup)
    Process.exit(runner, :boom)

    assert_receive {:tool_result, %{id: "call_c", ok: false, status: status}}, 2_000
    assert status =~ "tool crashed"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} =
             tool_result_of(second_body, "call_c")

    assert %{"ok" => false, "error" => error} = Jason.decode!(result_json)
    assert error =~ "tool crashed"
    assert_receive {:phase, :idle}, 2_000
  end

  test "a crashed stream task degrades to a system entry and idle" do
    server =
      start_server([
        [{:send, [@headers, frame("kept")]}, {:sleep, 60_000}, {:wait_close, 1_000}]
      ])

    {agent, sup} = start_agent(server, System.tmp_dir!())
    send(agent, {:prompt, self(), "hello"})

    assert_receive {:token, "kept"}, 2_000

    stream = await_task(sup)
    Process.exit(stream, :boom)

    assert_receive {:entry, :system, "[stream failed: :boom]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  ## Failure taxonomy and lifecycle

  test "a provider connection failure becomes a system entry and idle" do
    # Point at a dead port: nothing listens there.
    {:ok, agent} =
      Agent.start_link(
        provider:
          {:ok, %Config{base_url: "http://127.0.0.1:#{free_port()}", model: "m", api_key: "k"}},
        cwd: System.tmp_dir!(),
        name: nil
      )

    on_exit(fn -> DashFloat.TestTeardown.stop(agent) end)

    send(agent, {:prompt, self(), "hello"})

    assert_receive {:entry, :system, text}, 2_000
    assert text =~ "[llm: connection failed: "
    assert_receive {:phase, :idle}, 2_000
  end

  test "an unusable provider config answers with the setup instructions" do
    {:ok, agent} =
      Agent.start_link(
        provider: {:error, "missing provider config"},
        cwd: System.tmp_dir!(),
        name: nil
      )

    on_exit(fn -> DashFloat.TestTeardown.stop(agent) end)

    send(agent, {:prompt, self(), "hello"})

    assert_receive {:entry, :system, text}, 1_000
    assert text =~ "[llm: no provider configured"
    assert text =~ "DASHFLOAT_API_KEY"
    assert_receive {:phase, :idle}, 1_000
  end

  test "an empty reply degrades to a system entry" do
    server = start_server([[{:send, [@headers, "data: [DONE]\n\n"]}, :close]])
    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:prompt, self(), "hello"})

    assert_receive {:entry, :system, "[model returned nothing]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  test "a prompt while busy is ignored; a stale confirmation decision is ignored" do
    server =
      start_server([
        [{:send, [@headers, frame("hi")]}, {:sleep, 60_000}, {:wait_close, 1_000}]
      ])

    {agent, _sup} = start_agent(server, System.tmp_dir!())
    send(agent, {:prompt, self(), "first"})
    assert_receive {:token, "hi"}, 2_000
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    send(agent, {:prompt, self(), "second"})
    send(agent, {:confirm_decision, make_ref(), :approved})

    refute_receive {:sse_request, "POST", _, _, _second}, 300
    refute_receive {:entry, :system, _text}, 100

    send(agent, {:cancel})
    assert_receive {:phase, :idle}, 2_000
  end

  test "stale stream and runner messages while idle are ignored, never a crash" do
    server = start_server([final_episode("unused")])
    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:cancel})
    send(agent, {:token, "late"})
    send(agent, {:usage, %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})
    send(agent, {:stream_failed, "late failure", "late"})
    send(agent, {:stream_done, %{content: "late", tool_calls: [], cancelled: false}})
    send(agent, {:tool_done, "call_late", %{ok: true}})

    refute_receive {:token, _text}, 100
    refute_receive {:entry, :system, _text}, 100
    assert Process.alive?(agent)
  end

  ## Session persistence (ADR 0014 §5)

  @tag :tmp_dir
  test "no session file appears before the first prompt", ctx do
    server = start_server([final_episode("unused")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    # The directory is created on demand at the first save — a launch that
    # never prompts leaves nothing.
    refute File.exists?(sessions)

    DashFloat.TestTeardown.stop(agent)
  end

  @tag :tmp_dir
  test "a completed read_file turn persists the full transcript, untruncated", ctx do
    # 40 lines: the log row shows a 30-line excerpt, the transcript must hold
    # the whole result the model received.
    body = Enum.map_join(1..40, "\n", &"line #{&1}")
    write_sandbox(ctx, "long.txt", body <> "\n")

    server =
      start_server([
        call_tool_episode("call_1", "read_file", %{"path" => "long.txt"}),
        final_episode("read it all")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "read it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    assert_receive {:tool_result, %{id: "call_1", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    id = session_id(sessions)
    {:ok, session} = Session.load(sessions, id)

    assert session.version == 1
    assert session.id == id
    assert is_binary(session.created_at)

    assert session.pin == %{
             profile: nil,
             model: "test-model",
             base_url: SSEServer.base_url(server)
           }

    args_json = Jason.encode!(%{"path" => "long.txt"})

    result_json =
      Jason.encode!(%{
        ok: true,
        path: "long.txt",
        content: body,
        lines: 40,
        total_lines: 40,
        total_bytes: byte_size(body) + 1,
        truncated: false
      })

    assert session.messages == [
             %{"role" => "user", "content" => "read it"},
             %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "call_1",
                   "type" => "function",
                   "function" => %{"name" => "read_file", "arguments" => args_json}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => result_json},
             %{"role" => "assistant", "content" => "read it all"}
           ]
  end

  @tag :tmp_dir
  test "paused at the confirmation the file holds the dangling batch; approval completes it",
       ctx do
    args = %{"path" => "out/hello.txt", "content" => "hi there"}

    server =
      start_server([
        call_tool_episode("call_1", "write_file", args),
        final_episode("wrote it")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "create the file"})
    assert_receive {:confirm, ref, %{id: "call_1"}}, 2_000

    id = session_id(sessions)
    bytes = read_session(sessions)

    # The deliberately-dangling write: the batch is on disk with no tool
    # message yet — exactly the shape load repairs after a kill.
    assert %{
             "version" => 1,
             "id" => ^id,
             "created_at" => created_at,
             "pin" => %{"profile" => nil, "model" => "test-model"},
             "messages" => [
               %{"role" => "user", "content" => "create the file"},
               %{
                 "role" => "assistant",
                 "content" => nil,
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{"name" => "write_file", "arguments" => args_json}
                   }
                 ]
               }
             ]
           } = Jason.decode!(bytes)

    assert is_binary(created_at)
    assert args_json == Jason.encode!(args)
    assert String.ends_with?(bytes, "\n")

    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:tool_result, %{id: "call_1", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    {:ok, session} = Session.load(sessions, id)

    assert [%{"role" => "user"}, %{"role" => "assistant"}, tool, final] = session.messages

    assert Jason.decode!(tool["content"]) == %{
             "ok" => true,
             "path" => "out/hello.txt",
             "bytes" => 8,
             "created" => true
           }

    assert final["content"] == "wrote it"
  end

  @tag :tmp_dir
  test "a base_url carrying a query never pins its secret into the session file", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    secret = "SECRET-QUERY-SENTINEL"

    leaked_url = SSEServer.base_url(server) <> "?api_key=" <> secret

    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider: {:ok, %Config{base_url: leaked_url, model: "test-model", api_key: "k"}},
        cwd: ctx.tmp_dir,
        session_dir: sessions,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "hello"})
    assert_receive {:phase, :idle}, 2_000

    id = session_id(sessions)
    {:ok, session} = Session.load(sessions, id)

    # The pin is the query-free endpoint; the secret reaches neither.
    assert session.pin.base_url == SSEServer.base_url(server)

    session_path = Path.join(sessions, id <> ".json")
    bytes = File.read!(session_path)
    refute bytes =~ secret
    refute bytes =~ "api_key"
  end

  @tag :tmp_dir
  test "a batch announcing the SAME id twice: both calls execute and persist distinct ids", ctx do
    write_sandbox(ctx, "notes.md", "seed\n")

    # Both parallel calls announce the same id — a sloppy provider's batch.
    frames =
      tool_frames("call_dup", "read_file", [~s({"path":"notes.md"})]) ++
        tool_frames_1("call_dup", "list_directory", [~s({"path":"."})])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode("both done")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "run both"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    # Both calls execute; the repeat carries its occurrence rename.
    assert_receive {:tool_result, %{id: "call_dup", ok: true}}, 2_000
    assert_receive {:tool_result, %{id: "call_dup-2", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The persisted transcript carries distinct ids, answered one-to-one —
    # a file with a repeated id would refuse to load at all (ADR 0014 §4).
    id = session_id(sessions)
    {:ok, session} = Session.load(sessions, id)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
             tool_a,
             tool_b,
             %{"role" => "assistant", "content" => "both done"}
           ] = session.messages

    assert Enum.map(calls, & &1["id"]) == ["call_dup", "call_dup-2"]
    assert Enum.map([tool_a, tool_b], & &1["tool_call_id"]) == ["call_dup", "call_dup-2"]

    # Each answer is its own call's result, not one call's twice.
    assert Jason.decode!(tool_a["content"])["path"] == "notes.md"

    result_b = Jason.decode!(tool_b["content"])
    assert Map.has_key?(result_b, "entries")
  end

  @tag :tmp_dir
  test "a mid-batch cancel persists cancelled results for the whole batch", ctx do
    frames =
      tool_frames("call_run", "execute_command", [~s({"command":"sleep 10"})]) ++
        tool_frames_1("call_read", "read_file", [~s({"path":"never.txt"})])

    server = start_server([[{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close]])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, exec_timeout: 30_000)

    send(agent, {:prompt, self(), "go"})
    assert_receive {:confirm, ref, %{id: "call_run"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_run", status: "cancelled"}}, 3_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    {:ok, session} = Session.load(sessions, session_id(sessions))

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => calls},
             tool_run,
             tool_read
           ] = session.messages

    assert Enum.map(calls, & &1["id"]) == ["call_run", "call_read"]
    assert tool_run["tool_call_id"] == "call_run"
    assert tool_read["tool_call_id"] == "call_read"

    # The executed call keeps Exec's own cancelled report; the queued call is
    # filled with the bare cancelled result — both real JSON, never "null".
    assert %{"ok" => false, "cancelled" => true} = Jason.decode!(tool_run["content"])
    assert Jason.decode!(tool_read["content"]) == %{"ok" => false, "cancelled" => true}
  end

  @tag :tmp_dir
  test "a save failure degrades to a system entry and the turn still completes", ctx do
    # A regular file where the sessions directory should be: mkdir_p refuses.
    blocked = Path.join(ctx.tmp_dir, "not-a-dir")
    File.write!(blocked, "a file, not a directory")

    server = start_server([final_episode("still fine")])
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: blocked)

    send(agent, {:prompt, self(), "hello"})

    # Each failing save warns once and names the path; the episode continues.
    assert_receive {:entry, :system, text}, 2_000
    assert String.starts_with?(text, "[session not saved: ")
    assert text =~ blocked

    assert_receive {:token, "still fine"}, 2_000
    assert_receive {:entry, :system, "[session not saved: " <> _}, 2_000
    assert_receive {:phase, :idle}, 2_000
    assert Process.alive?(agent)
  end

  @tag :tmp_dir
  test "session_dir nil (the default) writes no session file anywhere", ctx do
    write_sandbox(ctx, "notes.md", "seed\n")

    server =
      start_server([
        call_tool_episode("call_1", "read_file", %{"path" => "notes.md"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "read it"})
    assert_receive {:tool_result, %{id: "call_1", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The sandbox holds only what the tool itself wrote.
    assert File.ls!(ctx.tmp_dir) == ["notes.md"]
  end

  @tag :tmp_dir
  test "the provider's api_key never reaches the session file", ctx do
    sentinel = "sentinel-key-" <> String.duplicate("x", 32)
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider:
          {:ok,
           %Config{base_url: SSEServer.base_url(server), model: "test-model", api_key: sentinel}},
        cwd: ctx.tmp_dir,
        session_dir: sessions,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "hello"})
    assert_receive {:phase, :idle}, 2_000

    bytes = read_session(sessions)
    refute bytes =~ sentinel
    refute bytes =~ "api_key"
  end

  @tag :tmp_dir
  test "kill round-trip: a mid-batch kill resumes with the repaired transcript", ctx do
    args = %{"path" => "out/killed.txt", "content" => "never finished"}

    server =
      start_server([
        call_tool_episode("call_k", "write_file", args),
        final_episode("picked up where we left off")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "write it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    assert_receive {:confirm, _ref, %{id: "call_k"}}, 2_000

    # Uncatchable: no terminate callback runs, so the on-disk truth is the
    # last completed atomic write — the dangling batch. Unlink first: the
    # test process started the agent, and :kill rides links.
    Process.unlink(agent)
    Process.exit(agent, :kill)

    id = session_id(sessions)
    bytes = read_session(sessions)
    decoded = Jason.decode!(bytes)

    assert %{
             "messages" => [
               %{"role" => "user", "content" => "write it"},
               %{"role" => "assistant", "tool_calls" => [call]}
             ]
           } = decoded

    assert call["id"] == "call_k"

    # Load repaired the dangling batch in memory: one synthesized cancelled
    # result, the file itself untouched.
    {:ok, session} = Session.load(sessions, id)

    assert [%{"role" => "user"}, %{"role" => "assistant"}, tool] = session.messages

    assert %{"role" => "tool", "tool_call_id" => "call_k", "content" => repair_json} = tool
    assert Jason.decode!(repair_json) == %{"ok" => false, "cancelled" => true}

    # A fresh agent adopts the repaired history; its first request carries
    # the original ids, the matching tool_call_ids, and the message order.
    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        resume: %{id: session.id, pin: session.pin, messages: session.messages}
      )

    send(resumed, {:prompt, self(), "continue"})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [
             %{"role" => "user", "content" => "write it"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => [resumed_call]},
             %{"role" => "tool", "tool_call_id" => "call_k", "content" => content},
             %{"role" => "user", "content" => "continue"}
           ] = request_messages(body)

    assert resumed_call == call
    assert Jason.decode!(content) == %{"ok" => false, "cancelled" => true}

    assert_receive {:phase, :idle}, 2_000

    # The next save rewrites the same file under the same id.
    assert session_id(sessions) == id

    {:ok, next} = Session.load(sessions, id)
    assert length(next.messages) == 5
    assert List.last(next.messages)["content"] == "picked up where we left off"
  end

  @tag :tmp_dir
  test "a cross-profile resume keeps the original pin on the next save", ctx do
    # ADR 0014 test plan 10: the active provider's identity differs from the
    # pinned one, yet the session's pin is immutable — the next save rewrites
    # the file under the original pin, never the active provider's.
    server = start_server([final_episode("continued")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    original_pin = %{profile: "work", model: "other-model", base_url: "https://pinned.example/v1"}

    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        resume: %{
          id: "20261001-000000-aabbcc",
          pin: original_pin,
          messages: [%{"role" => "user", "content" => "earlier"}]
        }
      )

    send(resumed, {:prompt, self(), "continue"})
    assert_receive {:phase, :idle}, 2_000

    {:ok, saved} = Session.load(sessions, "20261001-000000-aabbcc")
    assert saved.pin == original_pin
  end

  @tag :tmp_dir
  test "a resumed agent writes the hand-off's created_at verbatim on its first save", ctx do
    server = start_server([final_episode("resumed fine")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        resume: %{
          id: "20261001-000000-aabbcc",
          created_at: "2026-10-01T00:00:00Z",
          pin: %{profile: nil, model: "test-model", base_url: SSEServer.base_url(server)},
          messages: [%{"role" => "user", "content" => "earlier"}]
        }
      )

    send(resumed, {:prompt, self(), "continue"})
    assert_receive {:phase, :idle}, 2_000

    # The same file, under the adopted id, with the adopted created_at.
    assert session_id(sessions) == "20261001-000000-aabbcc"

    {:ok, session} = Session.load(sessions, "20261001-000000-aabbcc")
    assert session.created_at == "2026-10-01T00:00:00Z"

    assert session.messages == [
             %{"role" => "user", "content" => "earlier"},
             %{"role" => "user", "content" => "continue"},
             %{"role" => "assistant", "content" => "resumed fine"}
           ]
  end

  # The tool_call row is announced before the runner task is spawned; poll
  # until the supervisor holds it.
  defp await_task(sup, tries \\ 50) do
    case Task.Supervisor.children(sup) do
      [pid] -> pid
      [] when tries > 0 -> Process.sleep(10) && await_task(sup, tries - 1)
    end
  end

  # Everything the UI process received this test, in order.
  defp display_log(acc \\ []) do
    receive do
      msg
      when elem(msg, 0) in [:token, :usage, :phase, :entry, :tool_call, :tool_result, :confirm] ->
        display_log([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The display contract must be crash-free in the real UI process: fold every
  # message of the turn through State.stream_message. (The hostile review's
  # P1-1: an unparsed-arguments tool_call once crashed the render path while
  # the suite stayed green, because the test process never rendered.)
  defp contract_survives?(messages) do
    state =
      Enum.reduce(messages, State.new(test_mode: {80, 24}), fn msg, state ->
        State.stream_message(state, msg)
      end)

    state.phase == :idle
  end

  test "P2-3 regression: the no-provider notice carries the actual error (unknown --profile)" do
    # A static setup hint for a typo'd flag is a support dead-end; the
    # hard error's own text (valid names, never values) is the remedy.
    {:ok, sup} = Task.Supervisor.start_link()

    message =
      "profile \"ghost\" matches no profile in settings.json5 — valid profiles: work, personal"

    {:ok, agent} =
      Agent.start_link(
        provider: {:error, message},
        cwd: System.tmp_dir!(),
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "hello"})
    assert_receive {:entry, :system, text}, 500
    assert text =~ "no provider configured"
    assert text =~ "valid profiles: work, personal"
    assert text =~ "settings.json5"
  end

  test "the startup-phase handoff: {:set_provider, _} swaps the provider (ADR 0009)" do
    server = start_server([final_episode("after setup")])
    cwd = System.tmp_dir!()

    # Boots on the boot-time classification's error arm — like a forced
    # selection or onboarding state — then the setup completion delivers the
    # resolved provider (the UI's plain send, ADR 0009).
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider: {:error, "no profile selected — choose one to start"},
        cwd: cwd,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "too early"})
    assert_receive {:entry, :system, text}, 500
    assert text =~ "no provider"

    send(agent, {:set_provider, provider(server)})
    send(agent, {:prompt, self(), "after setup"})

    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    messages = request_messages(body)

    assert List.last(messages) == %{
             "role" => "user",
             "content" => "after setup"
           }
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

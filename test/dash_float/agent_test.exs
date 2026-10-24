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
  alias DashFloat.SSEServer

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
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
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
        name: nil
      )

    on_exit(fn ->
      if Process.alive?(agent), do: GenServer.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    {agent, sup}
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

  defp sandbox_file(ctx, relative), do: Path.join(ctx.tmp_dir, relative)

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
    assert_receive {:phase, :idle}, 2_000
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

    {agent, sup} = start_agent(server, ctx.tmp_dir, exec_timeout: 10_000)
    send(agent, {:prompt, self(), "run it"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:confirm, ref, %{name: "execute_command"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})

    assert_receive {:tool_call, %{id: "call_x"}}, 2_000
    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_x", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # Aborted: no second request re-prompts the model with a dead command.
    refute_receive {:sse_request, "POST", _, _, _second}, 300
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

    on_exit(fn -> if Process.alive?(agent), do: GenServer.stop(agent) end)

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

    on_exit(fn -> if Process.alive?(agent), do: GenServer.stop(agent) end)

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

  # The tool_call row is announced before the runner task is spawned; poll
  # until the supervisor holds it.
  defp await_task(sup, tries \\ 50) do
    case Task.Supervisor.children(sup) do
      [pid] -> pid
      [] when tries > 0 -> Process.sleep(10) && await_task(sup, tries - 1)
    end
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

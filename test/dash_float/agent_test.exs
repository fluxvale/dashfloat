defmodule AgentTestVetAllow do
  @moduledoc false
  @spec verdict(term(), term(), term(), term()) :: {:allow}
  def verdict(_provider, _call, _lines, _opts), do: {:allow}
end

defmodule AgentTestVetAsk do
  @moduledoc false
  @spec verdict(term(), term(), term(), term()) :: {:ask}
  def verdict(_provider, _call, _lines, _opts), do: {:ask}
end

defmodule AgentTestVetFail do
  @moduledoc false
  @spec verdict(term(), term(), term(), term()) :: {:error, String.t()}
  def verdict(_provider, _call, _lines, _opts), do: {:error, "boom"}
end

defmodule AgentTestVetGarbage do
  @moduledoc false
  # Out of contract on purpose: none of {:allow}/{:ask}/{:error, _}. The
  # agent must fail safe to confirm — never crash the batch (ADR 0016 §6).
  @spec verdict(term(), term(), term(), term()) :: :run
  def verdict(_provider, _call, _lines, _opts), do: :run
end

defmodule AgentTestVetParked do
  @moduledoc false
  # Parks until messaged — the agent's cancel is the message that resolves it.
  @spec verdict(term(), term(), term(), term()) :: {:ask}
  def verdict(_provider, _call, _lines, _opts) do
    receive do
      _any -> {:ask}
    end
  end
end

defmodule AgentTestVetParkedAllow do
  @moduledoc false
  # Parks until messaged — an injected message releases an {:allow} verdict,
  # so a test can switch the session mode while the check is in flight.
  def verdict(_provider, _call, _lines, _opts) do
    receive do
      _any -> {:allow}
    end
  end
end

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

  alias DashFloat.Accounting
  alias DashFloat.Agent
  alias DashFloat.Config
  alias DashFloat.Session
  alias DashFloat.SSEServer
  alias DashFloat.Synthetic
  alias DashFloat.TUI.State

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  defp usage_frame(total) when is_integer(total), do: usage_frame(10, 5, total)

  defp usage_frame({prompt, completion, total}), do: usage_frame(prompt, completion, total)

  defp usage_frame(prompt, completion, total) do
    ~s(data: {"choices":[],"usage":{"prompt_tokens":#{prompt},"completion_tokens":#{completion},"total_tokens":#{total}}}\n\n)
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

  # A third parallel call on index 2.
  defp tool_frames_2(id, name, arg_fragments) do
    opening =
      ~s(data: {"choices":[{"index":2,"delta":{"tool_calls":[{"index":2,"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)

    rest =
      for frag <- arg_fragments do
        ~s(data: {"choices":[{"index":2,"delta":{"tool_calls":[{"index":2,"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
      end

    [opening | rest]
  end

  defp call_tool_episode(id, name, args, opts \\ []) do
    frames = tool_frames(id, name, [Jason.encode!(args)])
    prefix = Keyword.get(opts, :prefix, [])
    suffix = if usage = opts[:usage], do: [usage_frame(usage)], else: []

    [{:send, [@headers | prefix ++ frames ++ suffix]}, {:send, "data: [DONE]\n\n"}, :close]
  end

  # A content frame whose payload carries quotes: Jason escapes it, where
  # frame/1's raw interpolation would break the delta's JSON.
  defp json_frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":#{Jason.encode!(content)}}}]}\n\n)
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

  # A pinned Synthetic context aimed at the loopback server (the ADR 0021 §2
  # test seam): repairs ride the same server's next scripted connection.
  defp synthetic_ctx(server) do
    %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}
  end

  # The repair endpoint's 200 responses (Req pre-decodes application/json).
  defp repair_ok(fixed) do
    content = Jason.encode!(%{"success" => true, "fixed" => fixed})
    body = Jason.encode!(%{choices: [%{message: %{content: content}}]})

    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  defp repair_failure do
    body = Jason.encode!(%{choices: [%{message: %{content: ~s({"success": false})}}]})

    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  defp provider(server) do
    {:ok,
     %Config{
       base_url: SSEServer.base_url(server),
       model: "test-model",
       api_key: "test-key-123",
       # The auto-title side-request is opted out suite-wide (#80): only the
       # title tests below opt in, so no other test's server script count or
       # request order gains a side-request connection.
       auto_title: false
     }}
  end

  # A provider carrying an explicit context window (ADR 0022 §2); the arity-1
  # helper keeps `context_tokens` nil — no window, nothing compacts.
  defp provider(server, context_tokens) do
    {:ok,
     %Config{
       base_url: SSEServer.base_url(server),
       model: "test-model",
       api_key: "test-key-123",
       context_tokens: context_tokens,
       auto_title: false
     }}
  end

  defp start_agent(server, cwd, opts \\ []) do
    # A per-test supervisor: the agent's stream/runner tasks land here, so
    # tests can enumerate them without leftovers from other tests.
    {:ok, sup} = Task.Supervisor.start_link()

    base = [
      provider: Keyword.get(opts, :provider, provider(server)),
      cwd: cwd,
      exec_timeout: Keyword.get(opts, :exec_timeout, 500),
      supervisor: sup,
      session_dir: Keyword.get(opts, :session_dir),
      resume: Keyword.get(opts, :resume),
      title: Keyword.get(opts, :title),
      title_fetcher: Keyword.get(opts, :title_fetcher),
      name: nil
    ]

    {:ok, agent} =
      base
      |> Keyword.merge(Keyword.take(opts, [:mode, :vetter, :vet_timeout, :synthetic]))
      |> Agent.start_link()

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

  # The AGENT's own id/file, for dirs that also hold pre-written holder
  # files (the collision and rename tests).
  defp own_id(agent), do: :sys.get_state(agent).session_id

  defp load_own_session(dir, agent) do
    {:ok, session} = Session.load(dir, own_id(agent))
    session
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

  # The session-start system message (ADR 0019) rides every request and
  # every persisted transcript. Its content is cwd/git dependent, so tests
  # assert its presence and shape, never its bytes — the accounting-driven
  # ones measure its weight where the window tuning matters. The discovery
  # rides along: the sandboxes live inside this repo, so the live prompt
  # picks up the repo's own AGENTS.md and the mirror must too. Load-bearing:
  # the sandbox writes stay under /tmp/, which .gitignore excludes — tracked
  # writes would flip the git line between this mirror's probe and the
  # agent's and break the byte-equality asserts below.
  defp system_message(cwd) do
    %{
      "role" => "system",
      "content" =>
        DashFloat.SystemPrompt.build(cwd,
          project_instructions: DashFloat.ProjectInstructions.load(cwd)
        )
    }
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

    send(agent, {:prompt, self(), "create the file", []})
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
             %{"role" => "system", "content" => _system_prompt},
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
  test "the first request message is the session system prompt", ctx do
    server = start_server([final_episode()])
    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [%{"role" => "system", "content" => content} | _rest] = request_messages(body)
    assert content =~ "You are DashFloat"
    assert content =~ "Working directory:"
  end

  @tag :tmp_dir
  test "a fresh session's system prompt carries the discovered AGENTS.md files", ctx do
    # A .git marker one level up stops the walk; the repo's own AGENTS.md,
    # further above, must NOT ride along (ADR 0019).
    root = Path.join(ctx.tmp_dir, "root")
    proj = Path.join(root, "proj")
    git_marker = Path.join(root, ".git")
    File.mkdir_p!(proj)
    File.mkdir_p!(git_marker)

    agents = Path.join(proj, "AGENTS.md")
    File.write!(agents, "always answer with a haiku\n")

    server = start_server([final_episode()])
    {agent, _sup} = start_agent(server, proj)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [%{"role" => "system", "content" => content} | _rest] = request_messages(body)
    assert content =~ "always answer with a haiku"
    assert content =~ "--- #{agents} ---"
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
    send(agent, {:prompt, self(), "write it", []})
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
    send(agent, {:prompt, self(), "read it", []})
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
    send(agent, {:prompt, self(), "read outside", []})
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
    send(agent, {:prompt, self(), "write outside", []})
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
    send(agent, {:prompt, self(), "edit it", []})
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
    send(agent, {:prompt, self(), "misbehave", []})
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
    send(agent, {:prompt, self(), "call it", []})
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

  ## Synthetic fix-json repair through the real agent (ADR 0021)

  @tag :tmp_dir
  test "a synthetic ctx repairs malformed arguments at the stream terminal and the turn proceeds",
       ctx do
    write_sandbox(ctx, "a.txt", "hello contents\n")

    # The args fragment is truncated mid-JSON: finish/1 must see it raw.
    broken = ~s({"path": "a.txt)
    frames = tool_frames("call_1", "read_file", [broken])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        [{:send, repair_ok(%{"path" => "a.txt"})}, :close],
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, synthetic: synthetic_ctx(server))
    send(agent, {:prompt, self(), "read it", []})

    # conn 0: the episode with the broken call.
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    # conn 1: the repair POST — Octofriend's contract, the raw broken string.
    assert_receive {:sse_request, "POST", "/chat/completions", repair_headers, repair_body},
                   2_000

    assert repair_headers["authorization"] == "Bearer test-key-123"

    decoded = Jason.decode!(repair_body)
    assert decoded["model"] == "hf:syntheticlab/fix-json"

    assert [%{"role" => "user", "content" => prompt}] = decoded["messages"]
    assert prompt =~ broken
    assert prompt =~ "Here's the string:\n"

    # The repair becomes a real read; the UI sees the successful tool result.
    assert_receive {:tool_result, %{id: "call_1", name: "read_file", ok: true}}, 2_000

    # conn 2: the next episode carries the REPAIRED arguments and the file.
    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    messages = request_messages(second_body)

    assert %{"role" => "assistant", "tool_calls" => [call]} = Enum.at(messages, -2)
    assert call["function"]["name"] == "read_file"
    assert call["function"]["arguments"] == ~s({"path":"a.txt"})

    assert %{"content" => result_json} = tool_result_message(messages, "call_1")
    assert %{"ok" => true, "content" => "hello contents"} = Jason.decode!(result_json)

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a failed repair degrades to exactly the no-key error result", ctx do
    frames = tool_frames("call_bad", "read_file", ["{\"path\": "])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        [{:send, repair_failure()}, :close],
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, synthetic: synthetic_ctx(server))
    send(agent, {:prompt, self(), "call it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_bad", ok: false}}, 2_000

    # conn 1 was the repair; conn 2 is the follow-up episode.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _repair_request}, 2_000

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
    messages = request_messages(second_body)

    assert %{"role" => "assistant", "tool_calls" => [call]} = Enum.at(messages, -2)
    assert call["function"]["arguments"] == "{}"

    assert %{"content" => result_json} = tool_result_message(messages, "call_bad")
    assert Jason.decode!(result_json) == %{"ok" => false, "error" => "invalid JSON arguments"}

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "Esc during a repair POST still cancels the turn", ctx do
    frames = tool_frames("call_1", "read_file", ["{\"path\": "])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        [{:sleep, 200}, {:send, repair_ok(%{"path" => "a.txt"})}, :close]
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, synthetic: synthetic_ctx(server))
    send(agent, {:prompt, self(), "call it", []})

    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    # The repair request is in flight; cancel lands inside it.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _repair_request}, 2_000
    send(agent, {:cancel})

    assert_receive {:entry, :system, "[cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  test "a pinned synthetic ctx survives a provider swap" do
    server = start_server([final_episode()])
    cwd = System.tmp_dir!()

    {agent, _sup} =
      start_agent(server, cwd,
        synthetic: %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "sk-pin"}
      )

    # A pinned context never moves (ADR 0021 §2) — even to a Synthetic host.
    send(agent, {:set_provider, provider(server)})

    assert :sys.get_state(agent).synthetic ==
             %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "sk-pin"}

    assert :sys.get_state(agent).synthetic_pinned? == true
  end

  test "an explicit nil synthetic opt is pinned off; :discover re-resolves on a swap" do
    server = start_server([final_episode()])
    cwd = System.tmp_dir!()

    {agent, _sup} = start_agent(server, cwd, synthetic: nil)
    assert :sys.get_state(agent).synthetic == nil
    assert :sys.get_state(agent).synthetic_pinned? == true

    # The default :discover arm: a loopback provider resolves to nil, and a
    # swap to a Synthetic host re-resolves to a live context.
    {discovering, _sup} = start_agent(server, cwd)

    assert :sys.get_state(discovering).synthetic == nil
    assert :sys.get_state(discovering).synthetic_pinned? == false

    synthetic_provider =
      {:ok,
       %Config{base_url: "https://api.synthetic.new/v1", model: "m", api_key: "test-key-123"}}

    send(discovering, {:set_provider, synthetic_provider})

    assert :sys.get_state(discovering).synthetic ==
             %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "test-key-123"}
  end

  ## web_search: advertisement and the safe-class round trip (ADR 0021 §§6–8)

  @tag :tmp_dir
  test "web_search is advertised only with a synthetic context", ctx do
    server = start_server([final_episode("with key"), final_episode("without key")])

    {pinned, _sup} = start_agent(server, ctx.tmp_dir, synthetic: synthetic_ctx(server))

    send(pinned, {:prompt, self(), "search enabled", []})
    assert_receive {:sse_request, "POST", _, _, with_body}, 2_000

    names =
      with_body
      |> Jason.decode!()
      |> Map.fetch!("tools")
      |> Enum.map(& &1["function"]["name"])

    assert names == [
             "read_file",
             "write_file",
             "edit_file",
             "execute_command",
             "list_directory",
             "web_search"
           ]

    # No :synthetic opt: discovery finds nothing on a loopback host — the
    # advertised array stays the base five.
    {plain, _sup} = start_agent(server, ctx.tmp_dir)

    send(plain, {:prompt, self(), "search disabled", []})
    assert_receive {:sse_request, "POST", _, _, without_body}, 2_000

    plain_names =
      without_body
      |> Jason.decode!()
      |> Map.fetch!("tools")
      |> Enum.map(& &1["function"]["name"])

    assert plain_names == [
             "read_file",
             "write_file",
             "edit_file",
             "execute_command",
             "list_directory"
           ]

    assert_receive {:phase, :idle}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "web_search runs with no confirmation and lands its results in context", ctx do
    entries = [
      %{"url" => "https://elixir-lang.org", "title" => "Elixir", "highlights" => ["a"]},
      %{"url" => "https://hex.pm", "highlights" => ["dashfloat"]}
    ]

    body = Jason.encode!(%{"results" => entries})

    search_ok =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    server =
      start_server([
        call_tool_episode("call_s", "web_search", %{"query" => "dashfloat elixir"}),
        [{:send, search_ok}, :close],
        final_episode("searched")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, synthetic: synthetic_ctx(server))
    send(agent, {:prompt, self(), "search it", []})

    # conn 0: the episode announcing the search call.
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    # conn 1: the search POST — the derived endpoint, the Bearer key, the query.
    assert_receive {:sse_request, "POST", "/v2/search", search_headers, search_body}, 2_000
    assert search_headers["authorization"] == "Bearer test-key-123"
    assert Jason.decode!(search_body) == %{"query" => "dashfloat elixir"}

    # The :safe class: announced, dispatched, no keypress — default :build mode.
    assert_receive {:tool_call,
                    %{id: "call_s", name: "web_search", args: %{"query" => "dashfloat elixir"}}},
                   2_000

    rendered = Enum.map_join(entries, "\n", &Jason.encode!/1)
    assert_receive {:tool_result, %{id: "call_s", ok: true, output: ^rendered}}, 2_000
    refute_received {:confirm, _ref, _preview}

    # conn 2: the next episode carries the rendered lines as the tool message.
    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} = tool_result_of(second_body, "call_s")

    assert %{
             "ok" => true,
             "query" => "dashfloat elixir",
             "content" => ^rendered,
             "count" => 2
           } = Jason.decode!(result_json)

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a pinned ctx with unusable fields degrades web_search to not configured, no crash", ctx do
    # A hand-pinned struct may hold nil fields (M7): the guard turns it into
    # "not configured" instead of crashing the agent mid-turn.
    server =
      start_server([
        call_tool_episode("call_u", "web_search", %{"query" => "anything"}),
        final_episode("noted")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, synthetic: %Synthetic{})
    send(agent, {:prompt, self(), "search anyway", []})

    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_u", ok: false, status: status}}, 2_000
    assert status =~ "web search is not configured"

    # The turn continues to the next episode.
    assert_receive {:sse_request, "POST", _, _, _second}, 4_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a hallucinated web_search without a key errors honestly and the turn continues", ctx do
    server =
      start_server([
        call_tool_episode("call_h", "web_search", %{"query" => "anything"}),
        final_episode("noted")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)
    send(agent, {:prompt, self(), "search anyway", []})

    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_h", ok: false, status: status}}, 2_000
    assert status =~ "web search is not configured"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} = tool_result_of(second_body, "call_h")

    assert Jason.decode!(result_json) == %{
             "ok" => false,
             "error" => "web search is not configured"
           }

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
    send(agent, {:prompt, self(), "copy it", []})
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
    send(agent, {:prompt, self(), "list", []})

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
    send(agent, {:prompt, self(), "read it", []})
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
    send(agent, {:prompt, self(), "hello", []})

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
    send(agent, {:prompt, self(), "run it", []})
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
    send(agent, {:prompt, self(), "run it", []})
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
    send(agent, {:prompt, self(), "go", []})
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
    send(agent, {:prompt, self(), "run it", []})
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
    send(agent, {:prompt, self(), "run it", []})
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
    send(agent, {:prompt, self(), "run it", []})
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
    send(agent, {:prompt, self(), "hello", []})

    assert_receive {:token, "kept"}, 2_000

    stream = await_task(sup)
    Process.exit(stream, :boom)

    assert_receive {:entry, :system, "[stream failed: :boom]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  ## Modes: the agent gate and the vetting state machine (ADR 0016)

  @tag :tmp_dir
  test "unchained runs a mutating tool with no confirmation", ctx do
    args = %{"path" => "out/free.txt", "content" => "unchained"}

    server =
      start_server([
        call_tool_episode("call_u", "write_file", args),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :unchained)
    send(agent, {:prompt, self(), "write it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    # The receipt lands without arming a confirmation and without a check.
    assert_receive {:tool_preview, %{id: "call_u", name: "write_file", lines: lines}}, 2_000
    assert Enum.any?(lines, &String.contains?(&1, "free.txt"))

    assert_receive {:tool_result, %{id: "call_u", ok: true}}, 2_000
    assert read_sandbox(ctx, "out/free.txt") == "unchained"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"ok" => true, "bytes" => 9, "created" => true} =
             second_body
             |> tool_result_of("call_u")
             |> Map.fetch!("content")
             |> Jason.decode!()

    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}
    refute_received {:phase, :checking}
  end

  @tag :tmp_dir
  test "auto runs when the vetter allows: checking phase, receipt, no confirm", ctx do
    server =
      start_server([
        call_tool_episode("call_a", "execute_command", %{"command" => "echo vet-ran"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetAllow)
    send(agent, {:prompt, self(), "run it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:phase, :checking}, 2_000
    assert_receive {:tool_preview, %{id: "call_a", name: "execute_command"}}, 2_000

    assert_receive {:tool_result, %{id: "call_a", ok: true, output: output}}, 2_000
    assert output =~ "vet-ran"

    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}
  end

  @tag :tmp_dir
  test "auto confirms when the vetter asks: nothing runs before approval", ctx do
    server =
      start_server([
        call_tool_episode("call_s", "execute_command", %{"command" => "touch asked.txt"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetAsk)
    send(agent, {:prompt, self(), "run it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:entry, :system, "[safety check: needs confirmation]"}, 2_000
    assert_receive {:confirm, ref, %{id: "call_s"}}, 2_000
    refute sandbox_exists?(ctx, "asked.txt")

    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:tool_result, %{id: "call_s", ok: true}}, 2_000
    assert sandbox_exists?(ctx, "asked.txt")
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a failed check degrades to confirm: auto never becomes unchained", ctx do
    server =
      start_server([
        call_tool_episode("call_f", "execute_command", %{"command" => "touch failed.txt"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetFail)
    send(agent, {:prompt, self(), "run it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:entry, :system, "[safety check unavailable — confirming]"}, 2_000
    assert_receive {:confirm, ref, %{id: "call_f"}}, 2_000
    refute sandbox_exists?(ctx, "failed.txt")

    send(agent, {:confirm_decision, ref, :rejected})
    assert_receive {:tool_result, %{id: "call_f", ok: false, status: "rejected"}}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute sandbox_exists?(ctx, "failed.txt")
  end

  @tag :tmp_dir
  test "an out-of-contract verdict fails safe: confirm with the unavailable entry, no crash",
       ctx do
    server =
      start_server([
        call_tool_episode("call_g", "execute_command", %{"command" => "touch garbage.txt"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetGarbage)
    send(agent, {:prompt, self(), "run it", []})
    assert_receive {:phase, :checking}, 2_000

    # The garbage verdict may neither run the call nor kill the GenServer:
    # the fail-safe arms the confirm, the entry naming what happened.
    assert_receive {:entry, :system, "[safety check unavailable — confirming]"}, 2_000
    assert_receive {:confirm, ref, %{id: "call_g"}}, 2_000
    refute sandbox_exists?(ctx, "garbage.txt")

    send(agent, {:confirm_decision, ref, :rejected})
    assert_receive {:tool_result, %{id: "call_g", ok: false, status: "rejected"}}, 2_000
    assert_receive {:phase, :idle}, 2_000
    assert Process.alive?(agent)
  end

  test "a fabricated vet_done while idle is ignored, never dispatched" do
    server = start_server([final_episode("unused")])
    {agent, _sup} = start_agent(server, System.tmp_dir!(), mode: :auto, vetter: AgentTestVetAllow)

    send(agent, {:vet_done, make_ref(), "nope", {:allow}})

    refute_receive {:tool_preview, _preview}, 200
    refute_receive {:phase, _phase}, 200
    refute_receive {:sse_request, "POST", _, _, _body}, 200
    assert Process.alive?(agent)
  end

  @tag :tmp_dir
  test "Esc during a check cancels the batch and stays round-trippable", ctx do
    frames =
      tool_frames("call_v", "execute_command", [~s({"command":"echo vet-ran"})]) ++
        tool_frames_1("call_q", "read_file", [~s({"path":"never.txt"})])

    server = start_server([[{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close]])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParked)

    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_v", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The transcript answers every announced call — no dangling tool_calls.
    tool_messages =
      agent
      |> :sys.get_state()
      |> Map.fetch!(:messages)
      |> Enum.filter(&(&1.role == "tool"))

    assert length(tool_messages) == 2

    for id <- ["call_v", "call_q"] do
      assert %{"ok" => false, "cancelled" => true} =
               tool_messages
               |> Enum.find(&(&1.tool_call_id == id))
               |> Map.fetch!(:content)
               |> Jason.decode!()
    end
  end

  @tag :tmp_dir
  test "Esc during a check aborts promptly — via the vetter's cancel, not its timeout", ctx do
    server =
      start_server([call_tool_episode("call_pc", "execute_command", %{"command" => "echo x"})])

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        mode: :auto,
        vetter: AgentTestVetParked,
        vet_timeout: 10_000
      )

    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:cancel})

    # The parked vetter can only exit by unblocking on the agent's forwarded
    # cancel: its death within this tight bound is the wiring's work — not
    # the 10 s deadline's, and not any-message luck.
    assert dead_within?(vet, 100)

    assert_receive {:tool_result, %{id: "call_pc", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a vetter killed mid-check degrades to confirm — the DOWN fail-safe", ctx do
    server =
      start_server([
        call_tool_episode("call_kd", "execute_command", %{"command" => "touch downed.txt"})
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParked)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    agent
    |> vetting_pid()
    |> Process.exit(:kill)

    assert_receive {:entry, :system, "[safety check unavailable — confirming]"}, 2_000
    assert_receive {:confirm, ref, %{id: "call_kd"}}, 2_000
    refute sandbox_exists?(ctx, "downed.txt")

    # The armed confirm still completes the batch normally.
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:tool_result, %{id: "call_kd", ok: true}}, 2_000
    assert sandbox_exists?(ctx, "downed.txt")
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a vetter killed after Esc aborts the batch with cancelled results", ctx do
    server =
      start_server([call_tool_episode("call_kq", "execute_command", %{"command" => "echo x"})])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParked)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:cancel})
    Process.exit(vet, :kill)

    # Whether the released report or the DOWN lands first, the batch aborts
    # exactly once.
    assert_receive {:tool_result, %{id: "call_kq", status: "cancelled"}}, 2_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute_receive {:tool_result, %{id: "call_kq"}}, 300
  end

  ## Mid-check mode switches: the gate is re-read at resolution (ADR 0016 §3)

  @tag :tmp_dir
  test "auto→plan mid-check: an allow verdict proposes, never executes", ctx do
    args = %{"path" => "out/late.txt", "content" => "must not land"}

    server =
      start_server([
        call_tool_episode("call_pl", "write_file", args),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParkedAllow)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:set_mode, self(), :plan})
    assert_receive {:mode, :plan}, 2_000
    send(vet, :release)

    # The stale allow may not write in plan: proposed, not executed.
    assert_receive {:tool_preview, %{id: "call_pl", name: "write_file"}}, 2_000
    assert_receive {:tool_result, %{id: "call_pl", ok: false, status: "proposed (plan)"}}, 2_000
    refute sandbox_exists?(ctx, "out/late.txt")
    refute_received {:confirm, _ref, _preview}

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert Jason.decode!(tool_result_of(second_body, "call_pl")["content"]) ==
             %{"ok" => false, "blocked" => "plan"}

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "auto→build mid-check: an allow verdict arms the confirm — no run without the keypress",
       ctx do
    server =
      start_server([
        call_tool_episode("call_bw", "write_file", %{"path" => "out/late.txt", "content" => "ok"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParkedAllow)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:set_mode, self(), :build})
    assert_receive {:mode, :build}, 2_000
    send(vet, :release)

    # The stale allow may not run without the keypress the new mode demands:
    # the confirm arms, with NO safety-check entry (nothing asked, nothing
    # failed).
    assert_receive {:confirm, ref, %{id: "call_bw"}}, 2_000
    refute sandbox_exists?(ctx, "out/late.txt")
    refute_received {:entry, :system, "[safety check" <> _}

    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:tool_result, %{id: "call_bw", ok: true}}, 2_000
    assert read_sandbox(ctx, "out/late.txt") == "ok"
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "auto→build mid-check: a vetter death confirms with the unavailable entry", ctx do
    server =
      start_server([
        call_tool_episode("call_bd", "execute_command", %{"command" => "touch never.txt"})
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParked)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:set_mode, self(), :build})
    assert_receive {:mode, :build}, 2_000
    Process.exit(vet, :kill)

    # The failure resolves under the NEW gate — build's confirm — with the
    # entry naming what happened.
    assert_receive {:entry, :system, "[safety check unavailable — confirming]"}, 2_000
    assert_receive {:confirm, ref, %{id: "call_bd"}}, 2_000
    refute sandbox_exists?(ctx, "never.txt")

    send(agent, {:confirm_decision, ref, :rejected})
    assert_receive {:tool_result, %{id: "call_bd", ok: false, status: "rejected"}}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "auto→unchained mid-check: an ask verdict dispatches, arms no confirm", ctx do
    server =
      start_server([
        call_tool_episode("call_uw", "write_file", %{"path" => "out/free.txt", "content" => "go"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto, vetter: AgentTestVetParked)
    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :checking}, 2_000

    vet = vetting_pid(agent)
    send(agent, {:set_mode, self(), :unchained})
    assert_receive {:mode, :unchained}, 2_000
    send(vet, :release)

    # Unchained can never enter :confirming: the ask degrades to a plain
    # dispatch — the receipt lands, the tool runs, no keypress, no check
    # entry (ADR 0016 §3).
    assert_receive {:tool_preview, %{id: "call_uw"}}, 2_000
    assert_receive {:tool_result, %{id: "call_uw", ok: true}}, 2_000
    assert read_sandbox(ctx, "out/free.txt") == "go"
    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}
    refute_received {:entry, :system, "[safety check" <> _}
  end

  @tag :tmp_dir
  test "auto end-to-end with the real vetter: the recorded verdict drives dispatch", ctx do
    vet_reply = ~s({"decision":"run","reason":"echo is reversible"})

    server =
      start_server([
        call_tool_episode("call_rv", "execute_command", %{"command" => "echo real-vet"}),
        [{:send, [@headers, json_frame(vet_reply)]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :auto)
    send(agent, {:prompt, self(), "run it", []})
    assert_receive {:sse_request, "POST", _, _, _model_first}, 2_000

    # The vet is a fresh-context completion: its request carries the static
    # instruction and the call payload, never the conversation.
    assert_receive {:phase, :checking}, 2_000
    assert_receive {:sse_request, "POST", _, _, vet_body}, 2_000
    assert vet_body =~ "safety check"
    assert vet_body =~ "execute_command"
    refute vet_body =~ "run it"

    assert_receive {:tool_preview, %{id: "call_rv", name: "execute_command"}}, 2_000

    assert_receive {:tool_result, %{id: "call_rv", ok: true, output: output}}, 2_000
    assert output =~ "real-vet"
    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}
  end

  @tag :tmp_dir
  test "plan proposes a mutation: previewed, never run, blocked result", ctx do
    write_sandbox(ctx, "seed.txt", "before\n")

    args = %{"path" => "seed.txt", "search_block" => "before", "replace_block" => "after"}

    server =
      start_server([
        call_tool_episode("call_p", "edit_file", args),
        final_episode("proposed it")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :plan)
    send(agent, {:prompt, self(), "edit it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_preview, %{id: "call_p", name: "edit_file"}}, 2_000
    assert_receive {:tool_result, %{id: "call_p", ok: false, status: "proposed (plan)"}}, 2_000

    assert read_sandbox(ctx, "seed.txt") == "before\n"

    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert %{"content" => result_json} = tool_result_of(second_body, "call_p")
    assert Jason.decode!(result_json) == %{"ok" => false, "blocked" => "plan"}

    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}
  end

  @tag :tmp_dir
  test "plan still runs safe tools", ctx do
    write_sandbox(ctx, "notes.md", "readable\n")

    server =
      start_server([
        call_tool_episode("call_pr", "read_file", %{"path" => "notes.md"}),
        final_episode()
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir, mode: :plan)
    send(agent, {:prompt, self(), "read it", []})

    assert_receive {:tool_result, %{id: "call_pr", ok: true, output: output}}, 2_000
    assert output =~ "readable"
    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "set_mode echoes, logs, and moves the gate; an invalid mode only logs", ctx do
    server =
      start_server([
        call_tool_episode("call_sm", "write_file", %{"path" => "switched.txt", "content" => "x"}),
        final_episode("done")
      ])

    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:set_mode, self(), :unchained})
    assert_receive {:mode, :unchained}, 2_000
    assert_receive {:entry, :system, "[mode: Build → Unchained]"}, 2_000

    # The next mutating call runs on the new mode's gate: no confirmation.
    send(agent, {:prompt, self(), "write it", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    assert_receive {:tool_result, %{id: "call_sm", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000
    refute_received {:confirm, _ref, _preview}

    # An invalid mode gets the naming entry, no echo, no change.
    send(agent, {:set_mode, self(), :yolo})
    assert_receive {:entry, :system, "unknown mode: :yolo (plan, build, auto, unchained)"}, 2_000
    refute_received {:mode, _mode}
    assert %{mode: :unchained} = :sys.get_state(agent)
  end

  test "an invalid :mode start opt raises ArgumentError" do
    assert_raise ArgumentError, ~r/unknown mode/, fn ->
      Agent.start_link(provider: {:error, "unused"}, mode: :yolo, name: nil)
    end
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

    send(agent, {:prompt, self(), "hello", []})

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

    send(agent, {:prompt, self(), "hello", []})

    assert_receive {:entry, :system, text}, 1_000
    assert text =~ "[llm: no provider configured"
    assert text =~ "DASHFLOAT_API_KEY"
    assert_receive {:phase, :idle}, 1_000
  end

  test "an empty reply degrades to a system entry" do
    server = start_server([[{:send, [@headers, "data: [DONE]\n\n"]}, :close]])
    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:prompt, self(), "hello", []})

    assert_receive {:entry, :system, "[model returned nothing]"}, 2_000
    assert_receive {:phase, :idle}, 2_000
  end

  test "a prompt while busy is ignored; a stale confirmation decision is ignored" do
    server =
      start_server([
        [{:send, [@headers, frame("hi")]}, {:sleep, 60_000}, {:wait_close, 1_000}]
      ])

    {agent, _sup} = start_agent(server, System.tmp_dir!())
    send(agent, {:prompt, self(), "first", []})
    assert_receive {:token, "hi"}, 2_000
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    send(agent, {:prompt, self(), "second", []})
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

    send(agent, {:prompt, self(), "read it", []})
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

    assert [
             %{"role" => "system", "content" => system_content} | transcript
           ] = session.messages

    assert system_content =~ "You are DashFloat"

    assert transcript == [
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

    send(agent, {:prompt, self(), "create the file", []})
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
               %{"role" => "system"},
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

    assert [%{"role" => "system"}, %{"role" => "user"}, %{"role" => "assistant"}, tool, final] =
             session.messages

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
        provider:
          {:ok,
           %Config{
             base_url: leaked_url,
             model: "test-model",
             api_key: "k",
             auto_title: false
           }},
        cwd: ctx.tmp_dir,
        session_dir: sessions,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    id = session_id(sessions)
    {:ok, session} = Session.load(sessions, id)

    # The pin is the query-free endpoint; the secret reaches neither.
    assert session.pin.base_url == SSEServer.base_url(server)

    session_path = Path.join(sessions, id <> ".json")
    bytes = File.read!(session_path)
    refute bytes =~ secret
    refute bytes =~ "api_key"

    ## The unparsable fallback: a base_url URI.parse cannot split into
    ## scheme+host pins the RAW string — endpoint identity as given, never
    ## mangled. The turn cannot stream, but the prompt-time save already
    ## pinned the endpoint.
    raw_sessions = Path.join(ctx.tmp_dir, "raw-sessions")

    {:ok, raw_sup} = Task.Supervisor.start_link()

    {:ok, raw_agent} =
      Agent.start_link(
        provider: {:ok, %Config{base_url: "not-a-url", model: "test-model", api_key: "k"}},
        cwd: ctx.tmp_dir,
        session_dir: raw_sessions,
        supervisor: raw_sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(raw_agent)
      if Process.alive?(raw_sup), do: Process.exit(raw_sup, :kill)
    end)

    send(raw_agent, {:prompt, self(), "hello", []})
    assert_receive {:entry, :system, failure}, 2_000
    assert failure =~ "llm:"
    assert_receive {:phase, :idle}, 2_000

    raw_id = session_id(raw_sessions)
    assert {:ok, raw_session} = Session.load(raw_sessions, raw_id)
    assert raw_session.pin.base_url == "not-a-url"
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

    send(agent, {:prompt, self(), "run both", []})
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
             %{"role" => "system"},
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
  test "a batch of call_1/call_1/call_1-2 renames to distinct ids that load", ctx do
    # The third call's ORIGINAL id is exactly the second call's rename: a
    # counter-only rename would produce [call_1, call_1-2, call_1-2] — a
    # file load refuses and the model gets two answers under one id. The
    # used-id-set rename continues the sequence instead: [call_1, call_1-2,
    # call_1-3].
    write_sandbox(ctx, "notes.md", "seed\n")

    frames =
      tool_frames("call_1", "read_file", [~s({"path":"notes.md"})]) ++
        tool_frames_1("call_1", "list_directory", [~s({"path":"."})]) ++
        tool_frames_2("call_1-2", "read_file", [~s({"path":"notes.md"})])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode("three done")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "run all three", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "call_1", ok: true}}, 2_000
    assert_receive {:tool_result, %{id: "call_1-2", ok: true}}, 2_000
    assert_receive {:tool_result, %{id: "call_1-3", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    id = session_id(sessions)

    # The persisted file carries the three distinct ids and LOADS — a
    # duplicate would refuse at load (ADR 0014 §4).
    assert {:ok, session} = Session.load(sessions, id)

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
             tool_a,
             tool_b,
             tool_c,
             %{"role" => "assistant", "content" => "three done"}
           ] = session.messages

    assert Enum.map(calls, & &1["id"]) == ["call_1", "call_1-2", "call_1-3"]

    assert Enum.map([tool_a, tool_b, tool_c], & &1["tool_call_id"]) == [
             "call_1",
             "call_1-2",
             "call_1-3"
           ]
  end

  @tag :tmp_dir
  test "a colliding id that is itself a rename form with an unused base continues its own name",
       ctx do
    # ["dup-2", "dup-2"]: the second dup-2 collides, but its base "dup" was
    # never announced — the sequence continues on the id itself (dup-2-2),
    # not on the never-used base.
    write_sandbox(ctx, "notes.md", "seed\n")

    frames =
      tool_frames("dup-2", "read_file", [~s({"path":"notes.md"})]) ++
        tool_frames_1("dup-2", "list_directory", [~s({"path":"."})])

    server =
      start_server([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        final_episode("pair done")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "run the pair", []})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000

    assert_receive {:tool_result, %{id: "dup-2", ok: true}}, 2_000
    assert_receive {:tool_result, %{id: "dup-2-2", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    id = session_id(sessions)
    assert {:ok, session} = Session.load(sessions, id)

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
             tool_a,
             tool_b,
             %{"role" => "assistant", "content" => "pair done"}
           ] = session.messages

    assert Enum.map(calls, & &1["id"]) == ["dup-2", "dup-2-2"]
    assert Enum.map([tool_a, tool_b], & &1["tool_call_id"]) == ["dup-2", "dup-2-2"]
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

    send(agent, {:prompt, self(), "go", []})
    assert_receive {:confirm, ref, %{id: "call_run"}}, 2_000
    send(agent, {:confirm_decision, ref, :approved})
    assert_receive {:phase, :executing_tool}, 1_000

    send(agent, {:cancel})

    assert_receive {:tool_result, %{id: "call_run", status: "cancelled"}}, 3_000
    assert_receive {:entry, :system, "[tool run cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    {:ok, session} = Session.load(sessions, session_id(sessions))

    assert [
             %{"role" => "system"},
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

    send(agent, {:prompt, self(), "hello", []})

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

    send(agent, {:prompt, self(), "read it", []})
    assert_receive {:tool_result, %{id: "call_1", ok: true}}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The sandbox holds only what the tool itself wrote.
    assert File.ls!(ctx.tmp_dir) == ["notes.md"]
  end

  # Named to keep "api_key" out of the tmp dir name: the cwd rides the
  # persisted system prompt (ADR 0019), so the literal refute below must
  # only ever trip on the field name itself.
  @tag :tmp_dir
  test "the provider's key never reaches the session file", ctx do
    sentinel = "sentinel-key-" <> String.duplicate("x", 32)
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider:
          {:ok,
           %Config{
             base_url: SSEServer.base_url(server),
             model: "test-model",
             api_key: sentinel,
             auto_title: false
           }},
        cwd: ctx.tmp_dir,
        session_dir: sessions,
        supervisor: sup,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    send(agent, {:prompt, self(), "hello", []})
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

    send(agent, {:prompt, self(), "write it", []})
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
               %{"role" => "system"},
               %{"role" => "user", "content" => "write it"},
               %{"role" => "assistant", "tool_calls" => [call]}
             ]
           } = decoded

    assert call["id"] == "call_k"

    # Load repaired the dangling batch in memory: one synthesized cancelled
    # result, the file itself untouched.
    {:ok, session} = Session.load(sessions, id)

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant"},
             tool
           ] = session.messages

    assert %{"role" => "tool", "tool_call_id" => "call_k", "content" => repair_json} = tool
    assert Jason.decode!(repair_json) == %{"ok" => false, "cancelled" => true}

    # A fresh agent adopts the repaired history; its first request carries
    # the original ids, the matching tool_call_ids, and the message order.
    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        resume: %{id: session.id, pin: session.pin, messages: session.messages}
      )

    send(resumed, {:prompt, self(), "continue", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [
             %{"role" => "system"},
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
    assert length(next.messages) == 6
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
          id: "0192aa0c-8e9f-7a2b-8f8e-2f3a4b5c6d7e",
          pin: original_pin,
          messages: [%{"role" => "user", "content" => "earlier"}]
        }
      )

    send(resumed, {:prompt, self(), "continue", []})
    assert_receive {:phase, :idle}, 2_000

    {:ok, saved} = Session.load(sessions, "0192aa0c-8e9f-7a2b-8f8e-2f3a4b5c6d7e")
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
          id: "0192aa0c-8e9f-7a2b-8f8e-2f3a4b5c6d7e",
          created_at: "2026-10-01T00:00:00Z",
          pin: %{profile: nil, model: "test-model", base_url: SSEServer.base_url(server)},
          messages: [%{"role" => "user", "content" => "earlier"}]
        }
      )

    send(resumed, {:prompt, self(), "continue", []})
    assert_receive {:phase, :idle}, 2_000

    # The same file, under the adopted id, with the adopted created_at.
    assert session_id(sessions) == "0192aa0c-8e9f-7a2b-8f8e-2f3a4b5c6d7e"

    {:ok, session} = Session.load(sessions, "0192aa0c-8e9f-7a2b-8f8e-2f3a4b5c6d7e")
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

  # The vetter task's pid from the live {:vetting, ...} slot — polled, since
  # the slot is written just after the :checking phase is announced.
  defp vetting_pid(agent, tries \\ 100) do
    case :sys.get_state(agent).tool_slot do
      {:vetting, _check_ref, _mon_ref, pid, _call, _preview} ->
        pid

      _other when tries > 0 ->
        Process.sleep(10)
        vetting_pid(agent, tries - 1)
    end
  end

  # True iff `pid` is dead within `ms` — a tight liveness bound, polled with
  # no fixed sleep.
  defp dead_within?(pid, ms) when ms <= 0, do: not Process.alive?(pid)

  defp dead_within?(pid, ms) do
    if Process.alive?(pid) do
      Process.sleep(5)
      dead_within?(pid, ms - 5)
    else
      true
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

    send(agent, {:prompt, self(), "hello", []})
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

    send(agent, {:prompt, self(), "too early", []})
    assert_receive {:entry, :system, text}, 500
    assert text =~ "no provider"

    send(agent, {:set_provider, provider(server)})
    send(agent, {:prompt, self(), "after setup", []})

    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    messages = request_messages(body)

    assert List.last(messages) == %{
             "role" => "user",
             "content" => "after setup"
           }
  end

  ## Context accounting and compaction (ADR 0022)

  # The test's mirror of Accounting's weights (ADR 0022 §1) over the
  # string-keyed message maps a request body carries: bytes/4 over the
  # content plus each tool call's function name and argument JSON.
  defp weight_of(message) do
    content_weight =
      case message["content"] do
        content when is_binary(content) -> div(byte_size(content), 4)
        _other -> 0
      end

    calls_weight =
      case message["tool_calls"] do
        calls when is_list(calls) ->
          Enum.sum(
            for call <- calls do
              div(byte_size(call["function"]["name"]), 4) +
                div(byte_size(call["function"]["arguments"]), 4)
            end
          )

        _other ->
          0
      end

    content_weight + calls_weight
  end

  defp weight_sum(messages) do
    messages
    |> Enum.map(&weight_of/1)
    |> Enum.sum()
  end

  # The fixture tokenizer (ADR 0022 test plan 7): Accounting's weights plus 8
  # tokens of per-message scaffolding the heuristic cannot see.
  defp f_of(messages), do: 8 * length(messages) + weight_sum(messages)

  defp user_message(text), do: %{"role" => "user", "content" => text}

  defp assistant_message(text), do: %{"role" => "assistant", "content" => text}

  defp tool_assistant_message(id, args) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => Jason.encode!(args)}
        }
      ]
    }
  end

  defp tool_message(id, content),
    do: %{"role" => "tool", "tool_call_id" => id, "content" => content}

  # read_file's result for a single-line file, byte-for-byte: the same map
  # literal, in the same key order, DashFloat.Tools.Runner.read_window/3's
  # whole-file clause builds.
  defp read_result_json(path, content) do
    Jason.encode!(%{
      ok: true,
      path: path,
      content: content,
      lines: 1,
      total_lines: 1,
      total_bytes: byte_size(content),
      truncated: false
    })
  end

  # The file payload whose read_file result JSON weighs exactly `target`
  # heuristic tokens (div(bytes, 4) over the encoded result, ADR 0022 §1).
  defp payload_for_result_weight(path, target) do
    4 * target - byte_size(read_result_json(path, ""))
  end

  # One scripted automatic read_file turn: prompt, tool batch, reply, and the
  # request-body shapes they must produce. The payload is sized so the tool
  # result weighs `result_weight` tokens.
  defp read_turn(k, result_weight) do
    path = "big_#{k}.txt"
    args = %{"path" => path}
    content = String.duplicate("a", payload_for_result_weight(path, result_weight))

    %{
      k: k,
      prompt: "turn #{k}",
      final: "done #{k}",
      args: args,
      content: content,
      expected: [
        user_message("turn #{k}"),
        tool_assistant_message("call_#{k}", args),
        tool_message("call_#{k}", read_result_json(path, content)),
        assistant_message("done #{k}")
      ]
    }
  end

  # The SSE scripts for a list of read turns. Every usage frame reports the
  # fixture tokenizer's F of the request list the agent is expected to send
  # (deterministic — every response is scripted), so the agent's anchored
  # estimate tracks the transcript's true weight exactly. `first_overrides`
  # maps a turn number to the compacted first-request list expected in place
  # of the full history; `prefix` is the leading system message (ADR 0019)
  # the live agent seeds, so the frames count its weight too.
  defp read_scripts(specs, first_overrides, prefix) do
    {scripts, _transcript} =
      Enum.map_reduce(specs, prefix, fn spec, transcript ->
        first = Map.get(first_overrides, spec.k, transcript ++ [user_message(spec.prompt)])

        # The second episode's request: the batch flushed, the final reply not
        # yet appended (expected is [user, batch_assistant, tool, final]).
        mid = first ++ Enum.slice(spec.expected, 1, 2)

        scripts = [
          call_tool_episode("call_#{spec.k}", "read_file", spec.args,
            usage: {f_of(first), 5, f_of(first) + 5}
          ),
          final_episode(spec.final, usage: {f_of(mid), 5, f_of(mid) + 5})
        ]

        {scripts, transcript ++ spec.expected}
      end)

    # One level only: every episode stays its own list of steps — one
    # connection per episode.
    Enum.concat(scripts)
  end

  defp start_read_server(ctx, specs, first_overrides \\ %{}, prefix \\ []) do
    for spec <- specs, do: write_sandbox(ctx, spec.args["path"], spec.content)
    start_server(read_scripts(specs, first_overrides, prefix))
  end

  # Drives each prompt to idle, collecting both forwarded request bodies of
  # every read turn in order.
  defp drive_read_turns(agent, prompts) do
    for prompt <- prompts do
      send(agent, {:prompt, self(), prompt, []})
      assert_receive {:sse_request, "POST", _, _, first_body}, 2_000
      assert_receive {:sse_request, "POST", _, _, second_body}, 4_000
      assert_receive {:phase, :idle}, 4_000
      {first_body, second_body}
    end
  end

  @tag :tmp_dir
  test "compaction drops the oldest whole turns when the estimate crosses 80%", ctx do
    # The system message (ADR 0019) rides every request and is pinned through
    # eviction, so it prefixes the transcript and its measured weight counts.
    sys = system_message(ctx.tmp_dir)
    specs = [read_turn(1, 800), read_turn(2, 800), read_turn(3, 800)]
    full = [sys | Enum.flat_map(specs, & &1.expected)]

    # The anchored estimate sits under the trigger at the second prompt and
    # crosses it at the third; the pure contract then drops exactly one turn.
    # The window is derived from the measured estimates — the system
    # message's weight varies with the cwd and git state.
    anchor_after = fn k -> %{tokens: f_of(Enum.take(full, 4 * k)), index: 4 * k} end

    estimate_at_prompt = fn k ->
      Accounting.estimate(
        Enum.take(full, 4 * (k - 1) + 1) ++ [user_message("turn #{k}")],
        anchor_after.(k - 1)
      )
    end

    under = estimate_at_prompt.(2)
    over = estimate_at_prompt.(3)
    window = div((under + div(over - under, 2)) * 5, 4) + 1
    threshold = div(window * 4, 5)

    assert under <= threshold
    assert over > threshold

    messages_at_3 = Enum.take(full, 9) ++ [user_message("turn 3")]
    plan = Accounting.compact(messages_at_3, anchor_after.(2), window)
    assert plan.dropped == 1
    refute plan.oversize

    server = start_read_server(ctx, specs, %{3 => plan.kept}, [sys])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    [_first, _second, {third_first, _request}] =
      drive_read_turns(agent, Enum.map(specs, & &1.prompt))

    # The eviction is announced with the estimate bracket.
    before = Accounting.estimate(messages_at_3, anchor_after.(2))
    after_estimate = Accounting.estimate(plan.kept, plan.anchor)

    assert_receive {:entry, :system, context_entry}, 2_000

    assert context_entry ==
             "[context: dropped 1 oldest turn(s) — est #{before}→#{after_estimate} of #{window}]"

    # The next request carries exactly the retained turns: the pinned system
    # message, the retained turns, and the newest turn — never turn 1.
    messages = request_messages(third_first)
    assert messages == plan.kept
    assert [%{"role" => "system"}, %{"role" => "user", "content" => "turn 2"} | _rest] = messages
    refute Enum.any?(messages, &(&1["content"] == "turn 1"))
    refute Enum.any?(messages, &match?(%{"tool_call_id" => "call_1"}, &1))

    # The file agrees with the request and records the eviction; load
    # succeeding is itself the no-dangling invariant. By load time turn 3 has
    # also completed, so the transcript is the retained turns plus its batch.
    [turn_3] = Enum.drop(specs, 2)

    id = session_id(sessions)
    {:ok, session} = Session.load(sessions, id)

    assert session.messages == plan.kept ++ Enum.drop(turn_3.expected, 1)
    assert hd(plan.kept)["role"] == "system"

    assert [
             %{
               "at" => at,
               "turns" => 1,
               "window" => ^window,
               "estimate_before" => ^before,
               "estimate_after" => ^after_estimate
             }
           ] = session.compactions

    assert is_binary(at)
  end

  @tag :tmp_dir
  test "a transcript under 80% is untouched", ctx do
    sys = system_message(ctx.tmp_dir)

    # Sized so the third prompt's anchored estimate sits just under the
    # trigger (~79%) — one more turn would cross it. The window is derived
    # from the measured estimate (the system message's weight varies).
    specs = [read_turn(1, 752), read_turn(2, 752), read_turn(3, 752)]
    full = [sys | Enum.flat_map(specs, & &1.expected)]
    anchor_2 = %{tokens: f_of(Enum.take(full, 8)), index: 8}
    messages_at_3 = Enum.take(full, 9) ++ [user_message("turn 3")]

    estimate = Accounting.estimate(messages_at_3, anchor_2)
    window = div((estimate + 50) * 5, 4) + 1
    threshold = div(window * 4, 5)
    assert estimate in (threshold - 100)..threshold

    server = start_read_server(ctx, specs, %{}, [sys])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    [_first, _second, {third_first, _request}] =
      drive_read_turns(agent, Enum.map(specs, & &1.prompt))

    # No context entry, no eviction: the third request carries the full history.
    assert request_messages(third_first) == messages_at_3
    refute_received {:entry, :system, "[context: " <> _}

    # No eviction record anywhere — not in the loaded shape, not in the bytes.
    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.compactions == []
    assert session.messages == full
    refute read_session(sessions) =~ "compactions"
  end

  @tag :tmp_dir
  test "a nil window never compacts", ctx do
    # The same oversized transcript the dropping test uses, but the provider
    # carries no context_tokens (the default helper): nothing compacts,
    # nothing is guessed (ADR 0022 §2).
    specs = [read_turn(1, 800), read_turn(2, 800), read_turn(3, 800)]
    full = [system_message(ctx.tmp_dir) | Enum.flat_map(specs, & &1.expected)]
    messages_at_3 = Enum.take(full, 9) ++ [user_message("turn 3")]

    server = start_read_server(ctx, specs)
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    [_first, _second, {third_first, _request}] =
      drive_read_turns(agent, Enum.map(specs, & &1.prompt))

    assert request_messages(third_first) == messages_at_3
    refute_received {:entry, :system, "[context: " <> _}

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.compactions == []
    assert session.messages == full
  end

  @tag :tmp_dir
  test "an oversize single turn is kept whole with a warning", ctx do
    window = 2000
    threshold = div(window * 4, 5)

    # One turn whose weight alone exceeds the whole budget: it cannot be
    # split (whole-turn rule) and cannot be dropped (the newest question), so
    # it is kept and warned.
    huge = String.duplicate("a", 4 * threshold + 64)

    server = start_server([final_episode("noted", usage: 100)])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    send(agent, {:prompt, self(), huge, []})

    assert_receive {:entry, :system,
                    "[context: the remaining turn alone exceeds the 80% window budget — kept whole]"},
                   2_000

    refute_received {:entry, :system, "[context: dropped" <> _}

    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [%{"role" => "system"}, %{"role" => "user", "content" => ^huge} | _rest] =
             request_messages(body)

    assert_receive {:token, "noted"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # Nothing dropped — no eviction record exists.
    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.compactions == []
  end

  @tag :tmp_dir
  test "the anchor persists and is adopted on resume", ctx do
    # Sized so the pure heuristic over the whole transcript stays under the
    # trigger while the anchored estimate crosses it: only an adopted anchor
    # can produce the eviction asserted below. The window is derived from the
    # measured estimates — the system message's weight varies with the cwd.
    sys = system_message(ctx.tmp_dir)
    specs = [read_turn(1, 780), read_turn(2, 780)]
    full = [sys | Enum.flat_map(specs, & &1.expected)]
    u3 = user_message("turn 3")

    # The resumed agent's anchor: the last scripted frame of turn 2 — F of its
    # 8-message request (the system message rides it, ADR 0019) — covering
    # those 8 messages.
    anchor = %{tokens: f_of(Enum.take(full, 8)), index: 8}
    messages_at_resume = full ++ [u3]

    heuristic = Accounting.estimate(messages_at_resume, nil)
    anchored = Accounting.estimate(messages_at_resume, anchor)
    window = div((heuristic + div(anchored - heuristic, 2)) * 5, 4) + 1
    threshold = div(window * 4, 5)

    assert anchored > threshold
    assert heuristic <= threshold

    plan = Accounting.compact(messages_at_resume, anchor, window)
    assert plan.dropped == 1

    for spec <- specs, do: write_sandbox(ctx, spec.args["path"], spec.content)

    server =
      start_server(
        read_scripts(specs, %{}, [sys]) ++
          [
            final_episode("ack", usage: {f_of(plan.kept ++ [u3]), 5, f_of(plan.kept ++ [u3]) + 5})
          ]
      )

    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    [_first, _second] = drive_read_turns(agent, Enum.map(specs, & &1.prompt))
    id = session_id(sessions)

    # The file persists the anchor: the last scripted frame's prompt_tokens
    # over that episode's request message count. No evictions yet.
    prompt_tokens = anchor.tokens

    decoded =
      sessions
      |> read_session()
      |> Jason.decode!()

    assert %{"context" => %{"prompt_tokens" => ^prompt_tokens, "messages" => 8}} = decoded

    {:ok, saved} = Session.load(sessions, id)
    assert saved.context == %{prompt_tokens: anchor.tokens, messages: 8}
    assert saved.compactions == []

    # A fresh agent adopts both diagnostics — threaded exactly as
    # application.ex threads them — and evicts on the ANCHORED estimate.
    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: provider(server, window),
        resume: %{
          id: saved.id,
          pin: saved.pin,
          messages: saved.messages,
          created_at: saved.created_at,
          context: saved.context,
          compactions: saved.compactions
        }
      )

    send(resumed, {:prompt, self(), "turn 3", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    # plan.kept already carries the pinned system message and the prompting
    # user message — the eviction never touches either.
    assert request_messages(body) == plan.kept
    messages = request_messages(body)
    assert Enum.at(messages, 1)["content"] == "turn 2"
    assert_receive {:phase, :idle}, 2_000

    # The file gains its first eviction record.
    {:ok, next} = Session.load(sessions, id)

    assert [%{"at" => at, "turns" => 1, "window" => ^window}] = next.compactions
    assert is_binary(at)
    assert next.messages == plan.kept ++ [assistant_message("ack")]
  end

  @tag :tmp_dir
  test "a malformed resume anchor or compactions never crashes a prompt (B1)", ctx do
    window = 2000
    spec = read_turn(1, 40)
    u1 = user_message("turn 1")
    u2 = user_message("turn 2")
    full = spec.expected

    # Both arms of the hostile-review B1 finding: a hand-built resume map can
    # carry a context of any shape (the loader tolerates one, ADR 0022 §6)
    # and a compactions value that is not a list. Neither may raise.
    resume = %{
      id: "0192aa0d-90a1-7b3c-9a9b-3b4c5d6e7f8a",
      pin: %{profile: nil, model: nil, base_url: nil},
      messages: full ++ [u1],
      context: %{prompt_tokens: "412", messages: 6},
      compactions: nil
    }

    server = start_server([final_episode("ack", usage: {10, 5, 15})])
    write_sandbox(ctx, spec.args["path"], spec.content)

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: Path.join(ctx.tmp_dir, "sessions"),
        provider: provider(server, window),
        resume: resume
      )

    send(agent, {:prompt, self(), "turn 2", []})
    assert_receive {:sse_request, "POST", _, _, _body}, 2_000
    assert_receive {:phase, :idle}, 2_000
    assert Process.alive?(agent)

    # A well-shaped anchor whose index claims more messages than exist (M1)
    # is no anchor at all: the trigger keeps working on the heuristic.
    resume2 = %{resume | context: %{prompt_tokens: 10, messages: 999_999}}

    {agent2, _sup2} =
      start_agent(server, ctx.tmp_dir, provider: provider(server, window), resume: resume2)

    send(agent2, {:prompt, self(), "turn 2", []})
    assert_receive {:sse_request, "POST", _, _, _body}, 2_000
    assert_receive {:phase, :idle}, 2_000
    assert Process.alive?(agent2)

    # And an integer anchor past the end must not disable the trigger: this
    # transcript alone is far over a tiny window, so the prompt-time hook
    # still evicts (asserted through the request body).
    big =
      Enum.map(1..8, fn i -> %{role: "user", content: String.duplicate("x", 400) <> "#{i}"} end)

    resume3 = %{resume2 | messages: big, context: %{prompt_tokens: 10, messages: 999_999}}

    {agent3, _sup3} =
      start_agent(server, ctx.tmp_dir, provider: provider(server, 100), resume: resume3)

    send(agent3, {:prompt, self(), "last", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000
    messages = request_messages(body)
    refute hd(messages)["content"] == "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx1"
    assert Process.alive?(agent3)

    # The compacting prompt's snapshot is the POST-EVICTION list — the
    # footer's estimate drops with the dropped turns, exactly the list the
    # request carries (here: every big turn evicted, the question kept).
    assert_receive {:context, %{messages: [%{role: "user", content: "last"}] = pushed}},
                   2_000

    assert length(pushed) == length(messages)
    assert Enum.at(messages, 0)["content"] == "last"
  end

  # The stage-2 footer seam (ADR 0015 §2 amendment): the {messages, anchor}
  # snapshot the footer's Accounting.usage/3 read computes from, pushed at
  # every transcript mutation (the persist seam) and each usage frame.
  @tag :tmp_dir
  test "prompt, usage frame, and finalize each push a context snapshot", ctx do
    server = start_server([final_episode("hello there", usage: {10, 5, 15})])

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: Path.join(ctx.tmp_dir, "sessions"))

    send(agent, {:prompt, self(), "hi", []})

    # The prompt's push: system + question, no anchor yet — the frame has
    # not landed, so the footer estimates heuristically until it does.
    assert_receive {:context,
                    %{
                      messages: [%{role: "system"} = sys, %{role: "user", content: "hi"}],
                      anchor: nil
                    }},
                   2_000

    assert is_binary(sys.content)
    assert_receive {:sse_request, "POST", _, _, _body}, 2_000

    # The usage frame's push: the anchor minted from the frame's
    # prompt_tokens over the request's message count (ADR 0022 §1).
    assert_receive {:context, %{messages: _, anchor: %{tokens: 10, index: 2}}}, 2_000

    # The finalize's push: the assistant reply joined the list.
    assert_receive {:context,
                    %{
                      messages: [_, _, %{role: "assistant", content: "hello there"}],
                      anchor: %{tokens: 10, index: 2}
                    }},
                   2_000

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "the context push rides with persistence off too (footer truth needs no file)",
       ctx do
    server = start_server([final_episode("ack")])
    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "hi", []})
    assert_receive {:sse_request, "POST", _, _, _body}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # No session_dir, no file — the snapshot still landed for the footer.
    assert_receive {:context, %{messages: [_, _], anchor: nil}}, 2_000
  end

  @tag :tmp_dir
  test "a resumed-agent save keeps the pre-compaction file shape (m3)", ctx do
    sessions = Path.join(ctx.tmp_dir, "sessions")

    # A session file that predates compaction: valid messages, no diagnostics.
    id = "0192aa0d-90a1-7b3c-9a9b-3b4c5d6e7f8a"

    body = %{
      "version" => 1,
      "id" => id,
      "created_at" => "2026-10-29T00:00:00Z",
      "pin" => %{"profile" => nil, "model" => nil, "base_url" => nil},
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    File.mkdir_p!(sessions)
    file = Path.join(sessions, id <> ".json")
    File.write!(file, Jason.encode!(body))
    {:ok, loaded} = Session.load(sessions, id)

    # The loader fills context: nil / compactions: [] in — but a save of that
    # same map must not write the keys back (ADR 0022 §6: written only once
    # they exist), so the file keeps its pre-compaction shape.
    assert :ok = Session.save(sessions, loaded)

    decoded =
      sessions
      |> Path.join(id <> ".json")
      |> File.read!()
      |> Jason.decode!()

    refute Map.has_key?(decoded, "context")
    refute Map.has_key?(decoded, "compactions")
  end

  @tag :tmp_dir
  test "the estimate tracks the fixture provider within the stated band", ctx do
    # Turn 1 is a read_file batch, turns 2 and 3 plain replies. Every usage
    # frame reports the fixture tokenizer's F of the request list the agent is
    # expected to send — deterministic, because every response is scripted.
    turn1 = read_turn(1, 40)
    [u1, tc1, tool1, af1] = turn1.expected
    u2 = user_message("turn 2")
    af2 = assistant_message("done 2")
    u3 = user_message("turn 3")
    af3 = assistant_message("done 3")
    u4 = user_message("turn 4")

    sys = system_message(ctx.tmp_dir)

    request_1a = [sys, u1]
    request_1b = [sys, u1, tc1, tool1]
    request_2 = request_1b ++ [af1, u2]
    request_3 = request_2 ++ [af2, u3]

    server =
      start_server([
        call_tool_episode("call_1", "read_file", turn1.args,
          usage: {f_of(request_1a), 5, f_of(request_1a) + 5}
        ),
        final_episode("done 1", usage: {f_of(request_1b), 5, f_of(request_1b) + 5}),
        final_episode("done 2", usage: {f_of(request_2), 5, f_of(request_2) + 5}),
        final_episode("done 3", usage: {f_of(request_3), 5, f_of(request_3) + 5})
      ])

    write_sandbox(ctx, turn1.args["path"], turn1.content)
    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    # After each turn: the anchored estimate must track the fixture
    # tokenizer's next request within the stated band — 8 tokens of
    # scaffolding per message appended since the frame, plus slack.
    assert_band = fn anchor, after_turn, next_request, appended ->
      estimate = Accounting.estimate(after_turn, anchor)
      assert abs(estimate - f_of(next_request)) <= 8 * length(appended) + 24
    end

    send(agent, {:prompt, self(), "turn 1", []})
    assert_receive {:sse_request, "POST", _, _, body_1a}, 2_000
    assert request_messages(body_1a) == request_1a
    assert_receive {:sse_request, "POST", _, _, body_1b}, 4_000
    assert request_messages(body_1b) == request_1b
    assert_receive {:phase, :idle}, 4_000

    assert_band.(%{tokens: f_of(request_1b), index: 4}, [sys, u1, tc1, tool1, af1], request_2, [
      af1,
      u2
    ])

    send(agent, {:prompt, self(), "turn 2", []})
    assert_receive {:sse_request, "POST", _, _, body_2}, 2_000
    assert request_messages(body_2) == request_2
    assert_receive {:phase, :idle}, 4_000

    assert_band.(%{tokens: f_of(request_2), index: 6}, request_2 ++ [af2], request_3, [af2, u3])

    send(agent, {:prompt, self(), "turn 3", []})
    assert_receive {:sse_request, "POST", _, _, body_3}, 2_000
    assert request_messages(body_3) == request_3
    assert_receive {:phase, :idle}, 4_000

    assert_band.(
      %{tokens: f_of(request_3), index: 8},
      request_3 ++ [af3],
      request_3 ++ [af3, u4],
      [
        af3,
        u4
      ]
    )
  end

  ## Manual /compact (issue #92; ADR 0022's amendment): the same eviction the
  ## prompt-time hook runs, on demand — same trigger, same entries.

  @tag :tmp_dir
  test "manual /compact runs the same eviction immediately, idle, without a prompt", ctx do
    # The estimate sits UNDER the trigger at the second prompt and OVER it
    # once turn 2's reply lands, so the automatic path stays silent through
    # both turns and the manual command does the dropping. The window is
    # derived from the measured estimates — the system message's weight
    # varies with the cwd and git state.
    sys = system_message(ctx.tmp_dir)
    specs = [read_turn(1, 800), read_turn(2, 800)]
    full = [sys | Enum.flat_map(specs, & &1.expected)]
    anchor_after = fn k -> %{tokens: f_of(Enum.take(full, 4 * k)), index: 4 * k} end

    est_at_prompt_2 =
      Accounting.estimate(Enum.take(full, 5) ++ [user_message("turn 2")], anchor_after.(1))

    est_after_reply_2 = Accounting.estimate(full, anchor_after.(2))
    window = div((est_at_prompt_2 + div(est_after_reply_2 - est_at_prompt_2, 2)) * 5, 4) + 1
    threshold = div(window * 4, 5)

    assert est_at_prompt_2 <= threshold
    assert threshold < est_after_reply_2

    plan = Accounting.compact(full, anchor_after.(2), window)
    assert plan.dropped == 1
    refute plan.oversize

    server = start_read_server(ctx, specs, %{}, [sys])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    drive_read_turns(agent, Enum.map(specs, & &1.prompt))

    # The automatic path never fired; the manual one does the work.
    refute_received {:entry, :system, "[context: " <> _}
    send(agent, {:compact, self()})

    before = est_after_reply_2
    after_estimate = Accounting.estimate(plan.kept, plan.anchor)

    assert_receive {:entry, :system, entry}, 2_000

    assert entry ==
             "[context: dropped 1 oldest turn(s) — est #{before}→#{after_estimate} of #{window}]"

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.messages == plan.kept

    assert [
             %{
               "at" => at,
               "turns" => 1,
               "window" => ^window,
               "estimate_before" => ^before,
               "estimate_after" => ^after_estimate
             }
           ] = session.compactions

    assert is_binary(at)
  end

  @tag :tmp_dir
  test "manual /compact below the trigger is a no-op that reports the estimate", ctx do
    sys = system_message(ctx.tmp_dir)
    specs = [read_turn(1, 800), read_turn(2, 800)]
    full = [sys | Enum.flat_map(specs, & &1.expected)]
    anchor_after = fn k -> %{tokens: f_of(Enum.take(full, 4 * k)), index: 4 * k} end

    # A window whose trigger sits above the whole transcript: nothing to drop.
    est_after_reply_2 = Accounting.estimate(full, anchor_after.(2))
    window = est_after_reply_2 * 2

    server = start_read_server(ctx, specs, %{}, [sys])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, window))

    drive_read_turns(agent, Enum.map(specs, & &1.prompt))
    send(agent, {:compact, self()})

    usage = Accounting.usage(full, anchor_after.(2), window)

    assert_receive {:entry, :system, entry}, 2_000

    assert entry ==
             "[context: at or under the 80% trigger — nothing to compact (est #{usage.used} of #{usage.window}, #{usage.percent}%)]"

    # The session file is untouched: no drop, no record.
    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.messages == full
    assert session.compactions == []
  end

  test "manual /compact with no configured window answers on the documented default, note naming the remedy (issue #111)" do
    server = start_server([])
    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:compact, self()})

    assert_receive {:entry, :system, entry}, 2_000

    # The fresh agent carries the system prompt (ADR 0019), so the estimate
    # is non-zero and cwd-dependent — assert the shape, not the number.
    assert entry =~ "[context: at or under the 80% trigger — nothing to compact (est "
    assert entry =~ " of 131072, "

    assert entry =~
             " — window assumed: no source knows this model, using the 131072-token default; " <>
               "set context on the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS to override]"
  end

  test "manual /compact with no resolved provider names the remedy (issue #111)" do
    server = start_server([])

    {agent, _sup} =
      start_agent(server, System.tmp_dir!(),
        provider: {:error, "missing provider config: api_key"}
      )

    send(agent, {:compact, self()})

    assert_receive(
      {:entry, :system,
       "[context: no context window resolved — nothing to compact; " <>
         "set context on the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS]"},
      2_000
    )
  end

  test "manual /compact on a stock Z.AI config answers on the seeded 1M window, no note (issue #111)" do
    server = start_server([])

    stock =
      {:ok,
       %Config{
         base_url: "https://api.z.ai/api/coding/paas/v4",
         model: "glm-5.3-flash",
         api_key: "PLACEHOLDER-stock-key",
         auto_title: false
       }}

    {agent, _sup} = start_agent(server, System.tmp_dir!(), provider: stock)

    send(agent, {:compact, self()})

    assert_receive {:entry, :system, entry}, 2_000

    # The seed is a known window, not an assumption: plain reply, no note.
    assert entry =~ "[context: at or under the 80% trigger — nothing to compact (est "
    assert entry =~ " of 1048576, "
    refute entry =~ "window assumed"
  end

  @tag :tmp_dir
  test "a drop against the documented default window carries the assumption note (issue #111, review F1)",
       ctx do
    # Two turns whose estimate sits over the DEFAULT window's trigger (an
    # unknown model at an unseeded provider): the most destructive action
    # discloses the most — the drop entry names the assumed window and the
    # remedy, exactly like the below-trigger reply.
    id = "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b44"
    sessions = Path.join(ctx.tmp_dir, "sessions")
    File.mkdir_p!(sessions)

    fixture =
      Jason.encode!(%{
        version: 1,
        id: id,
        created_at: "2026-10-30T00:00:00Z",
        pin: %{},
        messages:
          for turn <- ["a", "b"] do
            [
              %{"role" => "user", "content" => String.duplicate(turn, 120_000)},
              %{"role" => "assistant", "content" => String.duplicate(turn, 120_000)}
            ]
          end
          |> List.flatten()
      })

    path = Path.join(sessions, "#{id}.json")
    File.write!(path, fixture)

    {:ok, saved} = Session.load(sessions, id)
    server = start_server([])
    # provider/1: the mock's URL and an unknown model — the documented
    # 131072 default, :default source.
    resumed = %{
      id: saved.id,
      pin: saved.pin,
      messages: saved.messages,
      created_at: saved.created_at
    }

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: provider(server),
        resume: resumed
      )

    send(agent, {:compact, self()})

    assert_receive {:entry, :system, entry}, 2_000

    assert entry =~ "[context: dropped 1 oldest turn(s) — est "

    assert entry =~
             " of 131072 — window assumed, set context on the model's entry in settings.json5 or DASHFLOAT_CONTEXT_TOKENS]"
  end

  @tag :tmp_dir
  test "manual /compact on an oversize-only transcript warns but writes nothing", ctx do
    # One turn alone over the budget: nothing can drop, the survivor warns —
    # and a pass that dropped nothing must not rewrite the session file (the
    # ADR 0022 amendment's §3). The fixture file is resumed, not re-derived.
    id = "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"
    sessions = Path.join(ctx.tmp_dir, "sessions")
    File.mkdir_p!(sessions)
    path = Path.join(sessions, "#{id}.json")

    fixture =
      Jason.encode!(%{
        version: 1,
        id: id,
        created_at: "2026-10-30T00:00:00Z",
        pin: %{},
        messages: [
          %{"role" => "user", "content" => String.duplicate("a", 20_000)},
          %{"role" => "assistant", "content" => String.duplicate("b", 20_000)}
        ]
      })

    File.write!(path, fixture)

    {:ok, saved} = Session.load(sessions, id)
    server = start_server([])

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: provider(server, 8_000),
        resume: %{
          id: saved.id,
          pin: saved.pin,
          messages: saved.messages,
          created_at: saved.created_at
        }
      )

    send(agent, {:compact, self()})

    assert_receive {:entry, :system,
                    "[context: the remaining turn alone exceeds the 80% window budget — kept whole]"},
                   2_000

    refute_received {:entry, :system, "[context: dropped" <> _}

    # Byte-identical: no persist ran at all.
    assert File.read!(path) == fixture
  end

  @tag :tmp_dir
  test "manual /compact never mints a session file for an unprompted launch", ctx do
    # A fresh agent's only message is the pinned system prompt (ADR 0019); a
    # window smaller than it makes /compact oversize-only on a launch that
    # never prompted — which must leave NOTHING behind (ADR 0014 §5).
    server = start_server([])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, session_dir: sessions, provider: provider(server, 10))

    send(agent, {:compact, self()})

    assert_receive {:entry, :system, "[context: the remaining turn alone" <> _}, 2_000
    refute File.exists?(sessions)
  end

  test "a /compact while streaming is ignored" do
    # The reply pauses mid-stream: the command lands while the turn is open.
    server =
      start_server([
        [
          {:send, [@headers, frame("half")]},
          {:sleep, 300},
          {:send, frame(" rest")},
          {:send, "data: [DONE]\n\n"},
          :close
        ]
      ])

    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:token, "half"}, 2_000

    send(agent, {:compact, self()})

    assert_receive {:phase, :idle}, 2_000
    refute_received {:entry, :system, "[context:" <> _}
  end

  ## Session title (#80): the auto-title side-request, the rename seam,
  ## resume adoption. The suite's default provider opts the trigger out;
  ## these tests opt in through `title_provider/2`.

  # The auto-title tests' provider: the suite's shape with the tri-state the
  # trigger reads left unset (nil = enabled, the resolution default).
  defp title_provider(server, overrides \\ []) do
    {:ok,
     struct!(
       Config,
       Keyword.merge(
         [base_url: SSEServer.base_url(server), model: "test-model", api_key: "test-key-123"],
         overrides
       )
     )}
  end

  # A plain-JSON chat-completions response — the title side-request's reply
  # shape (no SSE).
  defp title_step(content) do
    body = Jason.encode!(%{choices: [%{message: %{content: content}}]})

    [
      {:send,
       "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n" <>
         body},
      :close
    ]
  end

  # A fetcher that notifies the test each time the agent calls it, then
  # proposes `title`.
  defp notify_fetcher(test_pid, title \\ "Proposed Title") do
    fn _config, _context ->
      send(test_pid, :title_fetcher_called)
      {:ok, title}
    end
  end

  defp save_titled(dir, id, title) do
    :ok =
      Session.save(dir, %{
        version: 1,
        id: id,
        created_at: "2026-10-29T00:00:00Z",
        pin: %{profile: nil, model: nil, base_url: nil},
        messages: [],
        title: title
      })
  end

  @other_id "0192aa10-b001-7c00-8000-00000000000b"
  @other_id_2 "0192aa10-b002-7c00-8000-00000000000c"

  @tag :tmp_dir
  test "the first settled turn fires one title side-request, e2e at the loopback", ctx do
    server =
      start_server([final_episode("Fix the login bug"), title_step("Fix the login bug")])

    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server, model: "glm-5.3-flash")
      )

    send(agent, {:prompt, self(), "title this session", []})
    assert_receive {:sse_request, "POST", "/chat/completions", _, _main}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The side-request: the resolved model (the loopback is a custom
    # provider, so unset autoTitle rides the active-model fallback — here
    # the Z.AI cheap id; the preset-table arm is Title's unit tests), the
    # instruction, the first exchange, and the 32-token cap.
    assert_receive {:sse_request, "POST", "/chat/completions", _, title_body}, 2_000

    assert %{
             "model" => "glm-5.3-flash",
             "max_tokens" => 32,
             "messages" => [
               %{"role" => "system", "content" => instruction},
               %{"role" => "user", "content" => "title this session"},
               %{"role" => "assistant", "content" => "Fix the login bug"}
             ]
           } = Jason.decode!(title_body)

    assert instruction =~ "Propose a concise title"

    # The scripted reply titles the session: the display push, the entry, and
    # the file (issue #106).
    assert_receive {:title, "Fix the login bug"}, 2_000
    assert_receive {:entry, :system, "[session titled: Fix the login bug]"}, 2_000

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == "Fix the login bug"
  end

  @tag :tmp_dir
  test "the turn reaches idle before the side-request is answered", ctx do
    server = start_server([final_episode("done"), [{:sleep, 400} | title_step("Slow Title")]])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server)
      )

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:sse_request, "POST", _, _, _main}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The side-request is still sleeping on the server; the agent is idle.
    refute_received {:entry, :system, "[session titled: Slow Title]"}

    assert_receive {:entry, :system, "[session titled: Slow Title]"}, 2_000
    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == "Slow Title"
  end

  @tag :tmp_dir
  test "no fire when the session boots titled", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title: "Booted Title",
        title_fetcher: notify_fetcher(self())
      )

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000
    Process.sleep(300)
    refute_received :title_fetcher_called

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == "Booted Title"
  end

  @tag :tmp_dir
  test "no fire when auto_title is false or persistence is off", ctx do
    server = start_server([final_episode("a"), final_episode("b")])

    # The two opt-outs are exercised APART (review: a shared iteration never
    # proves the auto_title guard with persistence on), each with a
    # notifying fetcher installed — the refute is only meaningful if a fire
    # would have been observable.
    for {provider, session_dir} <- [
          {title_provider(server, auto_title: false), Path.join(ctx.tmp_dir, "sessions-off")},
          {title_provider(server), nil}
        ] do
      {agent, _sup} =
        start_agent(server, ctx.tmp_dir,
          provider: provider,
          session_dir: session_dir,
          title_fetcher: notify_fetcher(self())
        )

      send(agent, {:prompt, self(), "hello", []})
      assert_receive {:phase, :idle}, 2_000
    end

    Process.sleep(300)
    refute_received :title_fetcher_called
  end

  @tag :tmp_dir
  test "a cancelled first turn never fires; the next settled turn does, once", ctx do
    # The first connection parks in wait_close — the cancel kills the client
    # side, which releases the single-threaded acceptor for the second turn
    # (no EOF can race the Esc into a normal end-of-turn).
    server =
      start_server([
        [{:send, [@headers, frame("partial")]}, {:wait_close, 30_000}],
        final_episode("settled now")
      ])

    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: notify_fetcher(self())
      )

    send(agent, {:prompt, self(), "go", []})
    assert_receive {:token, "partial"}, 2_000
    send(agent, {:cancel})
    assert_receive {:entry, :system, "[cancelled]"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # The cancelled turn is not a settled one: no fire.
    refute_received :title_fetcher_called

    send(agent, {:prompt, self(), "again", []})
    assert_receive {:phase, :idle}, 2_000
    assert_receive :title_fetcher_called, 2_000
    Process.sleep(300)
    refute_received :title_fetcher_called
  end

  @tag :tmp_dir
  test "a failed proposal never re-fires: the latch is one-shot per run", ctx do
    server = start_server([final_episode("one"), final_episode("two")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    test_pid = self()

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: fn _config, _context ->
          send(test_pid, :title_fetcher_called)
          :error
        end
      )

    send(agent, {:prompt, self(), "one", []})
    assert_receive {:phase, :idle}, 2_000
    assert_receive :title_fetcher_called, 2_000

    # The failure cleared the guard, kept the latch: no entry, no ref.
    assert %{title_fired?: true, title_ref: nil, session_title: nil} = :sys.get_state(agent)

    send(agent, {:prompt, self(), "two", []})
    assert_receive {:phase, :idle}, 2_000
    Process.sleep(300)
    refute_received :title_fetcher_called
  end

  @tag :tmp_dir
  test "a user title set while a proposal is in flight wins", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: fn _config, _context ->
          Process.sleep(400)
          {:ok, "Late Proposal"}
        end
      )

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000
    send(agent, {:set_title, self(), "User Title"})
    assert_receive {:entry, :system, "[session titled: User Title]"}, 2_000

    # The late proposal lands and loses — the in-flight guard drops it.
    Process.sleep(700)
    refute_received {:entry, :system, "[session titled: Late Proposal]"}
    assert %{session_title: "User Title", title_ref: nil} = :sys.get_state(agent)

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == "User Title"
  end

  @tag :tmp_dir
  test "a proposal another session holds lands in its (2) form", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    save_titled(sessions, @other_id, "Fix the bug")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: fn _config, _context -> {:ok, "Fix the bug"} end
      )

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:entry, :system, "[session titled: Fix the bug (2)]"}, 2_000

    session = load_own_session(sessions, agent)
    assert session.title == "Fix the bug (2)"
  end

  @tag :tmp_dir
  test "a colliding long proposal truncates under the cap with the suffix", ctx do
    long = String.duplicate("x", 90)
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    save_titled(sessions, @other_id, String.slice(long, 0, 80))

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: fn _config, _context -> {:ok, long} end
      )

    send(agent, {:prompt, self(), "hello", []})
    expected = String.slice(long, 0, 76) <> " (2)"
    assert_receive {:entry, :system, "[session titled: " <> _}, 2_000
    assert %{session_title: landed} = :sys.get_state(agent)
    assert landed == expected
    assert String.length(landed) == 80
  end

  @tag :tmp_dir
  test "eight held candidates give up silently: no title, no entry", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    save_titled(sessions, @other_id, "T")

    for n <- 2..8 do
      save_titled(sessions, "0192aa10-b00#{n}-7c00-8000-00000000000b", "T (#{n})")
    end

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        title_fetcher: fn _config, _context -> {:ok, "T"} end
      )

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000
    Process.sleep(300)
    refute_received {:entry, :system, "[session titled" <> _}
    assert %{session_title: nil, title_ref: nil} = :sys.get_state(agent)

    session = load_own_session(sessions, agent)
    assert session.title == nil
  end

  @tag :tmp_dir
  test "the side-request carries the FIRST exchange's contents (string-keyed resumes too)",
       ctx do
    server = start_server([final_episode("second answer")])

    resumed_messages = [
      %{"role" => "user", "content" => "first question"},
      %{"role" => "assistant", "content" => "first answer"}
    ]

    test_pid = self()

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: Path.join(ctx.tmp_dir, "sessions"),
        provider: title_provider(server),
        resume: %{
          id: "0192aa10-b009-7c00-8000-00000000000b",
          pin: %{profile: nil, model: nil, base_url: nil},
          messages: resumed_messages
        },
        title_fetcher: fn _config, context ->
          send(test_pid, {:title_context, context})
          {:ok, "T"}
        end
      )

    send(agent, {:prompt, self(), "second question", []})
    assert_receive {:phase, :idle}, 2_000
    assert_receive {:title_context, context}, 2_000
    assert context == %{user: "first question", assistant: "first answer"}
  end

  @tag :tmp_dir
  test "the context skips a nil-content tool announcement to the first real reply", ctx do
    write_sandbox(ctx, "notes.md", "seed\n")

    server =
      start_server([
        call_tool_episode("call_1", "read_file", %{"path" => "notes.md"}),
        final_episode("done")
      ])

    test_pid = self()

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: Path.join(ctx.tmp_dir, "sessions"),
        provider: title_provider(server),
        title_fetcher: fn _config, context ->
          send(test_pid, {:title_context, context})
          {:ok, "T"}
        end
      )

    send(agent, {:prompt, self(), "go", []})
    assert_receive {:phase, :idle}, 2_000
    assert_receive {:title_context, context}, 2_000

    # The first assistant message is the nil-content tool batch; the first
    # assistant REPLY is the episode that follows it.
    assert context == %{user: "go", assistant: "done"}
  end

  @tag :tmp_dir
  test "a stale title proposal is ignored, never a crash", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    send(agent, {:title_proposal, make_ref(), "Stale"})
    send(agent, {:title_proposal, make_ref(), nil})
    Process.sleep(100)

    assert Process.alive?(agent)
    assert %{session_title: nil, title_ref: nil} = :sys.get_state(agent)
    refute_received {:entry, :system, "[session titled" <> _}
  end

  ## The rename seam (#80)

  @tag :tmp_dir
  test "set_title: a free title normalizes, sets, persists, and confirms", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    send(agent, {:set_title, self(), "  Rename   Me  "})
    assert_receive {:title, "Rename Me"}, 2_000
    assert_receive {:entry, :system, "[session titled: Rename Me]"}, 2_000
    assert %{session_title: "Rename Me"} = :sys.get_state(agent)

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == "Rename Me"
  end

  @tag :tmp_dir
  test "set_title refuses empty, oversized, and uuid-shaped titles", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    for {raw, reason, refusal} <- [
          {"", "may not be empty", "[title not set: may not be empty]"},
          {"   ", "may not be empty", "[title not set: may not be empty]"},
          {String.duplicate("a", 81), "may not exceed 80 characters",
           "[title not set: may not exceed 80 characters]"},
          {"0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c", "may not look like a session id",
           "[title not set: may not look like a session id]"}
        ] do
      send(agent, {:set_title, self(), raw})
      # The dialog push (issue #106) carries the same human text, minus the
      # framing; the entry stays the log record.
      assert_receive {:title_refused, ^reason}, 2_000
      assert_receive {:entry, :system, ^refusal}, 2_000
    end

    assert %{session_title: nil} = :sys.get_state(agent)

    {:ok, session} = Session.load(sessions, session_id(sessions))
    assert session.title == nil
  end

  @tag :tmp_dir
  test "set_title names the holder when the title is taken", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    save_titled(sessions, @other_id_2, "Taken Name")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    send(agent, {:set_title, self(), "taken name"})
    # The dialog push names the holder too (issue #106).
    assert_receive {:title_refused, reason}, 2_000
    assert reason == ~s("taken name" is already taken by session #{@other_id_2})

    assert_receive {:entry, :system, taken}, 2_000
    assert taken == "[title not set: \"taken name\" is already taken by session #{@other_id_2}]"
    assert %{session_title: nil} = :sys.get_state(agent)

    session = load_own_session(sessions, agent)
    assert session.title == nil
  end

  @tag :tmp_dir
  test "set_title allows retitling to a key the session itself holds", ctx do
    server = start_server([final_episode("done")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    send(agent, {:set_title, self(), "Alpha"})
    assert_receive {:entry, :system, "[session titled: Alpha]"}, 2_000

    # The same key, different case: the holder scan skips this session's id.
    send(agent, {:set_title, self(), "ALPHA"})
    assert_receive {:entry, :system, "[session titled: ALPHA]"}, 2_000
    assert %{session_title: "ALPHA"} = :sys.get_state(agent)
  end

  @tag :tmp_dir
  test "set_title with persistence off still normalizes and confirms", ctx do
    server = start_server([final_episode("done")])
    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "hello", []})
    assert_receive {:phase, :idle}, 2_000

    send(agent, {:set_title, self(), "  Off   Grid  "})
    assert_receive {:title, "Off Grid"}, 2_000
    assert_receive {:entry, :system, "[session titled: Off Grid]"}, 2_000
    assert %{session_title: "Off Grid"} = :sys.get_state(agent)
  end

  @tag :tmp_dir
  test "a title set before the first prompt writes no session file", ctx do
    server = start_server([final_episode("unused")])
    sessions = Path.join(ctx.tmp_dir, "sessions")
    {agent, _sup} = start_agent(server, ctx.tmp_dir, session_dir: sessions)

    send(agent, {:set_title, self(), "Early"})
    assert_receive {:title, "Early"}, 2_000
    assert_receive {:entry, :system, "[session titled: Early]"}, 2_000
    assert %{session_title: "Early"} = :sys.get_state(agent)

    # The ADR 0014 §5 invariant: a launch that never prompts leaves nothing.
    refute File.exists?(sessions)
  end

  test "a malformed set_title message is ignored, never a crash" do
    server = start_server([final_episode("done")])
    {agent, _sup} = start_agent(server, System.tmp_dir!())

    send(agent, {:set_title, self(), 42})
    send(agent, {:set_title, "not-a-pid", "x"})
    Process.sleep(100)

    assert Process.alive?(agent)
    assert %{session_title: nil} = :sys.get_state(agent)
    refute_received {:entry, :system, "[title not set" <> _}
    refute_received {:entry, :system, "[session titled" <> _}
  end

  @tag :tmp_dir
  test "a resumed session keeps its title on the next save and never fires the nudge", ctx do
    id = "0192aa10-b010-7c00-8000-00000000000b"
    sessions = Path.join(ctx.tmp_dir, "sessions")
    save_titled(sessions, id, "Resumed Title")
    {:ok, loaded} = Session.load(sessions, id)

    server = start_server([final_episode("resumed fine")])

    {resumed, _sup} =
      start_agent(server, ctx.tmp_dir,
        session_dir: sessions,
        provider: title_provider(server),
        resume: %{
          id: loaded.id,
          pin: loaded.pin,
          messages: loaded.messages,
          created_at: loaded.created_at,
          title: loaded.title
        },
        title_fetcher: notify_fetcher(self())
      )

    assert %{session_title: "Resumed Title"} = :sys.get_state(resumed)

    send(resumed, {:prompt, self(), "continue", []})
    assert_receive {:phase, :idle}, 2_000
    Process.sleep(300)
    refute_received :title_fetcher_called

    # The round trip: the re-saved file carries the adopted title verbatim.
    {:ok, session} = Session.load(sessions, id)
    assert session.title == "Resumed Title"
    assert List.last(session.messages)["content"] == "resumed fine"
  end

  ## The image seam (ADR 0018 §4/§6): the request body proves what the model
  ## sees; refusals prove nothing was sent or appended.

  # An image-capable provider (ADR 0018 §1): the seam tests' fixture.
  defp image_provider(server) do
    {:ok, config} = provider(server)
    {:ok, %Config{config | images: true}}
  end

  @tag :tmp_dir
  test "an image turn rides the wire as content parts and re-sends on later episodes", ctx do
    image = Path.join(ctx.tmp_dir, "pic.png")
    File.write!(image, <<137, 80, 78, 71, 13, 10>>)

    server = start_server([final_episode("a cat"), final_episode("still a cat")])
    {agent, _sup} = start_agent(server, ctx.tmp_dir, provider: image_provider(server))

    send(agent, {:prompt, self(), "what is this?", [image]})
    assert_receive {:sse_request, "POST", _, _, first_body}, 2_000

    assert [%{"role" => "system"}, user] = request_messages(first_body)
    assert %{"role" => "user", "content" => parts} = user
    assert [%{"type" => "text", "text" => "what is this?"}, image_part] = parts
    assert %{"type" => "image_url", "image_url" => %{"url" => url}} = image_part
    assert "data:image/png;base64," <> payload = url
    assert Base.decode64!(payload) == File.read!(image)

    assert_receive {:token, "a cat"}, 2_000
    assert_receive {:phase, :idle}, 2_000

    # Image parts ride the transcript for the session's life (ADR 0018 §2):
    # the follow-up turn's request carries them again.
    send(agent, {:prompt, self(), "and now?", []})
    assert_receive {:sse_request, "POST", _, _, second_body}, 4_000

    assert [
             %{"role" => "system"},
             %{"role" => "user", "content" => [_text_part, _image_part]},
             %{"role" => "assistant", "content" => "a cat"},
             %{"role" => "user", "content" => "and now?"}
           ] = request_messages(second_body)

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "an image-only turn omits the empty text part", ctx do
    image = Path.join(ctx.tmp_dir, "pic.png")
    File.write!(image, <<1, 2, 3>>)

    server = start_server([final_episode()])
    {agent, _sup} = start_agent(server, ctx.tmp_dir, provider: image_provider(server))

    send(agent, {:prompt, self(), "", [image]})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [%{"role" => "system"}, %{"role" => "user", "content" => [only]}] =
             request_messages(body)

    assert %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> _url}} =
             only

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "an incapable model refuses visibly: no request, nothing appended", ctx do
    image = Path.join(ctx.tmp_dir, "pic.png")
    File.write!(image, <<1, 2, 3>>)

    server = start_server([final_episode()])
    {agent, _sup} = start_agent(server, ctx.tmp_dir)

    send(agent, {:prompt, self(), "hi", [image]})
    refute_receive {:sse_request, _, _, _, _}, 200

    assert_receive {:entry, :system,
                    "[images: model test-model does not accept images — attach refused]"},
                   1_000

    assert_receive {:phase, :idle}, 1_000

    # The refused turn appended nothing: the follow-up's request carries no
    # list-content message.
    send(agent, {:prompt, self(), "plain", []})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    messages = request_messages(body)
    refute Enum.any?(messages, &is_list(&1["content"]))

    assert_receive {:phase, :idle}, 2_000
  end

  @tag :tmp_dir
  test "a vanished attachment refuses naming the path, nothing sent", ctx do
    server = start_server([final_episode()])
    {agent, _sup} = start_agent(server, ctx.tmp_dir, provider: image_provider(server))

    send(agent, {:prompt, self(), "look", [Path.join(ctx.tmp_dir, "gone.png")]})
    refute_receive {:sse_request, _, _, _, _}, 200

    assert_receive {:entry, :system, entry}, 1_000
    assert entry =~ "gone.png"
    assert String.starts_with?(entry, "[images: ")
    assert_receive {:phase, :idle}, 1_000
  end

  @tag :tmp_dir
  test "an image turn persists and round-trips through Session.load", ctx do
    image = Path.join(ctx.tmp_dir, "pic.png")
    File.write!(image, <<9, 8, 7>>)

    server = start_server([final_episode()])
    sessions = Path.join(ctx.tmp_dir, "sessions")

    {agent, _sup} =
      start_agent(server, ctx.tmp_dir, provider: image_provider(server), session_dir: sessions)

    send(agent, {:prompt, self(), "what is this?", [image]})
    assert_receive {:phase, :idle}, 2_000

    loaded = load_own_session(sessions, agent)

    assert [
             %{"role" => "system"},
             %{"role" => "user", "content" => [text, image_part]}
             | _rest
           ] = loaded.messages

    assert %{"type" => "text", "text" => "what is this?"} = text

    assert %{
             "type" => "image_url",
             "image_url" => %{"url" => "data:image/png;base64," <> payload}
           } =
             image_part

    assert Base.decode64!(payload) == <<9, 8, 7>>
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

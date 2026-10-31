defmodule DashFloat.LLM.ChatStreamTest do
  @moduledoc false
  # Not async: each test owns a real loopback socket and a shared stream
  # supervisor task list.
  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.LLM.ChatStream
  alias DashFloat.SSEServer
  alias DashFloat.Synthetic

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  @fixture_dir Path.expand("../../fixtures/sse", __DIR__)

  defp fixture(name) do
    path = Path.join(@fixture_dir, name)
    File.read!(path)
  end

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  # A streamed tool-call: the id/name frame first, then argument fragments.
  defp tool_frames(id, name, arg_fragments) do
    opening =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)

    rest =
      for frag <- arg_fragments do
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
      end

    [opening | rest]
  end

  defp start_server(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp provider(base_url, api_key) do
    {:ok, %Config{base_url: base_url, model: "test-model", api_key: api_key}}
  end

  # Runs the producer as a Task (like the agent does), with the test process as
  # the agent, and returns `{task_pid, monitor_ref}`.
  defp start_stream(base_url, opts \\ []) do
    agent = self()
    messages = Keyword.get(opts, :messages, [%{role: "user", content: "hello"}])
    tools = Keyword.get(opts, :tools, [])
    key = Keyword.get(opts, :api_key, "test-key-123")
    run_opts = Keyword.take(opts, [:idle_timeout, :synthetic, :repair_timeout])

    {:ok, pid} =
      Task.start(fn ->
        ChatStream.run(agent, provider(base_url, key), messages, tools, run_opts)
      end)

    {pid, Process.monitor(pid)}
  end

  # Collects contract messages through the terminal {:stream_done, _}.
  defp collect(acc \\ []) do
    receive do
      {:token, _text} = msg -> collect([msg | acc])
      {:reasoning, _text} = msg -> collect([msg | acc])
      {:usage, _map} = msg -> collect([msg | acc])
      {:stream_failed, _text, _partial} = msg -> collect([msg | acc])
      {:stream_done, _report} = msg -> Enum.reverse([msg | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  defp tokens(messages) do
    for {:token, text} <- messages, into: "", do: text
  end

  # `in` demands exact equality; partial-key reports need pattern matching.
  defp reported?(messages, fun) when is_function(fun, 1), do: Enum.any?(messages, fun)

  defp failures(messages), do: for({:stream_failed, text, _partial} <- messages, do: text)

  defp done(messages), do: Enum.find(messages, &match?({:stream_done, _report}, &1))

  # A pre-flight rejection can finish before the monitor attaches, so the DOWN
  # arrives as :noproc — the same race the agent's DOWN handling documents.
  defp await_exit(ref) do
    assert_receive {:DOWN, ^ref, :process, _pid, reason}, 2_000
    assert reason in [:normal, :noproc]
  end

  test "happy path streams tokens in order, reports done, exits normal" do
    server = start_server([{:send, [@headers, fixture("happy.txt")]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "Hello, world!"

    assert {:stream_done,
            %{content: "Hello, world!", reasoning: "", tool_calls: [], cancelled: false}} in messages

    assert failures(messages) == []
    await_exit(ref)
  end

  test "one TCP chunk carrying several frames yields one token per frame" do
    frames = [frame("a"), frame("b"), frame("c"), "data: [DONE]\n\n"]
    server = start_server([{:send, [@headers, frames]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert for({:token, text} <- messages, do: text) == ["a", "b", "c"]
    await_exit(ref)
  end

  test "a slow drip delivers the first token before the stream finishes" do
    script = [
      {:send, [@headers, frame("first")]},
      {:sleep, 150},
      {:send, frame("second")},
      {:sleep, 50},
      {:send, "data: [DONE]\n\n"},
      :close
    ]

    server = start_server(script)
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:token, "first"}, 500
    rest = collect()
    assert "first" <> tokens(rest) == "firstsecond"
    await_exit(ref)
  end

  test "a malformed data frame aborts the stream and closes the connection" do
    # malformed.txt: two good frames, a broken JSON frame, then [DONE] (never
    # reached). The partial reply is kept in the failure report.
    server =
      start_server([
        {:send, [@headers, fixture("malformed.txt"), "data: [DONE]\n\n"]},
        {:wait_close, 2_000}
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "Hello, "
    assert failures(messages) == ["[llm: malformed SSE data frame — stream aborted]"]

    assert {:stream_failed, "[llm: malformed SSE data frame — stream aborted]", "Hello, "} in messages

    assert_receive {:sse_closed}, 3_000
    await_exit(ref)
  end

  test "a graceful disconnect without [DONE] keeps partial content and reports it" do
    server = start_server([{:send, [@headers, frame("partial")]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "partial"
    assert failures(messages) == ["[llm: stream ended without completion]"]
    await_exit(ref)
  end

  test "a mid-stream TCP reset reports a lost connection" do
    # Content-Length overstates the body so the RST is an error, not a
    # graceful end-of-body (connection-close framing treats close as :done).
    headers =
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
        "content-length: 1000\r\nconnection: close\r\n\r\n"

    server = start_server([{:send, [headers, frame("partial")]}, {:sleep, 50}, :reset])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "partial"
    assert failures(messages) == ["[llm: connection lost mid-stream]"]
    await_exit(ref)
  end

  test "silence past the idle timeout aborts and closes the connection" do
    server =
      start_server([
        {:send, [@headers, frame("one")]},
        {:sleep, 1_000},
        {:wait_close, 2_000}
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server), idle_timeout: 150)

    messages = collect()

    assert tokens(messages) == "one"
    assert failures(messages) == ["[llm: timed out waiting for stream data]"]
    assert_receive {:sse_closed}, 3_000
    await_exit(ref)
  end

  test "cancel keeps the partial reply, reports cancelled, and closes the connection" do
    script = [
      {:send, [@headers, frame("partial")]},
      {:sleep, 1_000},
      {:send, frame("late")},
      {:sleep, 100},
      {:wait_close, 3_000}
    ]

    server = start_server(script)
    {pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:token, "partial"}, 1_000
    send(pid, :cancel)

    messages = collect()

    assert {:stream_done, %{content: "partial", reasoning: "", tool_calls: [], cancelled: true}} in messages

    assert failures(messages) == []
    assert_receive {:sse_closed}, 2_000
    await_exit(ref)
  end

  test "partial tool fragments are dropped on cancel" do
    # A cancel mid tool-call must never leak a half-assembled call: the report
    # carries only the content (ADR 0007 §4).
    script =
      [{:send, [@headers, tool_frames("call_1", "write_file", ["{\"pa"])]}] ++
        [
          {:sleep, 1_000},
          {:send,
           ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":1}"}}]}}\n\n)},
          {:wait_close, 2_000}
        ]

    server = start_server(script)
    {pid, ref} = start_stream(SSEServer.base_url(server))

    # No content frames: sync on the request, then give the fragments time to
    # land before cancelling.
    assert_receive {:sse_request, "POST", _, _, _body}, 1_000
    Process.sleep(100)
    send(pid, :cancel)

    assert reported?(collect(), fn
             {:stream_done, %{tool_calls: [], cancelled: true}} -> true
             _other -> false
           end)

    await_exit(ref)
  end

  test "HTTP 401 reports the provider message; a non-JSON 502 falls back to the status" do
    unauthorized =
      ~s({"error":{"message":"invalid api key"}})

    server =
      start_server([
        {:send, json_response(401, unauthorized)},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))
    messages = collect()

    assert failures(messages) == ["[llm: HTTP 401 — invalid api key]"]
    await_exit(ref)

    server2 = start_server([{:send, json_response(502, "bad gateway")}, :close])
    {_pid2, ref2} = start_stream(SSEServer.base_url(server2))
    messages2 = collect()

    assert failures(messages2) == ["[llm: HTTP 502]"]
    await_exit(ref2)
  end

  test "a non-2xx drain honors :cancel" do
    body = ~s({"error":{"message":"invalid api key"}})

    server =
      start_server([
        {:send, json_response(401, body)},
        {:sleep, 2_000},
        {:wait_close, 2_000}
      ])

    {pid, ref} = start_stream(SSEServer.base_url(server))
    send(pid, :cancel)

    messages = collect()

    assert reported?(messages, fn
             {:stream_done, %{cancelled: true}} -> true
             _other -> false
           end)

    await_exit(ref)
  end

  test "unrelated mailbox messages are ignored mid-stream and mid-drain" do
    script = [
      {:send, [@headers, frame("kept")]},
      {:sleep, 300},
      {:send, "data: [DONE]\n\n"},
      :close
    ]

    server = start_server(script)
    {pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:token, "kept"}, 500
    send(pid, {:unrelated, :junk})
    assert match?({:stream_done, _report}, Enum.find(collect(), &match?({:stream_done, _}, &1)))
    await_exit(ref)
  end

  test "HTTP trailers are ignored: mid-stream and while draining an error" do
    chunked_ok =
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
        "transfer-encoding: chunked\r\n\r\n"

    server =
      start_server([
        {:send, [chunked_ok, chunk(frame("partial"))]},
        {:sleep, 50},
        {:send, "0\r\nx-check: 1\r\n\r\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()
    assert tokens(messages) == "partial"
    assert failures(messages) == ["[llm: stream ended without completion]"]
    await_exit(ref)

    chunked_error =
      "HTTP/1.1 500 Oops\r\ncontent-type: application/json\r\n" <>
        "transfer-encoding: chunked\r\n\r\n"

    body = ~s({"error":{"message":"boom"}})

    server2 =
      start_server([
        {:send, [chunked_error, chunk(body)]},
        {:sleep, 50},
        {:send, "0\r\nx-check: 1\r\n\r\n"},
        :close
      ])

    {_pid2, ref2} = start_stream(SSEServer.base_url(server2))
    assert ["[llm: HTTP 500 — boom]"] = failures(collect())
    await_exit(ref2)
  end

  test "the happy path closes the connection at [DONE]" do
    server =
      start_server([
        {:send, [@headers, frame("done")]},
        {:send, "data: [DONE]\n\n"},
        {:wait_close, 2_000}
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert tokens(collect()) == "done"
    assert_receive {:sse_closed}, 2_000
    await_exit(ref)
  end

  test "the idle timeout resets on every chunk" do
    script =
      [{:send, [@headers, frame("a")]}] ++
        Enum.flat_map(1..8, fn i -> [{:sleep, 60}, {:send, frame("b#{i}")}] end) ++
        [{:send, "data: [DONE]\n\n"}, :close]

    server = start_server(script)

    # Each gap is well under the timeout; only a total-budget implementation
    # would abort here.
    {_pid, ref} = start_stream(SSEServer.base_url(server), idle_timeout: 150)

    messages = collect()
    assert tokens(messages) == "a" <> Enum.map_join(1..8, "", &"b#{&1}")
    assert failures(messages) == []
    await_exit(ref)
  end

  test "a redirect is not followed and reports the status" do
    server =
      start_server([
        {:send,
         "HTTP/1.1 307 Temporary Redirect\r\nlocation: /chat/completions\r\n" <>
           "content-length: 0\r\nconnection: close\r\n\r\n"},
        {:wait_close, 1_000}
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    # Exactly one request: a followed redirect would POST again (and bill).
    assert_receive {:sse_request, "POST", "/chat/completions", _headers, _body}, 2_000
    assert ["[llm: HTTP 307]"] = failures(collect())
    refute_receive {:sse_request, _, _, _, _}, 300

    await_exit(ref)
  end

  test "an error body over the drain cap is truncated; unrelated messages are ignored" do
    # A valid provider message past the 64 KiB cap must NOT be reported: only
    # the first 64 KiB survive (an unbounded drain would print "late").
    prefix = String.duplicate(" ", 70_000)
    body = prefix <> ~s({"error":{"message":"late"}})

    headers =
      "HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"

    # Two writes so the second lands with the cap already reached.
    server =
      start_server([
        {:send, headers},
        {:send, prefix},
        {:sleep, 20},
        {:send, ~s({"error":{"message":"late"}})},
        :close
      ])

    {pid, ref} = start_stream(SSEServer.base_url(server))

    send(pid, {:unrelated, :junk})

    assert ["[llm: HTTP 502]"] = failures(collect())
    await_exit(ref)
  end

  test "cancel while waiting for response headers is honored at the next check" do
    # The server accepts but never answers: Req.post blocks in the header
    # phase, where our mailbox is not read. The cancel is picked up as soon as
    # the header wait ends.
    server = start_server([{:sleep, 1_000}, :close])
    {pid, ref} = start_stream(SSEServer.base_url(server), idle_timeout: 200)

    assert_receive {:sse_request, _, _, _, _}, 1_000
    send(pid, :cancel)

    messages = collect()

    assert reported?(messages, fn
             {:stream_done, %{cancelled: true}} -> true
             _other -> false
           end)

    await_exit(ref)
  end

  test "a body that never finishes hits the drain deadline" do
    headers =
      "HTTP/1.1 504 Slow\r\ncontent-type: application/json\r\n" <>
        "content-length: 500\r\nconnection: close\r\n\r\n"

    # Trickle a byte every 400 ms: the 5 s budget is absolute, not per message.
    trickle = Enum.flat_map(1..20, fn _i -> [{:send, "{"}, {:sleep, 400}] end)
    server = start_server([{:send, headers} | trickle])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:stream_failed, "[llm: HTTP 504]", _partial}, 7_000
    await_exit(ref)
  end

  test "a dropped connection while draining an error still reports the status" do
    headers =
      "HTTP/1.1 503 Busy\r\ncontent-type: application/json\r\n" <>
        "content-length: 500\r\nconnection: close\r\n\r\n"

    server = start_server([{:send, [headers, "partial"]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert ["[llm: HTTP 503]"] = failures(collect())
    await_exit(ref)
  end

  test "the request carries the conversation history and the tool catalogue" do
    server = start_server([{:send, [@headers, "data: [DONE]\n\n"]}, :close])

    messages = [
      %{role: "user", content: "hello"},
      %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{
            id: "call_1",
            type: "function",
            function: %{name: "read_file", arguments: "{\"path\":\"a\"}"}
          }
        ]
      },
      %{role: "tool", tool_call_id: "call_1", content: "{\"ok\":true}"}
    ]

    tools = [%{type: "function", function: %{name: "read_file", parameters: %{}}}]
    base = SSEServer.base_url(server) <> "/"
    {_pid, ref} = start_stream(base, messages: messages, tools: tools)
    assert_receive {:sse_request, method, path, headers, body}, 2_000

    assert method == "POST"
    assert path == "/chat/completions"
    assert headers["authorization"] == "Bearer test-key-123"
    assert headers["accept"] == "text/event-stream"

    decoded = Jason.decode!(body)

    assert decoded["model"] == "test-model"
    assert decoded["stream"] == true
    assert decoded["stream_options"] == %{"include_usage" => true}
    assert decoded["messages"] == roundtrip(messages)
    assert decoded["tools"] == roundtrip(tools)

    await_exit(ref)
  end

  test "a connection error after Esc still reports the cancel" do
    # The server accepts but stalls; Esc lands while Req.post is still waiting
    # for headers, and the eventual dial failure is reported as a cancel.
    server = start_server([{:sleep, 300}, :close])
    {pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:sse_request, _, _, _, _body}, 1_000
    send(pid, :cancel)

    assert {:stream_done, %{cancelled: true}} = done(collect())
    await_exit(ref)
  end

  test "Esc queued before the headers arrive cancels at the first check" do
    # 200 headers arrive late; the cancel is already in the mailbox when
    # handle_response runs, so the stream never starts.
    server =
      start_server([
        {:sleep, 200},
        {:send, [@headers, frame("never")]},
        {:sleep, 60_000},
        {:wait_close, 1_000}
      ])

    {pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:sse_request, _, _, _, _body}, 1_000
    send(pid, :cancel)

    assert {:stream_done, %{cancelled: true}} = done(collect())
    refute_receive {:token, _text}, 100
    await_exit(ref)
  end

  test "a refused connection degrades to a connection-failed report" do
    port = free_port()

    {_pid, ref} = start_stream("http://127.0.0.1:#{port}")

    messages = collect()

    assert [message] = failures(messages)
    assert message =~ "[llm: connection failed: "

    assert Enum.any?(messages, fn
             {:stream_failed, ^message, ""} -> true
             _other -> false
           end)

    await_exit(ref)
  end

  test "a malformed base_url is a connection failure, not a crashed producer" do
    {_pid, ref} = start_stream("api.example.com/v1")

    messages = collect()

    assert [message] = failures(messages)
    assert message =~ "[llm: connection failed: "
    await_exit(ref)
  end

  test "an {:error, _} provider is a connection failure, not a crash" do
    agent = self()

    {:ok, pid} =
      Task.start(fn -> ChatStream.run(agent, {:error, "missing provider config"}, [], []) end)

    ref = Process.monitor(pid)

    assert ["[llm: connection failed: missing provider config]"] = failures(collect())
    await_exit(ref)
  end

  test "the API key is redacted from a failure message that quotes it" do
    # The request must actually reach Mint's header validation for its message
    # to quote the header, so point at a listener that accepts and stalls.
    server = start_server([{:sleep, 500}, :close])
    agent = self()

    for key <- ["test-key-é123", "test-key\n123", ~s(test-key"123)] do
      provider = {:ok, %Config{base_url: SSEServer.base_url(server), model: "m", api_key: key}}
      {:ok, pid} = Task.start(fn -> ChatStream.run(agent, provider, [], []) end)
      ref = Process.monitor(pid)

      assert [message] = failures(collect())
      assert message =~ "[llm: connection failed: "
      refute message =~ key
      refute message =~ "test-key"
      await_exit(ref)
    end
  end

  test "a provider error body echoing the key is redacted in every form" do
    # Both the bare key and the quote-delimited echo must be redacted.
    echoed = ~s({"error":{"message":"bad key: test-key-123 and \\"test-key-123\\""}})
    server = start_server([{:send, json_response(401, echoed)}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert ["[llm: HTTP 401 — bad key: [redacted] and \"[redacted]\"]"] =
             failures(collect())

    await_exit(ref)
  end

  test "a provider error body with the inspect-escaped key form is redacted too" do
    # For a key containing a quote, Mint's error renders the header value with
    # inspect escaping; a provider (or upstream proxy) can echo that back.
    key = ~s(test"key-123)

    escaped =
      key
      |> inspect()
      |> String.slice(1..-2//1)

    body = Jason.encode!(%{"error" => %{"message" => "raw: #{key} escaped: #{escaped}"}})
    server = start_server([{:send, json_response(401, body)}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server), api_key: key)

    assert ["[llm: HTTP 401 — raw: [redacted] escaped: [redacted]]"] =
             failures(collect())

    await_exit(ref)
  end

  test "an unusable base_url or a non-printable api_key is a connection failure" do
    # These would make Req raise (missing host/scheme) or finch exit(:badarg)
    # (port out of range), and Mint quotes the header for a non-ASCII key;
    # every case degrades to a failure report that never carries the key.
    for {key, base} <- [
          {"test-key-123", "http://bad host/x"},
          {"test-key-123", "api.example.com/v1"},
          {"test-key-123", "http:///v1"},
          {"test-key-123", "ftp://127.0.0.1/v1"},
          {"test-key-123", "http://127.0.0.1:99999999999/v1"},
          {"test-key-123", "http://exämple.com/v1"},
          {"test-key-é123", "http://127.0.0.1:1"},
          {<<"test", 0, "key">>, "http://127.0.0.1:1"}
        ] do
      provider = {:ok, %Config{base_url: base, model: "m", api_key: key}}
      agent = self()
      {:ok, pid} = Task.start(fn -> ChatStream.run(agent, provider, [], []) end)
      ref = Process.monitor(pid)

      messages = collect()
      assert [message] = failures(messages)
      assert message =~ "[llm: connection failed: "
      refute message =~ "test-key"
      await_exit(ref)
    end
  end

  test "a single SSE frame over 1 MiB aborts the stream instead of growing the buffer" do
    # No blank line ever completes the frame: the parser buffers forever unless
    # ChatStream caps it.
    blob = String.duplicate("x", 512 * 1024)

    script =
      [{:send, @headers}, {:send, "data: " <> blob}] ++
        Enum.flat_map(1..2, fn _i -> [{:send, blob}, {:sleep, 10}] end) ++
        [{:wait_close, 2_000}]

    server = start_server(script)
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert failures(messages) == ["[llm: SSE frame exceeded 1 MiB — stream aborted]"]
    assert tokens(messages) == ""
    assert_receive {:sse_closed}, 3_000
    await_exit(ref)
  end

  # A reasoning delta frame (issue #78): both ecosystem spellings. Built as a
  # map so the JSON is valid by construction (iodata frames are legal in the
  # server's scripts).
  defp reasoning_frame(field, content) do
    frame = %{"choices" => [%{"index" => 0, "delta" => %{field => content}}]}
    ["data: ", Jason.encode!(frame), "\n\n"]
  end

  test "reasoning_content frames become {:reasoning, _} messages and ride the done report" do
    frames = [
      reasoning_frame("reasoning_content", "The user asks "),
      reasoning_frame("reasoning_content", "about Elixir."),
      frame("Elixir processes run independently."),
      "data: [DONE]\n\n"
    ]

    server = start_server([{:send, [@headers | frames]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert for({:reasoning, text} <- messages, do: text) == ["The user asks ", "about Elixir."]
    assert tokens(messages) == "Elixir processes run independently."

    assert {:stream_done,
            %{
              content: "Elixir processes run independently.",
              reasoning: "The user asks about Elixir.",
              tool_calls: [],
              cancelled: false
            }} in messages

    assert failures(messages) == []
    await_exit(ref)
  end

  test "the reasoning field name is captured too (the OpenRouter spelling)" do
    frames = [
      reasoning_frame("reasoning", "thinking "),
      reasoning_frame("reasoning", "hard"),
      "data: [DONE]\n\n"
    ]

    server = start_server([{:send, [@headers | frames]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert for({:reasoning, text} <- messages, do: text) == ["thinking ", "hard"]
    assert {:stream_done, %{reasoning: "thinking hard", content: ""}} = done(messages)
    await_exit(ref)
  end

  test "reasoning shape misses stay silent: empty strings, non-strings, role-only frames" do
    frames = [
      reasoning_frame("reasoning_content", ""),
      ~s(data: {"choices":[{"index":0,"delta":{"reasoning_content":42}}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{"reasoning":null}}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    server = start_server([{:send, [@headers | frames]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert for({:reasoning, text} <- messages, do: text) == []
    assert {:stream_done, %{reasoning: ""}} = done(messages)
    assert failures(messages) == []
    await_exit(ref)
  end

  test "reasoning_content is stripped from the request wire (DeepSeek-class 400s)" do
    server = start_server([{:send, [@headers, "data: [DONE]\n\n"]}, :close])

    messages = [
      %{role: "user", content: "hello"},
      %{role: "assistant", content: "hi", reasoning_content: "I pondered."},
      %{role: "user", content: "again"}
    ]

    base = SSEServer.base_url(server) <> "/"
    {_pid, ref} = start_stream(base, messages: messages)
    assert_receive {:sse_request, _method, _path, _headers, body}, 2_000

    decoded = Jason.decode!(body)
    stripped = Enum.map(messages, &Map.delete(&1, :reasoning_content))
    assert decoded["messages"] == roundtrip(stripped)
    await_exit(ref)
  end

  test "a final usage frame becomes a {:usage, map} message before done" do
    usage =
      ~s(data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":42,"total_tokens":162}}\n\n)

    server =
      start_server([
        {:send, [@headers, frame("Hello")]},
        {:send, usage},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))
    messages = collect()

    assert tokens(messages) == "Hello"

    assert {:usage, %{prompt_tokens: 120, completion_tokens: 42, total_tokens: 162}} in messages

    usage_index = Enum.find_index(messages, &match?({:usage, _usage}, &1))
    done_index = Enum.find_index(messages, &match?({:stream_done, _report}, &1))
    assert usage_index < done_index
    await_exit(ref)
  end

  test "a usage frame carrying choices emits both the token and the usage" do
    both =
      ~s(data: {"choices":[{"index":0,"delta":{"content":"tail"}}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}\n\n)

    server =
      start_server([
        {:send, [@headers, both]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))
    messages = collect()

    assert tokens(messages) == "tail"
    assert {:usage, %{prompt_tokens: 5, completion_tokens: 1, total_tokens: 6}} in messages
    await_exit(ref)
  end

  test "a malformed usage object is ignored, not an error" do
    for bad <- [
          ~s({"choices":[],"usage":{"prompt_tokens":"a","completion_tokens":1,"total_tokens":2}}),
          ~s({"choices":[],"usage":{"prompt_tokens":1,"total_tokens":2}}),
          ~s({"choices":[],"usage":"none"}),
          ~s({"choices":[],"usage":null}),
          # Hostile/buggy counts are not accounting data either.
          ~s({"choices":[],"usage":{"prompt_tokens":-1,"completion_tokens":1,"total_tokens":2}}),
          ~s({"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":-2}})
        ] do
      server =
        start_server([
          {:send, [@headers, "data: " <> bad <> "\n\n"]},
          {:send, "data: [DONE]\n\n"},
          :close
        ])

      {_pid, ref} = start_stream(SSEServer.base_url(server))
      messages = collect()

      refute Enum.any?(messages, &match?({:usage, _}, &1))
      assert failures(messages) == []
      assert Enum.any?(messages, &match?({:stream_done, _report}, &1))
      await_exit(ref)
    end
  end

  ## Tool-call streaming (ADR 0007 §1)

  test "streamed tool_calls assemble across frames into the done report" do
    fragments = ["{\"pa", "th\":", " \"lib/", "foo.ex\", \"off", "set\": 5, \"limit\": 10}"]

    server =
      start_server([
        {:send,
         [@headers, frame("Let me look."), tool_frames("call_abc", "read_file", fragments)]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))
    messages = collect()

    assert tokens(messages) == "Let me look."

    assert {:stream_done,
            %{
              content: "Let me look.",
              reasoning: "",
              cancelled: false,
              tool_calls: [
                %{
                  id: "call_abc",
                  name: "read_file",
                  args: %{"path" => "lib/foo.ex", "offset" => 5, "limit" => 10},
                  raw_args: ~s({"path": "lib/foo.ex", "offset": 5, "limit": 10}),
                  error: nil
                }
              ]
            }} in messages

    await_exit(ref)
  end

  test "tool arguments split mid-escape and mid-utf8 reassemble correctly" do
    # The fragment boundary sits inside \\u and a raw multi-byte char; binary
    # concatenation before parsing reassembles both.
    args = "{\"path\":\"ä\\\"x←.exs\",\"q\":\"ünïcode\"}"
    {a, b} = String.split_at(args, 12)

    server =
      start_server([
        {:send, [@headers, tool_frames("call_1", "write_file", [a, b])]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert {:stream_done, %{tool_calls: [%{args: %{"path" => "ä\"x←.exs", "q" => "ünïcode"}}]}} =
             done(collect())

    await_exit(ref)
  end

  test "malformed argument JSON finishes as an error call, not a stream failure" do
    server =
      start_server([
        {:send, [@headers, tool_frames("call_1", "read_file", ["{\"path\": "])]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert failures(messages) == []

    assert reported?(messages, fn
             {:stream_done,
              %{tool_calls: [%{id: "call_1", args: nil, error: "invalid JSON arguments"}]}} ->
               true

             _other ->
               false
           end)

    await_exit(ref)
  end

  test "a call without an id gets a synthesized one; a call without a name errors" do
    no_id =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"read_file","arguments":"{}"}}]}}]}\n\n)

    no_name =
      ~s(data: {"choices":[{"index":1,"delta":{"tool_calls":[{"index":1,"id":"call_x","type":"function","function":{"arguments":"{}"}}]}}]}\n\n)

    server =
      start_server([
        {:send, [@headers, no_id, no_name]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert {:stream_done, %{tool_calls: calls}} = done(collect())

    assert {%{id: "call_0", name: "read_file"} = synthesized,
            %{id: "call_x", name: "", error: "missing function name"}} =
             {Enum.find(calls, &(&1.id == "call_0")), Enum.find(calls, &(&1.id == "call_x"))}

    assert synthesized.error == nil
    await_exit(ref)
  end

  test "interleaved parallel calls keep separate buffers per index" do
    defrag = fn index, frag ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index},"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
    end

    opening = fn index, id, name ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index},"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)
    end

    # Fragments alternate between the two calls; order of finish is by index.
    script =
      [
        {:send,
         [@headers, opening.(0, "call_a", "read_file"), opening.(1, "call_b", "list_directory")]}
      ] ++
        [
          {:send, [defrag.(0, "{\"pa"), defrag.(1, "{\"pa")]},
          {:send, [defrag.(0, "th\":\"a\"}"), defrag.(1, "th\":\".\"}")]}
        ] ++
        [{:send, "data: [DONE]\n\n"}, :close]

    server = start_server(script)
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert {:stream_done, %{tool_calls: [first, second]}} = done(collect())
    assert {first.id, first.name, first.args} == {"call_a", "read_file", %{"path" => "a"}}
    assert {second.id, second.name, second.args} == {"call_b", "list_directory", %{"path" => "."}}

    await_exit(ref)
  end

  test "non-list and empty tool_calls deltas are skipped" do
    garbage =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":"nope"}}]}\n\n) <>
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[]}}]}\n\n) <>
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":["string"]}}]}\n\n)

    server =
      start_server([
        {:send, [@headers, garbage, "data: [DONE]\n\n"]},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert {:stream_done, %{tool_calls: []}} = done(collect())
    await_exit(ref)
  end

  ## Synthetic fix-json repair at the [DONE] terminal (ADR 0021 §3)

  defp start_per_connection(scripts) do
    {:ok, server} = SSEServer.start_link(:per_connection, scripts)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  # A minimal advertised-tool def (string keys, Tools.schema's shape): the
  # repair gate repairs only calls whose name the catalogue advertised
  # (ADR 0021 §3).
  defp advertised(name), do: %{"type" => "function", "function" => %{"name" => name}}

  # The repair endpoint's responses (application/json: Req pre-decodes them).
  defp repair_ok(fixed) do
    content = Jason.encode!(%{"success" => true, "fixed" => fixed})
    json_response(200, Jason.encode!(%{choices: [%{message: %{content: content}}]}))
  end

  defp repair_failure do
    json_response(
      200,
      Jason.encode!(%{choices: [%{message: %{content: ~s({"success": false})}}]})
    )
  end

  test "a synthetic ctx repairs malformed argument JSON at [DONE]" do
    server =
      start_per_connection([
        [
          {:send, [@headers, tool_frames("call_1", "read_file", ["{\"path\": "])]},
          {:send, "data: [DONE]\n\n"},
          :close
        ],
        [{:send, repair_ok(%{"path" => "a.txt"})}, :close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {_pid, ref} =
      start_stream(SSEServer.base_url(server), synthetic: ctx, tools: [advertised("read_file")])

    # conn 0 is the stream; the repair (conn 1) completes before stream_done.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000

    assert {:stream_done, %{content: "", tool_calls: [call], cancelled: false}} =
             done(collect())

    assert call.args == %{"path" => "a.txt"}
    assert call.error == nil

    assert_receive {:sse_request, "POST", "/chat/completions", repair_headers, repair_body},
                   2_000

    assert repair_headers["authorization"] == "Bearer test-key-123"

    decoded = Jason.decode!(repair_body)
    assert decoded["model"] == "hf:syntheticlab/fix-json"

    assert [%{"role" => "user", "content" => prompt}] = decoded["messages"]
    assert prompt =~ ~s({"path": )
    assert prompt =~ "Here's the string:\n"

    await_exit(ref)
  end

  test "a failed repair leaves the error call exactly as the no-key path built it" do
    server =
      start_per_connection([
        [
          {:send, [@headers, tool_frames("call_1", "read_file", ["{\"path\": "])]},
          {:send, "data: [DONE]\n\n"},
          :close
        ],
        [{:send, repair_failure()}, :close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {_pid, ref} =
      start_stream(SSEServer.base_url(server), synthetic: ctx, tools: [advertised("read_file")])

    assert {:stream_done,
            %{
              tool_calls: [
                %{
                  id: "call_1",
                  name: "read_file",
                  args: nil,
                  raw_args: ~s({"path": ),
                  error: "invalid JSON arguments"
                }
              ],
              cancelled: false
            }} = done(collect())

    await_exit(ref)
  end

  test "a cancel landing during a repair POST wins the terminal" do
    server =
      start_per_connection([
        [
          {:send,
           [@headers, frame("partial"), tool_frames("call_1", "read_file", ["{\"path\": "])]},
          {:send, "data: [DONE]\n\n"},
          :close
        ],
        [{:sleep, 150}, {:send, repair_ok(%{"path" => "a.txt"})}, :close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {pid, ref} =
      start_stream(SSEServer.base_url(server), synthetic: ctx, tools: [advertised("read_file")])

    # conn 0 (the stream), then conn 1 — the repair POST is in flight.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    send(pid, :cancel)

    assert {:stream_done, %{content: "partial", tool_calls: [], cancelled: true}} =
             done(collect())

    await_exit(ref)
  end

  test "calls fix-json cannot help are reported untouched, with no repair request" do
    no_name =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"arguments":"{}"}}]}}]}\n\n)

    server =
      start_per_connection([
        [{:send, [@headers, no_name]}, {:send, "data: [DONE]\n\n"}, :close],
        [:close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {_pid, ref} =
      start_stream(SSEServer.base_url(server), synthetic: ctx, tools: [advertised("read_file")])

    assert {:stream_done,
            %{
              tool_calls: [%{id: "call_x", name: "", args: %{}, error: "missing function name"}],
              cancelled: false
            }} = done(collect())

    # Exactly one request: no repair POST for a missing function name.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    refute_receive {:sse_request, _, _, _, _}, 300

    await_exit(ref)
  end

  test "a cancel mid-loop aborts the remaining repairs" do
    # Two repairable calls; the first repair responds, then a cancel that
    # landed mid-loop stops the second repair entirely.
    opening = fn index, id, name ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index},"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)
    end

    fragment = fn index, frag ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index},"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
    end

    frames =
      [opening.(0, "call_a", "read_file"), opening.(1, "call_b", "write_file")] ++
        [fragment.(0, "{\"path\": "), fragment.(1, "{\"content\": ")]

    server =
      start_per_connection([
        [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close],
        [{:sleep, 150}, {:send, repair_ok(%{"path" => "a.txt"})}, :close],
        [{:send, repair_ok(%{"content" => "x"})}, :close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {pid, ref} =
      start_stream(SSEServer.base_url(server),
        synthetic: ctx,
        tools: [advertised("read_file"), advertised("write_file")]
      )

    # conn 0 (the stream), then conn 1 — repair 1 in flight.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    send(pid, :cancel)

    # The in-flight repair returns, the remaining repair never fires: the
    # terminal is the cancel (partial content kept, tool fragments dropped).
    assert {:stream_done, %{content: "", tool_calls: [], cancelled: true}} = done(collect())

    # The script count proves it: conn 2 never happened.
    refute_receive {:sse_request, _, _, _, _}, 500

    await_exit(ref)
  end

  test "a broken-args call for a tool the catalogue never advertised gets no repair" do
    # The agent discards unadvertised names as unknown tools — repairing one
    # spends quota for output the agent throws away (ADR 0021 §3).
    server =
      start_per_connection([
        [
          {:send, [@headers, tool_frames("call_1", "explode", ["{\"path\": "])]},
          {:send, "data: [DONE]\n\n"},
          :close
        ],
        [{:send, repair_ok(%{"path" => "a.txt"})}, :close]
      ])

    ctx = %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

    {_pid, ref} =
      start_stream(SSEServer.base_url(server), synthetic: ctx, tools: [advertised("read_file")])

    assert {:stream_done,
            %{
              tool_calls: [%{id: "call_1", name: "explode", error: "invalid JSON arguments"}],
              cancelled: false
            }} = done(collect())

    # Exactly one connection: the stream, no repair POST.
    assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 2_000
    refute_receive {:sse_request, _, _, _, _}, 300

    await_exit(ref)
  end

  defp roundtrip(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  test "episode accumulations past 4 MiB abort the stream" do
    # ~9 half-MiB frames — three of them REASONING (issue #78): thinking
    # bytes count toward the episode budget exactly like content bytes. No
    # single frame trips the 1 MiB frame cap and the stream never idles —
    # only the episode cap stops it.
    blob = String.duplicate("x", 512 * 1024)

    frames =
      Enum.map(1..9, fn i ->
        if rem(i, 3) == 0, do: reasoning_frame("reasoning_content", blob), else: frame(blob)
      end)

    server =
      start_server([
        {:send, [@headers | frames]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert ["[llm: episode exceeded 4 MiB — stream aborted]"] = failures(messages)
    await_exit(ref)
  end

  test "a flood of fresh-index id-only deltas is capped by call count" do
    # Each delta opens a new index carrying a large id: bytes stay under the
    # episode cap while the accumulator map grows — the count cap stops it.
    id_only = fn index ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index},"id":"#{String.duplicate("i", 1024)}-#{index}","type":"function","function":{"name":"read_file","arguments":""}}]}}]}\n\n)
    end

    frames = Enum.map(0..64, id_only)

    server =
      start_server([
        {:send, [@headers | frames]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert ["[llm: more than 64 tool calls — stream aborted]"] = failures(messages)
    await_exit(ref)
  end

  test "an id-less fresh-index spray is capped too (entries, not ids, count)" do
    bare_index = fn index ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":#{index}}]}}]}\n\n)
    end

    frames = Enum.map(0..64, bare_index)

    server =
      start_server([
        {:send, [@headers | frames]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert ["[llm: more than 64 tool calls — stream aborted]"] = failures(collect())
    await_exit(ref)
  end

  test "one call split into many id-echoing fragments is NOT capped" do
    # Compat servers echo id+name on every fragment; a large write_file splits
    # into dozens of them. Distinct indices are what count — this must pass.
    echo_fragment = fn fragment ->
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_big","type":"function","function":{"name":"write_file","arguments":#{Jason.encode!(fragment)}}}]}}]}\n\n)
    end

    pieces = for i <- 1..70, do: echo_fragment.("chunk#{i};")

    server =
      start_server([
        {:send, [@headers | pieces]},
        {:send, "data: [DONE]\n\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert failures(messages) == []

    assert {:stream_done, %{tool_calls: [%{id: "call_big", name: "write_file"}]}} =
             done(messages)

    await_exit(ref)
  end

  defp json_response(status, body) do
    "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  defp chunk(data) do
    size = byte_size(data)
    Integer.to_string(size, 16) <> "\r\n" <> data <> "\r\n"
  end

  # An ephemeral port with nothing listening on it.
  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

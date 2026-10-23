defmodule DashFloat.LLM.ChatStreamTest do
  @moduledoc false
  # Not async: each test owns a real loopback socket and a shared stream
  # supervisor task list.
  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.LLM.ChatStream
  alias DashFloat.SSEServer

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  @fixture_dir Path.expand("../../fixtures/sse", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixture_dir, name))

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  defp start_server(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp provider(base_url) do
    %Config{base_url: base_url, model: "test-model", api_key: "test-key-123"}
  end

  # Runs the producer as a Task (like the TUI does), with the test process as
  # the UI, and returns `{task_pid, monitor_ref}`.
  defp start_stream(base_url, opts \\ []) do
    ui = self()
    prompt = Keyword.get(opts, :prompt, "hello")
    run_opts = Keyword.take(opts, [:idle_timeout])

    {:ok, pid} = Task.start(fn -> ChatStream.run(ui, provider(base_url), prompt, run_opts) end)
    {pid, Process.monitor(pid)}
  end

  # Collects contract messages through the terminal {:phase, :idle}.
  defp collect(acc \\ []) do
    receive do
      {:token, _} = msg -> collect([msg | acc])
      {:entry, _, _} = msg -> collect([msg | acc])
      {:phase, :idle} = msg -> Enum.reverse([msg | acc])
      {:phase, _} = msg -> collect([msg | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  defp tokens(messages) do
    for {:token, text} <- messages, into: "", do: text
  end

  defp system_entries(messages), do: for({:entry, :system, text} <- messages, do: text)

  defp await_exit(ref) do
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
  end

  test "happy path streams tokens in order, finalizes with idle, exits normal" do
    server = start_server([{:send, [@headers, fixture("happy.txt")]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "Hello, world!"
    assert {:phase, :idle} == List.last(messages)
    assert system_entries(messages) == []
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
    # reached). The partial reply is kept.
    server =
      start_server([
        {:send, [@headers, fixture("malformed.txt"), "data: [DONE]\n\n"]},
        {:wait_close, 2_000}
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "Hello, "
    assert system_entries(messages) == ["[llm: malformed SSE data frame — stream aborted]"]
    assert {:phase, :idle} == List.last(messages)
    assert_receive {:sse_closed}, 3_000
    await_exit(ref)
  end

  test "a graceful disconnect without [DONE] keeps partial content and reports it" do
    server = start_server([{:send, [@headers, frame("partial")]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    messages = collect()

    assert tokens(messages) == "partial"
    assert system_entries(messages) == ["[llm: stream ended without completion]"]
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
    assert system_entries(messages) == ["[llm: connection lost mid-stream]"]
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
    assert system_entries(messages) == ["[llm: timed out waiting for stream data]"]
    assert_receive {:sse_closed}, 3_000
    await_exit(ref)
  end

  test "cancel keeps the partial reply, logs [cancelled], and closes the connection" do
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
    assert system_entries(messages) == ["[cancelled]"]
    assert {:phase, :idle} == List.last(messages)
    assert_receive {:sse_closed}, 2_000
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

    assert system_entries(messages) == ["[llm: HTTP 401 — invalid api key]"]
    assert {:phase, :idle} == List.last(messages)
    await_exit(ref)

    server = start_server([{:send, json_response(502, "bad gateway")}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))
    messages = collect()

    assert system_entries(messages) == ["[llm: HTTP 502]"]
    await_exit(ref)
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
    assert system_entries(messages) == ["[cancelled]"]
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
    assert_receive {:phase, :idle}, 2_000
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
    assert system_entries(messages) == ["[llm: stream ended without completion]"]
    await_exit(ref)

    chunked_error =
      "HTTP/1.1 500 Oops\r\ncontent-type: application/json\r\n" <>
        "transfer-encoding: chunked\r\n\r\n"

    body = ~s({"error":{"message":"boom"}})

    server =
      start_server([
        {:send, [chunked_error, chunk(body)]},
        {:sleep, 50},
        {:send, "0\r\nx-check: 1\r\n\r\n"},
        :close
      ])

    {_pid, ref} = start_stream(SSEServer.base_url(server))
    assert ["[llm: HTTP 500 — boom]"] = system_entries(collect())
    await_exit(ref)
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
    assert system_entries(messages) == []
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
    assert ["[llm: HTTP 307]"] = system_entries(collect())
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

    assert ["[llm: HTTP 502]"] = system_entries(collect())
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
    assert system_entries(messages) == ["[cancelled]"]
    assert {:phase, :idle} == List.last(messages)
    await_exit(ref)
  end

  test "a body that never finishes hits the drain deadline" do
    headers =
      "HTTP/1.1 504 Slow\r\ncontent-type: application/json\r\n" <>
        "content-length: 500\r\nconnection: close\r\n\r\n"

    # Trickle a byte every 400 ms: the 5 s budget is absolute, not per message.
    trickle = Enum.flat_map(1..20, fn _ -> [{:send, "{"}, {:sleep, 400}] end)
    server = start_server([{:send, headers} | trickle])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert_receive {:entry, :system, "[llm: HTTP 504]"}, 7_000
    assert_receive {:phase, :idle}, 1_000
    await_exit(ref)
  end

  test "a dropped connection while draining an error still reports the status" do
    headers =
      "HTTP/1.1 503 Busy\r\ncontent-type: application/json\r\n" <>
        "content-length: 500\r\nconnection: close\r\n\r\n"

    server = start_server([{:send, [headers, "partial"]}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert ["[llm: HTTP 503]"] = system_entries(collect())
    await_exit(ref)
  end

  test "the request is a streamed chat completion at <base_url>/chat/completions" do
    server = start_server([{:send, [@headers, "data: [DONE]\n\n"]}, :close])
    base = SSEServer.base_url(server) <> "/"
    {_pid, ref} = start_stream(base)
    assert_receive {:sse_request, method, path, headers, body}, 2_000

    assert method == "POST"
    assert path == "/chat/completions"
    assert headers["authorization"] == "Bearer test-key-123"
    assert headers["accept"] == "text/event-stream"

    assert Jason.decode!(body) == %{
             "model" => "test-model",
             "stream" => true,
             "messages" => [%{"role" => "user", "content" => "hello"}]
           }

    await_exit(ref)
  end

  test "a refused connection degrades to a connection-failed entry" do
    port = free_port()

    {_pid, ref} = start_stream("http://127.0.0.1:#{port}")

    messages = collect()

    assert [message] = system_entries(messages)
    assert message =~ "[llm: connection failed: "
    assert {:phase, :idle} == List.last(messages)
    await_exit(ref)
  end

  test "a malformed base_url is a connection failure, not a crashed producer" do
    {_pid, ref} = start_stream("api.example.com/v1")

    messages = collect()

    assert [message] = system_entries(messages)
    assert message =~ "[llm: connection failed: "
    assert {:phase, :idle} == List.last(messages)
    await_exit(ref)
  end

  test "the API key is redacted from a failure message that quotes it" do
    # The request must actually reach Mint's header validation for its message
    # to quote the header, so point at a listener that accepts and stalls.
    server = start_server([{:sleep, 500}, :close])
    ui = self()

    for key <- ["test-key-é123", "test-key\n123", ~s(test-key"123)] do
      provider = %Config{base_url: SSEServer.base_url(server), model: "m", api_key: key}
      {:ok, pid} = Task.start(fn -> ChatStream.run(ui, provider, "hi") end)
      ref = Process.monitor(pid)

      assert [message] = collect() |> system_entries()
      assert message =~ "[llm: connection failed: "
      refute message =~ key
      refute message =~ "test-key"
      await_exit(ref)
    end
  end

  test "a provider error body echoing the key is redacted" do
    echoed = ~s({"error":{"message":"bad key: test-key-123"}})
    server = start_server([{:send, json_response(401, echoed)}, :close])
    {_pid, ref} = start_stream(SSEServer.base_url(server))

    assert ["[llm: HTTP 401 — bad key: [redacted]]"] = system_entries(collect())
    await_exit(ref)
  end

  test "an unusable base_url or a non-printable api_key is a connection failure" do
    # These would make Req raise (missing host/scheme) or finch exit(:badarg)
    # (port out of range), and Mint quotes the header for a non-ASCII key;
    # every case degrades to a chat entry that never carries the key.
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
      provider = %Config{base_url: base, model: "m", api_key: key}
      ui = self()
      {:ok, pid} = Task.start(fn -> ChatStream.run(ui, provider, "hi") end)
      ref = Process.monitor(pid)

      messages = collect()
      assert [message] = system_entries(messages)
      assert message =~ "[llm: connection failed: "
      refute message =~ "test-key"
      assert {:phase, :idle} == List.last(messages)
      await_exit(ref)
    end
  end

  defp json_response(status, body) do
    "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  defp chunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"

  # An ephemeral port with nothing listening on it.
  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

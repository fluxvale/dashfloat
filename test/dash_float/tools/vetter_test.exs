defmodule DashFloat.Tools.VetterTest do
  @moduledoc false
  # Not async: each test owns a real loopback socket.
  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.SSEServer
  alias DashFloat.Tools.Vetter

  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":#{Jason.encode!(content)}}}]}\n\n)
  end

  defp completion(served), do: [{:send, [@headers, frame(served), "data: [DONE]\n\n"]}, :close]

  defp start_server(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp provider(base_url),
    do: {:ok, %Config{base_url: base_url, model: "test-model", api_key: "test-key-123"}}

  defp call(name \\ "execute_command", args \\ %{"command" => "mix test"}),
    do: %{id: "call_1", name: name, args: args}

  defp vet(server, opts \\ [vet_timeout: 2_000]) do
    url = SSEServer.base_url(server)
    subject = call()
    vendor = provider(url)
    Vetter.verdict(vendor, subject, ["$ mix test"], opts)
  end

  test "a run decision allows the call" do
    server = start_server(completion(~s({"decision":"run","reason":"test run"})))
    assert {:allow} = vet(server)
  end

  test "a confirm decision asks the human" do
    server = start_server(completion(~s({"decision":"confirm","reason":"pushes"})))
    assert {:ask} = vet(server)
  end

  test "an unparseable reply is a failed check" do
    server = start_server(completion("Sounds good!"))
    assert {:error, "safety check returned unparseable output"} = vet(server)
  end

  test "a stream trickling past the vet deadline times out and cancels the stream" do
    server =
      start_server([
        {:send, [@headers, frame("working")]},
        {:sleep, 1_000},
        {:wait_close, 2_000}
      ])

    assert {:error, "safety check timed out after 100ms"} = vet(server, vet_timeout: 100)

    # The deadline sent the stream child :cancel; its connection closes.
    assert_receive {:sse_closed}, 3_000
  end

  test "a refused connection is a failed check" do
    no_listener =
      {:ok, %Config{base_url: "http://127.0.0.1:#{free_port()}", model: "m", api_key: "k"}}

    assert {:error, message} = Vetter.verdict(no_listener, call(), ["$ mix test"])
    assert message =~ "[llm: connection failed: "
  end

  test "the prompt carries the task, the tool, the risk class, the args, and the preview" do
    subject = call("write_file", %{"path" => "lib/keep.txt", "content" => "hi"})

    prompt =
      Vetter.build_prompt(subject, [
        "+++ lib/keep.txt",
        "+ hi"
      ])

    assert prompt =~ "write_file"
    assert prompt =~ "mutating"
    assert prompt =~ "lib/keep.txt"
    # The args ride JSON-in-JSON, so their encoded form shows escaped quotes.
    assert prompt =~ "\\\"content\\\""
    assert prompt =~ "+++ lib/keep.txt"
    assert prompt =~ "+ hi"
    assert prompt =~ "strict JSON"
    assert prompt =~ ~s("decision":"run"|"confirm")
    assert prompt =~ ~r/WITHOUT\s+human confirmation/
  end

  test "args over the 8 KiB cap are truncated with a marker and keep the prompt bounded" do
    big_call =
      call("write_file", %{"path" => "big.txt", "content" => String.duplicate("x", 20_000)})

    prompt = Vetter.build_prompt(big_call, ["+ x"])

    assert prompt =~ "… (truncated)"
    assert byte_size(prompt) < 16_000

    # A byte cut landing mid-codepoint backs off instead of raising.
    multibyte_call =
      call("write_file", %{"path" => "u.txt", "content" => String.duplicate("←", 10_000)})

    multibyte_prompt = Vetter.build_prompt(multibyte_call, ["+ u"])

    assert multibyte_prompt =~ "… (truncated)"
    assert String.valid?(multibyte_prompt)
  end

  test "parse accepts only strict decision JSON" do
    assert Vetter.parse(~s({"decision":"run","reason":"fine"})) == {:ok, :run}
    assert Vetter.parse(~s({"decision":"confirm","reason":"pushes"})) == {:ok, :confirm}
    assert Vetter.parse(~s({"decision":"allow","reason":"no"})) == :error
    assert Vetter.parse(~s({"decision":1})) == :error
    assert Vetter.parse(~s({"reason":"missing decision"})) == :error
    assert Vetter.parse("Sounds good!") == :error
    assert Vetter.parse(~s(["run"])) == :error
  end

  # An ephemeral port with nothing listening on it.
  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end
end

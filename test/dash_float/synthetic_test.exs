defmodule DashFloat.SyntheticTest do
  @moduledoc false
  # Not async: the repair tests own real loopback sockets (SSEServer).
  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.SSEServer
  alias DashFloat.Synthetic

  # The broken tool-call arguments every repair test tries to fix.
  @broken ~s({"path": )

  # Octofriend's fixJsonPrompt, byte-for-byte — the contract the fixer model
  # is custom-trained on (ADR 0021 §3). Asserted verbatim against the wire.
  @verbatim_prompt """
  The following string may be broken JSON. Fix it if possible. Respond with JSON in the following
  format, defined as TypeScript types:

  // Success response:
  type JsonFixSuccess = {
    success: true,

    // The parsed JSON
    fixed: any,
  };

  // Failure response:
  type JsonFixFailure = {
    success: false,
  };

  If it's more-or-less JSON, fix it and respond with the success response. If it's not, respond with
  the failure response. Here's the string:
  """

  defp config(fields), do: struct!(Config, fields)

  defp provider(label, base_url, api_key) do
    %{label: label, base_url: base_url, api_key: api_key}
  end

  ## context/1 — key discovery (ADR 0021 §1)

  test "the active provider's fields win when they carry a Synthetic host and a key" do
    for base_url <- [
          "https://api.synthetic.new/openai/v1",
          "https://synthetic.new/api/openai/v1",
          "https://api.glhf.chat/v1",
          "https://glhf.chat/api/v1"
        ] do
      assert Synthetic.context({:ok, config(base_url: base_url, api_key: " sk-live ")}) ==
               %Synthetic{base_url: base_url, api_key: " sk-live "}
    end
  end

  test "host matching is case-insensitive (URI.parse does not downcase)" do
    base_url = "HTTPS://API.SYNTHETIC.NEW/openai/v1"

    assert Synthetic.context({:ok, config(base_url: base_url, api_key: "sk")}) ==
             %Synthetic{base_url: base_url, api_key: "sk"}
  end

  test "the context struct redacts the key from inspect" do
    ctx = %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "sk-live"}

    refute inspect(ctx) =~ "sk-live"
    refute inspect(ctx, pretty: true, limit: :infinity) =~ "sk-live"
    assert inspect(ctx) =~ "api.synthetic.new"
  end

  test "the active fields miss but a profile provider hits" do
    cfg =
      config(
        base_url: "https://api.openai.com/v1",
        api_key: "sk-openai",
        providers: [
          provider("openai", "https://api.openai.com/v1", "sk-openai"),
          provider("syn", "https://api.glhf.chat/v1", "sk-glhf")
        ]
      )

    assert Synthetic.context({:ok, cfg}) ==
             %Synthetic{base_url: "https://api.glhf.chat/v1", api_key: "sk-glhf"}
  end

  test "a synthetic-host entry with a blank or nil key is skipped" do
    cfg =
      config(
        base_url: "https://api.openai.com/v1",
        api_key: "sk-openai",
        providers: [
          provider("blank", "https://api.synthetic.new/openai/v1", "   "),
          provider("nil", "https://synthetic.new/api/openai/v1", nil),
          provider("good", "https://api.synthetic.new/v1", "sk-ok")
        ]
      )

    assert Synthetic.context({:ok, cfg}) ==
             %Synthetic{base_url: "https://api.synthetic.new/v1", api_key: "sk-ok"}
  end

  test "no synthetic host anywhere is no context" do
    cfg = config(base_url: "https://api.openai.com/v1", api_key: "sk", providers: [])

    assert Synthetic.context({:ok, cfg}) == nil
  end

  test "a nil base_url is no context" do
    assert Synthetic.context({:ok, config(base_url: nil, api_key: "sk")}) == nil
  end

  test "an {:error, _} config is no context" do
    assert Synthetic.context({:error, "missing provider config"}) == nil
  end

  test "a hand-built config holding non-binaries is no context" do
    cfg =
      config(
        base_url: 42,
        api_key: "sk",
        providers: ["junk", provider("junk", "https://api.synthetic.new/v1", 123)]
      )

    assert Synthetic.context({:ok, cfg}) == nil
  end

  ## search_url/1 — the search endpoint derivation (ADR 0021 §6)

  test "the first matching OpenAI-compat suffix is stripped, then /v2/search" do
    for {base, expected} <- [
          {"https://api.synthetic.new/openai/v1", "https://api.synthetic.new/v2/search"},
          {"https://synthetic.new/api/openai/v1/", "https://synthetic.new/api/v2/search"},
          {"https://api.synthetic.new/api/v1", "https://api.synthetic.new/v2/search"},
          {"https://api.glhf.chat/v1", "https://api.glhf.chat/v2/search"},
          {"http://127.0.0.1:53211", "http://127.0.0.1:53211/v2/search"}
        ] do
      ctx = %Synthetic{base_url: base, api_key: "k"}
      assert Synthetic.search_url(ctx) == expected
    end
  end

  ## repair_json/3 — the fix-json round trip (ADR 0021 §3), loopback only

  # Req parses content-length, so the response helper must set it.
  defp json_ok(content_type, body) do
    "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  # The real repair shape: the outer JSON's message content is itself JSON.
  defp content_response(content, content_type \\ "application/json") do
    json_ok(content_type, Jason.encode!(%{choices: [%{message: %{content: content}}]}))
  end

  defp fix_response(fixed, content_type \\ "application/json") do
    content_response(Jason.encode!(%{"success" => true, "fixed" => fixed}), content_type)
  end

  defp start(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp ctx(server), do: %Synthetic{base_url: SSEServer.base_url(server), api_key: "test-key-123"}

  test "success: the fixed value becomes the args map, and the request carries the contract" do
    server = start([{:send, fix_response(%{"path" => "a.txt"})}, :close])

    assert Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000) ==
             {:ok, %{"path" => "a.txt"}}

    assert_receive {:sse_request, "POST", "/chat/completions", headers, body}, 2_000
    assert headers["authorization"] == "Bearer test-key-123"

    decoded = Jason.decode!(body)
    assert decoded["model"] == "hf:syntheticlab/fix-json"
    assert decoded["temperature"] == 0
    assert decoded["response_format"] == %{"type" => "json_object"}

    assert [%{"role" => "user", "content" => content}] = decoded["messages"]
    # Byte fidelity: the verbatim prompt, the raw string appended with no
    # separator (the fixer model is custom-trained on these bytes).
    assert content == @verbatim_prompt <> @broken
  end

  test "success: a binary (non-pre-decoded) body is decoded too" do
    server = start([{:send, fix_response(%{"path" => "a.txt"}, "text/plain")}, :close])

    assert Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000) ==
             {:ok, %{"path" => "a.txt"}}
  end

  test "a fixed value that is itself a JSON string is decoded one more time" do
    # The fixer sometimes wraps the object as a string (Octofriend's
    # parse-tool-call.ts double-decodes).
    server = start([{:send, fix_response(~s({"path": "a.txt"}))}, :close])

    assert Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000) ==
             {:ok, %{"path" => "a.txt"}}
  end

  test "a fixed value that is a non-JSON string is an error" do
    server = start([{:send, fix_response("a.txt")}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "a fixed value that is a JSON string of a non-map is an error too" do
    server = start([{:send, fix_response("[1,2]")}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "a non-map fixed value is an error" do
    server = start([{:send, fix_response("a.txt")}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "a success:false response is an error" do
    server = start([{:send, content_response(~s({"success": false}))}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "an unparseable message content is an error" do
    server = start([{:send, content_response("nope")}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "missing or empty choices, and other shape misses, are errors" do
    for body <- [
          ~s({"choices": []}),
          ~s({"other": 1}),
          ~s({"choices":[{"message":{}}]}),
          ~s({"choices":[{"message":{"content":42}}]})
        ] do
      server = start([{:send, json_ok("application/json", body)}, :close])

      assert {:error, _reason} =
               Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
    end
  end

  test "a binary body that is not JSON is an error too" do
    server = start([{:send, json_ok("text/plain", "junk")}, :close])

    assert {:error, _reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
  end

  test "a non-2xx response is an error naming the status" do
    server =
      start([
        {:send,
         "HTTP/1.1 500 Server Error\r\ncontent-type: application/json\r\n" <>
           "content-length: 0\r\nconnection: close\r\n\r\n"},
        :close
      ])

    assert {:error, reason} = Synthetic.repair_json(@broken, ctx(server), receive_timeout: 2_000)
    assert reason =~ "500"
  end

  test "a repair that outlives :receive_timeout is an error, not a hang" do
    server = start([{:sleep, 200}, {:send, fix_response(%{"path" => "a.txt"})}, :close])

    assert {:error, "fix-json failed: timed out"} =
             Synthetic.repair_json(@broken, ctx(server), receive_timeout: 50)
  end

  test "an unusable ctx degrades to a generic error, never a raise or a key leak" do
    # A host with embedded whitespace: the dial fails, returned as an error.
    assert {:error, "fix-json failed: connection error"} =
             Synthetic.repair_json("{}", %Synthetic{base_url: "http://bad host/x", api_key: "k"})

    # An out-of-range port makes finch exit(:badarg) — caught the same way.
    assert {:error, "fix-json failed: connection error"} =
             Synthetic.repair_json("{}", %Synthetic{
               base_url: "http://127.0.0.1:99999999999/v1",
               api_key: "k"
             })

    # A pinned (hand-built) ctx may hold a non-binary base_url: it raises
    # before any request exists — caught like every other misshape.
    assert {:error, "fix-json failed: connection error"} =
             Synthetic.repair_json("{}", %Synthetic{base_url: 42, api_key: "k\nraw-key"})
  end
end

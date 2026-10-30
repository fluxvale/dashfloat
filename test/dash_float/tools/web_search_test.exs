defmodule DashFloat.Tools.WebSearchTest do
  @moduledoc false
  # Not async: the tests own real loopback sockets (SSEServer). Every request
  # here stays on 127.0.0.1 — never the real search endpoint (ADR 0021).
  use ExUnit.Case, async: false

  alias DashFloat.SSEServer
  alias DashFloat.Tools.WebSearch

  @query "dashfloat elixir"

  # Req parses content-length, so the response helper must set it.
  defp json_ok(content_type, body) do
    "HTTP/1.1 200 OK\r\ncontent-type: #{content_type}\r\n" <>
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
  end

  defp search_ok(entries, content_type \\ "application/json") do
    json_ok(content_type, Jason.encode!(%{"results" => entries}))
  end

  defp start(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp conf(server),
    do: %{url: SSEServer.base_url(server) <> "/v2/search", api_key: "test-key-123"}

  defp run(server, opts),
    do: WebSearch.run(%{"query" => @query}, Keyword.merge([search: conf(server)], opts))

  test "success: two results render as two JSON lines, and the request carries the contract" do
    entries = [
      %{"url" => "https://elixir-lang.org", "title" => "Elixir", "highlights" => ["a"]},
      %{"url" => "https://hex.pm", "highlights" => ["dashfloat"]}
    ]

    server = start([{:send, search_ok(entries)}, :close])

    assert run(server, search_timeout: 2_000) == %{
             ok: true,
             query: @query,
             content: Enum.map_join(entries, "\n", &Jason.encode!/1),
             count: 2
           }

    assert_receive {:sse_request, "POST", "/v2/search", headers, body}, 2_000
    assert headers["authorization"] == "Bearer test-key-123"
    assert Jason.decode!(body) == %{"query" => @query}
  end

  test "success: a binary (non-pre-decoded) body is decoded too" do
    entries = [%{"url" => "https://example.com/a", "title" => "A"}]
    server = start([{:send, search_ok(entries, "text/plain")}])

    result = run(server, search_timeout: 2_000)

    assert result.ok == true
    assert result.count == 1
    assert result.content == Enum.map_join(entries, "\n", &Jason.encode!/1)
  end

  test "results that are not a list are an unexpected response" do
    server = start([{:send, json_ok("application/json", ~s({"results": "nope"}))}])

    assert run(server, search_timeout: 2_000) ==
             %{ok: false, error: "web search failed: unexpected response"}
  end

  test "a missing results key is an unexpected response" do
    server = start([{:send, json_ok("application/json", ~s({"other": 1}))}])

    assert run(server, search_timeout: 2_000) ==
             %{ok: false, error: "web search failed: unexpected response"}
  end

  test "an undecodable binary body is an unexpected response too" do
    server = start([{:send, json_ok("text/plain", "junk")}])

    assert run(server, search_timeout: 2_000) ==
             %{ok: false, error: "web search failed: unexpected response"}
  end

  test "a non-2xx response names the status" do
    server =
      start([
        {:send,
         "HTTP/1.1 500 Server Error\r\ncontent-type: application/json\r\n" <>
           "content-length: 0\r\nconnection: close\r\n\r\n"},
        :close
      ])

    assert run(server, search_timeout: 2_000) ==
             %{ok: false, error: "web search failed: HTTP 500"}
  end

  test "a search that outlives :search_timeout is a timeout, not a hang" do
    server = start([{:sleep, 200}, {:send, search_ok([%{"url" => "https://late.example"}])}])

    assert run(server, search_timeout: 50) ==
             %{ok: false, error: "web search failed: timed out"}
  end

  test "a connection reset is a connection error" do
    server = start([:reset])

    assert run(server, search_timeout: 2_000) ==
             %{ok: false, error: "web search failed: connection error"}
  end

  test "no usable :search opt is not configured" do
    assert WebSearch.run(%{"query" => @query}) ==
             %{ok: false, error: "web search is not configured"}

    assert WebSearch.run(%{"query" => @query}, search: nil) ==
             %{ok: false, error: "web search is not configured"}
  end

  test "an unusable conf degrades to an error, never a raise" do
    # A non-binary url makes Req raise before any request exists.
    raised = WebSearch.run(%{"query" => @query}, search: %{url: 42, api_key: "k"})
    assert raised.ok == false
    assert String.starts_with?(raised.error, "web search failed: ")

    # An out-of-range port makes finch exit(:badarg) — caught the same way.
    exited =
      WebSearch.run(%{"query" => @query},
        search: %{url: "http://127.0.0.1:99999999999/v1", api_key: "k"}
      )

    assert exited.ok == false
    assert String.starts_with?(exited.error, "web search failed: ")
  end
end

defmodule DashFloat.Config.CatalogTest do
  @moduledoc false
  # ADR 0009: the standing model catalog refresh — loopback /models fetches
  # (auth header present and absent), the fail-open arms, the merge rules,
  # and the async wiring. Placeholders only.
  use ExUnit.Case, async: true

  alias DashFloat.Config.Catalog
  alias DashFloat.SSEServer

  defp start_server!(script) do
    {:ok, server} = SSEServer.start_link(script)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  defp http_ok(body) do
    length =
      body
      |> byte_size()
      |> Integer.to_string()

    {:send,
     "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
       length <> "\r\n\r\n" <> body}
  end

  defp request_path! do
    assert_receive {:sse_request, "GET", path, _headers, _body}, 1_000
    assert path == "/models"
    path
  end

  defp auth_header!(expected) do
    assert_receive {:sse_request, "GET", _path, headers, _body}, 1_000

    case headers do
      %{"authorization" => value} -> assert value == expected
      %{} -> assert expected == :absent
    end
  end

  describe "fetch/3 against the loopback" do
    test "two providers, both landing: the OpenAI shape parses ids and contexts" do
      body =
        Jason.encode!(%{
          data: [
            %{"id" => "glm-5.3", "context" => 128_000},
            %{"id" => "glm-5.3-flash"},
            %{"id" => ""},
            "not-a-map"
          ]
        })

      server = start_server!([http_ok(body)])
      base = SSEServer.base_url(server)

      assert {:ok, entries} = Catalog.fetch(base, "PLACEHOLDER-key")

      assert entries == [
               %{model: "glm-5.3", context: 128_000},
               %{model: "glm-5.3-flash", context: nil}
             ]

      auth_header!("Bearer PLACEHOLDER-key")
    end

    test "a key-less provider is fetched WITHOUT Authorization and still parses" do
      server = start_server!([http_ok(~s({"data": [{"id": "open-one"}]}))])
      base = SSEServer.base_url(server)

      assert {:ok, [%{model: "open-one", context: nil}]} = Catalog.fetch(base, nil)
      auth_header!(:absent)
    end

    test "context_length — the metadata real OpenAI-compatible catalogs carry (issue #111)" do
      # Synthetic's live /models reports `context_length` per model (probed
      # 2026-10-30); the plain `context` spelling stays supported and loses
      # to nothing — either observed value beats every assumption.
      server =
        start_server!([
          http_ok(
            ~s({"data": [{"id": "syn:small:text", "context_length": 196608},
                                {"id": "syn:large:text", "context_length": 524288, "context": 999}]})
          )
        ])

      base = SSEServer.base_url(server)

      assert {:ok, entries} = Catalog.fetch(base, nil)

      assert entries == [
               %{model: "syn:small:text", context: 196_608},
               %{model: "syn:large:text", context: 524_288}
             ]
    end

    test "non-2xx reports the HTTP status" do
      server =
        start_server!([
          {:send, "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\n\r\n"}
        ])

      base = SSEServer.base_url(server)
      assert {:error, "HTTP 401"} = Catalog.fetch(base, "PLACEHOLDER-key")
      assert_receive {:sse_request, "GET", _path, _headers, _body}, 1_000
    end

    test "a garbage body reports the format mismatch" do
      server = start_server!([http_ok("not json at all")])
      base = SSEServer.base_url(server)
      assert {:error, "unexpected response format"} = Catalog.fetch(base, "PLACEHOLDER-key")
      assert_receive {:sse_request, _, _, _, _}, 1_000
    end

    test "a timeout reports the timeout" do
      # The server sleeps past the (test-scaled) receive timeout.
      server = start_server!([{:sleep, 5_000}])
      base = SSEServer.base_url(server)

      assert {:error, "timed out"} =
               Catalog.fetch(base, "PLACEHOLDER-key", timeout: 100)

      assert_receive {:sse_request, _, _, _, _}, 1_000
    end

    test "an unreachable host reports the connection failure without raising" do
      assert {:error, "connection failed"} =
               Catalog.fetch("http://127.0.0.1:1/v1", "PLACEHOLDER-key", timeout: 100)
    end

    test "any other error class reports the generic request failure" do
      # A response Mint cannot even parse is neither a transport failure nor
      # a format mismatch — the catch-all keeps the reason a safe phrase.
      server = start_server!([{:send, "NOT-HTTP AT ALL\r\n\r\n"}])
      base = SSEServer.base_url(server)
      assert {:error, "request failed"} = Catalog.fetch(base, "PLACEHOLDER-key")
    end
  end

  defmodule FetchStub do
    @spec two_arity(String.t(), String.t() | nil) ::
            {:ok, [Catalog.entry()]} | {:error, String.t()}
    def two_arity(_url, _key), do: {:ok, [%{model: "mfa-model", context: nil}]}
  end

  describe "fetch/3 failure arms" do
    test "an unparsable URL fails soft without raising" do
      assert {:error, _reason} =
               Catalog.fetch("not a url at all", "PLACEHOLDER-key", timeout: 100)
    end

    test "a 200 body that is not an object reports the format mismatch" do
      server = start_server!([http_ok("[1,2,3]")])
      base = SSEServer.base_url(server)
      assert {:error, "unexpected response format"} = Catalog.fetch(base, nil)
      assert_receive {:sse_request, _, _, _, _}, 1_000
    end

    test "non-string ids are skipped" do
      server = start_server!([http_ok(~s({"data": [{"id": 42}, {"id": "ok-one"}]}))])
      base = SSEServer.base_url(server)
      assert {:ok, [%{model: "ok-one"}]} = Catalog.fetch(base, nil)
    end
  end

  describe "refresh_async/2 MFA and message arms" do
    test "an {m, f} fetcher works and the message tag is public" do
      assert :catalog = Catalog.message()

      providers = [%{label: "a", base_url: "https://mfa.example/v1", api_key: nil}]

      assert {:ok, _pid} =
               Catalog.refresh_async(providers, send_to: self(), fetch: {FetchStub, :two_arity})

      assert_receive {:catalog, %{"https://mfa.example/v1" => [%{model: "mfa-model"}]}}, 1_000
    end

    test "a fetcher answering {:error, reason} still degrades to empty entries" do
      providers = [%{label: "a", base_url: "https://nope.example/v1", api_key: nil}]

      assert {:ok, _pid} =
               Catalog.refresh_async(providers,
                 send_to: self(),
                 fetch: fn _url, _key -> {:error, "HTTP 500"} end
               )

      assert_receive {:catalog, %{"https://nope.example/v1" => []}}, 1_000
    end
  end

  describe "merge/2 (ADR 0009 rules)" do
    test "an id collision never overrides the user's entry but refreshes context" do
      menu = [%{nickname: "Sol", model: "glm-5.3", context: nil}]
      catalog = [%{model: "glm-5.3", context: 128_000}]

      assert Catalog.merge(menu, catalog) == [
               %{nickname: "Sol", model: "glm-5.3", context: 128_000}
             ]
    end

    test "the user's context stays when the catalog reports none" do
      menu = [%{nickname: "Sol", model: "glm-5.3", context: 64_000}]
      assert Catalog.merge(menu, [%{model: "glm-5.3", context: nil}]) == menu
    end

    test "catalog ids the menu lacks are appended with nickname = id" do
      menu = [%{nickname: "Sol", model: "glm-5.3", context: 1}]
      catalog = [%{model: "glm-5.3", context: nil}, %{model: "new-one", context: 8}]

      assert Catalog.merge(menu, catalog) == [
               %{nickname: "Sol", model: "glm-5.3", context: 1},
               %{nickname: "new-one", model: "new-one", context: 8}
             ]
    end

    test "an empty catalog leaves the menu untouched" do
      menu = [%{nickname: "Sol", model: "glm-5.3", context: nil}]
      assert Catalog.merge(menu, []) == menu
    end
  end

  describe "refresh_async/2 (the wiring)" do
    test "a supervised task sweeps every provider and delivers {:catalog, map}" do
      # DashFloat.TaskSupervisor is started by the test-mode Application.
      providers = [
        %{label: "a", base_url: "https://one.example/v1", api_key: "PLACEHOLDER-one"},
        %{label: "b", base_url: "https://two.example/v1", api_key: nil}
      ]

      fetches = {:ok, [%{model: "m1", context: nil}]}

      assert {:ok, _pid} =
               Catalog.refresh_async(providers,
                 send_to: self(),
                 fetch: fn
                   "https://one.example/v1", "PLACEHOLDER-one" -> fetches
                   _url, nil -> {:ok, [%{model: "m2", context: 4}]}
                 end
               )

      assert_receive {:catalog,
                      %{
                        "https://one.example/v1" => [%{model: "m1"}],
                        "https://two.example/v1" => [%{model: "m2"}]
                      }},
                     1_000
    end

    test "a crashing or failing fetcher degrades to empty entries — never a crash" do
      providers = [%{label: "a", base_url: "https://boom.example/v1", api_key: nil}]

      assert {:ok, _pid} =
               Catalog.refresh_async(providers,
                 send_to: self(),
                 fetch: fn _url, _key -> raise "the network is a lie" end
               )

      assert_receive {:catalog, %{"https://boom.example/v1" => []}}, 1_000
    end
  end
end

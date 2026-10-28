defmodule DashFloat.TUI.SuggestTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Config
  alias DashFloat.TUI.Suggest

  @zai "https://api.z.ai/api/coding/paas/v4"
  @synthetic "https://api.synthetic.new/openai/v1"

  # A custom provider (not in the preset table) with an active model.
  defp config(overrides \\ []) do
    struct!(
      Config,
      Keyword.merge(
        [base_url: "https://custom.example/v1", model: "active-m", api_key: "k"],
        overrides
      )
    )
  end

  describe "tail/1" do
    test "no assistant entry is an empty string" do
      assert Suggest.tail([]) == ""
      assert Suggest.tail([%{kind: :user, text: "hi"}]) == ""
    end

    test "the LAST assistant entry's text" do
      entries = [
        %{kind: :assistant, text: "first"},
        %{kind: :user, text: "then"},
        %{kind: :assistant, text: "second"}
      ]

      assert Suggest.tail(entries) == "second"
    end

    test "a long reply is capped to its LAST 2000 chars" do
      text = String.duplicate("a", 2500) <> "END"
      tail = Suggest.tail([%{kind: :assistant, text: text}])

      assert tail == String.slice(text, -2000..-1//1)
      assert String.ends_with?(tail, "END")
    end
  end

  describe "model/1" do
    test "suggest: false reads nil (the caller never requests then)" do
      c = config(suggest: false)
      assert Suggest.model(c) == nil
    end

    test "an explicit id wins over the preset table" do
      c = config(suggest: "cheap-override-m", base_url: @zai)
      assert Suggest.model(c) == "cheap-override-m"
    end

    test "the zai preset falls to its cheap model" do
      c = config(base_url: @zai)
      assert Suggest.model(c) == "glm-5.3-flash"
    end

    test "the synthetic preset falls to its cheap model" do
      c = config(base_url: @synthetic)
      assert Suggest.model(c) == "glm-4.7-flash"
    end

    test "a custom provider falls back to the active model" do
      c = config()
      assert Suggest.model(c) == "active-m"
    end
  end

  describe "body/2" do
    test "the OpenAI shape: fixed instruction + the tail on the resolved model" do
      c = config(base_url: @zai)
      body = Suggest.body(c, "the tail")

      assert body["model"] == "glm-5.3-flash"
      assert body["max_tokens"] == 48

      assert [
               %{"role" => "system", "content" => instruction},
               %{"role" => "user", "content" => "the tail"}
             ] = body["messages"]

      assert instruction =~ "at most 8 words"
    end

    # Load-bearing (ADR 0015 §3): suggest nil + a preset base URL must put
    # the PRESET CHEAP model in the request body — the e2e loopback (a
    # custom provider) can only prove the active-model fallback.
    test "the default cheap model reaches the request body" do
      c = config(base_url: @zai, suggest: nil)
      assert Suggest.body(c, "t")["model"] == "glm-5.3-flash"
    end
  end

  describe "normalize/1" do
    test ":error is nil" do
      assert Suggest.normalize(:error) == nil
    end

    test "the first non-blank line, trimmed" do
      assert Suggest.normalize({:ok, "\n \n  tell me more  \nsecond line"}) == "tell me more"
    end

    test "ONE pair of surrounding quotes is stripped; inner quotes survive" do
      assert Suggest.normalize({:ok, ~s("tell me more")}) == "tell me more"
      assert Suggest.normalize({:ok, "'tell me more'"}) == "tell me more"
      assert Suggest.normalize({:ok, "`tell me more`"}) == "tell me more"
      assert Suggest.normalize({:ok, ~s("say "hi" now")}) == ~s(say "hi" now)
    end

    test "hard-capped to 80 chars" do
      raw = String.duplicate("x", 200)
      capped = Suggest.normalize({:ok, raw})

      assert String.length(capped) == 80
      assert String.starts_with?(raw, capped)
    end

    test "blank is nil" do
      assert Suggest.normalize({:ok, "\n \n"}) == nil
      assert Suggest.normalize({:ok, ""}) == nil
      assert Suggest.normalize({:ok, 42}) == nil
    end

    test "a raise inside the HTTP path is rescued to :error (fail-open)" do
      c = config(base_url: "not-a-url")
      assert Suggest.request(c, "tail") == :error
    end
  end

  describe "fetch_async/3" do
    test "the fetcher's result lands as {:suggestion, epoch, result} on send_to" do
      assert {:ok, _pid} =
               Suggest.fetch_async(config(), "tail",
                 send_to: self(),
                 epoch: 7,
                 fetcher: fn _config, tail -> {:ok, "for " <> tail} end
               )

      assert_receive {:suggestion, 7, {:ok, "for tail"}}, 1_000
    end

    test "a raising fetcher is just another failure (rescued to :error)" do
      assert {:ok, _pid} =
               Suggest.fetch_async(config(), "tail",
                 send_to: self(),
                 epoch: 1,
                 fetcher: fn _config, _tail -> raise "boom" end
               )

      assert_receive {:suggestion, 1, :error}, 1_000
    end
  end
end

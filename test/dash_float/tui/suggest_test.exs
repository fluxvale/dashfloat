defmodule DashFloat.TUI.SuggestTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Config
  alias DashFloat.SSEServer
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

    # A blank after quote-stripping is nil too: the empty string is truthy
    # and would blank the composer's placeholder entirely.
    test "a quote-only body is no ghost" do
      assert Suggest.normalize({:ok, "\"\""}) == nil
      assert Suggest.normalize({:ok, "''"}) == nil
      assert Suggest.normalize({:ok, "`"}) == nil
    end

    # Control bytes never reach the terminal byte stream: the ghost is
    # drawn as placeholder text, so a smuggled ESC byte would be interpreted
    # by the terminal (the printable remainder is inert text).
    test "control bytes are scrubbed before display" do
      ghost = Suggest.normalize({:ok, "\e[2Jtell me more"})

      assert ghost == "[2Jtell me more"
      refute ghost =~ "\e"

      assert Suggest.normalize({:ok, "tell\a me\b more\x7f"}) == "tell me more"
    end

    test "a body that scrubs to blank is nil" do
      assert Suggest.normalize({:ok, "\e\a\b\x7f"}) == nil
    end

    # The 8-bit CSI introducer (U+009B) and the bidi/format set: the same
    # threat as C0 control bytes — placeholder text is interpreted by the
    # terminal byte stream.
    test "C1 CSI and bidi/format characters are scrubbed too" do
      assert Suggest.normalize({:ok, "\u{009B}2Jpwn"}) == "2Jpwn"
      assert Suggest.normalize({:ok, "\u{202E}evil\u{200B}"}) == "evil"
    end

    # Invalid UTF-8 from a provider used to hard-fail the whole drawn frame
    # (ExRatatui.draw → {:error, "textarea.placeholder: unexpected value"} —
    # the composer froze until the ghost cleared). Repaired at the trust
    # boundary (the wrap/markdown precedent); a body that is nothing but
    # invalid bytes is no ghost.
    test "invalid UTF-8 is repaired; a pure-invalid body is nil" do
      ghost = Suggest.normalize({:ok, <<0xFF, ?a>>})

      assert String.valid?(ghost)
      assert ghost =~ "a"

      assert Suggest.normalize({:ok, <<0xFF, 0xFE>>}) == nil
    end

    # The unbounded-scan regression: the raw body is capped to @raw_cap
    # BYTES before any other work, so a misbehaving provider cannot stall
    # the composer (max_tokens only bounds well-behaved ones).
    test "a 5 MB body stays bounded: ≤80-char ghost" do
      ghost = Suggest.normalize({:ok, String.duplicate("a", 5_000_000)})

      assert String.length(ghost) == 80
    end

    # The deterministic bound (no wall clock — a timing guard flakes under
    # CPU oversubscription and an ASCII body cannot catch this failure
    # mode): one base char + 8M combining marks is a SINGLE grapheme, so a
    # grapheme cap would pass it whole and the downstream scan would be
    # unbounded. The byte prefix cuts the result to ≤ @raw_cap bytes.
    test "a single multi-megabyte grapheme cluster is byte-capped" do
      ghost = Suggest.normalize({:ok, "a" <> String.duplicate("\u0301", 8_000_000)})

      assert byte_size(ghost) <= 16_384
    end

    test "a raise inside the HTTP path is rescued to :error (fail-open)" do
      c = config(base_url: "not-a-url")
      assert Suggest.request(c, "tail") == :error
    end
  end

  describe "request/2 against the loopback" do
    # A followed redirect would relay the conversation tail to a third host
    # / re-bill it: a 3xx is just another failure (the ChatStream
    # precedent). The relative location points back at this server, so a
    # followed redirect would surface as a second connection.
    test "a 307 is never followed: :error and no second connection" do
      {:ok, server} = SSEServer.start_link([redirect_step(), :close])
      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

      base = SSEServer.base_url(server)
      config = loopback_config(base)

      assert Suggest.request(config, "tail") == :error

      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000
      Process.sleep(300)
      refute_receive {:sse_request, _, _, _, _}
    end

    defp loopback_config(base) do
      struct!(Config, base_url: base, model: "active-m", api_key: "k")
    end

    defp redirect_step do
      {:send, "HTTP/1.1 307 Temporary Redirect\r\nlocation: /x\r\ncontent-length: 0\r\n\r\n"}
    end
  end

  describe "fetch_async/3" do
    test "the normalized ghost lands as {:suggestion, epoch, text} on send_to" do
      assert {:ok, _pid} =
               Suggest.fetch_async(config(), "tail",
                 send_to: self(),
                 epoch: 7,
                 fetcher: fn _config, tail -> {:ok, "for " <> tail} end
               )

      assert_receive {:suggestion, 7, "for tail"}, 1_000
    end

    test "a raising fetcher is just another failure (rescued to :error → nil)" do
      assert {:ok, _pid} =
               Suggest.fetch_async(config(), "tail",
                 send_to: self(),
                 epoch: 1,
                 fetcher: fn _config, _tail -> raise "boom" end
               )

      assert_receive {:suggestion, 1, nil}, 1_000
    end

    # A fetcher returning something off the {:ok, _} | :error contract must
    # not kill the task inside the send expression — the message has to land
    # (fail-open), or suggest_task would stay a dead pid forever.
    test "an off-contract fetcher result still delivers {:suggestion, epoch, nil}" do
      assert {:ok, _pid} =
               Suggest.fetch_async(config(), "tail",
                 send_to: self(),
                 epoch: 2,
                 fetcher: fn _config, _tail -> :weird end
               )

      assert_receive {:suggestion, 2, nil}, 1_000
    end

    # throw/exit from a fetcher are failures too — rescue alone does not
    # catch them, and a task that dies uncaught never delivers, leaving
    # suggest_task a dead pid until an unrelated reap.
    test "a throwing or exiting fetcher still delivers {:suggestion, epoch, nil}" do
      for payload <- [fn _config, _tail -> throw(:ball) end, fn _config, _tail -> exit(:die) end] do
        assert {:ok, _pid} =
                 Suggest.fetch_async(config(), "tail",
                   send_to: self(),
                   epoch: 3,
                   fetcher: payload
                 )

        assert_receive {:suggestion, 3, nil}, 1_000
      end
    end
  end
end

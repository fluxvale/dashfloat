defmodule DashFloat.Session.TitleTest do
  @moduledoc false
  # tmp-dir discipline: every file-touching test runs against ctx.tmp_dir —
  # the real XDG data dir is off-limits. See #80.
  use ExUnit.Case, async: true

  alias DashFloat.Config
  alias DashFloat.Session
  alias DashFloat.Session.Title
  alias DashFloat.SSEServer

  describe "normalize/1" do
    test "trims, collapses inner whitespace runs, and preserves case" do
      assert Title.normalize("  Fix   the Login Bug ") == {:ok, "Fix the Login Bug"}
      assert Title.normalize("Résumé ✅") == {:ok, "Résumé ✅"}
    end

    test "80 graphemes pass, 81 refuse as :too_long" do
      exactly_80 = String.duplicate("a", 80)
      too_long = String.duplicate("a", 81)

      assert Title.normalize(exactly_80) == {:ok, exactly_80}
      assert Title.normalize(too_long) == {:error, :too_long}
    end

    test "blank, whitespace-only, control-only, and non-string input are :empty" do
      assert Title.normalize("") == {:error, :empty}
      assert Title.normalize("   ") == {:error, :empty}
      assert Title.normalize("\u{0}\u{1}") == {:error, :empty}
      assert Title.normalize(nil) == {:error, :empty}
    end

    test "widthless-only input is :empty — the proposal path's gate, shared" do
      # Soft hyphens (Cf), a word joiner (Cf), and lone combining marks
      # (Mn/Me) carry no width: a title made only of them is untypeable and
      # unresolvable — the manual path refuses exactly what the auto path
      # refuses (review P2).
      soft_hyphens = String.duplicate("\u{ad}", 3)
      assert Title.normalize(soft_hyphens) == {:error, :empty}
      assert Title.normalize("\u{2060}\u{2060}") == {:error, :empty}

      marks = String.duplicate("\u{301}", 4)
      assert Title.normalize(marks) == {:error, :empty}
    end

    test "widthless characters WITHIN a visible title survive" do
      assert Title.normalize("e\u{301}clair") == {:ok, "e\u{301}clair"}
      assert Title.normalize("soft\u{ad}ened") == {:ok, "soft\u{ad}ened"}
    end

    test "a uuid-shaped title is :reserved — ids and titles share --resume" do
      assert Title.normalize("0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c") == {:error, :reserved}

      # Strict lowercase match: an uppercase spelling is just a title.
      assert Title.normalize("0192AB4C-1E5F-7D3A-9B8C-2D4E6F8A1B3C") ==
               {:ok, "0192AB4C-1E5F-7D3A-9B8C-2D4E6F8A1B3C"}
    end

    test "scrub removes control and bidi/format characters" do
      assert Title.normalize("a\u{1}b") == {:ok, "ab"}
      assert Title.normalize("left\u{202e}right") == {:ok, "leftright"}
      assert Title.normalize("a\u{200b}b\u{feff}c") == {:ok, "abc"}
    end

    test "invalid utf-8 bytes are dropped at the trust boundary, never a raise" do
      assert Title.normalize(<<0xFF>>) == {:error, :empty}
      assert Title.normalize(<<0xFF, "ab">>) == {:ok, "ab"}
    end
  end

  describe "normalize_key/1" do
    test "downcases and collapses — case/whitespace differences share a key" do
      assert Title.normalize_key("  My   Session ") == "my session"
      assert Title.normalize_key("MY SESSION") == "my session"
      assert Title.normalize_key("My Session") == Title.normalize_key("  my session  ")
    end

    test "never raises — a non-normalizable input is its best-effort downcased trim" do
      assert Title.normalize_key(nil) == ""
      assert Title.normalize_key(42) == ""
      assert Title.normalize_key(<<0xFF, "A">>) == "a"
    end
  end

  describe "title_holder/3" do
    @tag :tmp_dir
    test "free is nil; taken is the holder's id, matched key-insensitively", ctx do
      assert Title.title_holder(ctx.tmp_dir, "Fix the bug") == nil

      save_titled(ctx, "0192aa10-a001-7b00-8000-000000000001", "Fix the bug")

      assert Title.title_holder(ctx.tmp_dir, "fix THE bug") ==
               "0192aa10-a001-7b00-8000-000000000001"
    end

    @tag :tmp_dir
    test "except_id skips the holder itself", ctx do
      id = "0192aa10-a002-7b00-8000-000000000002"
      save_titled(ctx, id, "Fix the bug")
      assert Title.title_holder(ctx.tmp_dir, "Fix the bug", id) == nil
    end

    @tag :tmp_dir
    test "undecodable and non-map files are skipped silently", ctx do
      garbage = Path.join(ctx.tmp_dir, "garbage.json")
      File.write!(garbage, "not json {{{")
      list = Path.join(ctx.tmp_dir, "list.json")
      body = Jason.encode!([1, 2])
      File.write!(list, body)

      id = "0192aa10-a003-7b00-8000-000000000003"
      save_titled(ctx, id, "Fix the bug")
      assert Title.title_holder(ctx.tmp_dir, "Fix the bug") == id
    end

    @tag :tmp_dir
    test "a missing directory is free", ctx do
      dir = Path.join(ctx.tmp_dir, "does-not-exist")
      assert Title.title_holder(dir, "Fix the bug") == nil
    end

    @tag :tmp_dir
    test "dot-named files are scanned — the sweep's File.ls view, not wildcard's", ctx do
      # Path.wildcard is blind to dotfiles while the migration sweep's
      # File.ls sees them; the scans and the sweep must agree on the store
      # (review P3).
      id = "0192aa10-a006-7b00-8000-000000000006"

      hidden_path = Path.join(ctx.tmp_dir, ".hidden.json")
      body = Jason.encode!(%{id: id, title: "Hidden"})
      assert File.write!(hidden_path, body) == :ok
      assert Title.title_holder(ctx.tmp_dir, "hidden") == id
      assert Title.find_by_title(ctx.tmp_dir, "Hidden") == {:ok, id}
    end
  end

  describe "find_by_title/2" do
    @tag :tmp_dir
    test "one match resolves, none is :none, case-different duplicates are ambiguous", ctx do
      assert Title.find_by_title(ctx.tmp_dir, "Fix the bug") == :none

      a = "0192aa10-a004-7b00-8000-000000000004"
      save_titled(ctx, a, "Fix the bug")
      assert Title.find_by_title(ctx.tmp_dir, "fix the bug") == {:ok, a}

      b = "0192aa10-a005-7b00-8000-000000000005"
      save_titled(ctx, b, "FIX THE BUG")

      assert {:ambiguous, [^a, ^b]} = Title.find_by_title(ctx.tmp_dir, "Fix the bug")
    end
  end

  defp save_titled(ctx, id, title) do
    :ok =
      Session.save(ctx.tmp_dir, %{
        version: 1,
        id: id,
        created_at: "2026-10-29T00:00:00Z",
        pin: %{profile: nil, model: nil, base_url: nil},
        messages: [],
        title: title
      })
  end

  ## The model side-request (#80)

  @zai "https://api.z.ai/api/coding/paas/v4"

  defp config(overrides \\ []) do
    struct!(
      Config,
      Keyword.merge(
        [base_url: "https://custom.example/v1", model: "active-m", api_key: "k"],
        overrides
      )
    )
  end

  defp context(user \\ "fix the login bug", assistant \\ "Here is the fix."),
    do: %{user: user, assistant: assistant}

  describe "model/1" do
    test "auto_title: false reads nil — the agent never requests then" do
      off = config(auto_title: false)
      assert Title.model(off) == nil
    end

    test "an explicit id wins over the preset table" do
      pinned = config(auto_title: "cheap-override-m", base_url: @zai)
      assert Title.model(pinned) == "cheap-override-m"
    end

    test "unset reads the preset cheap model; a custom provider falls back to the active model" do
      zai = config(base_url: @zai)
      custom = config()

      assert Title.model(zai) == "glm-5.3-flash"
      assert Title.model(custom) == "active-m"
    end
  end

  describe "body/2" do
    test "the instruction plus the first exchange's two messages, on the resolved model" do
      zai = config(base_url: @zai)
      body = Title.body(zai, context("the question", "the answer"))

      assert body["model"] == "glm-5.3-flash"
      assert body["max_tokens"] == 32

      assert [
               %{"role" => "system", "content" => instruction},
               %{"role" => "user", "content" => "the question"},
               %{"role" => "assistant", "content" => "the answer"}
             ] = body["messages"]

      assert instruction =~ "Propose a concise title"
    end

    # The bound is a BYTE prefix taken before any other work — a grapheme cap
    # would pass a single giant cluster whole (the Suggest @raw_cap pattern).
    test "each context string is byte-prefixed to 1 KiB" do
      huge = String.duplicate("a", 5_000)
      body = Title.body(config(), context(huge, huge <> "END"))

      [_system, %{"content" => user}, %{"content" => assistant}] = body["messages"]

      assert byte_size(user) == 1024
      assert byte_size(assistant) == 1024
      assert String.valid?(user) and String.valid?(assistant)
    end

    # A byte prefix can split a codepoint; the repair keeps the body
    # encodable (Jason refuses invalid UTF-8 strings).
    test "a split codepoint at the cap is repaired, never raises" do
      split = String.pad_trailing("é", 1022) <> "é" <> String.duplicate("a", 2000)
      body = Title.body(config(), context(split, "ok"))
      assert [%{"content" => user}, %{"content" => _assistant}] = tl(body["messages"])
      assert byte_size(user) <= 1024
      assert String.valid?(user)
    end
  end

  describe "request/2 against the loopback" do
    test "2xx with the OpenAI reply shape yields {:ok, content}" do
      steps = ok_step("Fix the Login Bug")
      {:ok, server} = SSEServer.start_link(steps)
      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

      config = config(base_url: SSEServer.base_url(server))

      assert Title.request(config, context()) == {:ok, "Fix the Login Bug"}

      assert_receive {:sse_request, "POST", "/chat/completions", headers, body}, 1_000
      assert headers["authorization"] == "Bearer k"
      decoded = Jason.decode!(body)
      assert decoded["max_tokens"] == 32
      assert [_system, _user, _assistant] = decoded["messages"]
    end

    test "no api key sends no authorization header" do
      steps = ok_step("t")
      {:ok, server} = SSEServer.start_link(steps)
      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

      config = config(base_url: SSEServer.base_url(server), api_key: nil)

      assert Title.request(config, context()) == {:ok, "t"}

      assert_receive {:sse_request, "POST", "/chat/completions", headers, _body}, 1_000
      refute Map.has_key?(headers, "authorization")
    end

    # A followed redirect would relay the first exchange to a third host: a
    # 3xx is just another failure (the ChatStream/Suggest precedent).
    test "a 307 is never followed: :error and no second connection" do
      {:ok, server} = SSEServer.start_link([redirect_step(), :close])
      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

      config = config(base_url: SSEServer.base_url(server))

      assert Title.request(config, context()) == :error

      assert_receive {:sse_request, "POST", "/chat/completions", _, _}, 1_000
      Process.sleep(300)
      refute_received {:sse_request, _, _, _, _}
    end

    test "a raise inside the HTTP path is rescued to :error (fail-open)" do
      config = config(base_url: "not-a-url")
      assert Title.request(config, context()) == :error
    end

    test "a shape violation (non-binary content) is :error" do
      steps = ok_step(42)
      {:ok, server} = SSEServer.start_link(steps)
      on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

      config = config(base_url: SSEServer.base_url(server))
      assert Title.request(config, context()) == :error
    end

    defp ok_step(content) do
      body = Jason.encode!(%{choices: [%{message: %{content: content}}]})

      [
        {:send,
         "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n" <>
           body},
        :close
      ]
    end

    defp redirect_step do
      {:send, "HTTP/1.1 307 Temporary Redirect\r\nlocation: /x\r\ncontent-length: 0\r\n\r\n"}
    end
  end

  describe "proposal/1" do
    test ":error is nil; non-binary content is nil" do
      assert Title.proposal(:error) == nil
      assert Title.proposal({:ok, 42}) == nil
    end

    test "the first non-blank line, trimmed" do
      assert Title.proposal({:ok, "\n \n  Fix the Login Bug  \nsecond line"}) ==
               "Fix the Login Bug"
    end

    test "ONE pair of surrounding quotes is stripped; inner quotes survive" do
      assert Title.proposal({:ok, ~s("Fix the Login Bug")}) == "Fix the Login Bug"
      assert Title.proposal({:ok, "'Fix the Login Bug'"}) == "Fix the Login Bug"
      assert Title.proposal({:ok, ~s("say "hi" now")}) == ~s(say "hi" now)
    end

    test "control, C1, and bidi characters are scrubbed" do
      assert Title.proposal({:ok, "fix\a the login\x7f bug"}) == "fix the login bug"
      assert Title.proposal({:ok, "\u{202E}evil\u{200B} title"}) == "evil title"
    end

    test "hard-capped to 80 graphemes" do
      raw = String.duplicate("x", 200)
      title = Title.proposal({:ok, raw})

      assert String.length(title) == 80
      assert String.starts_with?(raw, title)
    end

    test "blank, quote-only, and scrub-to-blank bodies are nil" do
      assert Title.proposal({:ok, "\n \n"}) == nil
      assert Title.proposal({:ok, "\"\""}) == nil
      assert Title.proposal({:ok, "\e\a\b\x7f"}) == nil
    end

    test "a UUID-shaped proposal is nil — the silent give-up" do
      assert Title.proposal({:ok, "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"}) == nil
    end

    test "invalid UTF-8 is repaired; a pure-invalid body is nil" do
      title = Title.proposal({:ok, <<0xFF, ?a>>})
      assert String.valid?(title)
      assert title == "a"

      assert Title.proposal({:ok, <<0xFF, 0xFE>>}) == nil
    end

    # The deterministic bound: a single multi-megabyte grapheme cluster is
    # byte-capped before any grapheme work.
    test "a single multi-megabyte grapheme cluster is byte-capped" do
      title = Title.proposal({:ok, "a" <> String.duplicate("\u0301", 8_000_000)})

      assert byte_size(title) <= 16_384
      assert String.length(title) == 1
    end
  end

  describe "fetch_async/3" do
    test "the normalized proposal lands as {:title_proposal, ref, text} on send_to" do
      ref = make_ref()

      assert {:ok, _pid} =
               Title.fetch_async(config(), context("q", "a"),
                 send_to: self(),
                 ref: ref,
                 fetcher: fn _config, _ctx -> {:ok, "for the exchange"} end
               )

      assert_receive {:title_proposal, ^ref, "for the exchange"}, 1_000
    end

    test "the default fetcher is the real request — an {m, f} or fun/2 fetcher both run" do
      ref = make_ref()

      assert {:ok, _pid} =
               Title.fetch_async(config(), context(),
                 send_to: self(),
                 ref: ref,
                 fetcher: {__MODULE__, :ok_fetcher}
               )

      assert_receive {:title_proposal, ^ref, "mfa title"}, 1_000
    end

    test ":error, a raise, a throw, an exit, and off-contract results all deliver nil" do
      fetchers = [
        fn _config, _ctx -> :error end,
        fn _config, _ctx -> raise "boom" end,
        fn _config, _ctx -> throw(:ball) end,
        fn _config, _ctx -> exit(:die) end,
        fn _config, _ctx -> :weird end
      ]

      for fetcher <- fetchers do
        ref = make_ref()

        assert {:ok, _pid} =
                 Title.fetch_async(config(), context(),
                   send_to: self(),
                   ref: ref,
                   fetcher: fetcher
                 )

        assert_receive {:title_proposal, ^ref, nil}, 1_000
      end
    end

    @spec ok_fetcher(term(), term()) :: {:ok, String.t()}
    def ok_fetcher(_config, _context), do: {:ok, "mfa title"}

    test "a supervisor that cannot start the task is an error tuple, never an exit" do
      # Task.Supervisor.start_child/2 on a dead/absent name EXITS out of
      # GenServer.call (OTP 29) — the side-channel must degrade, not take
      # the agent down (review P2).
      bogus = :"dashfloat-title-no-such-supervisor"

      assert {:error, :supervisor_unavailable} =
               Title.fetch_async(config(), context("q", "a"),
                 send_to: self(),
                 ref: make_ref(),
                 fetcher: fn _config, _ctx -> {:ok, "never runs"} end,
                 supervisor: bogus
               )

      refute_received {:title_proposal, _ref, _text}
    end

    test "the task rides the caller's supervisor via :supervisor" do
      {:ok, sup} = Task.Supervisor.start_link()
      ref = make_ref()

      assert {:ok, _pid} =
               Title.fetch_async(config(), context("q", "a"),
                 send_to: self(),
                 ref: ref,
                 fetcher: fn _config, _ctx -> {:ok, "own supervisor"} end,
                 supervisor: sup
               )

      assert_receive {:title_proposal, ^ref, "own supervisor"}, 1_000
    end
  end
end

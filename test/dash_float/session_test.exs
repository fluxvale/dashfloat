defmodule DashFloat.SessionTest do
  @moduledoc false
  # tmp-dir discipline: every test runs against ctx.tmp_dir — the real XDG
  # data dir is off-limits. See ADR 0014 §2–§4.
  use ExUnit.Case, async: true

  alias DashFloat.Session

  @id "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5c"
  @created_at "2026-10-27T14:30:52Z"

  defp session(messages, overrides \\ []) do
    Map.merge(
      %{
        version: 1,
        id: @id,
        created_at: @created_at,
        pin: %{profile: "personal", model: "glm-5.3", base_url: "https://api.example.test/v4"},
        messages: messages
      },
      Map.new(overrides)
    )
  end

  defp path(ctx), do: Path.join(ctx.tmp_dir, @id <> ".json")

  defp save_ok(ctx, messages, overrides \\ []) do
    assert :ok = Session.save(ctx.tmp_dir, session(messages, overrides))
  end

  defp load(ctx), do: Session.load(ctx.tmp_dir, @id)

  # Writes a raw (string-keyed) body, bypassing save/2 — the loader must
  # judge hand-written and damaged files exactly as it judges its own.
  defp write_body(ctx, body) do
    file = path(ctx)
    File.write!(file, Jason.encode!(body))
  end

  defp body_with(messages, overrides \\ []) do
    Map.merge(
      %{
        "version" => 1,
        "id" => @id,
        "created_at" => @created_at,
        "pin" => %{"profile" => "personal", "model" => "glm-5.3", "base_url" => nil},
        "messages" => messages
      },
      Map.new(overrides)
    )
  end

  defp call(id) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => "read_file", "arguments" => ~s({"path":"notes.txt"})}
    }
  end

  defp tool_result(tool_call_id, content),
    do: %{"role" => "tool", "tool_call_id" => tool_call_id, "content" => content}

  defp cancelled(tool_call_id), do: tool_result(tool_call_id, ~s({"ok":false,"cancelled":true}))

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  describe "dir/0 and new_id/0" do
    test "dir/0 is the sessions folder under the XDG data dir" do
      dir = Session.dir()
      assert Path.absname(dir) == dir
      assert String.ends_with?(dir, "dashfloat/sessions")
    end

    test "new_id/0 is a canonical lowercase UUIDv7: 36 chars, 8-4-4-4-12, version 7" do
      id = Session.new_id()
      assert String.length(id) == 36

      assert Regex.match?(
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
               id
             )

      # The version nibble sits at offset 14, after group one plus its dash.
      assert binary_part(id, 14, 1) == "7"
    end

    test "25 mints are unique and their unix-ms prefixes never sort backwards" do
      ids = for _i <- 1..25, do: Session.new_id()
      assert Enum.uniq(ids) == ids

      # The 48-bit unix-ms prefix ascends, so lexical order is recency order
      # (ADR 0014 §2). Same-millisecond mints tie on the prefix and are broken
      # by their random tail — no order claim within a millisecond.
      prefixes = Enum.map(ids, &binary_part(&1, 0, 13))

      assert prefixes
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a <= b end)
    end
  end

  describe "save/2 and load/2 round trip" do
    @tag :tmp_dir
    test "messages round-trip string-keyed, including nil content, batches, and UTF-8", ctx do
      messages = [
        %{role: "user", content: "héllo\nmulti-line € ünïcode ✓"},
        %{
          role: "assistant",
          content: nil,
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: ~s({"path":"notes.txt"})}
            },
            %{
              id: "call_2",
              type: "function",
              function: %{name: "write_file", arguments: ~s({"path":"a","content":"x\ny"})}
            }
          ]
        },
        %{
          role: "tool",
          tool_call_id: "call_1",
          content: ~s({"ok":true,"output":"line one\nline two"})
        },
        %{
          role: "tool",
          tool_call_id: "call_2",
          content: ~s({"ok":true,"output":"wrote 3 bytes"})
        },
        %{role: "assistant", content: "Done — ✓"}
      ]

      save_ok(ctx, messages)
      assert {:ok, loaded} = load(ctx)

      assert loaded == %{
               version: 1,
               id: @id,
               created_at: @created_at,
               pin: %{
                 profile: "personal",
                 model: "glm-5.3",
                 base_url: "https://api.example.test/v4"
               },
               messages: [
                 %{"role" => "user", "content" => "héllo\nmulti-line € ünïcode ✓"},
                 %{
                   "role" => "assistant",
                   "content" => nil,
                   "tool_calls" => [
                     %{
                       "id" => "call_1",
                       "type" => "function",
                       "function" => %{
                         "name" => "read_file",
                         "arguments" => ~s({"path":"notes.txt"})
                       }
                     },
                     %{
                       "id" => "call_2",
                       "type" => "function",
                       "function" => %{
                         "name" => "write_file",
                         "arguments" => ~s({"path":"a","content":"x\ny"})
                       }
                     }
                   ]
                 },
                 %{
                   "role" => "tool",
                   "tool_call_id" => "call_1",
                   "content" => ~s({"ok":true,"output":"line one\nline two"})
                 },
                 %{
                   "role" => "tool",
                   "tool_call_id" => "call_2",
                   "content" => ~s({"ok":true,"output":"wrote 3 bytes"})
                 },
                 %{"role" => "assistant", "content" => "Done — ✓"}
               ],
               title: nil,
               context: nil,
               compactions: []
             }
    end

    @tag :tmp_dir
    test "an env-only pin (all null fields) round-trips as nils", ctx do
      save_ok(ctx, [], pin: %{profile: nil, model: nil, base_url: nil})
      assert {:ok, loaded} = load(ctx)
      assert loaded.pin == %{profile: nil, model: nil, base_url: nil}
    end

    @tag :tmp_dir
    test "a missing or malformed pin compares nothing — it loads as all nils", ctx do
      write_body(ctx, %{
        "version" => 1,
        "id" => @id,
        "created_at" => @created_at,
        "messages" => []
      })

      assert {:ok, loaded} = load(ctx)
      assert loaded.pin == %{profile: nil, model: nil, base_url: nil}

      write_body(ctx, body_with([], %{"pin" => "garbage"}))
      assert {:ok, loaded} = load(ctx)
      assert loaded.pin == %{profile: nil, model: nil, base_url: nil}

      write_body(
        ctx,
        body_with([], %{"pin" => %{"profile" => 42, "model" => nil, "base_url" => "x"}})
      )

      assert {:ok, loaded} = load(ctx)
      assert loaded.pin == %{profile: nil, model: nil, base_url: "x"}
    end
  end

  describe "context and compactions (ADR 0022)" do
    @tag :tmp_dir
    test "context and compactions round-trip", ctx do
      compactions = [
        %{
          "at" => "2026-10-29T00:00:00Z",
          "turns" => 2,
          "window" => 2000,
          "estimate_before" => 1650,
          "estimate_after" => 1180
        }
      ]

      save_ok(ctx, [],
        context: %{prompt_tokens: 412, messages: 6},
        compactions: compactions
      )

      assert {:ok, loaded} = load(ctx)
      assert loaded.context == %{prompt_tokens: 412, messages: 6}
      assert loaded.compactions == compactions
    end

    @tag :tmp_dir
    test "a file without the two keys loads with context nil and compactions []", ctx do
      write_body(ctx, body_with([%{"role" => "user", "content" => "hi"}]))

      assert {:ok, loaded} = load(ctx)
      assert loaded.context == nil
      assert loaded.compactions == []
    end

    @tag :tmp_dir
    test "malformed context and compactions degrade — never a refusal", ctx do
      for context <- [
            42,
            "nope",
            %{"prompt_tokens" => "lots", "messages" => 2},
            %{"prompt_tokens" => 412},
            %{"messages" => 6},
            %{}
          ] do
        write_body(ctx, body_with([], %{"context" => context}))
        assert {:ok, loaded} = load(ctx)
        assert loaded.context == nil
      end

      for compactions <- ["nope", 42, %{"at" => "x"}] do
        write_body(ctx, body_with([], %{"compactions" => compactions}))
        assert {:ok, loaded} = load(ctx)
        assert loaded.compactions == []
      end
    end

    @tag :tmp_dir
    test "a context of two zeros is valid (non-negative includes zero) and round-trips", ctx do
      write_body(ctx, body_with([], %{"context" => %{"prompt_tokens" => 0, "messages" => 0}}))
      assert {:ok, loaded} = load(ctx)
      assert loaded.context == %{prompt_tokens: 0, messages: 0}

      save_ok(ctx, [], context: %{prompt_tokens: 0, messages: 0})
      assert {:ok, reloaded} = load(ctx)
      assert reloaded.context == %{prompt_tokens: 0, messages: 0}
    end

    @tag :tmp_dir
    test "messages validation is untouched: a known-bad message refuses with the diagnostics present",
         ctx do
      write_body(
        ctx,
        body_with([%{"role" => "user", "content" => 42}], %{
          "context" => %{"prompt_tokens" => 1, "messages" => 1},
          "compactions" => []
        })
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("content")
    end
  end

  describe "title (ADR 0014 §3's additive seam, #80)" do
    @tag :tmp_dir
    test "a titled session round-trips verbatim, case-preserved", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}], title: "Fix the  Login Bug ")
      assert {:ok, loaded} = load(ctx)
      assert loaded.title == "Fix the  Login Bug "
      file = path(ctx)
      contents = File.read!(file)
      decoded = Jason.decode!(contents)
      assert decoded["title"] == "Fix the  Login Bug "
    end

    @tag :tmp_dir
    test "an untitled session file carries no title key at all", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}])
      assert {:ok, loaded} = load(ctx)
      assert loaded.title == nil
      # Byte-level: the encoded JSON has no "title" outside messages.
      file = path(ctx)
      contents = File.read!(file)
      refute contents =~ "title"
    end

    @tag :tmp_dir
    test "a non-string title in a hand-written file loads as nil, never a refusal", ctx do
      write_body(ctx, body_with([], %{"title" => 42}))
      assert {:ok, loaded} = load(ctx)
      assert loaded.title == nil
    end
  end

  describe "save/2 on disk" do
    @tag :tmp_dir
    test "creates the sessions directory on demand", ctx do
      dir = Path.join(ctx.tmp_dir, "nested/sessions")
      refute File.exists?(dir)

      assert :ok = Session.save(dir, session([]))
      assert File.dir?(dir)
      assert {:ok, _loaded} = Session.load(dir, @id)
    end

    @tag :tmp_dir
    test "writes 0600 on a fresh file and keeps 0600 on rewrite", ctx do
      save_ok(ctx, [%{role: "user", content: "one"}])
      assert mode(path(ctx)) == 0o600

      save_ok(ctx, [%{role: "user", content: "two"}])
      assert mode(path(ctx)) == 0o600
    end

    @tag :tmp_dir
    test "a pre-planted .tmp symlink is no longer the staging name: the save succeeds around it",
         ctx do
      save_ok(ctx, [%{role: "user", content: "original"}])
      file = path(ctx)

      decoy = Path.join(ctx.tmp_dir, "decoy")
      File.write!(decoy, "decoy bytes")
      :ok = File.ln_s(decoy, file <> ".tmp")

      assert :ok = Session.save(ctx.tmp_dir, session([%{role: "user", content: "evil"}]))
      assert File.read!(file) =~ "evil"

      # The symlink is untouched, and the unique staging name is renamed
      # away — no .tmp* debris remains after a successful save.
      assert File.lstat!(file <> ".tmp").type == :symlink
      assert File.read!(decoy) == "decoy bytes"

      others = File.ls!(ctx.tmp_dir) -- [@id <> ".json", @id <> ".json.tmp"]
      refute Enum.any?(others, &String.contains?(&1, ".tmp"))
    end

    @tag :tmp_dir
    test "a stale regular .tmp neither blocks a save nor corrupts the session", ctx do
      save_ok(ctx, [%{role: "user", content: "v1"}])
      File.write!(path(ctx) <> ".tmp", "stale debris")

      save_ok(ctx, [%{role: "user", content: "v2"}])
      assert {:ok, loaded} = load(ctx)
      assert loaded.messages == [%{"role" => "user", "content" => "v2"}]
    end

    @tag :tmp_dir
    test "two concurrent writers and a reader: every read is one whole payload", ctx do
      # The unique staging name (ADR 0014 §7) means interleaved saves of one
      # session can never share a tmp file: a reader under concurrent writers
      # sees only whole payloads — the pre-write state or one writer's file —
      # never a torn mix. A parse error (or any other refusal) fails the test.
      a = String.duplicate("a", 4096)
      b = String.duplicate("b", 4096)
      payloads = MapSet.new([a, b])

      writer = fn content ->
        fn ->
          for _i <- 1..300 do
            assert :ok = Session.save(ctx.tmp_dir, session([%{role: "user", content: content}]))
          end
        end
      end

      run_a = writer.(a)
      run_b = writer.(b)
      task_a = Task.async(run_a)
      task_b = Task.async(run_b)

      reader =
        Task.async(fn ->
          for _i <- 1..600 do
            case Session.load(ctx.tmp_dir, @id) do
              {:ok, loaded} ->
                assert [%{"role" => "user", "content" => content}] = loaded.messages
                assert MapSet.member?(payloads, content)

              # The reader may outrun the first write: the pre-write state.
              {:error, "no session " <> _rest} ->
                :ok
            end
          end
        end)

      Task.await(task_a, 30_000)
      Task.await(task_b, 30_000)
      Task.await(reader, 30_000)

      # The final file loads and is exactly one writer's payload.
      assert {:ok, loaded} = Session.load(ctx.tmp_dir, @id)
      assert [%{"role" => "user", "content" => content}] = loaded.messages
      assert MapSet.member?(payloads, content)
    end

    @tag :tmp_dir
    test "an unencodable session errors naming the path only, never raising", ctx do
      assert {:error, error} =
               Session.save(ctx.tmp_dir, session([%{role: "user", content: <<0xFF>>}]))

      assert error == "cannot write #{path(ctx)}: session is not encodable"
    end

    @tag :tmp_dir
    test "an unwritable directory errors naming the path", ctx do
      blocker = Path.join(ctx.tmp_dir, "blocker")
      File.write!(blocker, "a file where a directory should be")
      dir = Path.join(blocker, "sessions")

      assert {:error, error} = Session.save(dir, session([]))
      assert error =~ blocker
    end

    @tag :tmp_dir
    test "no api_key key ever appears in a written session file", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}])
      file = path(ctx)
      contents = File.read!(file)
      body = Jason.decode!(contents)

      sorted =
        body
        |> Map.keys()
        |> Enum.sort()

      assert sorted == ["created_at", "id", "messages", "pin", "version"]
    end
  end

  describe "load/2 refusals" do
    @tag :tmp_dir
    test "an unknown id names the directory and the id", ctx do
      assert {:error, msg} = load(ctx)

      assert msg ==
               "no session #{@id} under #{ctx.tmp_dir} — list sessions with: ls #{ctx.tmp_dir}"
    end

    @tag :tmp_dir
    test "a missing sessions directory refuses the same way", ctx do
      dir = Path.join(ctx.tmp_dir, "does-not-exist")

      assert {:error, msg} = Session.load(dir, @id)
      assert msg =~ dir
      assert msg =~ @id
    end

    @tag :tmp_dir
    test "a truncated file errors naming the path and stays byte-identical", ctx do
      save_ok(ctx, [%{role: "user", content: "hello"}])
      file = path(ctx)
      original = File.read!(file)
      truncated = binary_part(original, 0, byte_size(original) - 5)
      File.write!(file, truncated)

      assert {:error, msg} = load(ctx)
      assert msg =~ path(ctx)
      assert File.read!(file) == truncated
    end

    @tag :tmp_dir
    test "a garbage file errors naming the path, echoing nothing, and stays byte-identical",
         ctx do
      garbage = "\u{0}\u{1} {{{ not json at all"
      file = path(ctx)
      File.write!(file, garbage)

      assert {:error, msg} = load(ctx)
      assert msg =~ path(ctx)
      refute msg =~ "not json"
      assert File.read!(file) == garbage
    end

    @tag :tmp_dir
    test "a directory where a session file should be errors without raising", ctx do
      file = path(ctx)
      File.mkdir!(file)

      assert {:error, msg} = load(ctx)
      assert msg =~ path(ctx)
    end

    @tag :tmp_dir
    test "a newer version refuses naming the field and both values", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}], version: 2)
      file = path(ctx)

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("version" is 2)
      assert msg =~ "newer"
      assert File.read!(file) =~ ~s("version":2)
    end

    @tag :tmp_dir
    test "a missing or non-integer version is malformed", ctx do
      write_body(ctx, body_with([], %{"version" => "1"}))

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("version")

      write_body(ctx, %{"id" => @id, "created_at" => @created_at, "messages" => []})

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("version")
    end

    @tag :tmp_dir
    test "a non-object top level refuses naming the path", ctx do
      file = path(ctx)
      File.write!(file, Jason.encode!([%{"version" => 1}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ path(ctx)
    end

    @tag :tmp_dir
    test "a file whose id is not the requested id refuses naming the field", ctx do
      write_body(ctx, body_with([], %{"id" => "another-session"}))

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("id")
    end

    @tag :tmp_dir
    test "a missing id key refuses naming the field", ctx do
      write_body(ctx, %{"version" => 1, "created_at" => @created_at, "messages" => []})

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("id")
    end

    @tag :tmp_dir
    test "a missing or non-string created_at refuses naming the field", ctx do
      write_body(ctx, %{"version" => 1, "id" => @id, "messages" => []})

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("created_at")

      write_body(ctx, %{"version" => 1, "id" => @id, "created_at" => 42, "messages" => []})

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("created_at")
    end

    @tag :tmp_dir
    test "a missing or non-list messages field refuses naming the field", ctx do
      write_body(ctx, %{"version" => 1, "id" => @id, "created_at" => @created_at})

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("messages")

      write_body(ctx, body_with("not a list"))

      assert {:error, msg} = load(ctx)
      assert msg =~ ~s("messages")
    end
  end

  describe "message shape validation" do
    @tag :tmp_dir
    test "an unknown role refuses naming the index and the field", ctx do
      write_body(ctx, body_with([%{"role" => "function", "content" => "x"}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("role")
    end

    @tag :tmp_dir
    test "a leading system message loads verbatim (ADR 0019)", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "system", "content" => "You are DashFloat."},
          %{"role" => "user", "content" => "hello"}
        ])
      )

      assert {:ok, session} = load(ctx)

      assert session.messages == [
               %{"role" => "system", "content" => "You are DashFloat."},
               %{"role" => "user", "content" => "hello"}
             ]
    end

    @tag :tmp_dir
    test "a system message interleaved in a tool batch rides the block through repair", ctx do
      # Hostile review F4: the validator tolerates a mid-batch system message
      # (batch state passes through, ADR 0019) — repair must agree, or it
      # synthesizes a duplicate answer and the next save bricks the file.
      calls = [
        %{
          "id" => "call_x",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"a\"}"}
        }
      ]

      messages = [
        %{"role" => "system", "content" => "session start"},
        %{"role" => "user", "content" => "go"},
        %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
        %{"role" => "system", "content" => "mid-batch"},
        %{"role" => "tool", "tool_call_id" => "call_x", "content" => "{\"ok\":true}"}
      ]

      write_body(ctx, body_with(messages))

      assert {:ok, session} = load(ctx)
      assert session.messages == messages

      # The repaired transcript re-saves and re-loads — no synthesized
      # duplicate, no refusal.
      assert :ok = Session.save(ctx.tmp_dir, session)
      assert {:ok, reloaded} = load(ctx)
      assert reloaded.messages == messages
    end

    @tag :tmp_dir
    test "a system message with non-binary content refuses naming the field", ctx do
      write_body(ctx, body_with([%{"role" => "system", "content" => 42}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("content")
    end

    @tag :tmp_dir
    test "a message that is not an object refuses naming the index", ctx do
      write_body(ctx, body_with(["just a string"]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
    end

    @tag :tmp_dir
    test "non-binary content refuses naming the index and the field", ctx do
      write_body(ctx, body_with([%{"role" => "user", "content" => 42}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("content")

      write_body(ctx, body_with([%{"role" => "assistant", "content" => []}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("content")
    end

    @tag :tmp_dir
    test "a tool_calls entry missing function.name refuses naming the index", ctx do
      calls = [
        %{
          "id" => "call_ok",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => "{}"}
        },
        %{"id" => "call_bad", "type" => "function", "function" => %{"arguments" => "{}"}}
      ]

      write_body(
        ctx,
        body_with([%{"role" => "assistant", "content" => nil, "tool_calls" => calls}])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("tool_calls")
    end

    @tag :tmp_dir
    test "a non-list tool_calls refuses naming the index and the field", ctx do
      write_body(
        ctx,
        body_with([%{"role" => "assistant", "content" => nil, "tool_calls" => "nope"}])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("tool_calls")
    end

    @tag :tmp_dir
    test "a tool message missing tool_call_id refuses naming the index", ctx do
      write_body(ctx, body_with([%{"role" => "tool", "content" => "{}"}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("tool_call_id")
    end

    @tag :tmp_dir
    test "the error names the violating message's index, not the first", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "fine"},
          %{"role" => "user", "content" => "fine"},
          %{"role" => "user", "content" => 42}
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 2"
    end

    @tag :tmp_dir
    @tag :tmp_dir
    test "an assistant message's reasoning_content round-trips verbatim (issue #78)", ctx do
      messages = [
        %{role: "user", content: "think about elixir"},
        %{
          role: "assistant",
          content: "the answer",
          reasoning_content: "the full thinking\nmulti-line too"
        }
      ]

      save_ok(ctx, messages)
      assert {:ok, loaded} = load(ctx)

      assert %{
               "role" => "assistant",
               "content" => "the answer",
               "reasoning_content" => "the full thinking\nmulti-line too"
             } in loaded.messages
    end

    @tag :tmp_dir
    test "a non-string reasoning_content refuses naming the field (issue #78)", ctx do
      messages = [%{role: "user", content: "q"}, %{role: "assistant", content: "a"}]

      save_ok(ctx, messages)
      path = Path.join(ctx.tmp_dir, @id <> ".json")

      decoded =
        path
        |> File.read!()
        |> Jason.decode!()

      damaged = List.update_at(decoded["messages"], 1, &Map.put(&1, "reasoning_content", 42))

      File.write!(path, Jason.encode!(%{decoded | "messages" => damaged}))

      assert {:error, error} = load(ctx)
      assert error =~ ~s(message 1 field "reasoning_content" must be a string)
    end

    @tag :tmp_dir
    test "an image-bearing user message round-trips verbatim (ADR 0018 §2)", ctx do
      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "what is this?"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,aGk="}}
          ]
        },
        %{"role" => "assistant", "content" => "a cat"}
      ]

      save_ok(ctx, messages)
      assert {:ok, loaded} = load(ctx)
      assert loaded.messages == messages

      # The round-tripped transcript re-saves and re-loads.
      assert :ok = Session.save(ctx.tmp_dir, loaded)
      assert {:ok, reloaded} = load(ctx)
      assert reloaded.messages == messages
    end

    @tag :tmp_dir
    test "a malformed parts list refuses naming the index and the expected shape", ctx do
      write_body(
        ctx,
        body_with([
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "fine"},
              %{"type" => "image_url", "image_url" => %{"url" => 42}}
            ]
          }
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("content")
      assert msg =~ ~s({"type": "image_url", "image_url": {"url": string}})
    end

    @tag :tmp_dir
    test "user content that is neither a string nor a parts list refuses with both shapes", ctx do
      write_body(ctx, body_with([%{"role" => "user", "content" => %{"junk" => true}}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ "must be a string or a list of content parts"
    end
  end

  describe "session id shape" do
    @tag :tmp_dir
    test "save refuses an id outside the minted shape, writing nothing", ctx do
      dir = Path.join(ctx.tmp_dir, "never-created")

      assert {:error, msg} = Session.save(dir, session([], id: "../escape"))
      assert msg == "session ids look like 0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"
      refute File.exists?(dir)
    end

    @tag :tmp_dir
    test "load refuses an id outside the shape naming the dir and the ls remedy", ctx do
      assert {:error, msg} = Session.load(ctx.tmp_dir, "../escape")

      assert msg ==
               "no session ../escape under #{ctx.tmp_dir} — session ids look like 0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c; list sessions with: ls #{ctx.tmp_dir}"

      assert File.ls!(ctx.tmp_dir) == []
    end

    @tag :tmp_dir
    test "a non-string id returns the shape error on both paths, never a raise", ctx do
      assert {:error, msg} = Session.save(ctx.tmp_dir, session([], id: 123))
      assert msg == "session ids look like 0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"

      assert {:error, msg} = Session.load(ctx.tmp_dir, 123)

      assert msg ==
               "no session 123 under #{ctx.tmp_dir} — session ids look like 0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c; list sessions with: ls #{ctx.tmp_dir}"

      # No String.Chars implementation: interpolation would raise here.
      assert {:error, _msg} = Session.load(ctx.tmp_dir, self())
      assert {:error, _msg} = Session.load(ctx.tmp_dir, %{id: :x})
      assert {:error, _msg} = Session.load(ctx.tmp_dir, {:tuple, :id})
    end

    @tag :tmp_dir
    test "a requested id with the trailing .json `ls` prints still loads", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}])
      assert {:ok, loaded} = Session.load(ctx.tmp_dir, @id <> ".json")
      assert loaded.id == @id
      assert loaded.messages == [%{"role" => "user", "content" => "hi"}]
    end
  end

  describe "summaries/1 (issue #128)" do
    @other_id "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5d"

    defp write_session_at(ctx, id, created_at, overrides \\ []) do
      body =
        Map.merge(
          %{
            "version" => 1,
            "id" => id,
            "created_at" => created_at,
            "pin" => %{"profile" => "work", "model" => "glm-5.3-flash", "base_url" => nil},
            "messages" => [
              %{"role" => "system", "content" => "prompt"},
              %{"role" => "user", "content" => "the first question"}
            ]
          },
          Map.new(overrides)
        )

      file = Path.join(ctx.tmp_dir, id <> ".json")
      File.write!(file, Jason.encode!(body))
    end

    @tag :tmp_dir
    test "lists sessions most recent first, with the picker row's fields", ctx do
      write_session_at(ctx, @id, "2026-10-27T14:30:52Z")
      write_session_at(ctx, @other_id, "2026-10-28T10:00:00Z", %{"title" => "Newest Thing"})

      assert [
               %{id: @other_id, title: "Newest Thing", created_at: "2026-10-28T10:00:00Z"} =
                 newest,
               %{id: @id, title: nil} = older
             ] = Session.summaries(ctx.tmp_dir)

      # The preview is the FIRST USER message — the system prompt (ADR 0019)
      # and any later turns are not row material.
      assert newest.preview == "the first question"
      assert newest.pin == %{profile: "work", model: "glm-5.3-flash", base_url: nil}
      assert older.preview == "the first question"
    end

    @tag :tmp_dir
    test "a user turn carried as content parts previews its text parts (ADR 0018 §2)", ctx do
      write_session_at(ctx, @id, @created_at, %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "look at "},
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,xx"}},
              %{"type" => "text", "text" => "this"}
            ]
          }
        ]
      })

      assert [%{preview: "look at this"}] = Session.summaries(ctx.tmp_dir)
    end

    @tag :tmp_dir
    test "a user turn with neither string nor parts content previews as empty", ctx do
      # Hand-damage the load path would refuse; the listing fail-opens —
      # the picker previews nothing rather than crashing on the row.
      write_session_at(ctx, @id, @created_at, %{
        "messages" => [%{"role" => "user", "content" => 12}]
      })

      assert [%{preview: ""}] = Session.summaries(ctx.tmp_dir)
    end

    @tag :tmp_dir
    test "skips what it cannot pick: legacy names, damaged bodies, id mismatches", ctx do
      # A timestamp-named file (pre-sweep shape — unresumable, ADR 0023 §2)…
      legacy = Path.join(ctx.tmp_dir, "20261027-143052-a1b2c3.json")
      File.write!(legacy, "{}")
      # …a garbage body, a non-map body, an id that disagrees with its
      # filename, a missing created_at, and a non-list messages field.
      garbage = Path.join(ctx.tmp_dir, @id <> ".json")
      File.write!(garbage, "{not json")
      other = Path.join(ctx.tmp_dir, @other_id <> ".json")
      File.write!(other, ~s([1, 2]))
      third = "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5e"
      write_session_at(ctx, third, @created_at, %{"id" => @id})
      fourth = "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b5f"
      write_session_at(ctx, fourth, %{"created_at" => 12})
      fifth = "01926cf4-9e8b-7f21-a3c4-8d1e2f3a4b50"
      write_session_at(ctx, fifth, @created_at, %{"messages" => %{}})

      assert Session.summaries(ctx.tmp_dir) == []
      # Nothing was written: the damaged files are byte-identical, and no
      # fresh files appeared (the load path stays the loud reporter).
      assert length(File.ls!(ctx.tmp_dir)) == 6
    end

    @tag :tmp_dir
    test "a nil directory and a missing directory list nothing", ctx do
      assert Session.summaries(nil) == []
      absent = Path.join(ctx.tmp_dir, "absent")
      assert Session.summaries(absent) == []
    end
  end

  describe "migrate_legacy_ids/1" do
    # The suite's one deliberate legacy-shaped id: the sweep's input.
    @legacy_id "20261027-090000-abc123"
    @bad_legacy_id "20261027-090500-bad000"

    defp legacy_body(overrides \\ []) do
      Map.merge(
        %{
          "version" => 1,
          "id" => @legacy_id,
          "created_at" => "2026-10-27T09:00:00Z",
          "pin" => %{"profile" => "personal", "model" => "glm-5.3", "base_url" => nil},
          "messages" => [%{"role" => "user", "content" => "legacy"}]
        },
        Map.new(overrides)
      )
    end

    defp write_legacy(ctx, body \\ legacy_body()) do
      file = legacy_path(ctx)
      File.write!(file, Jason.encode!(body))
    end

    defp legacy_path(ctx, id \\ @legacy_id), do: Path.join(ctx.tmp_dir, id <> ".json")

    @tag :tmp_dir
    test "a fully-loading legacy file is rewritten under a fresh id, fields verbatim", ctx do
      body =
        Map.merge(legacy_body(), %{
          "title" => "Kept Title",
          "context" => %{"prompt_tokens" => 3, "messages" => 1}
        })

      write_legacy(ctx, body)

      assert {:ok, 1} = Session.migrate_legacy_ids(ctx.tmp_dir)
      legacy = legacy_path(ctx)
      refute File.exists?(legacy)

      assert [new_name] = File.ls!(ctx.tmp_dir)
      new_id = Path.rootname(new_name)
      new_file = Path.join(ctx.tmp_dir, new_name)
      assert mode(new_file) == 0o600

      assert {:ok, loaded} = Session.load(ctx.tmp_dir, new_id)
      assert loaded.id == new_id
      assert loaded.created_at == "2026-10-27T09:00:00Z"
      assert loaded.pin == %{profile: "personal", model: "glm-5.3", base_url: nil}
      assert loaded.messages == [%{"role" => "user", "content" => "legacy"}]
      assert loaded.title == "Kept Title"
      assert loaded.context == %{prompt_tokens: 3, messages: 1}
    end

    @tag :tmp_dir
    test "a legacy file that does not fully load is left untouched", ctx do
      file = legacy_path(ctx)
      File.write!(file, "definitely {{{ not json")

      assert {:ok, 0} = Session.migrate_legacy_ids(ctx.tmp_dir)
      assert File.read!(file) == "definitely {{{ not json"
    end

    @tag :tmp_dir
    test "an all-uuid directory is steady state: zero writes", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}])
      file = path(ctx)
      {:ok, stat_before} = File.stat(file)

      assert {:ok, 0} = Session.migrate_legacy_ids(ctx.tmp_dir)

      {:ok, stat_after} = File.stat(file)
      assert stat_after.mtime == stat_before.mtime
      assert stat_after.size == stat_before.size
    end

    @tag :tmp_dir
    test "a missing directory is {:ok, 0} and stays missing", ctx do
      dir = Path.join(ctx.tmp_dir, "does-not-exist")
      assert {:ok, 0} = Session.migrate_legacy_ids(dir)
      refute File.exists?(dir)
    end

    @tag :tmp_dir
    test "a mixed directory migrates only the legacy names", ctx do
      save_ok(ctx, [%{role: "user", content: "already uuid"}])
      write_legacy(ctx)
      bad = legacy_path(ctx, @bad_legacy_id)
      File.write!(bad, "garbage {{{")
      notes = Path.join(ctx.tmp_dir, "notes.txt")
      File.write!(notes, "not a session file")

      assert {:ok, 1} = Session.migrate_legacy_ids(ctx.tmp_dir)

      assert File.read!(bad) == "garbage {{{"
      assert File.read!(notes) == "not a session file"
      assert {:ok, _loaded} = Session.load(ctx.tmp_dir, @id)
      legacy = legacy_path(ctx)
      refute File.exists?(legacy)

      kept = [@id <> ".json", @bad_legacy_id <> ".json", "notes.txt"]
      rest = File.ls!(ctx.tmp_dir) -- kept
      assert [new_name] = rest
      new_id = Path.rootname(new_name)

      assert {:ok, %{messages: [%{"role" => "user", "content" => "legacy"}]}} =
               Session.load(ctx.tmp_dir, new_id)
    end

    @tag :tmp_dir
    test "a uuid-named file is exempt by name shape alone, even when its body is damaged",
         ctx do
      file = path(ctx)
      body = %{"version" => 1, "id" => "another-session", "created_at" => @created_at}
      File.write!(file, Jason.encode!(body))

      assert {:ok, 0} = Session.migrate_legacy_ids(ctx.tmp_dir)
      assert File.read!(file) == Jason.encode!(body)
    end

    # The one deterministic save-failure trigger: a read-only directory (the
    # suite runs unprivileged — local user and the CI runner — so chmod bites;
    # the directory trick cannot work here, the file must exist to load).
    @tag :tmp_dir
    test "a save failure during the sweep errors naming the path", ctx do
      write_legacy(ctx)
      dir = ctx.tmp_dir
      on_exit(fn -> File.chmod(dir, 0o755) end)

      File.chmod!(dir, 0o555)
      assert {:error, error} = Session.migrate_legacy_ids(dir)
      assert error =~ dir
      # The legacy file survived the failed rewrite.
      legacy = legacy_path(ctx)
      assert File.exists?(legacy)
    end
  end

  describe "orphan tool results" do
    @tag :tmp_dir
    test "a tool message with no assistant batch before it refuses naming the index", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "go"},
          tool_result("call_9", "{}")
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 1"
    end

    @tag :tmp_dir
    test "a tool result for an id the batch never announced refuses naming the index", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "go"},
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          tool_result("call_other", "{}")
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 2"
    end
  end

  describe "duplicate batch ids" do
    @tag :tmp_dir
    test "a batch that repeats an id refuses, naming the index and the id", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "go"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [call("call_1"), call("call_1")]
          },
          tool_result("call_1", ~s({"ok":true})),
          tool_result("call_1", ~s({"ok":true}))
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 1"
      assert msg =~ "call_1"
    end

    @tag :tmp_dir
    test "distinct ids across different batches still load", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          tool_result("call_1", ~s({"ok":true})),
          %{"role" => "user", "content" => "next turn"},
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_2")]},
          tool_result("call_2", ~s({"ok":true}))
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert length(loaded.messages) == 5
    end
  end

  describe "detached tool answers" do
    @tag :tmp_dir
    test "an answer after an intervening user message refuses as detached from its batch", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          %{"role" => "user", "content" => "interrupted"},
          tool_result("call_1", ~s({"ok":true}))
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 2"
      assert msg =~ "detached from its batch"
    end

    @tag :tmp_dir
    test "an answer after an intervening assistant message refuses the same way", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          %{"role" => "assistant", "content" => "meanwhile"},
          tool_result("call_1", ~s({"ok":true}))
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 2"
      assert msg =~ "detached from its batch"
    end

    @tag :tmp_dir
    test "the contiguous equivalent loads unchanged", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          tool_result("call_1", ~s({"ok":true})),
          %{"role" => "user", "content" => "next turn"},
          %{"role" => "assistant", "content" => "done"}
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert length(loaded.messages) == 4
    end
  end

  describe "duplicate answers in one block" do
    @tag :tmp_dir
    test "one call answered twice in the same block refuses, naming the index", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "go"},
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          tool_result("call_1", ~s({"ok":true})),
          tool_result("call_1", ~s({"ok":true}))
        ])
      )

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 3"
      assert msg =~ "duplicate answer for tool call \"call_1\""
    end

    @tag :tmp_dir
    test "two calls answered once each still load", ctx do
      write_body(
        ctx,
        body_with([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [call("call_1"), call("call_2")]
          },
          tool_result("call_1", ~s({"ok":true})),
          tool_result("call_2", ~s({"ok":true}))
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert length(loaded.messages) == 3
    end
  end

  describe "dangling repair" do
    @tag :tmp_dir
    test "one dangling call gains exactly one cancelled result", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "user", "content" => "go"},
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]}
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert [_user, _assistant, repaired] = loaded.messages
      assert repaired == cancelled("call_1")
    end

    @tag :tmp_dir
    test "two dangling calls gain results in call order", ctx do
      write_body(
        ctx,
        body_with([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [call("call_b"), call("call_a")]
          }
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert [_assistant, first, second] = loaded.messages
      assert first == cancelled("call_b")
      assert second == cancelled("call_a")
    end

    @tag :tmp_dir
    test "one of two results present: only the missing id is repaired, at the block's end", ctx do
      write_body(
        ctx,
        body_with([
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [call("call_1"), call("call_2")]
          },
          tool_result("call_2", ~s({"ok":true}))
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert [_assistant, answered, repaired] = loaded.messages
      assert answered == tool_result("call_2", ~s({"ok":true}))
      assert repaired == cancelled("call_1")
    end

    @tag :tmp_dir
    test "a dangling batch mid-file is repaired in place, before later messages", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          %{"role" => "user", "content" => "next turn"}
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert [_assistant, repaired, _user] = loaded.messages
      assert repaired == cancelled("call_1")
    end

    @tag :tmp_dir
    test "a repaired load leaves the file byte-identical", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]}
        ])
      )

      file = path(ctx)
      on_disk = File.read!(file)
      assert {:ok, _loaded} = load(ctx)
      assert File.read!(file) == on_disk
    end

    @tag :tmp_dir
    test "a batch whose calls were all answered gains nothing", ctx do
      write_body(
        ctx,
        body_with([
          %{"role" => "assistant", "content" => nil, "tool_calls" => [call("call_1")]},
          tool_result("call_1", ~s({"ok":true})),
          %{"role" => "assistant", "content" => "done"}
        ])
      )

      assert {:ok, loaded} = load(ctx)
      assert length(loaded.messages) == 3
    end
  end
end

defmodule DashFloat.SessionTest do
  @moduledoc false
  # tmp-dir discipline: every test runs against ctx.tmp_dir — the real XDG
  # data dir is off-limits. See ADR 0014 §2–§4.
  use ExUnit.Case, async: true

  alias DashFloat.Session

  @id "20261027-143052-a1b2c3"
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

    test "new_id/0 is UTC YYYYMMDD-HHMMSS plus six lowercase hex chars" do
      assert Regex.match?(~r/^\d{8}-\d{6}-[0-9a-f]{6}$/, Session.new_id())
    end

    test "two ids minted in the same second differ" do
      ids = for _i <- 1..25, do: Session.new_id()
      assert Enum.uniq(ids) == ids
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
               ]
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
          for _ <- 1..300 do
            assert :ok = Session.save(ctx.tmp_dir, session([%{role: "user", content: content}]))
          end
        end
      end

      task_a = Task.async(writer.(a))
      task_b = Task.async(writer.(b))

      reader =
        Task.async(fn ->
          for _ <- 1..600 do
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
      write_body(ctx, body_with([%{"role" => "system", "content" => "x"}]))

      assert {:error, msg} = load(ctx)
      assert msg =~ "message 0"
      assert msg =~ ~s("role")
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
  end

  describe "session id shape" do
    test "save refuses an id outside the minted shape, writing nothing" do
      dir = Path.join("/tmp/opencode", "dashfloat-id-shape-#{System.unique_integer([:positive])}")

      assert {:error, msg} = Session.save(dir, session([], id: "../escape"))
      assert msg == "session ids look like 20261027-143052-a1b2c3"
      refute File.exists?(dir)
    end

    @tag :tmp_dir
    test "load refuses an id outside the shape, including a traversal attempt", ctx do
      assert {:error, msg} = Session.load(ctx.tmp_dir, "../escape")
      assert msg == "session ids look like 20261027-143052-a1b2c3"
      assert File.ls!(ctx.tmp_dir) == []
    end

    @tag :tmp_dir
    test "a requested id with the trailing .json `ls` prints still loads", ctx do
      save_ok(ctx, [%{role: "user", content: "hi"}])
      assert {:ok, loaded} = Session.load(ctx.tmp_dir, @id <> ".json")
      assert loaded.id == @id
      assert loaded.messages == [%{"role" => "user", "content" => "hi"}]
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

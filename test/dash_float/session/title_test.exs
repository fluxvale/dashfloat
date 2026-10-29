defmodule DashFloat.Session.TitleTest do
  @moduledoc false
  # tmp-dir discipline: every file-touching test runs against ctx.tmp_dir —
  # the real XDG data dir is off-limits. See #80.
  use ExUnit.Case, async: true

  alias DashFloat.Session
  alias DashFloat.Session.Title

  describe "normalize/1" do
    test "trims, collapses inner whitespace runs, and preserves case" do
      assert Title.normalize("  Fix   the Login Bug ") == {:ok, "Fix the Login Bug"}
      assert Title.normalize("Résumé ✅") == {:ok, "Résumé ✅"}
    end

    test "80 graphemes pass, 81 refuse as :too_long" do
      assert Title.normalize(String.duplicate("a", 80)) == {:ok, String.duplicate("a", 80)}
      assert Title.normalize(String.duplicate("a", 81)) == {:error, :too_long}
    end

    test "blank, whitespace-only, control-only, and non-string input are :empty" do
      assert Title.normalize("") == {:error, :empty}
      assert Title.normalize("   ") == {:error, :empty}
      assert Title.normalize("\u{0}\u{1}") == {:error, :empty}
      assert Title.normalize(nil) == {:error, :empty}
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
      File.write!(Path.join(ctx.tmp_dir, "garbage.json"), "not json {{{")
      File.write!(Path.join(ctx.tmp_dir, "list.json"), Jason.encode!([1, 2]))

      id = "0192aa10-a003-7b00-8000-000000000003"
      save_titled(ctx, id, "Fix the bug")
      assert Title.title_holder(ctx.tmp_dir, "Fix the bug") == id
    end

    @tag :tmp_dir
    test "a missing directory is free", ctx do
      assert Title.title_holder(Path.join(ctx.tmp_dir, "does-not-exist"), "Fix the bug") == nil
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
end

defmodule DashFloat.Tools.EditTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Tools.Edit

  test "an empty search block is an error before any matching" do
    assert Edit.locate("anything", "") == {:error, :empty_search}
    assert Edit.locate("", "") == {:error, :empty_search}
  end

  test "zero matches" do
    assert Edit.locate("hello world", "goodbye") == {:error, {:no_match, 0}}
    assert Edit.locate("", "x") == {:error, {:no_match, 0}}
  end

  test "two or more matches are ambiguous with their count" do
    assert Edit.locate("aXbXc", "X") == {:error, {:ambiguous, 2}}
    assert Edit.locate("aXbXcXd", "X") == {:error, {:ambiguous, 3}}
    # Non-overlapping: "aaaa" holds two "aa" matches, not three.
    assert Edit.locate("aaaa", "aa") == {:error, {:ambiguous, 2}}
  end

  test "a unique match returns its byte offset" do
    assert Edit.locate("hello world", "world") == {:ok, %{count: 1, start: 6}}
    assert Edit.locate("prefix", "prefix") == {:ok, %{count: 1, start: 0}}
  end

  test "the offset counts bytes, not codepoints" do
    # "héllo\n" is 7 bytes (é is two), so "world" starts at byte 7.
    assert Edit.locate("héllo\nworld", "world") == {:ok, %{count: 1, start: 7}}
  end

  test "lines drops the trailing empty piece but keeps interior empties" do
    assert Edit.lines("a\nb\n") == ["a", "b"]
    assert Edit.lines("a\nb") == ["a", "b"]
    assert Edit.lines("") == []
    assert Edit.lines("\n") == [""]
    assert Edit.lines("a\n\nb\n") == ["a", "", "b"]
  end
end

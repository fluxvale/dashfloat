defmodule DashFloat.TUI.SelectionTest do
  @moduledoc """
  Selection geometry over display rows (issue #28; ADR 0006 amendment):
  column ranges, cluster-atomic slicing (wide chars and emoji), reverse-
  video highlighting with boundary span splits, display-faithful copy, and
  the OSC 52 payload.
  """

  use ExUnit.Case, async: true

  alias DashFloat.TUI.Selection
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  defp line(texts) when is_list(texts) do
    texts
    |> Enum.map(&Span.new(&1))
    |> Line.new()
  end

  defp plain(%Line{} = line), do: Enum.map_join(line.spans, "", & &1.content)

  describe "range/1" do
    test "orders the bounds row-major regardless of drag direction" do
      assert Selection.range(%{anchor: {5, 10}, head: {2, 3}}) == {{2, 3}, {5, 10}}
      assert Selection.range(%{anchor: {2, 3}, head: {5, 10}}) == {{2, 3}, {5, 10}}
      assert Selection.range(%{anchor: {1, 9}, head: {2, 0}}) == {{1, 9}, {2, 0}}
    end
  end

  describe "columns/2" do
    test "single row: one column range" do
      sel = %{anchor: {4, 2}, head: {4, 9}}
      assert Selection.columns(sel, 4) == {2, 10}
      assert Selection.columns(sel, 3) == nil
      assert Selection.columns(sel, 5) == nil
    end

    test "multi row: first from col, interior whole, last to col" do
      sel = %{anchor: {2, 5}, head: {5, 3}}

      assert Selection.columns(sel, 2) == {5, nil}
      assert Selection.columns(sel, 3) == {0, nil}
      assert Selection.columns(sel, 4) == {0, nil}
      assert Selection.columns(sel, 5) == {0, 4}
    end

    test "covers_row?/2 follows the range" do
      sel = %{anchor: {2, 5}, head: {5, 3}}
      assert Selection.covers_row?(sel, 2)
      assert Selection.covers_row?(sel, 5)
      refute Selection.covers_row?(sel, 1)
      refute Selection.covers_row?(sel, 6)
    end
  end

  describe "slice_text/2" do
    test "slices plain text by half-open column range" do
      assert slice(["hello world"], {0, 5}) == "hello"
      assert slice(["hello world"], {6, 11}) == "world"
      assert slice(["hello world"], {3, 3}) == ""
    end

    test "whole row with nil to-column, trailing blanks trimmed" do
      assert slice(["row text   "], nil) == "row text"
    end

    test "slices across span boundaries" do
      assert slice(["abc", "def", "ghi"], {2, 5}) == "cde"
    end

    # "漢字xy": 漢 occupies columns 0-1, 字 2-3, x 4, y 5. A cluster belongs
    # to the range iff its FIRST column is in it — never split.
    test "wide clusters are atomic: selection starting mid-cluster" do
      row = line(["漢字xy"])

      assert Selection.slice_text(row, {0, 2}) == "漢"
      # starts at 字's second column: 漢 excluded, 字 included whole.
      assert Selection.slice_text(row, {1, 4}) == "字"
      assert Selection.slice_text(row, {2, 5}) == "字x"
      assert Selection.slice_text(row, {4, 6}) == "xy"
      # ends at 字's first column: 字 excluded; one column later it is in.
      assert Selection.slice_text(row, {0, 2}) == "漢"
      assert Selection.slice_text(row, {0, 3}) == "漢字"
    end

    test "emoji presentation sequences are atomic" do
      row = line(["a⚠️b"])
      # ⚠️ is one cluster at columns 1-2; a slice ending inside it keeps it.
      assert Selection.slice_text(row, {0, 2}) == "a⚠️"
      assert Selection.slice_text(row, {2, 4}) == "b"
    end
  end

  describe "extract/3" do
    test "joins rows with newlines, interior rows verbatim, trailing trimmed" do
      rows = [line(["first"]), line([""]), line(["second row"]), line(["tail"])]
      sel = %{anchor: {0, 0}, head: {3, 4}}

      assert Selection.extract(sel, rows, 0) == "first\n\nsecond row\ntail"
    end

    test "edge rows slice by column, wrapped rows copy display-faithful" do
      # One logical line wrapped into three display rows (hang indent on the
      # continuation rows, as the wrap layer produces).
      rows = [
        line(["the quick brown"]),
        line(["  fox jumps over"]),
        line(["  the lazy dog"])
      ]

      # Whole wrap selected: every word arrives, in order, rows joined.
      sel = %{anchor: {0, 0}, head: {2, 14}}

      words =
        sel
        |> Selection.extract(rows, 0)
        |> String.split()

      assert words == ~w(the quick brown fox jumps over the lazy dog)

      # Partial: first row from col 4, last row to col 3.
      partial = %{anchor: {0, 4}, head: {2, 3}}
      assert Selection.extract(partial, rows, 0) == "quick brown\n  fox jumps over\n  th"
    end

    test "a selection of pure blank rows copies nothing" do
      rows = [line([""]), line([""])]

      # Raw geometry: two empty rows join to one newline — the state layer
      # treats whitespace-only copies as nothing (see StateTest).
      assert Selection.extract(%{anchor: {0, 0}, head: {1, 0}}, rows, 0) == "\n"
    end
  end

  describe "extract_capped/4" do
    defp sel(first \\ 0) do
      %{anchor: {first, 0}, head: {first + 3, 999}, base_rows: 0}
    end

    test "under the cap it is extract/3 exactly" do
      rows = for i <- 1..4, do: line(["row #{i}"])

      assert Selection.extract_capped(sel(), rows, 0, 100) ==
               {:ok, Selection.extract(sel(), rows, 0)}
    end

    test "over the cap the build stops at the boundary" do
      # Review P2a: the BUILD is bounded — the full span never
      # materialises, and the reported bytes are the accumulated size at
      # the stop (a lower bound of the full copy).
      rows = for i <- 1..4, do: line(["row #{i}"])

      assert {:too_large, bytes} = Selection.extract_capped(sel(), rows, 0, 10)

      # "row 1" fits (5); joining "row 2" crosses the cap and stops there.
      assert bytes == 11
    end

    test "empty rows yield the empty copy" do
      assert Selection.extract_capped(sel(), [], 0, 100) == {:ok, ""}
    end
  end

  describe "highlight/2" do
    test "whole-row coverage reverses every span" do
      highlighted = highlight(["abc", "def"], {0, nil})

      assert Enum.all?(highlighted.spans, &(:reversed in &1.style.modifiers))
      assert plain(highlighted) == "abcdef"
    end

    test "partial coverage splits boundary spans and keeps styles" do
      fg = %ExRatatui.Style{fg: :green}
      row = Line.new([Span.new("hello ", style: fg), Span.new("world", style: fg)])
      highlighted = Selection.highlight(row, {3, 8})

      assert plain(highlighted) == "hello world"

      modifiers = Enum.map(highlighted.spans, &{&1.content, :reversed in &1.style.modifiers})
      assert modifiers == [{"hel", false}, {"lo ", true}, {"wo", true}, {"rld", false}]

      # The split pieces keep the original style plus the modifier.
      assert Enum.all?(highlighted.spans, &(&1.style.fg == :green))
    end

    test "a wide cluster is never halved by the highlight boundary" do
      highlighted = highlight(["漢字"], {1, 3})

      assert [{"漢", false}, {"字", true}] =
               Enum.map(highlighted.spans, &{&1.content, :reversed in &1.style.modifiers})
    end

    test "out-of-range rows pass through untouched" do
      row = line(["untouched"])
      assert Selection.highlight(row, nil) == row
    end
  end

  defp slice(texts, cols) do
    texts
    |> line()
    |> Selection.slice_text(cols)
  end

  defp highlight(texts, cols) do
    texts
    |> line()
    |> Selection.highlight(cols)
  end

  describe "osc52/1" do
    test "is the BEL-terminated base64 OSC 52 sequence" do
      assert Selection.osc52("hi") == "\e]52;c;" <> Base.encode64("hi") <> "\a"
    end
  end
end

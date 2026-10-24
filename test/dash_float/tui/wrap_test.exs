defmodule DashFloat.TUI.WrapTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.Wrap
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  defp line(texts) when is_list(texts) do
    texts
    |> Enum.map(fn {text, role} -> Span.new(text, style: Theme.style(role)) end)
    |> Line.new()
  end

  defp line(text), do: Line.new([Span.new(text)])

  defp flat(lines), do: Enum.map(lines, &Enum.map_join(&1.spans, "", fn s -> s.content end))

  describe "width/1" do
    test "ASCII and Latin-1 count one column per codepoint" do
      assert Wrap.width("") == 0
      assert Wrap.width("abc XYZ 123") == 11
      assert Wrap.width("café") == 4
    end

    test "East Asian Wide and Fullwidth count two columns" do
      assert Wrap.width("日本語") == 6
      assert Wrap.width("ｆｕｌｌｗｉｄｔｈ") == 18
      assert Wrap.width("한글") == 4
    end

    test "emoji count two columns" do
      assert Wrap.width("🎉") == 2
      assert Wrap.width("ok👍") == 4
    end

    test "combining marks and zero-width format characters count zero" do
      # e + combining acute (decomposed) is one column; the bare ZWJ joins
      # clusters without adding width of its own (the cluster rule below
      # handles full ZWJ sequences).
      assert Wrap.width("e\u0301") == 1
      assert Wrap.width("a\u200Db") == 2
    end

    test "emoji presentation sequences and ZWJ clusters render two columns" do
      # VS16 presentation (⚠️, ❤️, keycap) and ZWJ families are one emoji
      # cell pair in the renderer — never the per-codepoint sum.
      assert Wrap.width("⚠️") == 2
      assert Wrap.width("❤️") == 2
      assert Wrap.width("1️⃣") == 2
      assert Wrap.width("👨‍👩‍👧") == 2
      assert Wrap.width("👍🏽") == 2
      run = String.duplicate("⚠️", 39)
      assert Wrap.width(run) == 78
    end

    test "mixed runs account per codepoint" do
      assert Wrap.width("a日b🎉c") == 1 + 2 + 1 + 2 + 1
    end

    test "invalid UTF-8 counts as replacement glyphs, not early stop" do
      bad = "ok" <> <<0xFF, 0xFE>> <> "after"
      assert String.valid?(bad) == false
      # 2 invalid bytes -> 2 U+FFFD replacement glyphs, 1 column each.
      assert Wrap.width(bad) == String.length("ok") + 2 + String.length("after")
    end
  end

  describe "wrap/2 pass-through" do
    test "a line that fits is rebuilt identically" do
      original = [line([{"❯ ", :dim_italic}, {"hello world", :assistant}]), line("second")]

      assert Wrap.wrap(original, 80) == original
    end

    test "the line's own style and alignment ride along wrapped rows" do
      styled = %Line{line("a very long heading indeed") | alignment: :center}

      wrapped = Wrap.wrap([styled], 10)

      assert Enum.all?(wrapped, &(&1.alignment == :center))
    end

    test "blank lines pass through" do
      blank = Line.new([Span.new("")])
      assert Wrap.wrap([blank], 10) == [blank]
      assert Wrap.wrap([line("   ")], 10) == [line("   ")]
    end

    test "a width below one wraps at a single column" do
      assert flat(Wrap.wrap([line("ab")], 0)) == ["a", "b"]
    end
  end

  describe "wrap/2 word boundaries" do
    test "wraps at the word that would overflow, keeping words whole" do
      assert flat(Wrap.wrap([line("the quick brown fox")], 15)) == [
               "the quick brown",
               "fox"
             ]
    end

    test "a word exactly filling the row closes it" do
      assert flat(Wrap.wrap([line("abcdefghij klm")], 10)) == ["abcdefghij", "klm"]
    end

    test "whitespace at the wrap point is dropped, not carried" do
      assert flat(Wrap.wrap([line("aaa   bbb")], 3)) == ["aaa", "bbb"]
    end

    test "leading whitespace survives on the first row and indents continuations" do
      # The leading whitespace run is the hanging indent: every continuation
      # row re-carries it (tool output, user echo).
      assert flat(Wrap.wrap([line("  one two")], 5)) == ["  one", "  two"]
    end

    test "marker prefixes hang their continuations under the opener" do
      # Bullets, quote bars, prompts, gear rows: continuation rows indent by
      # the marker's width; the marker itself stays on the first row only
      # (review N3 — flush-left continuations broke the visual structure).
      bullet = line([{"• ", :assistant}, {"a list item that is long", :assistant}])

      assert flat(Wrap.wrap([bullet], 12)) == ["• a list ", "  item that ", "  is long"]

      quote_row = line([{"│ ", :quote}, {"a quoted paragraph that runs wide", :assistant}])

      assert flat(Wrap.wrap([quote_row], 14)) == [
               "│ a quoted ",
               "  paragraph ",
               "  that runs ",
               "  wide"
             ]

      prompt = line([{"❯ ", :user}, {"the quick brown fox jumps", :user}])

      assert flat(Wrap.wrap([prompt], 12)) == ["❯ the quick ", "  brown fox ", "  jumps"]
    end

    test "prose never hangs: a leading short word is not a marker" do
      assert flat(Wrap.wrap([line("the quick brown fox jumps over")], 12)) == [
               "the quick ",
               "brown fox ",
               "jumps over"
             ]
    end

    test "an indent wider than half the row is dropped, not guttered" do
      # Deep-nested output on a narrow terminal: wrapping at width beats a
      # two-column budget (review N5/N6).
      deep = line(String.duplicate(" ", 8) <> "return value here")

      assert flat(Wrap.wrap([deep], 10)) == ["return ", "value here"]
    end

    test "a whitespace run that overflows the row never fuses adjacent words" do
      # Regression (hostile review P1-2): the dropped run used to leave the
      # next word on the same row, deleting the gap — and the words' spacing
      # with it.
      assert flat(Wrap.wrap([line("left" <> String.duplicate(" ", 80) <> "right")], 80)) == [
               "left",
               "right"
             ]

      assert flat(Wrap.wrap([line("| a" <> String.duplicate(" ", 10) <> "| b |")], 12)) == [
               "| a",
               "  | b |"
             ]

      tail = "xxxx" <> String.duplicate("x", 36) <> String.duplicate(" ", 50) <> "TAIL_VALUE"

      assert flat(Wrap.wrap([line(tail)], 80)) == [
               String.duplicate("x", 40),
               "TAIL_VALUE"
             ]
    end
  end

  describe "wrap/2 unbreakable runs" do
    test "a run longer than a row splits at glyph boundaries with no loss" do
      url = "https://example.com/some/very/long/path"

      assert flat(Wrap.wrap([line(url)], 20)) ==
               ["https://example.com/", "some/very/long/path"]
    end

    test "a long run fills the current row remainder first" do
      assert flat(Wrap.wrap([line("go aaaaaaaaaa")], 6)) == ["go aaa", "aaaaaa", "a"]
    end

    test "a hash wider than the row wraps fully at width 8" do
      hash = "a1b2c3d4e5f6a7b8c9d0e1f2"

      assert flat(Wrap.wrap([line(hash)], 8)) == ["a1b2c3d4", "e5f6a7b8", "c9d0e1f2"]
    end

    test "an over-long word after an exactly full row starts a fresh row" do
      assert flat(Wrap.wrap([line("1234567890abcdefghijklm")], 10)) == [
               "1234567890",
               "abcdefghij",
               "klm"
             ]

      # The row is exactly full when the over-long word arrives: it closes
      # the row first, then splits across fresh rows.
      assert flat(Wrap.wrap([line("abcdefghij klmnopqrstuvwx")], 10)) == [
               "abcdefghij",
               "klmnopqrst",
               "uvwx"
             ]
    end
  end

  describe "wrap/2 wide characters" do
    test "CJK wraps at half the columns, rows stay within the width" do
      text = "日本語のテキストは全角で二列を使う"

      wrapped = Wrap.wrap([line(text)], 20)

      assert flat(wrapped) == ["日本語のテキストは全", "角で二列を使う"]
      assert Enum.all?(wrapped, fn row -> Wrap.width(hd(flat([row]))) <= 20 end)
    end

    test "a wide grapheme never straddles the boundary" do
      # 9 wide chars = 18 columns; the next wide char needs 2, row has 1 left.
      assert flat(Wrap.wrap([line("一二三四五六七八九十")], 19)) == [
               "一二三四五六七八九",
               "十"
             ]
    end

    test "a wide grapheme never starts a row it would overflow" do
      # 78 columns filled, one left: the CJK pair needs two, so the row
      # closes first (regression, hostile review P2-1: it used to emit an
      # 81-column row and the renderer clipped one glyph).
      src = String.duplicate("x", 78) <> " " <> String.duplicate("日", 60)
      rows = Wrap.wrap([line(src)], 80)

      assert Enum.all?(rows, &(Wrap.width(flatten_row(&1)) <= 80))

      joined =
        rows
        |> Enum.map_join(&flatten_row/1)
        |> String.replace(" ", "")

      assert joined == String.replace(src, " ", "")
    end

    defp flatten_row(row), do: Enum.map_join(row.spans, "", & &1.content)

    test "a wide grapheme in a 1-column budget still makes progress" do
      assert flat(Wrap.wrap([line("日x")], 1)) == ["日", "x"]
    end

    test "a lone grapheme wider than the budget renders as its own row" do
      assert flat(Wrap.wrap([line("日")], 1)) == ["日"]
    end
  end

  describe "renderer agreement (width never undercounts the renderer)" do
    alias ExRatatui.CellSession
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Paragraph

    # The width tables are asserted against the actual renderer, cell by
    # cell: every table entry (boundaries and midpoint) and the
    # emoji-sequence families we classify must advance exactly `Wrap.width/1`
    # columns, or more (over-counts wrap early; under-counts truncate — the
    # #20 bug). Technique: draw `X <> text <> Y` per row and read the column
    # Y lands on (the #20 review's differential probe).
    test "every table entry matches or over-counts the renderer's advance" do
      {wide, zero} = Wrap.__tables__()

      entries =
        (wide ++ zero)
        |> Enum.flat_map(fn {lo, hi} -> [lo, hi, div(lo + hi, 2)] end)
        |> Enum.uniq()

      entries
      |> Enum.map(&<<&1::utf8>>)
      |> advances()
      |> Enum.zip(entries)
      |> Enum.each(fn {rendered, cp} ->
        measured = Wrap.width(<<cp::utf8>>)

        assert is_integer(rendered) and measured >= rendered,
               "U+#{Integer.to_string(cp, 16)} undercounts: wrap=#{measured} render=#{rendered}"
      end)
    end

    test "emoji sequence families match the renderer's advance exactly" do
      sequences = [
        "⚠️",
        "❤️",
        "1️⃣",
        "🏳️‍🌈",
        "👨‍👩‍👧",
        "👍🏽",
        "☝🏽",
        "✍🏽",
        "e\u0301",
        "日",
        "ｆ",
        "a\u200Db",
        "TRL"
      ]

      sequences
      |> advances()
      |> Enum.zip(sequences)
      |> Enum.each(fn {rendered, seq} ->
        assert rendered == Wrap.width(seq),
               "#{inspect(seq)} wrap=#{Wrap.width(seq)} render=#{rendered}"
      end)
    end

    defp advances(texts) do
      lines = Enum.map(texts, &Line.new([Span.new("X" <> &1 <> "Y")]))
      height = length(lines)
      session = CellSession.new(20, height)

      :ok =
        CellSession.draw(session, [
          {%Paragraph{text: lines}, %Rect{x: 0, y: 0, width: 20, height: height}}
        ])

      y_cols =
        session
        |> CellSession.take_cells()
        |> Map.get(:cells, [])
        |> Enum.filter(&(&1.symbol == "Y"))
        |> Enum.group_by(& &1.row, & &1.col)
        |> Enum.into(%{}, fn {row, cols} -> {row, Enum.max(cols)} end)

      CellSession.close(session)

      Enum.with_index(texts, fn _text, i -> Map.get(y_cols, i, 0) - 1 end)
    end
  end

  describe "wrap/2 styled spans" do
    test "a word that fits a row of its own moves whole to the next row" do
      wrapped = Wrap.wrap([line([{"hello ", :dim}, {"bigworld", :accent}])], 8)

      assert flat(wrapped) == ["hello ", "bigworld"]

      assert Enum.map(hd(wrapped).spans, & &1.style) == [Theme.style(:dim)]
      assert Enum.map(Enum.at(wrapped, 1).spans, & &1.style) == [Theme.style(:accent)]
    end

    test "invalid UTF-8 in a span wraps as replacement glyphs, losing nothing" do
      bad = "good " <> <<0xFF, 0xFE>> <> " bytes"

      assert flat(Wrap.wrap([line(bad)], 20)) == [
               "good " <> String.replace_invalid(<<0xFF, 0xFE>>) <> " bytes"
             ]
    end

    test "adjacent same-style pieces merge back into one span" do
      wrapped = Wrap.wrap([line([{"a b c", :assistant}])], 10)
      assert [%Span{content: "a b c"}] = hd(wrapped).spans
    end

    test "a prefix span and body span on one fitting row stay separate spans" do
      original = [line([{"⚙ ", :accent}, {"read_file lib/foo.ex", :dim}])]
      assert Wrap.wrap(original, 80) == original
    end

    test "a wrapped markdown heading keeps the heading style on both rows" do
      heading = Line.new([Span.new("A very long heading indeed", style: Theme.style(:heading1))])
      wrapped = Wrap.wrap([heading], 10)

      assert flat(wrapped) == ["A very ", "long ", "heading ", "indeed"]

      assert Enum.all?(wrapped, fn line ->
               Enum.all?(line.spans, &(&1.style == Theme.style(:heading1)))
             end)
    end
  end
end

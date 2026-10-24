defmodule DashFloat.TUI.MarkdownTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Markdown
  alias DashFloat.TUI.Render
  alias DashFloat.TUI.Theme
  alias ExRatatui.Text.Line

  describe "headings" do
    test "h1 is the accent, bold" do
      [line] = Markdown.render("# Big title")
      assert [{"Big title", style}] = styled(line)
      assert style.fg == {:rgb, 217, 119, 87}
      assert :bold in style.modifiers
    end

    test "h2 is bold in the default foreground" do
      [line] = Markdown.render("## Section")
      assert [{"Section", style}] = styled(line)
      assert style.fg == nil
      assert style.modifiers == [:bold]
    end

    test "h3–h6 share the bold dim style" do
      for {md, text} <- [
            {"### Third", "Third"},
            {"#### Fourth", "Fourth"},
            {"##### Fifth", "Fifth"},
            {"###### Sixth", "Sixth"}
          ] do
        [line] = Markdown.render(md)
        assert [{^text, style}] = styled(line)
        assert style.fg == :dark_gray
        assert style.modifiers == [:bold]
      end
    end
  end

  describe "inline styles" do
    test "bold, italic, and inline code mixed in one paragraph" do
      [line] = Markdown.render("A **bold** with *italic* and `inline` mixed.")

      assert flatten(line) == "A bold with italic and inline mixed."

      assert {"bold", bold} = span(line, "bold")
      assert bold.modifiers == [:bold]

      assert {"italic", italic} = span(line, "italic")
      assert italic.modifiers == [:italic]

      assert {"inline", code} = span(line, "inline")
      assert code.fg == {:indexed, 215}

      assert {"A ", plain} = span(line, "A ")
      assert plain == Theme.style(:assistant)
    end

    test "strikethrough maps to the crossed-out modifier" do
      [line] = Markdown.render("~~gone~~")
      assert [{"gone", style}] = styled(line)
      assert style.modifiers == [:crossed_out]
    end
  end

  describe "links" do
    test "the href is appended dim only when the text differs from it" do
      [line] = Markdown.render("[docs](https://example.com/x)")
      assert flatten(line) == "docs (https://example.com/x)"

      assert {"docs", text} = span(line, "docs")
      assert :underlined in text.modifiers

      assert {" (https://example.com/x)", href} = span(line, " (https://example.com/x)")
      assert href.fg == :dark_gray
    end

    test "text equal to the href renders once, and autolinks stay bare" do
      [line] = Markdown.render("[https://a.b](https://a.b) and <https://auto.link>")
      assert flatten(line) == "https://a.b and https://auto.link"
      assert length(line.spans) == 3
    end
  end

  describe "lists" do
    test "nested bullets step •◦▪ by depth with two-space indents" do
      lines = Markdown.render("- one\n- two\n  - nested a\n  - nested b\n    - deep\n")

      assert Enum.map(lines, &flatten/1) == [
               "• one",
               "• two",
               "  ◦ nested a",
               "  ◦ nested b",
               "    ▪ deep"
             ]
    end

    test "ordered lists number from one, and from their start attribute" do
      lines = Markdown.render("1. first\n2. second\n   1. deep one\n   2. deep two\n")

      assert Enum.map(lines, &flatten/1) == [
               "1. first",
               "2. second",
               "  1. deep one",
               "  2. deep two"
             ]

      started = Markdown.render("3. three\n4. four")
      assert Enum.map(started, &flatten/1) == ["3. three", "4. four"]
    end

    test "list item content may be a paragraph or carry inline styling" do
      lines = Markdown.render("- item with `code`\n\n  continued para\n")
      assert Enum.map(lines, &flatten/1) == ["• item with code", "  continued para"]
      assert {"code", style} = span(hd(lines), "code")
      assert style.fg == {:indexed, 215}
    end
  end

  describe "fenced code" do
    test "a language tag line, then one padded :code line per source line" do
      lines = Markdown.render("```elixir\ndef x do\n  1\nend\n```")

      assert Enum.map(lines, &flatten/1) == ["┈ elixir", " def x do ", "   1 ", " end "]

      [tag | body] = lines
      assert [{"┈ elixir", tag_style}] = styled(tag)
      assert tag_style.fg == :dark_gray

      for line <- body do
        [{" " <> _rest, style}] = styled(line)
        assert style.fg == {:indexed, 252}
        assert style.bg == {:indexed, 234}
      end
    end

    test "no tag line without a language" do
      lines = Markdown.render("```\nplain\n```")
      assert Enum.map(lines, &flatten/1) == [" plain "]
    end

    test "blank lines inside a fence survive as padded :code lines" do
      lines = Markdown.render("```\na\n\nb\n```")
      texts = Enum.map(lines, &flatten/1)
      assert texts == [" a ", "  ", " b "]
      refute "" in texts
    end
  end

  describe "blocks" do
    test "blockquotes prefix every line dim, nesting included" do
      lines = Markdown.render("> quoted line\n> second line\n>\n> > nested **bold**\n")

      assert Enum.map(lines, &flatten/1) == [
               "│ quoted line",
               "│ second line",
               "│ │ nested bold"
             ]

      assert [{"│ ", bar} | _rest] = styled(hd(lines))
      assert bar.fg == :dark_gray
    end

    test "hr is one long dim rule line" do
      [line] = Markdown.render("---")
      assert flatten(line) == String.duplicate("─", 120)
      assert [{"─" <> _rest, style}] = styled(line)
      assert style.fg == :dark_gray
    end

    test "a paragraph's embedded newlines flow as consecutive lines" do
      lines = Markdown.render("para line one\npara line two")
      assert Enum.map(lines, &flatten/1) == ["para line one", "para line two"]
      assert Enum.all?(lines, &(&1.spans == [hd(&1.spans)]))
    end
  end

  describe "malformed input renders sensibly and never raises" do
    test "a hard break ends the line" do
      lines = Markdown.render("text with two spaces  \nnext line")
      assert Enum.map(lines, &flatten/1) == ["text with two spaces", "next line"]
    end

    test "an empty heading is one empty line, not a crash" do
      assert [%Line{spans: []}] = Markdown.render("# ")
    end

    test "images have no inner text, so they render nothing — no crash" do
      assert texts("a ![alt](x.png) b") == ["a  b"]
      assert Markdown.render("<img src=\"x\">") == []
    end

    test "a styled link's href suffix is still appended after inline markup" do
      [line] = Markdown.render("[a **b**](https://x.y)")
      assert flatten(line) == "a b (https://x.y)"
    end

    test "a verbatim anchor without an href stays bare" do
      [line] = Markdown.render("<a name=\"n\">t</a>")
      assert flatten(line) == "t"
    end

    test "a verbatim pre keeps its text as a plain line" do
      assert texts("<pre>code here</pre>") == ["code here"]
    end

    test "unclosed emphasis, stray HTML, and lone asterisks" do
      lines =
        Markdown.render("unclosed **emphasis here\n\n<div>raw text</div>\n\nlone * stars * here")

      assert Enum.map(lines, &flatten/1) == [
               "unclosed **emphasis here",
               "raw text",
               "lone  stars  here"
             ]
    end

    test "verbatim HTML keeps its inner text plainly" do
      [line] = Markdown.render("<span class=\"x\">tagged <b>bold</b></span>")
      assert flatten(line) == "tagged <b>bold</b>"
    end

    test "garbage bytes, huge delimiter runs, and unknown tables do not raise" do
      for input <- [
            <<0xFF, 0xFE>>,
            "a\0b",
            String.duplicate("*", 5_000),
            String.duplicate("[", 2_000) <> "x",
            "| a | b |\n| - | - |\n| 1 | 2 |\n",
            "![](img.png)"
          ] do
        assert is_list(Markdown.render(input))
      end
    end

    test "non-binary input is empty, not a crash" do
      assert Markdown.render(nil) == []
    end
  end

  describe "empty input" do
    test "empty and whitespace-only text render no lines" do
      assert Markdown.render("") == []
      assert Markdown.render("   \n\t\n") == []
    end

    test "through the render seam the entry is just the blank separator" do
      for text <- ["", "   \n\t\n"] do
        assert [%Line{spans: [%{content: ""}]}] = Render.entry_lines(:assistant, text)
      end
    end
  end

  describe "through Render.entry_lines/2" do
    test "the blank separator leads, then the markdown body" do
      lines = Render.entry_lines(:assistant, "# Title\n\nBody **text**")

      assert Enum.map(lines, &flatten/1) == ["", "Title", "Body text"]
      assert [{"", _blank} | _rest] = styled(hd(lines))
    end

    test "headings and code keep their styling through the seam" do
      lines = Render.entry_lines(:assistant, "## Section\n\n```sh\nls -l\n```")

      assert Enum.map(lines, &flatten/1) == ["", "Section", "┈ sh", " ls -l "]
      assert {"Section", heading} = span(Enum.at(lines, 1), "Section")
      assert heading.modifiers == [:bold]

      assert {" ls -l ", code} = span(List.last(lines), " ls -l ")
      assert code.bg == {:indexed, 234}
    end
  end

  ## helpers

  defp texts(markdown) do
    markdown
    |> Markdown.render()
    |> Enum.map(&flatten/1)
  end

  defp styled(%Line{spans: spans}), do: Enum.map(spans, &{&1.content, &1.style})
  defp flatten(line), do: Enum.map_join(line.spans, "", & &1.content)

  defp span(%Line{spans: spans}, content) do
    case Enum.find(spans, &(&1.content == content)) do
      nil -> nil
      span -> {span.content, span.style}
    end
  end
end

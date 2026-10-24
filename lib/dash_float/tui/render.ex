defmodule DashFloat.TUI.Render do
  @moduledoc """
  The one pure seam between entry truth and the log view:
  `entry_lines/2` turns an entry's raw text into styled lines, and the
  tool-contract builders (`tool_call/2`, `tool_result/3`, `confirm_preview/1`)
  turn the ADR 0007 messages into `{text, lines}` entries — text is the plain
  persistence truth, lines the styled view. Every entry starts with one blank
  separator line. Assistant text goes through the markdown mapper; the seam
  itself stays these functions (ADR 0006).
  """

  alias DashFloat.TUI.Markdown
  alias DashFloat.TUI.Theme
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc "The display lines of one entry, blank separator first."
  @spec entry_lines(:user | :assistant | :tool | :system, String.t()) :: [Line.t()]
  def entry_lines(kind, text) do
    [blank() | body_lines(kind, text)]
  end

  ## Tool-contract builders (ADR 0007)

  @doc """
  Builds the `:tool` entry for a tool call: accent gear glyph, then the call
  and its argument summary dim. The summary is the path arg for file tools,
  the command for `execute_command`.
  """
  @spec tool_call(String.t(), map()) :: {String.t(), [Line.t()]}
  def tool_call(name, args) when is_binary(name) and is_map(args) do
    rest = name_with_summary(name, args_summary(args))
    {"⚙ " <> rest, [blank(), tool_row(rest)]}
  end

  @doc """
  Builds the `:tool` entry for a tool result: gear row with the engine-authored
  status, then the output indented two spaces, dim, verbatim (not markdown).
  """
  @spec tool_result(String.t(), String.t(), String.t() | nil) :: {String.t(), [Line.t()]}
  def tool_result(name, status, output)
      when is_binary(name) and is_binary(status) and is_binary(output) do
    rest = "#{name} → #{status}"
    {"⚙ " <> rest <> "\n" <> output, [blank(), tool_row(rest) | output_rows(output)]}
  end

  def tool_result(name, status, nil) when is_binary(name) and is_binary(status) do
    rest = "#{name} → #{status}"
    {"⚙ " <> rest, [blank(), tool_row(rest)]}
  end

  @doc """
  Builds the `:tool` entry for a confirmation preview: `"+ "` additions and
  `"$ "` command lines read as inline code, everything else (including `"@@ "`
  hunk headers and `"- "` deletions) dim.
  """
  @spec confirm_preview([String.t()]) :: {String.t(), [Line.t()]}
  def confirm_preview(lines) when is_list(lines) do
    {Enum.join(lines, "\n"), [blank() | Enum.map(lines, &preview_line/1)]}
  end

  defp tool_row(rest),
    do:
      Line.new([
        Span.new("⚙ ", style: Theme.style(:accent)),
        Span.new(rest, style: Theme.style(:dim))
      ])

  defp name_with_summary(name, ""), do: name
  defp name_with_summary(name, summary), do: name <> " " <> summary

  defp args_summary(args), do: Map.get(args, "path") || Map.get(args, "command") || ""

  defp output_rows(output) do
    output
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new("  " <> &1, style: Theme.style(:dim))]))
  end

  defp preview_line("+ " <> _added = line), do: styled_line(line, :inline_code)
  defp preview_line("$ " <> _command = line), do: styled_line(line, :inline_code)
  defp preview_line(line), do: styled_line(line, :dim)

  defp styled_line(line, role), do: Line.new([Span.new(line, style: Theme.style(role))])

  defp blank, do: Line.new([Span.new("")])

  # The user's own words echo dim, with a bold prompt glyph on the first line
  # and continuation lines indented under it.
  defp body_lines(:user, text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn
      {line, 1} ->
        Line.new([
          Span.new("❯ ", style: bold(Theme.style(:user))),
          Span.new(line, style: Theme.style(:user))
        ])

      {line, _index} ->
        Line.new([Span.new("  " <> line, style: Theme.style(:user))])
    end)
  end

  # Assistant output is markdown; the mapper owns every style in it.
  defp body_lines(:assistant, text), do: Markdown.render(text)

  defp body_lines(:tool, text), do: lines(text, Theme.style(:tool))
  defp body_lines(:system, text), do: lines(text, Theme.style(:dim_italic))

  defp lines(text, style) do
    text
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new(&1, style: style)]))
  end

  defp bold(%Style{} = style), do: %{style | modifiers: style.modifiers ++ [:bold]}
end

defmodule DashFloat.TUI.Render do
  @moduledoc """
  The one pure seam between entry truth and the log view:
  `entry_lines/2` turns an entry's raw text into styled lines. Every entry
  starts with one blank separator line. The markdown mapper replaces the
  `:assistant` path later (ADR 0006); the seam itself stays this function.
  """

  alias DashFloat.TUI.Theme
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @doc "The display lines of one entry, blank separator first."
  @spec entry_lines(:user | :assistant | :tool | :system, String.t()) :: [Line.t()]
  def entry_lines(kind, text) do
    [Line.new([Span.new("")]) | body_lines(kind, text)]
  end

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

  # Plain default-foreground lines; the markdown mapper takes over this path.
  defp body_lines(:assistant, text), do: lines(text, Theme.style(:assistant))

  defp body_lines(:tool, text), do: lines(text, Theme.style(:tool))
  defp body_lines(:system, text), do: lines(text, Theme.style(:dim_italic))

  defp lines(text, style) do
    text
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new(&1, style: style)]))
  end

  defp bold(%Style{} = style), do: %{style | modifiers: style.modifiers ++ [:bold]}
end

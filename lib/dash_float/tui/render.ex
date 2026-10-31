defmodule DashFloat.TUI.Render do
  @moduledoc """
  The one pure seam between entry truth and the log view:
  `entry_lines/2` turns an entry's raw text into styled lines, the
  tool-contract builders (`tool_call/2`, `tool_result/3`, `confirm_preview/1`)
  turn the ADR 0007 messages into `{text, lines}` entries, and the reasoning
  builders (issue #78) draw the thinking block's header, content, and
  position footer — text is the plain persistence truth, lines the styled
  view. Every entry starts with one blank separator line. Assistant text goes
  through the markdown mapper; the seam itself stays these functions
  (ADR 0006).
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
  the command for `execute_command`. `nil` args mean the streamed arguments
  never parsed — an error result follows (ADR 0007 §1) and must render, never
  crash the UI.
  """
  @spec tool_call(String.t(), map() | nil) :: {String.t(), [Line.t()]}
  def tool_call(name, args) when is_binary(name) and is_map(args) do
    rest = name_with_summary(name, args_summary(args))
    {"⚙ " <> rest, [blank(), tool_row(rest)]}
  end

  def tool_call(name, nil) when is_binary(name) do
    rest = name_with_summary(name, "(invalid arguments)")
    {"⚙ " <> rest, [blank(), tool_row(rest)]}
  end

  ## Reasoning block builders (issue #78)

  @doc """
  The thinking block's summary header line: accent `◔` glyph, then the dim
  label. `meta` carries the block's display stats — `tokens` (the delta
  count, live and finalized) and `ms` (the frozen first→last-delta duration,
  finalized only) each render independently; a replayed block carries
  neither (replay is pure — stats never survived resume). The suffix rides
  the expanded header as the interaction hint.
  """
  @spec reasoning_header_line(map(), String.t() | nil) :: Line.t()
  def reasoning_header_line(meta, suffix \\ nil) do
    tokens = stat_part(meta, :tokens, &"#{&1} tokens")
    duration = stat_part(meta, :ms, &duration_label(&1))
    label = "Thinking" <> tokens <> duration <> suffix_part(suffix)

    Line.new([
      Span.new("◔ ", style: Theme.style(:accent)),
      Span.new(label, style: Theme.style(:dim))
    ])
  end

  defp stat_part(meta, key, render) do
    case meta do
      %{^key => value} when is_integer(value) and value >= 0 -> " · " <> render.(value)
      _missing -> ""
    end
  end

  defp suffix_part(nil), do: ""
  defp suffix_part(suffix) when is_binary(suffix), do: " " <> suffix

  @doc """
  The thinking block's full content as logical lines: one dim `│ `-prefixed
  row per reasoning line — the blockquote vocabulary, so hanging indents and
  selection treat the block like quoted prose.
  """
  @spec reasoning_logical(String.t()) :: [Line.t()]
  def reasoning_logical(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      Line.new([
        Span.new("│ ", style: Theme.style(:dim)),
        Span.new(line, style: Theme.style(:quote))
      ])
    end)
  end

  @doc """
  The expanded block's position footer: dim `└ first–last/total` over the
  visible window of wrapped content rows.
  """
  @spec reasoning_footer_line(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: Line.t()
  def reasoning_footer_line(first, last, total) do
    Line.new([Span.new("└ #{first}–#{last}/#{total}", style: Theme.style(:dim))])
  end

  @doc """
  Seconds for the thinking header: one decimal with a trailing `.0` trimmed
  (the footer spans' rule) — `8.1s`, `2s`.
  """
  @spec duration_label(non_neg_integer()) :: String.t()
  def duration_label(ms) when is_integer(ms) and ms >= 0 do
    seconds = Float.round(ms / 1000, 1)

    seconds
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
    |> then(&(&1 <> "s"))
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

  # The user's own words ride the bold :user role; the first line's accent
  # ❯ ties them to the composer's accent ❯ title (ADR 0006, #107) — "your
  # input" reads as one system. Continuation lines indent under it.
  defp body_lines(:user, text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn
      {line, 1} ->
        Line.new([
          Span.new("❯ ", style: bold(Theme.style(:accent))),
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

defmodule DashFloat.TUI.Selection do
  @moduledoc """
  Selection geometry over rendered display rows (issue #28; ADR 0006
  amendment).

  A selection is an anchor and a head, each `{display_row, column}` in the
  same wrapped-display-line space the scroll math counts — content-anchored,
  so it survives scrolling and appends. Columns are display columns within
  the log region; a wide/emoji cluster is atomic (selected iff its *first*
  column is in range — never split). Copy is display-faithful: interior rows
  verbatim, edge rows by column range, rows joined with newlines. Highlight
  is reverse video over the covered columns, splitting boundary spans at
  cluster boundaries. OSC 52 carries the copy to the system clipboard on
  terminals that support it; the others ignore the sequence silently.
  """

  alias DashFloat.TUI.Wrap
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @type cell :: {row :: non_neg_integer(), col :: non_neg_integer()}
  @type t :: %{anchor: cell(), head: cell()}
  @type columns :: {from :: non_neg_integer(), to :: non_neg_integer() | nil} | nil

  ## Range geometry

  @doc """
  The ordered selection bounds `{from, to}` (row-major; tuple comparison is
  lexicographic, so `{1, 9} < {2, 0}`).
  """
  @spec range(t()) :: {cell(), cell()}
  def range(%{anchor: a, head: b}) when a <= b, do: {a, b}
  def range(%{anchor: a, head: b}), do: {b, a}

  @doc """
  The half-open column range `[from, to)` selected on absolute display row
  `row`; `to` nil means the whole row (interior rows), nil means the row is
  outside the selection.
  """
  @spec columns(t(), non_neg_integer()) :: columns()
  def columns(sel, row) do
    {{from_row, from_col}, {to_row, to_col}} = range(sel)

    cond do
      row < from_row or row > to_row -> nil
      from_row == to_row -> {from_col, to_col}
      row == from_row -> {from_col, nil}
      row == to_row -> {0, to_col}
      true -> {0, nil}
    end
  end

  @doc "True when absolute display row `row` intersects the selection."
  @spec covers_row?(t(), non_neg_integer()) :: boolean()
  def covers_row?(sel, row), do: columns(sel, row) != nil

  ## Copy

  @doc """
  The copied text for a selection over `rows`, the display rows starting at
  absolute row `first_row`: each row contributes its column-range slice
  (whole row for interior rows), rows join with `\\n`, and per-row trailing
  blanks trim. A selection of pure blank rows yields `""`.
  """
  @spec extract(t(), [Line.t()], non_neg_integer()) :: String.t()
  def extract(selection, rows, first_row) when is_list(rows) do
    rows
    |> Enum.with_index(fn row, i -> slice_text(row, columns(selection, first_row + i)) end)
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  @doc """
  The plain text of `line` between display columns `[from, to)` (`to` nil or
  the whole line: the row's text verbatim). A grapheme is included iff its
  first column is inside the range, so wide/emoji clusters are never split.
  """
  @spec slice_text(Line.t(), columns()) :: String.t()

  def slice_text(%Line{} = line, nil) do
    line
    |> plain()
    |> String.trim_trailing()
  end

  def slice_text(%Line{} = line, {from, to}) do
    {acc, _col} =
      Enum.reduce(line.spans, {[], 0}, fn span, {acc, col} ->
        walk_span(span.content, {acc, col}, from, to)
      end)

    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp walk_span(content, {acc, col}, from, to) do
    content
    |> sanitized()
    |> String.graphemes()
    |> Enum.reduce({acc, col}, fn grapheme, {acc, col} ->
      acc =
        if col >= from and (to == nil or col < to),
          do: [grapheme | acc],
          else: acc

      {acc, col + Wrap.width(grapheme)}
    end)
  end

  defp plain(%Line{} = line), do: Enum.map_join(line.spans, "", & &1.content)

  ## Highlight

  @doc """
  Rebuilds `line` with the columns `[from, to)` (nil `to`/whole row) in
  reverse video: covered pieces gain the `:reversed` modifier, boundary
  spans split at cluster boundaries — a wide cluster belongs to the side its
  first column falls on, so the highlight never halves a cell.
  """
  @spec highlight(Line.t(), columns()) :: Line.t()
  def highlight(%Line{} = line, nil), do: line

  def highlight(%Line{} = line, cols) do
    {rev_spans, _col} =
      Enum.reduce(line.spans, {[], 0}, fn span, {acc, col} ->
        {pieces, col} = split_span(span, col, cols)
        {Enum.reverse(pieces) ++ acc, col}
      end)

    spans =
      case Enum.reverse(rev_spans) do
        [] -> line.spans
        spans -> spans
      end

    %Line{line | spans: spans}
  end

  # Walks one span's graphemes from its starting display column, grouping
  # consecutive covered/uncovered runs — the column accumulator continues
  # across spans, so a range boundary lands at the same column the renderer
  # measures.
  defp split_span(%Span{content: ""}, col, _cols), do: {[], col}

  defp split_span(%Span{content: content, style: style}, start_col, {from, to}) do
    {runs, col} =
      content
      |> sanitized()
      |> String.graphemes()
      |> Enum.reduce({[], start_col}, fn grapheme, {runs, col} ->
        covered = col >= from and (to == nil or col < to)
        {append_run(runs, grapheme, covered), col + Wrap.width(grapheme)}
      end)

    spans =
      runs
      |> Enum.reverse()
      |> Enum.map(fn {text, covered} ->
        Span.new(text, style: if(covered, do: reversed(style), else: style))
      end)

    {spans, col}
  end

  defp append_run([{text, true} | rest], grapheme, true), do: [{text <> grapheme, true} | rest]
  defp append_run([{text, false} | rest], grapheme, false), do: [{text <> grapheme, false} | rest]
  defp append_run(runs, grapheme, covered), do: [{grapheme, covered} | runs]

  defp reversed(style), do: %{style | modifiers: Enum.uniq(style.modifiers ++ [:reversed])}

  ## OSC 52

  @doc """
  The OSC 52 clipboard-copy escape sequence for `text` (BEL-terminated,
  base64 payload). Terminals that support it — the SSH-friendly path — copy
  to the system clipboard; the rest ignore it: degradation is silence,
  never a crash or a block. The caller performs one bounded write
  (ADR 0006 amendment, issue #28).
  """
  @spec osc52(String.t()) :: binary()
  def osc52(text) when is_binary(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

  # Tool output can carry invalid UTF-8; sanitize exactly like the wrap
  # layer (U+FFFD) so slicing measures what rendering measures.
  defp sanitized(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end
end

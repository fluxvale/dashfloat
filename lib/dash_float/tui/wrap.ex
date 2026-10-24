defmodule DashFloat.TUI.Wrap do
  @moduledoc """
  Word-wrap for styled display lines: `wrap/2` folds each logical line into
  display lines no wider than the log region, `:word_or_glyph` semantics
  matching the input textarea — breaks at word boundaries, and at glyph
  boundaries only for runs too long for a row (URLs, hashes). Styles travel
  with the text: a wrapped piece keeps the style of the span it came from, a
  line that already fits is rebuilt chunk-for-chunk, and the line's own
  style/alignment ride along. Continuation rows re-carry the line's leading
  whitespace as an indent. Every input line yields at least one display line,
  so blank separators survive untouched.

  Width accounting matches the Rust renderer (`unicode-width`, measured
  against it): East Asian Wide/Fullwidth codepoints count two columns,
  combining marks and format characters zero, everything else one. Grapheme
  clusters that carry a variation selector (emoji presentation) or a ZWJ
  count two — the renderer's cluster width — never one. Divergence from the
  renderer's tables is only ever an OVER-count (wraps early); the #20
  regression tests pin buffer-level no-truncation for the sequence classes
  that motivated this. Wrap runs at append, tick, and resize time — never
  per frame (ADR 0006, amended).
  """

  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @run ~r/\s+|\S+/
  @vs16 "\u{FE0F}"
  @zwj "\u{200D}"
  # Emoji skin-tone modifiers: a cluster carrying one renders as an emoji
  # pair whatever its base (☝🏽 = 1+0 per codepoint, 2 cells in the
  # renderer). Standalone they sit in the wide table.
  @skin_tones for cp <- 0x1F3FB..0x1F3FF, do: <<cp::utf8>>
  @alphanumeric ~r/[\p{L}\p{N}]/u

  # Width 2 ranges: East Asian Width W and F codepoints, plus codepoints the
  # bundled renderer (unicode-width 0.2.2, Unicode 15.1/16 data) measures as
  # two cells even where EAW disagrees. Provenance: measured cell-by-cell
  # through the renderer's cell session during the #20 hostile review; the
  # deltas beyond stock EAW W/F are the Khmer/trigram/IDE entries and the
  # Unicode-16 emoji additions. Unknown codepoints default to one column —
  # an over-count can wrap early, never truncate. Sorted by lo; the binary
  # search in covers?/4 relies on it.
  @wide [
    {0x1100, 0x115F},
    {0x17A4, 0x17A4},
    {0x17D8, 0x17D8},
    {0x231A, 0x231B},
    {0x2329, 0x232A},
    {0x23E9, 0x23EC},
    {0x23F0, 0x23F0},
    {0x23F3, 0x23F3},
    {0x25FD, 0x25FE},
    {0x2614, 0x2615},
    {0x2630, 0x2637},
    {0x2648, 0x2653},
    {0x267F, 0x267F},
    {0x268A, 0x268F},
    {0x2693, 0x2693},
    {0x26A1, 0x26A1},
    {0x26AA, 0x26AB},
    {0x26BD, 0x26BE},
    {0x26C4, 0x26C5},
    {0x26CE, 0x26CE},
    {0x26D4, 0x26D4},
    {0x26EA, 0x26EA},
    {0x26F2, 0x26F3},
    {0x26F5, 0x26F5},
    {0x26FA, 0x26FA},
    {0x26FD, 0x26FD},
    {0x2705, 0x2705},
    {0x270A, 0x270B},
    {0x2728, 0x2728},
    {0x274C, 0x274C},
    {0x274E, 0x274E},
    {0x2753, 0x2755},
    {0x2757, 0x2757},
    {0x2795, 0x2797},
    {0x27B0, 0x27B0},
    {0x27BF, 0x27BF},
    {0x2B1B, 0x2B1C},
    {0x2B50, 0x2B50},
    {0x2B55, 0x2B55},
    {0x2E80, 0x2E99},
    {0x2E9B, 0x2EF3},
    {0x2F00, 0x2FD5},
    {0x2FF0, 0x2FFF},
    {0x3000, 0x3029},
    {0x302E, 0x303E},
    {0x3041, 0x3096},
    {0x309B, 0x30FF},
    {0x3105, 0x312F},
    {0x3131, 0x318E},
    {0x3190, 0x31E5},
    {0x31EF, 0x31EF},
    {0x31F0, 0x321E},
    {0x3220, 0x3247},
    {0x3250, 0x4DBF},
    {0x4E00, 0xA48C},
    {0xA490, 0xA4C6},
    {0xA960, 0xA97C},
    {0xAC00, 0xD7A3},
    {0xF900, 0xFAFF},
    {0xFE10, 0xFE19},
    {0xFE30, 0xFE52},
    {0xFE54, 0xFE66},
    {0xFE68, 0xFE6B},
    {0xFF01, 0xFF60},
    {0xFFE0, 0xFFE6},
    {0x16FE0, 0x16FE4},
    {0x16FF0, 0x16FF1},
    {0x17000, 0x187F7},
    {0x18800, 0x18CD5},
    {0x18D00, 0x18D08},
    {0x1AFF0, 0x1AFF3},
    {0x1AFF5, 0x1AFFB},
    {0x1AFFD, 0x1AFFE},
    {0x1B000, 0x1B122},
    {0x1B150, 0x1B152},
    {0x1B164, 0x1B167},
    {0x1B170, 0x1B2FB},
    {0x1F004, 0x1F004},
    {0x1F0CF, 0x1F0CF},
    {0x1F18E, 0x1F18E},
    {0x1F191, 0x1F19A},
    {0x1F200, 0x1F202},
    {0x1F210, 0x1F23B},
    {0x1F240, 0x1F248},
    {0x1F250, 0x1F251},
    {0x1F260, 0x1F265},
    {0x1F300, 0x1F320},
    {0x1F32D, 0x1F335},
    {0x1F337, 0x1F37C},
    {0x1F37E, 0x1F393},
    {0x1F3A0, 0x1F3CA},
    {0x1F3CF, 0x1F3D3},
    {0x1F3E0, 0x1F3F0},
    {0x1F3F4, 0x1F3F4},
    {0x1F3F8, 0x1F43E},
    {0x1F440, 0x1F440},
    {0x1F442, 0x1F4FC},
    {0x1F4FF, 0x1F53D},
    {0x1F54B, 0x1F54E},
    {0x1F550, 0x1F567},
    {0x1F57A, 0x1F57A},
    {0x1F595, 0x1F596},
    {0x1F5A4, 0x1F5A4},
    {0x1F5FB, 0x1F64F},
    {0x1F680, 0x1F6C5},
    {0x1F6CC, 0x1F6CC},
    {0x1F6D0, 0x1F6D2},
    {0x1F6D5, 0x1F6D8},
    {0x1F6DC, 0x1F6DF},
    {0x1F6EB, 0x1F6EC},
    {0x1F6F4, 0x1F6FC},
    {0x1F7E0, 0x1F7EB},
    {0x1F7F0, 0x1F7F0},
    {0x1F90C, 0x1F93A},
    {0x1F93C, 0x1F945},
    {0x1F947, 0x1F9FF},
    {0x1FA70, 0x1FA7C},
    {0x1FA80, 0x1FA8A},
    {0x1FA8E, 0x1FA8F},
    {0x1FA90, 0x1FABE},
    {0x1FABF, 0x1FAC6},
    {0x1FAC8, 0x1FAC8},
    {0x1FACD, 0x1FACD},
    {0x1FACE, 0x1FADF},
    {0x1FAE0, 0x1FAEA},
    {0x1FAEF, 0x1FAEF},
    {0x1FAF0, 0x1FAF8},
    {0x20000, 0x2FFFD},
    {0x30000, 0x3FFFD}
  ]

  # Zero-width codepoints: combining marks and format characters that render
  # into the previous cell, plus the emoji skin-tone modifiers (they only
  # appear inside an emoji cluster, where the cluster itself carries the
  # width). Pruned to what a log plausibly carries; any unknown mark
  # defaults to one column (an over-count wraps a column early — it can
  # never truncate). Sorted by lo; the binary search in covers?/4 relies on
  # it.
  @zero [
    {0x0300, 0x036F},
    {0x0483, 0x0489},
    {0x0591, 0x05BD},
    {0x05BF, 0x05BF},
    {0x05C1, 0x05C2},
    {0x05C4, 0x05C5},
    {0x05C7, 0x05C7},
    {0x0610, 0x061A},
    {0x064B, 0x065F},
    {0x0670, 0x0670},
    {0x06D6, 0x06DC},
    {0x06DF, 0x06E4},
    {0x06E7, 0x06E8},
    {0x06EA, 0x06ED},
    {0x0711, 0x0711},
    {0x0730, 0x074A},
    {0x07A6, 0x07B0},
    {0x07EB, 0x07F3},
    {0x0816, 0x0819},
    {0x081B, 0x0823},
    {0x0825, 0x0827},
    {0x0829, 0x082D},
    {0x0900, 0x0902},
    {0x093A, 0x093A},
    {0x093C, 0x093C},
    {0x0941, 0x0948},
    {0x094D, 0x094D},
    {0x0951, 0x0957},
    {0x0962, 0x0963},
    {0x0981, 0x0981},
    {0x09BC, 0x09BC},
    {0x09C1, 0x09C4},
    {0x09CD, 0x09CD},
    {0x0A01, 0x0A02},
    {0x0A3C, 0x0A3C},
    {0x0A41, 0x0A42},
    {0x0A47, 0x0A48},
    {0x0A4B, 0x0A4D},
    {0x0A51, 0x0A51},
    {0x0A70, 0x0A71},
    {0x0A75, 0x0A75},
    {0x0A81, 0x0A82},
    {0x0ABC, 0x0ABC},
    {0x0AC1, 0x0AC5},
    {0x0AC7, 0x0AC8},
    {0x0ACD, 0x0ACD},
    {0x0B01, 0x0B01},
    {0x0B3C, 0x0B3C},
    {0x0B3F, 0x0B3F},
    {0x0B41, 0x0B44},
    {0x0B4D, 0x0B4D},
    {0x0B82, 0x0B82},
    {0x0BC0, 0x0BC0},
    {0x0BCD, 0x0BCD},
    {0x0C00, 0x0C00},
    {0x0C3E, 0x0C40},
    {0x0C46, 0x0C48},
    {0x0C4A, 0x0C4D},
    {0x0C81, 0x0C81},
    {0x0CBC, 0x0CBC},
    {0x0CBF, 0x0CBF},
    {0x0CC6, 0x0CC6},
    {0x0CCC, 0x0CCD},
    {0x0D01, 0x0D01},
    {0x0D41, 0x0D44},
    {0x0D4D, 0x0D4D},
    {0x0DCA, 0x0DCA},
    {0x0E31, 0x0E31},
    {0x0E34, 0x0E3A},
    {0x0E47, 0x0E4E},
    {0x0EB1, 0x0EB1},
    {0x0EB4, 0x0EBC},
    {0x0EC8, 0x0ECD},
    {0x1160, 0x11FF},
    {0x135D, 0x135F},
    {0x1712, 0x1714},
    {0x1732, 0x1734},
    {0x1752, 0x1753},
    {0x1772, 0x1773},
    {0x17B4, 0x17B5},
    {0x17B7, 0x17BD},
    {0x17C6, 0x17C6},
    {0x17C9, 0x17D3},
    {0x180B, 0x180D},
    {0x180F, 0x180F},
    {0x1AB0, 0x1ACE},
    {0x1DC0, 0x1DFF},
    {0x200B, 0x200F},
    {0x202A, 0x202E},
    {0x2060, 0x2064},
    {0x2066, 0x206F},
    {0x20D0, 0x20F0},
    {0x2CEF, 0x2CF1},
    {0x302A, 0x302D},
    {0x3099, 0x309A},
    {0xA66F, 0xA672},
    {0xA674, 0xA67D},
    {0xA69E, 0xA69F},
    {0xA6F0, 0xA6F1},
    {0xFB1E, 0xFB1E},
    {0xFE00, 0xFE0F},
    {0xFE20, 0xFE2F},
    {0xFEFF, 0xFEFF},
    {0x1D167, 0x1D169},
    {0x1D173, 0x1D182},
    {0x1D185, 0x1D18B},
    {0x1D1AA, 0x1D1AD},
    {0xE0100, 0xE01EF}
  ]

  @wide_ranges List.to_tuple(@wide)
  @wide_count tuple_size(@wide_ranges)
  @zero_ranges List.to_tuple(@zero)
  @zero_count tuple_size(@zero_ranges)

  # The binary search in covers?/4 relies on both tables being sorted, and
  # cp_width/1 consults zero before wide, so a range overlapping across the
  # tables silently re-classifies wide codepoints as zero-width (the
  # skin-tone range, found in the #20 review). Both invariants are enforced
  # at compile time.
  Enum.each([@wide, @zero], fn ranges ->
    true =
      ranges
      |> Enum.zip(tl(ranges))
      |> Enum.all?(fn {a, b} -> a < b end)
  end)

  Enum.each(@zero, fn {zero_lo, zero_hi} ->
    true =
      Enum.all?(@wide, fn {wide_lo, wide_hi} ->
        zero_hi < wide_lo or wide_hi < zero_lo
      end)
  end)

  @doc false
  # Width tables for the renderer-agreement property test: every entry, and
  # the emoji-sequence families, must advance at least `width/1` columns in
  # the real renderer (the no-undercount invariant — undercounting is what
  # truncates rows at the pane edge).
  @spec __tables__ ::
          {[{non_neg_integer(), non_neg_integer()}],
           [
             {non_neg_integer(), non_neg_integer()}
           ]}
  def __tables__, do: {Enum.to_list(@wide), Enum.to_list(@zero)}

  @doc "Display width in terminal columns of a single-line string."
  @spec width(String.t()) :: non_neg_integer()
  def width(text) when is_binary(text) do
    text
    |> sanitized()
    |> sum_width(0)
  end

  defp sum_width(text, acc) do
    case String.next_grapheme(text) do
      nil -> acc
      {grapheme, rest} -> sum_width(rest, acc + cluster_width(grapheme))
    end
  end

  # A cluster carrying a variation selector (emoji presentation), a skin
  # tone, or joining pictographics with a ZWJ renders as one emoji cell pair
  # — the renderer's cluster width, which a per-codepoint sum would
  # undercount (⚠️ = 1+0, ☝🏽 = 1+0) or wildly overcount (family emoji =
  # 2+0+2+0+2). A bare ZWJ between plain letters adds nothing.
  defp cluster_width(<<cp::utf8>>) when cp < 0x0300, do: 1

  defp cluster_width(grapheme) do
    cond do
      String.contains?(grapheme, @vs16) -> 2
      String.contains?(grapheme, @skin_tones) -> 2
      joined_emoji?(grapheme) -> 2
      true -> cp_sum(grapheme)
    end
  end

  # A ZWJ sequence reads as one emoji pair when it is led by one (the emoji
  # planes); a ZWJ that merely follows a plain letter adds nothing.
  defp joined_emoji?(grapheme) do
    <<first::utf8, _rest::binary>> = grapheme
    first >= 0x1F000 and String.contains?(grapheme, @zwj)
  end

  defp cp_sum(grapheme) do
    for <<cp::utf8 <- grapheme>>, reduce: 0 do
      acc -> acc + cp_width(cp)
    end
  end

  # Invalid UTF-8 (raw tool output) becomes U+FFFD — the same treatment the
  # markdown mapper gives assistant text. Without it the width generator
  # stops at the first invalid byte and undercounts the row.
  defp sanitized(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  @doc """
  Wraps styled lines to `width` columns (a `width` below 1 wraps at one
  column). Blank lines and lines that fit pass through unchanged; the line's
  leading whitespace becomes the indent of its wrapped continuation rows.
  """
  @spec wrap([Line.t()], integer()) :: [Line.t()]
  def wrap(lines, width) when is_list(lines) and is_integer(width) do
    width = max(width, 1)
    Enum.flat_map(lines, &wrap_line(&1, width))
  end

  defp wrap_line(%Line{} = line, width) do
    chunks = Enum.flat_map(line.spans, &span_chunks/1)
    {prefix, body} = split_prefix(chunks)
    indent = chunks_width(prefix)

    cond do
      # A blank or prefix-only line that fits is untouched.
      body == [] and indent <= width ->
        [line]

      # No hanging indent to carry, or one wider than half the row (deep
      # nesting at a narrow terminal) — wrapping the body without it beats
      # guttering the text down to a column or two.
      indent == 0 or indent > div(width, 2) ->
        wrap_chunks(body, width, line)

      # The first row keeps its prefix verbatim; continuation rows hang by
      # the prefix's width, so wrapped bullets, quote bars, gear rows, and
      # user echoes stay visually under their opener.
      true ->
        hanging_wrap(body, prefix, indent, width, line)
    end
  end

  defp hanging_wrap(body, prefix, indent, width, line) do
    chunks = drop_kinds(prefix)
    reversed = Enum.reverse(chunks)
    prefix_line = display_line(reversed, line)
    spaces = String.duplicate(" ", indent)
    hang = Span.new(spaces)

    body
    |> wrap_chunks(width - indent, line)
    |> indent_rows(prefix_line.spans, hang)
  end

  defp indent_rows([%Line{} = first], prefix_spans, _hang),
    do: [%Line{first | spans: prefix_spans ++ first.spans}]

  defp indent_rows([%Line{} = first | rest], prefix_spans, hang) do
    first = %Line{first | spans: prefix_spans ++ first.spans}

    rest =
      Enum.map(rest, fn %Line{} = row -> %Line{row | spans: [hang | row.spans]} end)

    [first | rest]
  end

  # The prefix is the line's leading whitespace plus an optional marker run:
  # a short symbolic word chunk (bullet "•", quote bar "│", prompt "❯",
  # gear "⚙") followed by a single space. Prose never matches — a leading
  # word must be purely symbolic to count as a marker, so "the quick brown
  # fox" carries no hanging indent while "❯ anything" does.
  defp split_prefix(chunks) do
    {spaces, rest} = Enum.split_while(chunks, fn {_t, _s, kind} -> kind == :space end)

    case rest do
      [{text, style, :word}, {space, _space_style, :space} | tail] ->
        if marker?(text) and width(space) == 1 do
          {spaces ++ [{text, style, :word}, {space, style, :space}], tail}
        else
          {spaces, rest}
        end

      _other ->
        {spaces, rest}
    end
  end

  defp marker?(text), do: width(text) <= 4 and not Regex.match?(@alphanumeric, text)

  defp chunks_width(chunks),
    do: Enum.reduce(chunks, 0, fn {text, _s, _k}, acc -> acc + width(text) end)

  defp drop_kinds(chunks), do: Enum.map(chunks, fn {text, style, _kind} -> {text, style} end)

  defp wrap_chunks(chunks, width, line) do
    {rev, cur, _col, _continued} =
      Enum.reduce(chunks, {[], [], 0, false}, &step(&1, width, &2))

    # The final display line is always emitted: blank in, blank out.
    emit([cur | rev], line)
  end

  ## Filling

  # A whitespace run on a fresh continuation row is dropped (wrap points
  # never inherit leading spaces). A run that would overflow a full row is
  # dropped and the row marked full (col := width) — the run is gone, so the
  # next word must move to the next row rather than abut the last word on
  # this one. A run overflowing an EMPTY row is dropped outright: marking it
  # full would manufacture a phantom blank row.
  defp step({text, style, :space}, width, {rev, cur, col, continued}) do
    w = width(text)

    cond do
      col + w <= width -> {rev, [{text, style} | cur], col + w, continued}
      cur == [] -> {rev, cur, col, continued}
      col == 0 and continued -> {rev, cur, col, true}
      true -> {rev, cur, width, continued}
    end
  end

  # A word that fits the remaining columns is placed. A word that fits a row
  # of its own moves to the next row whole. A word wider than a row is split
  # at glyph boundaries via split_word/6 — one pass, no re-measuring of the
  # remainder.
  defp step({text, style, :word}, width, {rev, cur, col, continued}) do
    w = width(text)

    cond do
      col + w <= width ->
        {rev, [{text, style} | cur], col + w, continued}

      w <= width ->
        {[cur | rev], [{text, style}], w, true}

      true ->
        split_word(text, style, width, rev, cur, col)
    end
  end

  # Fill the row's remaining columns with the word's head, close the row,
  # then let fill_rows/4 lay the rest across fresh rows. An empty head means
  # the row was already full (the P1-2 space rule or an exact fill): close
  # it and move on.
  defp split_word(text, style, width, rev, cur, col) do
    {head, rest} = split_fit(text, width - col, false)
    cur = if head == "", do: cur, else: [{head, style} | cur]
    rev = if cur == [], do: rev, else: [cur | rev]
    fill_rows(rest, style, width, rev)
  end

  # Lay an over-long word across full-width rows. The first grapheme of a
  # fresh row is always taken (progress beats a perfect fit at width 1);
  # the tail lands on an open row so no phantom blank follows it.
  defp fill_rows(text, style, width, rev) do
    {head, rest} = split_fit(text, width, true)

    if rest == "" do
      {rev, [{head, style}], width(head), true}
    else
      fill_rows(rest, style, width, [[{head, style}] | rev])
    end
  end

  # Longest prefix (by display width, at grapheme boundaries) that fits
  # `budget` columns, and the rest. With force? the first grapheme is taken
  # even when it alone exceeds the budget; without it an unfitting first
  # grapheme yields an empty head so the caller can close the row first (a
  # wide grapheme never starts a row it would overflow at width >= 2).
  defp split_fit(text, budget, force?)
  defp split_fit(text, budget, _force?) when budget <= 0, do: {"", text}
  defp split_fit(text, budget, force?), do: take_fit(text, budget, [], 0, force?)

  defp take_fit(text, budget, acc, used, force?) do
    case String.next_grapheme(text) do
      nil ->
        {join(acc), ""}

      {grapheme, rest} ->
        gw = width(grapheme)

        if (force? and acc == []) or used + gw <= budget do
          take_fit(rest, budget, [grapheme | acc], used + gw, force?)
        else
          {join(acc), text}
        end
    end
  end

  defp join(graphemes) do
    graphemes
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  ## Chunks

  # A span's content becomes alternating whitespace / word runs, each
  # carrying the span's style through the wrap.
  defp span_chunks(%Span{content: content, style: style}) do
    content = sanitized(content)

    @run
    |> Regex.scan(content)
    |> Enum.map(fn [run] -> {run, style, run_kind(run)} end)
  end

  defp run_kind(run), do: if(String.trim(run) == "", do: :space, else: :word)

  ## Emitting

  defp emit(rev_display_lines, line) do
    rev_display_lines
    |> Enum.reverse()
    |> Enum.map(&display_line(&1, line))
  end

  defp display_line([], %Line{} = line), do: %Line{line | spans: [Span.new("")]}

  defp display_line(rev_chunks, %Line{} = line) do
    spans =
      rev_chunks
      |> Enum.reverse()
      |> merge_spans([])

    %Line{line | spans: spans}
  end

  defp merge_spans([], acc), do: Enum.reverse(acc)

  defp merge_spans([{text, style} | rest], acc),
    do: merge_spans(rest, append_span(text, style, acc))

  defp append_span(text, style, [%Span{content: content, style: style} = span | acc]),
    do: [%{span | content: content <> text} | acc]

  defp append_span(text, style, acc), do: [Span.new(text, style: style) | acc]

  ## Column accounting

  # Codepoints below U+0300 (ASCII, Latin-1, Latin Extended) never touch the
  # range tables: the common case is one comparison. U+17D8 (Khmer sign
  # BEYYAL) is the one codepoint the renderer advances three cells.
  defp cp_width(0x17D8), do: 3
  defp cp_width(cp) when cp < 0x0300, do: 1

  defp cp_width(cp) do
    cond do
      covers?(@zero_ranges, @zero_count, cp) -> 0
      covers?(@wide_ranges, @wide_count, cp) -> 2
      true -> 1
    end
  end

  # Binary search over a tuple of {lo, hi} ranges sorted by lo.
  defp covers?(ranges, size, cp), do: covers?(ranges, 0, size - 1, cp)

  defp covers?(_ranges, lo, hi, _cp) when lo > hi, do: false

  defp covers?(ranges, lo, hi, cp) do
    mid = div(lo + hi, 2)
    {range_lo, range_hi} = elem(ranges, mid)

    cond do
      cp < range_lo -> covers?(ranges, lo, mid - 1, cp)
      cp > range_hi -> covers?(ranges, mid + 1, hi, cp)
      true -> true
    end
  end
end

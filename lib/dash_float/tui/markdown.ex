defmodule DashFloat.TUI.Markdown do
  @moduledoc """
  Markdown -> styled `Line`s: the assistant row's render truth (ADR 0006).
  Pure and total — any input renders something sensible, nothing raises.
  The mapper works on `EarmarkParser.as_ast/1` tag tuples; no highlighter is
  ever involved (syntax highlighting is out of scope).
  """

  alias DashFloat.TUI.Theme
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span

  @bullets ["• ", "◦ ", "▪ "]
  @rule String.duplicate("─", 120)
  @block_tags ~w(h1 h2 h3 h4 h5 h6 p ul ol pre blockquote hr)

  @type token :: {String.t(), Style.t()} | :break
  @type prefix :: [{String.t(), atom() | nil}]
  @type ctx :: %{
          quotes: non_neg_integer(),
          indent: non_neg_integer(),
          depth: non_neg_integer(),
          style: atom() | nil
        }

  @doc "Renders markdown to display lines. Empty or whitespace input is `[]`."
  @spec render(term()) :: [Line.t()]
  def render(text) when is_binary(text) do
    text = if String.valid?(text), do: text, else: String.replace_invalid(text)

    if String.trim(text) == "", do: [], else: render_ast(text)
  end

  def render(_other), do: []

  # One rescue boundary for the whole render: drops the styled rendering but
  # still returns the text as lines (ADR 0006: total, never raises). Sanitized
  # input makes this unreachable in practice (fuzzed), hence the coverage skip.
  defp render_ast(text) do
    {_status, ast, _messages} = EarmarkParser.as_ast(text)
    blocks(ast, ctx())
  rescue
    # coveralls-ignore-next-line
    _error -> to_lines([{text, Theme.style(:assistant)}], [], Theme.style(:assistant))
  end

  defp ctx, do: %{quotes: 0, indent: 0, depth: 0, style: nil}

  ## Blocks

  defp blocks(nodes, ctx), do: Enum.flat_map(nodes, &block(&1, ctx))

  defp block({"h1", _attrs, children, _meta}, ctx),
    do: text_lines(children, %{ctx | style: :heading1})

  defp block({"h2", _attrs, children, _meta}, ctx),
    do: text_lines(children, %{ctx | style: :heading2})

  defp block({tag, _attrs, children, _meta}, ctx) when tag in ["h3", "h4", "h5", "h6"],
    do: text_lines(children, %{ctx | style: :heading3})

  defp block({"p", _attrs, children, _meta}, ctx), do: text_lines(children, ctx)

  defp block({"ul", _attrs, items, _meta}, ctx), do: list(items, ctx, :ul)

  defp block({"ol", attrs, items, _meta}, ctx),
    do: list(items, ctx, {:ol, ol_start(attrs)})

  defp block({"blockquote", _attrs, children, _meta}, ctx),
    do: blocks(children, %{ctx | quotes: ctx.quotes + 1, style: :quote})

  defp block({"hr", _attrs, _children, _meta}, ctx) do
    rule = [{@rule, Theme.style(:rule)}]
    to_lines(rule, prefix(ctx), base_style(ctx))
  end

  defp block({"pre", _attrs, children, _meta}, ctx), do: fence(children, ctx)

  defp block(text, ctx) when is_binary(text), do: text_lines([text], ctx)

  # Unknown markup and verbatim HTML: recurse; strings inside render as text.
  defp block({_tag, _attrs, children, _meta}, ctx), do: blocks(children, ctx)

  defp text_lines(children, ctx) do
    base = base_style(ctx)
    to_lines(inline(children, base), prefix(ctx), base)
  end

  # Each line's prefix is quote bars plus indentation; only the quote bar
  # carries its own role, the indent inherits the surrounding base style.
  defp prefix(%{quotes: quotes, indent: indent}) do
    List.duplicate({"│ ", :quote}, quotes) ++ spaces(indent)
  end

  defp spaces(0), do: []
  defp spaces(n), do: [{String.duplicate(" ", n), nil}]

  defp prefix_spans(prefix, base) do
    Enum.map(prefix, fn
      {text, nil} -> Span.new(text, style: base)
      {text, role} -> Span.new(text, style: Theme.style(role))
    end)
  end

  ## Lists

  defp list(items, ctx, kind) do
    indexed = Enum.with_index(items, start_of(kind))

    Enum.flat_map(indexed, fn {{"li", _attrs, children, _meta}, index} ->
      list_item(children, ctx, kind, index)
    end)
  end

  defp list_item(children, ctx, kind, index) do
    {lead, rest} = split_lead(children)
    base = base_style(ctx)
    marker = marker(kind, index, ctx.depth)
    first = prefix(ctx) ++ [{marker, nil}]

    head =
      if lead == [] and rest != [],
        do: [],
        else: to_lines(inline(lead, base), first, base)

    head ++ blocks(rest, %{ctx | indent: ctx.indent + 2, depth: ctx.depth + 1})
  end

  defp start_of({:ol, start}), do: start
  defp start_of(:ul), do: 0

  defp marker({:ol, _start}, index, _depth), do: "#{index}. "
  defp marker(:ul, _index, depth), do: Enum.at(@bullets, rem(depth, 3))

  defp split_lead([{"p", _attrs, children, _meta} | rest]), do: {children, rest}
  defp split_lead(children), do: Enum.split_while(children, &(not block?(&1)))

  defp block?({tag, _attrs, _children, _meta}) when is_binary(tag), do: tag in @block_tags
  defp block?(_other), do: false

  defp ol_start(attrs) do
    with {"start", value} <- List.keyfind(attrs, "start", 0),
         {start, _rest} <- Integer.parse(value) do
      start
    else
      _other -> 1
    end
  end

  ## Fenced code

  defp fence([{"code", attrs, content, _meta}], ctx) do
    base = base_style(ctx)
    line_prefix = prefix_spans(prefix(ctx), base)
    tag = code_lang(attrs)

    tag_line =
      if tag == nil,
        do: [],
        else: [Line.new(line_prefix ++ [Span.new("┈ #{tag}", style: Theme.style(:code_lang))])]

    tag_line ++ code_lines(content, line_prefix)
  end

  # A verbatim `<pre>` keeps its text as a plain string, not a code node.
  defp fence(children, ctx), do: blocks(children, ctx)

  defp code_lines(content, line_prefix) do
    content
    |> Enum.map_join(&plain/1)
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(fn line ->
      Line.new(line_prefix ++ [Span.new(" " <> line <> " ", style: Theme.style(:code))])
    end)
  end

  defp code_lang(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", class} ->
        [lang | _rest] = String.split(class)
        lang

      nil ->
        nil
    end
  end

  ## Inline

  defp inline(nodes, base) when is_list(nodes), do: Enum.flat_map(nodes, &inline(&1, base))
  defp inline(text, base) when is_binary(text), do: [{text, base}]

  defp inline({"strong", _attrs, children, _meta}, base),
    do: inline(children, merge(base, :emphasis_bold))

  defp inline({"em", _attrs, children, _meta}, base),
    do: inline(children, merge(base, :emphasis_italic))

  defp inline({"del", _attrs, children, _meta}, base),
    do: inline(children, merge(base, :strikethrough))

  defp inline({"code", _attrs, children, _meta}, base),
    do: inline(children, merge(base, :inline_code))

  defp inline({"br", _attrs, _children, _meta}, _base), do: [:break]

  defp inline({"a", attrs, children, _meta}, base) do
    text = inline(children, merge(base, :link))

    text ++ href_suffix(children, href(attrs), base)
  end

  defp inline({_tag, _attrs, children, _meta}, base), do: inline(children, base)

  # The href is shown dim only when it adds information.
  defp href_suffix(children, href, base) do
    if href in ["", plain(children)],
      do: [],
      else: [{" (#{href})", merge(base, :dim)}]
  end

  defp plain(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &plain/1)
  defp plain(text) when is_binary(text), do: text
  defp plain({_tag, _attrs, children, _meta}), do: plain(children)

  # An inline anchor always leads with its href (Earmark's AST convention);
  # an empty one adds nothing to the display.
  defp href([{"href", href} | _attrs]), do: href

  defp merge(base, role) do
    overlay = Theme.style(role)

    %Style{
      fg: overlay.fg || base.fg,
      bg: overlay.bg || base.bg,
      modifiers: Enum.uniq(base.modifiers ++ overlay.modifiers)
    }
  end

  defp base_style(%{style: nil}), do: Theme.style(:assistant)
  defp base_style(%{style: role}), do: Theme.style(role)

  ## Lines

  # Tokens carry newlines; every newline starts a new line, prefix first.
  defp to_lines([], prefix, base) do
    spans = prefix_spans(prefix, base)
    [Line.new(spans)]
  end

  defp to_lines(tokens, prefix, base) do
    spans = prefix_spans(prefix, base)

    tokens
    |> Enum.flat_map(&expand/1)
    |> Enum.chunk_while([], &chunk/2, &close/1)
    |> Enum.map(&Line.new(spans ++ &1))
  end

  defp expand(:break), do: [nil]

  defp expand({text, style}) do
    text
    |> String.split("\n")
    |> Enum.map(&if(&1 == "", do: nil, else: Span.new(&1, style: style)))
    |> Enum.intersperse(nil)
  end

  defp chunk(nil, acc), do: {:cont, Enum.reverse(acc), []}
  defp chunk(span, acc), do: {:cont, [span | acc]}
  defp close(acc), do: {:cont, Enum.reverse(acc), []}
end

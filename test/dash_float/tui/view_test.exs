defmodule DashFloat.TUI.ViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Render
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.View
  alias DashFloat.TUI.Wrap

  defp new_state(opts \\ []) do
    [test_mode: {80, 24}]
    |> Keyword.merge(opts)
    |> State.new()
  end

  describe "regions/3" do
    test "status 1 row, log the rest, no activity row when idle, input borders + draft" do
      %{status: status, log: log, activity: activity, input: input} =
        View.regions({80, 24}, 1, false)

      assert {status.height, log.height, activity.height, input.height} == {1, 20, 0, 3}
      assert status.y == 0 and log.y == 1 and activity.y == 21 and input.y == 21
      assert Enum.map([status, log, activity, input], & &1.width) == [80, 80, 80, 80]
    end

    test "an active phase claims one activity row between log and input" do
      %{log: log, activity: activity, input: input} = View.regions({80, 24}, 1, true)
      assert activity.height == 1
      assert log.height == 19
      assert activity.y == 20 and input.y == 21
    end

    test "the input grows with the draft" do
      %{log: log, activity: activity, input: input} = View.regions({80, 24}, 5, true)
      assert input.height == 7
      assert_region_sum({80, 24}, [log, activity, input])
    end

    test "the input never exceeds a third of the frame" do
      assert View.input_height(10, 12) == 4
      assert View.input_height(1, 6) == 3
    end

    test "degenerate frames collapse regions without raising" do
      %{status: status, log: log, activity: activity, input: input} =
        View.regions({1, 1}, 1, true)

      assert status.height == 0 and log.height == 0
      assert activity.height + input.height <= 1
    end

    defp assert_region_sum({_w, h}, regions) do
      heights = Enum.map(regions, & &1.height)
      assert Enum.sum(heights) <= h
    end
  end

  describe "render/2" do
    test "produces the four widgets" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 80, height: 24})

      assert [
               {%ExRatatui.Widgets.Paragraph{}, _status_rect},
               {%ExRatatui.Widgets.Paragraph{}, _log_rect},
               {%ExRatatui.Widgets.Paragraph{}, _activity_rect},
               {%ExRatatui.Widgets.Textarea{}, _input_rect}
             ] = widgets
    end

    test "status bar carries the cwd, model, and phase truth, omitting token fields" do
      text = status_text(new_state())

      assert text =~ "❯ ~/"
      assert text =~ "—"
      refute text =~ "ctx"
      refute text =~ "tok/s"
      assert text =~ "● Idle"
    end

    test "token fields appear only once something has streamed, in ADR order" do
      base = new_state(provider: provider(128_000))

      state =
        base
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_000)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 4_100}},
          1_500
        )
        |> State.stream_message({:phase, :idle}, 2_000)

      text = status_text(state)

      # The usage frame reconciles the count (2 deltas batched 5 tokens), so
      # the frozen rate uses the authoritative 5 tokens over the 1 s window.
      assert text =~ ~r/model · ctx 4\.1k\/128k · 5\.0 tok\/s · ● Idle · /
      assert text =~ "test-model"
    end

    test "the status bar is one line of styled spans, dim separators between" do
      [line] = status_line(new_state())
      assert length(line.spans) > 4

      separators = Enum.filter(line.spans, &(&1.content == " · "))
      assert separators != []
      assert Enum.all?(separators, &(&1.style.fg == :dark_gray))
    end

    test "the configured model replaces the placeholder" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "gpt-test", api_key: "k"}}
      text = status_text(new_state(provider: provider))
      assert text =~ "gpt-test"
    end

    test "each phase maps to its status label" do
      for {phase, label} <- [
            streaming: "Streaming",
            executing_tool: "Running tool",
            confirming: "Confirm",
            idle: "Idle"
          ] do
        state = %{new_state() | phase: phase}
        assert status_text(state) =~ label
      end
    end

    test "the rate shows only once one exists" do
      refute status_text(new_state()) =~ "tok/s"

      state =
        new_state()
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert status_text(state) =~ "2.0 tok/s"
    end

    test "the context label shows the accumulated usage" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 4_100}},
          1_000
        )
        |> State.stream_message({:phase, :idle}, 2_000)

      assert status_text(state) =~ "ctx 4.1k"
    end

    test "empty log shows a placeholder" do
      [line] = log_lines(new_state())
      assert flatten(line) =~ "(log is empty"
    end

    test "the first tokens are never announced as an empty log" do
      state =
        new_state()
        |> State.stream_message({:token, "hello"}, 1_000)
        |> Map.put(:phase, :streaming)

      # Before the first tick the lines are not rendered yet, but the log
      # must not claim to be empty.
      assert log_lines(state) == []
    end

    test "log entries render from their stored lines, separators included" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a system line"})
        |> State.stream_message({:token, "streaming "})
        |> State.stream_message({:token, "through"})
        |> Map.put(:phase, :streaming)

      {ticked, :cont} = State.tick(state, 1_000)

      lines = log_lines(ticked)
      assert Enum.map(lines, &flatten/1) == ["", "a system line", "", "streaming through"]
    end

    test "only the visible window is built — log text is bounded by the viewport" do
      state =
        Enum.reduce(1..100, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      widget = log_widget(state, 80, 24)
      lines = widget.text
      assert length(lines) == 20
      assert flatten(List.last(lines)) =~ "line 100"
      # the window is pre-scrolled; the paragraph itself does no scrolling
      assert widget.scroll == {0, 0}
    end

    test "a scrolled-up view windows onto its slice, not the tail" do
      state =
        Enum.reduce(1..100, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      {paged, nil} = State.handle_key(state, "page_up", [])
      widget = log_widget(paged, 80, 24)
      texts = Enum.map(widget.text, &flatten/1)
      refute Enum.any?(texts, &(&1 =~ "line 100"))
      assert Enum.any?(texts, &(&1 =~ "line 81"))
    end

    # The full markdown vocabulary wraps coherently: every display row fits
    # the width, nothing is lost, and blank separators keep the rhythm.
    test "markdown entries wrap coherently across the block vocabulary" do
      doc = """
      # A heading long enough to wrap at twenty columns
      Some paragraph with **bold** and *italic* and `code` inside it.
      - a list item that is fairly long
      - another item
      > a quoted line that also wraps when narrow
      ```
      fenced code with a long line inside the block
      ```
      """

      base = %{new_state(test_mode: {20, 24}) | phase: :streaming}

      state =
        base
        |> State.stream_message({:token, doc}, 1_000)
        |> then(fn s -> elem(State.tick(s, 1_100), 0) end)
        |> State.stream_message({:phase, :idle}, 1_200)

      [entry] = state.entries
      rows = Enum.map(entry.lines, &flatten/1)

      assert Enum.all?(rows, &(Wrap.width(&1) <= 20))

      # Every word of the source survives somewhere in the wrapped rows.
      joined = Enum.join(rows, " ")

      for word <- ~w(heading columns paragraph italic fenced inside) do
        assert joined =~ word
      end

      assert Enum.any?(rows, &(&1 =~ "• "))
      assert Enum.any?(rows, &(&1 =~ "│ "))
    end

    test "huge logs keep the widget text at viewport size" do
      state =
        Enum.reduce(1..10_000, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      widget = log_widget(state, 80, 24)
      assert length(widget.text) == 20
    end

    test "the status position never shows an inverted range on tiny frames" do
      state =
        Enum.reduce(1..30, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      {paged, nil} = State.handle_key(state, "page_up", [])
      # 80x4: status(1) + log(0) + activity(0) + input(3); log height 0
      text = status_text_at(paged, 80, 4)
      refute Regex.match?(~r/L(\d+)-(\d+)/, text)
      assert text =~ "/60"
    end

    test "user entries are prefixed and continuation lines indented" do
      state = State.stream_message(new_state(), {:entry, :system, "x"})
      with_user = %{state | entries: user_entry("line one\nline two")}

      [_sep, first, second] = log_lines(with_user)
      assert flatten(first) =~ "❯ line one"
      assert flatten(second) == "  line two"
    end

    test "system rows are dim italic" do
      state = State.stream_message(new_state(), {:entry, :system, "note"})
      [_sep, line] = log_lines(state)
      [span] = line.spans
      assert span.style.fg == :dark_gray
      assert :italic in span.style.modifiers
    end

    test "very long entries wrap instead of breaking rendering or losing text" do
      long = String.duplicate("x", 5_000)
      state = State.stream_message(new_state(), {:entry, :system, long})
      [entry] = state.entries

      # Blank separator + one 80-column row per 80 chars; the wrapped pieces
      # join back to exactly the input.
      assert length(entry.lines) == 1 + div(5_000, 80) + 1
      assert Enum.map_join(entry.lines, &flatten/1) == long

      # The windowed view agrees with the accounting: follow shows the last
      # 20 display rows — 19 full rows plus the 40-char tail, nothing else.
      visible = log_lines(state)
      assert length(visible) == 20
      assert Enum.map_join(visible, &flatten/1) == String.duplicate("x", 19 * 80 + 40)
    end

    test "a tiny frame renders without raising" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 1, height: 1})
      assert length(widgets) == 4
    end
  end

  describe "activity line" do
    test "is empty while idle" do
      {widget, _rect} = activity(new_state())
      assert widget.text == []
    end

    test "says Thinking… before any token" do
      text = activity_text(%{new_state() | phase: :streaming})
      assert text =~ "Thinking…"
      assert text =~ "esc interrupt"
    end

    test "says Streaming… once tokens arrived" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "hi"}, 1_000)

      assert activity_text(state) =~ "Streaming…"
    end

    test "says Running tool… while executing a tool" do
      assert activity_text(%{new_state() | phase: :executing_tool}) =~ "Running tool…"
    end

    test "says Approve this change? while confirming, with the decision hint" do
      state = %{new_state() | phase: :confirming}
      assert activity_text(state) =~ "Approve this change?"
      refute activity_text(state) =~ "esc interrupt"
    end

    test "steps through the braille spinner in anim_step order" do
      frames = Theme.spinner_frames()
      assert length(frames) == 10

      for step <- 0..9 do
        text = activity_text(%{new_state() | phase: :streaming, anim_step: step})
        assert String.starts_with?(text, Enum.at(frames, step))
      end

      # It wraps.
      assert activity_text(%{new_state() | phase: :streaming, anim_step: 10}) =~
               Enum.at(frames, 0)
    end

    test "spinner and label are accent; the interrupt hint is dim" do
      {widget, _rect} = activity(%{new_state() | phase: :streaming})
      [spinner, _space, label, hint] = hd(widget.text).spans

      assert spinner.style == Theme.style(:accent)
      assert label.style == Theme.style(:accent)
      assert label.content == "Thinking…"
      assert hint.content == "  esc interrupt"
      assert hint.style == Theme.style(:dim)
    end

    test "the confirming hint offers approve/reject instead of interrupt" do
      {widget, _rect} = activity(%{new_state() | phase: :confirming})
      [spinner, _space, label, hint] = hd(widget.text).spans

      assert spinner.style == Theme.style(:accent)
      assert label.content == "Approve this change?"
      assert label.style == Theme.style(:accent)
      assert hint.content == "  ⏎ approve · esc reject"
      assert hint.style == Theme.style(:dim)
    end

    test "the activity row has height zero while idle and one while active" do
      assert View.regions({80, 24}, 1, false).activity.height == 0
      assert View.regions({80, 24}, 1, true).activity.height == 1
    end
  end

  describe "tool entries (ADR 0007)" do
    test "a tool call row is an accent gear with a dim remainder" do
      {_text, [blank, line]} = Render.tool_call("read_file", %{"path" => "lib/foo.ex"})

      assert flatten(blank) == ""

      [gear, rest] = line.spans
      assert gear.content == "⚙ "
      assert gear.style == Theme.style(:accent)
      assert rest.content == "read_file lib/foo.ex"
      assert rest.style == Theme.style(:dim)
    end

    test "tool result output indents two spaces, dim, verbatim" do
      {_text, [_blank, first | output]} = Render.tool_result("read_file", "ok", "one\ntwo")

      assert [gear, rest] = first.spans
      assert gear.content == "⚙ "
      assert rest.content == "read_file → ok"

      assert Enum.map(output, &flatten/1) == ["  one", "  two"]
      assert Enum.map(output, &hd(&1.spans).style) == [dim(), dim()]
    end

    test "the confirm preview styles additions and commands as inline code, rest dim" do
      lines = ["@@ -1 +1 @@", "- gone", "+ new", "$ mix format", "plain"]
      {_text, [_blank | styled]} = Render.confirm_preview(lines)

      assert Enum.map(styled, &flatten/1) == lines
      assert Enum.map(styled, &hd(&1.spans).style) == [dim(), dim(), code(), code(), dim()]
    end

    test "tool entries flow into the log view from their stored lines" do
      state =
        new_state()
        |> State.stream_message(
          {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}}
        )
        |> State.stream_message(
          {:tool_result, %{id: "t1", name: "read_file", ok: true, status: "ok", output: "body"}}
        )

      texts =
        state
        |> log_lines()
        |> Enum.map(&flatten/1)

      assert texts == [
               "",
               "⚙ read_file lib/foo.ex",
               "",
               "⚙ read_file → ok",
               "  body"
             ]
    end
  end

  describe "render/2 against a test terminal buffer" do
    test "the full frame draws and lands in the buffer" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "hello log"})
        |> Map.put(:history, ["past"])

      term = ExRatatui.init_test_terminal(80, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      buffer = ExRatatui.get_buffer_content(term)
      assert buffer =~ "❯"
      assert buffer =~ "Idle"
      assert buffer =~ "hello log"
      assert buffer =~ "ask anything"
      assert buffer =~ "Enter send"
    end

    # Issue #20 repro: at a narrow width every word of a long entry must still
    # reach the buffer (wrapped onto following rows), not stop at the first
    # row's right edge.
    test "long log lines wrap to the terminal width instead of truncating" do
      base = new_state(test_mode: {20, 24})
      state = State.stream_message(base, {:entry, :system, fox_text()})

      term = ExRatatui.init_test_terminal(20, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 20, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      buffer = ExRatatui.get_buffer_content(term)

      for word <- ~w(quick brown fox jumps over lazy dog again) do
        assert buffer =~ word, "expected #{inspect(word)} to survive the wrap"
      end
    end

    # Regression (hostile review P1-1): emoji presentation sequences count
    # two cells in the renderer but one per codepoint in a naive sum — the
    # row "fit" and the Paragraph clipped the tail exactly as in issue #20.
    test "emoji presentation sequences wrap without truncating the tail" do
      text = String.duplicate("⚠️", 39) <> " CRITICAL_TAIL"

      state = State.stream_message(new_state(), {:entry, :system, text})

      term = ExRatatui.init_test_terminal(80, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      assert ExRatatui.get_buffer_content(term) =~ "CRITICAL_TAIL"
    end
  end

  describe "input box" do
    test "rounded dim border, an accent prompt title, dim placeholder, word-or-glyph wrap" do
      {widget, _rect} = input(new_state())
      assert widget.wrap_mode == :word_or_glyph

      assert widget.placeholder ==
               "ask anything — Enter send · Shift+Enter newline · Esc interrupt · Ctrl+Q quit"

      assert widget.placeholder_style == Theme.style(:dim)
      assert widget.block.border_type == :rounded
      assert widget.block.borders == [:all]
      assert widget.block.border_style == Theme.style(:dim)
      assert %ExRatatui.Text.Span{content: "❯ ", style: style} = widget.block.title
      assert style == Theme.style(:accent)
    end
  end

  ## helpers

  defp user_entry(text) do
    [%{kind: :user, text: text, lines: Render.entry_lines(:user, text)}]
  end

  defp dim, do: Theme.style(:dim)
  defp code, do: Theme.style(:inline_code)

  defp provider(context_tokens) do
    {:ok,
     %DashFloat.Config{
       base_url: "http://x",
       model: "test-model",
       api_key: "k",
       context_tokens: context_tokens
     }}
  end

  defp status_text(state), do: status_text_at(state, 80, 24)

  defp status_text_at(state, w, h) do
    [line] = status_line_at(state, w, h)
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp status_line(state), do: status_line_at(state, 80, 24)

  defp status_line_at(state, w, h) do
    widgets = View.render(state, %ExRatatui.Frame{width: w, height: h})
    {widget, _rect} = List.first(widgets)
    widget.text
  end

  defp activity(state) do
    state
    |> View.render(%ExRatatui.Frame{width: 80, height: 24})
    |> Enum.at(2)
  end

  defp activity_text(state) do
    {widget, _rect} = activity(state)
    Enum.map_join(widget.text, "", &flatten/1)
  end

  defp fox_text, do: "the quick brown fox jumps over the lazy dog again and again"

  defp input(state) do
    state
    |> View.render(%ExRatatui.Frame{width: 80, height: 24})
    |> Enum.at(3)
  end

  defp log_widget(state, w, h) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: w, height: h})
      |> Enum.at(1)

    widget
  end

  defp log_lines(state) do
    case log_widget(state, 80, 24).text do
      lines when is_list(lines) -> lines
    end
  end

  defp spans(%ExRatatui.Text.Line{spans: spans}), do: Enum.map(spans, & &1.content)

  defp flatten(line) do
    line
    |> spans()
    |> Enum.join()
  end
end

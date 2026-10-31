defmodule DashFloat.TUI.ViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Config.Onboarding
  alias DashFloat.TUI.Commands
  alias DashFloat.TUI.Palette
  alias DashFloat.TUI.Render
  alias DashFloat.TUI.Selection
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
    test "status 1 row, log the rest, no activity row when idle, input borders + draft, footer 1 row" do
      %{status: status, log: log, gap: gap, activity: activity, input: input, footer: footer} =
        View.regions({80, 24}, 1, false)

      assert {status.height, log.height, gap.height, activity.height, input.height, footer.height} ==
               {1, 13, 2, 0, 3, 1}

      assert status.y == 2 and log.y == 3 and activity.y == 18 and input.y == 18
      assert Enum.map([status, log, activity, input, footer], & &1.width) == [76, 76, 76, 76, 76]
      # Two cells of padding on every side (issues #28 and #108): nothing at
      # the edges.
      assert status.x == 2 and log.x == 2 and input.x == 2 and footer.x == 2
      # The breathing gap (issue #129): two blank rows between the
      # transcript's bottom and the composer cluster — the margin language's
      # own rhythm — with nothing rendered into them.
      assert gap.y == 16 and gap.y + gap.height == input.y
      # The footer sits directly under the input (ADR 0015 §2).
      assert input.y + input.height == 21 and footer.y == 21
      assert footer.y + footer.height == 22
    end

    test "an active phase claims one activity row between the gap and input" do
      %{log: log, gap: gap, activity: activity, input: input, footer: footer} =
        View.regions({80, 24}, 1, true)

      assert activity.height == 1
      assert log.height == 12
      # The gap sits between the transcript and the composer CLUSTER — the
      # activity row belongs to the cluster (it is the composer's own
      # status chrome), so it renders under the air, hugging the input.
      assert gap.y == 15 and activity.y == 17 and input.y == 18 and footer.y == 21
    end

    test "the input grows with the draft" do
      %{log: log, activity: activity, input: input, footer: footer} =
        View.regions({80, 24}, 5, true)

      # 7 requested, capped at a third of the inset area (20 rows → 6).
      assert input.height == 6
      assert_region_sum({80, 24}, [log, activity, input, footer])
    end

    test "the input never exceeds a third of the frame" do
      assert View.input_height(10, 12) == 4
      assert View.input_height(1, 6) == 3
    end

    # The air collapses before the chrome does (issue #129): the demand the
    # gap must yield to includes the activity row when one exists.
    test "the gap collapses first on degenerate frames, counting the activity row" do
      # Idle: status(1) + gap(2) + input(3) + footer(1) = 7 — at inset 7 the
      # gap holds and the log takes 0; at 6 the air goes.
      assert View.regions({80, 7 + 4}, 1, false).gap.height == 2
      assert View.regions({80, 6 + 4}, 1, false).gap.height == 0

      # With the activity row up the demand is 8: at inset 7 the air goes
      # (not to 1 — the collapse is whole), at 8 it holds.
      assert View.regions({80, 7 + 4}, 1, true).gap.height == 0
      assert View.regions({80, 8 + 4}, 1, true).gap.height == 2
    end

    test "degenerate frames collapse regions without raising" do
      %{status: status, log: log, activity: activity, input: input, footer: footer} =
        View.regions({1, 1}, 1, true)

      assert status.height == 0 and log.height == 0
      assert activity.height + input.height + footer.height <= 1
    end

    # Issues #28 + #108: the wrap width is the log rect's width — one seam,
    # so wrap, re-wrap, windowing, and selection can never disagree.
    test "content_width is the log rect width across odd and narrow frames" do
      for width <- [3, 4, 12, 25, 61, 78, 80, 81, 120] do
        %{log: log} = View.regions({width, 24}, 1, false)

        assert View.content_width(width) == max(width - 4, 1)
        assert log.width == max(width - 4, 0)
      end

      # Degenerate frames clamp to one column, never zero.
      assert View.content_width(2) == 1
      assert View.content_width(1) == 1
    end

    defp assert_region_sum({_w, h}, regions) do
      heights = Enum.map(regions, & &1.height)
      assert Enum.sum(heights) <= h
    end
  end

  describe "render/2" do
    test "produces the five widgets" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 80, height: 24})

      assert [
               {%ExRatatui.Widgets.Paragraph{}, _status_rect},
               {%ExRatatui.Widgets.Paragraph{}, _log_rect},
               {%ExRatatui.Widgets.Paragraph{}, _activity_rect},
               {%ExRatatui.Widgets.Textarea{}, _input_rect},
               {%ExRatatui.Widgets.Paragraph{}, _footer_rect}
             ] = widgets
    end

    test "status bar carries the phase and ctx truth; cwd, model, and rate moved to the footer" do
      text = status_text(new_state())

      refute text =~ "❯ ~/"
      refute text =~ "—"
      refute text =~ "ctx"
      refute text =~ "tok/s"
      assert text =~ "● Idle"
    end

    # Nothing has streamed and the phase cluster follows the mode span (the
    # mode is always the bar's first group, ADR 0016 §7): a fresh session
    # never opens with a dangling leading separator.
    test "a fresh session's status opens with the mode, no leading separator" do
      text = status_text(new_state())

      assert String.starts_with?(text, "Build · ● ")
      refute String.starts_with?(text, " · ")
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
        |> State.stream_message(
          {:context,
           %{messages: [%{role: "user", content: "ab"}], anchor: %{tokens: 4_100, index: 1}}},
          1_600
        )
        |> State.stream_message({:phase, :idle}, 2_000)

      # ctx left the bar in stage 2 (ADR 0015 §2 amendment): mode, phase,
      # position — the tokens truth lives in the footer's context span now.
      assert status_text(state) =~ ~r/Build · ● Idle · /
      refute status_text(state) =~ "ctx"
      assert footer_text(state) =~ ~r/4\.1k\/128k · 3\.2%/
    end

    test "the status bar is one line of styled spans, dim separators between" do
      [line] = status_line(new_state())

      # Exact fresh-session truth — the mode label, phase cluster, one
      # separator between each group, the log position: a wrong separator
      # layout must fail here, not pass on count (mode first, ADR 0016 §7).
      assert Enum.map(line.spans, & &1.content) == [
               "Build",
               " · ",
               "● ",
               "Idle",
               " · ",
               "log empty"
             ]

      separators = Enum.filter(line.spans, &(&1.content == " · "))
      assert Enum.all?(separators, &(&1.style.fg == :dark_gray))
    end

    test "the status bar always carries the mode span (ADR 0016)" do
      for {mode, label} <- [plan: "Plan", build: "Build", auto: "Auto", unchained: "Unchained"] do
        assert status_text(%{new_state() | mode: mode}) =~ label
      end
    end

    test "the unchained mode label is error-styled" do
      [line] = status_line(%{new_state() | mode: :unchained})

      assert %ExRatatui.Text.Span{style: style} =
               Enum.find(line.spans, &(&1.content == "Unchained"))

      assert style == Theme.style(:error)
    end

    test "each phase maps to its status label" do
      for {phase, label} <- [
            streaming: "Streaming",
            executing_tool: "Running tool",
            checking: "Checking",
            confirming: "Confirm",
            asking: "Asking",
            idle: "Idle"
          ] do
        state = %{new_state() | phase: phase}
        assert status_text(state) =~ label
      end
    end

    test "a pending question's activity row names the wait and Esc's dismissal" do
      state = asking_state()
      assert activity_text(state) =~ "Waiting for your answer…"
      assert activity_text(state) =~ "esc dismiss"
    end

    # The composer replacement (ADR 0028): while a choice is pending the
    # input region carries a Paragraph (the question box), never the
    # Textarea — and its rows carry the question, the options with their
    # selection markers, and the hint.
    test "a pending choice replaces the composer widget with the question box" do
      state = asking_state()

      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})

      assert [
               {%ExRatatui.Widgets.Paragraph{}, _status},
               {%ExRatatui.Widgets.Paragraph{}, _log},
               {%ExRatatui.Widgets.Paragraph{}, _activity},
               {%ExRatatui.Widgets.Paragraph{}, _input},
               {%ExRatatui.Widgets.Paragraph{}, _footer}
             ] = widgets

      # The choice's clamp is the area minus status/footer/activity/one
      # log row (hostile review P0-1: the options are the payload) — the
      # 7-row question box gets its full 9 rows at the stock geometry.
      assert State.input_line_count(state) == 7
      regions = regions_of(state)
      assert {:ok, input} = Map.fetch(regions, :input)
      assert input.height == 9

      text = input_text(state)
      assert text =~ "Which database?"
      assert text =~ "❯ Postgres"
      assert text =~ "  SQLite"
      assert text =~ "    sturdy default"
      assert text =~ "↑↓ move · ⏎ answer · esc dismiss"
    end

    # P0-1's regression proof at the DRAWN CELLS: at the stock 80x24 a
    # 10-option question WITH descriptions (24 rows) overflows even the
    # widened clamp — the box must SCROLL with the selection, so the
    # last option is visible (and answerable with eyes open) when
    # selected, and the first is honestly scrolled away.
    test "an overflowing choice scrolls to keep the selected option visible" do
      alias ExRatatui.CellSession

      options = for i <- 1..10, do: %{"label" => "option-#{i}", "description" => "d#{i}"}

      armed =
        State.stream_message(new_state(), {
          :question,
          make_ref(),
          %{question: "Pick one", options: options, multiple: false}
        })

      moved =
        Enum.reduce(1..9, armed, fn _i, state ->
          {state, _nil} = State.handle_key(state, "down", [])
          state
        end)

      assert moved.choice.selected == 9

      session = CellSession.new(80, 24)

      :ok =
        CellSession.draw(session, View.render(moved, %ExRatatui.Frame{width: 80, height: 24}))

      snap = CellSession.take_cells(session)
      CellSession.close(session)
      text = Enum.map_join(snap.cells, "", & &1.symbol)

      assert text =~ "option-10"
      refute text =~ "option-1 "
    end

    # The plain 10-option list (14 rows) fits the widened clamp whole at
    # the stock geometry — every option and the hint visible, no scroll.
    test "a 10-option question without descriptions fits whole" do
      alias ExRatatui.CellSession

      options = for i <- 1..10, do: %{"label" => "option-#{i}"}

      armed =
        State.stream_message(new_state(), {
          :question,
          make_ref(),
          %{question: "Pick one", options: options, multiple: false}
        })

      session = CellSession.new(80, 24)

      :ok =
        CellSession.draw(session, View.render(armed, %ExRatatui.Frame{width: 80, height: 24}))

      snap = CellSession.take_cells(session)
      CellSession.close(session)
      text = Enum.map_join(snap.cells, "", & &1.symbol)

      for i <- 1..10, do: assert(text =~ "option-#{i}")
      assert text =~ "esc dismiss"
    end

    test "an approval renders its fixed two-choice set in the same box" do
      ref = make_ref()

      state =
        State.stream_message(
          new_state(),
          {:confirm, ref, %{id: "c1", name: "write_file", args: %{}, lines: ["+ x"]}}
        )

      text = input_text(state)
      assert text =~ "Approve write_file?"
      assert text =~ "❯ Approve"
      assert text =~ "  Reject"
      assert text =~ "↑↓ move · ⏎ answer · esc reject"
    end

    test "a multi question shows checkboxes and the toggle hint" do
      state =
        State.stream_message(new_state(), {
          :question,
          make_ref(),
          %{
            question: "Pick any",
            options: [%{"label" => "a"}, %{"label" => "b"}],
            multiple: true
          }
        })

      text = input_text(state)
      assert text =~ "[ ] a"
      assert text =~ "[ ] b"
      assert text =~ "space toggle"
    end

    # The mouse-selection geometry during a choice (delta re-review #2):
    # cell_at must map through the choice-aware log rect — a click below
    # the (taller) box anchors on the REAL last log row, never on phantom
    # rows the draft's third-cap layout would invent.
    test "mouse selection maps through the choice-aware log rect" do
      options = for i <- 1..10, do: %{"label" => "option-#{i}", "description" => "d"}

      entries_state =
        new_state()
        |> State.stream_message({:entry, :system, "row"})
        |> then(fn s ->
          for _n <- 1..30, reduce: s do
            acc -> State.stream_message(acc, {:entry, :system, "row"})
          end
        end)

      armed =
        State.stream_message(entries_state, {
          :question,
          make_ref(),
          %{question: "Pick one", options: options, multiple: false}
        })

      # The giant choice claims the whole area: the log rect collapses to
      # zero rows, so a click over the box selects NOTHING — the honest
      # mapping through the choice-aware rect (no phantom rows).
      %{log: log} =
        View.regions(armed.size, State.input_line_count(armed), State.overlay?(armed), true)

      assert log.height == 0
      {clicked, _copy} = State.select_mouse(armed, "down", 10, 22, [])
      assert clicked.selection == nil

      # A SMALLER choice leaves the log visible: clicks anchor inside the
      # real (shrunken) rect — never past it.
      small =
        State.stream_message(entries_state, {
          :question,
          make_ref(),
          %{
            question: "Pick one",
            options: [%{"label" => "a"}, %{"label" => "b"}],
            multiple: false
          }
        })

      %{log: small_log} =
        View.regions(small.size, State.input_line_count(small), State.overlay?(small), true)

      assert small_log.height > 0

      # Clicks over the box (and past it) CLAMP to the log rect's bottom
      # edge — the same content row for both — never inventing phantom
      # rows under the taller box.
      {clicked_small, _copy} = State.select_mouse(small, "down", 10, 22, [])
      {clicked_below, _copy2} = State.select_mouse(small, "down", 10, 23, [])

      {{_from, _fx}, {to_row, _tx}} = Selection.range(clicked_small.selection)
      {{_from2, _fx2}, {to_row2, _tx2}} = Selection.range(clicked_below.selection)
      assert to_row == to_row2
      # The anchor sits at the clamp edge: the viewport's last content row.
      assert to_row == State.log_line_count(small) - 1
    end

    # interior < 3 (degenerate frames, delta re-review #2's P3): at 80x10
    # the clamp floors at 3 rows (interior 1) — the scroll must still aim
    # AT the selection, keeping it on the one visible row.
    test "the scroll never aims past the selection on degenerate interiors" do
      alias ExRatatui.CellSession

      options = for i <- 1..10, do: %{"label" => "option-#{i}", "description" => "d"}

      armed =
        State.stream_message(new_state(), {
          :question,
          make_ref(),
          %{question: "Pick one", options: options, multiple: false}
        })

      moved =
        Enum.reduce(1..9, armed, fn _i, state ->
          {state, _nil} = State.handle_key(state, "down", [])
          state
        end)

      assert moved.choice.selected == 9

      session = CellSession.new(80, 10)

      :ok =
        CellSession.draw(
          session,
          View.render(moved, %ExRatatui.Frame{width: 80, height: 10})
        )

      snap = CellSession.take_cells(session)
      CellSession.close(session)
      text = Enum.map_join(snap.cells, "", & &1.symbol)

      assert text =~ "option-10"
      refute text =~ "option-1 "
    end

    defp asking_state do
      State.stream_message(new_state(), {
        :question,
        make_ref(),
        %{
          question: "Which database?",
          options: [
            %{"label" => "Postgres", "description" => "sturdy default"},
            %{"label" => "SQLite"}
          ],
          multiple: false
        }
      })
    end

    defp regions_of(state) do
      View.regions(
        state.size,
        State.input_line_count(state),
        State.overlay?(state),
        state.choice != nil
      )
    end

    test "the context span reads the accounting call over the agent's snapshot" do
      snapshot =
        {:context,
         %{messages: [%{role: "user", content: String.duplicate("a", 16_400)}], anchor: nil}}

      base = new_state(provider: provider(128_000))
      state = State.stream_message(base, snapshot, 1_000)

      assert footer_text(state) =~ ~r/4\.1k\/128k · 3\.2%/

      # Hidden pre-first-turn: no snapshot, no span (the rate-span pattern).
      refute footer_text(new_state()) =~ "128k"
    end

    test "empty log shows a placeholder" do
      [line] = log_lines(new_state())
      assert flatten(line) =~ "(log is empty"
    end

    test "the first tokens are never announced as an empty log" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "hello"}, 1_000)

      # Before the first tick the lines are not rendered yet, but the log
      # must not claim to be empty.
      assert log_lines(state) == []
    end

    test "log entries render from their stored lines, separators included" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a system line"})
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "streaming "})
        |> State.stream_message({:token, "through"})

      {ticked, :cont} = State.tick(state, 1_000)

      lines = log_lines(ticked)
      assert Enum.map(lines, &flatten/1) == ["", "a system line", "", "streaming through"]
    end

    # The live reasoning block (issue #78) renders between the stored
    # entries and the in-flight reply, its tail window auto-following.
    test "the live reasoning block renders between the entries and the reply" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a system line"})
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:reasoning, "thought one"}, 1_000)
        |> State.stream_message({:reasoning, "thought two"}, 1_100)
        |> State.stream_message({:token, "the reply"}, 1_200)

      {ticked, :cont} = State.tick(state, 1_300)

      # Deltas join into the block's text; line breaks are the model's own.
      rows =
        ticked
        |> log_lines()
        |> Enum.map(&flatten/1)

      assert rows == [
               "",
               "a system line",
               "",
               "◔ Thinking · 2 tokens",
               "│ thought onethought two",
               "",
               "the reply"
             ]
    end

    test "only the visible window is built — log text is bounded by the viewport" do
      state =
        Enum.reduce(1..100, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      widget = log_widget(state, 80, 24)
      lines = widget.text
      assert length(lines) == 13
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
      assert Enum.any?(texts, &(&1 =~ "line 91"))
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

      assert Enum.all?(rows, &(Wrap.width(&1) <= 18))

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
      assert length(widget.text) == 13
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

      # Blank separator + one 76-column row per 76 chars (the padded width,
      # issue #28); the wrapped pieces join back to exactly the input.
      assert length(entry.lines) == 1 + div(5_000, 76) + 1
      assert Enum.map_join(entry.lines, &flatten/1) == long

      # The windowed view agrees with the accounting: follow shows the last
      # 13 display rows — 12 full rows plus the 60-char tail, nothing else
      # (the gap shrank the viewport by two, issue #129).
      visible = log_lines(state)
      assert length(visible) == 13
      assert Enum.map_join(visible, &flatten/1) == String.duplicate("x", 12 * 76 + 60)
    end

    test "a tiny frame renders without raising" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 1, height: 1})
      assert length(widgets) == 5
    end

    # Issue #28: a selection highlights its covered rows in reverse video —
    # interior rows whole, edge rows by column range; untouched rows pass
    # through unchanged.
    test "a selection reverse-highlights exactly its covered rows" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "first row"})
        |> State.stream_message({:entry, :system, "second row"})
        |> Map.put(:selection, %{anchor: {1, 3}, head: {3, 6}})

      {widget, _rect} =
        state
        |> View.render(%ExRatatui.Frame{width: 80, height: 24})
        |> Enum.at(1)

      [row0, row1, row2, row3 | _rest] = widget.text

      # Row 0 is outside the selection.
      assert Enum.map_join(row0.spans, "", & &1.content) == ""
      assert Enum.all?(row0.spans, &(:reversed not in &1.style.modifiers))

      # Row 1 (first row): from column 3 to the end.
      assert [{"fir", false}, {"st row", true}] =
               Enum.map(row1.spans, &{&1.content, :reversed in &1.style.modifiers})

      # Row 2 (interior) is the blank separator: it has no cells to
      # reverse, so it passes through — the highlight reads from the rows
      # around it.
      assert Enum.map_join(row2.spans, "", & &1.content) == ""
      assert Enum.all?(row2.spans, &(:reversed not in &1.style.modifiers))

      # Row 3 (last row): through column 6's cell ("second " — the
      # pointed cell is included; review P2a).
      assert [{"second ", true}, {"row", false}] =
               Enum.map(row3.spans, &{&1.content, :reversed in &1.style.modifiers})
    end

    test "an interior text row highlights whole" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "alpha"})
        |> State.stream_message({:entry, :system, "beta"})
        |> State.stream_message({:entry, :system, "gamma"})
        |> Map.put(:selection, %{anchor: {1, 0}, head: {5, 2}})

      {widget, _rect} =
        state
        |> View.render(%ExRatatui.Frame{width: 80, height: 24})
        |> Enum.at(1)

      # Row 3 ("beta", interior) is reversed whole.
      row3 = Enum.at(widget.text, 3)
      assert Enum.map_join(row3.spans, "", & &1.content) == "beta"
      assert Enum.all?(row3.spans, &(:reversed in &1.style.modifiers))
    end

    # Review cosmetic: a collapsed selection (press, not yet a drag)
    # highlights nothing — one reversed cell under the pointer would read
    # as a cursor artifact.
    test "a collapsed selection highlights nothing" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "alpha"})
        |> Map.put(:selection, %{anchor: {1, 0}, head: {1, 0}})

      {widget, _rect} =
        state
        |> View.render(%ExRatatui.Frame{width: 80, height: 24})
        |> Enum.at(1)

      Enum.with_index(widget.text, fn row, i ->
        refute Enum.any?(row.spans, &(:reversed in &1.style.modifiers)), "row #{i} reversed"
      end)
    end
  end

  # The stats footer under the composer (ADR 0015 §2): the cwd, model, and
  # rate assertions moved here off the status bar — moved, not duplicated.
  describe "stats footer" do
    test "carries the cwd and the model placeholder, no rate before anything streamed" do
      text = footer_text(new_state())

      assert text =~ "❯ ~/"
      assert text =~ "—"
      refute text =~ "tok/s"
    end

    test "one line with the old status-bar span vocabulary: dim cwd, assistant model, dim separators" do
      [line] = footer_line(new_state())
      assert length(line.spans) >= 3

      [cwd, sep, model | _rest] = line.spans
      assert String.starts_with?(cwd.content, "❯ ~/")
      assert cwd.style == Theme.style(:dim)
      assert sep.content == " · "
      assert sep.style == Theme.style(:hint)
      assert model.content == "—"
      assert model.style == Theme.style(:assistant)
    end

    test "the configured model replaces the placeholder" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "gpt-test", api_key: "k"}}
      assert footer_text(new_state(provider: provider)) =~ "gpt-test"
    end

    test "the label names provider and model; the profile suffix is gone (issue #109)" do
      provider =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4",
           model: "glm-5.3",
           api_key: "k",
           nickname: "Sol",
           profile: "work"
         }}

      assert footer_text(new_state(provider: provider)) =~ "zai - Sol"
      refute footer_text(new_state(provider: provider)) =~ "(work)"
    end

    # The width discipline (ADR 0015's #130 amendment): the stats pair may
    # never clip, so the optional groups drop from the left in reverse
    # urgency — cwd, then context, then ttft; the glyph, the model label,
    # and the rate are never dropped. Rung by rung, against the footer
    # rect's real width.
    test "the drop ladder yields cwd, then context, then ttft — never the rate" do
      # A PINNED cwd label (the state stores the FORMATTED label — State.new
      # runs format_cwd): the ladder's arithmetic must not depend on where
      # the suite happens to check out (32 display cells).
      base = new_state(provider: provider(128_000))

      full =
        base
        |> Map.put(:cwd, "~/FluxVale/dashfloat-129-surface")
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_400)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message(
          {:context,
           %{messages: [%{role: "user", content: "ab"}], anchor: %{tokens: 4_100, index: 1}}}
        )
        |> Map.put(:stats, %{
          new_state().stats
          | sent_at: 0,
            ttft_ms: 1_400,
            rate: 32.0,
            tokens: 0,
            first_token_at: nil,
            last_token_at: nil
        })

      # Everything fits at a wide footer (rect = frame − 4; the full row
      # is 93 cells).
      all = footer_text(full, 100)
      assert all =~ "~/FluxVale" and all =~ "4.1k/128k · 3.2%" and all =~ "ttft 1.4s · 32 tok/s"

      # 80 cols: the cwd yields, the context and the pair stay.
      at_80 = footer_text(full, 80)
      refute at_80 =~ "~/FluxVale"
      assert at_80 =~ "x - test-model · 4.1k/128k · 3.2% · ttft 1.4s · 32 tok/s"

      # Narrower: the context snapshot yields too, ttft + rate stay.
      at_52 = footer_text(full, 52)
      refute at_52 =~ "~/FluxVale"
      refute at_52 =~ "4.1k/128k"
      assert at_52 =~ "x - test-model · ttft 1.4s · 32 tok/s"

      # Narrower still: ttft yields, the rate NEVER does.
      at_36 = footer_text(full, 36)
      refute at_36 =~ "ttft"
      assert at_36 =~ "x - test-model · 32 tok/s"

      # Degenerate: even alone, the rate is the last candidate standing.
      assert footer_text(full, 22) =~ "32 tok/s"
    end

    # The 📎 glyph is two display cells (ADR 0018 §1): a boundary-fit
    # candidate must count it wide — String.length would undercount by one
    # and ship a clipped rate (hostile review F3).
    test "the ladder counts the 📎 glyph at two cells" do
      capable =
        {:ok, %DashFloat.Config{base_url: "http://x", model: "glm", api_key: "k", images: true}}

      capable_state = new_state(provider: capable)
      state = Map.put(capable_state, :cwd, "~/FluxVale/dashfloat-129-surface")

      # The full row is 47 display cells: ❯-head(34) + "x - glm"(7) +
      # " 📎"(3 — the glyph's two cells plus its space). At rect 47 the cwd
      # survives; at 46 it must already be gone — the one-cell difference
      # is exactly the glyph's second cell, which String.length would have
      # undercounted and shipped clipped. (The pinned cwd label is the
      # FORMATTED one — 32 cells.)
      assert footer_text(state, 51) =~ "~/FluxVale"
      assert footer_text(state, 51) =~ "x - glm 📎"
      refute footer_text(state, 50) =~ "~/FluxVale"
      assert footer_text(state, 50) =~ "❯ · x - glm 📎"
    end

    # The width math never raises on hostile input (delta review N2): an
    # invalid-UTF-8 byte in the cwd — legal in an OS path on Linux — is
    # counted plain, and the footer still renders.
    test "an invalid-UTF-8 cwd renders without raising" do
      state = Map.put(new_state(), :cwd, <<0xFF>>)
      assert footer_text(state, 80) =~ "❯"
      assert footer_text(state, 80) =~ "—"
    end

    # The capability glyph (ADR 0018 §1): visible before any attach attempt.
    test "shows 📎 beside the label only for an image-capable provider" do
      capable =
        {:ok, %DashFloat.Config{base_url: "http://x", model: "glm", api_key: "k", images: true}}

      assert footer_text(new_state(provider: capable)) =~ " 📎"
      refute footer_text(new_state(provider: provider(nil))) =~ "📎"
    end

    test "the rate shows only once one exists — frozen, never live" do
      refute footer_text(new_state()) =~ "tok/s"

      # While streaming there is NO tok/s at all (issue #130's refinement:
      # the live number misrepresents — "it tends to speed up by the end").
      streaming =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)

      refute footer_text(streaming) =~ "tok/s"

      # Frozen at finalize: 2 tokens over the 0 s decode window (both at
      # t=1000) is no rate at all — never a division by zero.
      zero_window =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)

      refute footer_text(zero_window) =~ "tok/s"

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)

      # 2 tokens ÷ 0.5 s decode window = 4.0 tok/s; a trailing ".0" trims
      # (the percent span's rule, issue #130's exact format).
      assert footer_text(state) =~ "4 tok/s"
    end

    test "ttft shows from the turn's first token and persists after the turn" do
      # Before any token: no span.
      refute footer_text(new_state()) =~ "ttft"

      # A turn sent at t=0, first token at t=1_400: ttft is known while
      # still streaming — alone, with no tok/s beside it.
      streaming =
        new_state()
        |> Map.put(:stats, %{new_state().stats | sent_at: 0})
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_400)

      assert footer_text(streaming) =~ "ttft 1.4s"
      refute footer_text(streaming) =~ "tok/s"

      # After the turn ends both spans persist, ttft first (the issue's
      # exact format): `ttft 1.4s · 32 tok/s` — 96 tokens over the 3 s
      # decode window (1_400 → 4_400).
      state =
        new_state()
        |> Map.put(:stats, %{new_state().stats | sent_at: 0})
        |> Map.put(:phase, :streaming)
        |> then(fn s ->
          Enum.reduce(1..96, s, fn i, acc ->
            State.stream_message(acc, {:token, "t#{i}"}, 1_400 + div((i - 1) * 3_000, 95))
          end)
        end)
        |> State.stream_message({:phase, :idle}, 5_000)

      assert footer_text(state) =~ "ttft 1.4s · 32 tok/s"
    end

    test "the usage-reconciled frozen rate follows the model, in ADR order" do
      base = new_state(provider: provider(128_000))

      state =
        base
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 4_100}},
          1_500
        )
        |> State.stream_message({:phase, :idle}, 2_000)

      # The usage frame reconciles the count (2 deltas batched 5 tokens), so
      # the frozen rate uses the authoritative 5 tokens over the 0.5 s
      # decode window = 10 tok/s.
      assert footer_text(state) =~ ~r/test-model · 10 tok\/s/
    end

    # The stage-2 span (ADR 0015 §2 amendment): tokens-used and
    # percent-of-context from Accounting.usage/3 over the agent snapshot.
    test "the context span sits between the model and the rate, dim, hidden until a snapshot exists" do
      snapshot =
        {:context,
         %{messages: [%{role: "user", content: String.duplicate("a", 16_400)}], anchor: nil}}

      base = new_state(provider: provider(128_000))

      state =
        base
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message(snapshot, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)

      [line] = footer_line(state)
      [_cwd, _sep, model, sep, ctx | _rest] = line.spans
      assert model.content == "x - test-model"
      assert sep.content == " · "
      assert ctx.content == "4.1k/128k · 3.2%"
      assert ctx.style == Theme.style(:dim)
    end

    test "no display window means the absolute total alone (ADR 0022 §2)" do
      snapshot =
        {:context,
         %{messages: [%{role: "user", content: String.duplicate("a", 16_400)}], anchor: nil}}

      base = new_state()
      state = State.stream_message(base, snapshot, 1_000)

      assert footer_text(state) =~ "4.1k"
      refute footer_text(state) =~ "4.1k/"
      refute footer_text(state) =~ "· 3"
    end

    test "an assumed denominator carries the ~ marker — the visible note (issue #111)" do
      snapshot =
        {:context,
         %{messages: [%{role: "user", content: String.duplicate("a", 16_400)}], anchor: nil}}

      # A resolved provider whose model no source knows: 128k assumed.
      assumed =
        {:ok,
         %DashFloat.Config{
           base_url: "https://api.z.ai/api/coding/paas/v4",
           model: "glm-4.5",
           api_key: "k"
         }}

      assumed_state = new_state(provider: assumed)
      state = State.stream_message(assumed_state, snapshot, 1_000)

      [line] = footer_line(state)
      ctx = List.last(line.spans)
      assert ctx.content == "4.1k/~131.1k · 3.1%"
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

    test "says Checking… while a safety check is in flight (ADR 0016 §8)" do
      assert activity_text(%{new_state() | phase: :checking}) =~ "Checking…"
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

    # The attach prompt (ADR 0018 §5) claims the transient row while open:
    # accent label, the draft with the composer's block cursor, and the dim
    # key hints — all on the one line WHEN THEY ALL FIT. The draft owns the
    # row (§4's "fix the path and retry" UX): once it no longer fits beside
    # the hints, the hints drop and the draft's TAIL fills the freed space
    # — the path being edited stays readable, `…` marks the clipped head.
    test "the attach prompt replaces the idle row with label, draft, cursor, and hints" do
      # At the default 80 cols the draft owns the row and the hints drop
      # (below); a frame wide enough to fit everything shows the full prompt.
      state = %{new_state(test_mode: {84, 24}) | attach: %{draft: "c.png"}}

      text = activity_text(state, 84)
      assert text =~ "Attach image: c.png█"
      assert text =~ "⏎ attach · tab complete · esc keep · ^o close · ^d clear"
    end

    test "at 80 cols a draft that leaves no room for the hints drops them" do
      state = %{new_state() | attach: %{draft: "c.png"}}

      text = activity_text(state)
      assert text =~ "Attach image: c.png█"
      refute text =~ "tab complete"
    end

    test "a wide attach draft drops the hints and tail-shows into the row" do
      long = String.duplicate("p", 80) <> ".png"
      state = %{new_state() | attach: %{draft: long}}

      line = activity_text(state)
      # the whole prompt fits the content width — the draft is cut, not wrapped
      assert String.length(line) <= 76
      refute line =~ long
      assert line =~ "Attach image: "
      # the hints yielded, the tail survived, the head is a marked clip
      refute line =~ "tab complete"
      assert line =~ "…"
      assert line =~ ".png█"
    end

    # Issue #28: the armed exit-guard prompt claims the transient row —
    # even while idle — and outranks the streaming/confirm activity text.
    test "the exit-guard prompt shows while armed, even at idle" do
      state = %{new_state() | exit_guard_at: 1_000}
      {widget, rect} = activity(state)

      assert rect.height == 1
      assert activity_text(state) == "Press Ctrl+C again to exit"

      [span] = hd(widget.text).spans
      assert span.style == Theme.style(:status_tool)
    end

    test "the guard prompt outranks streaming and confirm text while armed" do
      for phase <- [:streaming, :confirming] do
        state = %{new_state() | phase: phase, exit_guard_at: 1_000}
        text = activity_text(state)
        assert text == "Press Ctrl+C again to exit"
      end
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

    # The question tool's row (#134, ADR 0028): the question IS the payload —
    # one flattened line, capped with `…` when it runs long.
    test "a question call row carries the question as its summary" do
      {_text, [_blank, line]} = Render.tool_call("question", args("Which database?"))

      [gear, rest] = line.spans
      assert gear.content == "⚙ "
      assert rest.content == "question Which database?"

      long = String.duplicate("w", 80)
      {_text, [_blank, long_line]} = Render.tool_call("question", args(long <> "\nnext"))

      [^gear, long_rest] = long_line.spans
      assert long_rest.content == "question " <> String.duplicate("w", 60) <> "…"
    end

    test "a question call with no question string renders bare, never crashes" do
      {_text, [_blank, line]} = Render.tool_call("question", %{})

      [_gear, rest] = line.spans
      assert rest.content == "question"
    end

    defp args(question), do: %{"question" => question, "options" => [%{"label" => "a"}]}

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

  describe "the setup screens (ADR 0009)" do
    test "the forced-selection modal renders the names and the chosen one" do
      state = new_state(setup: {:select, ["work", "personal"], 1})
      frame = %ExRatatui.Frame{width: 80, height: 24}

      assert [{%ExRatatui.Widgets.Paragraph{}, _rect}] = View.render(state, frame)

      term = ExRatatui.init_test_terminal(80, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      buffer = ExRatatui.get_buffer_content(term)
      assert buffer =~ "select a profile"
      assert buffer =~ "work"
      assert buffer =~ "personal"
    end

    test "every wizard step renders its screen (nothing raises, copy is present)" do
      steps = [
        {%Onboarding{step: :welcome}, "Welcome to DashFloat."},
        {%Onboarding{step: :profile_name, draft: "personal"}, "Name your first profile"},
        {%Onboarding{step: :provider}, "Add a provider."},
        {%Onboarding{step: :custom_url, draft: "https://x"}, "OpenAI-compatible"},
        {%Onboarding{step: :label, draft: "zai"}, "Label this provider"},
        {%Onboarding{step: :key, draft: "k"}, "API key"},
        {%Onboarding{step: :fetching}, "Fetching"},
        {%Onboarding{step: :model_pick, fetched: [%{model: "m-a"}, %{model: "m-b"}], choice: 1},
         "m-b"},
        {%Onboarding{step: :model_manual, draft: "glm"}, "model id"},
        {%Onboarding{
           step: :model_manual,
           draft: "glm",
           note: "Couldn't fetch the model list — HTTP 500."
         }, "Couldn't fetch"},
        {%Onboarding{step: :loop}, "Anything else?"},
        {%Onboarding{step: :mcp_name, draft: "fetch"}, "MCP server name"},
        {%Onboarding{step: :mcp_command, draft: "uvx"}, "MCP command"},
        {%Onboarding{step: :mcp_args, draft: "a b"}, "MCP arguments"},
        {%Onboarding{step: :mcp_token, draft: "T"}, "Token environment variable"},
        {%Onboarding{step: :done}, "All set"}
      ]

      for {wizard, expected} <- steps do
        term = ExRatatui.init_test_terminal(80, 24)
        frame = %ExRatatui.Frame{width: 80, height: 24}
        state = new_state(setup: wizard)
        widgets = View.render(state, frame)
        assert :ok = ExRatatui.draw(term, widgets)
        buffer = ExRatatui.get_buffer_content(term)
        assert buffer =~ expected
      end
    end

    test "a refused write renders the error and remedy on the wizard surface (issue #39)" do
      # Key step: the refusal replaces the write-promise hint with the retry
      # wording, and the draft stays masked.
      key_state =
        new_state(
          setup: %Onboarding{
            step: :key,
            draft: "PLACEHOLDER-secret\\key",
            error:
              "keys.json5 cannot store that key — it contains a backslash or both quote kinds; " <>
                "re-enter it without the character, or store a $ENV_VAR reference instead"
          }
        )

      key_buffer = drawn_text(key_state)
      assert key_buffer =~ "cannot store that key"
      assert key_buffer =~ "$ENV_VAR"
      assert key_buffer =~ "retries the write"
      refute key_buffer =~ "immediately"
      refute key_buffer =~ "PLACEHOLDER"

      # Loop step: the remedy rides above the options with the retry hint;
      # the done screen's copy is nowhere.
      loop_state =
        new_state(
          setup: %Onboarding{
            step: :loop,
            error:
              "settings.json5 already exists and is not empty — rename it aside " <>
                "(mv settings.json5 settings.json5.old) and re-run setup to write a fresh one"
          }
        )

      loop_buffer = drawn_text(loop_state)
      assert loop_buffer =~ "not empty"
      assert loop_buffer =~ "retries the write"
      assert loop_buffer =~ "write the config and start"
      refute loop_buffer =~ "All set"
    end

    test "the manual-fallback note renders dim between title and input, never as an error (issue #64)" do
      state =
        new_state(
          setup: %Onboarding{
            step: :model_manual,
            draft: "glm",
            note: "Couldn't fetch the model list — HTTP 500."
          }
        )

      buffer = drawn_text(state)

      assert buffer =~ "The model id."
      assert buffer =~ "Couldn't fetch the model list — HTTP 500."
      assert buffer =~ "empty skips"
      assert buffer =~ "❯ glm█"

      # Dim, not error: the note is informational (the error style would
      # make it a refusal).
      [{%ExRatatui.Widgets.Paragraph{text: lines}, _rect}] =
        View.render(state, %ExRatatui.Frame{width: 80, height: 24})

      error = Theme.style(:error)
      dim = Theme.style(:dim)

      note_rows =
        for %ExRatatui.Text.Line{spans: [%ExRatatui.Text.Span{content: content, style: style}]} <-
              lines,
            style == dim and content =~ "Couldn't fetch",
            do: content

      assert note_rows != []

      refute Enum.any?(lines, fn %ExRatatui.Text.Line{spans: spans} ->
               Enum.any?(spans, fn %ExRatatui.Text.Span{content: content, style: style} ->
                 style == error and content =~ "Couldn't fetch"
               end)
             end)
    end

    test "a remedy longer than the row wraps at glyph boundaries — never silently clipped (issue #42)" do
      # Width 40: the box's inner width is 36, and the mv remedy's paths are
      # longer than a row. The wrapper must fall back to glyph boundaries so
      # every character lands on screen (ADR 0009's never-clipped remedy).
      message =
        "settings.json5 already exists and is not empty — rename it aside " <>
          "(mv /tmp/very/long/path/to/settings.json5 /tmp/very/long/path/to/settings.json5.old) and re-run setup to write a fresh one"

      state = new_state(setup: %Onboarding{step: :loop, error: message})
      rows = error_rows(state, 40)

      assert rows != []
      Enum.each(rows, fn row -> assert Wrap.width(row) <= 36 end)

      # No character lost, none invented: rows joined without the wrap's
      # dropped spaces re-form the message.
      assert Enum.map_join(rows, &String.replace(&1, " ", "")) ==
               String.replace(message, " ", "")

      # Drawn buffer at 40 columns: the .old tail is readable on screen —
      # the glyph fallback breaks mid-path, never drops the tail.
      term = ExRatatui.init_test_terminal(40, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 40, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)
      buffer = ExRatatui.get_buffer_content(term)
      assert buffer =~ "old) and re-run setup"
      assert buffer =~ "fresh one"
    end

    test "a single-token remedy starts on the first row — no leading blank line (issue #42)" do
      # The old wrapper emitted a spurious blank first line when one word
      # exceeded the width (wrap_words("oneword", 1) → ["", "oneword"]).
      message = String.duplicate("x", 50)
      state = new_state(setup: %Onboarding{step: :key, draft: "k", error: message})

      rows = error_rows(state, 40)
      assert hd(rows) != ""
      assert Enum.map_join(rows, &String.replace(&1, " ", "")) == message

      # Drawn buffer at 40 columns: all 50 characters reach the screen.
      term = ExRatatui.init_test_terminal(40, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 40, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)
      buffer = ExRatatui.get_buffer_content(term)

      x_count =
        buffer
        |> String.graphemes()
        |> Enum.count(&(&1 == "x"))

      assert x_count == 50, "lost characters to clipping"
    end

    test "the wizard renders its steps, masking secret inputs" do
      wizard = %DashFloat.Config.Onboarding{step: :welcome}

      state = new_state(setup: wizard)
      frame = %ExRatatui.Frame{width: 80, height: 24}
      assert [{%ExRatatui.Widgets.Paragraph{}, _rect}] = View.render(state, frame)

      key_step = %DashFloat.Config.Onboarding{
        step: :key,
        draft: "PLACEHOLDER-secret-key",
        profile_name: "personal"
      }

      term = ExRatatui.init_test_terminal(80, 24)
      key_state = new_state(setup: key_step)
      key_frame = %ExRatatui.Frame{width: 80, height: 24}
      widgets = View.render(key_state, key_frame)
      assert :ok = ExRatatui.draw(term, widgets)

      # The draft is masked: the value itself never reaches the screen.
      buffer = ExRatatui.get_buffer_content(term)
      assert buffer =~ "❯ "
      refute buffer =~ "PLACEHOLDER-secret-key"
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
      # Mid-session (#91): the session is underway (a system entry), so an
      # empty composer shows NO placeholder — and the instruction tail is
      # gone everywhere (the key map lives in /help).
      refute buffer =~ "ask anything"
      refute buffer =~ "Enter send"
    end

    test "a fresh session shows the short hint, and never the instruction tail" do
      term = ExRatatui.init_test_terminal(80, 24)
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 80, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      buffer = ExRatatui.get_buffer_content(term)
      assert buffer =~ "ask anything"
      refute buffer =~ "Enter send"
      refute buffer =~ "Shift+Enter"
      refute buffer =~ "Ctrl+Q"
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

    # Issues #28 + #108: the margin takes four columns off the wrap width —
    # at odd frame widths (61 → 57 content columns, 81 → 77) the wrap math
    # must use the padded width consistently. No truncation at the pane edge.
    test "padded wrap width holds at odd and narrow frame widths" do
      for {frame_w, expected} <- [{19, 15}, {20, 16}, {61, 57}, {81, 77}] do
        base = new_state(test_mode: {frame_w, 24})
        state = State.stream_message(base, {:entry, :system, fox_text()})

        assert_entry_width(state, expected)

        term = ExRatatui.init_test_terminal(frame_w, 24)
        widgets = View.render(state, %ExRatatui.Frame{width: frame_w, height: 24})
        assert :ok = ExRatatui.draw(term, widgets)

        buffer = ExRatatui.get_buffer_content(term)

        for word <- ~w(quick brown fox jumps over lazy dog again) do
          assert buffer =~ word, "width #{frame_w}: expected #{inspect(word)} to survive"
        end

        # The unbreakable run must survive whole: if the wrap math used any
        # width wider than the rect, the Paragraph would clip each row's
        # tail and the buffer would come up short of Z's. (Z appears nowhere
        # else in the chrome — "w" collides with "brown"/"newline".)
        run_base = new_state(test_mode: {frame_w, 24})

        run =
          State.stream_message(run_base, {:entry, :system, String.duplicate("Z", expected * 3)})

        assert_entry_width(run, expected)

        zterm = ExRatatui.init_test_terminal(frame_w, 24)
        zwidgets = View.render(run, %ExRatatui.Frame{width: frame_w, height: 24})
        assert :ok = ExRatatui.draw(zterm, zwidgets)

        zbuffer = ExRatatui.get_buffer_content(zterm)

        z_count =
          zbuffer
          |> String.graphemes()
          |> Enum.count(&(&1 == "Z"))

        assert z_count == expected * 3, "width #{frame_w}: lost graphemes to clipping"
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

    # Regression (review N1): skin-tone sequences on non-wide bases (☝🏽 ✍🏽)
    # counted 1 per codepoint pair after the modifiers moved to the zero
    # table; the renderer gives them two cells, so rows overflowed and the
    # tail clipped. The cluster rule plus the renderer-agreement property
    # test pin the class.
    test "skin-tone emoji sequences wrap without truncating the tail" do
      text = String.duplicate("☝🏽", 40) <> " TAIL_C"

      state = State.stream_message(new_state(), {:entry, :system, text})

      term = ExRatatui.init_test_terminal(80, 24)
      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert :ok = ExRatatui.draw(term, widgets)

      assert ExRatatui.get_buffer_content(term) =~ "TAIL_C"
    end
  end

  describe "input box" do
    test "rounded dim border, an accent prompt title, dim placeholder, word-or-glyph wrap" do
      {widget, _rect} = input(new_state())
      assert widget.wrap_mode == :word_or_glyph

      # The hint is short and neutral — the key map lives in /help (#91).
      assert widget.placeholder == "ask anything"
      assert widget.placeholder_style == Theme.style(:dim)
      assert widget.block.border_type == :rounded
      assert widget.block.borders == [:all]
      assert widget.block.border_style == Theme.style(:dim)
      assert %ExRatatui.Text.Span{content: "❯ ", style: style} = widget.block.title
      assert style == Theme.style(:accent)
    end

    # The placeholder rule (#91, owner-set): the ghost keeps precedence
    # wherever the session stands; otherwise the hint shows ONLY until the
    # session's first entry — then an empty composer shows nothing at all.
    test "placeholder: the ghost wins, the hint waits for an empty session, else nothing" do
      # A command's output makes the session underway (ADR 0015 amendment)
      # — as does the first prompt or a resume note.
      underway = State.stream_message(new_state(), {:entry, :system, "hello log"})

      assert placeholder(input(new_state())) == "ask anything"
      assert placeholder(input(underway)) == nil

      ghosted = %{underway | suggestion: "what happened next?"}
      assert placeholder(input(ghosted)) == "what happened next?"

      fresh_ghost = %{new_state() | suggestion: "try asking about elixir"}
      assert placeholder(input(fresh_ghost)) == "try asking about elixir"
    end

    # The attachment chips (ADR 0018's 2026-10-31 amendment): the title
    # carries one numbered chip per pending attachment, in queue order.
    test "the title shows numbered [Image #n] chips only while attachments are pending" do
      assert input_title(new_state()).content == "❯ "

      one = %{new_state() | attachments: [%{path: "p", name: "a.png", kb: 1}]}
      assert input_title(one).content == "❯ [Image #1]"

      two = %{one | attachments: one.attachments ++ [%{path: "q", name: "b.jpg", kb: 2}]}
      assert input_title(two).content == "❯ [Image #1] [Image #2]"
    end

    defp input_title(state) do
      {widget, _rect} = input(state)
      widget.block.title
    end

    defp placeholder({widget, _rect}), do: widget.placeholder
  end

  # The composer's cursor artifact (ADR 0015 §1, amended by issue #104):
  # focus-gated, blink-toggled at idle, blink-riding-the-tick in active
  # phases.
  describe "input cursor" do
    defp cursor_style(state) do
      {widget, _rect} = input(state)
      widget.cursor_style
    end

    test "unfocused: the artifact is absent in every phase" do
      for phase <- [:idle, :streaming, :executing_tool, :confirming] do
        state = %{new_state() | phase: phase, focused?: false}
        assert cursor_style(state) == %ExRatatui.Style{}, "phase #{phase}"
      end
    end

    test "focused and idle: the blink phase gates the artifact (issue #104)" do
      for step <- 0..7 do
        state = %{new_state() | phase: :idle, anim_step: step}
        assert cursor_style(state) == Theme.style(:cursor), "step #{step}"
      end

      # The idle blink (ADR 0006's 2026-10-31 amendment): blink_on false is
      # the invisible half-period — the toggle frame's whole content.
      for step <- 0..7 do
        state = %{new_state() | phase: :idle, anim_step: step, blink_on: false}
        assert cursor_style(state) == %ExRatatui.Style{}, "step #{step}"
      end
    end

    test "blink/1 toggles the phase and nothing else" do
      base = %{new_state() | phase: :idle}
      off = State.blink(base)
      assert off.blink_on == false
      on = State.blink(off)
      assert on.blink_on == true
    end

    # Prominence regression (#91): reversed alone inherits the terminal's
    # default fg — dim-family next to the dark-gray placeholder. The role
    # must carry its own bright pair so the block pops on every palette.
    test "the cursor role is a bright reversed pair, not a bare reversal" do
      assert Theme.style(:cursor) == %ExRatatui.Style{
               fg: :white,
               bg: :black,
               modifiers: [:reversed]
             }
    end

    test "focused and streaming: the blink alternates 4 ticks on / 4 ticks off" do
      base = new_state()

      for step <- 0..7 do
        state = %{base | phase: :streaming, anim_step: step}

        expected =
          if step < 4, do: Theme.style(:cursor), else: %ExRatatui.Style{}

        assert cursor_style(state) == expected, "step #{step}"
      end
    end
  end

  # The cursor artifact proven at the DRAWN CELLS (ADR 0015 §1): the test
  # terminal's styled-cell API (ExRatatui.CellSession) renders through the
  # real Rust renderer, so the per-cell modifiers are the terminal truth —
  # not just the widget struct the renderer consumes.
  describe "input cursor drawn cells" do
    alias ExRatatui.CellSession

    defp reversed_cells(state) do
      session = CellSession.new(80, 24)

      :ok =
        CellSession.draw(session, View.render(state, %ExRatatui.Frame{width: 80, height: 24}))

      count =
        session
        |> CellSession.take_cells()
        |> Map.get(:cells, [])
        |> Enum.count(&(:reversed in &1.modifiers))

      CellSession.close(session)
      count
    end

    test "focused and idle: exactly one reversed cell" do
      idle = %{new_state() | phase: :idle}
      assert reversed_cells(idle) == 1
    end

    test "unfocused: zero reversed cells in every phase" do
      for phase <- [:idle, :streaming, :executing_tool, :confirming] do
        state = %{new_state() | phase: phase, focused?: false}
        assert reversed_cells(state) == 0, "phase #{phase}"
      end
    end

    test "focused and streaming: the blink draws on steps 0 and 3, not 4 and 7" do
      base = new_state()

      for step <- [0, 3] do
        assert reversed_cells(%{base | phase: :streaming, anim_step: step}) == 1,
               "step #{step}"
      end

      for step <- [4, 7] do
        assert reversed_cells(%{base | phase: :streaming, anim_step: step}) == 0,
               "step #{step}"
      end
    end
  end

  describe "the command palette (ADR 0020)" do
    test "a filter popup draws the matched commands over the frame" do
      palette = %Palette{
        mode: :filter,
        kind: :commands,
        items: Commands.match("model"),
        selected: 0
      }

      state = %{new_state() | palette: palette}

      assert drawn_text(state) =~ "/model — pick a model"
    end

    test "a models picker draws ids, context detail, and the current marker" do
      entries = [%{model: "m1", context: 128_000}, %{model: "m2", context: nil}]

      palette = %Palette{mode: :modal, kind: :models, items: entries, selected: 1}
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "m2", api_key: "k"}}
      state = %{new_state(provider: provider) | palette: palette}

      buffer = drawn_text(state)

      assert buffer =~ "Models"
      assert buffer =~ "m1 (128k)"
      assert buffer =~ "m2 · current"
    end

    test "the context detail rides the status bar's humanize ladder" do
      entries = [%{model: "tiny", context: 999}, %{model: "big", context: 1_048_576}]
      palette = %Palette{mode: :modal, kind: :models, items: entries, selected: 0}
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "tiny", api_key: "k"}}
      state = %{new_state(provider: provider) | palette: palette}

      buffer = drawn_text(state)

      assert buffer =~ "tiny (999)"
      assert buffer =~ "big (1m)"
    end

    test "a profiles picker draws the names" do
      palette = %Palette{mode: :modal, kind: :profiles, items: ["personal", "work"], selected: 0}
      state = %{new_state() | palette: palette}

      buffer = drawn_text(state)

      assert buffer =~ "Profiles"
      assert buffer =~ "personal"
    end

    test "a filter palette is idle-only: an active phase renders no palette widgets" do
      palette = %Palette{mode: :filter, kind: :commands, items: Commands.all(), selected: 0}
      state = %{new_state() | phase: :streaming, palette: palette}

      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert length(widgets) == 5
    end
  end

  describe "the title dialog (issue #106)" do
    defp dialog_state(draft, error) do
      %{new_state() | title_dialog: %{draft: draft, error: error}}
    end

    defp dialog_paragraph(state) do
      [{%ExRatatui.Widgets.Popup{content: %ExRatatui.Widgets.Paragraph{} = paragraph}, _area}] =
        state
        |> View.render(%ExRatatui.Frame{width: 80, height: 24})
        |> Enum.take(-1)

      paragraph
    end

    test "the dialog rides last, a Popup over the five chrome widgets" do
      state = dialog_state("fix it", nil)

      widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
      assert length(widgets) == 6

      assert {%ExRatatui.Widgets.Popup{}, _area} = List.last(widgets)
    end

    test "the box carries the accent title, the draft row, and the dim hint" do
      buffer = drawn_text(dialog_state("fix it", nil))

      assert buffer =~ "Session title"
      assert buffer =~ "❯ fix it█"
      assert buffer =~ "⏎ rename · esc cancel"
    end

    test "the refusal renders in the error role, wrapped so the holder id never clips" do
      holder = "0192aa10-b002-7c00-8000-00000000000c"
      error = ~s("Taken Name" is already taken by session #{holder})

      buffer = drawn_text(dialog_state("Taken Name", error))
      assert buffer =~ "already taken"
      assert buffer =~ holder

      # Every refusal row carries the :error role, and the wrap keeps each
      # row inside the box's inner width (60% of the 76-cell area, minus
      # borders → 43 columns).
      paragraph = dialog_paragraph(dialog_state("Taken Name", error))
      [_draft, _hint | error_lines] = paragraph.text

      assert error_lines != []

      for %ExRatatui.Text.Line{spans: [span]} <- error_lines do
        assert span.style == Theme.style(:error)
        assert String.length(span.content) <= 43
      end
    end

    test "a closed dialog renders no dialog widgets" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 80, height: 24})
      assert length(widgets) == 5
    end

    # Review F2: titles run to 80 chars, the box's inner width at 80 cols is
    # 43 — an over-long draft head-clips with `…` (the attach row's own
    # tail-showing rule) so the block cursor stays visible at the end,
    # where editing happens.
    test "an over-long draft tail-shows with a head-clip marker, cursor visible" do
      draft = String.duplicate("x", 79)

      buffer = drawn_text(dialog_state(draft, nil))
      assert buffer =~ "█"

      [%ExRatatui.Text.Line{spans: [prefix, body]} | _rest] =
        dialog_paragraph(dialog_state(draft, nil)).text

      assert prefix.content == "❯ "
      assert String.starts_with?(body.content, "…")
      # The row fits the 43-column inner width: prefix + `…` + tail + cursor.
      assert String.length(prefix.content) + String.length(body.content) <= 43
      # The cursor rides the END of the draft: the last grapheme before █ is
      # the draft's tail — the span is exactly the budget (40) + the cursor.
      assert String.ends_with?(body.content, "x█")
      assert String.length(body.content) == 41
    end
  end

  ## helpers

  # The error-styled rows of a rendered setup box (issue #42 probes): the
  # wizard wraps the refusal message itself, so the rows ARE the wrap output.
  defp error_rows(state, width) do
    [{%ExRatatui.Widgets.Paragraph{text: lines}, _rect}] =
      View.render(state, %ExRatatui.Frame{width: width, height: 24})

    error = Theme.style(:error)

    for %ExRatatui.Text.Line{spans: [%ExRatatui.Text.Span{content: content, style: ^error}]} <-
          lines,
        do: content
  end

  # The full drawn frame as text (the setup screens render one widget).
  defp drawn_text(state) do
    term = ExRatatui.init_test_terminal(80, 24)
    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    ExRatatui.get_buffer_content(term)
  end

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

  defp footer_line(state) do
    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    {widget, _rect} = Enum.at(widgets, 4)
    widget.text
  end

  defp footer_text(state, width \\ 80) do
    widgets = View.render(state, %ExRatatui.Frame{width: width, height: 24})
    {widget, _rect} = Enum.at(widgets, 4)

    widget.text
    |> List.first()
    |> then(&Enum.map_join(&1.spans, "", fn span -> span.content end))
  end

  defp activity(state, w \\ 80) do
    state
    |> View.render(%ExRatatui.Frame{width: w, height: 24})
    |> Enum.at(2)
  end

  defp activity_text(state, w \\ 80) do
    {widget, _rect} = activity(state, w)
    Enum.map_join(widget.text, "", &flatten/1)
  end

  defp fox_text, do: "the quick brown fox jumps over the lazy dog again and again"

  defp assert_entry_width(state, expected) do
    for entry <- state.entries do
      assert Enum.all?(entry.lines, &(Wrap.width(flatten(&1)) <= expected))
    end
  end

  defp input(state) do
    state
    |> View.render(%ExRatatui.Frame{width: 80, height: 24})
    |> Enum.at(3)
  end

  # The input region's flat text: the composer's placeholder/draft view, or
  # the choice box's rows while a choice replaces it (ADR 0028).
  defp input_text(state) do
    {widget, _rect} = input(state)
    Enum.map_join(widget.text, "\n", &flatten/1)
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

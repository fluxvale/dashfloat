defmodule DashFloat.TUI.ViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Render
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.View

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

    test "status bar carries the cwd, model, context, and phase truth" do
      text = status_text(new_state())

      assert text =~ "❯ ~/"
      assert text =~ " · ctx — · ● Idle · "
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
        State.stream_message(
          new_state(),
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 4_100}}
        )

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

    test "very long entries do not break rendering" do
      long = String.duplicate("x", 5_000)
      state = State.stream_message(new_state(), {:entry, :system, long})
      assert [_separator, _text] = log_lines(state)
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
      assert buffer =~ "Input"
      assert buffer =~ "Enter send"
    end
  end

  ## helpers

  defp user_entry(text) do
    [%{kind: :user, text: text, lines: Render.entry_lines(:user, text)}]
  end

  defp status_text(state), do: status_text_at(state, 80, 24)

  defp status_text_at(state, w, h) do
    widgets = View.render(state, %ExRatatui.Frame{width: w, height: h})
    {widget, _rect} = List.first(widgets)
    [line] = widget.text

    line
    |> spans()
    |> Enum.join()
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

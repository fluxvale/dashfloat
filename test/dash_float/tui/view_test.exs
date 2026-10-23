defmodule DashFloat.TUI.ViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.{State, View}

  defp new_state(opts \\ []) do
    State.new(Keyword.merge([test_mode: {80, 24}], opts))
  end

  describe "regions/2" do
    test "status 1 row, log the rest, input borders + draft lines" do
      %{status: status, log: log, input: input} = View.regions({80, 24}, 1)
      assert {status.height, log.height, input.height} == {1, 20, 3}
      assert status.y == 0 and log.y == 1 and input.y == 21
      assert Enum.map([status, log, input], & &1.width) == [80, 80, 80]
    end

    test "the input grows with the draft" do
      %{log: log, input: input} = View.regions({80, 24}, 5)
      assert input.height == 7
      assert log.height == 24 - 1 - 7
    end

    test "the input never exceeds a third of the frame" do
      assert View.input_height(10, 12) == 4
      assert View.input_height(1, 6) == 3
    end

    test "degenerate frames collapse regions without raising" do
      %{status: status, log: log, input: input} = View.regions({1, 1}, 1)
      assert status.height == 0 and log.height == 0 and input.height == 1
    end
  end

  describe "render/2" do
    test "produces the three widgets" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 80, height: 24})

      assert [
               {%ExRatatui.Widgets.Paragraph{}, _},
               {%ExRatatui.Widgets.Paragraph{}, _},
               {%ExRatatui.Widgets.Textarea{}, _}
             ] = widgets
    end

    test "status bar carries placeholders and the phase label" do
      line = hd(status_line(new_state()))
      text = line |> spans() |> Enum.join()
      assert text =~ "DashFloat"
      assert text =~ "model: —"
      assert text =~ "ctx: —"
      assert text =~ "Idle"
    end

    test "each phase maps to its status label" do
      for {phase, label} <- [
            streaming: "Streaming",
            executing_tool: "Executing Tool",
            idle: "Idle"
          ] do
        state = %{new_state() | phase: phase}
        assert status_text(state) =~ label
      end
    end

    test "empty log shows a placeholder" do
      state = new_state()
      [line] = log_lines(state)
      assert flatten(line) =~ "(log is empty"
    end

    test "log entries render with kind styling and prefixes" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a system line"})
        |> State.stream_message({:token, "streaming "})
        |> State.stream_message({:token, "through"})

      lines = log_lines(state)
      assert flatten(hd(lines)) =~ "a system line"
      assert length(lines) == 2
    end

    test "the scroll offset is applied to the log paragraph" do
      state =
        Enum.reduce(1..100, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "line #{i}"})
        end)

      widget = log_widget(state, 80, 24)
      assert widget.scroll == {80, 0}
    end

    test "user entries are prefixed" do
      state = new_state() |> State.stream_message({:entry, :system, "x"})
      state = put_in(state.entries, [{:user, "hello"}])
      [first | _] = log_lines(state)
      assert flatten(first) =~ "❯ hello"
    end

    test "very long entries do not break rendering" do
      long = String.duplicate("x", 5_000)
      state = new_state() |> State.stream_message({:entry, :system, long})
      assert [_] = log_lines(state)
    end

    test "a tiny frame renders without raising" do
      widgets = View.render(new_state(), %ExRatatui.Frame{width: 1, height: 1})
      assert length(widgets) == 3
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
      assert buffer =~ "DashFloat"
      assert buffer =~ "Idle"
      assert buffer =~ "hello log"
      assert buffer =~ "Input"
      assert buffer =~ "Enter send"
    end
  end

  ## helpers

  defp status_text(state) do
    state |> status_line() |> hd() |> spans() |> Enum.join()
  end

  defp status_line(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> List.first()

    case widget.text do
      lines when is_list(lines) -> lines
    end
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
  defp flatten(line), do: line |> spans() |> Enum.join()
end

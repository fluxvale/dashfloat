defmodule DashFloat.TUI.ChoiceTest do
  @moduledoc false
  # The shared choice widget's pure moves (ADR 0028): construction, arrow
  # movement, multi-select toggling, the Enter/Esc answers, and the height
  # arithmetic the input region sizes from.

  use ExUnit.Case, async: true

  alias DashFloat.TUI.Choice

  describe "approve/2" do
    test "the fixed two-choice set: Approve / Reject, single-select" do
      choice = Choice.approve(make_ref(), "write_file")

      assert choice.kind == :approve
      assert choice.question == "Approve write_file?"
      assert Enum.map(choice.options, & &1.label) == ["Approve", "Reject"]
      assert choice.multi? == false
      assert choice.selected == 0
    end
  end

  describe "ask/4" do
    test "builds from the validated tool args, flattening the question" do
      choice =
        Choice.ask(
          make_ref(),
          "Which one?\nPick carefully.",
          [
            %{"label" => "A", "description" => "first"},
            %{"label" => "B"}
          ],
          false
        )

      assert choice.kind == :ask
      assert choice.question == "Which one? Pick carefully."

      assert choice.options == [
               %{label: "A", description: "first"},
               %{label: "B", description: nil}
             ]

      assert choice.multi? == false
    end
  end

  describe "move/2" do
    test "down then up returns to the start; movement wraps at both ends" do
      choice = ask_three()
      assert Choice.move(choice, :down).selected == 1
      assert Choice.move(choice, :up).selected == 2

      twice =
        choice
        |> Choice.move(:down)
        |> Choice.move(:down)

      assert twice.selected == 2
      assert Choice.move(twice, :down).selected == 0
    end
  end

  describe "toggle/1" do
    test "single-select is a no-op" do
      choice = Choice.toggle(ask_three())
      assert choice.checked == MapSet.new()
    end

    test "multi toggles the selected option, on and off" do
      multi = %{ask_three() | multi?: true}
      one = Choice.toggle(multi)
      assert MapSet.to_list(one.checked) == [0]

      moved = Choice.move(one, :down)
      two = Choice.toggle(moved)
      assert MapSet.to_list(two.checked) == [0, 1]

      # Toggling the first again removes only it.
      off =
        two
        |> Choice.move(:up)
        |> Choice.toggle()

      assert MapSet.to_list(off.checked) == [1]
    end
  end

  describe "answer/1" do
    test "single answers the selected label" do
      assert Choice.answer(ask_three()) == {:answered, ["a"]}
      second = Choice.move(ask_three(), :down)
      assert Choice.answer(second) == {:answered, ["b"]}
    end

    test "multi answers every checked label in option order" do
      multi =
        %{ask_three() | multi?: true}
        |> Choice.toggle()
        |> Choice.move(:down)
        |> Choice.move(:down)
        |> Choice.toggle()

      assert Choice.answer(multi) == {:answered, ["a", "c"]}
    end

    test "multi with nothing checked answers an empty list — a none-of-these" do
      assert Choice.answer(%{ask_three() | multi?: true}) == {:answered, []}
    end
  end

  describe "height/1" do
    test "question + blank + options + blank + hint; descriptions add a row" do
      assert Choice.height(ask_three()) == 7

      described = Choice.ask(make_ref(), "Q?", [%{"label" => "A", "description" => "x"}], false)
      assert Choice.height(described) == 6
    end

    test "the approve widget: question, blank, two options, blank, hint" do
      approve = Choice.approve(make_ref(), "edit_file")
      assert Choice.height(approve) == 6
    end
  end

  defp ask_three do
    Choice.ask(make_ref(), "Q?", [%{"label" => "a"}, %{"label" => "b"}, %{"label" => "c"}], false)
  end
end

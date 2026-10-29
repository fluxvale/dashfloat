defmodule DashFloat.TUI.PaletteTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Palette

  defp palette, do: %Palette{mode: :filter, kind: :commands, items: ~w(a b c), selected: 1}

  test "move/2 steps down and clamps at the last item" do
    once = Palette.move(palette(), :down)
    twice = Palette.move(once, :down)

    assert once.selected == 2
    assert twice.selected == 2
  end

  test "move/2 steps up and clamps at the first item" do
    once = Palette.move(palette(), :up)
    twice = Palette.move(once, :up)

    assert once.selected == 0
    assert twice.selected == 0
  end

  test "move/2 touches only the selection" do
    assert %{Palette.move(palette(), :down) | selected: 1} == palette()
    assert %{Palette.move(palette(), :up) | selected: 1} == palette()
  end
end

defmodule DashFloat.TUI.Palette do
  @moduledoc """
  The open command palette (ADR 0020): `:filter` is the composer's derived
  slash autocomplete; `:modal` is Ctrl+P, the /model picker, or the /profile
  picker. Pure data plus the one clamped movement.
  """

  @enforce_keys [:mode, :kind, :items]
  defstruct [:mode, :kind, :items, selected: 0]

  @type mode :: :filter | :modal
  @type kind :: :commands | :models | :profiles

  @type t :: %__MODULE__{
          mode: mode(),
          kind: kind(),
          items: list(),
          selected: non_neg_integer()
        }

  @doc "Moves the selection one row, clamped at both ends — no wrap (ADR 0020)."
  @spec move(t(), :up | :down) :: t()
  def move(%__MODULE__{selected: selected} = palette, :up),
    do: %{palette | selected: max(selected - 1, 0)}

  def move(%__MODULE__{selected: selected} = palette, :down),
    do: %{palette | selected: min(selected + 1, length(palette.items) - 1)}
end

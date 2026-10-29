defmodule DashFloat.Mode do
  @moduledoc """
  The interaction modes — Plan / Build / Auto / Unchained — and the per-mode
  tool gate. See ADR 0016.
  """

  # @modes is the cycle order (ADR 0016 §1): plan → build → auto → unchained
  @modes [:plan, :build, :auto, :unchained]

  @type mode :: :plan | :build | :auto | :unchained
  @type gate :: :run | :confirm | :propose | :vet
  @type risk_class :: :safe | :mutating | :risky

  @doc "The modes in cycle order (ADR 0016 §1)."
  @spec modes() :: [mode(), ...]
  def modes, do: @modes

  @doc "The next mode in cycle order, wrapping `:unchained` back to `:plan`."
  @spec cycle(mode()) :: mode()
  def cycle(mode) do
    Enum.fetch!(@modes, rem(Enum.find_index(@modes, &(&1 == mode)) + 1, length(@modes)))
  end

  @doc "True iff `term` is one of the four mode atoms."
  @spec valid?(term()) :: boolean()
  def valid?(term), do: term in @modes

  @doc "The exact, case-sensitive mode name — frozen for #69's `/mode`."
  @spec from_string(String.t()) :: {:ok, mode()} | :error
  def from_string(name) when name in ["plan", "build", "auto", "unchained"],
    do: {:ok, String.to_existing_atom(name)}

  def from_string(_name), do: :error

  @doc "The status-bar label (ADR 0016 §8)."
  @spec label(mode()) :: String.t()
  def label(mode) do
    mode
    |> Atom.to_string()
    |> String.capitalize()
  end

  @doc "The per-mode gate matrix (ADR 0016 §3): what a call of `class` does."
  @spec gate(mode(), risk_class()) :: gate()
  def gate(_mode, :safe), do: :run
  def gate(:plan, _class), do: :propose
  def gate(:build, _class), do: :confirm
  def gate(:auto, _class), do: :vet
  def gate(:unchained, _class), do: :run
end

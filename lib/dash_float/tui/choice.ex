defmodule DashFloat.TUI.Choice do
  @moduledoc """
  The shared choice widget (ADR 0028): the pending multiple-choice state that
  temporarily replaces the composer. One widget, two askers — the approval
  question (#133, armed by the agent's `{:confirm, _}` seam) and the model's
  `question` tool (#134, armed by `{:question, _}`). Pure data and moves; the
  keys route and render live in State/View, like every other input mode.

  Single-select answers with arrows + Enter; multi-select toggles with Space
  and submits with Enter (an empty submit is a meaningful "none of these").
  Esc is the explicit negative: Reject on an approval, a dismissed answer on
  a question — never silent, always answered to the asker.
  """

  @typedoc "One answer option: label plus optional description (display-only)."
  @type option :: %{label: String.t(), description: String.t() | nil}

  @type kind :: :approve | :ask

  @enforce_keys [:kind, :question, :options]
  defstruct [
    :kind,
    :question,
    :options,
    # The asker's pending-decision ref (the confirm ref or the question ref);
    # the TUI echoes it back with the decision.
    :ref,
    multi?: false,
    selected: 0,
    checked: MapSet.new()
  ]

  @type t :: %__MODULE__{
          kind: kind(),
          question: String.t(),
          options: [option()],
          ref: term(),
          multi?: boolean(),
          selected: non_neg_integer(),
          checked: MapSet.t(non_neg_integer())
        }

  @approve_options [%{label: "Approve", description: nil}, %{label: "Reject", description: nil}]

  @doc """
  The approval question (#133, ADR 0028): `Approve <name>?` with the exact
  two-choice set every non-auto approval uses — Approve / Reject,
  single-select, identical for the mutating and risky prompt classes (the
  always-allow third choice stays deferred per ADR 0016's recorded
  alternative). `ref` is the confirm ref the decision echoes.
  """
  @spec approve(term(), String.t()) :: t()
  def approve(ref, name) when is_binary(name),
    do: %__MODULE__{
      kind: :approve,
      ref: ref,
      question: "Approve #{name}?",
      options: @approve_options
    }

  @doc """
  The model's question (#134, ADR 0028): builds the ask from the validated
  tool args — string-keyed option maps in (`"label"`, optional
  `"description"`), atom-shaped options out. The question flattens to one
  line (a model-authored `\\n` must not break the one-line height
  arithmetic; the transcript keeps the raw text verbatim).
  """
  @spec ask(term(), String.t(), [map()], boolean()) :: t()
  def ask(ref, question, options, multi?)
      when is_binary(question) and is_list(options) and is_boolean(multi?) do
    %__MODULE__{
      kind: :ask,
      ref: ref,
      question: String.replace(question, "\n", " "),
      options: Enum.map(options, &normalize_option/1),
      multi?: multi?
    }
  end

  defp normalize_option(%{"label" => label} = option) do
    %{label: label, description: option["description"]}
  end

  @doc "Moves the selection, wrapping at the ends (the wizard's arithmetic)."
  @spec move(t(), :up | :down) :: t()
  def move(%__MODULE__{options: options, selected: selected} = choice, delta) do
    count = length(options)
    step = if delta == :up, do: -1, else: 1
    %{choice | selected: rem(selected + step + count, count)}
  end

  @doc """
  Toggles the SELECTED option's checkbox — multi-select only; a single-select
  Space is a no-op (Enter answers).
  """
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{multi?: false} = choice), do: choice

  def toggle(%__MODULE__{selected: selected, checked: checked} = choice) do
    %{
      choice
      | checked:
          (selected in checked && MapSet.delete(checked, selected)) ||
            MapSet.put(checked, selected)
    }
  end

  @doc """
  The Enter answer: the selected label (single) or every checked label in
  option order (multi — possibly none, a meaningful "none of these").
  """
  @spec answer(t()) :: {:answered, [String.t()]}
  def answer(%__MODULE__{multi?: false, selected: selected, options: options}),
    do: {:answered, [Enum.fetch!(options, selected).label]}

  def answer(%__MODULE__{multi?: true, options: options, checked: checked}) do
    labels =
      options
      |> Enum.with_index()
      |> Enum.filter(fn {_option, index} -> index in checked end)
      |> Enum.map(fn {option, _index} -> option.label end)

    {:answered, labels}
  end

  @doc """
  The rendered height (the composer's replacement sizing): question, a
  breathing blank, one line per option (two when it carries a description),
  a blank, and the hint row.
  """
  @spec height(t()) :: pos_integer()
  def height(%__MODULE__{options: options} = _choice),
    do: rows_of(options) + 4

  @doc """
  The selected option's FIRST content row (0-based, the same arithmetic as
  `height/1`): question and blank lead, then the option rows in order. The
  input box's scroll keeps this row visible (ADR 0028).
  """
  @spec selected_row(t()) :: non_neg_integer()
  def selected_row(%__MODULE__{options: options, selected: selected}),
    do: 2 + rows_of(Enum.take(options, selected))

  defp rows_of(options) do
    options
    |> Enum.map(&option_row_count/1)
    |> Enum.sum()
  end

  defp option_row_count(%{description: nil}), do: 1
  defp option_row_count(_option), do: 2
end

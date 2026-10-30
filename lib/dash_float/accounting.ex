defmodule DashFloat.Accounting do
  @moduledoc """
  Context accounting for the conversation transcript
  ([ADR 0022](docs/decisions/0022-context-accounting-and-compaction.md)): the
  last provider usage frame anchors an estimate that a chars/4 heuristic
  grows per appended message, and eviction drops whole oldest turns once the
  estimate crosses 80% of the configured window. Pure — no I/O, no clock, no
  process state — and every number here is an estimate, never a count.
  """

  @type anchor :: nil | %{tokens: non_neg_integer(), index: non_neg_integer()}

  @doc """
  The size estimate of `messages` (ADR 0022 §1): with an anchor, its measured
  `tokens` plus the heuristic weight of every message after the `index` it
  covered; without one, the heuristic alone over the whole list. An estimate,
  never a count.
  """
  @spec estimate([map()], anchor()) :: non_neg_integer()
  def estimate(messages, anchor), do: estimate_trusted(messages, trust(anchor, messages))

  defp estimate_trusted(messages, nil), do: sum_weights(messages)

  defp estimate_trusted(messages, %{tokens: tokens, index: index}) do
    tokens + sum_weights(Enum.drop(messages, index))
  end

  # Total on purpose (hostile review B1): a hand-built or hand-edited anchor
  # must degrade to the pure heuristic, never raise out of a prompt. The
  # session loader refuses nothing here (ADR 0022 §6), so these public APIs —
  # which #67 will bind to — cannot assume their callers validated. An index
  # past the list is hand damage, not growth (M1): a legitimate frame never
  # covered more messages than exist, and honouring it would let a small
  # `tokens` vouch for an unbounded history and switch eviction off.
  defp trust(nil, _messages), do: nil

  defp trust(%{tokens: tokens, index: index}, messages)
       when is_integer(tokens) and tokens >= 0 and is_integer(index) and index >= 0 and
              index <= length(messages),
       do: %{tokens: tokens, index: index}

  defp trust(_malformed, _messages), do: nil

  @doc """
  The stage-2 read the stats footer binds to (ADR 0022 §7): the estimate of
  `messages`, `window` passed through, and the percent of window used to one
  decimal — `nil` percent with no window.
  """
  @spec usage([map()], anchor(), pos_integer() | nil) ::
          %{window: pos_integer() | nil, used: non_neg_integer(), percent: float() | nil}
  def usage(messages, anchor, window) do
    used = estimate(messages, anchor)
    %{window: window, used: used, percent: percent(used, window)}
  end

  @doc """
  Drops whole oldest turns — each `user` message opens one — from the front
  while the estimate sits above `div(window * 4, 5)` and more than one turn
  remains, so `kept` is always a suffix of `messages` and no `tool_calls`
  batch can be split from its results (ADR 0022 §4). A leading non-user
  prelude is its own first group. A leading `system` message is session
  context, not a turn (ADR 0019): it stays pinned — never evicted — and its
  weight rides the estimate as a heuristic floor whenever the anchor is nil
  or spent, so the trigger always sees the full list the wire carries. The
  anchor sheds the weights of the messages a drop takes, and `oversize`
  flags a surviving turn that is itself above the budget.
  """
  @spec compact([map()], anchor(), pos_integer()) ::
          %{kept: [map()], anchor: anchor(), dropped: non_neg_integer(), oversize: boolean()}
  def compact(messages, anchor, window), do: compact_at(messages, anchor, div(window * 4, 5), 0)

  # The pinned split (ADR 0019): the anchor threads down (shift) and back
  # (unshift — unless the INPUT anchor covers nothing, where nil stays nil
  # and index 0 stays index 0), and the pinned weight threads down as a
  # floor for nil/spent-anchor estimates. A real anchor's tokens already
  # measured everything the floor stands for — the two never add.
  defp compact_at(messages, anchor, threshold, floor) do
    case split_system(messages) do
      {[system], rest} ->
        shifted = shift(anchor)
        plan = compact_at(rest, shifted, threshold, floor + weight(system))

        anchor =
          if is_nil(anchor) or anchor.index == 0,
            do: plan.anchor,
            else: unshift(plan.anchor)

        %{plan | kept: [system | plan.kept], anchor: anchor}

      :none ->
        {groups, anchor, dropped} =
          evict(turns(messages), trust(anchor, messages), threshold, 0, floor)

        kept = Enum.concat(groups)

        %{
          kept: kept,
          anchor: anchor,
          dropped: dropped,
          oversize: evict_estimate(groups, anchor, floor) > threshold
        }
    end
  end

  defp sum_weights(messages) do
    messages
    |> Enum.map(&weight/1)
    |> Enum.sum()
  end

  # Bytes/4 over the counted fields (ADR 0022 §1): the content, plus each
  # tool call's function name and argument JSON.
  defp weight(message) do
    content = field(message, :content)
    content_weight = if is_binary(content), do: div(byte_size(content), 4), else: 0

    content_weight + calls_weight(message)
  end

  defp calls_weight(message) do
    case field(message, :tool_calls) do
      calls when is_list(calls) ->
        calls
        |> Enum.map(&call_weight/1)
        |> Enum.sum()

      _other ->
        0
    end
  end

  defp call_weight(call) do
    function = field(call, :function)
    div(byte_size(field(function, :name)), 4) + div(byte_size(field(function, :arguments)), 4)
  end

  # Message maps arrive atom-keyed (live) or string-keyed (loaded); every
  # read tries both (ADR 0022 §1).
  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # Turns are structural: each `user` message opens one. Leading non-user
  # messages form their own leading group (dropped first, so they can never
  # split from what follows), and a transcript with no user message is a
  # single turn (ADR 0022 §4).
  defp turns(messages) do
    {reversed, current} =
      Enum.reduce(messages, {[], []}, fn message, {turns, current} ->
        if user?(message) and current != [] do
          {[Enum.reverse(current) | turns], [message]}
        else
          {turns, [message | current]}
        end
      end)

    Enum.reverse([Enum.reverse(current) | reversed])
  end

  defp user?(message), do: field(message, :role) == "user"

  # The pinned leading system message (ADR 0019): the anchor shifts with the
  # split so its coverage boundary stays on the same message. The shift back
  # is applied by compact_at only when a drop re-indexed the anchor, so an
  # index-0 anchor stays index-0 and a nil anchor stays nil — the round trip
  # is symmetric for every shape the loader tolerates.
  defp split_system([first | rest]) do
    if system?(first), do: {[first], rest}, else: :none
  end

  defp split_system([]), do: :none

  defp system?(message), do: field(message, :role) == "system"

  defp shift(nil), do: nil

  defp shift(%{tokens: tokens, index: index}),
    do: %{tokens: tokens, index: max(index - 1, 0)}

  defp unshift(nil), do: nil

  defp unshift(%{tokens: tokens, index: index}), do: %{tokens: tokens, index: index + 1}

  # Oldest turns leave whole, one at a time, while the estimate sits above
  # the trigger and more than one turn remains (ADR 0022 §4).
  defp evict([last], anchor, _threshold, dropped, _floor), do: {[last], anchor, dropped}

  defp evict(groups, anchor, threshold, dropped, floor) do
    if evict_estimate(groups, anchor, floor) > threshold do
      [group | rest] = groups
      evict(rest, shed(anchor, group), threshold, dropped + 1, floor)
    else
      {groups, anchor, dropped}
    end
  end

  # A nil anchor (no frame yet, a provider that never emits usable usage, a
  # spent anchor) estimates the heuristic over the groups PLUS the pinned
  # floor — the full list the wire carries; an anchored estimate already
  # measured the floor's weight and must not double-count it.
  defp evict_estimate(groups, nil, floor), do: floor + sum_weights(Enum.concat(groups))

  defp evict_estimate(groups, anchor, _floor), do: estimate(Enum.concat(groups), anchor)

  # The anchor sheds the weights of the covered messages a drop takes away
  # (ADR 0022 §4); once it covers nothing it is spent.
  defp shed(nil, _group), do: nil

  defp shed(%{tokens: tokens, index: index}, group) do
    taken = Enum.take(group, index)
    tokens = max(0, tokens - sum_weights(taken))
    index = index - length(taken)

    if index == 0, do: nil, else: %{tokens: tokens, index: index}
  end

  defp percent(used, window) when is_integer(window) and window > 0,
    do: Float.round(100 * used / window, 1)

  defp percent(_used, _window), do: nil
end

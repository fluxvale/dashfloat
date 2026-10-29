defmodule DashFloat.AccountingTest do
  @moduledoc false
  # Fixtures are hand-built provider-shaped maps, atom-keyed (live) and
  # string-keyed (loaded) — see ADR 0022.
  use ExUnit.Case, async: true

  alias DashFloat.Accounting

  defp pad(n), do: String.duplicate("x", n)

  defp user(n), do: %{role: "user", content: pad(n)}

  defp assistant(n), do: %{role: "assistant", content: pad(n)}

  defp call(id, name_bytes, args_bytes) do
    %{
      id: id,
      type: "function",
      function: %{name: pad(name_bytes), arguments: pad(args_bytes)}
    }
  end

  defp tool_assistant(calls, content_bytes) do
    %{
      role: "assistant",
      content: if(content_bytes == 0, do: nil, else: pad(content_bytes)),
      tool_calls: calls
    }
  end

  defp tool_result(id, n), do: %{role: "tool", tool_call_id: id, content: pad(n)}

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {Atom.to_string(key), stringify(inner)} end)
  end

  defp stringify(value), do: value

  defp field_of(message, key), do: Map.get(message, key) || Map.get(message, Atom.to_string(key))

  defp role(message), do: field_of(message, :role)

  defp call_ids(messages) do
    for message <- messages,
        calls = field_of(message, :tool_calls),
        is_list(calls),
        call <- calls do
      field_of(call, :id)
    end
    |> MapSet.new()
  end

  defp tool_ids(messages) do
    for message <- messages, role(message) == "tool" do
      field_of(message, :tool_call_id)
    end
    |> MapSet.new()
  end

  # The invariants of a compact that dropped something (ADR 0022 §4): the
  # kept list is a user-first suffix and no kept call lost its answer.
  # The suffix rule always holds; the user-first head is a property of a
  # DROP (a retained prelude, including a no-user transcript, keeps whatever
  # head the input had — ADR 0022 §4). Hostile review m2: the randomized run
  # must exercise those arms, not assume them away.
  defp assert_suffix_invariants(messages, kept, dropped \\ 1) do
    prefix_length = length(messages) - length(kept)
    assert kept == Enum.drop(messages, prefix_length)
    if dropped > 0 and has_user?(messages), do: assert(role(hd(kept)) == "user")

    calls = call_ids(kept)
    answers = tool_ids(kept)
    assert MapSet.equal?(calls, answers)
  end

  defp has_user?(messages), do: Enum.any?(messages, &(role(&1) == "user"))

  defp turn_count(messages) do
    Enum.count(messages, fn message -> role(message) == "user" end)
  end

  # N copies of one plain two-message turn.
  defp same_turns(n, user_bytes, assistant_bytes) do
    [user(user_bytes), assistant(assistant_bytes)]
    |> List.duplicate(n)
    |> Enum.concat()
  end

  describe "weights" do
    test "a user message contributes div(byte_size, 4) for its content" do
      assert Accounting.estimate([user(10)], nil) == 2
      assert Accounting.estimate([user(16)], nil) == 4
    end

    test "an assistant message contributes content plus each call's name and arguments" do
      message = tool_assistant([call("c1", 9, 12)], 8)

      assert Accounting.estimate([message], nil) == div(8, 4) + div(9, 4) + div(12, 4)
    end

    test "content nil weighs only its tool_calls" do
      message = tool_assistant([call("c1", 4, 2)], 0)

      assert Accounting.estimate([message], nil) == 1
    end

    test "atom-keyed and string-keyed twins estimate identically" do
      messages = [
        user(300),
        tool_assistant([call("c1", 10, 40), call("c2", 8, 0)], 0),
        tool_result("c1", 120),
        tool_result("c2", 64),
        assistant(500)
      ]

      loaded = stringify(messages)

      assert Accounting.estimate(messages, nil) == Accounting.estimate(loaded, nil)

      assert Accounting.estimate(messages, %{tokens: 900, index: 2}) ==
               Accounting.estimate(loaded, %{tokens: 900, index: 2})
    end
  end

  describe "estimate/2" do
    test "nil anchor sums the heuristic over the whole list" do
      messages = [user(400), assistant(800), tool_result("c1", 40)]

      assert Accounting.estimate(messages, nil) == 100 + 200 + 10
    end

    test "an anchor adds its tokens to the growth after the messages it covered" do
      messages = [user(400), assistant(800), user(400), assistant(800)]

      # index 2 covers the first two messages; the last two grow the estimate.
      assert Accounting.estimate(messages, %{tokens: 1000, index: 2}) == 1000 + 100 + 200
    end

    test "an index at the end adds no growth" do
      messages = [user(400), assistant(800)]

      assert Accounting.estimate(messages, %{tokens: 750, index: 2}) == 750
    end

    test "an index past the end is no anchor, not free growth (M1)" do
      messages = [user(400), assistant(800)]

      # A frame can never have covered more messages than exist; honouring the
      # stale count would report 750 for 300 tokens of history.
      assert Accounting.estimate(messages, %{tokens: 750, index: 9}) == 300
    end

    # The totality contract (hostile review B1): these are the two public
    # functions #67 binds to, so no caller's anchor shape may raise a prompt.
    test "a malformed anchor degrades to the heuristic in estimate/2 and compact/3" do
      messages = [user(400), assistant(800), user(100), assistant(200)]
      heuristic = Accounting.estimate(messages, nil)

      for anchor <- [
            %{tokens: nil, index: 2},
            %{tokens: "412", index: 2},
            %{tokens: 412, index: "2"},
            %{"tokens" => 412, "index" => 2},
            %{tokens: -5, index: 2},
            %{tokens: 1.5, index: 2},
            :junk
          ] do
        assert Accounting.estimate(messages, anchor) == heuristic

        assert %{dropped: dropped} = Accounting.compact(messages, anchor, 400)
        assert dropped >= 0
      end
    end
  end

  describe "usage/3" do
    test "returns the window, the used estimate, and the percent to one decimal" do
      assert Accounting.usage([user(400)], nil, 4000) ==
               %{window: 4000, used: 100, percent: 2.5}
    end

    test "no window means no percent" do
      assert Accounting.usage([user(400)], nil, nil) ==
               %{window: nil, used: 100, percent: nil}
    end
  end

  describe "compact/3 trigger" do
    test "a transcript at 79% of the window is untouched" do
      messages = same_turns(4, 400, 1180)
      assert Accounting.estimate(messages, nil) == 1580

      assert %{kept: kept, anchor: nil, dropped: 0, oversize: false} =
               Accounting.compact(messages, nil, 2000)

      assert kept == messages
    end

    test "just past 80% drops exactly the oldest turns required" do
      messages = same_turns(4, 400, 2000)

      assert %{kept: kept, anchor: anchor, dropped: 2} = Accounting.compact(messages, nil, 2000)

      assert kept == Enum.drop(messages, 4)
      assert Accounting.estimate(kept, anchor) <= 1600
    end

    test "a single drop suffices when one turn frees enough" do
      messages = same_turns(3, 400, 2000)

      assert %{kept: kept, dropped: 1} = Accounting.compact(messages, nil, 2000)

      assert kept == Enum.drop(messages, 2)
    end
  end

  describe "compact/3 boundary invariants" do
    test "a compact that dropped something keeps a user-first suffix with no orphaned calls" do
      messages = [
        user(400),
        tool_assistant([call("c1", 8, 20)], 10),
        tool_result("c1", 200),
        user(400),
        tool_assistant([call("c2", 8, 20), call("c3", 8, 20)], 0),
        tool_result("c2", 200),
        tool_result("c3", 200),
        user(400),
        assistant(300)
      ]

      assert %{kept: kept, dropped: dropped} = Accounting.compact(messages, nil, 500)
      assert dropped > 0

      assert_suffix_invariants(messages, kept)
    end
  end

  describe "compact/3 oversize" do
    test "a single turn above the budget stays whole and flags oversize" do
      messages = [user(100), assistant(6500)]
      assert Accounting.estimate(messages, nil) == 25 + 1625

      assert %{kept: kept, anchor: nil, dropped: 0, oversize: true} =
               Accounting.compact(messages, nil, 2000)

      assert kept == messages
    end

    test "a fitting oldest turn leaves when the newest alone exceeds the budget" do
      oldest = [user(400), assistant(2000)]
      newest = [user(100), assistant(6500)]
      messages = oldest ++ newest

      assert %{kept: kept, dropped: 1, oversize: true} = Accounting.compact(messages, nil, 2000)

      assert kept == newest
    end
  end

  describe "compact/3 anchor adjustment" do
    test "a drop shrinks the anchor by the weights of the messages it takes" do
      messages = [user(400), assistant(400), user(400), user(400), assistant(400)]

      assert %{kept: kept, anchor: anchor, dropped: 1} =
               Accounting.compact(messages, %{tokens: 1500, index: 3}, 2000)

      assert anchor == %{tokens: 1300, index: 1}
      assert kept == Enum.drop(messages, 2)
    end

    test "a drop that takes everything the anchor covered spends it" do
      messages = [user(400), assistant(400), user(400), user(400), assistant(400)]

      assert %{kept: kept, anchor: nil, dropped: 2} =
               Accounting.compact(messages, %{tokens: 1900, index: 3}, 2000)

      assert kept == Enum.drop(messages, 3)
    end
  end

  describe "compact/3 randomized" do
    test "a seeded randomized run never yields an unpaired call" do
      :rand.seed(:exsss, {1, 2, 3})

      for _transcript <- 1..200 do
        messages = generate_transcript()
        window = rand_int(200, 8000)
        anchor = random_anchor(messages)
        threshold = div(window * 4, 5)

        result = Accounting.compact(messages, anchor, window)

        assert result.dropped >= 0
        assert_suffix_invariants(messages, result.kept, result.dropped)

        estimate = Accounting.estimate(result.kept, result.anchor)

        assert estimate <= threshold or turn_count(result.kept) <= 1
        assert result.oversize == estimate > threshold
      end
    end

    # The prelude and no-user arms of the grouping rule (ADR 0022 §4), which
    # the generator above cannot produce (hostile review m2).
    test "a leading assistant prelude is its own leading group and drops first" do
      messages = [
        assistant(1200),
        user(400),
        assistant(1200),
        user(400),
        assistant(1200)
      ]

      assert %{kept: kept, dropped: 1} = Accounting.compact(messages, nil, 1000)
      assert hd(kept) == Enum.at(messages, 1)
    end

    test "a drop that includes a whole tool batch leaves no unpaired call" do
      messages = [
        user(400),
        tool_assistant([call("c1", 8, 20)], 0),
        tool_result("c1", 3000),
        user(400),
        assistant(200)
      ]

      assert %{kept: kept, dropped: 1} = Accounting.compact(messages, nil, 1000)
      assert kept == Enum.drop(messages, 3)
    end

    test "a transcript with no user message is one never-dropped turn" do
      messages = [assistant(2000)]

      assert %{kept: ^messages, dropped: 0, oversize: true} =
               Accounting.compact(messages, nil, 100)
    end
  end

  # 1–8 turns of a user message, an assistant that may carry 0–3 uniquely
  # identified tool calls, and one tool answer per call in order; the key
  # style is chosen per transcript, and both must behave identically.
  defp generate_transcript do
    messages =
      case :rand.uniform(10) do
        # a leading assistant prelude (ADR 0022 §4)
        n when n <= 2 ->
          [assistant(rand_int(1, 300)) | generate_turns()]

        # a transcript with no user message at all
        3 ->
          [assistant(rand_int(1, 4000))]

        _other ->
          generate_turns()
      end

    if :rand.uniform(2) == 1, do: stringify(messages), else: messages
  end

  defp generate_turns do
    {turns, _next_id} = build_turns(rand_int(1, 8), 1, [])

    turns
    |> Enum.reverse()
    |> Enum.concat()
  end

  defp build_turns(0, next_id, turns), do: {turns, next_id}

  defp build_turns(remaining, next_id, turns) do
    {turn, next_id} = build_turn(next_id)
    build_turns(remaining - 1, next_id, [turn | turns])
  end

  defp build_turn(next_id) do
    user = %{role: "user", content: pad(rand_int(1, 400))}
    {calls, tools, next_id} = build_calls(rand_int(0, 3), next_id, [], [])
    assistant = %{role: "assistant", content: assistant_content(), tool_calls: calls}

    {[user, assistant] ++ tools, next_id}
  end

  defp build_calls(0, next_id, calls, tools),
    do: {Enum.reverse(calls), Enum.reverse(tools), next_id}

  defp build_calls(remaining, next_id, calls, tools) do
    id = "call-#{next_id}"

    call = %{
      id: id,
      type: "function",
      function: %{name: pad(rand_int(1, 20)), arguments: pad(rand_int(0, 300))}
    }

    tool = %{role: "tool", tool_call_id: id, content: pad(rand_int(1, 500))}

    build_calls(remaining - 1, next_id + 1, [call | calls], [tool | tools])
  end

  defp assistant_content do
    if :rand.uniform(10) <= 3, do: nil, else: pad(rand_int(0, 600))
  end

  defp random_anchor(messages) do
    if :rand.uniform(2) == 1 do
      nil
    else
      %{tokens: rand_int(0, 5000), index: rand_int(0, length(messages))}
    end
  end

  defp rand_int(low, high), do: low + :rand.uniform(high - low + 1) - 1
end

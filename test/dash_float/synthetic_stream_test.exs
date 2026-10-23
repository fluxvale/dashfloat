defmodule DashFloat.SyntheticStreamTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.SyntheticStream

  test "emit/3 sends the full message contract in order and ends idle" do
    parent = self()

    collector =
      spawn(fn ->
        loop = fn loop ->
          receive do
            msg ->
              send(parent, msg)
              loop.(loop)
          after
            100 -> :ok
          end
        end

        loop.(loop)
      end)

    :ok = SyntheticStream.emit(collector, "ping", interval_ms: 0, sentences: 1)

    msgs =
      Stream.repeatedly(fn ->
        receive do
          msg -> msg
        after
          200 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    # Order: tokens → executing_tool → tool entry → streaming → tokens → idle.
    tokens = Enum.filter(msgs, &match?({:token, _}, &1))
    assert tokens != []
    assert Enum.all?(tokens, fn {:token, t} -> is_binary(t) end)
    assert Enum.any?(tokens, fn {:token, t} -> String.contains?(t, "ping") end)

    assert Enum.find_index(msgs, &match?({:token, _}, &1)) <
             Enum.find_index(msgs, &match?({:phase, :executing_tool}, &1))

    assert {:entry, :tool, text} = Enum.find(msgs, &match?({:entry, :tool, _}, &1))
    assert text =~ "[tool]"

    assert List.last(msgs) == {:phase, :idle}
    assert {:phase, :streaming} in msgs
  end
end

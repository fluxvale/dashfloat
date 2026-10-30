defmodule DashFloat.LLM.ToolCallsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.LLM.ToolCalls

  # Multi-byte characters on purpose: binary concatenation must survive a
  # split in the middle of a codepoint (invalid UTF-8 fragments recombine).
  @args_json ~s({"path": "lib/éléphant.ex", "note": "你好"})

  defp call(id, name, args_json) do
    %{
      "index" => 0,
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => args_json}
    }
  end

  test "whole-frame feed: id, name, and complete arguments in one delta" do
    acc = ToolCalls.feed(ToolCalls.new(), [call("call_abc", "read_file", @args_json)])

    assert ToolCalls.finish(acc) == [
             %{
               id: "call_abc",
               name: "read_file",
               args: %{"path" => "lib/éléphant.ex", "note" => "你好"},
               raw_args: @args_json,
               error: nil
             }
           ]
  end

  test "per-fragment feed: opening fragment then argument continuations" do
    acc =
      ToolCalls.new()
      |> ToolCalls.feed([call("call_1", "write_file", ~s({"path": ))])
      |> ToolCalls.feed([%{"index" => 0, "function" => %{"arguments" => ~s("a.txt", )}}])
      |> ToolCalls.feed([%{"index" => 0, "function" => %{"arguments" => ~s("content": "x"})}}])

    assert ToolCalls.finish(acc) == [
             %{
               id: "call_1",
               name: "write_file",
               args: %{"path" => "a.txt", "content" => "x"},
               raw_args: ~s({"path": "a.txt", "content": "x"}),
               error: nil
             }
           ]
  end

  test "adversarial splits: every byte offset of the fixture yields the unsplit result" do
    expected =
      ToolCalls.new()
      |> ToolCalls.feed([call("call_x", "read_file", @args_json)])
      |> ToolCalls.finish()

    Enum.each(0..(byte_size(@args_json) - 1), fn split ->
      acc =
        ToolCalls.new()
        |> ToolCalls.feed([
          %{
            "index" => 0,
            "id" => "call_x",
            "type" => "function",
            "function" => %{
              "name" => "read_file",
              "arguments" => binary_part(@args_json, 0, split)
            }
          }
        ])
        |> ToolCalls.feed([
          %{
            "index" => 0,
            "function" => %{
              "arguments" => binary_part(@args_json, split, byte_size(@args_json) - split)
            }
          }
        ])

      assert ToolCalls.finish(acc) == expected
    end)
  end

  test "malformed argument JSON degrades to args nil plus an error, not a raise" do
    acc =
      ToolCalls.new()
      |> ToolCalls.feed([call("call_bad", "edit_file", ~s({"path": ))])
      |> ToolCalls.feed([%{"index" => 0, "function" => %{"arguments" => ~s(})}}])

    assert ToolCalls.finish(acc) == [
             %{
               id: "call_bad",
               name: "edit_file",
               args: nil,
               raw_args: ~s({"path": }),
               error: "invalid JSON arguments"
             }
           ]
  end

  test "arguments decoding to a non-object are invalid" do
    acc = ToolCalls.feed(ToolCalls.new(), [call("call_1", "read_file", "[1, 2]")])

    assert ToolCalls.finish(acc) == [
             %{
               id: "call_1",
               name: "read_file",
               args: nil,
               raw_args: "[1, 2]",
               error: "invalid JSON arguments"
             }
           ]
  end

  test "a missing id is synthesized from the index" do
    acc =
      ToolCalls.feed(ToolCalls.new(), [
        %{
          "index" => 0,
          "type" => "function",
          "function" => %{"name" => "list_directory", "arguments" => "{}"}
        }
      ])

    assert ToolCalls.finish(acc) == [
             %{id: "call_0", name: "list_directory", args: %{}, raw_args: "{}", error: nil}
           ]
  end

  test "an empty-string id synthesizes from the index like a missing one" do
    acc =
      ToolCalls.feed(ToolCalls.new(), [
        %{
          "index" => 0,
          "id" => "",
          "type" => "function",
          "function" => %{"name" => "list_directory", "arguments" => "{}"}
        }
      ])

    assert ToolCalls.finish(acc) == [
             %{id: "call_0", name: "list_directory", args: %{}, raw_args: "{}", error: nil}
           ]
  end

  test "a missing name with arguments present is an error with an empty name" do
    acc =
      ToolCalls.feed(ToolCalls.new(), [
        %{"index" => 2, "id" => "call_2", "function" => %{"arguments" => "{}"}}
      ])

    assert ToolCalls.finish(acc) == [
             %{
               id: "call_2",
               name: "",
               args: %{},
               raw_args: "{}",
               error: "missing function name"
             }
           ]
  end

  test "no argument fragments at all means empty args and no error" do
    acc =
      ToolCalls.feed(ToolCalls.new(), [
        %{
          "index" => 0,
          "id" => "call_9",
          "type" => "function",
          "function" => %{"name" => "list_directory"}
        }
      ])

    assert ToolCalls.finish(acc) == [
             %{id: "call_9", name: "list_directory", args: %{}, raw_args: "", error: nil}
           ]
  end

  test "interleaved indices accumulate independently and finish sorted by index" do
    acc =
      ToolCalls.new()
      |> ToolCalls.feed([
        %{
          "index" => 1,
          "id" => "call_b",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => ~s({"pa)}
        }
      ])
      |> ToolCalls.feed([
        %{
          "index" => 0,
          "id" => "call_a",
          "type" => "function",
          "function" => %{"name" => "list_directory", "arguments" => "{}"}
        }
      ])
      |> ToolCalls.feed([%{"index" => 1, "function" => %{"arguments" => ~s(th": "x"})}}])

    assert [%{id: "call_a"}, %{id: "call_b"}] = ToolCalls.finish(acc)
  end

  test "non-map deltas and entries without an integer index are skipped" do
    acc =
      ToolCalls.feed(ToolCalls.new(), [
        "garbage",
        5,
        nil,
        %{"id" => "call_z", "function" => %{"name" => "list_directory"}},
        %{"index" => "0", "id" => "call_str", "function" => %{"name" => "read_file"}},
        call("call_ok", "list_directory", "{}")
      ])

    assert [%{id: "call_ok"}] = ToolCalls.finish(acc)
  end

  test "a delta without a function map contributes only its id" do
    acc =
      ToolCalls.new()
      |> ToolCalls.feed([%{"index" => 0, "id" => "call_n", "type" => "function"}])
      |> ToolCalls.feed([
        %{"index" => 0, "function" => %{"name" => "read_file", "arguments" => "{}"}}
      ])

    assert ToolCalls.finish(acc) == [
             %{id: "call_n", name: "read_file", args: %{}, raw_args: "{}", error: nil}
           ]
  end

  test "an empty feed is a no-op" do
    acc = ToolCalls.new()
    assert ToolCalls.feed(acc, []) == acc
    assert ToolCalls.finish(acc) == []
  end
end

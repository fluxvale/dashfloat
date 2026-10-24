defmodule DashFloat.LLM.ToolCalls do
  @moduledoc """
  Pure accumulator for streamed OpenAI-compatible `tool_calls` fragments.

  A streamed tool call arrives as `choices[0].delta.tool_calls` fragments: the
  first fragment for an index carries `id` and `function.name` plus the
  opening `arguments` piece; later fragments carry only `index` and argument
  pieces that must be concatenated as binaries — before any JSON parse, so a
  split inside a multi-byte character still reassembles. Multiple calls
  interleave by `index`.

  `feed/2` takes one frame's decoded `tool_calls` list (the caller guards for
  frames without one); `finish/1` decodes the accumulated arguments and sorts
  the calls by index. Malformed argument JSON degrades to an `:error` field —
  never a raise.
  """

  defstruct calls: %{}

  @typep entry :: %{id: String.t() | nil, name: String.t() | nil, args: binary()}
  @type t :: %__MODULE__{calls: %{optional(non_neg_integer()) => entry()}}

  @type call :: %{id: String.t(), name: String.t(), args: map() | nil, error: nil | String.t()}

  @doc "A fresh accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Merges one frame's decoded `tool_calls` value: per index, `id` and the
  function `name` are set once and `arguments` fragments are appended.
  Non-map entries and entries without an integer `"index"` are skipped.
  """
  @spec feed(t(), [term()]) :: t()
  def feed(acc, deltas) when is_list(deltas), do: Enum.reduce(deltas, acc, &merge/2)

  @doc "Decodes accumulated arguments and returns the calls sorted by index."
  @spec finish(t()) :: [call()]
  def finish(%__MODULE__{calls: calls}) do
    calls
    |> Enum.sort_by(fn {index, _entry} -> index end)
    |> Enum.map(&build_call/1)
  end

  defp merge(delta, %__MODULE__{calls: calls} = acc) when is_map(delta) do
    case delta["index"] do
      index when is_integer(index) and index >= 0 ->
        prev = Map.get(calls, index, %{id: nil, name: nil, args: ""})

        entry = %{
          id: prev.id || binary_field(delta["id"]),
          name: prev.name || name_field(delta),
          args: prev.args <> args_field(delta)
        }

        %{acc | calls: Map.put(calls, index, entry)}

      _missing_index ->
        acc
    end
  end

  defp merge(_delta, acc), do: acc

  defp name_field(%{"function" => fun}) when is_map(fun), do: binary_field(fun["name"])
  defp name_field(_delta), do: nil

  defp args_field(%{"function" => fun}) when is_map(fun) do
    case fun["arguments"] do
      fragment when is_binary(fragment) -> fragment
      _absent -> ""
    end
  end

  defp args_field(_delta), do: ""

  defp binary_field(value) when is_binary(value), do: value
  defp binary_field(_value), do: nil

  defp build_call({index, entry}) do
    {args, args_error} = decode_args(entry.args)

    error =
      cond do
        is_nil(entry.name) -> "missing function name"
        args_error -> "invalid JSON arguments"
        true -> nil
      end

    %{
      id: entry.id || "call_#{index}",
      name: entry.name || "",
      args: args,
      error: error
    }
  end

  # An empty accumulator means no argument fragments were seen: no arguments.
  defp decode_args(""), do: {%{}, false}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {map, false}
      _other -> {nil, true}
    end
  end
end

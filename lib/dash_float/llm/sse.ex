defmodule DashFloat.LLM.SSE do
  @moduledoc """
  Pure incremental Server-Sent Events parser.

  `feed/2` takes socket chunks and returns the frames completed by a blank
  line, keeping any partial frame buffered for the next call. Only `data:`
  lines are extracted; `event:`/`id:`/`retry:`, comments, and unknown fields
  are dropped per the SSE spec. Line endings are LF and CRLF — lone CR is not
  supported (ADR 0004). `[DONE]` is interpreted by `DashFloat.LLM.ChatStream`,
  not here.
  """

  defstruct buffer: ""

  @type frame :: %{data: String.t()}
  @type t :: %__MODULE__{buffer: String.t()}

  @doc "A fresh parser with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds one chunk, returning the frames it completed and the parser holding
  the remainder. A frame ends at a blank line; an incomplete tail stays
  buffered.
  """
  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(%__MODULE__{buffer: buffer}, chunk) when is_binary(chunk) do
    {frames, rest} = buffer |> Kernel.<>(chunk) |> normalize() |> split_frames([])

    {frames |> Enum.reverse() |> Enum.flat_map(&parse_frame/1), %__MODULE__{buffer: rest}}
  end

  # Normalizing the whole buffer (not just the new chunk) keeps a CRLF split
  # across two chunks intact: the held-back "\r" meets the next "\n" here.
  defp normalize(buffer), do: String.replace(buffer, "\r\n", "\n")

  defp split_frames(buffer, acc) do
    case :binary.split(buffer, "\n\n") do
      [frame, rest] -> split_frames(rest, [frame | acc])
      [rest] -> {acc, rest}
    end
  end

  defp parse_frame(frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&data_value/1)

    case data do
      [] -> []
      lines -> [%{data: Enum.join(lines, "\n")}]
    end
  end

  # "data: value" strips exactly one leading space; "data:value" keeps its own.
  defp data_value("data: " <> value), do: value
  defp data_value("data:" <> value), do: value
end

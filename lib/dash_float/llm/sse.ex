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
    # Normalize only the new chunk (plus a "\r" held back from the previous
    # one, so a CRLF split across chunks stays intact) — re-scanning the whole
    # buffer on every chunk would be quadratic on a large frame.
    {buffer, chunk} = move_trailing_cr(buffer, chunk)

    {frames, rest} = (buffer <> normalize(chunk)) |> split_frames([])

    {frames |> Enum.reverse() |> Enum.flat_map(&parse_frame/1), %__MODULE__{buffer: rest}}
  end

  # A "\r" at the very end of the buffer may be half of a CRLF whose "\n"
  # arrives in this chunk: hold it back so normalize/1 can see the pair.
  defp move_trailing_cr(buffer, chunk) do
    size = byte_size(buffer)

    if size > 0 and :binary.last(buffer) == ?\r do
      {binary_part(buffer, 0, size - 1), "\r" <> chunk}
    else
      {buffer, chunk}
    end
  end

  defp normalize(chunk), do: String.replace(chunk, "\r\n", "\n")

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

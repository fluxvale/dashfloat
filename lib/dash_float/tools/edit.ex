defmodule DashFloat.Tools.Edit do
  @moduledoc """
  Shared exact-match locator for `edit_file`, plus the line splitting both
  the runner and the preview hunk builder agree on.

  Matching is byte-exact substring matching (`:binary.matches`) — no
  normalization, no whitespace flexibility. `search_block == replace_block`
  is the runner's concern, not `locate/2`'s.
  """

  @doc "Splits `content` into lines, dropping the trailing empty piece."
  @spec lines(String.t()) :: [String.t()]
  def lines(""), do: []

  def lines(content) do
    if String.ends_with?(content, "\n") do
      content
      |> String.split("\n")
      |> Enum.drop(-1)
    else
      String.split(content, "\n")
    end
  end

  @doc """
  Locates `search_block` in `content`: `{:ok, %{count: 1, start: offset}}` on
  exactly one byte-offset match, `{:error, {:ambiguous, n}}` for `n >= 2`
  matches, `{:error, {:no_match, 0}}` for none, `{:error, :empty_search}` for
  an empty block. Matches do not overlap.
  """
  @spec locate(String.t(), String.t()) ::
          {:ok, %{count: 1, start: non_neg_integer()}}
          | {:error, {:ambiguous, pos_integer()} | {:no_match, 0} | :empty_search}
  def locate(_content, ""), do: {:error, :empty_search}

  def locate(content, search_block) when is_binary(content) and is_binary(search_block) do
    case :binary.matches(content, search_block) do
      [{start, _length}] -> {:ok, %{count: 1, start: start}}
      [] -> {:error, {:no_match, 0}}
      matches -> {:error, {:ambiguous, length(matches)}}
    end
  end
end

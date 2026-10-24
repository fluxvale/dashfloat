defmodule DashFloat.Config.JSON5 do
  @moduledoc """
  JSON5 codec for the config files ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  Wraps hex `json5`'s Combine backend. Two deviations from the raw library,
  both load-bearing:

    * numbers decode as `Decimal` (the library preserves precision); they are
      normalized to integers/floats here so config consumers never see one
    * parser errors are replaced with a bare `"invalid JSON5"` — the raw
      reason is position-only noise, and a fixed string guarantees no input
      content can ever leak into an error message next to secrets
  """

  @doc """
  Decodes JSON5 `input`, normalizing numbers. `{:error, "invalid JSON5"}` on
  any parse failure — never the input's content.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(input) when is_binary(input) do
    case Json5.decode(input) do
      {:ok, term} -> {:ok, normalize(term)}
      {:error, _reason} -> {:error, "invalid JSON5"}
    end
  end

  @doc "Encodes `term` as pretty JSON5 (config files are hand-edited)."
  @spec encode(term()) :: binary()
  def encode(term) do
    {:ok, text} = Json5.encode(term, pretty: true)
    text
  end

  defp normalize(%Decimal{} = decimal) do
    if Decimal.integer?(decimal), do: Decimal.to_integer(decimal), else: Decimal.to_float(decimal)
  end

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end

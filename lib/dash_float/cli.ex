defmodule DashFloat.CLI do
  @moduledoc """
  Startup-argument parsing for the profile/model selection flags
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  `parse/1` turns argv into a keyword list the config loader consumes:
  `[profile: "work", model: "Sol"]`. Accepted forms: `--profile work`,
  `--profile=work`, `--model Sol`, `--model=Sol`. A switch without a value,
  an unrecognized argument, or a repeated switch warns and is ignored —
  argument mistakes must not crash startup, and the config loader's own
  unknown-profile/model warnings still surface the miss. Everything is
  startup-time; runtime switching is a named future slice in the ADR.
  """

  require Logger

  @flags ["--profile", "--model"]
  @keys %{"--profile" => :profile, "--model" => :model}

  @doc "Parses argv into `[profile: name, model: name]`, warning and skipping what it does not recognize."
  @spec parse([String.t()]) :: keyword()
  def parse(argv) when is_list(argv) do
    argv
    |> do_parse([])
    |> Enum.reverse()
  end

  defp do_parse([], acc), do: acc

  defp do_parse([flag, value | rest], acc) when flag in @flags do
    do_parse(rest, put_new(acc, Map.fetch!(@keys, flag), value))
  end

  defp do_parse([flag | rest], acc) when flag in @flags do
    Logger.warning("#{flag} given without a value — ignored")
    do_parse(rest, acc)
  end

  defp do_parse([arg | rest], acc) do
    case String.split(arg, "=", parts: 2) do
      [flag, value] when flag in @flags ->
        do_parse(rest, put_new(acc, Map.fetch!(@keys, flag), value))

      _other ->
        warn_ignored(arg)
        do_parse(rest, acc)
    end
  end

  # The flag name only — a value like `--api-key=<secret>` must never reach a
  # log (the whole argv is user input, and secret-shaped mistakes are the
  # natural typo next to DASHFLOAT_API_KEY).
  defp warn_ignored(arg) do
    flag =
      arg
      |> String.split("=", parts: 2)
      |> hd()

    Logger.warning("unrecognized argument #{inspect(flag)} — ignored")
  end

  # The first occurrence wins; later repeats warn.
  defp put_new(acc, key, value) do
    if Keyword.has_key?(acc, key) do
      Logger.warning("a selection flag given more than once — keeping the first value")
      acc
    else
      [{key, value} | acc]
    end
  end
end

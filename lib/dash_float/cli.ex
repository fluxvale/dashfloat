defmodule DashFloat.CLI do
  @moduledoc """
  Startup-argument parsing for the profile/model selection flags
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)) and the
  session flags ([ADR 0014](../decisions/0014-session-persistence.md) §6).

  `parse/1` turns argv into a keyword list the config loader and the boot
  consume: `[profile: "work", model: "Sol", resume: "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c", title: "My session"]`.
  Accepted forms: `--profile work`, `--profile=work`, `--model Sol`,
  `--model=Sol`, `--resume <id>`, `--resume=<id>`, `--title <title>`,
  `--title=<title>`. A switch without a value, an unrecognized argument, or a
  repeated switch warns and is ignored — argument mistakes must not crash
  startup, and the config loader's own unknown-profile/model warnings still
  surface the miss. Everything is startup-time; runtime switching is a named
  future slice in the ADR. The resume id is a plain session-file id and the
  title is plain user text (never a secret); the boot consumes both after
  config classification.
  """

  require Logger

  @flags ["--profile", "--model", "--resume", "--title"]
  @keys %{
    "--profile" => :profile,
    "--model" => :model,
    "--resume" => :resume,
    "--title" => :title
  }

  @doc """
  Whether argv asks for the version (`--version`), which the boot handles and
  exits before config loading or terminal setup (ADR 0010).
  """
  @spec version?([String.t()]) :: boolean()
  def version?(argv) when is_list(argv), do: "--version" in argv

  @doc """
  Whether argv asks for the update subcommand (`update` leading argv —
  `dashfloat update [--check]`), which the boot runs and exits before
  config loading or terminal setup, like `--version`
  ([ADR 0026](../decisions/0026-update-command.md)).
  """
  @spec update?([String.t()]) :: boolean()
  def update?(["update" | _rest]), do: true
  def update?(_argv), do: false

  @doc "Parses argv into `[profile: name, model: name]`, warning and skipping what it does not recognize."
  @spec parse([String.t()]) :: keyword()
  def parse(argv) when is_list(argv) do
    argv
    |> do_parse([])
    |> Enum.reverse()
  end

  defp do_parse([], acc), do: acc

  # Handled by the boot before load (ADR 0010) — not a selection flag, and not
  # a typo worth warning about.
  defp do_parse(["--version" | rest], acc), do: do_parse(rest, acc)

  # The launcher's end-of-options separator (ADR 0010's amendment, issue
  # #113): everything past it is pure user argv, and the marker itself is
  # not an argument.
  defp do_parse(["--" | rest], acc), do: do_parse(rest, acc)

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

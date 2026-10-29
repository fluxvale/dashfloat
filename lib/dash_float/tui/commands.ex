defmodule DashFloat.TUI.Commands do
  @moduledoc """
  The slash-command registry, as data (ADR 0020): one list of
  `ExRatatui.Widgets.SlashCommands.Command` structs plus thin matching
  wrappers around the widget's `parse/1` and `match_commands/2`. Adding a
  command is one entry here plus one `run_command/3` clause in
  `DashFloat.TUI.State` — the registry never executes anything.
  """

  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.SlashCommands.Command

  @commands [
    %Command{name: "clear", description: "clear the log (input history survives)"},
    %Command{name: "help", description: "list commands and keys"},
    %Command{name: "mode", description: "show or switch the interaction mode"},
    %Command{name: "model", description: "pick a model for the next request"},
    %Command{name: "profile", description: "pick a profile"},
    %Command{name: "quit", description: "quit DashFloat"},
    %Command{name: "title", description: "rename this session"}
  ]

  @doc "The registry — every command, in display order."
  @spec all() :: [Command.t(), ...]
  def all, do: @commands

  @doc "The draft's slash prefix, per the widget (`{:command, prefix}` or `:no_command`)."
  @spec parse(String.t()) :: {:command, String.t()} | :no_command
  def parse(text), do: SlashCommands.parse(text)

  @doc "The registry commands whose name (case-insensitively) starts with `prefix`."
  @spec match(String.t()) :: [Command.t()]
  def match(prefix), do: SlashCommands.match_commands(all(), prefix)

  @doc """
  The command-shaped test (ADR 0020): `{name, rest}` when the trimmed draft's
  first whitespace-free token is exactly a registry name — `/clear`, but also
  `/mode plan` (`rest` is the trimmed remainder, possibly `""`). Anything
  else — `/etc/hosts is weird`, a prefix like `/clea` — is not a command: nil.
  """
  @spec split_command(String.t()) :: {String.t(), String.t()} | nil
  def split_command(text) do
    trimmed = String.trim(text)

    case parse(trimmed) do
      {:command, prefix} -> registry_lookup(trimmed, prefix)
      :no_command -> nil
    end
  end

  defp registry_lookup(trimmed, prefix) do
    # Case-insensitive like the widget's matcher (ADR 0020): "/MODE plan"
    # runs mode — the popup and the submit path can never disagree.
    case Enum.find(all(), &(&1.name == String.downcase(prefix))) do
      %Command{name: name} -> {name, rest_after(trimmed, name)}
      nil -> nil
    end
  end

  defp rest_after(trimmed, name) do
    trimmed
    |> String.slice((String.length(name) + 1)..-1//1)
    |> String.trim()
  end
end

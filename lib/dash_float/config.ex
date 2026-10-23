defmodule DashFloat.Config do
  @moduledoc """
  Provider configuration for the LLM streaming engine.

  Loads `~/.config/dashfloat/config.json` (honoring `XDG_CONFIG_HOME`) and
  overlays per-field environment variables, so a value can be overridden
  without editing the file. Loading happens once in `DashFloat.Application`
  and rides into the TUI as a mount opt — the UI process performs no file I/O.
  See ADR 0005.
  """

  @fields [
    base_url: "DASHFLOAT_BASE_URL",
    model: "DASHFLOAT_MODEL",
    api_key: "DASHFLOAT_API_KEY"
  ]

  # The provider rides in the TUI state, and a UI crash logs that state: never
  # let the key into a log line (ADR 0005).
  @derive {Inspect, except: [:api_key]}
  defstruct [:base_url, :model, :api_key]

  @type t :: %__MODULE__{
          base_url: String.t(),
          model: String.t(),
          api_key: String.t()
        }

  @doc "Loads the config from the default path, overlaid with the environment."
  @spec load() :: {:ok, t()} | {:error, String.t()}
  def load, do: load(default_path(), System.get_env())

  @doc "The per-user config file path (`XDG_CONFIG_HOME` respected)."
  @spec default_path() :: String.t()
  def default_path do
    :filename.basedir(:user_config, "dashfloat") |> Path.join("config.json")
  end

  @doc """
  Testable core: reads `path` (missing file = empty) and overlays `env`
  (a map of variable names to values). Blank fields after the merge yield an
  error naming only the missing field names — values are never echoed.
  """
  @spec load(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def load(path, env) when is_binary(path) and is_map(env) do
    with {:ok, file} <- read_file(path) do
      build(merge(file, env))
    end
  end

  defp merge(file, env) do
    Map.new(@fields, fn {field, var} ->
      {field, env_value(env, var) || Map.get(file, Atom.to_string(field))}
    end)
  end

  defp build(values) do
    case Enum.reject(@fields, fn {field, _var} -> value(values[field]) end) do
      [] ->
        {:ok, struct!(__MODULE__, Map.new(values, fn {field, raw} -> {field, value(raw)} end))}

      missing ->
        {:error, "missing provider config: " <> field_names(missing)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> decode(path, contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(path, contents) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "invalid JSON in #{path}: expected a JSON object"}
      {:error, error} -> {:error, "invalid JSON in #{path}: #{Exception.message(error)}"}
    end
  end

  # Only a non-blank string is a usable value; everything else is missing.
  # Trailing whitespace is dropped (a pasted newline in config.json is a
  # common accident).
  defp value(v) when is_binary(v) do
    case String.trim_trailing(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp value(_other), do: nil

  defp env_value(env, var), do: env |> Map.get(var) |> value()

  defp field_names(fields) do
    Enum.map_join(fields, ", ", fn {field, _var} -> Atom.to_string(field) end)
  end
end

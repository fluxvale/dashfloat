defmodule DashFloat.Config.Posture do
  @moduledoc """
  The 0600 security posture shared by the config files' load and migration
  paths ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md) and its
  keys-split amendment): a file that ever held credentials is 0600 wherever it
  lives.

  Best effort, failures ignored — repair never blocks a load; this only keeps
  secrets private. Only REGULAR files are chmod'd — lstat, not stat: chmod
  must never follow a symlink out of the config directory onto a file the
  loader does not own, and a non-regular file by a secrets name keeps its own
  semantics (0600 on a directory strips the execute bit and makes it
  untraversable). A missing target is a no-op.
  """

  require Logger

  @secret_mode 0o600

  @doc "Tightens `path` to 0600 when too permissive; `label` names it in warnings."
  @spec tighten(Path.t(), String.t()) :: :ok
  def tighten(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning("#{label} is a symlink — not repairing permissions")

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning("#{label} is too permissive — repairing to 0600")
          # Best effort: the result is ignored — repair never blocks a load.
          File.chmod(path, @secret_mode)
        end

        :ok

      {:ok, %File.Stat{type: other}} ->
        Logger.warning("#{label} is a #{other}, not a regular file — permissions left alone")

      _missing ->
        :ok
    end
  end
end

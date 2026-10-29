defmodule DashFloat.Config.Posture do
  @moduledoc """
  The 0600 security posture shared by the config files' load and migration
  paths ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md) and its
  keys-split amendment; [ADR 0009](../decisions/0009-config-v3-persona-profiles.md)
  for the writer's wider use): a file that ever held credentials is 0600
  wherever it lives, and every config write lands atomically at 0600.

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

  @doc """
  Writes `contents` to `path` atomically at 0600 (ADR 0008/0009): tmp file
  created empty under 0600, filled, renamed — no crash can leave a torn or
  half-written destination, and every byte the file ever holds is
  private-only. The staging name is unique per write (`<path>.tmp.<random>`,
  ADR 0014 §7): two concurrent writers of one path never share a tmp file,
  so neither can tear the other's write. The tmp path is lstat-guarded: a
  symlink at the staging name is refused, never written through.
  `{:error, message}` names paths only.
  """
  @spec write_private(Path.t(), binary()) :: :ok | {:error, String.t()}
  def write_private(path, contents) when is_binary(path) and is_binary(contents) do
    bytes = :crypto.strong_rand_bytes(4)
    rand = Base.encode16(bytes, case: :lower)
    tmp = path <> ".tmp." <> rand

    with :ok <- guard_tmp(path, tmp),
         :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, @secret_mode),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      # guard_tmp's message is already user-shaped; filesystem reasons are
      # wrapped. The tmp debris of a failed write is removed either way.
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} when is_atom(reason) ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp guard_tmp(path, tmp) do
    case File.lstat(tmp) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: other}} ->
        {:error, "cannot write #{path}: #{tmp} is a #{other}, not a regular file"}

      _missing ->
        :ok
    end
  end
end

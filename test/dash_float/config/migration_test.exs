defmodule DashFloat.Config.MigrationTest do
  @moduledoc false
  # ADR 0008 migration semantics: legacy config.json becomes the default
  # profile inside settings.json5 (0600, secrets inline), the old file
  # survives as a backup, and re-runs are no-ops. Placeholders only — never a
  # real key.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DashFloat.Config.JSON5

  @migration DashFloat.Config.Migration
  @tmp_root "/tmp/opencode"

  defp tmp_dir do
    dir = Path.join(@tmp_root, "dashfloat-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_legacy!(dir, map) do
    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(map))
    dir
  end

  defp full_legacy do
    %{
      "base_url" => "https://legacy.example/v1",
      "model" => "legacy-model",
      "api_key" => "PLACEHOLDER-legacy-key",
      "context_tokens" => 128_000
    }
  end

  defp paths(dir) do
    %{
      main: Path.join(dir, "settings.json5"),
      legacy: Path.join(dir, "config.json"),
      backup: Path.join(dir, "config.json.bak")
    }
  end

  test "a legacy config becomes the default profile, key inline, in one file" do
    dir = write_legacy!(tmp_dir(), full_legacy())

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)

    %{main: main} = paths(dir)

    assert {:ok,
            %{
              "configVersion" => 1,
              "profiles" => [
                %{
                  "name" => "default",
                  "baseUrl" => "https://legacy.example/v1",
                  "apiKey" => "PLACEHOLDER-legacy-key",
                  "models" => [
                    %{
                      "nickname" => "legacy-model",
                      "model" => "legacy-model",
                      "context" => 128_000
                    }
                  ]
                }
              ]
            }} =
             main
             |> File.read!()
             |> JSON5.decode()
  end

  test "settings.json5 is created 0600 and the legacy file is backed up by rename" do
    dir = tmp_dir()
    legacy_contents = Jason.encode!(full_legacy())
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, legacy_contents)
    # A world-readable legacy file (the v1 default shape) so the assertion
    # is umask-independent.
    File.chmod!(legacy, 0o644)

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)
    %{main: main, backup: backup} = paths(dir)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(main)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.exists?(legacy)
    assert File.read!(backup) == legacy_contents
  end

  test "the backup is tightened to 0600 and no temp debris is left behind" do
    dir = write_legacy!(tmp_dir(), full_legacy())
    # 0644 on disk — exactly the rider's live-smoke finding (issue #28):
    # the backup still holds the credential, so it lands 0600.
    legacy = Path.join(dir, "config.json")
    File.chmod!(legacy, 0o644)

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)
    %{backup: backup} = paths(dir)

    assert {:ok, %File.Stat{mode: backup_mode}} = File.stat(backup)
    assert Bitwise.band(backup_mode, 0o777) == 0o600

    files = File.ls!(dir)
    refute Enum.any?(files, &String.ends_with?(&1, ".tmp"))
  end

  test "credentials containing one quote kind survive the round trip" do
    # The Combine decoder processes no escapes, so the migration renders its
    # fixed document by hand: single-quoted values, double-quoted when the
    # value holds a single quote. A quote in a credential is preserved
    # exactly (hostile-review P1 — the json5 encoder corrupted these).
    dir =
      write_legacy!(
        tmp_dir(),
        %{
          "base_url" => "https://leg'acy.example/v1",
          "model" => "mo\"del",
          "api_key" => "PLACEHOLDER-mo'dern-key"
        }
      )

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)

    %{main: main} = paths(dir)

    assert {:ok,
            %{
              "profiles" => [
                %{
                  "baseUrl" => "https://leg'acy.example/v1",
                  "apiKey" => "PLACEHOLDER-mo'dern-key",
                  "models" => [%{"model" => "mo\"del", "nickname" => "mo\"del"}]
                }
              ]
            }} =
             main
             |> File.read!()
             |> JSON5.decode()
  end

  test "a value with both quote kinds or a backslash fails the migration by field name" do
    for bad <- ["both'kinds\"", "back\\slash"] do
      base = tmp_dir()
      dir = write_legacy!(base, Map.put(full_legacy(), "api_key", bad))

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "api_key"
          assert message =~ "cannot represent"
          refute message =~ "PLACEHOLDER"
        end)

      assert logs == ""

      %{main: main, legacy: legacy} = paths(dir)
      refute File.exists?(main)
      assert File.exists?(legacy)
    end
  end

  test "an empty settings.json5 (crash debris) is not a marker; migration proceeds" do
    dir = write_legacy!(tmp_dir(), full_legacy())
    main = Path.join(dir, "settings.json5")
    File.write!(main, "")

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)

    decoded =
      main
      |> File.read!()
      |> JSON5.decode()

    assert {:ok, %{"profiles" => [%{"name" => "default"}]}} = decoded

    backup = Path.join(dir, "config.json.bak")
    assert File.exists?(backup)
  end

  test "an unwritable directory is a load error, not a crash" do
    dir = write_legacy!(tmp_dir(), full_legacy())
    on_exit(fn -> File.chmod!(dir, 0o700) end)
    File.chmod!(dir, 0o500)

    logs =
      capture_log(fn ->
        assert {:error, message} = @migration.maybe_migrate(dir)
        assert message =~ "cannot write"
        assert message =~ "settings.json5"
      end)

    refute logs =~ "PLACEHOLDER"

    # The legacy file is untouched — nothing was renamed over it.
    legacy = Path.join(dir, "config.json")
    assert File.exists?(legacy)
  end

  test "a legacy string context_tokens (v1-accepted shape) survives the migration" do
    dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "context_tokens", "128000"))

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)

    %{main: main} = paths(dir)

    decoded =
      main
      |> File.read!()
      |> JSON5.decode()

    assert {:ok, %{"profiles" => [%{"models" => [%{"context" => 128_000}]}]}} = decoded
  end

  test "re-running is a no-op: the marker file exists, nothing is rewritten" do
    dir = write_legacy!(tmp_dir(), full_legacy())

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)
    %{backup: backup} = paths(dir)
    backup_contents = File.read!(backup)

    assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
    assert File.read!(backup) == backup_contents
    # One backup only — no .bak of the .bak, no new files.
    files = File.ls!(dir)
    assert Enum.count(files, &String.starts_with?(&1, "config.json")) == 1
  end

  test "no legacy file, or an already-migrated directory, needs nothing" do
    empty = tmp_dir()
    assert {:ok, :not_needed} = @migration.maybe_migrate(empty)

    migrated = write_legacy!(tmp_dir(), full_legacy())
    assert {:ok, :migrated} = @migration.maybe_migrate(migrated)
    assert {:ok, :not_needed} = @migration.maybe_migrate(migrated)
  end

  test "a malformed legacy file fails safely with nothing written" do
    dir = tmp_dir()
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, ~s({"api_key": "PLACEHOLDER-x",))

    assert {:error, message} = @migration.maybe_migrate(dir)
    assert message =~ "invalid JSON"
    assert message =~ "config.json"
    refute message =~ "PLACEHOLDER"

    %{main: main} = paths(dir)
    refute File.exists?(main)
    assert File.exists?(legacy)
  end

  test "an unreadable legacy file is an error, not a crash" do
    dir = tmp_dir()
    # A directory where the legacy file would be: File.read fails with :eisdir.
    legacy = Path.join(dir, "config.json")
    File.mkdir(legacy)

    assert {:error, message} = @migration.maybe_migrate(dir)
    assert message =~ "cannot read"
    assert message =~ "config.json"

    %{main: main} = paths(dir)
    refute File.exists?(main)
  end

  test "a legacy file that is not an object fails safely" do
    dir = tmp_dir()
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, "[1, 2, 3]")

    assert {:error, message} = @migration.maybe_migrate(dir)
    assert message =~ "expected a JSON object"

    %{main: main} = paths(dir)
    refute File.exists?(main)
  end

  test "an incomplete legacy file names the missing fields and writes nothing" do
    dir =
      write_legacy!(tmp_dir(), %{"base_url" => "https://legacy.example/v1", "model" => "m"})

    assert {:error, message} = @migration.maybe_migrate(dir)
    assert message =~ "missing fields api_key"
    refute message =~ "legacy.example"

    %{main: main, legacy: legacy} = paths(dir)
    refute File.exists?(main)
    assert File.exists?(legacy)
  end

  test "blank legacy values count as missing" do
    dir =
      write_legacy!(tmp_dir(), %{
        "base_url" => "https://legacy.example/v1",
        "model" => "  ",
        "api_key" => "PLACEHOLDER-x"
      })

    assert {:error, message} = @migration.maybe_migrate(dir)
    assert message =~ "missing fields model"
  end

  test "an unusable legacy context_tokens is simply omitted from the new layout" do
    dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "context_tokens", "nope"))

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)

    %{main: main} = paths(dir)

    decoded =
      main
      |> File.read!()
      |> JSON5.decode()

    assert {:ok, %{"profiles" => [%{"models" => [entry]}]}} = decoded

    refute Map.has_key?(entry, "context")
  end

  test "an existing backup is never clobbered; the legacy file stays, inert" do
    dir = tmp_dir()
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, Jason.encode!(full_legacy()))
    backup = Path.join(dir, "config.json.bak")
    File.write!(backup, ~s({"base_url": "https://older.example", "api_key": "PLACEHOLDER-old"}))

    # The older backup may itself carry a credential (issue #28 rider): it
    # is left content-intact but tightened to 0600 like every other
    # secrets-bearing file.
    File.chmod!(backup, 0o644)

    logs =
      capture_log(fn ->
        assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      end)

    assert logs =~ "already exists"
    assert File.read!(backup) =~ "older.example"
    assert {:ok, %File.Stat{mode: backup_mode}} = File.stat(backup)
    assert Bitwise.band(backup_mode, 0o777) == 0o600
    # The legacy file was NOT renamed over the user's backup…
    assert File.exists?(legacy)
    # …but it still holds the credential, so it is tightened to 0600.
    assert {:ok, %File.Stat{mode: legacy_mode}} = File.stat(legacy)
    assert Bitwise.band(legacy_mode, 0o777) == 0o600
    # …and the layout is complete and loadable regardless.
    %{main: main} = paths(dir)
    assert File.exists?(main)
  end

  # Review probe: chmod must never follow a symlink out of the config
  # directory (ADR 0008's rule, applied to the migration's tightening too).
  test "a symlinked legacy config is migrated but its target is never chmod'd" do
    dir = tmp_dir()

    target = Path.join(dir, "real-legacy.json")
    File.write!(target, Jason.encode!(full_legacy()))
    File.chmod!(target, 0o644)
    File.ln_s!(target, Path.join(dir, "config.json"))

    logs =
      capture_log(fn ->
        assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      end)

    # The migration read through the link, wrote settings.json5 0600, and
    # renamed the LINK to the backup — the target's mode is untouched.
    assert logs =~ "symlink"
    assert {:ok, %File.Stat{mode: mode}} = File.stat(target)
    assert Bitwise.band(mode, 0o777) == 0o644

    %{main: main, backup: backup} = paths(dir)
    assert File.exists?(main)
    assert File.exists?(backup)
    assert File.lstat!(backup).type == :symlink

    assert {:ok, %File.Stat{mode: main_mode}} = File.stat(main)
    assert Bitwise.band(main_mode, 0o777) == 0o600
  end

  # Review finding: only REGULAR files are tightened. A directory named
  # config.json.bak keeps its own semantics — chmod 0600 would strip its
  # execute bit and make it untraversable.
  test "a non-regular backup is warned about and left alone" do
    dir = tmp_dir()
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, Jason.encode!(full_legacy()))
    backup = Path.join(dir, "config.json.bak")
    File.mkdir(backup)
    File.chmod!(backup, 0o700)

    logs =
      capture_log(fn ->
        assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      end)

    assert logs =~ "not a regular file"

    # The directory kept its traverse bit and its contents.
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(backup)
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "repair_backup/1 covers the missing case silently" do
    empty = tmp_dir()
    assert @migration.repair_backup(empty) == :ok
  end
end

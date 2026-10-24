defmodule DashFloat.Config.MigrationTest do
  @moduledoc false
  # ADR 0008 migration semantics: legacy config.json becomes the default
  # profile inside dashfloat.json5 (0600, secrets inline), the old file
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
      main: Path.join(dir, "dashfloat.json5"),
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

  test "dashfloat.json5 is created 0600 and the legacy file is backed up by rename" do
    dir = tmp_dir()
    legacy_contents = Jason.encode!(full_legacy())
    legacy = Path.join(dir, "config.json")
    File.write!(legacy, legacy_contents)

    assert {:ok, :migrated} = @migration.maybe_migrate(dir)
    %{main: main, backup: backup} = paths(dir)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(main)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.exists?(legacy)
    assert File.read!(backup) == legacy_contents
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
    File.write!(backup, ~s({"base_url": "https://older.example"}))

    logs =
      capture_log(fn ->
        assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      end)

    assert logs =~ "already exists"
    assert File.read!(backup) =~ "older.example"
    # The legacy file was NOT renamed over the user's backup…
    assert File.exists?(legacy)
    # …and the layout is complete and loadable regardless.
    %{main: main} = paths(dir)
    assert File.exists?(main)
  end
end

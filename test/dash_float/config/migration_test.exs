defmodule DashFloat.Config.MigrationTest do
  @moduledoc false
  # ADR 0008 migration semantics and its keys-split amendment: a legacy
  # config.json becomes the default profile in de-secreted settings.json5 +
  # keys.json5 (both 0600), a v1 inline-keys settings.json5 splits in place
  # (byte-exact 0600 backup first), and re-runs are no-ops. Every backup of
  # a file that ever held credentials is 0600. Placeholders only — never a
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

  # What a real #23-migrated directory looks like: one settings.json5 with
  # inline keys (v1). Tolerated content (yourName, models extras) rides in
  # the fixtures so the general renderer is proven lossless.
  defp v1_inline do
    """
    {
      configVersion: 1,
      yourName: 'terry-placeholder',
      profiles: [
        {
          name: 'work',
          baseUrl: 'https://provider.example/v1',
          apiKey: 'PLACEHOLDER-work-key',
          settings: { defaultModel: 'Flash' },
          models: [
            { nickname: 'Sol', model: 'glm-5.3', context: 524288, modalities: ['text'] },
            { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
          ],
        },
        {
          name: 'personal',
          baseUrl: 'https://provider.example/v1',
          apiKey: 'PLACEHOLDER-personal-key',
          models: [{ nickname: 'Sol', model: 'glm-5.3', context: 262144 }],
        },
      ],
    }
    """
  end

  defp write_v1!(dir, contents \\ nil) do
    main = Path.join(dir, "settings.json5")
    File.write!(main, contents || v1_inline())
    File.chmod!(main, 0o600)
    dir
  end

  defp paths(dir) do
    %{
      main: Path.join(dir, "settings.json5"),
      keys: Path.join(dir, "keys.json5"),
      settings_backup: Path.join(dir, "settings.json5.bak"),
      legacy: Path.join(dir, "config.json"),
      backup: Path.join(dir, "config.json.bak")
    }
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  describe "legacy path: config.json → default profile + keys.json5" do
    test "the legacy triple lands de-secreted in settings.json5 plus keys.json5" do
      dir = write_legacy!(tmp_dir(), full_legacy())

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      %{main: main, keys: keys} = paths(dir)

      assert {:ok,
              %{
                "configVersion" => 2,
                "profiles" => [
                  %{
                    "name" => "default",
                    "baseUrl" => "https://legacy.example/v1",
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

      assert {:ok, %{"default" => "PLACEHOLDER-legacy-key"}} =
               keys
               |> File.read!()
               |> JSON5.decode()
    end

    test "settings.json5 and keys.json5 are created 0600 and the legacy file is backed up by rename" do
      dir = tmp_dir()
      legacy_contents = Jason.encode!(full_legacy())
      legacy = Path.join(dir, "config.json")
      File.write!(legacy, legacy_contents)
      # A world-readable legacy file (the v1 default shape) so the assertion
      # is umask-independent.
      File.chmod!(legacy, 0o644)

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      %{main: main, keys: keys, backup: backup} = paths(dir)

      assert mode(main) == 0o600
      assert mode(keys) == 0o600
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

      assert mode(backup) == 0o600

      files = File.ls!(dir)
      refute Enum.any?(files, &String.ends_with?(&1, ".tmp"))
    end

    test "credentials containing one quote kind survive the round trip" do
      # The Combine decoder processes no escapes, so migrations render by
      # hand: single-quoted values, double-quoted when the value holds a
      # single quote. A quote in a credential is preserved exactly
      # (hostile-review P1 — the json5 encoder corrupted these).
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

      %{main: main, keys: keys} = paths(dir)

      assert {:ok, %{"profiles" => [%{"baseUrl" => "https://leg'acy.example/v1"}]}} =
               main
               |> File.read!()
               |> JSON5.decode()

      assert {:ok, %{"default" => "PLACEHOLDER-mo'dern-key"}} =
               keys
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

        %{main: main, keys: keys, legacy: legacy} = paths(dir)
        refute File.exists?(main)
        refute File.exists?(keys)
        assert File.exists?(legacy)
      end
    end

    test "an empty settings.json5 (crash debris) is not a marker; migration proceeds" do
      dir = write_legacy!(tmp_dir(), full_legacy())
      main = Path.join(dir, "settings.json5")
      File.write!(main, "")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"profiles" => [%{"name" => "default"}]}} =
               main
               |> File.read!()
               |> JSON5.decode()

      assert File.exists?(paths(dir).keys)
      assert File.exists?(paths(dir).backup)
    end

    test "an unwritable directory is a load error, not a crash" do
      dir = write_legacy!(tmp_dir(), full_legacy())
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      File.chmod!(dir, 0o500)

      # keys.json5 is written FIRST (the credential reaches its new home
      # before the marker file exists), so it is the write that fails.
      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "cannot write"
          assert message =~ "keys.json5"
        end)

      refute logs =~ "PLACEHOLDER"

      # The legacy file is untouched — nothing was renamed over it.
      assert File.exists?(paths(dir).legacy)
    end

    test "a legacy string context_tokens (v1-accepted shape) survives the migration" do
      dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "context_tokens", "128000"))

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"profiles" => [%{"models" => [%{"context" => 128_000}]}]}} =
               paths(dir).main
               |> File.read!()
               |> JSON5.decode()
    end

    test "an unusable legacy context_tokens is simply omitted from the new layout" do
      dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "context_tokens", "nope"))

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"profiles" => [%{"models" => [entry]}]}} =
               paths(dir).main
               |> File.read!()
               |> JSON5.decode()

      refute Map.has_key?(entry, "context")
    end

    test "re-running is a no-op: the marker file exists, nothing is rewritten" do
      dir = write_legacy!(tmp_dir(), full_legacy())

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      %{main: main, keys: keys, backup: backup} = paths(dir)
      backup_contents = File.read!(backup)
      main_contents = File.read!(main)
      keys_contents = File.read!(keys)

      assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
      assert File.read!(backup) == backup_contents
      assert File.read!(main) == main_contents
      assert File.read!(keys) == keys_contents
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

      %{main: main, keys: keys} = paths(dir)
      refute File.exists?(main)
      refute File.exists?(keys)
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

      refute File.exists?(paths(dir).main)
    end

    test "a legacy file that is not an object fails safely" do
      dir = tmp_dir()
      legacy = Path.join(dir, "config.json")
      File.write!(legacy, "[1, 2, 3]")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "expected a JSON object"

      refute File.exists?(paths(dir).main)
    end

    test "an incomplete legacy file names the missing fields and writes nothing" do
      dir =
        write_legacy!(tmp_dir(), %{"base_url" => "https://legacy.example/v1", "model" => "m"})

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "missing fields api_key"
      refute message =~ "legacy.example"

      %{main: main, keys: keys, legacy: legacy} = paths(dir)
      refute File.exists?(main)
      refute File.exists?(keys)
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

    test "an existing keys.json5 wins over the legacy key" do
      dir = write_legacy!(tmp_dir(), full_legacy())
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{'default': 'PLACEHOLDER-user-key',}")
      File.chmod!(keys, 0o600)

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"default" => "PLACEHOLDER-user-key"}} =
               keys
               |> File.read!()
               |> JSON5.decode()
    end

    test "a malformed existing keys.json5 blocks the legacy migration too" do
      dir = write_legacy!(tmp_dir(), full_legacy())
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{ broken")
      File.chmod!(keys, 0o600)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "invalid JSON5"
      assert message =~ "keys.json5"

      # Nothing was written and the legacy file was not renamed.
      refute File.exists?(paths(dir).main)
      assert File.exists?(paths(dir).legacy)
    end

    test "a non-regular existing keys.json5 is left alone; the migration proceeds" do
      dir = write_legacy!(tmp_dir(), full_legacy())
      keys = Path.join(dir, "keys.json5")
      File.mkdir!(keys)

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "not a regular file"

      # settings.json5 and the backup landed; the directory named keys.json5
      # kept its semantics; the legacy key survives in the backup.
      assert File.exists?(paths(dir).main)
      assert File.lstat!(keys).type == :directory
      assert File.read!(paths(dir).backup) =~ "PLACEHOLDER-legacy-key"
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
      assert mode(backup) == 0o600
      # The legacy file was NOT renamed over the user's backup…
      assert File.exists?(legacy)
      # …but it still holds the credential, so it is tightened to 0600.
      assert mode(legacy) == 0o600
      # …and the layout is complete and loadable regardless.
      assert File.exists?(paths(dir).main)
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

      # The migration read through the link, wrote the new layout 0600, and
      # renamed the LINK to the backup — the target's mode is untouched.
      assert logs =~ "symlink"
      assert mode(target) == 0o644

      %{main: main, keys: keys, backup: backup} = paths(dir)
      assert File.exists?(main)
      assert File.exists?(keys)
      assert File.exists?(backup)
      assert File.lstat!(backup).type == :symlink

      assert mode(main) == 0o600
      assert mode(keys) == 0o600
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

  describe "split path: v1 inline keys split in place" do
    test "a v1 inline-keys settings.json5 splits: settings de-secreted, keys.json5 0600, backup 0600" do
      dir = tmp_dir()
      original = v1_inline()
      write_v1!(dir, original)
      # The realistic already-migrated directory carries a 0644 legacy
      # backup from #23 — it still holds the old credential.
      backup = Path.join(dir, "config.json.bak")
      File.write!(backup, ~s({"api_key": "PLACEHOLDER-old"}))
      File.chmod!(backup, 0o644)

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      %{main: main, keys: keys, settings_backup: settings_backup} = paths(dir)

      # The live settings file carries NO credential field, keeps tolerated
      # content (yourName, models extras) losslessly, and moves to v2.
      assert {:ok, decoded} =
               main
               |> File.read!()
               |> JSON5.decode()

      assert decoded["configVersion"] == 2
      assert decoded["yourName"] == "terry-placeholder"
      refute File.read!(main) =~ "PLACEHOLDER"

      [work, personal] = decoded["profiles"]
      refute Map.has_key?(work, "apiKey")
      refute Map.has_key?(personal, "apiKey")

      assert work["models"]
             |> hd()
             |> Map.get("modalities") == ["text"]

      # Keys land keyed by PROFILE NAME, 0600.
      assert {:ok, %{"work" => "PLACEHOLDER-work-key", "personal" => "PLACEHOLDER-personal-key"}} =
               keys
               |> File.read!()
               |> JSON5.decode()

      assert mode(keys) == 0o600

      # BOTH backups are 0600; the settings backup is a byte-exact copy.
      assert File.read!(settings_backup) == original
      assert mode(settings_backup) == 0o600
      assert mode(backup) == 0o600
      assert File.read!(backup) =~ "PLACEHOLDER-old"
    end

    test "re-splitting is a no-op: the v2 marker holds" do
      dir = write_v1!(tmp_dir())

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      %{main: main, keys: keys, settings_backup: settings_backup} = paths(dir)
      main_contents = File.read!(main)
      keys_contents = File.read!(keys)
      backup_contents = File.read!(settings_backup)

      assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
      assert File.read!(main) == main_contents
      assert File.read!(keys) == keys_contents
      assert File.read!(settings_backup) == backup_contents
    end

    test "a v1 file with no inline credential field is byte-untouched" do
      dir = tmp_dir()

      stripped =
        v1_inline()
        |> String.replace("apiKey: 'PLACEHOLDER-work-key',\n", "")
        |> String.replace("apiKey: 'PLACEHOLDER-personal-key',\n", "")

      write_v1!(dir, stripped)

      logs = capture_log(fn -> assert {:ok, :not_needed} = @migration.maybe_migrate(dir) end)

      assert logs == ""
      assert File.read!(paths(dir).main) == stripped
      refute File.exists?(paths(dir).settings_backup)
    end

    test "a v2 file with a stray inline key is left alone (the loader warns instead)" do
      dir =
        write_v1!(tmp_dir(), String.replace(v1_inline(), "configVersion: 1", "configVersion: 2"))

      assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
      assert File.read!(paths(dir).main) =~ "apiKey"
      refute File.exists?(paths(dir).settings_backup)
    end

    test "an existing keys.json5 wins over collected inline keys" do
      dir = write_v1!(tmp_dir())
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{'work': 'PLACEHOLDER-user-key',}")
      File.chmod!(keys, 0o600)

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      # The user's keys file is the explicit new home — never rewritten; the
      # inline values survive in the settings backup.
      assert {:ok, %{"work" => "PLACEHOLDER-user-key"}} =
               keys
               |> File.read!()
               |> JSON5.decode()

      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
      assert File.read!(paths(dir).settings_backup) =~ "PLACEHOLDER-work-key"
      assert logs =~ "already exists"
    end

    test "a malformed existing keys.json5 is an error — never destroy unreadable data" do
      dir = write_v1!(tmp_dir())
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{ broken")
      File.chmod!(keys, 0o600)
      original = File.read!(paths(dir).main)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "invalid JSON5"
      assert message =~ "keys.json5"

      # Nothing was written or rewritten.
      assert File.read!(paths(dir).main) == original
      refute File.exists?(paths(dir).settings_backup)
    end

    test "an existing settings.json5.bak is never clobbered, just tightened" do
      dir = write_v1!(tmp_dir())
      settings_backup = Path.join(dir, "settings.json5.bak")
      File.write!(settings_backup, "// an older pre-split backup")
      File.chmod!(settings_backup, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "already exists"
      assert File.read!(settings_backup) == "// an older pre-split backup"
      assert mode(settings_backup) == 0o600
      # The split itself still completes: unique data survives (keys →
      # keys.json5, rest → rewritten settings), only the pre-split
      # formatting of the CURRENT file is lost.
      assert File.read!(paths(dir).keys) =~ "PLACEHOLDER-work-key"
      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
    end

    test "a symlinked settings.json5 is skipped — the split is left by hand" do
      dir = tmp_dir()
      target = Path.join(dir, "real-settings")
      File.write!(target, v1_inline())
      File.chmod!(target, 0o644)
      File.ln_s!(target, Path.join(dir, "settings.json5"))

      logs =
        capture_log(fn ->
          assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
        end)

      # tmp+rename would SEVER the link; the original keeps its inline keys.
      assert logs =~ "not a regular file"
      assert logs =~ "settings.json5"
      assert File.read!(target) == v1_inline()
      refute File.exists?(paths(dir).keys)

      main = Path.join(dir, "settings.json5")
      assert File.lstat!(main).type == :symlink
    end

    test "a symlinked keys.json5 is skipped the same way" do
      dir = write_v1!(tmp_dir())
      target = Path.join(dir, "real-keys")
      File.write!(target, "{}")
      File.chmod!(target, 0o644)
      File.ln_s!(target, Path.join(dir, "keys.json5"))

      logs =
        capture_log(fn ->
          assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "keys.json5"
      assert logs =~ "not a regular file"
      assert File.read!(paths(dir).main) == v1_inline()

      keys = Path.join(dir, "keys.json5")
      assert File.lstat!(keys).type == :symlink
    end

    test "an unrepresentable tolerated value fails the split by path with nothing written" do
      dir = tmp_dir()

      # A literal backslash DECODES fine (the Combine backend passes escapes
      # through verbatim) but cannot be re-rendered — the reachable shape of
      # an unrepresentable tolerated value.
      unrepresentable = "'back" <> "\\" <> "slash-name'"
      write_v1!(dir, String.replace(v1_inline(), "'terry-placeholder'", unrepresentable))

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "yourName"
          assert message =~ "cannot represent"
          assert message =~ "settings.json5"
          refute message =~ "PLACEHOLDER"
        end)

      assert logs == ""

      # Renders run before any write: the directory is untouched.
      assert File.read!(paths(dir).main) =~ "apiKey"
      refute File.exists?(paths(dir).keys)
      refute File.exists?(paths(dir).settings_backup)
    end

    test "blank-only inline keys are dropped without creating an empty keys.json5" do
      dir = tmp_dir()

      contents =
        v1_inline()
        |> String.replace("apiKey: 'PLACEHOLDER-work-key',", "apiKey: '',")
        |> String.replace("apiKey: 'PLACEHOLDER-personal-key',", "apiKey: null,")

      write_v1!(dir, contents)

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, decoded} =
               paths(dir).main
               |> File.read!()
               |> JSON5.decode()

      assert Enum.all?(decoded["profiles"], &(not Map.has_key?(&1, "apiKey")))
      refute File.exists?(paths(dir).keys)
    end

    test "an unwritable directory warns about the backup and fails on the keys write" do
      dir = write_v1!(tmp_dir())
      original = File.read!(paths(dir).main)
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      File.chmod!(dir, 0o500)

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "cannot write"
          assert message =~ "keys.json5"
        end)

      # The backup failure is a WARNING, not an error — but the keys write
      # must abort the split before the settings file is emptied.
      assert logs =~ "settings.json5.bak"
      assert File.read!(paths(dir).main) == original
    end

    test "an unreadable settings.json5 is an error, not a crash" do
      dir = write_v1!(tmp_dir())
      main = Path.join(dir, "settings.json5")
      on_exit(fn -> File.chmod!(main, 0o600) end)
      File.chmod!(main, 0o000)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "cannot read"
      assert message =~ "settings.json5"

      refute File.exists?(paths(dir).keys)
      refute File.exists?(paths(dir).settings_backup)
    end

    test "garbage profile entries ride through the split untouched" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 1,
          profiles: [
            'not-a-map',
            { baseUrl: 'https://no-name.example' },
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      # Only the NAMED profile's key is collected; the garbage entries are
      # tolerated content and survive the rewrite verbatim.
      assert {:ok, decoded} =
               paths(dir).main
               |> File.read!()
               |> JSON5.decode()

      ["not-a-map", no_name, work] = decoded["profiles"]
      assert no_name == %{"baseUrl" => "https://no-name.example"}
      refute Map.has_key?(work, "apiKey")

      assert {:ok, %{"work" => "PLACEHOLDER-work-key"}} =
               paths(dir).keys
               |> File.read!()
               |> JSON5.decode()
    end
  end
end

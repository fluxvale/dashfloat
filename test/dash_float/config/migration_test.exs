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

  defp write_keys_file!(dir, contents) do
    keys = Path.join(dir, "keys.json5")
    File.write!(keys, contents)
    File.chmod!(keys, 0o600)
    keys
  end

  defp write_backup!(dir, contents) do
    backup = Path.join(dir, "settings.json5.bak")
    File.write!(backup, contents)
    File.chmod!(backup, 0o600)
    backup
  end

  defp paths(dir) do
    %{
      main: Path.join(dir, "settings.json5"),
      keys: Path.join(dir, "keys.json5"),
      settings_backup: Path.join(dir, "settings.json5.bak"),
      keys_backup: Path.join(dir, "keys.json5.bak"),
      legacy: Path.join(dir, "config.json"),
      backup: Path.join(dir, "config.json.bak")
    }
  end

  # The recurring read-and-decode chains, as helpers (credo's pipe rules
  # would flag every inline occurrence).
  defp decoded_keys(dir), do: decode_file(paths(dir).keys)

  defp decoded_main(dir), do: decode_file(paths(dir).main)

  defp decode_file(path) do
    path
    |> File.read!()
    |> JSON5.decode()
  end

  defp models_of(provider), do: Map.get(provider, "models")

  defp rename_second(map), do: put_in(map, ["profiles", Access.at(1), "name"], "second")

  defp unwrap_rendered({:ok, text}), do: text

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
                "configVersion" => 3,
                "defaultProfile" => "default",
                "profiles" => [
                  %{
                    "name" => "default",
                    "providers" => [
                      %{
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
                  }
                ]
              }} =
               main
               |> File.read!()
               |> JSON5.decode()

      # The legacy chain lands ENDPOINT-KEYED (ADR 0009): one write, no v2
      # intermediate on disk.
      assert {:ok, %{"default" => %{"https://legacy.example/v1" => "PLACEHOLDER-legacy-key"}}} =
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

      assert {:ok,
              %{"profiles" => [%{"providers" => [%{"baseUrl" => "https://leg'acy.example/v1"}]}]}} =
               main
               |> File.read!()
               |> JSON5.decode()

      assert {:ok, %{"default" => %{"https://leg'acy.example/v1" => "PLACEHOLDER-mo'dern-key"}}} =
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

        # The legacy file is tightened BEFORE anything else (P2-1), so its
        # repair warning is expected — but no value ever reaches a log.
        refute logs =~ "PLACEHOLDER"

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

      assert {:ok,
              %{"profiles" => [%{"providers" => [%{"models" => [%{"context" => 128_000}]}]}]}} =
               decoded_main(dir)
    end

    test "an unusable legacy context_tokens is simply omitted from the new layout" do
      dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "context_tokens", "nope"))

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"profiles" => [%{"providers" => [%{"models" => [entry]}]}]}} =
               decoded_main(dir)

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

      # The user's flat v2 key is completed to endpoint-keyed by the v3
      # step (the single-provider join is unambiguous) — value untouched.
      assert {:ok, %{"default" => %{"https://legacy.example/v1" => "PLACEHOLDER-user-key"}}} =
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

  ## The never-lose-a-credential invariant (round-2 hostile review): after
  ## ANY migration outcome on ANY constructible pre-state, every credential
  ## VALUE that existed before is still present in at least one file on
  ## disk afterward — or the migration REFUSED with no destructive step.
  ## Crash states are modeled as constructible pre-states: writes are
  ## tmp+rename atomic, so every intermediate is either whole or absent,
  ## and the cells below ARE those intermediates (keys written + identical
  ## .bak + v1 main = post-keys crash; identical .bak + v1 main = post-
  ## backup crash; occupied .bak.tmp = blocked re-run).

  describe "invariant sweep: no credential value is ever silently lost" do
    @shapes %{
      plain: %{
        file: """
        {
          configVersion: 1,
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key',
              models: [{ model: 'glm-5.3' }] },
            { name: 'personal', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-personal-key',
              models: [{ model: 'glm-5.3' }] },
          ],
        }
        """,
        values: ["PLACEHOLDER-work-key", "PLACEHOLDER-personal-key"],
        collected: %{"work" => "PLACEHOLDER-work-key", "personal" => "PLACEHOLDER-personal-key"}
      },
      duplicates: %{
        file: """
        {
          configVersion: 1,
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-dup-old', models: [{ model: 'glm-5.3' }] },
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-dup-new', models: [{ model: 'glm-5.3' }] },
          ],
        }
        """,
        values: ["PLACEHOLDER-dup-old", "PLACEHOLDER-dup-new"],
        collected: %{"work" => "PLACEHOLDER-dup-old"}
      },
      blank_name: %{
        file: """
        {
          configVersion: 1,
          profiles: [
            { name: '', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-nameless-key', models: [{ model: 'glm-5.3' }] },
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key', models: [{ model: 'glm-5.3' }] },
          ],
        }
        """,
        values: ["PLACEHOLDER-nameless-key", "PLACEHOLDER-work-key"],
        collected: %{"work" => "PLACEHOLDER-work-key"}
      },
      root_key: %{
        file: """
        {
          configVersion: 1,
          apiKey: 'PLACEHOLDER-root-key',
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key', models: [{ model: 'glm-5.3' }] },
          ],
        }
        """,
        values: ["PLACEHOLDER-root-key", "PLACEHOLDER-work-key"],
        collected: %{"work" => "PLACEHOLDER-work-key"}
      }
    }

    defp build_cell(shape, keys_state, bak_state) do
      dir = tmp_dir()
      spec = @shapes[shape]
      main = Path.join(dir, "settings.json5")
      File.write!(main, spec.file)
      File.chmod!(main, 0o600)
      write_keys_state(dir, keys_state, spec)
      write_bak_state(dir, bak_state, spec)
      dir
    end

    defp write_keys_state(dir, keys_state, spec) do
      case keys_state do
        :absent ->
          :ok

        :malformed ->
          write_keys_file!(dir, "{ broken")

        :keys_tmp_blocked ->
          # The keys WRITE failure state (delta-2 modeling note): the split
          # reaches write_keys with a blocked tmp path — backup already
          # written, settings still untouched.
          keys_tmp = Path.join(dir, "keys.json5.tmp")
          File.mkdir!(keys_tmp)

        variant when variant in [:same, :different, :superset, :subset] ->
          write_keys_file!(dir, "{#{render_keys(variant, spec)}}")
      end
    end

    defp render_keys(variant, spec) do
      base = spec.collected

      contents =
        case variant do
          :same -> base
          :different -> Map.put(base, "work", "PLACEHOLDER-different-key")
          :superset -> Map.put(base, "ghost", "PLACEHOLDER-ghost-key")
          :subset -> Map.delete(base, "work")
        end

      contents
      |> Enum.sort()
      |> Enum.map_join(", ", fn {name, key} -> "'#{name}': '#{key}'" end)
    end

    defp write_bak_state(dir, bak_state, spec) do
      backup_tmp = Path.join(dir, "settings.json5.bak.tmp")
      backup = Path.join(dir, "settings.json5.bak")
      main = Path.join(dir, "settings.json5")

      case bak_state do
        :absent ->
          :ok

        :identical ->
          write_backup!(dir, spec.file)

        :stale ->
          write_backup!(dir, "// stale pre-split backup")

        :tmp_occupied ->
          File.mkdir!(backup_tmp)

        # Delta-2 P2 shapes: a .bak that is a symlink (lstat, never the
        # read-through) is KEPT — it preserves nothing from this file.
        :self_link ->
          File.ln_s!(main, backup)

        # P2-4 (issue #33's class): a DANGLING .bak symlink answers
        # File.exists? == false — pre-fix the write replaced the link with
        # a regular file, silently, against the "never replaced" docs.
        :dangling_link ->
          target = Path.join(dir, "no-such-target")
          File.ln_s!(target, backup)

        :outside_link ->
          copy = Path.join(dir, "dotfiles-copy")
          File.write!(copy, spec.file)
          File.ln_s!(copy, backup)

        :link_dir ->
          target = Path.join(dir, "a-directory")
          File.mkdir!(target)
          File.ln_s!(target, backup)
      end
    end

    defp file_texts(dir) do
      # File.read, not read!: a .bak symlink may point at a directory —
      # unreadable holders contribute nothing rather than raising.
      ["settings.json5", "keys.json5", "settings.json5.bak", "keys.json5.bak", "config.json.bak"]
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(&read_or_empty/1)
      |> Enum.join("\n")
    end

    defp read_or_empty(path) do
      case File.read(path) do
        {:ok, text} -> [text]
        _error -> []
      end
    end

    test "malformed-shape cells refuse cleanly with the file byte-unchanged (P1-1)" do
      shapes = [
        # profiles as a map carrying an inline key (the loss-class repro)
        "{configVersion: 1, profiles: {work: {baseUrl: 'https://provider.example/v1', apiKey: 'PLACEHOLDER-work-key'}}}",
        # profiles as a string
        "{configVersion: 1, profiles: 'nope', apiKey: 'PLACEHOLDER-root-key'}",
        # a list holding a non-object entry beside a real profile
        "{configVersion: 1, profiles: ['junk', {name: 'work', baseUrl: 'https://provider.example/v1', apiKey: 'PLACEHOLDER-work-key'}]}",
        # providers as a map on a named entry
        "{configVersion: 1, profiles: [{name: 'work', baseUrl: 'https://provider.example/v1', apiKey: 'PLACEHOLDER-work-key', providers: {x: 1}}]}",
        # mcp as a map on a named entry ({}, the empty object literal, is a
        # json5-dep parser quirk in this position — a non-empty map is the
        # honest fixture for the same wrong type)
        "{configVersion: 1, profiles: [{name: 'work', baseUrl: 'https://provider.example/v1', apiKey: 'PLACEHOLDER-work-key', mcp: {mode: 1}}}]"
      ]

      for file <- shapes, bak_state <- [:absent, :stale] do
        dir = tmp_dir()
        main = Path.join(dir, "settings.json5")
        File.write!(main, file)
        File.chmod!(main, 0o600)
        if bak_state == :stale, do: write_backup!(dir, "// stale")

        cell = "#{bak_state}:#{String.slice(file, 0, 40)}"

        # Either refusal arm protects the file: our unshapeable refusal, or
        # the json5 dep's own parse error — the dep's parse outcome for a
        # few of these shapes is PER-BOOT nondeterministic (same VM always
        # agrees; across boots, hash-order in its parser tables flips a
        # marginal shape — banked as a follow-up). A parse error is also a
        # loud, nothing-written refusal, which is the invariant here.
        assert {:error, message} = @migration.maybe_migrate(dir), "cell #{cell}"

        assert message =~ "not a shape the v3 migration can represent" or
                 message =~ "invalid JSON5",
               "cell #{cell}: #{message}"

        # Refuse-and-unchanged: the malformed file (and its inline keys)
        # survive byte-exact.
        assert File.read!(main) == file, "cell #{cell}"
      end
    end

    test "every pre-state cell preserves every credential value or refuses cleanly" do
      shapes = Map.keys(@shapes)

      keys_states = [
        :absent,
        :same,
        :different,
        :superset,
        :subset,
        :malformed,
        :keys_tmp_blocked
      ]

      bak_states = [
        :absent,
        :identical,
        :stale,
        :tmp_occupied,
        :self_link,
        :dangling_link,
        :outside_link,
        :link_dir
      ]

      for shape <- shapes, keys_state <- keys_states, bak_state <- bak_states do
        dir = build_cell(shape, keys_state, bak_state)
        spec = @shapes[shape]
        main_path = Path.join(dir, "settings.json5")
        keys_path = Path.join(dir, "keys.json5")
        backup_path = Path.join(dir, "settings.json5.bak")
        _original_main = File.read!(main_path)
        keys_file_states = [:same, :different, :superset, :subset, :malformed]
        original_keys = if keys_state in keys_file_states, do: File.read!(keys_path)

        original_bak =
          if bak_state in [:identical, :stale],
            do: File.read!(backup_path)

        cell = "#{shape}/#{keys_state}/#{bak_state}"

        {outcome, _logs} = with_log(fn -> @migration.maybe_migrate(dir) end)

        # Symlinked backups — dangling included — are never replaced.
        if bak_state in [:self_link, :dangling_link, :outside_link, :link_dir] do
          assert File.lstat!(backup_path).type == :symlink, "cell #{cell}: .bak link replaced"
        end

        # The blocked keys tmp path is likewise untouched.
        if keys_state == :keys_tmp_blocked do
          blocked = Path.join(dir, "keys.json5.tmp")
          assert File.lstat!(blocked).type == :directory, "cell #{cell}: keys tmp replaced"
        end

        case outcome do
          # REFUSED: the invariant's other arm — nothing destructive happened.
          # (Under the v3 CHAIN a cell can legitimately refuse at the v2 step
          # after the split succeeded — settings then hold the v2 shape with
          # every value homed in keys/backup. The byte-identical claim is
          # the SPLIT's contract; the sweep pins the chain's: every value
          # still on disk, and keys/backup never rewritten by a refusal.)
          {:error, _message} ->
            on_disk = file_texts(dir)

            for value <- spec.values do
              assert String.contains?(on_disk, value),
                     "cell #{cell}: refusal LOST a credential value"
            end

            if original_keys,
              do: assert(File.read!(keys_path) == original_keys, "cell #{cell}")

            if original_bak,
              do: assert(File.read!(backup_path) == original_bak, "cell #{cell}")

          # MIGRATED: every original value survives in at least one file,
          # and the LIVE settings file carries none of them.
          {:ok, :migrated} ->
            on_disk = file_texts(dir)
            live_main = File.read!(main_path)

            for value <- spec.values do
              assert String.contains?(on_disk, value),
                     "cell #{cell}: credential value LOST from every file"
            end

            for value <- spec.values do
              refute String.contains?(live_main, value),
                     "cell #{cell}: credential value still in live settings"
            end

          {:ok, :not_needed} ->
            flunk("cell #{cell}: split unexpectedly stood down")
        end
      end
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

      assert decoded["configVersion"] == 3
      assert decoded["defaultProfile"] == "work"
      assert decoded["yourName"] == "terry-placeholder"
      refute File.read!(main) =~ "PLACEHOLDER"

      [work, personal] = decoded["profiles"]
      refute Map.has_key?(work, "apiKey")
      refute Map.has_key?(personal, "apiKey")

      first_model =
        work["providers"]
        |> hd()
        |> models_of()
        |> hd()

      assert Map.get(first_model, "modalities") == ["text"]

      # Keys land ENDPOINT-KEYED under their profiles (ADR 0009), 0600.
      assert {:ok,
              %{
                "work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"},
                "personal" => %{"https://provider.example/v1" => "PLACEHOLDER-personal-key"}
              }} =
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

    test "a v1 file with no inline credential field skips the SPLIT and still reshapes to v3" do
      dir = tmp_dir()

      stripped =
        v1_inline()
        |> String.replace("apiKey: 'PLACEHOLDER-work-key',\n", "")
        |> String.replace("apiKey: 'PLACEHOLDER-personal-key',\n", "")

      write_v1!(dir, stripped)

      # The split's own rule holds — nothing to de-secret, so no settings
      # backup, no keys file. But v3 has no v1/v2 read path: the reshape
      # still restructures the profiles (ADR 0009).
      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      refute File.exists?(paths(dir).keys)

      {:ok, decoded} = decoded_main(dir)
      assert decoded["configVersion"] == 3

      assert [%{"baseUrl" => "https://provider.example/v1"}] =
               hd(decoded["profiles"])["providers"]

      refute File.read!(paths(dir).main) =~ "apiKey"
    end

    test "a v2 file with a stray inline key: the split stands down, the reshape still runs" do
      dir =
        write_v1!(tmp_dir(), String.replace(v1_inline(), "configVersion: 1", "configVersion: 2"))

      # The SPLIT's rule is unchanged — v2+ strays are the loader's warning,
      # not a rewrite — but the v3 reshape restructures the profiles; the
      # stray rides verbatim (still the loader's warning territory).
      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      main = File.read!(paths(dir).main)
      assert main =~ "PLACEHOLDER-work-key"

      {:ok, decoded} = JSON5.decode(main)
      assert decoded["configVersion"] == 3

      assert [%{"baseUrl" => "https://provider.example/v1"}] =
               hd(decoded["profiles"])["providers"]
    end

    # Hostile review P1-1: keys.json5 AND settings.json5.bak both pre-exist,
    # the personal key's name is absent from the user's keys.json5, and the
    # never-clobbered .bak means no fresh backup — pre-fix the split
    # "succeeded" and the key vanished from every file on disk while two
    # warnings claimed it survived.
    test "the split refuses when a credential would land in NO file" do
      dir = write_v1!(tmp_dir())
      keys = write_keys_file!(dir, "{'work': 'PLACEHOLDER-user-key',}")
      backup = write_backup!(dir, "// an older pre-split backup")

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "no home"
          assert message =~ "split it by hand"
          refute message =~ "PLACEHOLDER"
        end)

      # The existing-keys warning may fire before the refusal; no value
      # ever reaches a log.
      refute logs =~ "PLACEHOLDER"

      # Nothing was written: BOTH inline keys are still in the live file,
      # the user's keys.json5 and the old backup are untouched.
      main = File.read!(paths(dir).main)
      assert main =~ "PLACEHOLDER-work-key"
      assert main =~ "PLACEHOLDER-personal-key"
      assert File.read!(keys) =~ "PLACEHOLDER-user-key"
      assert File.read!(backup) == "// an older pre-split backup"
    end

    test "a pre-existing keys.json5 with a DIFFERENT value refuses the same way" do
      dir = write_v1!(tmp_dir())
      write_keys_file!(dir, "{'work': 'PLACEHOLDER-other',}")
      write_backup!(dir, "// older")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "no home"
      assert File.read!(paths(dir).main) =~ "PLACEHOLDER-work-key"
    end

    # The crash-recovery state must still converge: a partial run already
    # wrote keys.json5 with IDENTICAL values and the backup exists.
    test "identical pre-existing keys with an existing backup converge" do
      dir = write_v1!(tmp_dir())

      write_keys_file!(
        dir,
        "{'work': 'PLACEHOLDER-work-key', 'personal': 'PLACEHOLDER-personal-key',}"
      )

      write_backup!(dir, File.read!(paths(dir).main))

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, decoded} =
               decoded_main(dir)

      assert decoded["configVersion"] == 3
      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
    end

    test "a blank-name profile's key refuses the split when no backup can be written" do
      dir = tmp_dir()

      # The no-apiKey entry walks uncollectable?'s false arm before the
      # nameless key is found.
      write_v1!(
        dir,
        """
        {
          configVersion: 1,
          profiles: [
            { name: 'ok', baseUrl: 'https://provider.example/v1',
              models: [{ model: 'glm-5.3' }] },
            { name: '', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-nameless-key',
              models: [{ model: 'glm-5.3' }] },
          ],
        }
        """
      )

      write_backup!(dir, "// older")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "no home"

      # Pre-fix the nameless key was silently deleted from every file.
      assert File.read!(paths(dir).main) =~ "PLACEHOLDER-nameless-key"

      # With no pre-existing backup the fresh byte-exact copy preserves it.
      other = tmp_dir()

      write_v1!(
        other,
        """
        {
          configVersion: 1,
          profiles: [
            { name: '', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-nameless-key',
              models: [{ model: 'glm-5.3' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(other)
      refute File.read!(paths(other).main) =~ "PLACEHOLDER-nameless-key"
      assert File.read!(paths(other).settings_backup) =~ "PLACEHOLDER-nameless-key"
    end

    # Hostile review P1-2: a ROOT-level apiKey in a v1 file rode into the
    # live v2 settings verbatim and unwarned.
    test "a root-level apiKey is stripped by the split and preserved in the backup" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 1,
          apiKey: 'PLACEHOLDER-root-key',
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      main = File.read!(paths(dir).main)
      refute main =~ "apiKey"
      refute main =~ "PLACEHOLDER-root-key"

      assert {:ok, decoded} = JSON5.decode(main)
      assert decoded["configVersion"] == 3

      assert File.read!(paths(dir).settings_backup) =~ "PLACEHOLDER-root-key"
      assert mode(paths(dir).settings_backup) == 0o600
    end

    # Hostile review P2-1: the legacy crash window (settings written, backup
    # rename never reached) left a 0644 config.json beside a complete layout
    # forever. Tightening happens BEFORE any write, so the failure paths
    # leave it private too.
    test "the legacy file is tightened before the migration writes anything" do
      dir = write_legacy!(tmp_dir(), Map.put(full_legacy(), "api_key", "back\\slash"))
      legacy = Path.join(dir, "config.json")
      File.chmod!(legacy, 0o644)

      assert {:error, _message} = @migration.maybe_migrate(dir)
      assert mode(legacy) == 0o600
    end

    # Hostile review P2-2: a pre-planted keys.json5.tmp symlink was chmod'd
    # and written THROUGH — the victim lost its mode and content, and
    # keys.json5 ended as the symlink itself.
    test "a pre-planted .tmp symlink is refused, never written through" do
      dir = write_v1!(tmp_dir())

      victim = Path.join(dir, "user-notes.txt")
      File.write!(victim, "keep me")
      File.chmod!(victim, 0o644)
      File.ln_s!(victim, Path.join(dir, "keys.json5.tmp"))

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "not a regular file"
          assert message =~ "keys.json5.tmp"
        end)

      assert logs == ""
      assert File.read!(victim) == "keep me"
      assert mode(victim) == 0o644
      refute File.exists?(paths(dir).keys)
      assert File.read!(paths(dir).main) == v1_inline()
    end

    test "regular .tmp crash debris is replaced by the write" do
      dir = write_v1!(tmp_dir())
      tmp = Path.join(dir, "keys.json5.tmp")
      File.write!(tmp, "// debris from an interrupted run")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"}}} =
               decoded_keys(dir)

      refute File.exists?(tmp)
    end

    # Round-2 P1: the no-loss decision must be made from the backup's
    # ACTUAL outcome, not from the .bak's pre-existence — a failing backup
    # write (occupied .bak.tmp) plus a differing key used to "migrate" with
    # the key in no file.
    test "an occupied .bak.tmp with a differing key refuses — the backup's failure feeds the decision" do
      dir = write_v1!(tmp_dir())
      keys = write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-old',}")
      blocked_tmp = Path.join(dir, "settings.json5.bak.tmp")
      File.mkdir!(blocked_tmp)

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "no home"
          refute message =~ "PLACEHOLDER"
        end)

      # No destructive step, and the user's occupied tmp path is untouched.
      assert logs =~ "cannot write settings.json5.bak"
      refute logs =~ "backed up first"
      main = File.read!(paths(dir).main)
      assert main =~ "PLACEHOLDER-work-key"
      assert main =~ "PLACEHOLDER-personal-key"
      assert File.read!(keys) =~ "PLACEHOLDER-work-old"
      assert File.lstat!(blocked_tmp).type == :directory
      refute File.exists?(paths(dir).settings_backup)
    end

    # Round-2 P1-adjacent: duplicate profile names — the loader tolerates
    # the shape, so the migration must account for the second key too.
    defp duplicates_file do
      """
      {
        configVersion: 1,
        profiles: [
          { name: 'work', baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-dup-old',
            models: [{ model: 'glm-5.3' }] },
          { name: 'work', baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-dup-new',
            models: [{ model: 'glm-5.3' }] },
        ],
      }
      """
    end

    test "duplicate-name keys refuse without a backup; both values survive with one" do
      refusing = write_v1!(tmp_dir(), duplicates_file())
      write_backup!(refusing, "// stale")

      assert {:error, message} = @migration.maybe_migrate(refusing)
      assert message =~ "no home"
      # BOTH keys still in the live file — the loser was not silently
      # dropped from disk.
      main = File.read!(paths(refusing).main)
      assert main =~ "PLACEHOLDER-dup-old"
      assert main =~ "PLACEHOLDER-dup-new"

      fresh = write_v1!(tmp_dir(), duplicates_file())

      # The SPLIT succeeds (the loser is homed in the backup), but the v3
      # reshape refuses: one value cannot nest under two endpoints. The
      # chain surfaces the reshape's remedy; nothing is lost either way.
      capture_log(fn ->
        assert {:error, message} = @migration.maybe_migrate(fresh)
        assert message =~ ~s(duplicate profile "work" with a key in keys.json5)
      end)

      assert File.read!(paths(fresh).keys) =~ "PLACEHOLDER-dup-old"
      assert File.read!(paths(fresh).settings_backup) =~ "PLACEHOLDER-dup-new"

      # The remedy: rename one by hand; the re-run migrates.
      {:ok, v2_map} = decoded_main(fresh)

      renamed =
        v2_map
        |> rename_second()
        |> JSON5.render()
        |> unwrap_rendered()

      File.write!(paths(fresh).main, renamed <> "\n")

      assert {:ok, :migrated} = @migration.maybe_migrate(fresh)

      assert {:ok, %{"work" => %{"https://provider.example/v1" => "PLACEHOLDER-dup-old"}}} =
               decoded_keys(fresh)
    end

    # Delta-2 P2: a self-referential .bak symlink made File.read "prove" the
    # values preserved while the rewrite emptied the only real copy — the
    # split migrated and the root key vanished from every file.
    test "a self-referential .bak symlink is kept, not trusted — the split refuses" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 1,
          apiKey: 'PLACEHOLDER-root-key',
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
          ],
        }
        """
      )

      backup = Path.join(dir, "settings.json5.bak")
      main = Path.join(dir, "settings.json5")
      File.ln_s!(main, backup)

      logs =
        capture_log(fn ->
          assert {:error, message} = @migration.maybe_migrate(dir)
          assert message =~ "no home"
        end)

      assert logs =~ "not a regular file"

      # Nothing was destroyed: the live file keeps the key, the link stays a
      # link (never clobbered), no rewrite happened through it.
      assert File.read!(paths(dir).main) =~ "PLACEHOLDER-root-key"

      link = Path.join(dir, "settings.json5.bak")
      assert File.lstat!(link).type == :symlink
      assert File.read!(link) =~ "PLACEHOLDER-root-key"

      # The safe variant keeps working: an OUTSIDE target is kept too, and a
      # split with nothing at risk still completes.
      outside = tmp_dir()

      write_v1!(outside, """
      {
        configVersion: 1,
        profiles: [
          { name: 'work', baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
        ],
      }
      """)

      copy = Path.join(outside, "dotfiles-copy")
      File.write!(copy, File.read!(paths(outside).main))
      File.ln_s!(copy, Path.join(outside, "settings.json5.bak"))

      assert {:ok, :migrated} = @migration.maybe_migrate(outside)

      assert File.read!(paths(outside).keys) =~ "PLACEHOLDER-work-key"
      assert File.read!(copy) =~ "PLACEHOLDER-work-key"

      outside_link = Path.join(outside, "settings.json5.bak")
      assert File.lstat!(outside_link).type == :symlink
    end

    test "adding the missing key to keys.json5 clears the refusal" do
      dir = write_v1!(tmp_dir())
      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-key',}")
      write_backup!(dir, "// stale")

      assert {:error, _message} = @migration.maybe_migrate(dir)

      # The error's own advice: add the keys under their names.
      write_keys_file!(
        dir,
        "{'work': 'PLACEHOLDER-work-key', 'personal': 'PLACEHOLDER-personal-key',}"
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
    end

    test "a byte-identical pre-existing .bak converges instead of refusing (crash recovery)" do
      dir = write_v1!(tmp_dir())
      write_backup!(dir, File.read!(paths(dir).main))

      # Any shape — including the nameless credentials that have no
      # keys.json5 name to be added under.
      root_dir = tmp_dir()

      write_v1!(
        root_dir,
        """
        {
          configVersion: 1,
          apiKey: 'PLACEHOLDER-root-key',
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
          ],
        }
        """
      )

      write_backup!(root_dir, File.read!(paths(root_dir).main))

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      assert {:ok, :migrated} = @migration.maybe_migrate(root_dir)

      refute File.read!(paths(root_dir).main) =~ "PLACEHOLDER-root-key"
      assert File.read!(paths(root_dir).settings_backup) =~ "PLACEHOLDER-root-key"
    end

    test "moving a stale .bak aside lets a fresh backup clear the refusal (documented unblock)" do
      dir = write_v1!(tmp_dir())
      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-old',}")
      stale = write_backup!(dir, "// stale")

      assert {:error, _message} = @migration.maybe_migrate(dir)

      # The error's other documented remedy: move the stale backup aside.
      File.rename!(stale, stale <> ".old")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      # Fresh byte-exact backup now holds both inline values.
      backup = File.read!(paths(dir).settings_backup)
      assert backup =~ "PLACEHOLDER-work-key"
      assert backup =~ "PLACEHOLDER-personal-key"
      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
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

      # The user's keys file is the explicit new home — the SPLIT never
      # rewrites it; the v3 reshape then moves its flat value to the
      # endpoint-keyed shape with a byte-exact keys.json5.bak behind it.
      assert {:ok, %{"work" => %{"https://provider.example/v1" => "PLACEHOLDER-user-key"}}} =
               keys
               |> File.read!()
               |> JSON5.decode()

      refute File.read!(paths(dir).main) =~ "PLACEHOLDER"
      assert File.read!(paths(dir).settings_backup) =~ "PLACEHOLDER-work-key"
      assert File.read!(paths(dir).keys_backup) =~ "PLACEHOLDER-user-key"

      # P3-3: the survival claim is TRUE in this state — no pre-existing
      # .bak, so this split wrote the backup the warning mentions.
      assert logs =~ "already exists"
      assert logs =~ "the current settings.json5 is backed up first"
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

    # P3-3: the warning claims only what is true in this state — no new
    # backup is written; the inline keys' home is the fresh keys.json5.
    test "an existing settings.json5.bak is never clobbered, just tightened" do
      dir = write_v1!(tmp_dir())
      settings_backup = Path.join(dir, "settings.json5.bak")
      File.write!(settings_backup, "// an older pre-split backup")
      File.chmod!(settings_backup, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "no new backup is written"
      assert logs =~ "already exists"
      assert File.read!(settings_backup) == "// an older pre-split backup"
      assert mode(settings_backup) == 0o600
      # The split itself still completes: the inline keys' home is the
      # fresh keys.json5; the old backup keeps its own content.
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
               decoded_main(dir)

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

    test "P1-1 regression: garbage (non-object) entries now REFUSE the chain, byte-unchanged" do
      # Pre-fix these rode through the rewrite verbatim; the hostile
      # review's rule is stricter and loss-free: a non-object entry is
      # unshapeable for v3, and tolerating it through a rewrite is how the
      # map-shaped profiles hole hid. The chain refuses, nothing is
      # written, the credential stays put.
      dir = tmp_dir()

      damaged =
        "{configVersion: 1, profiles: ['not-a-map', {name: 'work', baseUrl: 'https://provider.example/v1', apiKey: 'PLACEHOLDER-work-key'}]}"

      main = Path.join(dir, "settings.json5")
      File.write!(main, damaged)
      File.chmod!(main, 0o600)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "not a shape the v3 migration can represent"
      assert File.read!(main) == damaged
      assert File.read!(main) =~ "PLACEHOLDER-work-key"
      refute File.exists?(paths(dir).keys)
    end
  end

  describe "v3 reshape: v2 profiles → one-provider profiles" do
    defp v2_settings do
      """
      {
        configVersion: 2,
        profiles: [
          {
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            settings: { defaultModel: 'Flash' },
            models: [
              { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
              { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
            ],
          },
          {
            name: 'personal',
            baseUrl: 'https://synthetic.example/openai/v1',
            models: [{ nickname: 'Deep', model: 'hf:deepseek' }],
          },
        ],
      }
      """
    end

    defp v2_keys do
      "{'work': 'PLACEHOLDER-work-key', 'personal': 'PLACEHOLDER-personal-key',}"
    end

    defp v2_dir do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      write_keys_file!(dir, v2_keys())
      dir
    end

    test "a realistic multi-profile v2 directory migrates with every credential in exactly keys[profile][baseUrl]" do
      dir = v2_dir()

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      %{main: main, keys: keys, settings_backup: settings_backup, keys_backup: keys_backup} =
        paths(dir)

      assert {:ok, decoded} = decode_file(main)

      assert decoded["configVersion"] == 3
      # v2's effective default (the first profile) is preserved — no forced
      # selection modal as a migration side effect.
      assert decoded["defaultProfile"] == "work"

      [work, personal] = decoded["profiles"]
      assert work["name"] == "work"

      assert [%{"baseUrl" => "https://provider.example/v1", "models" => models}] =
               work["providers"]

      assert [%{"baseUrl" => "https://synthetic.example/openai/v1"}] = personal["providers"]
      assert work["settings"] == %{"defaultModel" => "Flash"}
      # No label is written — the host default is the point (ADR 0009).
      labelless =
        work["providers"]
        |> hd()
        |> Map.has_key?("label")

      refute labelless

      assert [
               %{"nickname" => "Sol", "model" => "glm-5.3", "context" => 524_288},
               %{"nickname" => "Flash", "model" => "glm-5.3-flash", "context" => 196_608}
             ] = models

      # THE NO-LOSS INVARIANT, v3 arm: every credential value present in
      # EXACTLY the endpoint-keyed slots; none anywhere in live settings.
      assert {:ok,
              %{
                "work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"},
                "personal" => %{
                  "https://synthetic.example/openai/v1" => "PLACEHOLDER-personal-key"
                }
              }} = decode_file(keys)

      live_main = File.read!(main)
      refute live_main =~ "PLACEHOLDER"

      # Backups inherit sensitivity: byte-exact pre-reshape copies at 0600.
      assert File.read!(settings_backup) == v2_settings()
      assert mode(settings_backup) == 0o600
      assert File.read!(keys_backup) == v2_keys()
      assert mode(keys_backup) == 0o600

      # Idempotent: the v3 marker stands the chain down.
      assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
    end

    test "refusal: duplicate v2 profile names with a key — one value cannot nest under two endpoints" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { name: 'work', baseUrl: 'https://one.example/v1', models: [{ model: 'm1' }] },
            { name: 'work', baseUrl: 'https://two.example/v1', models: [{ model: 'm2' }] },
          ],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ ~s(duplicate profile "work" with a key in keys.json5)
      assert message =~ "rename one by hand"

      # Nothing was written.
      assert {:ok, _decoded} = decoded_main(dir)
      assert File.read!(paths(dir).keys) == "{'work': 'PLACEHOLDER-work-key',}"

      # The remedy clears it: rename one by hand, re-run.
      write_v1!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { name: 'work', baseUrl: 'https://one.example/v1', models: [{ model: 'm1' }] },
            { name: 'second', baseUrl: 'https://two.example/v1', models: [{ model: 'm2' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"work" => %{"https://one.example/v1" => "PLACEHOLDER-work-key"}}} =
               decoded_keys(dir)
    end

    test "refusal: a key without a baseUrl has no endpoint to nest under" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{ name: 'work', models: [{ model: 'm1' }] }],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ ~s(profile "work" has a key but no baseUrl)
      assert message =~ "add the baseUrl"
      assert File.read!(paths(dir).keys) == "{'work': 'PLACEHOLDER-work-key',}"
    end

    test "refusal: models without a baseUrl have no provider to live in (env-completed v2)" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{ name: 'work', models: [{ model: 'm1' }] }],
        }
        """
      )

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ ~s(profile "work" has models but no baseUrl)
    end

    test "P1-1 regression: a map-shaped profiles field with inline keys is refused, never emptied" do
      # Reviewer repro A: `profiles` as a MAP (not a list) makes every
      # guard no-op (profiles_list reads []) and the reshape used to write
      # `configVersion: 3, profiles: []` OVER the file — both inline keys
      # vanished from every file on disk, no refusal. Pre-fix this ran to
      # :onboard with the tree gone.
      dir = tmp_dir()
      main = Path.join(dir, "settings.json5")

      damaged =
        "{configVersion: 2, profiles: {work: {baseUrl: 'https://one.example/v1', apiKey: 'PLACEHOLDER-a'}, home: {baseUrl: 'https://two.example/v1', apiKey: 'PLACEHOLDER-b'}}}"

      File.write!(main, damaged)
      File.chmod!(main, 0o600)
      # A stale backup present: pre-fix the chain still wrote over the file.
      write_backup!(dir, "// stale")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "not a shape the v3 migration can represent"
      assert message =~ "profiles must be a list of objects"

      # EVERYTHING byte-unchanged: both credentials still in the live file.
      assert File.read!(main) == damaged
      assert File.read!(main) =~ "PLACEHOLDER-a"
      assert File.read!(main) =~ "PLACEHOLDER-b"
      refute File.exists?(paths(dir).keys)
    end

    test "P1-1 regression: a v3-shaped tree inside a map-shaped profiles is refused" do
      # Reviewer repro B: a full provider tree + mcp + defaultProfile inside
      # a `profiles` map, no configVersion: 3. The tripwire cannot see it
      # (profiles_list reads []); pre-fix the reshape silently emptied it
      # with ZERO warnings.
      dir = tmp_dir()
      main = Path.join(dir, "settings.json5")

      damaged =
        "{defaultProfile: 'work', profiles: {work: {providers: [{baseUrl: 'https://one.example/v1'}], mcp: [{name: 'f', command: 'uvx'}]}}}"

      File.write!(main, damaged)
      File.chmod!(main, 0o600)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "not a shape the v3 migration can represent"
      assert File.read!(main) == damaged
      assert File.read!(main) =~ "https://one.example/v1"
      assert File.read!(main) =~ "mcp"
    end

    test "P1-1 regression: non-object entries and non-list providers/mcp refuse" do
      cases = [
        # a list holding a non-object entry
        "{configVersion: 2, profiles: [{name: 'ok', baseUrl: 'https://one.example/v1'}, 7]}",
        # a list-holding entry with providers as a map
        "{configVersion: 2, profiles: [{name: 'ok', baseUrl: 'https://one.example/v1', providers: {a: 1}}]}",
        # mcp not a list on a v2 entry
        "{configVersion: 2, profiles: [{name: 'ok', baseUrl: 'https://one.example/v1', mcp: 3}]}"
      ]

      for damaged <- cases do
        dir = tmp_dir()
        main = Path.join(dir, "settings.json5")
        File.write!(main, damaged)
        File.chmod!(main, 0o600)

        assert {:error, message} = @migration.maybe_migrate(dir), inspect(damaged)
        assert message =~ "not a shape the v3 migration can represent"
        assert File.read!(main) == damaged, inspect(damaged)
      end
    end

    test "an absent profiles field still reshapes to the empty v3 list (nothing to lose)" do
      dir = tmp_dir()
      write_v1!(dir, "{configVersion: 2, yourName: 'terry-placeholder'}")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"configVersion" => 3, "profiles" => [], "yourName" => "terry-placeholder"}} =
               decoded_main(dir)
    end

    test "refusal: a v3-shaped file without configVersion: 3 trips the ambiguity guard" do
      cases = [
        # A top-level defaultProfile with no marker
        {"{ defaultProfile: 'work', profiles: [{ name: 'work' }] }", "defaultProfile"},
        # A profile-level providers tree with no marker
        {"{ profiles: [{ name: 'work', providers: [{ baseUrl: 'https://provider.example/v1', models: [{ model: 'm1' }] }] }] }",
         "providers"},
        # An mcp list with no marker
        {"{ profiles: [{ name: 'work', mcp: [{ name: 'fetch', command: 'uvx' }] }] }", "mcp"}
      ]

      for {file, _trigger} <- cases do
        dir = tmp_dir()
        write_v1!(dir, file)

        assert {:error, message} = @migration.maybe_migrate(dir)
        assert message =~ "already has the v3 shape"
        assert message =~ "set configVersion: 3 by hand"
      end
    end

    test "refusal: keys.json5 already endpoint-keyed while settings predates v3" do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      write_keys_file!(dir, "{'work': {'https://provider.example/v1': 'PLACEHOLDER-work-key'}}")

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "already endpoint-keyed"
      assert message =~ "set configVersion: 3"
    end

    test "refusal: dead keys may only drop when the keys backup holds them" do
      refusing = tmp_dir()
      write_v1!(refusing, v2_settings())

      write_keys_file!(
        refusing,
        "{'work': 'PLACEHOLDER-work-key', 'ghost': 'PLACEHOLDER-ghost-key'}"
      )

      # A stale keys.json5.bak blocks the fresh backup the drop needs.
      keys_bak = Path.join(refusing, "keys.json5.bak")
      File.write!(keys_bak, "// stale")
      File.chmod!(keys_bak, 0o600)

      assert {:error, message} = @migration.maybe_migrate(refusing)
      assert message =~ "profiles that no longer exist"
      assert message =~ "move a stale keys.json5.bak aside"
      assert File.read!(keys_bak) == "// stale"

      # The remedy: move the stale backup aside; a fresh one holds the dead
      # value, and the drop proceeds.
      File.rename!(keys_bak, keys_bak <> ".old")

      assert {:ok, :migrated} = @migration.maybe_migrate(refusing)

      assert {:ok,
              %{
                "work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"}
              }} = decoded_keys(refusing)

      assert File.read!(keys_bak) =~ "PLACEHOLDER-ghost-key"
    end

    test "junk (non-string) key values warn and drop — they are not credentials" do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-key', 'ghost': 42}")

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ ~s("ghost" holds a non-string value — dropping it as junk)
      assert {:ok, decoded} = decoded_keys(dir)
      refute Map.has_key?(decoded, "ghost")
    end

    test "refusal: an unparseable keys.json5 beside a v2 settings is a loud error" do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{ broken")
      File.chmod!(keys, 0o600)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "invalid JSON5"
      assert message =~ "keys.json5"
      assert File.read!(keys) == "{ broken"
    end

    test "crash debris (settings v3, keys flat) converges on the next load" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            { name: 'work', providers: [{ baseUrl: 'https://provider.example/v1',
              models: [{ model: 'm1' }] }] },
          ],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, :migrated} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "completed an interrupted v3 migration"

      assert {:ok, %{"work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"}}} =
               decoded_keys(dir)

      # Fully-converged: a re-run is a no-op.
      assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
    end

    test "a completed v3 directory with flat keys for several providers warns and moves nothing" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            { name: 'work', providers: [
              { baseUrl: 'https://one.example/v1', models: [{ model: 'm1' }] },
              { baseUrl: 'https://two.example/v1', models: [{ model: 'm2' }] },
            ] },
          ],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-ambiguous',}")

      logs =
        capture_log(fn ->
          assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ "no single provider endpoint — nest it under the baseUrl by hand"
      assert File.read!(paths(dir).keys) == "{'work': 'PLACEHOLDER-ambiguous',}"
    end

    test "a flat key under a profile that does not exist warns and stays" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            { name: 'work', providers: [{ baseUrl: 'https://provider.example/v1',
              models: [{ model: 'm1' }] }] },
          ],
        }
        """
      )

      write_keys_file!(dir, "{'ghost': 'PLACEHOLDER-ghost',}")

      logs =
        capture_log(fn ->
          assert {:ok, :not_needed} = @migration.maybe_migrate(dir)
        end)

      assert logs =~ ~s("ghost" holds a bare key but no profile is named "ghost")
      assert File.read!(paths(dir).keys) == "{'ghost': 'PLACEHOLDER-ghost',}"
    end

    test "finish_partial arms: unparseable keys error, nested values stay, mixed flats merge" do
      # Unparseable keys beside a v3 settings: a loud error, never a guess.
      broken = tmp_dir()

      write_v1!(
        broken,
        "{configVersion: 3, profiles: [{ name: 'work', providers: [{ baseUrl: 'https://one.example/v1' }]}]}"
      )

      write_keys_file!(broken, "{ broken")

      assert {:error, message} = @migration.maybe_migrate(broken)
      assert message =~ "invalid JSON5"

      # A flat value AND a nested value under the same name: the flat moves
      # up (merge), the nested stays.
      mixed = tmp_dir()

      write_v1!(
        mixed,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{ baseUrl: 'https://one.example/v1' }] }],
        }
        """
      )

      write_keys_file!(
        mixed,
        "{'work': {'https://other.example/v1': 'PLACEHOLDER-nested'}, 'work-flat': 'PLACEHOLDER-flat'}"
      )

      write_v1!(
        mixed,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            { name: 'work', providers: [{ baseUrl: 'https://one.example/v1' }] },
            { name: 'work-flat', providers: [{ baseUrl: 'https://flat.example/v1' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(mixed)

      assert {:ok,
              %{
                "work" => %{"https://other.example/v1" => "PLACEHOLDER-nested"},
                "work-flat" => %{"https://flat.example/v1" => "PLACEHOLDER-flat"}
              }} = decoded_keys(mixed)
    end

    test "a keys.json5 holding only blanks is rewritten to the empty v3 shape" do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      write_keys_file!(dir, "{'work': '', 'ghost': null}")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{}} = decoded_keys(dir)
    end

    test "P1-1 regression: a v2 directory with non-object profile entries refuses" do
      dir = tmp_dir()
      damaged = "{configVersion: 2, profiles: [\"garbage\", 7, {}]}"
      main = Path.join(dir, "settings.json5")
      File.write!(main, damaged)
      File.chmod!(main, 0o600)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "not a shape the v3 migration can represent"
      assert File.read!(main) == damaged
    end

    test "a v2 directory with an EMPTY profiles list reshapes to the empty v3 list" do
      # An empty list is a list: nothing to lose, and the marker advances.
      # (defaultProfile stays absent — no addressable profile to name.)
      dir = tmp_dir()
      write_v1!(dir, "{configVersion: 2, profiles: []}")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"configVersion" => 3, "profiles" => []}} = decoded_main(dir)

      {:ok, decoded} = decoded_main(dir)
      refute Map.has_key?(decoded, "defaultProfile")
    end

    test "a v3 profile with junk inside providers skips the junk and moves nothing" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: ['junk', 7] }],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-flat'}")

      logs = capture_log(fn -> assert {:ok, :not_needed} = @migration.maybe_migrate(dir) end)
      assert logs =~ ~s(profile "work" has no single provider endpoint)

      assert {:ok, keys} = decoded_keys(dir)
      assert keys == %{"work" => "PLACEHOLDER-flat"}
    end

    test "a v3 directory with junk entries in profiles skips them; named profiles still move" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: ['junk', 7, { name: 'work', providers: [{ baseUrl: 'https://one.example/v1' }] }],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-flat'}")

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"work" => %{"https://one.example/v1" => "PLACEHOLDER-flat"}}} =
               decoded_keys(dir)
    end

    test "a v2 directory with a NAMELESS map entry skips it for defaultProfile" do
      # Nameless maps ride through (they are objects; load drops them with
      # a warning); the first NAMED profile still becomes defaultProfile.
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { baseUrl: 'https://nameless.example/v1', models: [{ model: 'x' }] },
            { name: 'work', baseUrl: 'https://provider.example/v1', models: [{ model: 'm1' }] },
          ],
        }
        """
      )

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      assert {:ok, %{"defaultProfile" => "work", "profiles" => [_nameless, work]}} =
               decoded_main(dir)

      assert work["name"] == "work"
    end

    test "a v3 profile whose providers is not a list finishes with nothing to move" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          profiles: [{ name: 'work', providers: 'nope' }],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-flat'}")

      logs = capture_log(fn -> assert {:ok, :not_needed} = @migration.maybe_migrate(dir) end)
      assert logs =~ ~s(profile "work" has no single provider endpoint)
    end

    test "a pre-existing keys.json5.bak identical to the current keys counts as preserved" do
      dir = tmp_dir()
      write_v1!(dir, v2_settings())
      write_keys_file!(dir, v2_keys())
      # Simulate the crash state: the backup already holds these exact bytes.
      keys_file = Path.join(dir, "keys.json5")
      backup_file = Path.join(dir, "keys.json5.bak")
      write_keys_file!(dir, v2_keys())
      File.rename!(keys_file, backup_file)
      write_keys_file!(dir, v2_keys())

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)
      assert File.read!(backup_file) == v2_keys()
    end

    test "finish_partial's keys write failure is an error, never a crash" do
      dir = tmp_dir()

      write_v1!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{ baseUrl: 'https://one.example/v1' }] }],
        }
        """
      )

      write_keys_file!(dir, "{'work': 'PLACEHOLDER-flat'}")
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      File.chmod!(dir, 0o500)

      assert {:error, message} = @migration.maybe_migrate(dir)
      assert message =~ "cannot write"
    end

    test "a v1 inline-keys file reaches v3 in ONE load (the chain composes)" do
      dir = write_v1!(tmp_dir())

      assert {:ok, :migrated} = @migration.maybe_migrate(dir)

      {:ok, decoded} = decoded_main(dir)
      assert decoded["configVersion"] == 3
      assert decoded["defaultProfile"] == "work"

      assert {:ok,
              %{
                "work" => %{"https://provider.example/v1" => "PLACEHOLDER-work-key"},
                "personal" => %{"https://provider.example/v1" => "PLACEHOLDER-personal-key"}
              }} = decoded_keys(dir)
    end
  end
end

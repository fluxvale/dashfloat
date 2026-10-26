defmodule DashFloat.ConfigTest do
  @moduledoc false
  # Not async: the load/1 test manipulates process-wide env vars.
  # Placeholders only — never a real key anywhere in this file.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DashFloat.Config

  @tmp_root "/tmp/opencode"

  defp tmp_dir do
    dir = Path.join(@tmp_root, "dashfloat-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(dir, contents) do
    # settings.json5 is credential-free but stays 0600 — free hardening
    # (ADR 0008 keys-split amendment).
    path = Path.join(dir, "settings.json5")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  defp write_keys!(dir, contents) do
    # keys.json5 holds the credentials: every fixture writes it 0600.
    path = Path.join(dir, "keys.json5")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  # The fleet-shaped layout: two profiles on one provider (work/personal),
  # per-profile menus, work defaulting to Flash via settings. The API keys
  # live in keys.json5, keyed by profile name.
  defp fleet_file do
    """
    {
      configVersion: 2,
      yourName: 'terry-placeholder',
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
          baseUrl: 'https://provider.example/v1',
          models: [{ nickname: 'Sol', model: 'glm-5.3', context: 262144 }],
        },
      ],
    }
    """
  end

  defp fleet_keys do
    "{'work': 'PLACEHOLDER-work-key', 'personal': 'PLACEHOLDER-personal-key',}"
  end

  defp fleet_dir do
    dir = tmp_dir()
    write!(dir, fleet_file())
    write_keys!(dir, fleet_keys())
    dir
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  describe "loading the fleet layout" do
    test "first profile is active; its first model is the default; label fields ride along" do
      assert {:ok,
              %Config{
                base_url: "https://provider.example/v1",
                model: "glm-5.3-flash",
                api_key: "PLACEHOLDER-work-key",
                context_tokens: 196_608,
                nickname: "Flash",
                profile: "work"
              }} = Config.load(fleet_dir(), %{}, [])
    end

    test "settings.defaultModel can name the entry by nickname or by model id" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            settings: { defaultModel: 'glm-5.3' },
            models: [
              { nickname: 'Flash', model: 'glm-5.3-flash' },
              { nickname: 'Sol', model: 'glm-5.3' },
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} = Config.load(dir, %{}, [])
    end

    test "a defaultModel that matches nothing warns and falls back to the first entry" do
      dir = tmp_dir()
      main = String.replace(fleet_file(), "defaultModel: 'Flash'", "defaultModel: 'Nope'")
      write!(dir, main)
      write_keys!(dir, fleet_keys())

      logs =
        capture_log(fn ->
          assert {:ok, %Config{nickname: "Sol", model: "glm-5.3"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "defaultModel \"Nope\" matches no model in this profile"
    end

    test "a profile with no models yields nothing but its endpoint; env completes the rest" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:error, "missing provider config: model"} = Config.load(dir, %{}, [])

      assert {:ok, %Config{model: "env-model", profile: "work"}} =
               Config.load(dir, %{"DASHFLOAT_MODEL" => "env-model"}, [])
    end
  end

  describe "two profiles on one provider across the two files (the differentiator)" do
    test "same baseUrl, distinct credentials: each profile selects its own key and menu" do
      dir = fleet_dir()

      assert {:ok, work} = Config.load(dir, %{}, [])
      assert {:ok, personal} = Config.load(dir, %{}, profile: "personal")

      assert %Config{
               base_url: "https://provider.example/v1",
               model: "glm-5.3-flash",
               api_key: "PLACEHOLDER-work-key",
               nickname: "Flash",
               profile: "work",
               context_tokens: 196_608
             } = work

      assert %Config{
               base_url: "https://provider.example/v1",
               model: "glm-5.3",
               api_key: "PLACEHOLDER-personal-key",
               nickname: "Sol",
               profile: "personal",
               context_tokens: 262_144
             } = personal
    end

    test "two profiles with different settings maps select the right setup end to end" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              settings: { defaultModel: 'Sol' },
              models: [
                { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
                { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
              ] },
            { name: 'personal', baseUrl: 'https://provider.example/v1',
              settings: { defaultModel: 'Mini' },
              models: [{ nickname: 'Mini', model: 'glm-5.3-mini', context: 128000 }] },
          ],
        }
        """
      )

      write_keys!(dir, fleet_keys())

      assert {:ok,
              %Config{
                model: "glm-5.3",
                api_key: "PLACEHOLDER-work-key",
                nickname: "Sol",
                profile: "work",
                context_tokens: 524_288
              }} =
               Config.load(dir, %{}, [])

      assert {:ok,
              %Config{
                model: "glm-5.3-mini",
                api_key: "PLACEHOLDER-personal-key",
                nickname: "Mini",
                profile: "personal",
                context_tokens: 128_000
              }} =
               Config.load(dir, %{}, profile: "personal")
    end

    test "a key for a missing profile name in keys.json5 is simply unused" do
      dir = fleet_dir()
      # keys.json5 with a stale extra entry: inert, never an error.
      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key', 'ghost': 'PLACEHOLDER-x',}")

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
    end
  end

  describe "selection precedence: flag > env > file" do
    test "the --profile flag beats DASHFLOAT_PROFILE, which beats the first profile" do
      dir = fleet_dir()

      assert {:ok, %Config{profile: "work"}} = Config.load(dir, %{}, [])

      assert {:ok, %Config{profile: "personal"}} =
               Config.load(dir, %{"DASHFLOAT_PROFILE" => "personal"}, [])

      assert {:ok, %Config{profile: "personal"}} =
               Config.load(dir, %{"DASHFLOAT_PROFILE" => "work"}, profile: "personal")
    end

    test "the --model flag selects by nickname, then by model id, under the active profile" do
      dir = fleet_dir()

      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol", api_key: "PLACEHOLDER-work-key"}} =
               Config.load(dir, %{}, model: "Sol")

      assert {:ok, %Config{model: "glm-5.3-flash", nickname: "Flash"}} =
               Config.load(dir, %{}, model: "glm-5.3-flash")

      assert {:ok,
              %Config{model: "glm-5.3", nickname: "Sol", api_key: "PLACEHOLDER-personal-key"}} =
               Config.load(dir, %{}, profile: "personal", model: "Sol")
    end

    test "a --model miss warns and falls back to the profile default" do
      dir = fleet_dir()

      logs =
        capture_log(fn ->
          assert {:ok, %Config{nickname: "Flash"}} = Config.load(dir, %{}, model: "Ghost")
        end)

      assert logs =~ "--model \"Ghost\" matches no model in this profile"
    end

    test "a flag or env profile that matches no definition warns and is used anyway" do
      dir = fleet_dir()

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: base_url, model, api_key"} =
                   Config.load(dir, %{"DASHFLOAT_PROFILE" => "ghost"}, [])
        end)

      assert logs =~ "profile \"ghost\" (flag or DASHFLOAT_PROFILE) matches no profile"

      flag_logs =
        capture_log(fn ->
          assert {:error, "missing provider config: base_url, model, api_key"} =
                   Config.load(dir, %{}, profile: "ghost")
        end)

      assert flag_logs =~ "profile \"ghost\" (flag or DASHFLOAT_PROFILE) matches no profile"
    end
  end

  describe "field precedence: file < env, per field" do
    test "each env var overrides only its field" do
      dir = fleet_dir()

      env = %{
        "DASHFLOAT_BASE_URL" => "https://env.example/v1",
        "DASHFLOAT_MODEL" => "env-model",
        "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key",
        "DASHFLOAT_CONTEXT_TOKENS" => "100000"
      }

      assert {:ok,
              %Config{
                base_url: "https://env.example/v1",
                model: "env-model",
                api_key: "PLACEHOLDER-env-key",
                context_tokens: 100_000,
                # File vocabulary stays: the entry is still Flash of work.
                nickname: "Flash",
                profile: "work"
              }} = Config.load(dir, env, [])
    end

    test "blank env vars count as absent and fall back to the files" do
      dir = fleet_dir()

      env = %{
        "DASHFLOAT_MODEL" => "   ",
        "DASHFLOAT_API_KEY" => "",
        "DASHFLOAT_CONTEXT_TOKENS" => "  ",
        "DASHFLOAT_PROFILE" => ""
      }

      assert {:ok, config} = Config.load(dir, env, [])

      assert %Config{
               model: "glm-5.3-flash",
               api_key: "PLACEHOLDER-work-key",
               context_tokens: 196_608,
               profile: "work"
             } = config
    end

    test "env alone works without any config files" do
      env = %{
        "DASHFLOAT_BASE_URL" => "https://env.example/v1",
        "DASHFLOAT_MODEL" => "env-model",
        "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
      }

      assert {:ok,
              %Config{
                base_url: "https://env.example/v1",
                model: "env-model",
                api_key: "PLACEHOLDER-env-key",
                nickname: nil,
                profile: nil
              }} = Config.load(tmp_dir(), env, [])
    end

    test "an env key completes a settings-only directory (no keys.json5)" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

      assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])

      assert {:ok, %Config{api_key: "PLACEHOLDER-env-key", nickname: "Sol"}} =
               Config.load(dir, %{"DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"}, [])
    end

    test "an unusable env context is nil, never an error; a blank one falls back" do
      dir = fleet_dir()

      assert {:ok, %Config{context_tokens: nil}} =
               Config.load(dir, %{"DASHFLOAT_CONTEXT_TOKENS" => "nope"}, [])

      assert {:ok, %Config{context_tokens: 196_608}} =
               Config.load(dir, %{"DASHFLOAT_CONTEXT_TOKENS" => ""}, [])
    end

    test "a --model flag with a blank value counts as absent" do
      dir = fleet_dir()
      assert {:ok, %Config{nickname: "Flash"}} = Config.load(dir, %{}, model: "   ")
    end
  end

  describe "keys.json5 resolution" do
    test "an unusable key value is missing, never an error" do
      dir = fleet_dir()
      write_keys!(dir, "{'work': 3, 'personal': 'PLACEHOLDER-personal-key',}")

      assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])

      assert {:ok, %Config{api_key: "PLACEHOLDER-personal-key"}} =
               Config.load(dir, %{}, profile: "personal")
    end

    test "a malformed keys.json5 is a load error naming the file" do
      dir = fleet_dir()
      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',")

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message == "invalid JSON5 in #{Path.join(dir, "keys.json5")}"
      refute message =~ "PLACEHOLDER"
    end

    test "a keys.json5 that is not an object is a load error" do
      dir = fleet_dir()
      write_keys!(dir, "['nope']")

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "expected an object"
    end

    test "a stray inline apiKey is tolerated, warned, and ignored — never a fallback" do
      stray_file = """
      {
        configVersion: 2,
        profiles: [{
          name: 'work',
          baseUrl: 'https://provider.example/v1',
          apiKey: 'PLACEHOLDER-stray',
          models: [{ nickname: 'Sol', model: 'glm-5.3' }],
        }],
      }
      """

      dir = tmp_dir()
      write!(dir, stray_file)
      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ ~s(profile "work": apiKey is ignored — API keys live in keys.json5)
      refute logs =~ "PLACEHOLDER"

      # Without a keys entry the stray value is NOT used — the error names
      # the field, never the value.
      bare_dir = tmp_dir()
      write!(bare_dir, stray_file)

      error_logs =
        capture_log(fn ->
          assert {:error, message} = Config.load(bare_dir, %{}, [])
          assert message =~ "api_key"
          refute message =~ "PLACEHOLDER"
        end)

      assert error_logs =~ "apiKey is ignored"
    end
  end

  describe "missing pieces degrade to field-name errors" do
    test "no file and no env names exactly the missing fields" do
      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(tmp_dir(), %{}, [])
    end

    test "a profile without baseUrl or a keys entry names exactly those fields" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            models: [{ nickname: 'Sol', model: 'glm-5.3', profile: 'work' }],
          }],
        }
        """
      )

      assert {:error, "missing provider config: base_url, api_key"} = Config.load(dir, %{}, [])

      assert {:ok,
              %Config{
                base_url: "https://env.example/v1",
                api_key: "PLACEHOLDER-env-key",
                nickname: "Sol"
              }} =
               Config.load(
                 dir,
                 %{
                   "DASHFLOAT_BASE_URL" => "https://env.example/v1",
                   "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
                 },
                 []
               )
    end
  end

  describe "profile and model addressing edge cases (hostile review)" do
    test "duplicate profile names warn and the first definition wins" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { name: 'work', baseUrl: 'https://first.example/v1',
              models: [{ model: 'm1' }] },
            { name: 'work', baseUrl: 'https://second.example/v1',
              models: [{ model: 'm2' }] },
          ],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-first',}")

      logs =
        capture_log(fn ->
          assert {:ok,
                  %Config{
                    base_url: "https://first.example/v1",
                    api_key: "PLACEHOLDER-first",
                    model: "m1"
                  }} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~ ~s(duplicate profile "work" — keeping the first)
      refute logs =~ "PLACEHOLDER"
    end

    test "--model resolves nickname-then-id when they collide across entries" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [
              { nickname: 'alpha', model: 'beta' },
              { nickname: 'beta', model: 'gamma' },
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      # "beta" is BOTH entry one's model id and entry two's nickname: the
      # nickname is the user-facing address and wins.
      assert {:ok, %Config{model: "gamma", nickname: "beta"}} =
               Config.load(dir, %{}, model: "beta")
    end

    test "a flag/env profile matching nothing warns even with no profiles defined" do
      dir = tmp_dir()

      logs =
        capture_log(fn ->
          env = %{
            "DASHFLOAT_PROFILE" => "ghost",
            "DASHFLOAT_BASE_URL" => "https://env.example/v1",
            "DASHFLOAT_MODEL" => "env-model",
            "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
          }

          assert {:ok, %Config{profile: "ghost"}} = Config.load(dir, env, [])
        end)

      assert logs =~ "profile \"ghost\" (flag or DASHFLOAT_PROFILE) matches no profile"
    end

    test "a --model flag on a profile with no models warns it was discarded" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: model"} = Config.load(dir, %{}, model: "Sol")
        end)

      assert logs =~ ~s(--model "Sol" has no models to select from)
    end

    test "a present-but-unusable defaultModel warns and uses the first entry" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            settings: { defaultModel: 3 },
            models: [{ nickname: 'Sol', model: 'glm-5.3' }, { nickname: 'Flash', model: 'glm-5.3-flash' }],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{nickname: "Sol"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "defaultModel is not a usable nickname"
    end
  end

  describe "malformed and unusual files" do
    test "invalid JSON5 is reported without echoing the file contents" do
      dir = tmp_dir()
      write!(dir, ~s({"apiKey": "PLACEHOLDER-secret",))

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message == "invalid JSON5 in #{Path.join(dir, "settings.json5")}"
      refute message =~ "PLACEHOLDER"
    end

    test "a file that is not an object is reported as invalid" do
      dir = tmp_dir()
      write!(dir, "[1, 2, 3]")

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "expected an object"
    end

    test "an unreadable path is reported, not raised" do
      assert {:error, message} = Config.load("/proc/self/mem", %{}, [])
      assert message =~ "cannot read"
    end

    test "bad entries inside a valid document warn and are skipped" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            'not-a-map',
            { baseUrl: 'https://no-name.example' },
          ],
        }
        """
      )

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: base_url, model, api_key"} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~ "a profile entry that is not an object is ignored"
      assert logs =~ "a profile without a name is ignored"
      refute logs =~ "PLACEHOLDER"
    end

    test "profiles or models that are not lists warn and are ignored" do
      dir = tmp_dir()
      write!(dir, "{ profiles: 'nope' }")

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: base_url, model, api_key"} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~ "profiles must be a list"
    end

    test "a models list that is not a list warns and is ignored for that profile" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: 3,
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: model"} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "models must be a list — ignored"
    end

    test "bad models entries inside a valid profile warn and are skipped" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [
              { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
              { nickname: 'NoModel' },
              'not-a-map',
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "a models entry without a model id is ignored"
      assert logs =~ "a models entry that is not an object is ignored"
    end

    test "an invalid settings map warns and is ignored" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            settings: 'nope',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "settings must be an object — ignored"
    end

    test "unknown settings keys warn by name; values are never logged" do
      dir = tmp_dir()

      main =
        String.replace(
          fleet_file(),
          "settings: { defaultModel: 'Flash' }",
          "settings: { defaultModel: 'Flash', tools: 'dangerous-value' }"
        )

      write!(dir, main)
      write_keys!(dir, fleet_keys())

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3-flash"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "unknown profile settings ignored: tools"
      refute logs =~ "dangerous-value"
      refute logs =~ "PLACEHOLDER"
    end

    test "a newer configVersion warns; an older or absent one is silent" do
      dir = tmp_dir()
      main = String.replace(fleet_file(), "configVersion: 2", "configVersion: 9")
      write!(dir, main)
      write_keys!(dir, fleet_keys())

      logs =
        capture_log(fn ->
          assert {:ok, %Config{}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "configVersion 9 is newer"
    end
  end

  describe "security posture" do
    test "repair happens even when the too-permissive file is also malformed" do
      # The hand-made-file path is exactly this: 0644 with a typo in it. The
      # repair must not depend on the file also being valid JSON5
      # (hostile-review P1).
      dir = tmp_dir()
      main = Path.join(dir, "settings.json5")
      File.write!(main, "{ broken")
      File.chmod!(main, 0o644)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "invalid JSON5"

      assert mode(main) == 0o600
    end

    test "a symlinked settings.json5 warns and never chmods the target" do
      dir = tmp_dir()
      target = Path.join(dir, "real-config")
      File.write!(target, fleet_file())
      File.chmod!(target, 0o644)
      File.ln_s!(target, Path.join(dir, "settings.json5"))
      write_keys!(dir, fleet_keys())

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "is a symlink"

      # The loader does not own the target file — its mode is untouched.
      assert mode(target) == 0o644
    end

    test "a too-permissive settings.json5 is repaired to 0600 with a warning" do
      dir = fleet_dir()
      main = Path.join(dir, "settings.json5")
      File.chmod!(main, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "repairing to 0600"

      assert mode(main) == 0o600
    end

    test "a too-permissive keys.json5 is repaired to 0600 with a warning" do
      dir = fleet_dir()
      keys = Path.join(dir, "keys.json5")
      File.chmod!(keys, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "keys.json5 is too permissive"
      assert mode(keys) == 0o600
    end

    # Hostile review P2-3: invalid UTF-8 raised FunctionClauseError out of
    # Config.load instead of reaching the config-error path.
    test "invalid UTF-8 in keys.json5 is an error, not a crash" do
      dir = fleet_dir()
      keys = Path.join(dir, "keys.json5")
      File.write!(keys, "{'work': 'PLACE\xFFHOLDER',}")
      File.chmod!(keys, 0o600)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message == "invalid JSON5 in #{keys}"
      refute message =~ "PLACE"
    end

    # Hostile review P1-2, loader half: a root-level apiKey in settings is
    # warned about and ignored exactly like a profile-level stray.
    test "a stray top-level apiKey warns and is never used" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          apiKey: 'PLACEHOLDER-stray-root',
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "top-level apiKey is ignored"
      refute logs =~ "PLACEHOLDER"
    end

    # Historical-loss surfacing (round-2 review, incident-hiding note): a
    # profile with no key under its name in an EXISTING keys.json5 warns at
    # load — the shape a lost credential leaves behind. Names only; silent
    # when keys.json5 is absent (env-keyed setups are legitimate).
    test "an unkeyed profile warns at load when keys.json5 exists" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              models: [{ model: 'glm-5.3' }] },
            { name: 'personal', baseUrl: 'https://provider.example/v1',
              models: [{ model: 'glm-5.3' }] },
          ],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])

          assert {:error, message} = Config.load(dir, %{}, profile: "personal")
          assert message =~ "api_key"
        end)

      assert logs =~ ~s(profile "personal" has no key in keys.json5)
      refute logs =~ ~s(profile "work" has no key)
      refute logs =~ "PLACEHOLDER"

      # Delta-2 P3a: the warning respects the loader's own precedence —
      # DASHFLOAT_API_KEY keys the profile, so no nag (pre-fix: warned).
      env = %{"DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"}

      env_logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-env-key"}} =
                   Config.load(dir, env, profile: "personal")
        end)

      assert env_logs == ""

      # No keys.json5 at all → silent (env-keyed setups).
      keys_path = Path.join(dir, "keys.json5")
      File.rm!(keys_path)

      assert capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, env, []) end) == ""
    end

    # Delta-2 P3b: the documented "mv settings.json5.bak aside" unblock must
    # not be able to strand a world-readable credential copy no path
    # tightens — the load repairs the sidecar name.
    test "load tightens a leftover .bak.old sidecar to 0600" do
      dir = fleet_dir()
      sidecar = Path.join(dir, "settings.json5.bak.old")
      File.write!(sidecar, ~s({"apiKey": "PLACEHOLDER-old"}))
      File.chmod!(sidecar, 0o644)

      logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

      assert logs =~ "settings.json5.bak.old is too permissive"
      assert mode(sidecar) == 0o600
    end

    # Hostile review P2-1, load-path half: the legacy migration's crash
    # window leaves a 0644 config.json beside a complete layout — re-runs
    # stand down, so the load itself must converge it to 0600.
    test "load tightens a leftover world-readable config.json (legacy crash state)" do
      dir = fleet_dir()
      legacy = Path.join(dir, "config.json")
      File.write!(legacy, ~s({"api_key": "PLACEHOLDER-legacy"}))
      File.chmod!(legacy, 0o644)

      logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

      assert logs =~ "config.json is too permissive"
      assert mode(legacy) == 0o600
    end

    test "a symlinked keys.json5 warns and never chmods the target" do
      dir = fleet_dir()
      keys = Path.join(dir, "keys.json5")
      File.rm!(keys)

      target = Path.join(dir, "real-keys")
      File.write!(target, fleet_keys())
      File.chmod!(target, 0o644)
      File.ln_s!(target, keys)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "keys.json5 is a symlink"
      assert mode(target) == 0o644
    end

    test "a non-regular keys.json5 is warned about, left alone, and unreadable" do
      dir = fleet_dir()
      keys = Path.join(dir, "keys.json5")
      File.rm!(keys)
      File.mkdir!(keys)
      File.chmod!(keys, 0o700)

      logs =
        capture_log(fn ->
          assert {:error, message} = Config.load(dir, %{}, [])
          assert message =~ "cannot read"
          assert message =~ "keys.json5"
        end)

      assert logs =~ "not a regular file"
      assert File.lstat!(keys).type == :directory
    end

    test "oauth.json5 is posture-only: repaired when present, silent when absent, never read" do
      dir = fleet_dir()
      oauth = Path.join(dir, "oauth.json5")

      # Absent: silent.
      assert capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end) == ""

      # Present, too permissive, and garbage — repaired, never parsed, and
      # the load does not care.
      File.write!(oauth, "{ this is not json5 at all")
      File.chmod!(oauth, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "oauth.json5 is too permissive"
      assert mode(oauth) == 0o600
    end

    test "a leftover too-permissive settings.json5.bak is repaired to 0600" do
      dir = fleet_dir()
      backup = Path.join(dir, "settings.json5.bak")
      File.write!(backup, "// pre-split backup")
      File.chmod!(backup, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "settings.json5.bak"
      assert logs =~ "too permissive"
      assert mode(backup) == 0o600
    end

    test "a UTF-8 BOM is stripped before decoding" do
      dir = tmp_dir()
      write!(dir, "\xEF\xBB\xBF" <> fleet_file())
      write_keys!(dir, fleet_keys())

      assert {:ok, %Config{nickname: "Flash", profile: "work"}} = Config.load(dir, %{}, [])
    end

    test "error messages never contain values that were present" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{ name: 'work', baseUrl: 'https://file.example/v1' }],
        }
        """
      )

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message == "missing provider config: model, api_key"
      refute message =~ "file.example"
    end

    test "Inspect never prints the api key" do
      config = %Config{base_url: "http://x", model: "m", api_key: "PLACEHOLDER-key"}
      refute inspect(config) =~ "PLACEHOLDER-key"
      refute inspect(%{provider: {:ok, config}}) =~ "PLACEHOLDER-key"
    end
  end

  describe "nickname-less and context-less entries" do
    test "a missing nickname falls back to the model id" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [{ model: 'glm-5.3' }],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:ok, %Config{nickname: "glm-5.3", context_tokens: nil}} = Config.load(dir, %{}, [])
    end

    test "unusable context values are nil, never errors" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            models: [{ model: 'a', context: 0 }],
          }],
        }
        """
      )

      write_keys!(dir, "{'work': 'PLACEHOLDER-work-key',}")

      assert {:ok, %Config{model: "a", context_tokens: nil}} = Config.load(dir, %{}, [])
    end
  end

  describe "migration is wired into load" do
    test "a legacy config.json migrates on first load, then loads as the default profile" do
      dir = tmp_dir()

      legacy = Path.join(dir, "config.json")

      File.write!(
        legacy,
        Jason.encode!(%{
          base_url: "https://legacy.example/v1",
          model: "legacy-model",
          api_key: "PLACEHOLDER-legacy-key"
        })
      )

      assert {:ok,
              %Config{
                base_url: "https://legacy.example/v1",
                model: "legacy-model",
                api_key: "PLACEHOLDER-legacy-key",
                nickname: "legacy-model",
                profile: "default"
              }} = Config.load(dir, %{}, [])

      backup = Path.join(dir, "config.json.bak")
      assert File.exists?(backup)

      # The live settings file never holds the credential; keys.json5 does.
      main = Path.join(dir, "settings.json5")
      keys = Path.join(dir, "keys.json5")
      refute File.read!(main) =~ "PLACEHOLDER-legacy-key"
      assert File.read!(keys) =~ "PLACEHOLDER-legacy-key"
      assert mode(main) == 0o600
      assert mode(keys) == 0o600

      # The second load does not migrate again — the marker file exists.
      assert {:ok, %Config{profile: "default"}} = Config.load(dir, %{}, [])

      files = File.ls!(dir)
      assert Enum.count(files, &String.starts_with?(&1, "config.json")) == 1
    end

    test "a v1 inline-keys settings.json5 splits in place on load" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 1,
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key", nickname: "Sol", profile: "work"}} =
               Config.load(dir, %{}, [])

      main = Path.join(dir, "settings.json5")
      refute File.read!(main) =~ "PLACEHOLDER-work-key"
      assert mode(Path.join(dir, "keys.json5")) == 0o600
      assert mode(Path.join(dir, "settings.json5.bak")) == 0o600
    end

    test "no credential material ever lands in the live settings.json5 (both paths)" do
      # Legacy path.
      legacy_dir = tmp_dir()
      legacy_main = Path.join(legacy_dir, "settings.json5")
      legacy_backup = Path.join(legacy_dir, "config.json.bak")
      legacy_source = Path.join(legacy_dir, "config.json")

      File.write!(
        legacy_source,
        Jason.encode!(%{
          base_url: "https://legacy.example/v1",
          model: "legacy-model",
          api_key: "PLACEHOLDER-legacy-key"
        })
      )

      assert {:ok, %Config{api_key: "PLACEHOLDER-legacy-key"}} =
               Config.load(legacy_dir, %{}, [])

      refute File.read!(legacy_main) =~ "PLACEHOLDER-legacy-key"
      assert File.read!(legacy_backup) =~ "PLACEHOLDER-legacy-key"
      assert mode(legacy_backup) == 0o600

      # In-place split path (the realistic v1-migrated directory).
      split_dir = tmp_dir()
      split_main = Path.join(split_dir, "settings.json5")
      split_keys = Path.join(split_dir, "keys.json5")
      split_backup = Path.join(split_dir, "settings.json5.bak")
      old_backup = Path.join(split_dir, "config.json.bak")

      write!(
        split_dir,
        """
        {
          configVersion: 1,
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
            { name: 'personal', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-personal-key',
              models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
          ],
        }
        """
      )

      File.write!(old_backup, ~s({"api_key": "PLACEHOLDER-old"}))
      File.chmod!(old_backup, 0o644)

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(split_dir, %{}, [])

      assert {:ok, %Config{api_key: "PLACEHOLDER-personal-key"}} =
               Config.load(split_dir, %{}, profile: "personal")

      # The LIVE settings file is credential-free...
      refute File.read!(split_main) =~ "PLACEHOLDER"
      # ...while the keys live in keys.json5 and the BY-DESIGN backups hold
      # the old values at 0600 (backups inherit sensitivity — that IS the
      # principle, not a leak).
      assert File.read!(split_keys) =~ "PLACEHOLDER-work-key"
      assert mode(split_keys) == 0o600
      assert mode(split_backup) == 0o600
      assert mode(old_backup) == 0o600
      assert File.read!(split_backup) =~ "PLACEHOLDER-work-key"
    end
  end

  test "load/1 uses the default directory and the real environment" do
    # Point the user-config dir at an empty temp dir, so a real config on the
    # developer's machine cannot make this test pass or fail by accident.
    dir = Path.join(@tmp_root, "xdg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    vars = [
      "XDG_CONFIG_HOME",
      "DASHFLOAT_BASE_URL",
      "DASHFLOAT_MODEL",
      "DASHFLOAT_API_KEY",
      "DASHFLOAT_CONTEXT_TOKENS",
      "DASHFLOAT_PROFILE"
    ]

    saved = Map.new(vars, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(saved, fn {var, value} -> restore(var, value) end) end)

    System.put_env("XDG_CONFIG_HOME", dir)

    for var <- List.delete(vars, "XDG_CONFIG_HOME") do
      System.delete_env(var)
    end

    assert Config.config_dir() == Path.join(dir, "dashfloat")
    assert {:error, "missing provider config: base_url, model, api_key"} = Config.load()
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  # Issue #28 rider, load-path half (review P2c): an ALREADY-migrated
  # directory never runs the migration, so a leftover 0644 config.json.bak
  # (still holding the old credential) was never touched. The load repairs
  # it like every other secrets-bearing file — and never chmods through a
  # symlink.
  test "load repairs a too-permissive leftover config.json.bak to 0600" do
    dir = fleet_dir()
    backup = Path.join(dir, "config.json.bak")
    File.write!(backup, ~s({"api_key": "PLACEHOLDER-old"}))
    File.chmod!(backup, 0o644)

    logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

    assert logs =~ "config.json.bak"
    assert logs =~ "too permissive"

    assert mode(backup) == 0o600
  end

  test "load leaves a 0600 backup alone and a missing one unmentioned" do
    dir = fleet_dir()
    backup = Path.join(dir, "config.json.bak")
    File.write!(backup, ~s({"api_key": "PLACEHOLDER-old"}))
    File.chmod!(backup, 0o600)

    assert capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end) == ""

    File.rm!(backup)
    assert capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end) == ""
  end

  test "load never chmods a symlinked backup through to its target" do
    dir = fleet_dir()

    target = Path.join(dir, "elsewhere.json")
    File.write!(target, ~s({"api_key": "PLACEHOLDER-old"}))
    File.chmod!(target, 0o644)
    File.ln_s!(target, Path.join(dir, "config.json.bak"))

    logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

    assert logs =~ "symlink"

    # The target kept its mode — chmod did not follow the link out.
    assert mode(target) == 0o644
  end

  test "load warns about and never chmods a non-regular backup" do
    dir = fleet_dir()
    backup = Path.join(dir, "config.json.bak")
    File.mkdir!(backup)
    File.chmod!(backup, 0o700)

    logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

    assert logs =~ "not a regular file"

    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(backup)
    assert Bitwise.band(mode, 0o777) == 0o700
  end
end

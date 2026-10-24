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
    # dashfloat.json5 carries secrets: every fixture starts 0600 (ADR 0008).
    path = Path.join(dir, "dashfloat.json5")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  # The fleet-shaped file: two profiles on one provider (work/personal),
  # inline credentials, per-profile menus, work defaulting to Flash via
  # settings.
  defp fleet_file do
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
            { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
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

  defp fleet_dir do
    dir = tmp_dir()
    write!(dir, fleet_file())
    dir
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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            settings: { defaultModel: 'glm-5.3' },
            models: [
              { nickname: 'Flash', model: 'glm-5.3-flash' },
              { nickname: 'Sol', model: 'glm-5.3' },
            ],
          }],
        }
        """
      )

      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} = Config.load(dir, %{}, [])
    end

    test "a defaultModel that matches nothing warns and falls back to the first entry" do
      dir = tmp_dir()
      main = String.replace(fleet_file(), "defaultModel: 'Flash'", "defaultModel: 'Nope'")
      write!(dir, main)

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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
          }],
        }
        """
      )

      assert {:error, "missing provider config: model"} = Config.load(dir, %{}, [])

      assert {:ok, %Config{model: "env-model", profile: "work"}} =
               Config.load(dir, %{"DASHFLOAT_MODEL" => "env-model"}, [])
    end
  end

  describe "two profiles on one provider (the differentiator)" do
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
          profiles: [
            { name: 'work', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-work-key',
              settings: { defaultModel: 'Sol' },
              models: [
                { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
                { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
              ] },
            { name: 'personal', baseUrl: 'https://provider.example/v1',
              apiKey: 'PLACEHOLDER-personal-key',
              settings: { defaultModel: 'Mini' },
              models: [{ nickname: 'Mini', model: 'glm-5.3-mini', context: 128000 }] },
          ],
        }
        """
      )

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

    test "blank env vars count as absent and fall back to the file" do
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

    test "env alone works without a config file" do
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

  describe "missing pieces degrade to field-name errors" do
    test "no file and no env names exactly the missing fields" do
      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(tmp_dir(), %{}, [])
    end

    test "a profile without baseUrl or apiKey names exactly those fields" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
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

  describe "malformed and unusual files" do
    test "invalid JSON5 is reported without echoing the file contents" do
      dir = tmp_dir()
      write!(dir, ~s({"apiKey": "PLACEHOLDER-secret",))

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message == "invalid JSON5 in #{Path.join(dir, "dashfloat.json5")}"
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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: 3,
          }],
        }
        """
      )

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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: [
              { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
              { nickname: 'NoModel' },
              'not-a-map',
            ],
          }],
        }
        """
      )

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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            settings: 'nope',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

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

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3-flash"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "unknown profile settings ignored: tools"
      refute logs =~ "dangerous-value"
      refute logs =~ "PLACEHOLDER"
    end

    test "a newer configVersion warns; an older or absent one is silent" do
      dir = fleet_dir()

      main = String.replace(fleet_file(), "configVersion: 1", "configVersion: 9")
      write!(dir, main)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "configVersion 9 is newer"
    end
  end

  describe "security posture" do
    test "a too-permissive dashfloat.json5 is repaired to 0600 with a warning" do
      dir = fleet_dir()
      main = Path.join(dir, "dashfloat.json5")
      File.chmod!(main, 0o644)

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "repairing to 0600"

      assert {:ok, %File.Stat{mode: mode}} = File.stat(main)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "error messages never contain values that were present" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
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
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: [{ model: 'glm-5.3' }],
          }],
        }
        """
      )

      assert {:ok, %Config{nickname: "glm-5.3", context_tokens: nil}} = Config.load(dir, %{}, [])
    end

    test "unusable context values are nil, never errors" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          profiles: [{
            name: 'work',
            baseUrl: 'https://provider.example/v1',
            apiKey: 'PLACEHOLDER-work-key',
            models: [{ model: 'a', context: 0 }],
          }],
        }
        """
      )

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

      main = Path.join(dir, "dashfloat.json5")
      assert {:ok, %File.Stat{mode: mode}} = File.stat(main)
      assert Bitwise.band(mode, 0o777) == 0o600

      # The second load does not migrate again — the marker file exists.
      assert {:ok, %Config{profile: "default"}} = Config.load(dir, %{}, [])

      files = File.ls!(dir)
      assert Enum.count(files, &String.starts_with?(&1, "config.json")) == 1
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
end

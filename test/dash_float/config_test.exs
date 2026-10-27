defmodule DashFloat.ConfigTest do
  @moduledoc false
  # Not async: the load/1 test manipulates process-wide env vars.
  # Placeholders only — never a real key anywhere in this file.
  # ADR 0009: persona profiles, endpoint-keyed keys.json5, deliberate
  # selection, $ENV_REF values, malformed-config tolerance.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DashFloat.Config
  alias DashFloat.Config.JSON5

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

  @base_url "https://provider.example/v1"

  # The fleet-shaped layout (ADR 0009): two personas on one provider — the
  # v1/v2 differentiator, now expressed as two profiles whose keys nest
  # under the SAME endpoint inside their own names. Work defaults via
  # defaultProfile + defaultProvider + settings.defaultModel.
  defp fleet_file do
    """
    {
      configVersion: 3,
      defaultProfile: 'work',
      yourName: 'terry-placeholder',
      profiles: [
        {
          name: 'work',
          defaultProvider: 'zai',
          providers: [
            {
              label: 'zai',
              baseUrl: '#{@base_url}',
              models: [
                { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
                { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
              ],
            },
          ],
          settings: { defaultModel: 'Flash' },
        },
        {
          name: 'personal',
          providers: [
            {
              baseUrl: '#{@base_url}',
              models: [{ nickname: 'Sol', model: 'glm-5.3', context: 262144 }],
            },
          ],
        },
      ],
    }
    """
  end

  defp fleet_keys do
    """
    {
      work: { '#{@base_url}': 'PLACEHOLDER-work-key' },
      personal: { '#{@base_url}': 'PLACEHOLDER-personal-key' },
    }
    """
  end

  defp fleet_dir do
    dir = tmp_dir()
    write!(dir, fleet_file())
    write_keys!(dir, fleet_keys())
    dir
  end

  defp settings_path(dir), do: Path.join(dir, "settings.json5")
  defp keys_path(dir), do: Path.join(dir, "keys.json5")

  defp read_settings(dir) do
    path = settings_path(dir)
    JSON5.read_map(path)
  end

  defp read_keys(dir) do
    path = keys_path(dir)
    JSON5.read_map(path)
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp snapshot(dir) do
    for name <- ["settings.json5", "keys.json5"],
        path = Path.join(dir, name),
        File.exists?(path),
        into: %{},
        do: {name, File.read!(path)}
  end

  describe "loading the fleet layout" do
    test "defaultProfile is active; its defaultProvider's first model is the default; the provider set rides along" do
      assert {:ok,
              %Config{
                base_url: @base_url,
                model: "glm-5.3-flash",
                api_key: "PLACEHOLDER-work-key",
                context_tokens: 196_608,
                nickname: "Flash",
                profile: "work",
                providers: [%{label: "zai", base_url: @base_url, api_key: "PLACEHOLDER-work-key"}]
              }} = Config.load(fleet_dir(), %{}, [])
    end

    test "settings.defaultModel can name the entry by nickname or by model id" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{
              baseUrl: '#{@base_url}',
              models: [
                { nickname: 'Flash', model: 'glm-5.3-flash' },
                { nickname: 'Sol', model: 'glm-5.3' },
              ],
            }],
            settings: { defaultModel: 'glm-5.3' },
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} = Config.load(dir, %{}, [])
    end

    test "a defaultModel that matches nothing warns and falls back to the first entry" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{
              baseUrl: '#{@base_url}',
              models: [
                { nickname: 'Flash', model: 'glm-5.3-flash' },
                { nickname: 'Sol', model: 'glm-5.3' },
              ],
            }],
            settings: { defaultModel: 'Nope' },
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3-flash", nickname: "Flash"}} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~
               ~s(defaultModel "Nope" matches no model in this profile — using the profile default)
    end

    test "a provider with no models yields nothing but its endpoint; env completes the rest" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{ baseUrl: '#{@base_url}' }] }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      env = %{"DASHFLOAT_MODEL" => "env-model"}

      assert {:ok,
              %Config{base_url: @base_url, model: "env-model", api_key: "PLACEHOLDER-work-key"}} =
               Config.load(dir, env, [])
    end
  end

  describe "two personas on one provider (the differentiator)" do
    test "same baseUrl, distinct credentials: each profile selects its own key and menu" do
      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key", context_tokens: 196_608}} =
               Config.load(fleet_dir(), %{}, profile: "work")

      assert {:ok, %Config{api_key: "PLACEHOLDER-personal-key", context_tokens: 262_144}} =
               Config.load(fleet_dir(), %{}, profile: "personal")
    end

    test "two providers in one profile: defaultProvider addresses the label, menus scope to it" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'personal',
          profiles: [
            {
              name: 'personal',
              defaultProvider: 'synthetic',
              providers: [
                { label: 'zai', baseUrl: 'https://zai.example/api',
                  models: [{ nickname: 'Sol', model: 'glm-5.3' }] },
                { label: 'synthetic', baseUrl: 'https://synthetic.example/openai/v1',
                  models: [{ nickname: 'Deep', model: 'hf:deepseek' }] },
              ],
            },
          ],
        }
        """
      )

      write_keys!(
        dir,
        """
        {
          personal: {
            'https://zai.example/api': 'PLACEHOLDER-zai-key',
            'https://synthetic.example/openai/v1': 'PLACEHOLDER-synthetic-key',
          },
        }
        """
      )

      assert {:ok,
              %Config{
                base_url: "https://synthetic.example/openai/v1",
                model: "hf:deepseek",
                nickname: "Deep",
                api_key: "PLACEHOLDER-synthetic-key",
                providers: providers
              }} = Config.load(dir, %{}, [])

      assert [
               %{label: "zai", api_key: "PLACEHOLDER-zai-key"},
               %{label: "synthetic", api_key: "PLACEHOLDER-synthetic-key"}
             ] = providers

      assert {:ok, %Config{base_url: "https://zai.example/api", model: "glm-5.3"}} =
               Config.load(
                 dir,
                 %{
                   "DASHFLOAT_BASE_URL" => "https://zai.example/api",
                   "DASHFLOAT_MODEL" => "glm-5.3"
                 },
                 []
               )
    end

    test "an unknown defaultProvider warns and falls back to the first provider" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            defaultProvider: 'nope',
            providers: [
              { label: 'first', baseUrl: 'https://first.example/v1', models: [{ model: 'm1' }] },
              { label: 'second', baseUrl: 'https://second.example/v1', models: [{ model: 'm2' }] },
            ],
          }],
        }
        """
      )

      write_keys!(
        dir,
        "{work: {'https://first.example/v1': 'K1', 'https://second.example/v1': 'K2'}}"
      )

      logs =
        capture_log(fn ->
          assert {:ok, %Config{base_url: "https://first.example/v1", model: "m1"}} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~
               ~s(defaultProvider "nope" matches no provider in profile "work" — using the first)
    end

    test "a provider label defaults to the URL host" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [
              { baseUrl: 'https://api.z.ai/api/coding/paas/v4', models: [{ model: 'glm-5.3' }] },
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'https://api.z.ai/api/coding/paas/v4': 'PLACEHOLDER'}}")

      assert {:ok, %Config{providers: [%{label: "api.z.ai"}]}} = Config.load(dir, %{}, [])
    end

    test "a key for a profile that no longer exists in settings is simply unused" do
      dir = fleet_dir()

      # The dead-key mirror of the unkeyed warning: silent for settings
      # truth, surfaced nowhere as an error.
      write_keys!(
        dir,
        """
        {
          work: { '#{@base_url}': 'PLACEHOLDER-work-key' },
          personal: { '#{@base_url}': 'PLACEHOLDER-personal-key' },
          ghost: { '#{@base_url}': 'PLACEHOLDER-ghost-key' },
        }
        """
      )

      assert {:ok, %Config{profile: "work"}} = Config.load(dir, %{}, [])
    end
  end

  describe "deliberate profile selection (ADR 0009)" do
    test "--profile beats DASHFLOAT_PROFILE, which beats defaultProfile" do
      env = %{"DASHFLOAT_PROFILE" => "personal"}

      assert {:ok, %Config{profile: "personal"}} = Config.load(fleet_dir(), env, [])
      assert {:ok, %Config{profile: "work"}} = Config.load(fleet_dir(), env, profile: "work")
      assert {:ok, %Config{profile: "work"}} = Config.load(fleet_dir(), %{}, [])
    end

    test "--profile <unknown> is a hard error listing the valid profile names" do
      assert {:error, message} = Config.load(fleet_dir(), %{}, profile: "nope")
      assert message =~ ~s(profile "nope" matches no profile in settings.json5)
      assert message =~ "valid profiles: work, personal"
      assert is_binary(message)
    end

    test "DASHFLOAT_PROFILE <unknown> errors the same way" do
      assert {:error, message} = Config.load(fleet_dir(), %{"DASHFLOAT_PROFILE" => "ghost"}, [])
      assert message =~ "valid profiles: work, personal"
    end

    test "no defaultProfile, one profile: auto-selected (no modal)" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          profiles: [{
            name: 'solo',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{solo: {'#{@base_url}': 'PLACEHOLDER-solo'}}")

      assert {:ok, %Config{profile: "solo"}} = Config.load(dir, %{}, [])
    end

    test "no defaultProfile, two profiles: the forced-selection classification" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          profiles: [
            { name: 'a', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'b', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm2' }] }] },
          ],
        }
        """
      )

      assert {:select, ["a", "b"]} = Config.load(dir, %{}, [])
    end

    test "an explicit profile still wins over the forced-selection state" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          profiles: [
            { name: 'a', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'b', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm2' }] }] },
          ],
        }
        """
      )

      write_keys!(dir, "{b: {'#{@base_url}': 'PLACEHOLDER-b'}}")

      assert {:ok, %Config{profile: "b", model: "m2"}} = Config.load(dir, %{}, profile: "b")
    end

    test "zero profiles and incomplete env: the onboarding classification" do
      emptied = tmp_dir()
      write!(emptied, "{configVersion: 3, profiles: []}")
      assert :onboard = Config.load(emptied, %{}, [])

      bare = tmp_dir()
      assert :onboard = Config.load(bare, %{}, [])
    end

    test "zero profiles with a complete env boots env-only — never the wizard" do
      env = %{
        "DASHFLOAT_BASE_URL" => @base_url,
        "DASHFLOAT_MODEL" => "env-model",
        "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
      }

      assert {:ok,
              %Config{
                base_url: @base_url,
                model: "env-model",
                api_key: "PLACEHOLDER-env-key",
                providers: []
              }} = Config.load(tmp_dir(), env, [])
    end

    test "an explicit profile with zero profiles stays the env-only regime (v2 parity)" do
      env = %{
        "DASHFLOAT_BASE_URL" => @base_url,
        "DASHFLOAT_MODEL" => "env-model",
        "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
      }

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "env-model"}} =
                   Config.load(tmp_dir(), env, profile: "ghost")
        end)

      assert logs =~ ~s(profile "ghost" \(flag or DASHFLOAT_PROFILE\) matches no profile)
    end
  end

  describe "model selection within the active provider" do
    test "the --model flag selects by nickname, then by model id" do
      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} =
               Config.load(fleet_dir(), %{}, profile: "work", model: "Sol")

      assert {:ok, %Config{model: "glm-5.3", nickname: "Sol"}} =
               Config.load(fleet_dir(), %{}, profile: "work", model: "glm-5.3")
    end

    test "a --model miss warns and falls back to the profile default" do
      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3-flash"}} =
                   Config.load(fleet_dir(), %{}, profile: "work", model: "Nope")
        end)

      assert logs =~
               ~s(--model "Nope" matches no model in this profile — using the profile default)
    end

    test "a --model flag with a blank value counts as absent" do
      assert {:ok, %Config{model: "glm-5.3-flash"}} =
               Config.load(fleet_dir(), %{}, profile: "work", model: "  ")
    end

    test "--model resolves nickname-then-id when they collide across entries" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{
              baseUrl: '#{@base_url}',
              models: [
                { nickname: 'A', model: 'id-one' },
                { nickname: 'id-one', model: 'id-two' },
              ],
            }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      assert {:ok, %Config{model: "id-two", nickname: "id-one"}} =
               Config.load(dir, %{}, model: "id-one")
    end

    test "a --model flag on a provider with no models warns it was discarded" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{ baseUrl: '#{@base_url}' }] }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "env-model"}} =
                   Config.load(dir, %{"DASHFLOAT_MODEL" => "env-model"}, model: "dropped")
        end)

      assert logs =~ ~s(--model "dropped" has no models to select from — ignored)
    end

    test "a present-but-unusable defaultModel warns and uses the first entry" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{
              baseUrl: '#{@base_url}',
              models: [{ nickname: 'Flash', model: 'glm-5.3-flash' }],
            }],
            settings: { defaultModel: 42 },
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "glm-5.3-flash"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "defaultModel is not a usable nickname — using the first entry"
    end
  end

  describe "field precedence: file < env, per field" do
    test "each env var overrides only its field" do
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
                nickname: "Flash",
                profile: "work"
              }} =
               Config.load(fleet_dir(), env, [])
    end

    test "blank env vars count as absent and fall back to the files" do
      env = %{"DASHFLOAT_BASE_URL" => " ", "DASHFLOAT_MODEL" => "", "DASHFLOAT_API_KEY" => ""}

      assert {:ok,
              %Config{
                base_url: @base_url,
                model: "glm-5.3-flash",
                api_key: "PLACEHOLDER-work-key"
              }} = Config.load(fleet_dir(), env, [])
    end

    test "an env key completes a settings-only directory (no keys.json5)" do
      dir = tmp_dir()
      write!(dir, fleet_file())

      assert {:ok, %Config{api_key: "PLACEHOLDER-env-key"}} =
               Config.load(dir, %{"DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"}, [])
    end

    test "an unusable env context is nil, never an error; a blank one falls back" do
      assert {:ok, %Config{context_tokens: nil}} =
               Config.load(fleet_dir(), %{"DASHFLOAT_CONTEXT_TOKENS" => "garbage"}, [])

      assert {:ok, %Config{context_tokens: 196_608}} =
               Config.load(fleet_dir(), %{"DASHFLOAT_CONTEXT_TOKENS" => " "}, [])
    end
  end

  describe "keys.json5 resolution (endpoint-keyed, ADR 0009)" do
    test "a $ENV_VAR value resolves from the environment" do
      dir = fleet_dir()

      write_keys!(
        dir,
        "{work: {'#{@base_url}': '$PLACEHOLDER_WORK_KEY'}}"
      )

      env = %{"PLACEHOLDER_WORK_KEY" => "PLACEHOLDER-work-key"}

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, env, [])
    end

    test "an unset $ENV_VAR warns naming the variable and the field errors as missing" do
      dir = fleet_dir()

      write_keys!(
        dir,
        "{work: {'#{@base_url}': '$PLACEHOLDER_UNSET_KEY'}}"
      )

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "references unset environment variable PLACEHOLDER_UNSET_KEY"
      refute logs =~ "PLACEHOLDER_UNSET_KEY="
    end

    test "a literal that merely starts with $ is not a reference" do
      dir = fleet_dir()

      write_keys!(
        dir,
        ~s({work: {'#{@base_url}': '$2a$10$placeholder-literally-a-bcrypt-shape'}})
      )

      assert {:ok, %Config{api_key: "$2a$10$placeholder-literally-a-bcrypt-shape"}} =
               Config.load(dir, %{}, [])
    end

    test "an unusable key value is missing, never an error" do
      dir = fleet_dir()

      write_keys!(
        dir,
        "{work: {'#{@base_url}': 123}}"
      )

      assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])
    end

    test "a stray inline apiKey is tolerated, warned, and ignored — never a fallback" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            apiKey: 'PLACEHOLDER-stray',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ ~s(profile "work": apiKey is ignored)
    end
  end

  describe "mcp entries (storage shape, ADR 0009)" do
    test "a literal token warns and the entry is ignored; a $REF shape is accepted" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [
              { name: 'good', command: 'uvx', args: ['mcp-server-fetch'], token: '$FETCH_TOKEN' },
              { name: 'bad', command: 'uvx', token: 'a-literal-secret' },
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "an mcp entry with a literal token is ignored"
    end

    test "an mcp entry without a name or command warns and is ignored" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [{ command: 'uvx' }, { name: 'fetch' }, "not-an-object", 7],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn -> Config.load(dir, %{}, []) end)

      assert logs =~ "an mcp entry without a name or command is ignored"
      assert logs =~ "an mcp entry that is not an object is ignored"
    end
  end

  describe "missing pieces degrade to field-name errors" do
    test "no file and no env names exactly the missing fields" do
      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(tmp_dir(), %{}, profile: "ghost")
    end

    test "a provider without a baseUrl or a keys entry names exactly those fields" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{}] }],
        }
        """
      )

      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(dir, %{}, [])
    end
  end

  describe "profile addressing edge cases" do
    test "duplicate profile names warn and the first definition wins" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            { name: 'work', providers: [{ baseUrl: 'https://first.example/v1', models: [{ model: 'first' }] }] },
            { name: 'work', providers: [{ baseUrl: 'https://second.example/v1', models: [{ model: 'second' }] }] },
          ],
        }
        """
      )

      write_keys!(dir, "{work: {'https://first.example/v1': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{base_url: "https://first.example/v1", model: "first"}} =
                   Config.load(dir, %{}, [])
        end)

      assert logs =~ ~s(duplicate profile "work" — keeping the first)
    end
  end

  describe "malformed and unusual files" do
    test "bad entries inside a valid document warn and are skipped" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [
            "not-an-object",
            42,
            { providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'work', providers: ["nope", 3, {}, { baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
          ],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "m1"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "a profile entry that is not an object is ignored"
      assert logs =~ "a profile without a name is ignored"
      assert logs =~ "a providers entry that is not an object is ignored"
      assert logs =~ "a providers entry without a baseUrl is ignored"
    end

    test "profiles or providers that are not lists warn and are ignored" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          profiles: 'nope',
        }
        """
      )

      logs =
        capture_log(fn -> assert :onboard = Config.load(dir, %{}, []) end)

      assert logs =~ "profiles must be a list — ignored"
    end

    test "a models list that is not a list warns and is ignored for that provider" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: 'nope' }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "env-model"}} =
                   Config.load(dir, %{"DASHFLOAT_MODEL" => "env-model"}, [])
        end)

      assert logs =~ "models must be a list — ignored"
    end

    test "bad models entries inside a valid provider warn and are skipped" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: ["nope", {}, { model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{model: "m1"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "a models entry that is not an object is ignored"
      assert logs =~ "a models entry without a model id is ignored"
    end

    test "an invalid settings map warns and is ignored" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            settings: 'nope',
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{model: "m1"}} = Config.load(dir, %{}, []) end)

      assert logs =~ ~s(profile "work": settings must be an object — ignored)
    end

    test "unknown settings keys warn by name; values are never logged" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            settings: { defaultModel: 'm1', secretLooking: 'should-not-print' },
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{model: "m1"}} = Config.load(dir, %{}, []) end)

      assert logs =~ "unknown profile settings ignored: secretLooking"
      refute logs =~ "should-not-print"
    end

    test "a newer configVersion warns; an older one is silent" do
      dir = tmp_dir()
      write!(dir, String.replace(fleet_file(), "configVersion: 3", "configVersion: 9"))
      write_keys!(dir, fleet_keys())

      logs =
        capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)

      assert logs =~ "configVersion 9 is newer than supported 3 — fields may be misread"
    end

    test "a v3 file with a v2-shaped profile baseUrl warns" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            baseUrl: '#{@base_url}',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{model: "m1"}} = Config.load(dir, %{}, []) end)

      assert logs =~ ~s(profile "work": baseUrl at the profile level is v2 shape)
    end
  end

  describe "hand-vandalized configs degrade, never crash (ADR 0009 tolerance)" do
    test "defaultProfile missing is silent and falls to the classification" do
      # One profile: auto-select. Two: forced selection. Missing is OPTIONAL —
      # no warning (that is Terence's scenario minus the deletion mistake).
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          profiles: [
            { name: 'a', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'b', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm2' }] }] },
          ],
        }
        """
      )

      logs = capture_log(fn -> assert {:select, ["a", "b"]} = Config.load(dir, %{}, []) end)
      refute logs =~ "defaultProfile"
    end

    test "defaultProfile not-a-string warns and both classification arms still work" do
      one = tmp_dir()

      write!(
        one,
        """
        {
          configVersion: 3,
          defaultProfile: 42,
          profiles: [{ name: 'solo', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] }],
        }
        """
      )

      write_keys!(one, "{solo: {'#{@base_url}': 'PLACEHOLDER-solo'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{profile: "solo"}} = Config.load(one, %{}, []) end)

      assert logs =~ "defaultProfile is not a string — ignoring it"

      two = tmp_dir()

      write!(
        two,
        """
        {
          configVersion: 3,
          defaultProfile: ['work'],
          profiles: [
            { name: 'a', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'b', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm2' }] }] },
          ],
        }
        """
      )

      logs_two = capture_log(fn -> assert {:select, ["a", "b"]} = Config.load(two, %{}, []) end)
      assert logs_two =~ "defaultProfile is not a string — ignoring it"
    end

    test "defaultProfile unknown warns in both arms (Terence's deleted-key scenario)" do
      # The exact scenario: the default profile name was edited away. The
      # warning says so, and the state machine recovers.
      one = tmp_dir()

      write!(
        one,
        """
        {
          configVersion: 3,
          defaultProfile: 'ghost',
          profiles: [{ name: 'solo', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] }],
        }
        """
      )

      write_keys!(one, "{solo: {'#{@base_url}': 'PLACEHOLDER-solo'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{profile: "solo"}} = Config.load(one, %{}, []) end)

      assert logs =~ ~s(defaultProfile "ghost" matches no profile in settings.json5 — ignoring it)

      two = tmp_dir()

      write!(
        two,
        """
        {
          configVersion: 3,
          defaultProfile: 'ghost',
          profiles: [
            { name: 'a', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] },
            { name: 'b', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm2' }] }] },
          ],
        }
        """
      )

      logs_two = capture_log(fn -> assert {:select, ["a", "b"]} = Config.load(two, %{}, []) end)

      assert logs_two =~
               ~s(defaultProfile "ghost" matches no profile in settings.json5 — ignoring it)
    end

    test "a blank defaultProfile warns" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: '  ',
          profiles: [{ name: 'solo', providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }] }],
        }
        """
      )

      write_keys!(dir, "{solo: {'#{@base_url}': 'PLACEHOLDER-solo'}}")

      logs =
        capture_log(fn -> assert {:ok, %Config{profile: "solo"}} = Config.load(dir, %{}, []) end)

      assert logs =~ "defaultProfile is blank — ignoring it"
    end

    test "an empty profiles list hand-emptied with no env lands in the wizard" do
      dir = tmp_dir()
      write!(dir, "{configVersion: 3, profiles: []}")
      assert :onboard = Config.load(dir, %{}, [])
    end

    test "keys.json5: a profile map that is not an object warns and treats its keys as missing" do
      dir = fleet_dir()
      write_keys!(dir, "{work: 123}")

      logs =
        capture_log(fn ->
          assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])
        end)

      assert logs =~ ~s(keys.json5: "work" is not an object — its keys are unusable)
    end

    test "keys.json5 unparseable is a loud error naming the path and is never overwritten" do
      dir = fleet_dir()
      path = write_keys!(dir, "{work: ")
      before = File.read!(path)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "invalid JSON5"
      assert message =~ path
      assert File.read!(path) == before
    end

    test "settings.json5 unparseable is a loud error naming the path and is never overwritten" do
      dir = tmp_dir()
      path = write!(dir, "{profiles: ")
      before = File.read!(path)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "invalid JSON5"
      assert message =~ path
      assert File.read!(path) == before
    end

    test "a 0-byte settings.json5 is no config: the state machine takes over (no crash)" do
      dir = tmp_dir()
      path = Path.join(dir, "settings.json5")
      File.write!(path, "")
      File.chmod!(path, 0o600)

      assert :onboard = Config.load(dir, %{}, [])
    end

    test "a whitespace-only keys.json5 reads as empty (no crash, no error)" do
      dir = fleet_dir()
      write_keys!(dir, "   \n\t ")

      assert {:error, "missing provider config: api_key"} = Config.load(dir, %{}, [])
    end

    test "loading a damaged-but-parseable v3 directory never rewrites any file" do
      # The whole family's spine: warnings and classification, zero content
      # churn. (finish_partial's crash-debris MOVE is the migration's own
      # warned behavior, not silent load churn — it needs a FLAT STRING
      # value, which this fixture deliberately avoids: every damage here is
      # non-string, so nothing converges or rewrites.)
      dir = fleet_dir()
      write_keys!(dir, "{work: {'#{@base_url}': 123}, personal: 42}")
      before = snapshot(dir)

      capture_log(fn -> Config.load(dir, %{}, []) end)

      assert snapshot(dir) == before
    end
  end

  describe "security posture" do
    test "a symlinked settings.json5 warns and never chmods the target" do
      dir = tmp_dir()
      target = Path.join(dir, "target.json5")
      File.write!(target, fleet_file())
      File.chmod!(target, 0o644)
      File.ln_s!(target, Path.join(dir, "settings.json5"))

      logs = capture_log(fn -> {:error, _error} = Config.load(dir, %{}, []) end)

      assert logs =~ "settings.json5 is a symlink — not repairing permissions"
      assert mode(target) == 0o644
    end

    test "a too-permissive settings.json5 is repaired to 0600 with a warning" do
      dir = fleet_dir()
      path = Path.join(dir, "settings.json5")
      File.chmod!(path, 0o644)

      capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(path) == 0o600
    end

    test "a too-permissive keys.json5 is repaired to 0600 with a warning" do
      dir = fleet_dir()
      path = Path.join(dir, "keys.json5")
      File.chmod!(path, 0o644)

      capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(path) == 0o600
    end

    test "a stray top-level apiKey warns and is never used" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          apiKey: 'PLACEHOLDER-stray',
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      assert logs =~ "top-level apiKey is ignored"
    end

    test "an unkeyed provider warns at load when keys.json5 exists" do
      dir = fleet_dir()

      write_keys!(
        dir,
        "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}"
      )

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
        end)

      # The ACTIVE profile is work: its own provider is keyed. The personal
      # profile's provider is other-persona noise and stays silent; switch
      # profiles and it surfaces.
      refute logs =~ ~s(provider "zai" in profile "work" has no key)

      logs_personal =
        capture_log(fn ->
          assert {:error, _error} = Config.load(dir, %{}, profile: "personal")
        end)

      assert logs_personal =~
               ~s(provider "provider.example" in profile "personal" has no key in keys.json5)
    end

    test "a provider keyed by DASHFLOAT_API_KEY stays silent" do
      dir = tmp_dir()

      write_keys!(
        dir,
        "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}"
      )

      logs =
        capture_log(fn ->
          write!(
            dir,
            String.replace(fleet_file(), ~s/defaultProfile: 'work'/, "defaultProfile: 'personal'")
          )

          assert {:ok, %Config{api_key: "env-key"}} =
                   Config.load(dir, %{"DASHFLOAT_API_KEY" => "env-key"}, [])
        end)

      refute logs =~ "has no key in keys.json5"
    end

    test "silent when keys.json5 is absent (env-keyed setups)" do
      dir = tmp_dir()
      write!(dir, fleet_file())

      logs =
        capture_log(fn ->
          assert {:ok, %Config{api_key: "env-key"}} =
                   Config.load(dir, %{"DASHFLOAT_API_KEY" => "env-key"}, [])
        end)

      refute logs =~ "has no key"
    end

    test "oauth.json5 is posture-only: repaired when present, silent when absent, never read" do
      dir = fleet_dir()
      oauth = Path.join(dir, "oauth.json5")
      File.write!(oauth, "{}")
      File.chmod!(oauth, 0o644)

      logs = capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(oauth) == 0o600
      assert logs =~ "oauth.json5 is too permissive — repairing to 0600"
    end

    test "error messages never contain values that were present" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: [{ baseUrl: 'https://secret-endpoint.example/v1' }] }],
        }
        """
      )

      write_keys!(dir, "{work: {'https://secret-endpoint.example/v1': 'PLACEHOLDER-secret-key'}}")

      logs =
        capture_log(fn ->
          assert {:error, message} = Config.load(dir, %{}, [])
          refute message =~ "PLACEHOLDER-secret-key"
          refute message =~ "secret-endpoint"
        end)

      refute logs =~ "PLACEHOLDER-secret-key"
    end

    test "Inspect never prints the api key (nor the provider set's keys)" do
      assert {:ok, config} = Config.load(fleet_dir(), %{}, [])
      inspected = inspect(config)
      refute inspected =~ "PLACEHOLDER"
      assert inspected =~ "..."
    end
  end

  describe "nickname-less and context-less entries" do
    test "a missing nickname falls back to the model id" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'glm-5.3' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      assert {:ok, %Config{nickname: "glm-5.3"}} = Config.load(dir, %{}, [])
    end

    test "unusable context values are nil, never errors" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{
              baseUrl: '#{@base_url}',
              models: [
                { model: 'a', context: 'garbage' },
                { model: 'b', context: -1 },
                { model: 'c', context: 0 },
              ],
            }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      assert {:ok, %Config{model: "a", context_tokens: nil}} = Config.load(dir, %{}, [])
    end
  end

  describe "parse tolerance arms (ADR 0009)" do
    test "a profile without providers parses to zero providers" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work' }],
        }
        """
      )

      assert {:error, "missing provider config: base_url, model, api_key"} =
               Config.load(dir, %{}, [])
    end

    test "providers/mcp that are not lists warn and are ignored" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{ name: 'work', providers: 'nope', mcp: 7 }],
        }
        """
      )

      logs = capture_log(fn -> assert :onboard != Config.load(dir, %{}, []) end)

      assert logs =~ ~s(profile "work": providers must be a list — ignored)
      assert logs =~ ~s(profile "work": mcp must be a list — ignored)
    end

    test "a base URL without a host uses the whole URL as the label" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: 'not-a-url', models: [{ model: 'm1' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'not-a-url': 'PLACEHOLDER-k'}}")

      assert {:ok, %Config{providers: [%{label: "not-a-url"}]}} = Config.load(dir, %{}, [])
    end

    test "an mcp entry with no token and non-list args parses" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [{ name: 'fetch', command: 'uvx', args: 'nope' }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-k'}}")

      logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)
      assert logs != :error
    end

    test "a string context value parses to an integer window" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1', context: '128000' }] }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-k'}}")

      assert {:ok, %Config{context_tokens: 128_000}} = Config.load(dir, %{}, [])
    end

    test "write_keys_entry under an impossible directory path errors naming it" do
      dir = tmp_dir()
      blocker = Path.join(dir, "a-file")
      File.write!(blocker, "in the way")
      blocked = Path.join([dir, "a-file", "sub"])

      assert {:error, message} = Config.write_keys_entry(blocked, "p", @base_url, "k")
      assert message =~ "cannot create"
      assert message =~ "a-file"
    end

    test "P2-2 regression: an mcp entry whose args holds an object warns and skips, never raises" do
      # Reviewer's 17-shape fuzz crash: to_string/1 on a map raises
      # Protocol.UndefinedError straight out of Config.load. Shape junk
      # NEVER crashes the loader (tolerance principle).
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [{ name: 'obj-args', command: 'c', args: {nested: 1} }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-k'}}")

      logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)
      assert logs =~ "an mcp entry with a non-list args is ignored"

      # A list holding a non-scalar element is the same class.
      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [{ name: 'obj-elem', command: 'c', args: ['ok', {bad: 1}] }],
          }],
        }
        """
      )

      logs_late = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)
      assert logs_late =~ "an mcp entry with a non-scalar arg is ignored"
    end

    test "scalar args (numbers, booleans) stringify; P3-4: only the ACTIVE profile's unkeyed providers warn" do
      dir = fleet_dir()

      # personal is NOT the active profile (defaultProfile: 'work') — its
      # unkeyed provider must stay silent; work is fully keyed.
      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-work-key'}}")

      logs =
        capture_log(fn ->
          assert {:ok, %Config{profile: "work"}} = Config.load(dir, %{}, [])
        end)

      refute logs =~ "has no key in keys.json5"
      refute logs =~ ~s(profile "personal")

      # Make the ACTIVE profile the unkeyed one and it speaks.
      write!(
        dir,
        String.replace(fleet_file(), "defaultProfile: 'work'", "defaultProfile: 'personal'")
      )

      logs_personal =
        capture_log(fn ->
          assert {:error, _missing} = Config.load(dir, %{}, [])
        end)

      assert logs_personal =~ ~s(provider "provider.example" in profile "personal" has no key)
    end

    test "an mcp entry with a non-string token warns; one without args parses" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 3,
          defaultProfile: 'work',
          profiles: [{
            name: 'work',
            providers: [{ baseUrl: '#{@base_url}', models: [{ model: 'm1' }] }],
            mcp: [
              { name: 'numeric', command: 'c', token: 42 },
              { name: 'no-args', command: 'c' },
            ],
          }],
        }
        """
      )

      write_keys!(dir, "{work: {'#{@base_url}': 'PLACEHOLDER-k'}}")

      logs = capture_log(fn -> assert {:ok, %Config{}} = Config.load(dir, %{}, []) end)
      assert logs =~ "an mcp entry with a literal token is ignored"
    end

    test "write_keys_entry on an unwritable directory errors with the path" do
      dir = tmp_dir()
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      File.chmod!(dir, 0o500)

      assert {:error, message} = Config.write_keys_entry(dir, "p", @base_url, "k")
      assert message =~ "cannot write"
      assert message =~ "keys.json5"
      assert message =~ dir
    end
  end

  describe "migration is wired into load" do
    test "a v2 settings + flat keys directory reshapes to v3 on load" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 2,
          profiles: [{
            name: 'work',
            baseUrl: '#{@base_url}',
            models: [{ nickname: 'Sol', model: 'glm-5.3' }],
          }],
        }
        """
      )

      write_keys!(dir, "{work: 'PLACEHOLDER-work-key'}")

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key", model: "glm-5.3"}} =
               Config.load(dir, %{}, [])

      assert {:ok, %{"configVersion" => 3, "defaultProfile" => "work"}} =
               read_settings(dir)
    end

    test "no credential material ever lands in the live settings.json5" do
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 1,
          profiles: [
            { name: 'work', baseUrl: '#{@base_url}', apiKey: 'PLACEHOLDER-work-key',
              models: [{ model: 'm1' }] },
          ],
        }
        """
      )

      {:ok, _config} = Config.load(dir, %{}, [])

      settings = settings_path(dir)
      live = File.read!(settings)
      refute live =~ "PLACEHOLDER"
    end
  end

  describe "onboarding writers (ADR 0009)" do
    test "write_keys_entry merges atomically at 0600 and refuses to clobber damage" do
      dir = tmp_dir()

      assert :ok = Config.write_keys_entry(dir, "personal", @base_url, "PLACEHOLDER-one")

      assert {:ok, %{"personal" => %{@base_url => "PLACEHOLDER-one"}}} =
               read_keys(dir)

      assert :ok =
               Config.write_keys_entry(
                 dir,
                 "personal",
                 "https://other.example/v1",
                 "PLACEHOLDER-two"
               )

      assert {:ok,
              %{
                "personal" => %{
                  @base_url => "PLACEHOLDER-one",
                  "https://other.example/v1" => "PLACEHOLDER-two"
                }
              }} = read_keys(dir)

      keys_file = keys_path(dir)
      assert mode(keys_file) == 0o600

      # A bare value under the profile name is hand damage: refuse, never
      # clobber what might hold a key.
      damaged = tmp_dir()
      write_keys!(damaged, "{personal: 'PLACEHOLDER-flat'}")

      assert {:error, message} =
               Config.write_keys_entry(damaged, "personal", @base_url, "PLACEHOLDER-new")

      assert message =~ ~s("personal" holds a bare value)

      damaged_keys = keys_path(damaged)
      assert File.read!(damaged_keys) == "{personal: 'PLACEHOLDER-flat'}"
    end

    test "write_keys_entry refuses an unparseable keys.json5" do
      dir = tmp_dir()
      keys = keys_path(dir)
      write_keys!(dir, "{nope")
      before = File.read!(keys)

      assert {:error, _write_error} = Config.write_keys_entry(dir, "personal", @base_url, "K")
      assert File.read!(keys) == before
    end

    test "write_keys_entry refuses an unquotable value with the remedy, never the value (issue #39)" do
      dir = tmp_dir()

      for value <- ["k\\1", "both'kinds\"k"] do
        assert {:error, message} = Config.write_keys_entry(dir, "personal", @base_url, value)
        assert message =~ "cannot store that key"
        assert message =~ "backslash or both quote kinds"
        assert message =~ "$ENV_VAR"
        refute message =~ value
      end

      keys = keys_path(dir)
      refute File.exists?(keys)
    end

    test "write_keys_entry names the profile or endpoint when one of those is unquotable (review)" do
      # A quotable value under an unquotable profile name: the remedy must
      # blame the name, not the key the user just typed.
      dir = tmp_dir()

      assert {:error, message} =
               Config.write_keys_entry(dir, "bad\\name", @base_url, "PLACEHOLDER-k")

      assert message =~ "cannot store the profile name or endpoint"
      assert message =~ "backslash or both quote kinds"
      refute message =~ "PLACEHOLDER-k"
      keys = keys_path(dir)
      refute File.exists?(keys)
    end

    test "write_keys_entry blames a pre-existing unquotable value, not the clean entry (issue #42)" do
      # Backslash strings decode (only escaped quotes fail decode), so the
      # file on disk can hold a value the dialect cannot re-emit: the
      # refusal must name the stored value, not the profile/endpoint the
      # user just entered — and the bounced :key screen's hint no longer
      # promises that fixing the typed key fixes the write.
      dir = tmp_dir()
      keys = keys_path(dir)
      write_keys!(dir, "{personal: {'https://other/v1': 'a\\b'}}")

      assert {:error, message} =
               Config.write_keys_entry(dir, "personal", @base_url, "PLACEHOLDER-k")

      assert message =~ "already holds a name or value"
      assert message =~ "backslash or both quote kinds"
      assert message =~ "by hand"
      refute message =~ "profile name or endpoint"
      refute message =~ "PLACEHOLDER-k"
      assert File.read!(keys) == "{personal: {'https://other/v1': 'a\\b'}}"

      # Stored text in any decodable shape blames the file the same way: a
      # value inside a nested list (hand damage), and a stored ENDPOINT KEY
      # — the same honesty gap one level up, never the clean entry's fields.
      write_keys!(dir, "{personal: {'https://other/v1': ['a', 'a\\b']}}")

      assert {:error, nested} =
               Config.write_keys_entry(dir, "personal", @base_url, "PLACEHOLDER-k")

      assert nested =~ "already holds a name or value"

      write_keys!(dir, "{personal: {'https://other/v1': 'k', 'https://bad\\url': 'k2'}}")

      assert {:error, bad_key} =
               Config.write_keys_entry(dir, "personal", @base_url, "PLACEHOLDER-k")

      assert bad_key =~ "already holds a name or value"
      refute bad_key =~ "profile name or endpoint"
      assert File.read!(keys) == "{personal: {'https://other/v1': 'k', 'https://bad\\url': 'k2'}}"

      # The remedy works: fix the file by hand, re-enter the key — it lands
      # beside the repaired entry, both intact.
      File.write!(keys, "{personal: {'https://other/v1': 'ab'}}")

      assert :ok = Config.write_keys_entry(dir, "personal", @base_url, "PLACEHOLDER-k")

      assert {:ok, %{"personal" => merged}} = JSON5.read_map(keys)
      assert merged["https://other/v1"] == "ab"
      assert merged[@base_url] == "PLACEHOLDER-k"
    end

    test "write_settings names model ids and nicknames in the unquotable enumeration (issue #42)" do
      # A backslashed manual model id refuses while every named field is
      # clean: the enumeration must cover model ids and nicknames.
      dir = tmp_dir()

      assert {:error, message} =
               Config.write_settings(dir, %{
                 "configVersion" => 3,
                 "defaultProfile" => "personal",
                 "profiles" => [
                   %{
                     "name" => "personal",
                     "providers" => [
                       %{
                         "label" => "zai",
                         "baseUrl" => @base_url,
                         "models" => [%{"nickname" => "m\\x", "model" => "m\\x"}]
                       }
                     ]
                   }
                 ]
               })

      assert message =~ "cannot store that text"
      assert message =~ "model id"
      assert message =~ "nickname"
      assert message =~ "backslash or both quote kinds"
      settings = settings_path(dir)
      refute File.exists?(settings)
    end

    test "write_settings refuses an unquotable document with the remedy (issue #39)" do
      dir = tmp_dir()

      assert {:error, message} =
               Config.write_settings(dir, %{
                 "configVersion" => 3,
                 "profiles" => [%{"name" => "bad\\name", "providers" => []}]
               })

      assert message =~ "cannot store that text"
      assert message =~ "backslash or both quote kinds"
      settings = settings_path(dir)
      refute File.exists?(settings)
    end

    test "P2-1 regression: write_settings refuses a non-empty existing settings.json5" do
      # The wizard must never clobber what it did not write — an
      # unparseable or hand-made file is the user's to move aside (#31's
      # never-clobber rule, the reviewer's repro).
      dir = tmp_dir()
      settings = settings_path(dir)
      File.write!(settings, "{profiles: broken")
      before = File.read!(settings)

      assert {:error, message} =
               Config.write_settings(dir, %{
                 "configVersion" => 3,
                 "profiles" => [%{"name" => "personal", "providers" => []}]
               })

      assert message =~ "already exists and is not empty"
      assert message =~ "rename it aside"
      assert File.read!(settings) == before

      # A parseable-but-foreign file is equally protected.
      File.write!(settings, "{yourName: 'someone-else'}")

      assert {:error, _refused} =
               Config.write_settings(dir, %{"configVersion" => 3, "profiles" => []})

      assert File.read!(settings) == "{yourName: 'someone-else'}"

      # Empty (crash debris) is the one overwrite the wizard owns.
      File.write!(settings, "")

      assert :ok =
               Config.write_settings(dir, %{
                 "configVersion" => 3,
                 "defaultProfile" => "personal",
                 "profiles" => [%{"name" => "personal", "providers" => []}]
               })
    end

    test "write_settings on an unreadable settings.json5 is a read error naming the path" do
      dir = tmp_dir()
      settings = settings_path(dir)
      File.write!(settings, "{}")
      on_exit(fn -> File.chmod!(settings, 0o600) end)
      File.chmod!(settings, 0o000)

      assert {:error, message} =
               Config.write_settings(dir, %{"configVersion" => 3, "profiles" => []})

      assert message =~ "cannot read"
      assert message =~ "settings.json5"
    end

    test "write_settings writes the wizard's document atomically at 0600" do
      dir = tmp_dir()

      assert :ok =
               Config.write_settings(dir, %{
                 "configVersion" => 3,
                 "defaultProfile" => "personal",
                 "profiles" => [%{"name" => "personal", "providers" => []}]
               })

      assert {:ok, %{"configVersion" => 3, "defaultProfile" => "personal"}} =
               read_settings(dir)

      settings_file = settings_path(dir)
      assert mode(settings_file) == 0o600
    end
  end

  describe "load/1 uses the default directory and the real environment" do
    test "reads XDG_CONFIG_HOME, env completing the pieces" do
      # NEVER the real ~/.config/dashfloat: load/1 would run the real
      # directory's migrations. XDG_CONFIG_HOME points it at a fixture — and
      # the test PROVES the path: config_dir/0 must resolve INSIDE this
      # sandbox, and the load must read the fixture's file (the profile and
      # base_url come from settings.json5; env completes only the model and
      # key). Deleting the fixture changes the outcome — the fleet's guard
      # on the real-dir incident class (hostile review: the previous
      # fixture lived at dir/xdg-root while XDG pointed at dir, so the load
      # never read it and the assertion passed vacuously).
      dir = tmp_dir()
      xdg = Path.join(dir, "xdg-root")
      fixture = Path.join(xdg, "dashfloat")
      File.mkdir_p!(fixture)
      write!(fixture, fleet_file())
      write_keys!(fixture, fleet_keys())

      env = %{
        "DASHFLOAT_MODEL" => "env-model",
        "DASHFLOAT_API_KEY" => "PLACEHOLDER-env-key"
      }

      previous_xdg = System.get_env("XDG_CONFIG_HOME")

      previous =
        for {var, _value} <- env,
            into: %{},
            do: {var, System.get_env(var)}

      try do
        System.put_env("XDG_CONFIG_HOME", xdg)

        for {var, value} <- env, do: System.put_env(var, value)

        assert Config.config_dir() == fixture

        assert {:ok, %Config{model: "env-model", profile: "work", base_url: @base_url}} =
                 Config.load([])

        # And the fixture was load-bearing: without it the same env lands on
        # a different, fileless outcome (env-only — no profile, no file
        # base_url). This is the arm that fails if the path ever stops
        # resolving into the sandbox.
        File.rm_rf!(fixture)
        env_complete = Map.put(env, "DASHFLOAT_BASE_URL", "https://env-only.example/v1")
        for {var, value} <- env_complete, do: System.put_env(var, value)

        assert {:ok, %Config{profile: nil, base_url: "https://env-only.example/v1"}} =
                 Config.load([])
      after
        restore_env("XDG_CONFIG_HOME", previous_xdg)
        for {var, _value} <- env, do: restore_env(var, previous[var])
      end
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)

  describe "load repairs leftovers (posture riders)" do
    test "a too-permissive leftover config.json.bak is repaired to 0600" do
      dir = fleet_dir()
      bak = Path.join(dir, "config.json.bak")
      File.write!(bak, ~s({"api_key": "PLACEHOLDER-old"}))
      File.chmod!(bak, 0o644)

      capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(bak) == 0o600
    end

    test "a leftover keys.json5.bak (the v3 migration's backup) is repaired too" do
      dir = fleet_dir()
      bak = Path.join(dir, "keys.json5.bak")
      File.write!(bak, "{work: 'PLACEHOLDER-old'}")
      File.chmod!(bak, 0o644)

      capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(bak) == 0o600
    end

    test "a 0600 backup is left alone and a missing one unmentioned" do
      dir = fleet_dir()
      bak = Path.join(dir, "settings.json5.bak")
      File.write!(bak, "{}")
      File.chmod!(bak, 0o600)

      logs = capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(bak) == 0o600
      refute logs =~ "settings.json5.bak is too permissive"
    end

    test "never chmods a symlinked backup through to its target" do
      dir = fleet_dir()
      target = Path.join(dir, "target.bak")
      File.write!(target, "{}")
      File.chmod!(target, 0o644)
      File.ln_s!(target, Path.join(dir, "settings.json5.bak"))

      capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert mode(target) == 0o644
    end

    test "warns about and never chmods a non-regular backup" do
      dir = fleet_dir()
      nonregular = Path.join(dir, "config.json.bak")
      File.mkdir_p!(nonregular)

      logs = capture_log(fn -> {:ok, _config} = Config.load(dir, %{}, []) end)
      assert logs =~ "config.json.bak is a directory"
    end
  end

  describe "the v1+interleave recovery path (issue #39)" do
    # A hand-merged file: inline keys (v1) AND a v3-only field. Pre-fix the
    # split wrote configVersion: 2 to disk and the reshape's tripwire then
    # refused advising "set configVersion: 3" — advice that, followed on the
    # now-v2-shaped file, produced a provider-less config with the flat key
    # stranded in keys.json5. The designed end state (ADR 0009 amendment):
    # refuse at the head of the chain, zero writes.
    @interleave "{ profiles: [{ name: 'work', baseUrl: 'https://p.example/v1', apiKey: 'PLACEHOLDER-work-key', models: [{ model: 'm1' }] }], defaultProfile: 'work', }"

    defp dir_snapshot(dir) do
      for name <- File.ls!(dir), path = Path.join(dir, name), into: %{} do
        {:ok, stat} = File.lstat(path)
        {name, {stat.type, snapshot_text(path)}}
      end
    end

    defp snapshot_text(path) do
      case File.read(path) do
        {:ok, text} -> text
        _unreadable -> nil
      end
    end

    test "real load refuses naming both facts, and the directory is byte-identical" do
      dir = tmp_dir()
      write!(dir, @interleave)
      before = dir_snapshot(dir)

      assert {:error, message} = Config.load(dir, %{}, [])

      # Both facts named, the no-write guarantee stated, no value echoed.
      assert message =~ "settings.json5"
      assert message =~ "inline apiKey"
      assert message =~ "v3-only fields"
      assert message =~ "defaultProfile"
      assert message =~ "nothing was written"
      refute message =~ "PLACEHOLDER"

      # Zero writes: every file byte-identical and no new file (no keys.json5,
      # no .bak) — proven on the whole directory, not just settings.json5.
      assert dir_snapshot(dir) == before
    end

    test "the printed remedy converges: remove the field, re-run, the config loads" do
      dir = tmp_dir()
      write!(dir, @interleave)

      assert {:error, _message} = Config.load(dir, %{}, [])

      # Follow the remedy verbatim: delete the v3-only field, re-run.
      edited =
        dir
        |> settings_path()
        |> File.read!()
        |> String.replace(", defaultProfile: 'work'", "")

      settings = settings_path(dir)
      File.write!(settings, edited)

      assert {:ok, config} = Config.load(dir, %{}, [])
      assert %Config{profile: "work", base_url: "https://p.example/v1"} = config
      assert config.api_key == "PLACEHOLDER-work-key"
      assert config.model == "m1"

      # The chain finished v1 → v3 in the re-run: defaultProfile re-derived,
      # keys endpoint-keyed, no credential left in live settings.
      assert {:ok, %{"configVersion" => 3, "defaultProfile" => "work"}} = read_settings(dir)

      assert {:ok, %{"work" => %{"https://p.example/v1" => "PLACEHOLDER-work-key"}}} =
               read_keys(dir)

      live = File.read!(settings)
      refute live =~ "PLACEHOLDER"
    end

    test "mcp with no providers tree is refused at the head; the remedy converges (re-add included)" do
      dir = tmp_dir()

      file =
        "{ profiles: [{ name: 'work', baseUrl: 'https://p.example/v1', apiKey: 'PLACEHOLDER-work-key', models: [{ model: 'm1' }], mcp: [{ name: 'fetch', command: 'uvx' }] }], }"

      write!(dir, file)
      before = dir_snapshot(dir)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "v3-only fields"
      assert message =~ "mcp"
      assert message =~ "nothing was written"
      assert dir_snapshot(dir) == before

      # Follow the remedy verbatim: remove the field, re-run…
      without_mcp = String.replace(file, ", mcp: [{ name: 'fetch', command: 'uvx' }]", "")
      settings = settings_path(dir)
      File.write!(settings, without_mcp)

      assert {:ok, config} = Config.load(dir, %{}, [])
      assert config.api_key == "PLACEHOLDER-work-key"

      # …and re-add what was removed — the migrated v3 file takes the mcp
      # entry back and still loads.
      {:ok, migrated} = read_settings(dir)

      readded =
        put_in(migrated, ["profiles", Access.at(0), "mcp"], [
          %{"name" => "fetch", "command" => "uvx"}
        ])

      {:ok, text} = JSON5.render(readded)

      File.write!(settings, text <> "\n")

      assert {:ok, %Config{api_key: "PLACEHOLDER-work-key"}} = Config.load(dir, %{}, [])
    end

    test "a providers-carrying interleave keeps the marker path — followed, it converges with the tree intact" do
      # Review P1-1: the head-refusal must not fire for a v3-shaped file —
      # the split preserves the provider tree, the flat key nests under its
      # single endpoint, and the tripwire's marker remedy converges. The
      # refusal's removal-remedy would instead invite deleting the authored
      # provider menu.
      dir = tmp_dir()

      write!(
        dir,
        """
        {
          configVersion: 1,
          defaultProfile: 'work',
          profiles: [
            { name: 'work',
              providers: [{ baseUrl: 'https://p.example/v1', models: [{ model: 'm1' }, { model: 'm2' }] }],
              apiKey: 'PLACEHOLDER-work-key' },
          ],
        }
        """
      )

      # The chain splits (writes), then the tripwire refuses with the marker
      # remedy — the sanctioned post-split arm, whose remedy fits this file.
      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "set configVersion: 3 by hand"
      refute message =~ "nothing was written"
      keys = keys_path(dir)
      assert File.exists?(keys)

      # Follow that remedy verbatim.
      settings = settings_path(dir)

      marked =
        settings
        |> File.read!()
        |> String.replace("configVersion: 2", "configVersion: 3")

      File.write!(settings, marked)

      assert {:ok, config} = Config.load(dir, %{}, [])
      assert %Config{profile: "work", base_url: "https://p.example/v1"} = config
      assert config.api_key == "PLACEHOLDER-work-key"

      # The authored two-model menu survived the whole route.
      assert {:ok, %{"profiles" => [%{"providers" => [%{"models" => models}]}]}} =
               read_settings(dir)

      assert Enum.map(models, & &1["model"]) == ["m1", "m2"]

      assert {:ok, %{"work" => %{"https://p.example/v1" => "PLACEHOLDER-work-key"}}} =
               read_keys(dir)
    end

    test "a root-level apiKey interleave is refused with its own converging remedy" do
      # Review round 2, P1-1: a root-level credential has no profile name,
      # so removing the v3-only field alone would strand it in a backup —
      # the message names the move instead.
      dir = tmp_dir()

      file =
        "{ configVersion: 1, apiKey: 'PLACEHOLDER-root-key', defaultProfile: 'work', profiles: [{ name: 'work', baseUrl: 'https://p.example/v1', models: [{ model: 'm1' }] }], }"

      write!(dir, file)
      before = dir_snapshot(dir)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "root-level apiKey"
      assert message =~ "nothing was written"
      assert dir_snapshot(dir) == before

      # Follow the remedy verbatim: move the root key under the profile's
      # name (flat), remove it and the v3-only field, re-run.
      write_keys!(dir, "{work: 'PLACEHOLDER-root-key'}")

      edited =
        file
        |> String.replace("apiKey: 'PLACEHOLDER-root-key', ", "")
        |> String.replace(", defaultProfile: 'work'", "")

      settings = settings_path(dir)
      File.write!(settings, edited)

      assert {:ok, config} = Config.load(dir, %{}, [])
      assert config.api_key == "PLACEHOLDER-root-key"
      assert config.base_url == "https://p.example/v1"

      assert {:ok, %{"configVersion" => 3, "defaultProfile" => "work"}} = read_settings(dir)

      assert {:ok, %{"work" => %{"https://p.example/v1" => "PLACEHOLDER-root-key"}}} =
               read_keys(dir)
    end

    test "a root-level apiKey with several profiles names the profile the reshape will load" do
      # Review round 3, P2-1: "its profile's name" is ambiguous when
      # defaultProfile names a non-first profile — the converging home is
      # the FIRST profile, the one the reshape re-derives as defaultProfile.
      # The message names it explicitly.
      dir = tmp_dir()

      file =
        "{ configVersion: 1, apiKey: 'PLACEHOLDER-root-key', defaultProfile: 'personal', profiles: [{ name: 'work', baseUrl: 'https://one.example/v1', models: [{ model: 'm1' }] }, { name: 'personal', baseUrl: 'https://two.example/v1', models: [{ model: 'm2' }] }], }"

      write!(dir, file)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ ~s(under "work")
      assert message =~ "root-level apiKey"

      # Following it verbatim converges on that profile.
      write_keys!(dir, "{work: 'PLACEHOLDER-root-key'}")

      edited =
        file
        |> String.replace("apiKey: 'PLACEHOLDER-root-key', ", "")
        |> String.replace(", defaultProfile: 'personal'", "")

      settings = settings_path(dir)
      File.write!(settings, edited)

      assert {:ok, config} = Config.load(dir, %{}, [])
      assert config.profile == "work"
      assert config.api_key == "PLACEHOLDER-root-key"
    end

    test "a root-level apiKey with no named profile gets only the by-hand route" do
      # Review round 3, P2-1: profiles: [] has nothing to move the key
      # under and no first profile to re-derive defaultProfile from — the
      # move instruction and the migration promise would both be false.
      dir = tmp_dir()

      file =
        "{ configVersion: 1, apiKey: 'PLACEHOLDER-root-key', defaultProfile: 'ghost', profiles: [], }"

      write!(dir, file)
      before = dir_snapshot(dir)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "nothing was written"
      assert message =~ "reshape it to v3 by hand"
      refute message =~ ~s(under ")
      refute message =~ "re-derives defaultProfile"
      assert dir_snapshot(dir) == before
    end

    test "non-regular files keep the stand-down: no interleave refusal on symlinked layouts" do
      # Review round 1 P1-2 + round 2 P2-1: the refusal shares the split's
      # regular-file precondition. Case A is arm-INeligible (providers tree)
      # and loads through the link exactly as before the fix. Case B is
      # arm-ELIGIBLE (mcp interleave, no providers) — the arm must stay
      # silent there and let the loader produce its own outcome, pinning
      # the gate a dropped regular? guard would silently remove.
      dir_a = tmp_dir()

      write!(
        dir_a,
        """
        {
          defaultProfile: 'work',
          profiles: [
            { name: 'work',
              providers: [{ baseUrl: 'https://p.example/v1', models: [{ model: 'm1' }] }],
              apiKey: 'PLACEHOLDER-leftover-key' },
          ],
        }
        """
      )

      target = Path.join(dir_a, "dotfiles-keys.json5")
      File.write!(target, "{work: {'https://p.example/v1': 'PLACEHOLDER-work-key'}}")
      File.chmod!(target, 0o600)
      File.ln_s!(target, keys_path(dir_a))

      assert {:ok, config} = Config.load(dir_a, %{}, [])
      assert config.api_key == "PLACEHOLDER-work-key"

      keys_a = keys_path(dir_a)
      assert File.lstat!(keys_a).type == :symlink

      dir_b = tmp_dir()

      write!(
        dir_b,
        """
        {
          defaultProfile: 'work',
          profiles: [
            { name: 'work', baseUrl: 'https://p.example/v1',
              apiKey: 'PLACEHOLDER-work-key', models: [{ model: 'm1' }],
              mcp: [{ name: 'fetch', command: 'uvx' }] },
          ],
        }
        """
      )

      other_target = Path.join(dir_b, "dotfiles-keys.json5")
      File.write!(other_target, "{}")
      File.chmod!(other_target, 0o600)
      File.ln_s!(other_target, keys_path(dir_b))

      # The split always stood down for a non-regular keys file; the v2
      # profiles then degrade at load. The interleave refusal must not
      # replace that outcome with its own.
      assert {:error, message} = Config.load(dir_b, %{}, [])
      refute message =~ "v3-only fields"
      assert message =~ "missing provider config"

      keys_b = keys_path(dir_b)
      assert File.lstat!(keys_b).type == :symlink
      assert File.exists?(other_target)
    end
  end

  describe "keys.json5 as a non-regular file" do
    test "a directory named keys.json5 is a loud read error, never clobbered" do
      dir = fleet_dir()
      keys_dir = keys_path(dir)
      File.rm!(keys_dir)
      File.mkdir!(keys_dir)

      assert {:error, message} = Config.load(dir, %{}, [])
      assert message =~ "cannot read"
      assert message =~ "keys.json5"
      assert File.lstat!(keys_dir).type == :directory
    end
  end

  describe "a UTF-8 BOM is stripped before decoding" do
    test "a BOM-prefixed settings.json5 loads" do
      dir = tmp_dir()
      settings = settings_path(dir)
      File.write!(settings, "\xEF\xBB\xBF" <> fleet_file())
      File.chmod!(settings, 0o600)
      write_keys!(dir, fleet_keys())

      assert {:ok, %Config{profile: "work"}} = Config.load(dir, %{}, [])
    end
  end
end

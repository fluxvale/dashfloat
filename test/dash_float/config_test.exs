defmodule DashFloat.ConfigTest do
  @moduledoc false
  # Not async: the load/0 test manipulates process-wide env vars.
  use ExUnit.Case, async: false

  alias DashFloat.Config

  @tmp_dir "/tmp/opencode"

  defp tmp_path do
    path = Path.join(@tmp_dir, "dashfloat-config-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write!(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
    path
  end

  defp full_file do
    %{"base_url" => "https://file.example/v1", "model" => "file-model", "api_key" => "file-key"}
  end

  test "a complete file loads with no env" do
    path = write!(tmp_path(), full_file())

    assert {:ok,
            %Config{base_url: "https://file.example/v1", model: "file-model", api_key: "file-key"}} =
             Config.load(path, %{})
  end

  test "env alone works without a config file" do
    env = %{
      "DASHFLOAT_BASE_URL" => "https://env.example/v1",
      "DASHFLOAT_MODEL" => "env-model",
      "DASHFLOAT_API_KEY" => "env-key"
    }

    assert {:ok,
            %Config{base_url: "https://env.example/v1", model: "env-model", api_key: "env-key"}} =
             Config.load(tmp_path(), env)
  end

  test "env overrides the file per field, leaving the others alone" do
    path = write!(tmp_path(), full_file())
    env = %{"DASHFLOAT_MODEL" => "env-model"}

    assert {:ok,
            %Config{base_url: "https://file.example/v1", model: "env-model", api_key: "file-key"}} =
             Config.load(path, env)
  end

  test "present-and-blank after the merge names exactly the missing fields" do
    path = write!(tmp_path(), %{"base_url" => "https://file.example/v1", "model" => "  "})

    assert {:error, message} = Config.load(path, %{"DASHFLOAT_MODEL" => ""})
    assert message == "missing provider config: model, api_key"
  end

  test "invalid JSON is reported without echoing the file contents" do
    path = tmp_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"api_key": "secret-file-key",))

    assert {:error, message} = Config.load(path, %{})
    assert message =~ "invalid JSON in #{path}:"
    refute message =~ "secret-file-key"
  end

  test "error messages never contain values that were present" do
    path =
      write!(tmp_path(), %{"base_url" => "https://file.example/v1", "api_key" => "test-key-123"})

    assert {:error, message} = Config.load(path, %{})
    assert message == "missing provider config: model"
    refute message =~ "test-key-123"
    refute message =~ "file.example"
  end

  test "a JSON file that is not an object is reported as invalid" do
    path = tmp_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[1, 2, 3]")

    assert {:error, message} = Config.load(path, %{})
    assert message == "invalid JSON in #{path}: expected a JSON object"
  end

  test "an unreadable path is reported, not raised" do
    path = tmp_path()
    File.mkdir_p!(path)
    on_exit(fn -> File.rmdir(path) end)

    assert {:error, message} = Config.load(path, %{})
    assert message =~ "cannot read #{path}:"
  end

  test "a blank env var falls back to the file value" do
    path = write!(tmp_path(), full_file())
    env = %{"DASHFLOAT_MODEL" => "   ", "DASHFLOAT_API_KEY" => ""}

    assert {:ok, %Config{model: "file-model", api_key: "file-key"}} = Config.load(path, env)
  end

  test "trailing whitespace is trimmed from values" do
    path =
      write!(tmp_path(), %{
        "base_url" => "https://file.example/v1\n",
        "model" => "  model  ",
        "api_key" => "file-key\t"
      })

    assert {:ok,
            %Config{base_url: "https://file.example/v1", model: "  model", api_key: "file-key"}} =
             Config.load(path, %{})
  end

  test "Inspect never prints the api key" do
    config = %Config{base_url: "http://x", model: "m", api_key: "test-key-123"}
    refute inspect(config) =~ "test-key-123"
    refute inspect(%{provider: {:ok, config}}) =~ "test-key-123"
  end

  test "load/0 uses the default path and the real environment" do
    # Point the user-config dir at an empty temp dir, so a real config on the
    # developer's machine cannot make this test pass or fail by accident.
    dir = Path.join(@tmp_dir, "xdg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    vars = ["XDG_CONFIG_HOME", "DASHFLOAT_BASE_URL", "DASHFLOAT_MODEL", "DASHFLOAT_API_KEY"]
    saved = Map.new(vars, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(saved, fn {var, value} -> restore(var, value) end) end)

    System.put_env("XDG_CONFIG_HOME", dir)

    for var <- ["DASHFLOAT_BASE_URL", "DASHFLOAT_MODEL", "DASHFLOAT_API_KEY"] do
      System.delete_env(var)
    end

    assert Config.default_path() == Path.join(dir, "dashfloat/config.json")
    assert {:error, "missing provider config: base_url, model, api_key"} = Config.load()
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)
end

defmodule DashFloat.ConfigTest do
  @moduledoc false
  use ExUnit.Case, async: true

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

  test "a non-object JSON file contributes no fields" do
    path = tmp_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[1, 2, 3]")

    assert {:error, "missing provider config: base_url, model, api_key"} =
             Config.load(path, %{})
  end

  test "an unreadable path is reported, not raised" do
    path = tmp_path()
    File.mkdir_p!(path)
    on_exit(fn -> File.rmdir(path) end)

    assert {:error, message} = Config.load(path, %{})
    assert message =~ "cannot read #{path}:"
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

  test "load/0 reads the default path with the real environment" do
    # The path is derived from the user config dir; assert the shape only.
    assert Config.default_path() =~ "dashfloat/config.json"

    original = {System.get_env("DASHFLOAT_MODEL"), System.get_env("DASHFLOAT_BASE_URL")}
    on_exit(fn -> restore_env(original) end)

    System.delete_env("DASHFLOAT_MODEL")
    System.delete_env("DASHFLOAT_BASE_URL")

    assert {:error, message} = Config.load()
    assert message =~ "missing provider config:"
    refute message =~ "test-key-123"
  end

  defp restore_env({model, base_url}) do
    if model,
      do: System.put_env("DASHFLOAT_MODEL", model),
      else: System.delete_env("DASHFLOAT_MODEL")

    if base_url,
      do: System.put_env("DASHFLOAT_BASE_URL", base_url),
      else: System.delete_env("DASHFLOAT_BASE_URL")
  end
end

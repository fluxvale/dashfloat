defmodule DashFloat.ImagesTest do
  @moduledoc false
  # The one owner of the image rules (ADR 0018 §3): allow-list, MIME map,
  # 10 MiB cap, path validation, data-URL encode. Pure File I/O on tmp paths.

  use ExUnit.Case, async: true

  alias DashFloat.Images

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp tmp_path(name) do
    unique = System.unique_integer([:positive])
    dir = Path.join("/tmp/opencode", "dashfloat-images-#{unique}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, name)
  end

  describe "check/1 (the attach prompt's stat-only gate, ADR 0018 §5)" do
    test "a valid image returns its name and size in KB" do
      path = tmp_path("photo.png")
      File.write!(path, @png_bytes)

      assert {:ok, %{name: "photo.png", kb: 1}} = Images.check(path)
    end

    test "a missing file is unreadable, naming the path" do
      path = tmp_path("gone.png")

      assert {:error, msg} = Images.check(path)
      assert msg =~ path
      assert msg =~ "no such file"
    end

    test "a directory is not a regular file, naming the path" do
      path = tmp_path("dir.png")
      File.mkdir_p!(path)

      assert {:error, msg} = Images.check(path)
      assert msg =~ path
      assert msg =~ "not a regular file"
    end

    test "a non-image extension is refused, naming the path and the allow-list" do
      path = tmp_path("notes.txt")
      File.write!(path, "text")

      assert {:error, msg} = Images.check(path)
      assert msg =~ path
      assert msg =~ "not an image extension"
      assert msg =~ ".webp"
    end

    test "the extension check is case-insensitive" do
      path = tmp_path("photo.PNG")
      File.write!(path, @png_bytes)

      assert {:ok, %{name: "photo.PNG"}} = Images.check(path)
    end

    test "a file over the 10 MiB cap is refused, naming the path and the size" do
      path = tmp_path("big.png")
      File.write!(path, String.duplicate("x", 10 * 1024 * 1024 + 1))

      assert {:error, msg} = Images.check(path)
      assert msg =~ path
      assert msg =~ "#{10 * 1024 * 1024 + 1} bytes exceeds the 10 MiB image cap"
    end

    test "a file exactly at the 10 MiB cap passes" do
      path = tmp_path("exact.png")
      File.write!(path, String.duplicate("x", 10 * 1024 * 1024))

      assert {:ok, %{kb: kb}} = Images.check(path)
      assert kb == 10 * 1024
    end
  end

  describe "data_url/1 (the agent's submit-time encode, ADR 0018 §6)" do
    test "encodes the bytes into a data URL with the extension's MIME" do
      path = tmp_path("pic.png")
      File.write!(path, @png_bytes)

      assert {:ok, "data:image/png;base64," <> payload} = Images.data_url(path)
      assert Base.decode64!(payload) == @png_bytes
    end

    test "all three jpg spellings encode as image/jpeg" do
      for name <- ["a.jpg", "b.jpeg", "c.JPG"] do
        path = tmp_path(name)
        File.write!(path, "jpeg")

        assert {:ok, "data:image/jpeg;base64," <> payload} = Images.data_url(path)
        assert Base.decode64!(payload) == "jpeg"
      end
    end

    test "gif and webp carry their own MIME types" do
      for {name, mime} <- [{"a.gif", "image/gif"}, {"b.webp", "image/webp"}] do
        path = tmp_path(name)
        File.write!(path, "x")

        prefix = "data:#{mime};base64,"
        assert {:ok, url} = Images.data_url(path)
        assert String.starts_with?(url, prefix)

        "data:" <> ^mime <> ";base64," <> payload = url
        assert Base.decode64!(payload) == "x"
      end
    end

    test "every check/1 refusal is a data_url/1 refusal too" do
      missing = tmp_path("missing.png")
      assert {:error, _msg} = Images.data_url(missing)

      dir = tmp_path("dir.gif")
      File.mkdir_p!(dir)
      assert {:error, msg} = Images.data_url(dir)
      assert msg =~ "not a regular file"

      txt = tmp_path("notes.md")
      File.write!(txt, "text")
      assert {:error, msg} = Images.data_url(txt)
      assert msg =~ "not an image extension"

      big = tmp_path("big.gif")
      File.write!(big, String.duplicate("x", 10 * 1024 * 1024 + 1))
      assert {:error, msg} = Images.data_url(big)
      assert msg =~ "exceeds the 10 MiB image cap"
    end

    test "a validated file whose bytes cannot be read refuses naming the path" do
      path = tmp_path("secret.png")
      File.write!(path, @png_bytes)
      File.chmod!(path, 0o000)

      assert {:error, msg} = Images.data_url(path)
      assert msg =~ path
      assert msg =~ "permission denied"
    end
  end
end

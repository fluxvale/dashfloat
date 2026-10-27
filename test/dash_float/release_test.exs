defmodule DashFloat.ReleaseTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # DASHFLOAT_LIBSCTP is VM-global: every test starts from it unset and puts
  # back whatever the shell had.
  setup do
    previous = System.get_env("DASHFLOAT_LIBSCTP")
    System.delete_env("DASHFLOAT_LIBSCTP")

    on_exit(fn ->
      if previous,
        do: System.put_env("DASHFLOAT_LIBSCTP", previous),
        else: System.delete_env("DASHFLOAT_LIBSCTP")
    end)

    :ok
  end

  test "copies an explicit source into lib/sctp/libsctp.so.1 and returns the release" do
    source = tmp_path("source")
    File.write!(source, "fake libsctp")
    release = tmp_release()
    bundled = Path.join([release.path, "lib", "sctp", "libsctp.so.1"])

    assert DashFloat.Release.bundle_sctp(release, source) == release
    assert File.read!(bundled) == "fake libsctp"
    # LGPL-2.1+: the licence ships with the redistributed library.
    license = Path.join(release.path, "lib/sctp/COPYING")
    assert File.exists?(license)
  end

  # A rebuild without a library must not keep exporting a stale one: env.sh
  # exports the directory whenever it exists.
  test "a rebuild with no source removes a previously bundled library" do
    source = tmp_path("source")
    File.write!(source, "fake libsctp")
    release = tmp_release()
    sctp_dir = Path.join(release.path, "lib/sctp")

    DashFloat.Release.bundle_sctp(release, source)
    lib = Path.join(sctp_dir, "libsctp.so.1")
    assert File.exists?(lib)

    assert DashFloat.Release.bundle_sctp(release, "/nonexistent/libsctp.so.1") == release
    refute File.exists?(sctp_dir)
  end

  test "a missing explicit source leaves the release untouched" do
    release = tmp_release()
    sctp_dir = Path.join(release.path, "lib/sctp")

    assert DashFloat.Release.bundle_sctp(release, "/nonexistent/libsctp.so.1") == release
    refute File.exists?(sctp_dir)
  end

  test "a DASHFLOAT_LIBSCTP pointing at a missing path leaves the release untouched" do
    System.put_env("DASHFLOAT_LIBSCTP", "/nonexistent/libsctp.so.1")
    release = tmp_release()
    sctp_dir = Path.join(release.path, "lib/sctp")

    assert DashFloat.Release.bundle_sctp(release) == release
    refute File.exists?(sctp_dir)
  end

  # Also exercises the known-system-paths scan, which finds nothing on hosts
  # without libsctp; where a system library exists it is bundled, so no
  # directory assertion here.
  test "with no source anywhere it returns the release" do
    release = tmp_release()

    assert DashFloat.Release.bundle_sctp(release) == release
  end

  defp tmp_release do
    path = tmp_path("release")
    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf!(path) end)

    %{path: path}
  end

  defp tmp_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "dashfloat-release-test-#{kind}-#{System.unique_integer([:positive])}"
    )
  end
end

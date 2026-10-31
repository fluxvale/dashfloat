defmodule DashFloat.UpdateTest do
  @moduledoc false
  # The hermetic update suite (ADR 0026): every HTTP arm — the GitHub API
  # check and the tarball/checksums downloads — runs against the loopback
  # standin, never the network. async: true is safe: each test owns its
  # standin, tmp_dir, and ports.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DashFloat.Update
  alias DashFloat.UpdateStandin

  @target "x86_64-unknown-linux-gnu"
  @latest "9.9.9"

  # -- helpers ----------------------------------------------------------------

  defp standin do
    {:ok, standin} = UpdateStandin.start_link()
    standin
  end

  # A check-shaped release: the API record alone, no assets — checks never
  # look at them.
  defp check_release(standin, tag),
    do: UpdateStandin.set_release(standin, %{"tag_name" => tag, "assets" => []})

  # A release tarball whose bin/dashfloat is a real executable answering
  # `--version` with `version` — the smoke target. `script` replaces the
  # stub's body (the smoke-failure arms); `no_exec` strips the exec bit (the
  # launcher that cannot start at all).
  defp tarball(tmp, version, script, no_exec) do
    bin_dir = Path.join([tmp, "src", version, "bin"])
    File.mkdir_p!(bin_dir)
    bin = Path.join(bin_dir, "dashfloat")
    File.write!(bin, script || "#!/bin/sh\necho dashfloat #{version}\n")
    File.chmod!(bin, if(no_exec, do: 0o644, else: 0o755))

    tgz = Path.join(tmp, "rel-#{version}.tar.gz")
    archive = String.to_charlist(tgz)
    stored = String.to_charlist(bin)

    :ok = :erl_tar.create(archive, [{~c"bin/dashfloat", stored}], [:compressed])
    File.read!(tgz)
  end

  defp sha(bytes) do
    hash = :crypto.hash(:sha256, bytes)
    Base.encode16(hash, case: :lower)
  end

  # Arms the standin as a full release of `tag`: API record + tarball +
  # checksums. `tamper` swaps the served tarball bytes (the corruption arm);
  # `sums` overrides the checksums file; `script` changes the stub the
  # tarball carries.
  defp arm_release(standin, tag, tmp, opts \\ []) do
    base = UpdateStandin.base(standin)
    version = String.trim_leading(tag, "v")
    asset = "dashfloat-#{version}-#{@target}.tar.gz"
    sums = "dashfloat-#{version}-sha256sums.txt"

    bytes =
      Keyword.get(opts, :tarball) || tarball(tmp, version, opts[:script], opts[:no_exec] || false)

    served = Keyword.get(opts, :tamper, bytes)
    sums_body = Keyword.get(opts, :sums) || "#{sha(bytes)}  #{asset}\n"

    UpdateStandin.serve(standin, "/download/#{asset}", served)
    UpdateStandin.serve(standin, "/download/#{sums}", sums_body)
    served_release(standin, base, asset, sums)
    %{asset: asset, sums: sums}
  end

  defp served_release(standin, base, asset, sums) do
    version =
      asset
      |> String.replace_prefix("dashfloat-", "")
      |> String.replace_suffix("-#{@target}.tar.gz", "")

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v" <> version,
      "assets" => [
        %{"name" => asset, "browser_download_url" => "#{base}/download/#{asset}"},
        %{"name" => sums, "browser_download_url" => "#{base}/download/#{sums}"}
      ]
    })
  end

  # The install.sh layout on disk: versions/0.4.0 behind a `current`
  # symlink (ADR 0010). Returns {home, running_dir, new_dir} — the fixture's
  # old release, and where an update would install the latest.
  defp script_home(tmp) do
    home = Path.join(tmp, "dashfloat")
    versions = Path.join(home, "versions")
    running = Path.join(versions, "0.4.0")
    bin_dir = Path.join(running, "bin")

    File.mkdir_p!(bin_dir)
    bin = Path.join(bin_dir, "dashfloat")
    File.write!(bin, "#!/bin/sh\necho dashfloat 0.4.0\n")
    File.chmod!(bin, 0o755)
    File.ln_s!(running, Path.join(home, "current"))

    {home, running, Path.join(versions, @latest)}
  end

  defp run(argv, standin, extra),
    do: Update.run(argv, [api_base: UpdateStandin.base(standin), timeout: 2_000] ++ extra)

  # Runs the command with both output streams captured; returns
  # {exit_code, all_output} (stdout and stderr interleaved for matching).
  defp run_captured(argv, standin, extra \\ []) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, run(argv, standin, extra)}) end)
        send(parent, {:stdout, stdout})
      end)

    code =
      receive do
        {:code, code} -> code
      after
        1_000 -> nil
      end

    stdout =
      receive do
        {:stdout, stdout} -> stdout
      after
        0 -> ""
      end

    {code, stdout <> "\n" <> stderr}
  end

  defp current_points_at(home) do
    current = Path.join(home, "current")

    case File.read_link(current) do
      {:ok, target} -> target
      _other -> nil
    end
  end

  # -- the check -------------------------------------------------------------

  test "--check on the latest version prints it and exits 0" do
    standin = standin()
    check_release(standin, "v#{DashFloat.version()}")

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 0
    # The hyphen form pins the ASCII-only output rule (ADR 0026): on OTP 29
    # a binwrite of non-ASCII under a UTF-8 locale double-encodes, and the
    # puts path escapes under a C locale — ASCII is the only form correct
    # in every locale.
    assert out =~ "- the latest release"
  end

  test "--check on an outdated copy names the latest and exits 1" do
    standin = standin()
    check_release(standin, "v#{@latest}")

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 1
    assert out =~ "v#{@latest}"
    assert out =~ "update with: dashfloat update"
  end

  test "--check on a build newer than the latest exits 0" do
    standin = standin()
    check_release(standin, "v0.1.0")

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 0
    assert out =~ "newer than the latest"
  end

  test "a plain update on the latest version is check-shaped and exits 0" do
    standin = standin()
    check_release(standin, "v#{DashFloat.version()}")

    {code, out} = run_captured(["update"], standin)

    assert code == 0
    assert out =~ "the latest release"
  end

  test "extra arguments after --check are ignored" do
    standin = standin()
    check_release(standin, "v#{DashFloat.version()}")

    {code, _out} = run_captured(["update", "--check", "extra"], standin)

    assert code == 0
  end

  # The env override steers a real binary at a controlled release source
  # (install.sh's DASHFLOAT_RELEASE_BASE_URL precedent); the opt wins.
  test "the API base resolves from the opt, then the env override, then GitHub" do
    standin = standin()
    check_release(standin, "v#{@latest}")
    base = UpdateStandin.base(standin)
    parent = self()

    out =
      capture_io(fn ->
        send(
          parent,
          {:codes,
           [
             Update.run(["update", "--check"],
               timeout: 2_000,
               env: %{"DASHFLOAT_UPDATE_API_BASE" => base}
             ),
             Update.run(
               ["update", "--check"],
               timeout: 2_000,
               api_base: base,
               env: %{"DASHFLOAT_UPDATE_API_BASE" => "http://127.0.0.1:1"}
             )
           ]}
        )
      end)

    assert_received {:codes, [1, 1]}
    assert out =~ "v#{@latest}"
  end

  # -- check refusals: visible, classified, never a crash ---------------------

  test "offline is a visible refusal: exit 2 in check mode, 1 otherwise" do
    # Port 1 on loopback: nothing listens — a connection the transport layer
    # refuses, the honest offline arm.
    opts = [api_base: "http://127.0.0.1:1", timeout: 1_000]
    parent = self()

    out =
      capture_io(:stderr, fn ->
        send(
          parent,
          {:codes, [Update.run(["update", "--check"], opts), Update.run(["update"], opts)]}
        )
      end)

    assert_received {:codes, [2, 1]}
    assert out =~ "could not reach GitHub"
  end

  test "an API rate limit is a visible refusal naming the reset" do
    standin = standin()
    reset = DateTime.to_unix(~U[2027-01-01 14:37:00Z])

    UpdateStandin.set_release(
      standin,
      {:status, 403, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "#{reset}"}]}
    )

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 2
    assert out =~ "rate limit"
    assert out =~ "14:37 UTC"
  end

  test "a 403 without the exhausted header is a plain HTTP refusal" do
    standin = standin()
    UpdateStandin.set_release(standin, {:status, 403, [{"x-ratelimit-remaining", "58"}]})

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 2
    assert out =~ "HTTP 403"

    # No rate-limit headers at all: still a plain HTTP refusal.
    UpdateStandin.set_release(standin, {:status, 403, []})

    {code_again, out_again} = run_captured(["update", "--check"], standin)

    assert code_again == 2
    assert out_again =~ "HTTP 403"
  end

  test "a 429 with the exhausted header is the rate-limit refusal" do
    standin = standin()

    UpdateStandin.set_release(
      standin,
      {:status, 429, [{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", "not-a-number"}]}
    )

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ "rate limit"
    assert out =~ "retry within the hour"

    # No reset header: the same within-the-hour refusal.
    UpdateStandin.set_release(standin, {:status, 429, [{"x-ratelimit-remaining", "0"}]})

    {code_again, out_again} = run_captured(["update"], standin)

    assert code_again == 1
    assert out_again =~ "retry within the hour"
  end

  test "a 404 names no published release" do
    standin = standin()
    UpdateStandin.set_release(standin, {:status, 404, []})

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 2
    assert out =~ "no published release"
  end

  test "a 5xx names the status" do
    standin = standin()
    UpdateStandin.set_release(standin, {:status, 503, []})

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ "HTTP 503"
  end

  test "a body that is not JSON refuses" do
    standin = standin()

    UpdateStandin.set_release(
      standin,
      {:status, 200, [{"content-type", "application/json"}], "{not json"}
    )

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ "release record"
  end

  test "a JSON body that is not a release object refuses" do
    standin = standin()

    UpdateStandin.set_release(
      standin,
      {:status, 200, [{"content-type", "application/json"}], "[1,2,3]"}
    )

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 2
    assert out =~ "release record"
  end

  # Review finding 2 (PR #126): decodable-but-wrong shapes must refuse, not
  # crash the boot (ADR 0011's rule).
  test "a non-binary tag_name refuses instead of crashing" do
    standin = standin()
    UpdateStandin.set_release(standin, %{"tag_name" => 42, "assets" => []})

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ "release record"
  end

  test "a missing tag_name refuses instead of crashing" do
    standin = standin()
    UpdateStandin.set_release(standin, %{"assets" => []})

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ "release record"
  end

  @tag :tmp_dir
  test "asset urls that are empty or not strings read as missing assets", ctx do
    standin = standin()
    base = UpdateStandin.base(standin)

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{"name" => "dashfloat-#{@latest}-#{@target}.tar.gz", "browser_download_url" => ""},
        %{"name" => "dashfloat-#{@latest}-sha256sums.txt", "browser_download_url" => 123}
      ]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "has no dashfloat-#{@latest}-#{@target}.tar.gz asset"
    assert current_points_at(home) == running
  end

  # Delta-review finding 1 (PR #126): a URL Req cannot build must refuse,
  # not raise out of the boot — a broken DASHFLOAT_UPDATE_API_BASE or a
  # malformed asset URL is the offline class.
  @tag :tmp_dir
  test "a download URL Req cannot build refuses instead of crashing", ctx do
    standin = standin()

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{
          "name" => "dashfloat-#{@latest}-#{@target}.tar.gz",
          "browser_download_url" => "not a url"
        },
        %{"name" => "dashfloat-#{@latest}-sha256sums.txt", "browser_download_url" => "::::"}
      ]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "downloading"
    assert out =~ "network error"
    assert current_points_at(home) == running
  end

  # The exit-class arm (final delta review, PR #126): an out-of-range port
  # makes Mint EXIT from inside the connect, which rescue cannot intercept —
  # catch :exit is what keeps it a refusal.
  @tag :tmp_dir
  test "a URL with an out-of-range port refuses instead of exiting", ctx do
    standin = standin()

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{
          "name" => "dashfloat-#{@latest}-#{@target}.tar.gz",
          "browser_download_url" => "http://127.0.0.1:99999/x"
        },
        %{
          "name" => "dashfloat-#{@latest}-sha256sums.txt",
          "browser_download_url" => "http://127.0.0.1:99999/y"
        }
      ]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "network error"
    assert current_points_at(home) == running
  end

  test "an API base Req cannot build refuses instead of crashing" do
    parent = self()

    out =
      capture_io(:stderr, fn ->
        code = Update.run(["update", "--check"], api_base: "http://[", timeout: 500)
        send(parent, {:code, code})
      end)

    assert_received {:code, 2}
    assert out =~ "could not reach GitHub"
  end

  test "asset entries that are not name/url maps are ignored" do
    standin = standin()

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [%{"name" => 42}, "junk"]
    })

    {code, _out} = run_captured(["update", "--check"], standin)

    assert code == 1
  end

  test "a tag without the v prefix still reads" do
    standin = standin()
    check_release(standin, @latest)

    {code, out} = run_captured(["update", "--check"], standin)

    assert code == 1
    assert out =~ @latest
  end

  test "a tag that is not a version refuses, naming the tag" do
    standin = standin()
    check_release(standin, "nightly")

    {code, out} = run_captured(["update"], standin)

    assert code == 1
    assert out =~ ~s("nightly")
  end

  # -- install-method detection ----------------------------------------------

  @tag :tmp_dir
  test "detect_method reads the install.sh layout as the script method", ctx do
    {home, _running, _new} = script_home(ctx.tmp_dir)
    running = Path.join([home, "versions", "0.4.0"])
    other = Path.join([home, "versions", @latest])

    assert Update.detect_method(running) == {:script, home}
    assert Update.detect_method(other) == {:script, home}
  end

  test "detect_method reads a Cellar path as Homebrew" do
    arm = "/opt/homebrew/Cellar/dashfloat/0.4.0/libexec"
    intel = "/usr/local/Cellar/dashfloat/0.4.0/libexec"

    assert Update.detect_method(arm) == {:brew, arm}
    assert Update.detect_method(intel) == {:brew, intel}
  end

  @tag :tmp_dir
  test "a versions layout without the current symlink is unknown, as is anything else", ctx do
    versions = Path.join([ctx.tmp_dir, "dashfloat", "versions", "0.4.0"])
    File.mkdir_p!(versions)

    assert Update.detect_method(versions) == :unknown
    assert Update.detect_method(ctx.tmp_dir) == :unknown
  end

  # -- the brew handoff -------------------------------------------------------

  test "a Homebrew install prints the brew upgrade handoff and never installs" do
    standin = standin()
    check_release(standin, "v#{@latest}")

    {code, out} =
      run_captured(["update"], standin, root: "/opt/homebrew/Cellar/dashfloat/0.4.0/libexec")

    assert code == 0
    assert out =~ "brew upgrade dashfloat"
    assert out =~ "Homebrew"
  end

  # -- the unknown-method refusal ----------------------------------------------

  test "an install method that can't be determined lists both options" do
    standin = standin()
    check_release(standin, "v#{@latest}")

    {code, out} = run_captured(["update"], standin, root: "/somewhere/dashfloat")

    assert code == 1
    assert out =~ "can't tell how this copy was installed"
    assert out =~ "brew upgrade dashfloat"
    assert out =~ "install.sh"

    # Without an injected root the real :code.root_dir() is probed — under
    # mix test it is a build tree, never Cellar or an install.sh layout, so
    # the same refusal fires.
    {code_again, out_again} = run_captured(["update"], standin)

    assert code_again == 1
    assert out_again =~ "can't tell how this copy was installed"
  end

  # -- the install.sh update: the verification chain ---------------------------

  @tag :tmp_dir
  test "updates an install.sh layout: download, verify, swap, smoke, prune", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir)
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 0
    assert out =~ "sha256 verified"
    assert out =~ "Updated DashFloat to #{@latest}"

    # The swap: current now names the new version; the old one is pruned.
    assert current_points_at(home) == new_dir
    new_bin = Path.join([new_dir, "bin", "dashfloat"])
    assert File.exists?(new_bin)
    refute File.exists?(running)

    # No staging leftovers.
    versions = Path.join(home, "versions")
    assert File.ls!(versions) == [@latest]
  end

  @tag :tmp_dir
  test "a corrupted download refuses and leaves the installation byte-identical", ctx do
    standin = standin()

    # The checksums file describes the REAL tarball; the served bytes are
    # swapped — a truncated or tampered download.
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, tamper: "garbage bytes, not a tarball")
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "checksum mismatch"
    assert out =~ "expected:"
    assert out =~ "actual:"
    assert current_points_at(home) == running

    running_bin = Path.join([running, "bin", "dashfloat"])
    assert File.exists?(running_bin)
    refute File.exists?(new_dir)

    versions = Path.join(home, "versions")
    assert File.ls!(versions) == ["0.4.0"]
  end

  @tag :tmp_dir
  test "a smoke failure after the swap rolls the symlink back and prunes the new tree", ctx do
    standin = standin()

    # A tarball whose launcher answers the WRONG version: extract, checksum,
    # and swap all succeed — the smoke is what catches it.
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, script: "#!/bin/sh\necho dashfloat 0.0.1\n")
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    assert out =~ "rolled back"
    assert current_points_at(home) == running

    running_bin = Path.join([running, "bin", "dashfloat"])
    assert File.exists?(running_bin)
    refute File.exists?(new_dir)
  end

  @tag :tmp_dir
  test "a new release that exits non-zero rolls back", ctx do
    standin = standin()

    arm_release(standin, "v#{@latest}", ctx.tmp_dir,
      script: "#!/bin/sh\necho dashfloat #{@latest}\nexit 3\n"
    )

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    assert out =~ "exit 3"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a new release that never answers is killed and rolled back", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, script: "#!/bin/sh\nsleep 30\n")
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 200)

    assert code == 1
    assert out =~ "timeout"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a launcher that cannot start at all fails the smoke and rolls back", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, no_exec: true)
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    # /bin/sh starts fine and reports the non-executable launcher (exit 126).
    assert out =~ "did not start correctly"
    assert out =~ "exit 126"
    assert current_points_at(home) == running
    refute File.exists?(new_dir)
  end

  # The rollback's own failure (review finding 1, PR #126): a home that
  # turns unwritable during the smoke window means the repoint cannot land.
  # The new tree must SURVIVE (current still resolves into it) and the
  # refusal must say the rollback failed, not claim success. The stub is the
  # saboteur: it chmods the home read-only from inside the smoke.
  @tag :tmp_dir
  test "a rollback that cannot repoint keeps the new tree and says so", ctx do
    standin = standin()
    {home, running, new_dir} = script_home(ctx.tmp_dir)
    sabotage = "#!/bin/sh\nchmod 555 #{home}\necho dashfloat 0.0.1\n"
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, script: sabotage)

    {code, out} =
      try do
        run_captured(["update"], standin, root: running, smoke_timeout: 2_000)
      after
        File.chmod!(home, 0o755)
      end

    assert code == 1
    assert out =~ "could not be restored"
    assert out =~ "re-run install.sh"
    # current still resolves into the kept new tree; the old one too.
    assert current_points_at(home) == new_dir

    new_bin = Path.join([new_dir, "bin", "dashfloat"])
    assert File.exists?(new_bin)
    assert File.exists?(running)
  end

  @tag :tmp_dir
  test "a failed rollback over a regular-file current keeps the new tree", ctx do
    standin = standin()
    {home, running, new_dir} = script_home(ctx.tmp_dir)
    sabotage = "#!/bin/sh\nchmod 555 #{home}\necho dashfloat 0.0.1\n"
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, script: sabotage)

    current = Path.join(home, "current")
    File.rm!(current)
    File.write!(current, "not a symlink")

    {code, out} =
      try do
        run_captured(["update"], standin, root: running, smoke_timeout: 2_000)
      after
        File.chmod!(home, 0o755)
      end

    assert code == 1
    assert out =~ "could not be restored"
    assert File.exists?(current)

    new_bin = Path.join([new_dir, "bin", "dashfloat"])
    assert File.exists?(new_bin)
  end

  # A `current` that is a regular file (not a symlink) still satisfies the
  # layout detection; the swap replaces it with the link — and a later
  # rollback removes the link rather than restoring any file.
  @tag :tmp_dir
  test "a current that is a regular file is replaced by the swapped link", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir)
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    current = Path.join(home, "current")
    File.rm!(current)
    File.write!(current, "not a symlink")

    {code, _out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 0
    assert current_points_at(home) == new_dir
  end

  @tag :tmp_dir
  test "rolling back over a regular-file current removes the swapped link", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, script: "#!/bin/sh\necho dashfloat 0.0.1\n")
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    current = Path.join(home, "current")
    File.rm!(current)
    File.write!(current, "not a symlink")

    {code, _out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    # The rollback drops the link it just installed; the running tree stays.
    refute File.exists?(current)
    assert File.exists?(running)
    refute File.exists?(new_dir)
  end

  @tag :tmp_dir
  test "a checksums file without the asset's line refuses", ctx do
    standin = standin()
    other_sum = String.duplicate("0", 64)

    arm_release(standin, "v#{@latest}", ctx.tmp_dir,
      sums: "#{other_sum}  some-other-asset.tar.gz\n"
    )

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "no checksum"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a valid checksum over bytes that are not a tarball refuses at extract", ctx do
    standin = standin()
    garbage = "definitely not gzip"
    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"
    sums_body = "#{sha(garbage)}  #{asset}\n"
    arm_release(standin, "v#{@latest}", ctx.tmp_dir, tamper: garbage, sums: sums_body)
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "could not be extracted"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "an archive without bin/dashfloat refuses", ctx do
    standin = standin()
    base = UpdateStandin.base(standin)

    # A tarball of a lone plain file: self-consistent checksum, no launcher.
    plain = Path.join(ctx.tmp_dir, "plain")
    File.write!(plain, "just a file")

    tgz = Path.join(ctx.tmp_dir, "plain.tar.gz")
    archive = String.to_charlist(tgz)
    stored = String.to_charlist(plain)
    :ok = :erl_tar.create(archive, [{~c"plain", stored}], [:compressed])

    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"
    sums = "dashfloat-#{@latest}-sha256sums.txt"
    bytes = File.read!(tgz)

    UpdateStandin.serve(standin, "/download/#{asset}", bytes)
    UpdateStandin.serve(standin, "/download/#{sums}", "#{sha(bytes)}  #{asset}\n")
    served_release(standin, base, asset, sums)

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "no bin/dashfloat"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a release missing its tarball asset refuses, naming the asset", ctx do
    standin = standin()
    check_release(standin, "v#{@latest}")
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "has no dashfloat-#{@latest}-#{@target}.tar.gz asset"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a release missing its checksums asset refuses, naming the asset", ctx do
    standin = standin()
    base = UpdateStandin.base(standin)
    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [%{"name" => asset, "browser_download_url" => "#{base}/download/#{asset}"}]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "has no dashfloat-#{@latest}-sha256sums.txt asset"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a platform with no release tarball refuses", ctx do
    standin = standin()
    check_release(standin, "v#{@latest}")
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, target: nil)

    assert code == 1
    assert out =~ "no release tarball for this platform"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a download that 404s refuses", ctx do
    standin = standin()
    base = UpdateStandin.base(standin)
    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"
    sums = "dashfloat-#{@latest}-sha256sums.txt"

    # The API promises the asset; the download route never serves it.
    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{"name" => asset, "browser_download_url" => "#{base}/download/missing"},
        %{"name" => sums, "browser_download_url" => "#{base}/download/#{sums}"}
      ]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "downloading"
    assert out =~ "HTTP 404"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a download that cannot connect refuses", ctx do
    standin = standin()
    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"
    sums = "dashfloat-#{@latest}-sha256sums.txt"

    # Both asset URLs point at a dead port while the API stays live.
    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{"name" => asset, "browser_download_url" => "http://127.0.0.1:1/download/#{asset}"},
        %{"name" => sums, "browser_download_url" => "http://127.0.0.1:1/download/#{sums}"}
      ]
    })

    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    {code, out} = run_captured(["update"], standin, root: running, timeout: 1_000)

    assert code == 1
    assert out =~ "network error"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "an unwritable versions directory refuses before downloading anything", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir)
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    versions = Path.join(home, "versions")
    File.chmod!(versions, 0o500)
    on_exit(fn -> File.chmod!(versions, 0o755) end)

    {code, out} = run_captured(["update"], standin, root: running)

    assert code == 1
    assert out =~ "staging directory"
  end

  @tag :tmp_dir
  test "an unreplaceable leftover version directory refuses cleanly", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir)
    {home, running, _new_dir} = script_home(ctx.tmp_dir)

    # A previous half-finished attempt left versions/9.9.9 unreadable with
    # contents: it can neither be cleared nor renamed over.
    stale = Path.join([home, "versions", @latest])
    File.mkdir_p!(stale)
    leftover = Path.join(stale, "leftover")
    File.write!(leftover, "junk")
    File.chmod!(stale, 0o000)
    on_exit(fn -> File.chmod!(stale, 0o755) end)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    assert out =~ "moving the new release into place failed"
    assert current_points_at(home) == running
  end

  @tag :tmp_dir
  test "a read-only home directory refuses at the symlink swap and cleans the new tree", ctx do
    standin = standin()
    arm_release(standin, "v#{@latest}", ctx.tmp_dir)
    {home, running, new_dir} = script_home(ctx.tmp_dir)

    File.chmod!(home, 0o555)
    on_exit(fn -> File.chmod!(home, 0o755) end)

    {code, out} = run_captured(["update"], standin, root: running, smoke_timeout: 2_000)

    assert code == 1
    assert out =~ "moving the new release into place failed"
    assert current_points_at(home) == running
    refute File.exists?(new_dir)
  end

  # -- platform targets --------------------------------------------------------

  test "target/0 answers for this host and target/2 for every platform arm" do
    assert Update.target() in [
             "x86_64-unknown-linux-gnu",
             "aarch64-apple-darwin",
             "x86_64-apple-darwin",
             nil
           ]

    assert Update.target({:unix, :darwin}, "aarch64-apple-darwin") == "aarch64-apple-darwin"
    assert Update.target({:unix, :darwin}, "arm64-apple-darwin24") == "aarch64-apple-darwin"
    assert Update.target({:unix, :darwin}, "x86_64-apple-darwin") == "x86_64-apple-darwin"
    assert Update.target({:unix, :darwin}, "powerpc-apple-darwin") == nil
    assert Update.target({:unix, :linux}, "x86_64-pc-linux-gnu") == "x86_64-unknown-linux-gnu"
    assert Update.target({:unix, :linux}, "amd64-linux") == "x86_64-unknown-linux-gnu"
    # Linux aarch64 has no release (ADR 0010's platform table).
    assert Update.target({:unix, :linux}, "aarch64-unknown-linux-gnu") == nil
    assert Update.target({:unix, :win32}, "x86_64-pc-windows") == nil
  end
end

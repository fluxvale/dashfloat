defmodule DashFloat.UpdateEnvTest do
  @moduledoc false
  # The RELEASE_* inheritance regression (PR #126's e2e find), isolated in a
  # SYNC module: the test mutates VM-global environment
  # (System.put_env/1), which an async module must not do — a concurrent
  # test's smoke child could otherwise read the transient value.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DashFloat.UpdateStandin

  @latest "9.9.9"
  @target "x86_64-unknown-linux-gnu"

  test "the smoke ignores an inherited RELEASE_* context" do
    {:ok, standin} = UpdateStandin.start_link()
    tmp = Path.join(System.tmp_dir!(), "df122-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    home = Path.join(tmp, "dashfloat")
    versions = Path.join(home, "versions")
    running = Path.join(versions, "0.4.0")
    bin_dir = Path.join(running, "bin")
    File.mkdir_p!(bin_dir)
    bin = Path.join(bin_dir, "dashfloat")
    File.write!(bin, "#!/bin/sh\necho dashfloat 0.4.0\n")
    File.chmod!(bin, 0o755)
    File.ln_s!(running, Path.join(home, "current"))

    # The stub answers the OLD version when it sees the inherited variable:
    # with the parent env set, only the smoke's context cleanup keeps the
    # update green.
    src_dir = Path.join([tmp, "src", "bin"])
    File.mkdir_p!(src_dir)
    stub = Path.join(src_dir, "dashfloat")

    File.write!(
      stub,
      "#!/bin/sh\nif [ -n \"$RELEASE_VSN\" ]; then echo dashfloat $RELEASE_VSN; else echo dashfloat #{@latest}; fi\n"
    )

    File.chmod!(stub, 0o755)

    tgz = Path.join(tmp, "rel.tar.gz")
    archive = String.to_charlist(tgz)
    stored = String.to_charlist(stub)
    :ok = :erl_tar.create(archive, [{~c"bin/dashfloat", stored}], [:compressed])
    bytes = File.read!(tgz)

    sha =
      bytes
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    asset = "dashfloat-#{@latest}-#{@target}.tar.gz"
    sums = "dashfloat-#{@latest}-sha256sums.txt"
    base = UpdateStandin.base(standin)
    UpdateStandin.serve(standin, "/download/#{asset}", bytes)
    UpdateStandin.serve(standin, "/download/#{sums}", "#{sha}  #{asset}\n")

    UpdateStandin.set_release(standin, %{
      "tag_name" => "v#{@latest}",
      "assets" => [
        %{"name" => asset, "browser_download_url" => "#{base}/download/#{asset}"},
        %{"name" => sums, "browser_download_url" => "#{base}/download/#{sums}"}
      ]
    })

    System.put_env("RELEASE_VSN", "0.4.0")

    _stdout =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          code =
            DashFloat.Update.run(["update"],
              api_base: base,
              timeout: 2_000,
              root: running,
              smoke_timeout: 2_000
            )

          send(self(), {:code, code})
        end)
      end)

    assert_received {:code, 0}

    current = Path.join(home, "current")
    assert {:ok, target} = File.read_link(current)
    assert target == Path.join(versions, @latest)
  after
    System.delete_env("RELEASE_VSN")
  end
end

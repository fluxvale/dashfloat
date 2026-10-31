defmodule DashFloat.PinnedToolTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.PinnedTool
  alias DashFloat.SSEServer

  describe "pins" do
    test "asset URLs follow each release's own naming" do
      assert PinnedTool.archive_url(:actionlint, {:linux, :amd64}) ==
               "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz"

      assert PinnedTool.archive_url(:shellcheck, {:linux, :amd64}) ==
               "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz"

      assert PinnedTool.archive_url(:shellcheck, {:darwin, :arm64}) ==
               "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz"

      assert PinnedTool.archive_url(:actionlint, {:linux, :amd64}, "http://loopback.invalid") ==
               "http://loopback.invalid/actionlint_1.7.12_linux_amd64.tar.gz"
    end

    test "every supported platform has a lowercase sha256 pin" do
      for tool <- [:actionlint, :shellcheck],
          os <- [:linux, :darwin],
          arch <- [:amd64, :arm64] do
        assert PinnedTool.expected_sha(tool, {os, arch}) =~ ~r/^[0-9a-f]{64}$/
      end
    end

    test "normalize covers the fleet's machines and refuses the rest" do
      assert PinnedTool.normalize({:unix, :linux}, "x86_64-pc-linux-gnu") == {:linux, :amd64}

      assert PinnedTool.normalize({:unix, :darwin}, "aarch64-apple-darwin24.6.0") ==
               {:darwin, :arm64}

      assert PinnedTool.normalize({:unix, :darwin}, "arm64") == {:darwin, :arm64}
      assert PinnedTool.normalize({:unix, :linux}, "riscv64-unknown-linux-gnu") == nil
      assert PinnedTool.normalize({:windows, :nt}, "x86_64") == nil
    end
  end

  # The loopback release server serves an archive the test built itself, so
  # the whole cold path — download, verify, extract, place, mark — runs
  # against bytes it controls; the `sha:` opt is that seam (the digest of
  # the stub archive, standing in for the module's pin).
  describe "fetch" do
    test "a warm cache answers from the marker alone, no network" do
      root = tmp_path("warm")

      bin =
        Path.join([root, "actionlint-#{PinnedTool.version(:actionlint)}", "bin", "actionlint"])

      dir = Path.dirname(bin)
      File.mkdir_p!(dir)
      File.write!(bin, "#!/bin/sh\nexit 0\n")
      File.write!(bin <> ".sha256", "cafebabe")

      assert {:ok, ^bin} = PinnedTool.fetch(:actionlint, root: root, sha: "cafebabe")
    end

    test "a cold cache downloads, verifies, extracts, and installs both layouts" do
      root = tmp_path("cold")
      # An orphaned old-version cache dir: a successful install must prune it.
      stale = Path.join(root, "actionlint-1.6.9")
      stale_bin = Path.join(stale, "bin")
      File.mkdir_p!(stale_bin)

      {_al_archive, al_body, al_sha} = stub_archive("actionlint")

      {_sc_archive, sc_body, sc_sha} =
        stub_archive("shellcheck-v#{PinnedTool.version(:shellcheck)}/shellcheck")

      {:ok, al_server} = SSEServer.start_link([{:send, http_ok(al_body)}])
      {:ok, sc_server} = SSEServer.start_link([{:send, http_ok(sc_body)}])

      # The loopback servers forward every request here: asserting the exact
      # asset path proves the download really hit the loopback (a regression
      # in the base plumbing would otherwise download real GitHub bytes
      # before failing elsewhere).
      {:ok, platform} = host_platform()
      al_asset = PinnedTool.asset_name(:actionlint, platform)

      sc_asset = PinnedTool.asset_name(:shellcheck, platform)

      assert {:ok, al_bin} =
               PinnedTool.fetch(:actionlint,
                 root: root,
                 base: SSEServer.base_url(al_server),
                 sha: al_sha
               )

      assert_received {:sse_request, "GET", "/" <> ^al_asset, _headers, _body}

      stub = File.read!(al_bin)
      assert String.contains?(stub, "#!/bin/sh")
      assert File.read!(al_bin <> ".sha256") == al_sha
      assert Bitwise.band(File.stat!(al_bin).mode, 0o755) == 0o755

      assert {:ok, sc_bin} =
               PinnedTool.fetch(:shellcheck,
                 root: root,
                 base: SSEServer.base_url(sc_server),
                 sha: sc_sha
               )

      assert_received {:sse_request, "GET", "/" <> ^sc_asset, _headers, _body}
      refute File.exists?(stale)

      assert sc_bin ==
               Path.join([
                 root,
                 "shellcheck-#{PinnedTool.version(:shellcheck)}",
                 "bin",
                 "shellcheck"
               ])

      # From here the cache must answer on its own: the linked servers are
      # stopped, so a second fetch that touched the network would fail.
      GenServer.stop(al_server)
      GenServer.stop(sc_server)
      assert {:ok, ^al_bin} = PinnedTool.fetch(:actionlint, root: root, sha: al_sha)
      assert {:ok, ^sc_bin} = PinnedTool.fetch(:shellcheck, root: root, sha: sc_sha)
    end

    test "an archive whose digest does not match the pin is refused" do
      root = tmp_path("mismatch")
      {_archive, body, _sha} = stub_archive("actionlint")
      {:ok, server} = SSEServer.start_link([{:send, http_ok(body)}])

      assert {:error, reason} =
               PinnedTool.fetch(:actionlint,
                 root: root,
                 base: SSEServer.base_url(server),
                 sha: String.duplicate("0", 64)
               )

      assert reason =~ "checksum mismatch"

      tool_dir = Path.join(root, "actionlint-#{PinnedTool.version(:actionlint)}")
      assert File.ls!(tool_dir) == []
    end

    test "an HTTP failure is a class-phrase error" do
      {:ok, server} =
        SSEServer.start_link([{:send, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n"}])

      assert {:error, reason} =
               PinnedTool.fetch(:actionlint,
                 root: tmp_path("http404"),
                 base: SSEServer.base_url(server),
                 sha: "x"
               )

      assert reason =~ "HTTP 404"
    end

    test "a connection that dies mid-download is a class-phrase error" do
      # An empty script: the server reads the request and closes without
      # sending a byte of response.
      {:ok, server} = SSEServer.start_link([])

      assert {:error, reason} =
               PinnedTool.fetch(:actionlint,
                 root: tmp_path("dead"),
                 base: SSEServer.base_url(server),
                 sha: "x"
               )

      assert reason =~ "network error"
    end

    test "a cache root that cannot be created is a class-phrase error" do
      blocker = tmp_path("blocker")
      File.write!(blocker, "a file where the cache root should be")

      assert {:error, reason} = PinnedTool.fetch(:actionlint, root: blocker, sha: "x")
      assert reason =~ "could not create"
    end
  end

  describe "extract_into" do
    test "bytes that are not a tarball fail cleanly and leave no scratch" do
      dir = tmp_path("junk")
      File.mkdir_p!(dir)
      junk = Path.join(dir, "junk.tar.gz")
      File.write!(junk, "definitely not gzip")

      assert {:error, reason} = PinnedTool.extract_into(dir, junk, "sha", :actionlint)
      assert reason =~ "could not be extracted"
      scratch = Path.join(dir, ".extract")
      refute File.exists?(scratch)
    end

    test "an archive missing the expected binary fails cleanly" do
      {archive, _body, sha} = stub_archive("README.md")
      dir = tmp_path("nomember")
      File.mkdir_p!(dir)
      tool_dir = Path.join(dir, "tool-1")

      assert {:error, reason} = PinnedTool.extract_into(tool_dir, archive, sha, :actionlint)

      assert reason =~ "could not install"
    end
  end

  defp stub_archive(member) do
    archive = tmp_path("archive-#{System.unique_integer([:positive])}") <> ".tar.gz"
    path = String.to_charlist(archive)
    entry = {String.to_charlist(member), "#!/bin/sh\nexit 0\n"}
    :ok = :erl_tar.create(path, [entry], [:compressed])

    body = File.read!(archive)
    digest = :crypto.hash(:sha256, body)
    sha = Base.encode16(digest, case: :lower)
    {archive, body, sha}
  end

  defp http_ok(body) do
    "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
  end

  defp host_platform do
    case PinnedTool.normalize(:os.type(), to_string(:erlang.system_info(:system_architecture))) do
      nil -> flunk("no supported platform on this test host")
      platform -> {:ok, platform}
    end
  end

  defp tmp_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "dashfloat-pinned-tool-#{kind}-#{System.unique_integer([:positive])}"
    )
  end
end

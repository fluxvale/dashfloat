defmodule DashFloat.PinnedTool do
  @moduledoc """
  Pin-loads the external lint binaries the `mix ci` gate shells out to
  ([ADR 0030](../decisions/0030-actionlint-inside-the-ci-gate.md)).

  `fetch/2` answers the absolute path to a tool's pinned version on this
  machine, downloading it from the tool's GitHub release on first use — the
  archive verified against the sha256 pins below — and caching it under
  `_build/tools/` (`DASHFLOAT_TOOL_ROOT` overrides the root; tests use it to
  point the `mix lint.workflows` task at a seeded cache). There is
  deliberately no PATH lookup and no skip when a binary is missing: the gate
  runs the identical version locally and in CI — whatever `shellcheck`
  happens to be on PATH (absent, ancient, or a broken mise shim) made bare
  actionlint fatal on this machine the day this shipped — and a cold cache
  without network fails the gate loudly, the same class as
  `deps.get --check-locked` offline. Bumping a tool means editing its
  version and the four archive checksums here; nothing else moves.
  """

  @actionlint_version "1.7.12"
  @shellcheck_version "0.11.0"

  @timeout_ms 30_000

  @typedoc "The gate's two external binaries."
  @type tool :: :actionlint | :shellcheck

  @typedoc "The normalized host platform the sha table and asset names key on."
  @type platform :: {:linux | :darwin, :amd64 | :arm64}

  @release_roots %{
    actionlint: "https://github.com/rhysd/actionlint/releases/download/v#{@actionlint_version}",
    shellcheck: "https://github.com/koalaman/shellcheck/releases/download/v#{@shellcheck_version}"
  }

  @versions %{actionlint: @actionlint_version, shellcheck: @shellcheck_version}

  # sha256 of each release's per-platform .tar.gz. actionlint's rows come
  # from the release's own actionlint_1.7.12_checksums.txt; shellcheck ships
  # no checksums file, so its rows were computed from the release assets
  # fetched over HTTPS (twice, byte-identical) when this module was written.
  @shas %{
    actionlint: %{
      {:linux, :amd64} => "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
      {:linux, :arm64} => "325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6",
      {:darwin, :amd64} => "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644",
      {:darwin, :arm64} => "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
    },
    shellcheck: %{
      {:linux, :amd64} => "b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6",
      {:linux, :arm64} => "68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc",
      {:darwin, :amd64} => "c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51",
      {:darwin, :arm64} => "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"
    }
  }

  @doc """
  The absolute path to `tool`'s pinned binary on this machine, downloading
  and sha-verifying it on first use. `root` overrides the cache root and
  `base` the release URL root (tests point the latter at a loopback server);
  both default to production behavior. `{:ok, path}` or `{:error, reason}`,
  the reason a class phrase fit for the gate's failure line.
  """
  @spec fetch(tool(), keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def fetch(tool, opts \\ []) do
    with {:ok, platform} <- host_platform() do
      sha = opts[:sha] || expected_sha(tool, platform)
      dir = cache_dir(tool, opts[:root] || default_root())

      case cached_bin(dir, tool, sha) do
        nil -> install(tool, platform, sha, dir, opts[:base])
        bin -> {:ok, bin}
      end
    end
  end

  @doc false
  @spec version(tool()) :: String.t()
  def version(tool), do: @versions[tool]

  @doc false
  @spec archive_url(tool(), platform(), String.t() | nil) :: String.t()
  def archive_url(tool, platform, base \\ nil) do
    root = base || @release_roots[tool]
    root <> "/" <> asset_name(tool, platform)
  end

  @doc false
  @spec expected_sha(tool(), platform()) :: String.t() | nil
  def expected_sha(tool, platform), do: @shas[tool][platform]

  @doc false
  @spec normalize({atom(), atom()}, String.t()) :: platform() | nil
  def normalize({:unix, os}, arch) when os in [:linux, :darwin] do
    cond do
      String.contains?(arch, ["x86_64", "amd64"]) -> {os, :amd64}
      String.contains?(arch, ["arm64", "aarch64"]) -> {os, :arm64}
      true -> nil
    end
  end

  def normalize(_os, _arch), do: nil

  @doc false
  @spec asset_name(tool(), platform()) :: String.t()
  def asset_name(:actionlint, {os, arch}) do
    "actionlint_#{@actionlint_version}_#{os}_#{arch}.tar.gz"
  end

  # shellcheck names its assets with the GNU arch vocabulary.
  def asset_name(:shellcheck, {os, arch}) do
    arch = %{amd64: "x86_64", arm64: "aarch64"}[arch]
    "shellcheck-v#{@shellcheck_version}.#{os}.#{arch}.tar.gz"
  end

  # -- the install pipeline ---------------------------------------------------
  #
  # Download into the tool's cache dir, verify, extract into a scratch dir,
  # and copy only the binary into `bin/` — the marker is written last, so a
  # half-written cache is simply a cold cache on the next run.

  defp install(tool, platform, sha, dir, base) do
    # A bare `mix lint.workflows` runs no app.start — Req's registry comes
    # up here; a warm cache never needs it.
    {:ok, _apps} = Application.ensure_all_started(:req)
    archive = Path.join(dir, asset_name(tool, platform))

    result =
      with :ok <- make_dir(dir),
           {:ok, _dest} <- download(archive_url(tool, platform, base), archive),
           :ok <- verify(archive, sha, tool),
           do: extract_into(dir, archive, sha, tool)

    File.rm(archive)
    result
  end

  @doc false
  @spec extract_into(Path.t(), Path.t(), String.t(), tool()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def extract_into(dir, archive, sha, tool) do
    scratch = Path.join(dir, ".extract")
    bin_dir = Path.join(dir, "bin")

    result =
      with :ok <- make_dir(scratch),
           :ok <- untar(archive, scratch),
           :ok <- make_dir(bin_dir),
           do: place(Path.join(scratch, member(tool)), bin_dir, sha)

    File.rm_rf(scratch)
    result
  end

  # The marker is written only after the binary is in place and executable,
  # so its presence + a matching sha is the whole cache-validity story.
  defp place(source, bin_dir, sha) do
    bin = Path.join(bin_dir, Path.basename(source))

    case {File.cp(source, bin), File.chmod(bin, 0o755)} do
      {:ok, :ok} ->
        File.write!(bin <> ".sha256", sha)
        {:ok, bin}

      _cp_or_chmod_failed ->
        {:error, "could not install #{Path.basename(source)} into the cache"}
    end
  end

  defp member(:actionlint), do: "actionlint"
  defp member(:shellcheck), do: "shellcheck-v#{@shellcheck_version}/shellcheck"

  defp untar(archive, scratch) do
    archive = String.to_charlist(archive)
    cwd = {:cwd, String.to_charlist(scratch)}

    case :erl_tar.extract(archive, [:compressed, cwd]) do
      :ok -> :ok
      {:error, _reason} -> {:error, "the downloaded archive could not be extracted"}
    end
  end

  defp download(url, dest) do
    case Req.get(url, into: File.stream!(dest), receive_timeout: @timeout_ms, retry: false) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, dest}

      {:ok, %Req.Response{status: status}} ->
        File.rm(dest)
        {:error, "downloading #{Path.basename(url)} failed (HTTP #{status})"}

      {:error, _transport} ->
        File.rm(dest)
        {:error, "downloading #{Path.basename(url)} failed (network error)"}
    end
  end

  defp verify(archive, expected, tool) do
    if sha256_file(archive) == expected do
      :ok
    else
      {:error,
       "#{tool} archive checksum mismatch - the download is corrupt or this module's pin is stale"}
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, _reason} -> {:error, "could not create #{dir} - is the disk writable?"}
    end
  end

  defp host_platform do
    case normalize(:os.type(), to_string(:erlang.system_info(:system_architecture))) do
      nil ->
        {:error,
         "no lint-tool release for this platform - the gate runs on linux/darwin, amd64/arm64"}

      platform ->
        {:ok, platform}
    end
  end

  # The cache is valid only while the marker names the pinned archive sha —
  # a version bump in this module invalidates it with no cache-key dance.
  defp cached_bin(dir, tool, sha) do
    bin = Path.join([dir, "bin", Atom.to_string(tool)])

    with {:ok, marked} <- File.read(bin <> ".sha256"),
         ^sha <- String.trim(marked),
         true <- File.exists?(bin) do
      bin
    else
      _stale_or_absent -> nil
    end
  end

  # Absolute on purpose: System.cmd/spawn_executable refuses relative paths.
  defp cache_dir(tool, root) do
    root
    |> Path.join("#{tool}-#{@versions[tool]}")
    |> Path.expand()
  end

  defp default_root, do: System.get_env("DASHFLOAT_TOOL_ROOT") || "_build/tools"
end

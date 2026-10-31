defmodule DashFloat.Update do
  @moduledoc """
  The `dashfloat update` command
  ([ADR 0026](../decisions/0026-update-command.md)): checks the latest
  GitHub release against the running version and updates the installation;
  `--check` is the scriptable check-only form.

  Exit codes: check-only answers `0` when current or ahead, `1` when
  outdated, `2` when the check itself failed; a plain update answers `0`
  when it updated, found the copy current, or handed off to brew, and `1`
  on every refusal.

  Every failure is a visible refusal on stderr — offline and rate-limited
  included — never a crash (the [ADR 0011](../decisions/0011-boot-tty-and-clean-refusal.md)
  discipline). There are no background or startup checks: the network is
  touched only when the user runs the command.

  The detected install method decides the update path. Homebrew prints the
  `brew upgrade dashfloat` handoff (brew owns that binary); an install.sh
  layout ([ADR 0010](../decisions/0010-release-packaging.md)) is updated in
  place — download, sha256 verify against the release's checksums file,
  staged extract, atomic `current` symlink swap, a start-up smoke of the new
  release with rollback on failure, then prune of the previous version;
  anything else is a visible refusal listing both options.
  """

  @api_base "https://api.github.com"
  @repo "fluxvale/dashfloat"
  @timeout_ms 10_000
  @smoke_timeout_ms 15_000
  @accept [{"accept", "application/vnd.github+json"}]

  @typedoc "The latest-release record: tag, its bare version, and name → download URL."
  @type release_info :: %{
          required(:tag) => String.t(),
          required(:version) => String.t(),
          required(:assets) => %{optional(String.t()) => String.t()}
        }

  @typedoc "Why a check or update refused: a class phrase, never response bodies."
  @type refusal ::
          :offline
          | :no_releases
          | :bad_response
          | {:rate_limited, integer() | nil}
          | {:http, pos_integer()}
          | {:bad_version, String.t()}

  @doc """
  Runs the command for `argv`, which begins with `"update"`; `"--check"`
  anywhere in it means check-only. Performs all of the command's IO and
  returns the process exit code (see the moduledoc).

  The API base resolves from the `:api_base` opt, then the
  `DASHFLOAT_UPDATE_API_BASE` environment variable (the same escape hatch
  install.sh's `DASHFLOAT_RELEASE_BASE_URL` gives the installer — a smoke
  can point a real binary at a controlled release source), then GitHub.
  """
  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(argv, opts \\ []) when is_list(argv) do
    with {:ok, release} <- fetch_latest(opts),
         {:ok, relation} <- relate(DashFloat.version(), release) do
      act(relation, release, argv, opts)
    else
      {:error, kind} ->
        say_refusal(describe_refusal(kind))
        refusal_code(argv)
    end
  end

  defp refusal_code(argv), do: if(check_only?(argv), do: 2, else: 1)
  defp check_only?(argv), do: "--check" in argv

  # The latest-version relation: :current, :ahead (running a newer build),
  # or :behind. Both versions parse through the same rule, so a malformed
  # tag refuses exactly like a malformed running version.
  defp relate(current, release) do
    with {:ok, current_v} <- parse_version(current),
         {:ok, latest_v} <- parse_version(release.version) do
      {:ok, Version.compare(current_v, latest_v)}
    end
  end

  defp act(:eq, release, _argv, _opts) do
    say("dashfloat #{DashFloat.version()} - the latest release (#{release.tag})")
    0
  end

  defp act(:gt, release, _argv, _opts) do
    say(
      "dashfloat #{DashFloat.version()} is newer than the latest published release (#{release.tag})"
    )

    0
  end

  defp act(:lt, release, argv, opts) do
    if check_only?(argv) do
      say(
        "dashfloat #{DashFloat.version()} - latest is #{release.tag} (update with: dashfloat update)"
      )

      1
    else
      update_installation(release, opts)
    end
  end

  # -- install-method routing (ADR 0026 §2) ---------------------------------

  @doc """
  How this copy was installed, read from the running release's root:
  a Homebrew `Cellar` path, the install.sh layout (a `versions/<v>` root
  whose parent holds the `current` symlink), or `:unknown`. The layout is
  the marker — install.sh's directory shape is deterministic, so no separate
  marker file is recorded.
  """
  @spec detect_method(Path.t()) :: {:brew, Path.t()} | {:script, Path.t()} | :unknown
  def detect_method(root) when is_binary(root) do
    root = Path.expand(root)
    versions_dir = Path.dirname(root)

    cond do
      String.contains?(root, "/Cellar/") -> {:brew, root}
      script_home?(root, versions_dir) -> {:script, Path.dirname(versions_dir)}
      true -> :unknown
    end
  end

  defp script_home?(root, versions_dir) do
    home = Path.dirname(versions_dir)
    current = Path.join(home, "current")

    Path.basename(versions_dir) == "versions" and root != home and File.exists?(current)
  end

  defp update_installation(release, opts) do
    root =
      opts
      |> Keyword.get_lazy(:root, fn -> to_string(:code.root_dir()) end)
      |> Path.expand()

    case detect_method(root) do
      {:brew, _root} ->
        brew_handoff(release)

      {:script, home} ->
        case install_release(release, home, opts) do
          :ok ->
            0

          {:error, message} ->
            say_refusal(message)
            1
        end

      :unknown ->
        say_refusal(
          "can't tell how this copy was installed (running from #{root}).\n\n" <>
            "Update options:\n" <>
            "  Homebrew:   brew upgrade dashfloat\n" <>
            "  Installer:  curl -fsSL https://github.com/#{@repo}/releases/latest/download/install.sh | sh"
        )

        1
    end
  end

  defp brew_handoff(release) do
    say("DashFloat #{release.version} is available (this copy: #{DashFloat.version()}).")
    say("This installation is managed by Homebrew - brew owns that binary, and")
    say("DashFloat will not modify it. Update with:")
    say("")
    say("    brew upgrade dashfloat")
    0
  end

  # -- the release check (ADR 0026 §1) ---------------------------------------

  defp fetch_latest(opts) do
    base =
      opts
      |> api_base()
      |> String.trim_trailing("/")

    timeout = Keyword.get(opts, :timeout, @timeout_ms)
    url = base <> "/repos/#{@repo}/releases/latest"

    case Req.get(url, headers: @accept, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_release(body)

      {:ok, %Req.Response{status: status, headers: headers}} when status in [403, 429] ->
        if header(headers, "x-ratelimit-remaining") == "0" do
          {:error, {:rate_limited, reset_at(headers)}}
        else
          {:error, {:http, status}}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_releases}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      # Req hands back the JSON decoder's failure for a body that promised
      # to be JSON; a transport error is every other shape (offline,
      # refused, timed out).
      {:error, %Jason.DecodeError{}} ->
        {:error, :bad_response}

      {:error, %Req.TransportError{}} ->
        {:error, :offline}
    end
  end

  # The API base: the test seam first, then the env override (install.sh's
  # DASHFLOAT_RELEASE_BASE_URL precedent — a smoke can steer a real binary
  # at a controlled release source), then GitHub itself.
  defp api_base(opts) do
    env = Keyword.get(opts, :env) || System.get_env()

    Keyword.get(opts, :api_base) || env["DASHFLOAT_UPDATE_API_BASE"] || @api_base
  end

  defp parse_release(%{"tag_name" => tag} = body) when is_map(body) do
    assets =
      body
      |> Map.get("assets", [])
      |> List.wrap()
      |> Enum.flat_map(fn asset -> asset_name_url(asset) end)
      |> Map.new()

    case parse_version(tag) do
      {:ok, _version} -> {:ok, %{tag: tag, version: bare(tag), assets: assets}}
      :error -> {:error, {:bad_version, tag}}
    end
  end

  defp parse_release(_other), do: {:error, :bad_response}

  defp asset_name_url(%{"name" => name, "browser_download_url" => url}) when is_binary(name),
    do: [{name, url}]

  defp asset_name_url(_other), do: []

  # Req's response headers: a map of lowercase name → value list.
  defp header(headers, name) do
    case headers do
      %{^name => [value | _rest]} -> value
      _other -> nil
    end
  end

  defp reset_at(headers) do
    case header(headers, "x-ratelimit-reset") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {unix, ""} -> DateTime.from_unix!(unix)
          _other -> nil
        end
    end
  end

  defp describe_refusal(:offline),
    do: "could not reach GitHub - offline or blocked. No update was performed."

  defp describe_refusal(:no_releases),
    do: "GitHub reports no published release for #{@repo} - nothing to update from."

  defp describe_refusal(:bad_response),
    do: "GitHub's answer wasn't a release record - retry later."

  defp describe_refusal({:http, status}),
    do: "GitHub answered HTTP #{status} - retry later."

  defp describe_refusal({:rate_limited, nil}),
    do: "GitHub's unauthenticated API rate limit is exhausted - retry within the hour."

  defp describe_refusal({:rate_limited, at}),
    do:
      "GitHub's unauthenticated API rate limit is exhausted (resets #{Calendar.strftime(at, "%H:%M UTC")}) - retry later."

  defp describe_refusal({:bad_version, tag}),
    do: "can't read the latest release's version tag (#{inspect(tag)}) - nothing was done."

  # "v1.2.3" or "1.2.3" through Elixir's own Version: pre-release tags order
  # correctly and anything odd refuses instead of guessing.
  defp parse_version("v" <> rest), do: parse_version(rest)

  defp parse_version(version) do
    case Version.parse(version) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp bare("v" <> rest), do: rest
  defp bare(tag), do: tag

  # -- the platform tarball (ADR 0026 §3) ------------------------------------

  @doc """
  The release-tarball target for this machine (`x86_64-unknown-linux-gnu`,
  `aarch64-apple-darwin`, `x86_64-apple-darwin`), or `nil` when this
  platform has no release.
  """
  @spec target() :: String.t() | nil
  def target, do: target(:os.type(), to_string(:erlang.system_info(:system_architecture)))

  @doc false
  @spec target({atom(), atom()}, String.t()) :: String.t() | nil
  def target({:unix, :darwin}, arch) do
    cond do
      String.contains?(arch, ["arm64", "aarch64"]) -> "aarch64-apple-darwin"
      String.contains?(arch, ["x86_64", "amd64"]) -> "x86_64-apple-darwin"
      true -> nil
    end
  end

  def target({:unix, :linux}, arch) do
    if String.contains?(arch, ["x86_64", "amd64"]) do
      "x86_64-unknown-linux-gnu"
    else
      # aarch64 Linux has no release yet (ADR 0010's platform table).
      nil
    end
  end

  def target(_os, _arch), do: nil

  # -- the install.sh update (ADR 0026 §3) -----------------------------------
  #
  # The step order is the safety claim: the running installation is
  # byte-identical until the single rename in swap_current/4; after the
  # swap, a failed smoke rolls the symlink back and removes the new tree.
  # The previous version is kept until the new one is proven to run, then
  # pruned — ADR 0010's one-version rule, with the rollback window it
  # lacked. The command's own VM halts right after (the boot owns the
  # halt), which is what makes pruning the running release safe.

  defp install_release(release, home, opts) do
    versions_dir = Path.join(home, "versions")
    workdir = Path.join(versions_dir, ".update-#{System.unique_integer([:positive])}")

    result =
      with {:ok, urls} <- asset_urls(release, opts),
           :ok <- say_download(release, urls),
           :ok <- make_dir(workdir),
           {:ok, tarball} <- download(urls.tarball_url, Path.join(workdir, "tarball"), opts),
           {:ok, expected} <- download_sums(urls, workdir, opts),
           :ok <- verify_checksum(tarball, expected, urls.asset),
           staging = Path.join(workdir, "staging"),
           :ok <- extract_tarball(tarball, staging),
           :ok <- assert_launcher(staging),
           {:ok, previous} <- swap_current(home, versions_dir, staging, release.version) do
        smoke_and_finish(home, versions_dir, release, previous, opts)
      end

    File.rm_rf(workdir)
    result
  end

  # Both download URLs must exist in the release's asset list; a nil target
  # is the platform refusal (this machine has no release tarball at all).
  defp asset_urls(release, opts) do
    target =
      opts
      |> Keyword.get(:target, :host)
      |> resolve_target()

    case target do
      nil ->
        {:error,
         "no release tarball for this platform - DashFloat publishes x86_64 Linux and macOS (arm64, x86_64) builds."}

      target ->
        asset = "dashfloat-#{release.version}-#{target}.tar.gz"
        sums = "dashfloat-#{release.version}-sha256sums.txt"

        urls = %{
          target: target,
          asset: asset,
          tarball_url: release.assets[asset],
          sums_url: release.assets[sums],
          sums: sums
        }

        case {urls.tarball_url, urls.sums_url} do
          {nil, _sums_url} -> {:error, missing_asset(release, asset)}
          {_tarball_url, nil} -> {:error, missing_asset(release, sums)}
          _present -> {:ok, urls}
        end
    end
  end

  defp resolve_target(:host), do: target()
  defp resolve_target(target), do: target

  defp say_download(release, urls) do
    say("Updating DashFloat #{DashFloat.version()} -> #{release.version} (#{urls.target})...")
    say("Downloading #{urls.asset}...")
    :ok
  end

  defp missing_asset(release, asset),
    do: "the release #{release.tag} has no #{asset} asset - nothing to install."

  defp make_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error,
         "could not create the staging directory under #{Path.dirname(dir)} - is the disk writable?"}
    end
  end

  defp download(url, dest, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    name =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> Path.basename()

    case Req.get(url, into: File.stream!(dest), receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, dest}

      {:ok, %Req.Response{status: status}} ->
        File.rm(dest)
        {:error, "downloading #{name} failed (HTTP #{status}) - nothing was changed."}

      {:error, _transport} ->
        File.rm(dest)
        {:error, "downloading #{name} failed (network error) - nothing was changed."}
    end
  end

  # Downloads the checksums file and pulls the tarball's line out of it:
  # `<sha256>  <filename>`, one asset per line (the single source the
  # installer and the formula also read — ADR 0010).
  defp download_sums(urls, workdir, opts) do
    with {:ok, sums_path} <- download(urls.sums_url, Path.join(workdir, "sums"), opts),
         {:ok, contents} <- File.read(sums_path) do
      case expected_sum(contents, urls.asset) do
        nil -> {:error, "sha256sums.txt has no checksum for #{urls.asset} - refusing to install."}
        sum -> {:ok, String.downcase(sum)}
      end
    end
  end

  defp expected_sum(contents, asset) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [sum, name] when name == asset -> sum
        _other -> nil
      end
    end)
  end

  defp verify_checksum(tarball, expected, asset) do
    actual = sha256_file(tarball)

    if actual == expected do
      say("sha256 verified")
      :ok
    else
      {:error,
       "checksum mismatch for #{asset}\n  expected: #{expected}\n  actual:   #{actual}\n" <>
         "The download is corrupt or tampered with; nothing was changed."}
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp extract_tarball(tarball, staging) do
    archive = String.to_charlist(tarball)
    cwd = String.to_charlist(staging)

    case :erl_tar.extract(archive, [:compressed, {:cwd, cwd}]) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, "the downloaded tarball could not be extracted - nothing was changed."}
    end
  end

  defp assert_launcher(staging) do
    launcher =
      staging
      |> Path.join("bin/dashfloat")
      |> File.exists?()

    if launcher do
      :ok
    else
      {:error, "the downloaded archive has no bin/dashfloat - nothing was changed."}
    end
  end

  # The atomic swap: rename the staged tree into `versions/<v>`, then move
  # the `current` symlink onto its new target with a second rename. Both
  # renames are single POSIX operations — no reader ever sees a half state.
  # `previous` is the old link's stored value (restored verbatim on
  # rollback, so a relative or absolute link both round-trip).
  defp swap_current(home, versions_dir, staging, version) do
    target_dir = Path.join(versions_dir, version)
    current = Path.join(home, "current")

    previous =
      case File.read_link(current) do
        {:ok, target} -> {:ok, target}
        _not_a_link -> :none
      end

    File.rm_rf(target_dir)
    say("Installing...")

    with :ok <- File.rename(staging, target_dir),
         :ok <- relink(current, target_dir) do
      {:ok, previous}
    else
      _failure ->
        # The staging rename may have landed; either way nothing points at
        # the new tree yet, so removing it restores the exact prior state.
        File.rm_rf(target_dir)

        {:error,
         "moving the new release into place failed - the current installation is unchanged."}
    end
  end

  defp relink(current, target) do
    tmp = "#{current}.new-#{System.unique_integer([:positive])}"

    with :ok <- File.ln_s(target, tmp),
         :ok <- File.rename(tmp, current) do
      :ok
    else
      _failure ->
        File.rm(tmp)
        :error
    end
  end

  defp smoke_and_finish(home, versions_dir, release, previous, opts) do
    target_dir = Path.join(versions_dir, release.version)

    case smoke(Path.join(target_dir, "bin/dashfloat"), release.version, opts) do
      :ok ->
        prune(versions_dir, target_dir)
        say("Verified: the new release reports dashfloat #{release.version}.")
        say("Updated DashFloat to #{release.version}. The previous release was removed.")
        :ok

      {:error, reason} ->
        rollback(home, previous, target_dir)

        {:error,
         "the new release did not start correctly (#{reason}) - rolled back; the previous installation is unchanged."}
    end
  end

  # The new release must answer `--version` with its own version — the same
  # smoke the release pipeline runs on every artifact (ADR 0010). A bounded
  # port: a hung child is killed at the timeout, not waited on forever.
  #
  # The child runs through /bin/sh (the launcher's own shebang guarantees it)
  # with the parent's RELEASE_* context unset: a running release exports the
  # whole suite, and the generated launcher honors RELEASE_SYS_CONFIG and
  # RELEASE_VSN over its own tree — an inherited context boots the OLD
  # release's code and answers the old version. Found on the real-artifact
  # e2e (issue #122): the test VM carries no RELEASE_* environment, so the
  # standin suite alone could not catch it.
  @release_env ~w(
    RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN
    RELEASE_COMMAND
    RELEASE_COOKIE
    RELEASE_DISTRIBUTION
    RELEASE_MODE
    RELEASE_MUTABLE_DIR
    RELEASE_NAME
    RELEASE_NODE
    RELEASE_PROG
    RELEASE_ROOT
    RELEASE_SYS_CONFIG
    RELEASE_TMP
    RELEASE_VM_ARGS
    RELEASE_REMOTE_VM_ARGS
    RELEASE_VSN
  )

  defp smoke(bin, version, opts) do
    timeout = Keyword.get(opts, :smoke_timeout, @smoke_timeout_ms)
    unset = Enum.map_join(@release_env, " ", & &1)
    script = "unset #{unset}; exec \"$0\" --version"

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        {:args, ["-c", script, bin]}
      ])

    result = collect_smoke(port, timeout, "")

    case result do
      {:ok, output, 0} ->
        if String.contains?(output, "dashfloat #{version}") do
          :ok
        else
          {:error, "unexpected --version output"}
        end

      {:ok, _output, status} ->
        {:error, "exit #{status}"}

      :timeout ->
        {:error, "no answer before the timeout"}
    end
  end

  defp collect_smoke(port, timeout, acc) do
    receive do
      {^port, {:data, chunk}} -> collect_smoke(port, timeout, acc <> chunk)
      {^port, {:exit_status, status}} -> {:ok, acc, status}
    after
      # The port closes on timeout and takes the child with it; after an
      # exit status it is already gone (closing again raises).
      timeout ->
        Port.close(port)
        :timeout
    end
  end

  # Restores the previous `current` link verbatim and removes the new tree.
  defp rollback(home, previous, target_dir) do
    current = Path.join(home, "current")

    case previous do
      {:ok, target} -> relink(current, target)
      :none -> File.rm(current)
    end

    File.rm_rf(target_dir)
  end

  # ADR 0010's one-version rule: everything under versions/ except the new
  # release goes. Dot-prefixed staging dirs are skipped (the workdir is
  # removed by install_release/3 after this runs). An unreadable directory
  # prunes nothing — the {:error, _} from File.ls matches no generator.
  defp prune(versions_dir, keep) do
    for {:ok, entries} <- [File.ls(versions_dir)],
        entry <- entries,
        dir = Path.join(versions_dir, entry),
        dir != keep,
        not String.starts_with?(entry, "."),
        do: File.rm_rf(dir)

    :ok
  end

  # -- output ----------------------------------------------------------------

  defp say(line), do: IO.binwrite(:stdio, line <> "\n")
  defp say_refusal(message), do: IO.binwrite(:stderr, "dashfloat: #{message}\n")
end

defmodule DashFloat.Tools.PathPolicy do
  @moduledoc """
  Sandbox path resolution for every tool (ADR 0007).

  `resolve/2` maps a model-supplied path onto an absolute path that is
  guaranteed (lexically and through symlinks) to stay under `root`. The check
  is byte-exact — no case folding, no Unicode normalization. Paths that are
  lexically under `root` but reach outside it through a symlink are rejected,
  as are writes into a dangling symlink: a symlink entry counts as existing
  and must resolve back under the root.
  """

  @doc """
  Resolves `path` against `root` to an absolute sandboxed path, or an error
  naming the offending path.
  """
  @spec resolve(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(root, path) when is_binary(root) and is_binary(path) do
    root_components =
      root
      |> Path.expand()
      |> String.split("/")

    case realpath(root_components, [], 0) do
      {:error, _reason} ->
        {:error, "working directory does not exist"}

      {:ok, root_real} ->
        # Compare against the expanded root too: a trailing slash or a
        # relative root must not produce bogus escape errors.
        root_expanded = Path.expand(root)
        abs = Path.expand(path, root)

        if under?(root_expanded, abs) do
          resolve_real(root_real, path, abs)
        else
          {:error, outside_error(path)}
        end
    end
  end

  defp resolve_real(root_real, path, abs) do
    {existing, rest} = deepest_existing(abs)

    case realpath(String.split(existing, "/"), [], 0) do
      {:ok, real} ->
        if under?(root_real, real), do: {:ok, join(real, rest)}, else: {:error, escape(path)}

      {:error, _reason} ->
        # A dangling symlink (or a symlink loop) cannot be shown to stay
        # inside the sandbox — reject rather than write through it.
        {:error, escape(path)}
    end
  end

  defp escape(path), do: "path escapes the working directory: " <> path

  defp outside_error(path) do
    if Path.type(path) == :absolute,
      do: "path is outside the working directory: " <> path,
      else: escape(path)
  end

  # `prefix <> "/"` keeps the boundary exact: /home/u/root must not admit
  # /home/u/root-evil.
  defp under?(prefix, path), do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp join(real, []), do: real
  defp join(real, rest), do: Path.join([real | rest])

  # realpath(3): resolves every symlink component, splicing its target into
  # the walk. `:file.realpath/1` does not exist on this OTP, so it lives here.
  # Inputs are lexically normalized (Path.expand'd) — no "." or ".." segments.
  # The hop cap turns symlink loops into {:error, :eloop}. Every component
  # read_link'd has been lstat-checked to exist by the callers; read_link
  # failures (a dangling symlink's target is :enoent) propagate as errors.
  defp realpath([], acc, _hops) do
    ordered = Enum.reverse(acc)
    {:ok, "/" <> Enum.join(ordered, "/")}
  end

  defp realpath(_components, _acc, hops) when hops >= 64, do: {:error, :eloop}

  defp realpath(["" | rest], acc, hops), do: realpath(rest, acc, hops)

  defp realpath([component | rest], acc, hops) do
    ordered = Enum.reverse([component | acc])
    canonical = "/" <> Enum.join(ordered, "/")

    case File.read_link(canonical) do
      {:error, :einval} ->
        realpath(rest, [component | acc], hops)

      {:ok, link} ->
        target =
          if Path.type(link) == :absolute do
            link
          else
            parent = Path.dirname(canonical)
            Path.expand(link, parent)
          end

        realpath(String.split(target, "/") ++ rest, [], hops + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Walks up to the deepest entry that exists (a symlink entry counts, even
  # when its target is missing), returning it with the non-existing lexical
  # remainder as a list of segments, outermost first.
  defp deepest_existing(path) do
    if present?(path) do
      {path, []}
    else
      {existing, rest} = deepest_existing(Path.dirname(path))
      {existing, rest ++ [Path.basename(path)]}
    end
  end

  defp present?(path), do: match?({:ok, _stat}, File.lstat(path))
end

defmodule DashFloat.Images do
  @moduledoc """
  One owner for the image-attachment rules
  ([ADR 0018](../decisions/0018-image-attachments.md) §3): the extension
  allow-list, the MIME map, the 10 MiB per-file cap, path validation, and the
  bytes→data-URL encode. Two surfaces share the rule set: the attach prompt
  checks a typed path (stat only — image bytes are never read in the UI
  process, ADR 0018 §5), and the agent re-validates and reads at submit (the
  file may have changed since attach, ADR 0018 §6). Errors are user-facing
  strings naming the path — the raw material of an `[images: …]` system entry
  (ADR 0018 §4). Pure validation + `File` reads; no processes.
  """

  @extensions ~w(.png .jpg .jpeg .gif .webp)

  # All three jpg spellings decode to image/jpeg (ADR 0018 §3).
  @mimes %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @max_bytes 10 * 1024 * 1024

  @typedoc "The display metadata the TUI keeps for an attached image (ADR 0018 §6)."
  @type meta :: %{name: String.t(), kb: pos_integer()}

  @doc """
  The drop-detection predicate (ADR 0018's 2026-10-31 amendment): true when
  `path` names an existing regular file with an image extension — no cap
  test (that is `check/1`'s to refuse on). The composer's bracketed-paste
  hook asks this before a paste converts to an attachment; one `stat`, the
  same sanctioned read shape as the attach prompt.
  """
  @spec image_file?(Path.t()) :: boolean()
  def image_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        ext =
          path
          |> Path.extname()
          |> String.downcase()

        Map.has_key?(@mimes, ext)

      _other ->
        false
    end
  end

  @doc """
  The attach prompt's check (ADR 0018 §5): validates `path` without reading
  image bytes — it must exist, be a regular file, carry an image extension,
  and sit under the 10 MiB cap (per its stat). Returns the display metadata —
  name and size in KB — or `{:error, reason}` naming the path.
  """
  @spec check(Path.t()) :: {:ok, meta()} | {:error, String.t()}
  def check(path) do
    case validate(path) do
      # The KB display floors at 1 (a 0-byte image is degenerate but its
      # indicator still reads honestly as a line, not "(0 KB)").
      {:ok, %{size: size}} -> {:ok, %{name: Path.basename(path), kb: max(ceil(size / 1024), 1)}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The agent's submit-time encode (ADR 0018 §6): re-validates `path`, reads
  the bytes, and builds the wire's `"data:<mime>;base64,<payload>"` URL
  (ADR 0018 §2). `{:error, reason}` names the path.
  """
  @spec data_url(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def data_url(path) do
    with {:ok, %{mime: mime}} <- validate(path),
         {:ok, bytes} <- read(path) do
      {:ok, "data:" <> mime <> ";base64," <> Base.encode64(bytes)}
    end
  end

  # The shared gate (ADR 0018 §3): a readable regular file, an image
  # extension, under the cap — each refusal naming the path.
  @spec validate(Path.t()) ::
          {:ok, %{mime: String.t(), size: non_neg_integer()}} | {:error, String.t()}
  defp validate(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        with {:ok, mime} <- extension(path),
             :ok <- cap(path, size) do
          {:ok, %{mime: mime, size: size}}
        end

      {:ok, %File.Stat{}} ->
        {:error, "#{path}: not a regular file"}

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp extension(path) do
    ext =
      path
      |> Path.extname()
      |> String.downcase()

    if Map.has_key?(@mimes, ext) do
      {:ok, Map.fetch!(@mimes, ext)}
    else
      {:error, "#{path}: not an image extension (one of #{Enum.join(@extensions, " ")})"}
    end
  end

  defp cap(_path, size) when size <= @max_bytes, do: :ok

  defp cap(path, size),
    do: {:error, "#{path}: #{size} bytes exceeds the 10 MiB image cap"}

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        # The size race (hostile review): a file grown or swapped between
        # the stat and this read must not ride the wire over the cap —
        # re-check the bytes themselves (ADR 0018 §3).
        case cap(path, byte_size(bytes)) do
          :ok ->
            {:ok, bytes}

          # coveralls-ignore-start
          # Reachable only through a real stat/read race — a file that
          # grows between the two calls — not a deterministic test.
          {:error, _reason} = error ->
            error
            # coveralls-ignore-stop
        end

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end
end

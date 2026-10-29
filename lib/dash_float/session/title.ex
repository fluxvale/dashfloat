defmodule DashFloat.Session.Title do
  @moduledoc """
  Session title normalization and resolution (#80): the optional unique-
  by-convention `title` field of the session file (ADR 0014 §3's additive
  seam), the normalization rules it must pass, and the directory scans that
  enforce uniqueness and resolve a `--resume`-able title to an id.

  The display cap is `@display_cap` (80 graphemes) — shared with the model
  side-request this module will later serve. Stored titles are case-
  preserved; matching and uniqueness compare case-insensitively through
  `normalize_key/1`.
  """

  @display_cap 80

  # Session's @id_shape, locally: titles and session ids share the `--resume`
  # surface, so a UUID-shaped title would make resume ambiguous. Strict
  # lowercase — we mint lowercase ids. See #80.
  @id_shape ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # The same character set DashFloat.TUI.Suggest scrubs (control bytes, the
  # C1 range U+0080–U+009F, bidi/format characters) — defined locally, the
  # store must not depend on the TUI.
  @scrub ~r/[\x00-\x1f\x7f\x80-\x9f\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/u

  @ws ~r/\s+/u

  @doc """
  Normalizes a raw title for storage: invalid UTF-8 repaired at the trust
  boundary, control/C1/bidi characters scrubbed, whitespace runs collapsed,
  trimmed — case-preserved. `{:error, :empty}` when nothing visible remains,
  `{:error, :too_long}` past `@display_cap` (80) graphemes, `{:error,
  :reserved}` when the result is a UUID-shaped string.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, :empty | :too_long | :reserved}
  def normalize(raw) when is_binary(raw) do
    title = clean(raw)

    cond do
      title == "" -> {:error, :empty}
      String.length(title) > @display_cap -> {:error, :too_long}
      Regex.match?(@id_shape, title) -> {:error, :reserved}
      true -> {:ok, title}
    end
  end

  def normalize(_other), do: {:error, :empty}

  @doc """
  The uniqueness/resolution key: `normalize/1`'s pipeline downcased —
  two titles differing only in case or whitespace share a key. Never raises;
  a non-normalizable input returns its best-effort downcased trim.
  """
  @spec normalize_key(term()) :: String.t()
  def normalize_key(raw) when is_binary(raw) do
    raw
    |> clean()
    |> String.downcase()
  end

  def normalize_key(_other), do: ""

  # Invalid UTF-8 repaired first — a unicode regex on raw bytes raises, and
  # nothing a title passes through may (the wrap/markdown precedent).
  defp clean(raw) do
    repaired = if String.valid?(raw), do: raw, else: String.replace_invalid(raw, "")

    repaired
    |> String.replace(@scrub, "")
    |> String.replace(@ws, " ")
    |> String.trim()
  end

  @doc """
  The id of the first session under `dir` whose title's `normalize_key/1`
  equals `raw_title`'s key, skipping `except_id` — nil when the title is
  free. Fail-open scan: undecodable files are skipped silently, the load
  path stays the loud reporter (ADR 0014 §4); a missing directory is free.
  """
  @spec title_holder(Path.t(), String.t(), String.t() | nil) :: String.t() | nil
  def title_holder(dir, raw_title, except_id \\ nil) do
    key = normalize_key(raw_title)
    ids = holders(dir, key)
    Enum.find(ids, &(&1 != except_id))
  end

  @doc """
  Resolves every session under `dir` whose title's key equals `raw_title`'s
  key: exactly one → `{:ok, id}`, none → `:none`, two or more (hand damage
  or a concurrent-writer race) → `{:ambiguous, ids}`, ids sorted.
  """
  @spec find_by_title(Path.t(), String.t()) ::
          {:ok, String.t()} | :none | {:ambiguous, [String.t()]}
  def find_by_title(dir, raw_title) do
    case holders(dir, normalize_key(raw_title)) do
      [] -> :none
      [id] -> {:ok, id}
      ids -> {:ambiguous, Enum.sort(ids)}
    end
  end

  # Filename order — the ids sort with their files.
  defp holders(dir, key) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      case decode_title(path) do
        {id, ^key} -> [id]
        _other -> []
      end
    end)
  end

  defp decode_title(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"id" => id, "title" => title}}
         when is_binary(id) and is_binary(title) <- Jason.decode(body) do
      {id, normalize_key(title)}
    else
      _other -> nil
    end
  end
end

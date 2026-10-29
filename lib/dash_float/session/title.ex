defmodule DashFloat.Session.Title do
  @moduledoc """
  Session title normalization and resolution (#80): the optional unique-
  by-convention `title` field of the session file (ADR 0014 §3's additive
  seam), the normalization rules it must pass, and the directory scans that
  enforce uniqueness and resolve a `--resume`-able title to an id.

  The display cap is `@display_cap` (80 graphemes) — shared with the model
  side-request this module also serves: the one-shot proposal request
  (Suggest's discipline, ADR 0015 §3 — fail-open, bounded, secrets never in
  errors) whose result is auto-normalized into a storage-legal title.
  Stored titles are case-preserved; matching and uniqueness compare
  case-insensitively through `normalize_key/1`.
  """

  alias DashFloat.Config
  alias DashFloat.Config.Presets

  @display_cap 80

  # The proposal request's bounds (Suggest's, ADR 0015 §3): each context
  # string is byte-prefixed to 1 KiB before any other work, the reply is
  # byte-prefixed to @raw_cap, and the completion is a handful of tokens on
  # a 5 s timeout.
  @context_cap 1024
  @raw_cap 16_384
  @max_tokens 32
  @timeout_ms 5_000
  @quote_chars ["\"", "'", "`"]

  @instruction "Propose a concise title for this conversation: 3-6 words, plain text only — no quotes, no explanation, no trailing punctuation."

  # Session's @id_shape, locally: titles and session ids share the `--resume`
  # surface, so a UUID-shaped title would make resume ambiguous. Strict
  # lowercase — we mint lowercase ids. See #80.
  @id_shape ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # The same character set DashFloat.TUI.Suggest scrubs (control bytes, the
  # C1 range U+0080–U+009F, bidi/format characters) — defined locally, the
  # store must not depend on the TUI.
  @scrub ~r/[\x00-\x1f\x7f\x80-\x9f\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/u

  # The visibility gate's widthless set (the Suggest precedent): format
  # characters and combining marks carry no width, so a proposal made only
  # of them is no title at all.
  @invisible ~r/[\p{Cf}\p{Mn}\p{Me}]/u

  @ws ~r/\s+/u

  @doc """
  The display cap (80 graphemes): the agent's collision suffix math truncates
  each `" (n)"` candidate under it, so every landed title is normalize-legal.
  """
  @spec display_cap() :: pos_integer()
  def display_cap, do: @display_cap

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

  ## The model side-request (#80) — Suggest's discipline (ADR 0015 §3)

  @doc """
  The model the title side-request targets: the `auto_title` tri-state
  through the shared `Config.Presets.side_model/3` resolution. `auto_title:
  false` reads nil — the agent never requests then (the hard stop).
  """
  @spec model(Config.t()) :: String.t() | nil
  def model(%Config{auto_title: auto_title, base_url: base_url, model: model}) do
    Presets.side_model(auto_title, base_url, model)
  end

  @doc """
  The chat-completions body: the fixed instruction plus the first
  exchange's two messages, each byte-prefixed to `@context_cap` (1 KiB)
  before any other work, on the resolved model, capped at `@max_tokens`
  completion tokens.
  """
  @spec body(Config.t(), %{user: String.t(), assistant: String.t()}) :: map()
  def body(%Config{} = config, %{user: user, assistant: assistant}) do
    %{
      "model" => model(config),
      "max_tokens" => @max_tokens,
      "messages" => [
        %{"role" => "system", "content" => @instruction},
        %{"role" => "user", "content" => bounded(user)},
        %{"role" => "assistant", "content" => bounded(assistant)}
      ]
    }
  end

  # The bound is a BYTE prefix — taken before any grapheme work, so even a
  # body that is one giant grapheme stays ≤ @context_cap bytes (the Suggest
  # @raw_cap pattern). The prefix can split a codepoint; the repair keeps
  # the request body encodable.
  defp bounded(text) do
    prefix = binary_part(text, 0, min(byte_size(text), @context_cap))

    if String.valid?(prefix), do: prefix, else: String.replace_invalid(prefix, "")
  end

  @doc """
  The one-shot request: `POST {base_url}/chat/completions` with a Bearer
  header only when a key exists. 2xx with the OpenAI reply shape yields
  `{:ok, content}`; everything else — status, shape, network, a raise — is
  `:error`. Fail-open by construction; a failure never carries the key.
  """
  @spec request(Config.t(), %{user: String.t(), assistant: String.t()}) ::
          {:ok, String.t()} | :error
  def request(%Config{base_url: base_url, api_key: api_key} = config, context) do
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"
    headers = if is_binary(api_key), do: [{"authorization", "Bearer " <> api_key}], else: []

    case Req.post(url,
           headers: headers,
           json: body(config, context),
           receive_timeout: @timeout_ms,
           retry: false,
           # Never follow a redirect: a followed 3xx would relay the first
           # exchange to a third host (and re-bill it). A redirect is just
           # another failure (the ChatStream precedent).
           redirect: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse(body)

      _other ->
        :error
    end
  rescue
    # Fail-open, absolutely (the Catalog precedent): a raise in Req/Mint/
    # Jason is just another failure — no title, no crash, no leak.
    _reason -> :error
  end

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _older]})
       when is_binary(content),
       do: {:ok, content}

  defp parse(_other), do: :error

  @doc """
  Starts the supervised side-request (the `TUI.Suggest.fetch_async` shape):
  under `DashFloat.TaskSupervisor`, the fetcher (an `{m, f}` MFA or fun/2;
  default the real HTTP path) runs rescued and caught to nil — a raising
  fetcher, or one returning something off the `{:ok, _} | :error` contract,
  is just another failure — and the ALREADY-NORMALIZED proposal lands as
  `{:title_proposal, ref, text}` (`String.t() | nil`) on `send_to` (default
  `self()`). The message must always land: a dead task would strand the
  agent's one-shot latch — normalization runs inside the supervised task,
  never in the agent loop.
  """
  @spec fetch_async(Config.t(), %{user: String.t(), assistant: String.t()}, keyword()) ::
          {:ok, pid()} | {:error, term()}
  def fetch_async(%Config{} = config, context, opts \\ []) do
    send_to = Keyword.get(opts, :send_to, self())
    ref = Keyword.fetch!(opts, :ref)
    fetcher = Keyword.get(opts, :fetcher) || {__MODULE__, :request}

    Task.Supervisor.start_child(DashFloat.TaskSupervisor, fn ->
      # Normalize HERE, inside the supervised task — never in the agent loop.
      text =
        try do
          proposal(run(fetcher, config, context))
        rescue
          _reason -> nil
        catch
          # throw/exit from a fetcher are failures too — the message must
          # land either way, or the agent's title_ref stays set forever.
          _kind, _reason -> nil
        end

      send(send_to, {:title_proposal, ref, text})
    end)
  end

  # The fetch runs INSIDE the rescue: a raising fetcher is just another
  # failure to fail open on (the Suggest precedent).
  defp run(fetcher, config, context) do
    case fetcher do
      {mod, fun} -> apply(mod, fun, [config, context])
      fun when is_function(fun, 2) -> fun.(config, context)
    end
  rescue
    _reason -> :error
  end

  @doc """
  Proposal normalization: `:error` → nil; `{:ok, raw}` → the first
  non-blank line, trimmed, ONE pair of surrounding quotes stripped,
  control/bidi characters scrubbed, hard-capped to `@display_cap` (80)
  graphemes, refused when nothing visible remains — then `normalize/1`'s
  storage rules on the result, an `{:error, _}` (blank, or a UUID-shaped
  proposal) reading nil: a silent give-up, no retry, no suffix. Bounded by
  construction: the raw body is byte-prefixed to `@raw_cap` bytes before any
  other work, and invalid UTF-8 is repaired at the trust boundary (the
  wrap/markdown precedent).
  """
  @spec proposal({:ok, term()} | :error) :: String.t() | nil
  def proposal(:error), do: nil

  def proposal({:ok, raw}) when is_binary(raw) do
    # The cap is the bound — a BYTE prefix before any grapheme work, the
    # Suggest @raw_cap pattern; the prefix can split a codepoint and the
    # repair below already handles that.
    prefix = binary_part(raw, 0, min(byte_size(raw), @raw_cap))

    repaired = if String.valid?(prefix), do: prefix, else: String.replace_invalid(prefix, "")

    line =
      repaired
      |> String.split("\n")
      |> Enum.find(&(String.trim(&1) != ""))

    case line do
      nil -> nil
      line -> title_candidate(line)
    end
  end

  def proposal({:ok, _other}), do: nil

  defp title_candidate(line) do
    candidate =
      line
      |> String.trim()
      |> strip_quotes()
      |> String.replace(@scrub, "")
      |> String.slice(0, @display_cap)

    if visible?(candidate) do
      case normalize(candidate) do
        {:ok, title} -> title
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  defp visible?(candidate) do
    candidate
    |> String.replace(@invisible, "")
    |> String.trim()
    |> Kernel.!=("")
  end

  defp strip_quotes(line) do
    cond do
      quote_only?(line) ->
        ""

      line != "" and byte_size(line) >= 2 and
        String.first(line) in @quote_chars and String.last(line) == String.first(line) ->
        String.slice(line, 1..-2//1)

      true ->
        line
    end
  end

  # A body that is nothing but quote characters is no title (the model
  # echoed the instruction's "no quotes" back as punctuation).
  defp quote_only?(line) do
    line != "" and
      line
      |> String.graphemes()
      |> Enum.all?(&(&1 in @quote_chars))
  end
end

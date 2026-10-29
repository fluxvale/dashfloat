defmodule DashFloat.TUI.Suggest do
  @moduledoc """
  The composer's ghost-text suggestion: the prompt, the one-shot
  side-request, and the display normalization
  ([ADR 0015](../../docs/decisions/0015-input-surface-cursor-stats-ghost.md)
  §3). Pure decision logic — `DashFloat.TUI.State` carries it as data and
  the TUI runner interprets intents at its choke point. The request follows
  the `Config.Catalog` precedent: `Req`, no retries, 5 s timeout, fail-open
  on everything, and the api key never near a log line or an error.
  """

  alias DashFloat.Config
  alias DashFloat.Config.Presets

  # The prompt is the last assistant reply's tail; the completion is one
  # short line; the display caps hard (ADR 0015 §3's bounds by construction:
  # ≤ ~3 KiB prompt, ≤ 48 completion tokens, ≤ 80 display chars).
  @tail_cap 2000
  @max_tokens 48
  @timeout_ms 5_000
  @display_cap 80
  # The raw-body cap: a BYTE prefix, taken before any grapheme work, so
  # everything downstream of normalize/1 runs on ≤ 16 KiB — even a body that
  # is one giant grapheme (a base char + N combining marks). max_tokens only
  # bounds well-behaved providers (ADR 0015 §3's bounds).
  @raw_cap 16_384
  @quote_chars ["\"", "'", "`"]

  # Control bytes (ESC, BEL, NUL, DEL), the C1 range U+0080–U+009F (the 8-bit
  # CSI introducer on UTF-8 terminals), and bidi/format characters
  # (zero-width, directional overrides, BOM) never reach the composer: the
  # ghost is drawn as placeholder text, so a smuggled escape or direction
  # override would be interpreted by the terminal byte stream. The printable
  # remainder is inert text.
  @scrub ~r/[\x00-\x1f\x7f\x80-\x9f\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}\x{feff}]/u

  @instruction "Suggest the user's next message: one short line, at most 8 words, plain text only — no quotes, no explanation."

  @doc """
  The LAST assistant entry's text, capped to its LAST `@tail_cap` chars;
  `""` when there is none — no side-channel spend before real context.
  """
  @spec tail([map()]) :: String.t()
  def tail(entries) do
    case Enum.reverse(entries) do
      [%{kind: :assistant, text: text} | _older] -> String.slice(text, -@tail_cap..-1//1)
      _other -> ""
    end
  end

  @doc """
  The model the side-request targets: the configured id wins, else the
  provider's preset cheap model, else the active model. `suggest: false`
  reads nil — the caller never requests then (the hard stop).
  """
  @spec model(Config.t()) :: String.t() | nil
  def model(%Config{suggest: false}), do: nil
  def model(%Config{suggest: id}) when is_binary(id), do: id

  def model(%Config{base_url: base_url, model: model}),
    do: Presets.suggest_model(base_url) || model

  @doc """
  The chat-completions body: the fixed instruction plus the reply tail, on
  the resolved model, capped at `@max_tokens` completion tokens.
  """
  @spec body(Config.t(), String.t()) :: map()
  def body(%Config{} = config, tail) do
    %{
      "model" => model(config),
      "max_tokens" => @max_tokens,
      "messages" => [
        %{"role" => "system", "content" => @instruction},
        %{"role" => "user", "content" => tail}
      ]
    }
  end

  @doc """
  The one-shot request: `POST {base_url}/chat/completions` with a Bearer
  header only when a key exists. 2xx with the OpenAI reply shape yields
  `{:ok, content}`; everything else — status, shape, network, a raise — is
  `:error`. Fail-open by construction; a failure never carries the key.
  """
  @spec request(Config.t(), String.t()) :: {:ok, String.t()} | :error
  def request(%Config{base_url: base_url, api_key: api_key} = config, tail) do
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"
    headers = if is_binary(api_key), do: [{"authorization", "Bearer " <> api_key}], else: []

    case Req.post(url,
           headers: headers,
           json: body(config, tail),
           receive_timeout: @timeout_ms,
           retry: false,
           # Never follow a redirect: a followed 3xx would relay the
           # conversation tail to a third host (and re-bill it). A redirect
           # is just another failure (the ChatStream precedent).
           redirect: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse(body)

      _other ->
        :error
    end
  rescue
    # Fail-open, absolutely (the Catalog precedent): a raise in Req/Mint/
    # Jason is just another failure — no ghost, no crash, no leak.
    _reason -> :error
  end

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _older]})
       when is_binary(content),
       do: {:ok, content}

  defp parse(_other), do: :error

  @doc """
  Starts the supervised side-request (the `Catalog.refresh_async` shape):
  under `DashFloat.TaskSupervisor`, the fetcher (an `{m, f}` MFA or fun/2;
  default the real HTTP path) runs rescued to `:error` — a raising fetcher,
  or one returning something off the `{:ok, _} | :error` contract, is just
  another failure — and the ALREADY-NORMALIZED ghost lands as
  `{:suggestion, epoch, text}` (`String.t() | nil`) on `send_to` (default
  `self()`): normalization runs inside the supervised task, never in the TUI
  process.
  """
  @spec fetch_async(Config.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def fetch_async(%Config{} = config, tail, opts \\ []) do
    send_to = Keyword.get(opts, :send_to, self())
    epoch = Keyword.fetch!(opts, :epoch)
    fetcher = Keyword.get(opts, :fetcher) || {__MODULE__, :request}

    Task.Supervisor.start_child(DashFloat.TaskSupervisor, fn ->
      # Normalize HERE, inside the supervised task — never in the TUI process.
      # The rescue covers normalize too: a fetcher returning something off
      # its `{:ok, _} | :error` contract is just another failure (fail-open)
      # — the message must land either way, or suggest_task would stay a
      # dead pid with no result ever delivered.
      text =
        try do
          normalize(run(fetcher, config, tail))
        rescue
          _reason -> nil
        catch
          # throw/exit from a fetcher are failures too — the message must
          # land either way, or suggest_task stays a dead pid forever.
          _kind, _reason -> nil
        end

      send(send_to, {:suggestion, epoch, text})
    end)
  end

  # The fetch runs INSIDE the rescue: a raising fetcher is just another
  # failure to fail open on (ADR 0015 §3).
  defp run(fetcher, config, tail) do
    case fetcher do
      {mod, fun} -> apply(mod, fun, [config, tail])
      fun when is_function(fun, 2) -> fun.(config, tail)
    end
  rescue
    _reason -> :error
  end

  @doc """
  Display normalization: `:error` → nil; `{:ok, raw}` → the first non-blank
  line, trimmed, control/bidi characters scrubbed (an escape byte must never
  reach the terminal byte stream), ONE pair of surrounding quotes stripped,
  hard-capped to `@display_cap` (80) graphemes. Bounded by construction: the
  raw body is byte-prefixed to `@raw_cap` bytes before any other work, and
  invalid UTF-8 is repaired at the trust boundary (the wrap/markdown
  precedent). Blank at any point → nil — no ghost at all.
  """
  @spec normalize({:ok, term()} | :error) :: String.t() | nil
  def normalize(:error), do: nil

  def normalize({:ok, raw}) when is_binary(raw) do
    # The cap is the bound — and it is a BYTE prefix, taken before any
    # grapheme work: a grapheme cap would pass a single giant cluster (one
    # base char + N combining marks) whole and the scan would be unbounded
    # again. The prefix can split a codepoint; the repair below already
    # handles that.
    prefix = binary_part(raw, 0, min(byte_size(raw), @raw_cap))

    # Invalid UTF-8 repaired at the trust boundary (the wrap/markdown
    # precedent): a raw byte would hard-fail the drawn frame and freeze the
    # composer. Empty replacement — a pure-invalid body is no ghost at all.
    repaired = if String.valid?(prefix), do: prefix, else: String.replace_invalid(prefix, "")

    # Grapheme work happens only here, on the repaired ≤ @raw_cap-byte
    # prefix; the ghost itself is capped to @display_cap (80) graphemes.
    body = String.slice(repaired, 0, @raw_cap)

    line =
      body
      |> String.split("\n")
      |> Enum.find(&(String.trim(&1) != ""))

    case line do
      nil ->
        nil

      line ->
        ghost =
          line
          |> String.trim()
          |> scrub()
          |> strip_quotes()
          |> String.slice(0, @display_cap)

        if String.trim(ghost) == "", do: nil, else: ghost
    end
  end

  def normalize({:ok, _other}), do: nil

  defp scrub(line), do: String.replace(line, @scrub, "")

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

  # A body that is nothing but quote characters is no ghost (the model
  # echoed the instruction's "no quotes" back as punctuation).
  defp quote_only?(line) do
    line != "" and
      line
      |> String.graphemes()
      |> Enum.all?(&(&1 in @quote_chars))
  end
end

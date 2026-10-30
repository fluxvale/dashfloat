defmodule DashFloat.Synthetic do
  @moduledoc """
  Shared context for Synthetic-keyed extras (ADR 0021): fix-json repair of
  malformed streamed tool-call arguments now, web_search groundwork (the
  search endpoint derivation) for slice B.

  A Synthetic context is discovered from the resolved provider config — the
  active provider's fields first, then the profile's provider list — by host:
  every base URL Synthetic (or its GLHF predecessor) has ever used, per
  Octofriend's `SYNTHETIC_BASE_URLS`, counts. A non-blank key is required.
  `nil` means both features are off and every caller keeps today's exact
  behavior.
  """

  # Every base-URL host Synthetic has ever served (Octofriend's
  # SYNTHETIC_BASE_URLS), so configs keyed to an old endpoint still qualify.
  @synthetic_hosts ["api.synthetic.new", "synthetic.new", "api.glhf.chat", "glhf.chat"]

  # OpenAI-compat path suffixes those base URLs carry, tried longest-specific
  # first when deriving the search root (ADR 0021 §4).
  @suffixes ["/openai/v1", "/api/openai/v1", "/api/v1", "/v1"]

  @fix_json_model "hf:syntheticlab/fix-json"

  @default_repair_timeout 15_000

  @type ctx :: %{base_url: String.t(), api_key: String.t()}

  # Octofriend's fixJsonPrompt, verbatim: the raw argument string is appended
  # with no separator (the template ends in a newline).
  @fix_json_prompt """
  The following string may be broken JSON. Fix it if possible. Respond with JSON in the following
  format, defined as TypeScript types:

  // Success response:
  { success: true, fixed: any }

  // Failure response:
  { success: false }

  If it's more-or-less JSON, fix it and respond with the success response. If it's not, respond with
  the failure response. Here's the string:
  """

  @doc """
  The Synthetic context for a `DashFloat.Config.load/0` outcome: the active
  provider's fields when they carry a Synthetic host and a non-blank key,
  else the first qualifying entry of the profile's provider list, else nil
  (an {:error, _} config included — both features stay off).
  """
  @spec context({:ok, DashFloat.Config.t()} | {:error, term()}) :: ctx() | nil
  def context({:ok, %DashFloat.Config{} = config}) do
    ctx_for(config.base_url, config.api_key) || profile_ctx(config.providers)
  end

  def context({:error, _reason}), do: nil

  defp profile_ctx(providers) do
    Enum.find_value(providers, fn
      %{base_url: base_url, api_key: api_key} -> ctx_for(base_url, api_key)
      _other -> nil
    end)
  end

  # The one qualification rule — a Synthetic-hosted URL with a non-blank
  # binary key. A hand-built config struct may hold anything in these fields.
  defp ctx_for(base_url, api_key) do
    if synthetic_host?(host(base_url)) and usable?(api_key) do
      %{base_url: base_url, api_key: api_key}
    end
  end

  defp host(base_url) when is_binary(base_url), do: URI.parse(base_url).host
  defp host(_other), do: nil

  defp synthetic_host?(host) when is_binary(host), do: host in @synthetic_hosts
  defp synthetic_host?(_other), do: false

  defp usable?(key) when is_binary(key), do: String.trim(key) != ""
  defp usable?(_other), do: false

  @doc """
  One non-streaming fix-json repair attempt for a malformed tool-call
  argument string (ADR 0021 §3): Octofriend's prompt, the
  `hf:syntheticlab/fix-json` model, `temperature: 0`, and a JSON-object
  response. On success the repaired value is the arguments map. Every other
  outcome — non-2xx, timeout, transport error, a shape miss, `success: false`,
  a non-map `fixed` — is `{:error, reason}`; this never raises.

  Options:

    * `:receive_timeout` — the request's timeout in ms
      (default #{@default_repair_timeout}).
  """
  @spec repair_json(binary(), ctx(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def repair_json(raw_args, ctx, opts \\ []) when is_binary(raw_args) do
    timeout = Keyword.get(opts, :receive_timeout, @default_repair_timeout)

    try do
      case Req.post(
             String.trim_trailing(ctx.base_url, "/") <> "/chat/completions",
             json: %{
               model: @fix_json_model,
               temperature: 0,
               response_format: %{type: "json_object"},
               messages: [%{role: "user", content: @fix_json_prompt <> raw_args}]
             },
             headers: [{"authorization", "Bearer " <> ctx.api_key}],
             # A repair is one attempt: a retry would double-bill the same
             # broken string (ADR 0021 §3).
             retry: false,
             receive_timeout: timeout
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          extract_fixed(body)

        {:ok, %Req.Response{status: status}} ->
          {:error, "fix-json failed: HTTP #{status}"}

        {:error, exception} ->
          {:error, Exception.message(exception)}
      end
    rescue
      # An unusable ctx.base_url makes Req raise before any request exists —
      # the same pre-flight cases ChatStream.check_url refuses. A repair is
      # best-effort: degrade, never crash the caller (ADR 0021 §3).
      exception ->
        {:error, Exception.message(exception)}
    catch
      # finch exits :badarg on an out-of-range port before any request exists
      # (see ChatStream.check_url) — degrade the same way.
      :exit, reason ->
        {:error, inspect(reason)}
    end
  end

  # Req decodes an application/json body itself; a different content type
  # leaves the body a binary — accept both shapes.
  defp extract_fixed(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> extract_fixed(decoded)
      _other -> {:error, "fix-json returned an unusable response"}
    end
  end

  defp extract_fixed(%{"choices" => [%{"message" => %{"content" => content}} | _rest]})
       when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"success" => true, "fixed" => fixed}} when is_map(fixed) ->
        {:ok, fixed}

      _other ->
        {:error, "fix-json returned an unusable response"}
    end
  end

  defp extract_fixed(_other), do: {:error, "fix-json returned an unusable response"}

  @doc """
  The Synthetic search endpoint for a context: the base URL minus its
  OpenAI-compat path suffix (longest-specific first), plus `/v2/search` —
  `https://api.synthetic.new/openai/v1` derives
  `https://api.synthetic.new/v2/search`, and a bare loopback URL derives
  `http://127.0.0.1:PORT/v2/search`. Wired by slice B (web_search).
  """
  @spec search_url(ctx()) :: String.t()
  def search_url(%{base_url: base_url}) do
    trimmed = String.trim_trailing(base_url, "/")

    root =
      Enum.find_value(@suffixes, trimmed, fn suffix ->
        if String.ends_with?(trimmed, suffix), do: String.replace_suffix(trimmed, suffix, "")
      end)

    root <> "/v2/search"
  end
end

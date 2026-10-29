defmodule DashFloat.Config.Catalog do
  @moduledoc """
  The standing model catalog refresh
  ([ADR 0009](../../docs/decisions/0009-config-v3-persona-profiles.md)).

  At every startup DashFloat fetches `GET {baseUrl}/models` for each provider
  of the active profile — Octofriend's pattern, adapted async: a supervised,
  unlinked task started after the TUI mounts, 5 s timeout, no retries,
  **fail-open** (any failure — auth, network, timeout, non-2xx, a body that
  is not the OpenAI `{data: […]}` shape — leaves the configured menus
  untouched and never blocks, crashes, or errors the app). The merge is
  in-memory per session: the user's explicit settings entries always win (an
  id collision never overrides, though the catalog may refresh the entry's
  `context`), and catalog ids the menu lacks are added with nickname = id.
  Nothing is written back to settings.json5.

  The onboarding wizard's model picker reuses this same fetch and merge —
  one HTTP path, one parser, one merge contract.
  """

  @timeout_ms 5_000

  @type entry :: %{model: String.t(), context: pos_integer() | nil}
  @type menu_entry :: %{nickname: String.t(), model: String.t(), context: term()}

  @doc """
  Fetches and parses a provider's model catalog: `GET {baseUrl}/models` with
  `Authorization: Bearer` when `api_key` resolves (the header is omitted for
  key-less providers — a catalog that needs no auth still refreshes).
  `{:ok, entries}` (each `%{model: id, context: positive integer | nil}`) or
  `{:error, reason}` — the reason a SHORT, safe class phrase (an HTTP status
  or an error class; the wizard shows it on screen), never response-body
  content. Never a raise, never a leak. `timeout:` bounds the wait (default
  5 s; tests use milliseconds).
  """
  @spec fetch(String.t(), String.t() | nil, keyword()) ::
          {:ok, [entry()]} | {:error, String.t()}
  def fetch(base_url, api_key, opts \\ []) when is_binary(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/models"

    headers = if is_binary(api_key), do: [{"authorization", "Bearer " <> api_key}], else: []
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    case Req.get(url, headers: headers, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP " <> Integer.to_string(status)}

      # Classes, not bodies: the reason lands on the wizard's screen.
      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "timed out"}

      {:error, %Req.TransportError{}} ->
        {:error, "connection failed"}

      # Req hands back the JSON decoder's failure for a body its
      # content-type promised was JSON — the same format-mismatch class.
      {:error, %Jason.DecodeError{}} ->
        {:error, "unexpected response format"}

      {:error, _other} ->
        {:error, "request failed"}
    end
  rescue
    # Fail-open, absolutely: a raise in Req/Mint/Jason is the same as any
    # other failure — configured menus stay, the app never notices.
    _reason -> {:error, "request failed"}
  end

  # The OpenAI listing shape: {"data": [{"id": "…"}, …]}. Anything else is a
  # schema mismatch and fails open. `context` is optional metadata (not part
  # of the OpenAI shape; a provider that reports it refreshes the entry).
  defp parse(%{"data" => entries}) when is_list(entries) do
    parsed =
      for entry <- entries,
          is_map(entry),
          id <- [usable(entry["id"])],
          is_binary(id) do
        %{model: id, context: positive_int(entry["context"])}
      end

    {:ok, parsed}
  end

  defp parse(_other), do: {:error, "unexpected response format"}

  defp usable(value) when is_binary(value) do
    case String.trim_trailing(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp usable(_other), do: nil

  defp positive_int(value) when is_integer(value) and value in 1..1_000_000_000_000, do: value
  defp positive_int(_other), do: nil

  @doc """
  Merges fetched catalog entries into a parsed menu (ADR 0009 rules): an id
  the menu already has keeps its entry — only its `context` may refresh (the
  catalog is the fresher truth for metadata); ids the menu lacks are APPENDED
  with nickname defaulting to the id; menu-only entries keep their position.
  """
  @spec merge([menu_entry()], [entry()]) :: [menu_entry()]
  def merge(menu, catalog) when is_list(menu) and is_list(catalog) do
    refreshed =
      Enum.map(menu, fn entry ->
        case Enum.find(catalog, &(&1.model == entry.model)) do
          nil -> entry
          %{context: context} when is_integer(context) -> %{entry | context: context}
          _other -> entry
        end
      end)

    known = MapSet.new(menu, & &1.model)

    added =
      for entry <- catalog,
          entry.model not in known,
          do: %{nickname: entry.model, model: entry.model, context: entry.context}

    refreshed ++ added
  end

  @doc """
  Starts the async refresh: a supervised, unlinked task under
  `DashFloat.TaskSupervisor` fetches every provider's catalog (sequential,
  fail-open per provider — the sweep already runs off the app's boot path)
  and sends `{:catalog, %{baseUrl => entries}}` to `send_to` (default
  `self()`) when it lands. Startup latency stays flat — the caller never
  waits. `fetch:` injects the fetcher (tests pass fakes; the default is the
  real HTTP path).
  """
  @spec refresh_async([DashFloat.Config.provider()], keyword()) ::
          {:ok, pid()} | {:error, term()}
  def refresh_async(providers, opts \\ []) when is_list(providers) do
    send_to = Keyword.get(opts, :send_to, self())
    fetcher = Keyword.get(opts, :fetch, {__MODULE__, :fetch})

    Task.Supervisor.start_child(DashFloat.TaskSupervisor, fn ->
      send(send_to, {:catalog, sweep(providers, fetcher)})
    end)
  end

  defp sweep(providers, fetcher),
    do: Map.new(providers, fn provider -> {provider.base_url, run_fetch(fetcher, provider)} end)

  defp run_fetch({mod, fun}, provider),
    do: fail_open(fn -> apply(mod, fun, [provider.base_url, provider.api_key]) end)

  defp run_fetch(fun, provider) when is_function(fun, 2),
    do: fail_open(fn -> fun.(provider.base_url, provider.api_key) end)

  # The fetch runs INSIDE the rescue: a raising fetcher is just another
  # failure to fail open on (ADR 0009).
  defp fail_open(fetch) do
    case fetch.() do
      {:ok, entries} when is_list(entries) -> entries
      _other -> []
    end
  rescue
    _reason -> []
  end

  @doc "The message `refresh_async/2` delivers (`{:catalog, %{baseUrl => entries}}`)."
  @spec message() :: :catalog
  def message, do: :catalog
end

defmodule DashFloat.Tools.WebSearch do
  @moduledoc """
  The web_search tool's HTTP call (ADR 0021 §6): one Bearer-keyed POST of
  `{"query": q}` to the Synthetic search endpoint derived from the session's
  context. Every outcome — transport failure included — is a runner-shaped
  result map; this never raises, so the agent's turn cannot die on a
  misbehaving search.
  """

  @default_search_timeout 15_000

  @doc """
  Runs the search for the already-validated `args` (`%{"query" => q}`).
  Options:

    * `:search` — `%{url: _, api_key: _}` derived from the agent's Synthetic
      context; absent (or any other shape) means the tool is not configured
    * `:search_timeout` — the request's timeout in ms
      (default #{@default_search_timeout}).

  A 2xx body's `results` list renders as one JSON line per entry. Every other
  outcome is `%{ok: false, error: ...}`.
  """
  @spec run(map(), keyword()) :: map()
  def run(args, opts \\ []) do
    case Keyword.get(opts, :search) do
      %{url: url, api_key: api_key} ->
        search(args, url, api_key, Keyword.get(opts, :search_timeout, @default_search_timeout))

      _other ->
        %{ok: false, error: "web search is not configured"}
    end
  end

  defp search(args, url, api_key, timeout) do
    case Req.post(
           url,
           json: %{"query" => args["query"]},
           headers: [{"authorization", "Bearer " <> api_key}],
           # One attempt — a retried search double-bills the same query,
           # the repair POST's posture (ADR 0021 §3).
           retry: false,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        render(args["query"], body)

      {:ok, %Req.Response{status: status}} ->
        %{ok: false, error: "web search failed: HTTP #{status}"}

      {:error, %{reason: :timeout}} ->
        %{ok: false, error: "web search failed: timed out"}

      {:error, _exception} ->
        %{ok: false, error: "web search failed: connection error"}
    end
  rescue
    # An unusable hand-built conf makes Req raise before any request exists —
    # degrade, never crash the runner (the repair POST's posture, ADR 0021 §3).
    exception ->
      %{ok: false, error: "web search failed: " <> Exception.message(exception)}
  catch
    :exit, reason ->
      %{ok: false, error: "web search failed: " <> inspect(reason)}
  end

  # Req decodes an application/json body itself; a different content type
  # leaves the body a binary — accept both shapes.
  defp render(query, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> render(query, decoded)
      _other -> unexpected()
    end
  end

  # One JSON line per result: Octofriend's rendering, `content`-keyed so the
  # agent's display excerpt shows the results.
  defp render(query, %{"results" => entries}) when is_list(entries) do
    %{
      ok: true,
      query: query,
      content: Enum.map_join(entries, "\n", &Jason.encode!/1),
      count: length(entries)
    }
  end

  defp render(_query, _other), do: unexpected()

  defp unexpected, do: %{ok: false, error: "web search failed: unexpected response"}
end

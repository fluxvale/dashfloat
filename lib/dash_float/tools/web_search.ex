defmodule DashFloat.Tools.WebSearch do
  @moduledoc """
  The web_search tool's HTTP call (ADR 0021 §6): one Bearer-keyed POST of
  `{"query": q}` to the Synthetic search endpoint derived from the session's
  context. Every outcome — transport failure included — is a runner-shaped
  result map; this never raises, so the agent's turn cannot die on a
  misbehaving search.
  """

  @default_search_timeout 15_000

  # Search results land whole in the conversation; cap them at the exec tool's
  # byte budget (ADR 0012), whole lines only.
  @content_limit 32 * 1024

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
           # One attempt, no redirect follow — a retried or redirected search
           # double-bills the same query, the repair POST's posture
           # (ADR 0021 §§3, 8).
           retry: false,
           redirect: false,
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
  # agent's display excerpt shows the results. Whole lines only while the
  # joined content stays within @content_limit bytes — the runner's byte-cap
  # discipline (ADR 0012); `count` is what the model actually sees.
  defp render(query, %{"results" => entries}) when is_list(entries) do
    lines = Enum.map(entries, &Jason.encode!/1)
    {content, count, truncated?} = take_lines(lines)

    %{
      ok: true,
      query: query,
      content: if(truncated?, do: content <> "\n… [truncated]", else: content),
      count: count
    }
  end

  defp render(_query, _other), do: unexpected()

  # Whole lines while the joined content stays within @content_limit bytes.
  defp take_lines(lines), do: take_lines(lines, "", 0, 0)

  defp take_lines([], acc, count, _bytes), do: {acc, count, false}

  defp take_lines([line | rest], acc, count, bytes) do
    addition = if bytes == 0, do: line, else: "\n" <> line
    joined = bytes + byte_size(addition)

    if joined <= @content_limit do
      take_lines(rest, acc <> addition, count + 1, joined)
    else
      {acc, count, true}
    end
  end

  defp unexpected, do: %{ok: false, error: "web search failed: unexpected response"}
end

# Slice 2 — `DashFloat.Tools.Vetter`: the PreToolUse safety check

> **Superseded in part by [ADR 0016](../decisions/0016-interaction-modes.md) as amended
> (post-hostile-review):** the prompt payload is fence-free (one bare JSON object,
> content-capped in both args and preview) and the vetter reads `:cancel`. Where this
> spec and the ADR disagree, the ADR wins.

Issue [#68](https://github.com/fluxvale/dashfloat/issues/68). Design:
[ADR 0016](../decisions/0016-interaction-modes.md) — read §5 (the seam) and all
of §6 (the check) before starting. Depends on slice 1's `Tools.class/1` (the
prompt payload embeds the risk class) — write against its frozen contract
(`class(name) :: :safe | :mutating | :risky`, unknown → `:risky`) and rebase
onto `feat/modes` once slice 1 lands. Do not touch the agent or the TUI —
slice 3 wires this in.

Files you will touch: new `lib/dash_float/tools/vetter.ex`, new
`test/dash_float/tools/vetter_test.exs`. Study `lib/dash_float/llm/chat_stream.ex`
first — the vetter is a thin orchestrator over it, not a new HTTP path.

## Goal

The AUTO-mode safety evaluator: a fresh-context, one-shot completion that reads
a tool call plus its preview and answers allow / ask, failing to ask on any
error or timeout.

## Spec

### Public interface (frozen by ADR 0016)

```elixir
defmodule DashFloat.Tools.Vetter do
  # Injected into the agent as a module (agent opt :vetter, slice 3).

  @doc "The task body: runs the check and returns the verdict."
  @spec verdict(provider, map(), [String.t()], keyword()) ::
          {:allow} | {:ask} | {:error, String.t()}
  def verdict(provider, call, preview_lines, opts \\ [])

  @doc "The single user message: static instruction + payload."
  @spec build_prompt(map(), [String.t()]) :: String.t()

  @doc "Strict-JSON reply parse."
  @spec parse(String.t()) :: {:ok, :run | :confirm} | :error
end
```

- `provider` is the same `{:ok, config}` shape `DashFloat.Agent` carries.
- `call` is the normalized tool call (`%{id: _, name: _, args: map()}`).
- `opts`: `:vet_timeout` (ms, default `10_000`), plus anything the stream needs.

### `verdict/4` — the task body

Runs inside a supervised Task when called from the agent (slice 3), so it owns
its own deadline (timers live in tasks, never the agent — ADR 0001/0007):

1. Start `ChatStream.run(self(), provider, [prompt_message], [], stream_opts)`
   as a linked process or task — `tools: []` (the vet never calls tools), the
   message list is exactly one user message (fresh context: no conversation,
   no system role — ADR 0016 §6).
2. Arm `Process.send_after(self(), :vet_deadline, timeout)`. On
   `:vet_deadline`: send the stream child `:cancel`, return
   `{:error, "safety check timed out after #{timeout}ms"}`.
3. Collect `{:token, text}` (accumulate), `{:stream_failed, text, _}` (return
   `{:error, text}`), `{:stream_done, %{content: content}}` (parse; on
   `{:ok, decision}` return `{:allow}` for `:run`, `{:ask}` for `:confirm`; on
   `:error` return `{:error, "safety check returned unparseable output"}`).
4. A stream child dying abnormally is a failed check: `{:error, reason}`.
   Never raises — every failure is a normal `{:error, _}` return (the caller
   turns any error into confirm, ADR 0016 §6's fail-safe).

### `build_prompt/2` — the prompt (versioned here, in code)

One user message. Structure it as:

1. A static instruction paragraph (a module attribute — the canary test asserts
   its key phrases):
   - The task: gate-keep a tool call for an AI coding assistant running in
     AUTO mode; decide whether it is safe to run WITHOUT human confirmation.
   - The rubric: **run** = routine, reversible, project-scoped development
     work (builds, tests, searches, file edits inside the project,
     lockfile-driven installs); **confirm** = destructive, irreversible,
     outside the project, touching credentials or secrets, network mutation
     (push, deploy), installing from the network, privilege escalation, force
     operations.
   - The reply contract: strict JSON only, no prose, exactly
     `{"decision":"run"|"confirm","reason":"<one short sentence>"}`.
2. The payload as fenced JSON:
   - `tool` — the tool name; `risk_class` — `Tools.class(name)`'s value as a
     string (ADR 0016 §2: the vet's severity prior — a shell is scrutinized
     harder than a scoped edit);
   - `args` — the normalized args, `Jason.encode!`, then capped at 8 KiB with
     a trailing `… (truncated)` marker when larger;
   - `preview` — the preview lines verbatim (already capped at 50 by
     `Preview.build`): exactly what a BUILD-mode human would confirm.

### `parse/1`

`Jason.decode` → require a map with `"decision"` in `["run", "confirm"]` →
`{:ok, :run | :confirm}`. Everything else — malformed JSON, missing or
out-of-vocabulary decision, non-map — `:error`. `"reason"` is accepted and
ignored (v1 does not display it).

## Tests (`test/dash_float/tools/vetter_test.exs`, loopback SSE pattern)

Follow the existing `ChatStream` test's loopback server setup (recorded SSE
responses served to the real HTTP client):

1. **allow path**: served completion `{"decision":"run","reason":"test run"}`
   → `verdict` returns `{:allow}`.
2. **ask path**: `{"decision":"confirm","reason":"pushes"}` → `{:ask}`.
3. **unparseable**: served `"Sounds good!"` → `{:error, _}` naming the
   unparseable output.
4. **timeout**: a served stream that trickles frames past a tiny
   `vet_timeout` (e.g. 100 ms) → `{:error, "safety check timed out…"}` and the
   stream child is cancelled (its connection closes).
5. **stream failure**: the server refuses/drops → `{:error, _}`.
6. **prompt canary**: `build_prompt/2` output contains the tool name, the risk
   class, the encoded args, the preview lines, the words `strict JSON`, and
   the decision vocabulary; the args cap: a call with > 8 KiB args produces a
   truncation marker and a bounded prompt.
7. **parse table**: valid run, valid confirm, missing decision, bad decision
   value, malformed JSON, non-map top level.

## Done when

```
mix deps.get && mix test test/dash_float/tools/vetter_test.exs
```

exits 0 with all tests visible and passing, and

```
mix ci
```

exits 0. Paste both transcripts. `git diff --stat main -- lib test` shows
your two new files plus slice 1's already-merged output (`lib/dash_float/mode.ex`,
`lib/dash_float/tools.ex`, and their tests) — nothing else.

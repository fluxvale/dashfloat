# 0021 — Synthetic repair and web search: fix-json at the stream terminal, the search endpoint seam

- **Status:** Accepted
- **Date:** 2026-10-30
- **Implements:** [issue #73](https://github.com/fluxvale/dashfloat/issues/73)
  (the repair half) and
  [issue #74](https://github.com/fluxvale/dashfloat/issues/74) (the
  web_search half, §§6–8).
- **Extends:** [ADR 0007](0007-tool-calls-and-execution.md) (the stream
  terminal's tool-call report and the error-result path it feeds),
  [ADR 0005](0005-llm-streaming-engine.md) (the streaming producer's
  process shape), [ADR 0016](0016-interaction-modes.md) (the
  risk classes the search tool's `:safe` gating rides). Reference
  implementation: Octofriend's `source/compilers/autofix.ts`,
  `source/prompts/autofix-prompts.ts`, and
  `source/tools/tool-defs/web-search.ts`.
- **Governs:** `DashFloat.Synthetic` (new), `ToolCalls.build_call/1`'s
  `raw_args`, the `ChatStream` [DONE] terminal, the agent's `:synthetic`
  opt, and `DashFloat.Tools`' advertisement of `web_search`
  (`DashFloat.Tools.WebSearch`).

## Context

A streamed tool call's arguments arrive as fragments concatenated into one
binary; when that binary fails `JSON.parse`, `ToolCalls.finish/1` discards
the bytes and degrades the call to `args: nil, error: "invalid JSON
arguments"`. The agent surfaces the error to the model as a tool result and
the turn continues — but the model often cannot reproduce its own broken
JSON, so the turn stalls. Synthetic hosts two custom-trained repair models
for exactly this (`hf:syntheticlab/fix-json`, `hf:syntheticlab/diff-apply` —
ids from Octofriend's first-time setup, not Synthetic's public docs page),
and Octofriend routes every malformed tool-call argument through fix-json
before accepting the failure. A Synthetic (or GLHF) key may sit in the
active provider's fields or in another provider of the same profile.

Three facts verified in code shape the design:

1. The raw argument binary was the only missing input: `finish/1` decodes
   from an accumulator that still holds it.
2. The `[DONE]` clause of `ChatStream.emit_frames/5` is the one place every
   call is finished — and it already runs inside the stream Task, off the
   agent's state machine.
3. `DashFloat.Config`'s resolved shape carries the active provider's
   `base_url`/`api_key` fields plus `providers` (each with its effective
   key) — enough to discover a Synthetic key without re-reading files.

## Decision

### 1. Key discovery — `DashFloat.Synthetic.context/1`

The host set is every base-URL host Synthetic has ever served (Octofriend's
`SYNTHETIC_BASE_URLS`): `api.synthetic.new`, `synthetic.new`,
`api.glhf.chat`, `glhf.chat`. A config qualifies a context when a base URL's
`URI.parse/1` host is in that set AND the key is a non-blank binary — the
active provider's own fields first, then the profile's provider list, first
entry wins. `{:error, _}` configs, missing keys, and hand-built structs
holding non-binaries all yield nil: no context, both features off, every
caller keeps today's behavior. The context travels as a plain
`%{base_url:, api_key:}` map so tests can pin one without a config file.

### 2. The repair hook lives at the stream terminal

`ChatStream.run/5` gains `:synthetic` (a context or nil) and
`:repair_timeout` (ms, default 15 000), threaded into the episode
accumulator at the 2xx branch. The `[DONE]` clause: without a context,
today's terminal report, byte-identical. With one, every call whose error is
exactly `"invalid JSON arguments"` is repaired — sequentially, in call
order, inside the already-async stream task. `raw_args` (added to
`build_call/1`'s call map — the accumulated argument binary) is the repair
input. A successful repair replaces the call's `args` with the fixed value
and clears the error; schema validation then happens in the agent exactly as
for a well-formed stream, so a fixed-but-invalid payload still gets the
normal validate error (Octofriend parity). A failed repair leaves the call
untouched — the agent's error-result path is the fallback, unchanged. Calls
with `"missing function name"` or no error are never repaired: there is
nothing fix-json can add to a missing name.

No agent state-machine churn: the repair is one blocking POST inside a task
that is already disposable, monitored, and idle-timeout-free by design (the
repair carries its own `receive_timeout`).

### 3. The fix-json call — `DashFloat.Synthetic.repair_json/3`

One non-streaming `POST {base_url}/chat/completions` with
`hf:syntheticlab/fix-json`, `temperature: 0`,
`response_format: %{type: "json_object"}`, a single user message (Octofriend
's `fixJsonPrompt` verbatim, raw arguments appended with no separator),
Bearer auth, `retry: false` (a repair is one attempt; a retry would
double-bill the same broken string), and `receive_timeout`. A 2xx body's
`choices[0].message.content` is itself JSON: `{"success": true, "fixed": m}`
with `m` a map yields `{:ok, m}`; every other outcome — non-2xx (the reason
names `HTTP <status>`), timeout, transport error, a shape miss, a decode
failure, `success: false`, a non-map `fixed` — yields
`{:error, reason}`. It never raises: the agent's turn must not die because a
repair attempt misbehaved.

### 4. Model ids

`hf:syntheticlab/fix-json` is wired. `hf:syntheticlab/diff-apply` (repairs
an edit's non-matching search string) is recorded here and deliberately NOT
wired:

- Both of the issue's trigger examples are malformed-JSON cases fix-json
  already covers; a non-matching search block is not a malformed completion.
- DashFloat already surfaces a non-matching search block as a precise tool
  error the model retries on — the loop closes today without a second model.
- Wiring diff-apply would put an HTTP call inside the preview/confirmation
  flow, a different process and timeout regime than the stream terminal.

A candidate follow-up issue if the retry loop proves too weak in practice.

### 5. Fallback and cancel semantics

No context (no key anywhere), a repair timeout, or any repair failure lands
on exactly today's path: the call keeps `args: nil, error: "invalid JSON
arguments"`, the agent answers with the error tool result, the turn
continues. Cancellation: a cancel that lands while a repair POST is in
flight is invisible to the stream loop's own checks, so the repair path —
and only the repair path — re-checks `cancelled?/0` after the repairs; the
cancel wins (`terminal_cancel/2`, partial content kept, tool fragments
dropped). Without repairs attempted there is no re-check: the no-key
terminal is byte-identical.

### 6. The search endpoint seam — `DashFloat.Synthetic.search_url/1`

The web_search POST targets `{root}/v2/search`; the root is the context's
base URL minus its trailing slash and its OpenAI-compat path suffix —
`/openai/v1`, `/api/openai/v1`, `/api/v1`, `/v1`, tried longest-specific
first. A suffix-less base URL (the loopback test server) derives
`{base_url}/v2/search` unchanged, which is what makes the search round-trip
loopback-testable.

### 7. web_search — advertisement gated on the context

The tool lives in the one `DashFloat.Tools` parameter table like every other,
but `schema/1` advertises it only when the session carries a Synthetic
context — discovered from the config or pinned by the `:synthetic` opt
(§1). Without a context the advertised array is the base five-tool list,
exactly as before. `validate/2` stays total over the table on purpose: a
model hallucinating a web_search call without a key passes validation (the
table is the single source of truth for argument shapes) and then the runner
answers with a plain error result — "web search is not configured" — the
turn continues, one honest error instead of a second advertisement channel
to keep in sync.

The tool's risk class is `:safe` (read-only, ADR 0016): the gate sends it
straight to dispatch in every mode — no preview, no confirmation, no safety
check. The agent derives the call's target per dispatch from its context
(`search_url/1` plus the context's key) and threads it to the runner as the
`:search` opt; a nil context threads nil.

### 8. The search call and its rendering

One non-streaming `POST {root}/v2/search` with `{"query": q}`, Bearer auth,
`retry: false` (one attempt — a retry would double-bill the same query, the
repair POST's §3 posture), and a `receive_timeout` defaulting to 15 000 ms.
A 2xx body — pre-decoded by Req or a binary decoded with Jason — must carry
`results` as a list; each entry renders as one JSON line (`Jason.encode!/1`)
and the lines join with newlines into the result's `content`, Octofriend's
rendering. Every other outcome — non-2xx (`HTTP <status>`), timeout,
transport error, a shape miss — is a `%{ok: false, error: ...}` result map,
never a raise: the agent's turn cannot die on a misbehaving search.

## Alternatives considered

- **Repair in the agent** (on receiving the `{:stream_done, ...}` report) —
  rejected: it drags an HTTP timeout into the agent's message handling and
  its state machine, and it needs the raw args shipped through the report.
  The stream task already owns the bytes and is already disposable.
- **Repair inside `ToolCalls.finish/1`** — rejected: the accumulator is a
  pure, side-effect-free module; injecting HTTP there would make every
  caller (including tests and the transcript replays) network-bound.
- **Repairing on schema-validation failure too** — rejected: a repaired-but-
  invalid payload is the model's semantics being wrong, not its syntax; the
  validate error already teaches it what to fix. Widening the trigger
  doubles the HTTP surface for no demonstrated gain.
- **Surfacing repair failures to the UI** — rejected for now: the fallback
  error result already reaches the model and the log; a second notice would
  double-report the same broken call.

## Consequences

- A malformed tool call on a Synthetic-keyed config usually heals without a
  model round-trip through the main chat: one cheap, temperature-0 POST
  replaces an error/retry cycle.
- The stream terminal's duration gains a repair-shaped tail (bounded by
  `:repair_timeout` per repaired call); Esc still cancels — it takes effect
  the moment the in-flight repair returns.
- `raw_args` rides every call map and the terminal report: a small,
  permanent addition to the ChatStream↔Agent contract.
- Quota: repairs spend Synthetic quota only when a stream actually produces
  malformed arguments; every test drives the loopback server, never the real
  endpoint.
- web_search spends quota only when the model calls it, and only on a
  session with a Synthetic context; a keyless session sees an unchanged tool
  list, and the `:safe` class means a call needs no keypress — the search's
  own timeout bounds how long the tool batch can pause on it.

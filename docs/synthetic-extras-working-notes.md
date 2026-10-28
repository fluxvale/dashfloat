# Working notes: Synthetic repair models (#73) + web_search (#74)

Status: IN-PROGRESS LANE NOTES — research and design are settled, no code written yet.
Delete this file before the PR ships (the ADR carries the durable decisions).

Branch `feat/synthetic-extras`, worktree `dashfloat-73-synthetic`, based on main `08240d3`.

## Reference implementation (Octofriend, on this machine, READ-ONLY)

Checkout: `~/DevTools/octofriend`. Relevant files:

- `source/compilers/autofix.ts` — both fixer calls. Non-streaming OpenAI-compatible
  `chat/completions` POST: `temperature: 0`, `response_format: {type: "json_object"}`,
  single user message, model from config. Any failure (no config, no key, HTTP error,
  unparseable response) returns null / `{success: false}` — the caller falls back to the
  legacy error. No retry.
- `source/prompts/autofix-prompts.ts` — the fix-json prompt (send verbatim, substituting
  `<str>`): 
  `The following string may be broken JSON. Fix it if possible. Respond with JSON in the following\nformat, defined as TypeScript types:\n\n// Success response:\n{ success: true, fixed: any }\n\n// Failure response:\n{ success: false }\n\nIf it's more-or-less JSON, fix it and respond with the success response. If it's not, respond with\nthe failure response. Here's the string:\n<str>`
  Response contract: `{"success": true, "fixed": <parsed JSON>}` or `{"success": false}`.
- `source/libocto/compilers/parse-tool-call.ts` — TRIGGER: arguments arrive as a string
  that fails `JSON.parse` → `autofixJson(source)`; on `success: true` the `fixed` value
  becomes the args (then schema-validated as normal); on failure the legacy error
  message ("Syntax error: invalid JSON in tool call arguments"). Empty string args
  parse as `{}`. A `fixed` value that is itself a JSON string gets double-decoded.
- `source/first-time-setup.tsx` (lines ~325/362) — THE FIXER MODEL IDS on Synthetic's
  OpenAI-compatible endpoint `https://api.synthetic.new/openai/v1`:
  - `hf:syntheticlab/fix-json` — repairs broken tool-call argument JSON
  - `hf:syntheticlab/diff-apply` — repairs an edit's non-matching search string
    (response `{"success": true, "search": "..."}` or `{"success": false}`)
  Both are custom-trained, open-sourced (huggingface.co/syntheticlab/fix-json, /diff-apply).
  They are NOT on Synthetic's public models docs page — the ids come from Octofriend.
- `source/config.ts` — `readSearchConfig` + `SYNTHETIC_BASE_URLS` (every base URL
  Synthetic has ever used): `https://api.synthetic.new/openai/v1`,
  `https://synthetic.new/api/openai/v1`, `https://api.synthetic.new/v1`,
  `https://api.glhf.chat/v1`, `https://glhf.chat/api/v1`, `https://glhf.chat/api/openai/v1`.
- `source/tools/tool-defs/web-search.ts` — search tool: `POST {searchConf.url}` with body
  `{"query": q}`, `Authorization: Bearer <key>`; default url `https://api.synthetic.new/v2/search`.
  Response shape: `{"results": [{"url", "title"?, "highlights": [string], "published"?}]}` —
  each result rendered as one JSON line joined by newlines into the tool output.

Synthetic docs (https://dev.synthetic.new/docs/api/models, read Oct 29 2026): the models
page lists only syn: aliases + always-on chat models (no fixer entries; the docs site is a
client-rendered SPA — fetch via a rendering reader, direct curl gets the shell). Search
reference page exists in the sidebar ("Synthetic Reference — /quotas, /search") but the
direct URL 404s through the reader; Octofriend's implementation above is the operative spec.

## DashFloat seam map (verified by reading, no code touched yet)

- `DashFloat.LLM.ToolCalls` (`lib/dash_float/llm/tool_calls.ex`): `finish/1` decodes args;
  malformed JSON → `%{args: nil, error: "invalid JSON arguments"}` — the RAW args binary is
  discarded in `build_call/1`. Needs `raw_args` added to the call map (trivial: `entry.args`).
- `DashFloat.LLM.ChatStream` (`lib/dash_float/llm/chat_stream.ex`): the `[DONE]` clause of
  `emit_frames` is where `ToolCalls.finish/1` feeds `{:stream_done, %{tool_calls: ...}}`.
  This is the chosen repair hook (inside the already-async stream Task — no new agent
  state machine; see design below). `run/5` opts currently: `:idle_timeout`.
- `DashFloat.Agent` (`lib/dash_float/agent.ex`): `next_call/2` → `classify/1` — a call with
  `error` short-circuits to an error tool-result (`%{ok: false, error: error}`) and the
  turn CONTINUES (the model sees the error; nothing hard-fails today — "failing the turn"
  in the issue = this error-result path). `start_episode/1` calls
  `ChatStream.run(agent, state.provider, state.messages, Tools.schema())` (line ~309).
  Started by `DashFloat.Application` with `provider:`/`name:`/`supervisor:` only — a new
  defaulted opt is backward-compatible. `handle_info({:set_provider, _})` swaps provider
  post-wizard.
- `DashFloat.Tools` (`lib/dash_float/tools.ex`): one `@params` table drives `schema/0` and
  `validate/2`; `@order` fixes advertisement. web_search goes here, gated in schema.
- `DashFloat.Tools.Runner`: `run/4` case dispatch; opts carry `:exec_timeout` — the
  precedent for a `:search` opt. `automatic?/1` in the agent decides confirmation:
  web_search is read-only → automatic.
- `DashFloat.Config`: resolved config carries `providers` (the ACTIVE profile's providers,
  each with EFFECTIVE key) plus the active provider's own `base_url`/`api_key` fields —
  enough to discover a Synthetic key without re-reading files.
- Loopback seam: `DashFloat.SSEServer` (`test/support/sse_server.ex`) — raw :gen_tcp,
  `:per_connection` scripts, forwards every request as `{:sse_request, method, path,
  headers, body}` to the test process. It can serve ANY http response (repair POST JSON,
  search JSON), not just SSE. Response scripts must set content-length (Req parses).
  Agent-test driving pattern + `provider(server)` helper: `test/dash_float/agent_test.exs`.

## Design (settled; the two worker specs below were ready to fan out)

### New module `DashFloat.Synthetic` (`lib/dash_float/synthetic.ex`)

Shared context for both issues:

- `context/1` (`%DashFloat.Config{} -> %{base_url, api_key} | nil`): scan the active
  provider fields first, then `config.providers`; first entry whose `URI.parse(base_url).host`
  is in the Synthetic host set — derive from Octofriend's `SYNTHETIC_BASE_URLS` hosts:
  `api.synthetic.new`, `synthetic.new`, `api.glhf.chat`, `glhf.chat` — with a non-blank
  key. nil otherwise (= both features off).
- `repair_json(raw_args, ctx, opts \\ [])`: POST `ctx.base_url <> "/chat/completions"` with
  `model: "hf:syntheticlab/fix-json"`, `temperature: 0`,
  `response_format: %{type: "json_object"}`, one user message (the fix prompt above),
  Bearer header, `retry: false`, `receive_timeout:` opt (default 15_000). 2xx →
  `choices[0].message.content` → Jason.decode → `{"success": true, "fixed" => m}` when
  is_map(m) → `{:ok, m}`; everything else (non-2xx, decode fail, success:false, non-map
  fixed, transport error, timeout) → `{:error, reason}`. Never raises.
- `search_url/1`: `ctx.base_url` minus trailing `/`, minus the first matching OpenAI-compat
  suffix (`/openai/v1`, `/api/openai/v1`, `/v1`, `/api/v1`) → root; return `root <> "/v2/search"`.
  (Loopback `http://127.0.0.1:PORT` has no suffix → `http://127.0.0.1:PORT/v2/search` — this
  is what makes the search round-trip loopback-testable.)

### #73 fix-json wiring — in ChatStream, at the stream terminal

- `Agent` gains `:synthetic` opt (default `:discover` → `Synthetic.context(provider)` at
  init and on `{:set_provider, _}`; an explicit map or nil PINS it — the test seam; the
  loopback server must be impersonatable). Field `synthetic` + a pinned/discover flag.
- `ChatStream.run/5` opts gain `:synthetic`; the [DONE] clause:
  - ctx nil → EXACTLY today's `ToolCalls.finish(acc.tool_calls)` (byte-identical no-key path).
  - ctx present → repair each call whose `error == "invalid JSON arguments"` (leave
    `"missing function name"` alone): `Synthetic.repair_json(call.raw_args, ctx)` →
    `{:ok, fixed}` ⇒ `%{call | args: fixed, error: nil}` (validation happens in the agent
    as usual — a fixed-but-invalid map gets the normal validate error, Octofriend parity);
    `{:error, _}` ⇒ call unchanged (today's error result). Repairs run sequentially
    before `{:stream_done, ...}` is sent. If any repair was attempted, check `cancelled?()`
    first — a cancel that landed during the repair POST wins → `terminal_cancel`
  (today's [DONE] does not re-check cancel; only the repair path adds the check, keeping
  the no-key path byte-identical).
- `ToolCalls.build_call/1` adds `raw_args: entry.args` to the call map (type updated).
- Scope decision to flag to Terence: **diff-apply (`hf:syntheticlab/diff-apply`) is
  RECORDED in the ADR but NOT wired.** Reasoning: a non-matching edit search_block is not
  a malformed completion (both issue examples — bad tool_call shape, broken edit syntax —
  are malformed-JSON cases fix-json covers); DashFloat already surfaces the mismatch as a
  precise tool error the model retries on; wiring diff-apply means an HTTP call inside the
  preview/confirmation flow (agent process today — would need the tool-slot task machinery).
  If wanted, it is a follow-up issue with its own Done-when.

### #74 web_search

- `Tools`: `@params["web_search"] = [query: string, required, nonempty]`; description
  ("Search the web…") appended to `@order`. `schema(synthetic \\ nil)`: web_search is
  advertised ONLY when synthetic != nil; other tools unchanged. `validate/2` stays total
  over the table (a hallucinated web_search without a key validates, then the runner
  errors "web search is not configured" — honest single source of truth, smallest diff).
- New `DashFloat.Tools.WebSearch` (`lib/dash_float/tools/web_search.ex`):
  `run(args, opts)` — no `search` opt → `%{ok: false, error: "web search is not configured"}`.
  POST `%{"query" => q}` Bearer-keyed to the search url, `retry: false`,
  `receive_timeout:` (`:search_timeout` opt, default 15_000). 2xx + `{"results" => list}` →
  `%{ok: true, query: q, content: <one JSON line per result, \n-joined>, count: n}` (content
  key so the agent's display_excerpt works); non-list/missing results → error; non-2xx →
  `web search failed: HTTP <status>`; timeout → `web search failed: timed out`; transport →
  `web search failed: connection error`. Never raises.
- `Runner.run/4` case clause `"web_search"` → WebSearch.run(args, opts).
- `Agent`: `Tools.schema()` → `Tools.schema(state.synthetic)` in `start_episode`;
  `dispatch_runner` opts gain `search: %{url: Synthetic.search_url(ctx), api_key: ctx.api_key}`
  (nil without ctx); `automatic?("web_search") -> true` (read-only, no confirmation;
  Preview never sees it).

### Slice split (workers glm-5.3-flash; sequential in this worktree — both slices touch agent.ex, parallel would collide)

- Slice A (do first): synthetic.ex + ToolCalls raw_args + ChatStream repair + Agent
  synthetic opt + ADR 0014 (repair sections; see below) + README index row + tests:
  synthetic_test.exs (discovery, search_url, repair round-trip vs SSEServer: success /
  fixed-non-map / 500 / timeout via `{:sleep, ...}` script + `repair_timeout: 50`), 
  tool_calls raw_args, agent loopback repair round-trip (conn 0: stream a read_file call
  with args fragment `{"path": "a.txt` truncated; conn 1: repair response; conn 2: final
  episode; assert repair request model id + prompt contains the broken JSON; assert the
  NEXT request's assistant tool_calls arguments are the REPAIRED JSON and the tool result
  is the real read), no-key byte-identical (one connection only; next request's tool
  message == `{"ok":false,"error":"invalid JSON arguments"}`, assistant args `"{}"` —
  today's exact encoding), repair-failure-degrades identically, cancel-during-repair
  (sleeping repair script + `{:cancel}` → `[cancelled]`, idle).
- Slice B (on top of A): Tools gating + WebSearch module + Runner clause + Agent threading
  + ADR search section + tests: schema with/without ctx, web_search loopback round-trip
  (assert `{"query": ...}` body + Bearer header + results rendered), timeout (sleep script
  > search_timeout), non-2xx, bad shape, not-configured, agent-level: advertised tools
  array INCLUDES web_search with ctx (assert in conn-0 forwarded body) / EXCLUDES without,
  search result lands in the next request's messages.

### ADR 0014 (`docs/decisions/0014-synthetic-extras.md`)

Nygard format per `docs/decisions/README.md`. Sections: key discovery (host set, active
profile), repair trigger conditions (error == "invalid JSON arguments" + raw_args + ctx),
model ids (fix-json wired; diff-apply recorded + deferred with the reasoning above),
fallback (no key / any repair failure / timeout → today's path, byte-identical), cancel
semantics (a cancel during a repair attempt still wins), search gating + endpoint +
timeout. Add the README index row (covers both issues; slice B appends the search section).

## Done-when checklist (from the issue bodies)

- #73: fixture-driven malformed tool_call repaired through the real request path (loopback
  round-trip) and the turn proceeds; no-key legacy path byte-identical; ADR records
  triggers + model ids + fallback; `mix ci` green.
- #74: with a key fixture the tool appears in the session's tool list + a driven round-trip
  returns loopback results into context (assert via the seams); without a key the tool is
  absent from the registry; timeout path tested; `mix ci` green.

## Process state at park time (for the resuming session)

- Quota at fan-out check (Oct 29 ~05:00 Manila, off-peak): Z.AI tokens 10% / time 1% →
  workers on `zai-coding-plan/glm-5.3-flash`, reviewer on the OPPOSITE host
  (`synthetic/syn:large:text`), own Herdr tab `df73-review-synthetic`, own worktree, fresh
  context, READ-ONLY, no Synthetic creds for live probes — loopback evidence is the standard.
- Gate order: gate 1 = architect's own DoD re-runs; gate 2 = hostile review after gate 1;
  merge only after both (+ delta re-check), squash PR titled as a conventional commit.
- COORDINATION: the Phase 4 and sysprompt lanes touch adjacent request-path code —
  freshness-rebase onto main before merge (watch PR #57-era merges) and report collisions.
- `mix deps.get` before tests (fresh worktree, no deps fetched yet). Worktree-local
  untracked `opencode.jsonc` pins the architect model; leave it in place.

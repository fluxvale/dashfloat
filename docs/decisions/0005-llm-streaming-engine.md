# 0005 — LLM streaming engine: SSE adapter process architecture

- **Status:** Accepted
- **Date:** 2026-10-23
- **Implements:** [issue #8](https://github.com/fluxvale/dashfloat/issues/8) — Phase 2 of the
  [ADR 0001](0001-founding-stack-and-architecture.md) roadmap. Supersedes the
  synthetic demo path in [ADR 0002](0002-tui-skeleton.md); the stream message
  contract there is unchanged and remains the integration surface. The usage
  row in the error-taxonomy table below is amended by
  [ADR 0006](0006-ui-truth-and-rendering.md).

## Context

Phase 2 replaces the synthetic producer with a real OpenAI-compatible SSE
client. The `req` 0.7.5 / `finch` 0.24 surface was read from the dependency
source before deciding:

- `Req.post(url, …, into: :self)` returns once status + headers have arrived
  (it issues `Finch.async_request` and receives them internally). Connection
  failures — DNS, refused, TLS, pool/header-phase timeouts — return
  `{:error, exception}` from that call; no receive loop has started yet.
- Afterwards body events land in **the caller's mailbox** as
  `{ref, {:data, binary}}`, `{ref, :done}`, `{ref, {:trailers, _}}`,
  `{ref, {:error, reason}}`; `Req.parse_message/2` normalizes them and
  `Req.cancel_async_response/1` closes the connection.
- Finch's HTTP/1 async helper **monitors the requesting process**: if it dies,
  the socket is closed. Cancellation is therefore kill-safe in both directions.
- Req's default retry only covers safe methods, but a streaming
  `POST /chat/completions` is non-idempotent and billed; we set `retry: false`
  explicitly. Redirects are refused for the same reason (`redirect: false`):
  following one would silently re-POST the completion.
- Two inputs bypass the request path entirely: Req raises — or finch
  `exit(:badarg)` — before a request exists for an unusable `base_url` (no
  scheme or host, embedded whitespace, out of range port, non-ASCII host) or
  an `api_key` containing non-printable ASCII (Mint validates header values).

## Decision

### Process architecture — the producer slot, no new processes

`DashFloat.LLM.ChatStream.run(ui, provider, prompt, opts \\ [])` is the Task
body started by the TUI on submit under `DashFloat.StreamSupervisor`
(`restart: :temporary`, monitored by the UI) — exactly the producer slot ADR
0002 defined. The UI process is untouched: it still performs zero I/O, still
understands only the ADR-0002 message contract
(`{:token, _}` / `{:phase, _}` / `{:entry, _, _}` / `{:DOWN, …}`).

```
UI process (ExRatatui.Server)          DashFloat.LLM.ChatStream (Task, temporary)
  submit ──Task.Supervisor.start_child──▶ build request
                                          Req.post(into: :self, retry: false)
  ◀── {:token, delta} ──────────────────  receive loop (parse_message + SSE)
  ◀── {:entry, :system, …} ─────────────  error/cancel paths
  ◀── {:phase, :idle} ─────────────────  terminal message, then exit :normal
```

The stream handler always sends its own terminal `{:phase, _}` before exiting
(the ADR-0002 rule); the UI's monitor stays a safety net, never the reporter
of record.

**No retries, no redirects, no bad inputs at the door.** `ChatStream` sets
`retry: false` and `redirect: false`: a retried or followed streaming
completions POST duplicates generation and billing, so both are refused. It
also validates the endpoint and key before calling Req — `base_url` must be an
`http(s)` URL with an ASCII host, no embedded whitespace, and a port in range;
`api_key` must be printable ASCII. Unguarded, such a config would kill the
producer before its terminal message, surfacing as `[stream failed: …]`
instead of the `[llm: …]` taxonomy. Validated, each case degrades to a
`[llm: connection failed: …]` entry naming the problem (never the value) and
the terminal idle phase, exactly like a transport failure. A non-ASCII key is
refused outright rather than scrubbed after the fact: Mint quotes header
values in its error, and the quoting form varies, so no replace list is
reliable.

### Token granularity and backpressure — no drop policy

One `{:token, text}` message per **SSE data frame** (the provider-native delta
granularity) — not per socket chunk, not per line, no batching, no flushing
timer, no drops. Rationale: token messages are pure data appended in `O(1)`;
the render loop coalesces queued messages into single frames
([ADR 0002](0002-tui-skeleton.md)), so a burst of N tokens costs N appends and
one render, bounded by the viewport. The coalescer *is* the backpressure
valve; the Phase-1 responsiveness test already proves keystroke round-trips
stay under 100 ms through a 300-token burst at cadence, and a Phase-2 test
re-proves it through the real engine. Dropping or sampling tokens in the
producer would corrupt replies to defend a render loop that needs no defense.

### Cancellation semantics

`Esc` while the phase is `:streaming` cancels. Order of events:

1. The TUI sends `:cancel` to the task pid (a no-op if the task already died).
2. The task calls `Req.cancel_async_response/1` — the upstream connection
   closes; the provider stops generating (and billing).
3. The task sends `{:entry, :system, "[cancelled]"}` and `{:phase, :idle}`
   (which finalizes the partial reply as an assistant entry), then exits
   `:normal`.
4. The later `{:DOWN, _, :process, _, :normal}` is a no-op safety net.

What dies: the HTTP request first, then the task. What the UI shows: the
partial reply kept, a gray `[cancelled]` line, status `Idle`, input usable
immediately. If the task is wedged and ignores `:cancel`, the existing
monitor/kill safety net from ADR 0002 still applies — and finch's
owner-monitor closes the socket the moment the task dies.

### Error taxonomy — every path degrades to a chat entry

Failures never crash the node and never bypass the terminal message. Partial
content is always finalized. The API key never appears in any message — error
text carries status codes and provider-supplied text only.

| Failure | Detection | Chat log entry |
| --- | --- | --- |
| Connect refused / DNS / TLS / header timeout | `Req.post` returns `{:error, e}` | `[llm: connection failed: <message>]` |
| HTTP non-2xx | initial status; drain body ≤ 64 KiB, ≤ 5 s | `[llm: HTTP 401 — <provider error.message>]` (fallback `[llm: HTTP 502]`) |
| Malformed frame (`data:` payload is not valid JSON) | decode error mid-loop | cancel + `[llm: malformed SSE data frame — stream aborted]` |
| Valid JSON frame without `choices[0].delta.content` (role-only, usage, keepalive frames) | shape miss | skipped silently — not an error. (Amended by [ADR 0006](0006-ui-truth-and-rendering.md): usage frames are consumed and forwarded as `{:usage, _}` messages.) |
| Connection dropped mid-stream | `{ref, {:error, _}}` | `[llm: connection lost mid-stream]` |
| Stream ended without `[DONE]` | `{ref, :done}` before `[DONE]` | `[llm: stream ended without completion]` |
| No data for 60 s (configurable via `:idle_timeout`) | socket `receive_timeout`, with the receive `after` as backstop | cancel + `[llm: timed out waiting for stream data]` |
| Single SSE frame larger than 1 MiB (a stream that never delimits a frame) | buffer cap in `ChatStream` | cancel + `[llm: SSE frame exceeded 1 MiB — stream aborted]` |
| SSE comment / unknown field lines | parser | ignored per the SSE spec (keepalives) |

### SSE parsing — a pure incremental parser

`DashFloat.LLM.SSE` is pure: `new/0`, `feed/2 → {[%{data: binary}], parser}`,
holding back partial frames in a buffer until a blank line completes them.
Line endings: LF and CRLF (the OpenAI-compatible ecosystem; lone CR is not
handled). Only `data:` lines are extracted — `event:`/`id:`/comments are
dropped per spec. `[DONE]` is interpreted by `ChatStream`, not the parser. The
parser is unbounded by design; `ChatStream` caps the held-back buffer at 1 MiB
and aborts a stream that never delimits a frame.

### Provider config — one endpoint, file + env

`DashFloat.Config.load/0` reads JSON at
`:filename.basedir(:user_config, "dashfloat")` → `config.json` (honors
`XDG_CONFIG_HOME`; fields `base_url`, `model`, `api_key`), then overlays
per-field env overrides `DASHFLOAT_BASE_URL`, `DASHFLOAT_MODEL`,
`DASHFLOAT_API_KEY`. Missing/blank fields after the merge yield
`{:error, message}` naming **only the missing fields** — never the values
present. Loading happens once in `Application.start/1` and rides into the TUI
as mount opts (`provider:`), keeping file I/O out of the UI process. Without a
usable provider the TUI still runs; submitting degrades to a system entry with
setup instructions. The endpoint is one OpenAI-compatible URL:
`base_url <> "/chat/completions"`, `stream: true`, `Authorization: Bearer`.

*(This section's file layout and precedence are superseded by
[ADR 0008](0008-config-layout-profiles-json5.md) — octofriend-style JSON5
files with profiles. The load-once-in-Application contract, the mount-opt
handoff, and the never-echo-values error rule stand, as restated there.)*

### Testing — recorded bytes and a loopback server

The SSE parser is tested on recorded byte-stream fixtures (fed whole and
byte-by-byte). `ChatStream` and the TUI integration run against a one-shot
`:gen_tcp` loopback server (127.0.0.1, ephemeral port) scripted per test with
exact bytes, sleeps, and closes — deterministic, no external network, no new
dependencies. Live-key smoke is a documented manual step.

## Alternatives considered

- **`into: fun` / `into: collectable`** — chunks are delivered while blocked
  inside Req; cannot select on cancel or timeouts between chunks. Control is
  the point; rejected.
- **Raw finch/mint** — re-implements URL/headers/JSON handling req already
  owns; [ADR 0001](0001-founding-stack-and-architecture.md) already chose req.
- **Kill-only cancellation** — a `:killed` DOWN reads
  `[stream failed: :killed]` and skips graceful partial finalize; kept as the
  safety net, not the user path.
- **Token batching / drop policy in the producer** — lossy complexity
  defending a render loop that already coalesces; violates "messages are
  data". Rejected.
- **Retries and redirect following** — a streaming completions POST is not
  resumable; retrying or following a 307/308 duplicates generation and
  billing. Neither.
- **TOML config** — adds a dependency; jason already ships. JSON chosen.
- **Reading config in `mount/1`** — file I/O in the UI process; loaded in
  `Application.start/1` instead.

## Consequences

- The UI seam is unchanged: `ChatStream` is just a new producer speaking the
  ADR-0002 contract; the synthetic demo module is deleted.
- Tests open real loopback sockets; CI stays offline and deterministic.
- The parser covers LF/CRLF only; a lone-CR server would stall (none exists in
  this ecosystem). A frame over 1 MiB aborts the stream rather than growing the
  buffer without bound.
- Without provider config the TUI can no longer produce replies — the demo
  path is gone by design; the config error entry carries setup instructions.
- One in-flight request at a time stands (ADR 0002); queueing stays out.
- The endpoint/key pre-flight narrows what config is usable: a key outside
  printable ASCII cannot be used at all, and a non-HTTP(S), non-ASCII-hosted,
  or otherwise malformed base URL is reported at submit time as
  `[llm: connection failed: …]` instead of reaching the network.

# 0014 — Session persistence: transcript store, resume, dangling repair, pinning

- **Status:** Accepted (design; the plan gate of 2026-10-27). Implementation
  lands through [issue #27](https://github.com/fluxvale/dashfloat/issues/27).
- **Date:** 2026-10-27
- **Implements:** [issue #27](https://github.com/fluxvale/dashfloat/issues/27) — Phase 4
  of the [ADR 0001](0001-founding-stack-and-architecture.md) roadmap.
- **Extends:** [ADR 0006](0006-ui-truth-and-rendering.md) (amended below and
  in that file: the transcript, not entry text, is the persistence truth),
  [ADR 0007](0007-tool-calls-and-execution.md) (the transcript shape and the
  dangling-`tool_calls` rule), [ADR 0008](0008-config-layout-profiles-json5.md)/
  [ADR 0009](0009-config-v3-persona-profiles.md) (atomic tmp-0600+rename write
  posture, malformed-file tolerance, profile/model selection vocabulary).
  Nothing is superseded.
- **Governs:** this slice (#27) and the context-accounting/compaction slice
  ([#43](https://github.com/fluxvale/dashfloat/issues/43)) — both read the
  same transcript. This ADR's scope is #27 only.

## Context

Closing the TUI loses the conversation: `DashFloat.Agent`'s `state.messages`
dies with the BEAM and the next launch starts blank. Two facts verified in
code shape everything below:

1. **There are two "conversations" and only one is real.** `state.messages`
   is provider-shaped (assistant messages carry `tool_calls` with ids and
   full argument JSON — `begin_tool_batch/3`; tool messages carry
   `tool_call_id` plus the complete bounded result the model received —
   `flush_tool_messages/1`). `TUI.State.entries` is display-only: a tool
   row's `text` is a `display_excerpt/1` capped at 30 lines with no tool
   ids. Persisting the log and reloading it would render a convincing
   transcript and then fail on the first send — ADR 0007 §1 rejects a
   transcript whose `tool_calls` have no results.
2. **A kill can land between a tool call and its results.**
   `begin_tool_batch/3` appends the assistant `tool_calls` message *before*
   any tool runs, so a kill mid-batch persists exactly the dangling shape
   ADR 0007 §1 forbids — if the write happens at every message-list
   mutation. Repair at load is therefore a requirement, not an
   embellishment: the in-process cancel path already synthesizes
   `{"ok":false,"cancelled":true}` results for unresolved calls
   (`fill_cancelled/1`), and load reuses that shape.

## Decision

### 1. One artifact, one truth

**The session file persists `state.messages` — the agent transcript — and
nothing else display-shaped.** The log is derived: live from the display
contract (unchanged), on resume by replaying the transcript through the
render pipeline (§6). This amends ADR 0006 (see that file's 2026-10-27
amendment): entries become derived state; `text` stays the render cache.

The **UI process still performs zero I/O** (ADRs 0005/0007): the
conversation is the agent's, so the agent persists it. The TUI only ever
receives display-contract messages.

### 2. Store: one module, one file per session

`DashFloat.Session` owns the whole store.

- **Location:** the XDG data directory —
  `:filename.basedir(:user_data, "dashfloat") |> Path.join("sessions")` →
  `~/.local/share/dashfloat/sessions/` (verified on this OTP; XDG_DATA_HOME
  respected). Sessions are data, not config — the config directory holds
  credentials. The directory is created on demand at the first save
  (`File.mkdir_p`, the config layer's `ensure_dir` pattern).
- **One file per session:** `<sessions>/<id>.json` (compact JSON via Jason,
  newline-terminated). Machine files, not hand-editing targets — but
  readable enough to hand-repair, which the tolerance rules rely on.
- **0600, atomically, always:** every write goes through
  `DashFloat.Config.Posture.write_private/2` — a temp file created empty at
  0600 under a **unique** staging name (`<path>.tmp.<random>`), filled,
  renamed into place. No reader or crash ever sees a torn file; concurrent
  writers of one path never share a staging file (§7); a symlink planted
  at a predictable staging name has nothing to intercept. Transcripts
  carry source code and tool output read off the user's disk — the mode is
  mandatory, not courtesy.
- **Session ids:** `YYYYMMDD-HHMMSS-xxxxxx` — UTC wall clock plus six hex
  chars of `:crypto.strong_rand_bytes/1`. Name-sortable ≈ time-sortable,
  typeable, collision-safe in practice. Discovery is the filesystem: the
  README documents `ls ~/.local/share/dashfloat/sessions/`; `--continue`
  (latest) and an in-TUI picker are future slices.

### 3. File schema (version 1)

```json
{
  "version": 1,
  "id": "20261027-143052-a1b2c3",
  "created_at": "2026-10-27T14:30:52Z",
  "pin": {
    "profile": "personal",
    "model": "glm-5.3",
    "base_url": "https://api.z.ai/api/coding/paas/v4"
  },
  "messages": [ … provider-shaped, exactly DashFloat.Agent's state.messages … ]
}
```

- **`messages`** is the agent's message list verbatim, in order. In memory
  it is atom-keyed maps; JSON round-trips it as string-keyed maps — and
  that is fine by design: `ChatStream` only Jason-encodes `messages` into
  the request body (atoms and strings encode identically), so a resumed
  list (string-keyed) and newly appended messages (atom-keyed) mix freely.
  **Nothing may atomize loaded messages** — tool ids and content are
  provider strings; dynamic atoms are a leak.
- **`pin`** records the profile and model the session started with
  (`profile`, `model` — the comparison fields) and `base_url` (endpoint
  identity per ADR 0009, pinned for diagnostics). It is written **once,
  at the first save**, from the effective provider config's named fields
  — built field-by-field, never by encoding a config struct — and is
  **immutable for the session's life** (§5).
- **`version`** is `1`. A file whose version is newer than this binary
  knows is refused for that session, naming the field and both values —
  never reinterpreted, never rewritten. A missing or non-integer `version`
  is malformed (§4). Unknown **top-level** fields are ignored silently:
  additive evolution rides inside v1 where older binaries must tolerate
  it; anything that changes how existing fields are *read* bumps the
  version (which old binaries then refuse). This is the #43 seam —
  accounting/compaction reads the same `messages` and may add fields, not
  reinterpret them.
- **Never a credential by the writer's own hand.** The file holds `version`,
  `id`, `created_at`, `pin`, `messages` — nothing else. The writer receives
  the message list and three pin strings, never the key: `api_key` values,
  keys.json5 contents, and environment values have no path into what the
  writer serializes. **What the transcript itself carries is different and
  deliberate:** user text and tool results are persisted *verbatim* — the
  transcript must replay exactly what the model saw, so a tool that printed
  a secret (`env`, a build log) persists it too. That is precisely why the
  0600 mode is mandatory (the issue's own rationale: transcripts carry
  source code and tool output read off disk). `pin.base_url` is sanitized
  to `scheme://host[:port]/path` (userinfo, query, and fragment dropped) —
  it is our metadata, not conversation, and a URL-carried key must not sit
  in it.
- **Unknown top-level fields are ignored AND dropped:** an older binary
  that resumes a file with newer top-level fields tolerates them at load
  and omits them on its next save (tolerance means no crash, not
  preservation). Additive fields that must survive an older binary's
  re-save live **inside** `messages` entries, which are carried verbatim
  (`pin` is rebuilt from its three fields at load — extras inside it do
  not survive). Anything that changes how existing fields are *read* bumps
  the version (which old binaries then refuse). This is the #43 seam —
  accounting/compaction reads the same `messages` and nests its additions
  there.

### 4. Load: tolerance, refusals, repair

`Session.load(dir, id)` returns `{:ok, session}` or `{:error, message}`
(messages name paths and reasons, never values) and never writes.

- **Unknown id** (no file for it, including a missing sessions directory):
  error naming the sessions directory and the id.
- **Unparseable / truncated / unreadable file:** loud error naming the path
  and the reason. Never auto-deleted, never auto-overwritten — the config
  migration's discipline per file.
- **Shape validation:** the top level must be a map with `version` (above),
  a string `id` equal to the requested id (a renamed or shuffled file
  refuses; a requested id ending in `.json` is tolerated — the README's own
  `ls` prints the file name), a string `created_at` (our writer always
  records it; a file without it is malformed), and a `messages` list. The
  `pin` degrades tolerantly — missing, non-map, or non-string fields
  compare as nil (§6's nil-compare rule) rather than refusing. Each
  message must match its role's
  provider shape — `user`: binary `content`; `assistant`: binary-or-nil
  `content` and an optional list `tool_calls` (each with binary `id`,
  `type`, `function.name`, `function.arguments`); `tool`: binary
  `tool_call_id` and binary `content`. A violating message refuses the
  **whole file**, naming the message index and the field — a partially
  dropped transcript would be a silent lie; the honest outcomes are
  all-or-nothing. (`function.arguments` stays an opaque string at load:
  the provider gets it verbatim; only replay decodes it, for display.)
- **Dangling repair (in memory, at load):** for every assistant message
  with `tool_calls`, each announced call id with no matching tool message
  before the next user/assistant message gets a synthesized
  `%{"role" => "tool", "tool_call_id" => id, "content" => "{\"ok\":false,\"cancelled\":true}"}`
  appended at the end of that batch's tool block — the same result shape
  the agent's cancel path writes (`fill_cancelled/1`; share one helper,
  `DashFloat.Tools.cancelled_result/0`). This is the repair for the one
  crash shape this codebase can produce (§ Context 2). The file on disk is
  not rewritten by the repair; it converges on the next save.
- **Orphan tool messages** (a `tool_call_id` matching no announced call)
  refuse as malformed — no write path of ours can produce one, so it is
  hand damage, and the refusal names it. **Two further shape rules from
  the hostile review:** a batch whose `tool_calls` repeat an id refuses
  (dup ids make one answer "cover" two calls — the repair would serve an
  unbalanced transcript), and a tool message must sit in the **contiguous**
  tool block following its batch — an answer detached past a user or
  assistant message refuses, and so does a second answer for a call the
  same block already answered (validation and repair must agree on what a
  batch's block is, and one call takes exactly one answer).

- **Id uniqueness is owned at the persistence boundary (ADR 0007 §1
  refinement).** ADR 0007 left id uniqueness to providers for the *live*
  round trip; persistence makes ids load-bearing across processes, so the
  agent de-duplicates ids when it appends the assistant `tool_calls`
  message (occurrence rename: `id`, `id-2`, … — the assistant message,
  dispatch, results, and tool messages all carry the renamed ids, so the
  round trip stays internally consistent), and `DashFloat.LLM.ToolCalls`
  treats an empty-string id like a missing one (the sloppy-provider
  synthesis). The loader's dup refusal above is the backstop for
  hand-damage.

**Never bricks startup:** every load failure is a `{:error, message}`, and
the boot path (§7) turns it into a clean refusal or a warning — never a
raise, never a blank session replacing a conversation the user named.

### 5. Writes: at every message-list mutation

The agent persists the transcript **at each of the five sites that mutate
`state.messages`** — inside the mutating helper, so no call site is missed:

1. the `{:prompt, _ui, _text}` handler, after appending the user message (a
   kill mid-stream must lose at most the reply, never the question);
2. `begin_tool_batch/3`, after appending the assistant `tool_calls` message
   (this is what makes the dangling shape real on disk — and repairable);
3. `flush_tool_messages/1`, after appending the batch's tool messages;
4. `finalize_episode/2`, after appending assistant content;
5. `fill_cancelled/1`, after appending the cancelled results.

Each write is a **full-file rewrite** of the schema above. A session file
appears iff at least one turn was started (the id is minted at the first
save; a launch-and-quit leaves nothing). Size is unbounded in this slice —
same as the in-memory transcript; #43 owns accounting.

**Save failures degrade, never crash:** a failed save (disk full,
unwritable directory) logs a warning and appends one system entry naming
the session path — the turn continues. Persistence is a courtesy of the
agent loop, not a participant in it.

**Agent opts:** `:session_dir` (default **nil = persistence disabled**) and
`:resume` (the loaded session's `id`/`pin`/`messages`). The nil default is
deliberate: tests (and any embedded starter) must opt in — an implicit real
XDG path would have every test suite writing to the user's home. The
Application always passes the real directory outside test.

### 6. Resume: `--resume <id>`

**UX:** `dashfloat --resume 20261027-143052-a1b2c3` continues that session.
`--continue` (latest) and an in-TUI picker are future slices.

**Boot (`DashFloat.Application`, after classification, before children):**

- Load the session. **Failure refuses:** the message goes to stderr and the
  boot returns an error tuple (exit non-zero) — the same shape as the
  interactive-setup refusal. The user asked for a specific conversation;
  silently starting blank is the one outcome the refusal exists to prevent,
  and it applies to *every* load failure (unknown id, unparseable,
  truncated, unreadable, version, shape) — one rule: **you get the
  conversation you named, or a loud refusal naming the path and the
  remedy.** The refused file is byte-identical afterwards. (This shapes the
  issue's tolerance clause: malformed session state never raises and never
  bricks the boot path — the refusal *is* the graceful path — and a boot
  without `--resume` never touches session files at all.)
- **Pin compare — warn, never refuse, never rewrite:** when classification
  is `{:ok, config}`, compare `pin.profile` and `pin.model` against the
  active profile/model (fields where both sides are non-nil; an env-only
  session pins nil profile fields and compares nothing). Any mismatch
  produces a warning naming both sides — pinned and active — as
  `Logger.warning` *and* as a `:system` entry appended at the bottom of the
  replayed log (the alt screen swallows Logger; #39's lesson: warnings the
  user must see ride the surface). Cross-profile resume proceeds: window
  and tool support may differ, and the model will tell.
- **Hand-off:** the agent boots with `session_dir` plus `resume:` (id, pin,
  messages — subsequent saves rewrite the same file under the same id); the
  TUI boots with `transcript:` (the same loaded message list) and
  `resume_note:` (the warning text or nil). One load, two consumers, one
  truth.

**Replay (the log is derived):** `DashFloat.TUI.State.new/1` gains
`transcript:` (default `[]`) and `resume_note:` (default nil); when a
transcript is present, entries are built by replaying it through the
existing render path — per message type, because the tool builders do not
round-trip through `entry_lines/2`:

- `user` / `assistant`-with-content → `Render.entry_lines/2` (assistant
  rides the markdown mapper);
- `assistant`-with-`tool_calls` → `Render.tool_call/2` per call, decoding
  `function.arguments` for the summary (decode failure renders the
  existing "(invalid arguments)" arm);
- `tool` → `Render.tool_result/3`, with the call's name looked up by
  `tool_call_id` in the preceding batch, the result JSON decoded, and
  status + 30-line display excerpt derived by the same helpers the agent's
  display messages use (`DashFloat.Tools.display_status/1`,
  `DashFloat.Tools.display_excerpt/1` — extracted from `DashFloat.Agent`,
  which keeps calling them; one derivation, two callers).

Everything lands through the same `put_entry` path as live entries:
`logical` freshly built, `lines` wrapped at the current width, `follow?`
true — the resumed log opens pinned at the bottom. **Nothing display-only
survives resume** (`[cancelled]`, stream-failure entries, confirm previews
were never in the transcript; the excerpt cap is recomputed from the full
result). A tool message whose content does not decode displays as an error
row, never crashes. The resume note, if any, appends last as a `:system`
entry. Input history (the draft-recall list) is not restored — display
convenience, out of scope.

**Next turn continues the conversation:** the first prompt after resume
sends the full restored history — no truncation, no accounting. That is
#43's lane; the seam is the transcript itself.

### 7. Concurrency and truth

No locking: two DashFloat instances resuming the same session both write
the same file. Each save is atomic through a **unique temp name**
(`Posture.write_private` stages at `<path>.tmp.<random>` — two concurrent
writers never share a staging file, so neither can tear the other's
write), and the file is always one writer's consistent payload;
last-writer-wins. Accepted — a single-user local harness; the alternative
(lock files) buys little and bricks resume after a kill, the exact case
this slice exists for. *(The unique tmp name is the hostile review's fix:
a shared fixed `.tmp` path let two writers interleave and, at rest,
corrupt the destination permanently.)*

## Interface freeze

- `DashFloat.Session`: `dir/0`, `new_id/0`, `save(dir, session) :: :ok |
  {:error, String.t()}`, `load(dir, id) :: {:ok, session} | {:error,
  String.t()}`; `session` per §3 (`%{version: 1, id: id, created_at: bin,
  pin: %{profile: _, model: _, base_url: _}, messages: [msg]}`).
- `DashFloat.Tools`: `cancelled_result/0`, `display_status/1`,
  `display_excerpt/1` (moved from `DashFloat.Agent`'s privates; the agent
  swaps to them).
- `DashFloat.Agent` opts: `:session_dir` (nil = off), `:resume`
  (`%{id: _, pin: _, messages: _}` | absent).
- `DashFloat.CLI`: `--resume <id>` / `--resume=<id>` → `[resume: id]`,
  same parse discipline as `--profile`.
- `DashFloat.Application`: `--resume` handling per §6; args seam gains
  `:sessions_dir`; agent opts gain `session_dir:`/`resume:`; TUI mount
  opts gain `transcript:`/`resume_note:`.
- `DashFloat.TUI.State.new/1` opts: `:transcript`, `:resume_note`.

## Alternatives considered

- **Persist the TUI log (entries/text)** — rejected: it is display-shaped;
  resume would replay prettily and fail on the first send against ADR 0007
  §1 (no tool ids, truncated results). The founding mistake ADR 0006's
  amendment now closes.
- **Append-only event log (JSONL per message)** — rejected for now: atomic
  per-state full rewrites are simpler, self-healing (the previous good file
  survives any kill), and the transcript is already memory-bounded by the
  episode rules; #43 can revisit when size is actually a measured problem.
- **SQLite / a database** — rejected: one-user, one-file-per-session, no
  queries; JSON files are inspectable and hand-repairable, which the
  tolerance rules lean on.
- **Atomizing loaded message keys** — rejected: provider strings as atoms
  is an unbounded-atom leak; encoding treats atoms and strings alike.
- **Repair-by-rewriting the file at load** — rejected: load never writes;
  the repair converges on the next save instead.
- **Resume-latest (`--continue`) / in-TUI picker** — future slices, named
  by the issue; `--resume` is the one to lead with.
- **Silent fresh start when the named session won't load** — rejected: it
  is the blank-session outcome the unknown-id refusal exists to prevent;
  refusal is uniform across load failures.
- **Locking concurrent resumers** — rejected (§7).

## Consequences

- Closing the TUI no longer loses the conversation; killing DashFloat
  mid-tool-batch leaves a repairable dangling transcript instead of a
  guaranteed 400 on naive resume.
- Session files hold source code and tool output from the user's disk —
  0600 is load-bearing, and any future writer must ride
  `Posture.write_private/2`.
- The ADR 0006 persistence-truth clause is relocated (amendment in that
  file); entries are derived forever after.
- The transcript grows without bound in memory and on disk this slice —
  honest, and #43's contract (same file, additive fields within v1).
- The status bar's context total starts at "—" after resume (usage frames
  are not persisted) — honest; banking history usage is #43's.
- `DashFloat.Agent`'s state gains a session identity; its tests gain a
  tmp-dir discipline (`session_dir:` opt-in) mirroring the config suite's.

## Test plan (the issue's Done-when, refined)

All under tmp-dir discipline; network only via the loopback SSE server.

1. `mix ci` green (format, warnings-as-errors, credo strict, dialyzer,
   coverage floor), patch coverage 100% on the diff.
2. **Kill round-trip:** drive a real agent to a mid-batch kill — the
   scripted episode announces a mutating tool, the test (as UI) receives
   the confirmation and instead kills the agent with an uncatchable
   `Process.exit(pid, :kill)` (no terminate callback runs; the on-disk
   truth is the last completed atomic write — SIGKILL semantics for the
   process). The persisted file holds the dangling `tool_calls` shape; a
   fresh agent started with `resume:` restores `messages` equal to the
   pre-kill list plus synthesized cancelled results; the first request
   after resume, asserted against the loopback server's forwarded body,
   carries the same `tool_calls` ids, the same `tool_call_id`s, and the
   full untruncated result JSON.
3. **Replay fidelity:** a resumed `State` holds one display entry per
   persisted message, tool rows built by `Render.tool_call/2` /
   `Render.tool_result/3`, `logical`/`lines` freshly built (assert the
   loaded entries are not read from disk), `follow?` true.
4. **Dangling repair:** a hand-written session whose assistant message
   carries `tool_calls` with no tool messages loads with one synthesized
   `{"ok":false,"cancelled":true}` result per call and completes a turn
   against the fixture server.
5. **Mode:** `stat -c '%a'` is `600` on a written session file, in a fresh
   (created-on-demand) directory and over an existing session.
6. **Secrets:** a turn run with a unique sentinel as the active
   `api_key` leaves `grep -R <sentinel>` over the sessions directory
   empty, and the string `api_key` appears as no key in any session file.
7. **Atomicity:** a stale `.tmp.*` file leaves the previous file loadable;
   concurrent saves on one id never tear (reader-under-writers test); the
   staging name is unpredictable, so a pre-planted symlink has nothing to
   intercept.
8. **Tolerance:** a truncated file, a garbage file, a missing directory,
   and an unreadable file each fail `load` with a message (no raise); under
   `--resume` each refuses the boot on stderr with no blank session;
   `--resume <unknown-id>` refuses naming the sessions directory.
9. **Version:** a session written with an unknown `version` refuses to
   resume naming the field, and the file is byte-identical afterwards.
10. **Pinning:** resume under a different `--profile` starts, warns naming
    the pinned and the active profile (system entry + log), and leaves the
    session's pin unchanged on the next save.
11. **Hostile-review pins:** duplicate or empty tool-call ids never reach
    disk (batch-boundary rename; empty synthesizes like nil); a hand file
    with a duplicate batch id refuses; a detached tool answer refuses; a duplicate answer refuses;
    concurrent saves on one id never tear (a reader under concurrent
    writers sees only whole payloads); a save whose encoding raises
    degrades to a warning; `pin.base_url` carries no query, fragment, or
    userinfo; the pin survives the next save after a cross-profile resume.

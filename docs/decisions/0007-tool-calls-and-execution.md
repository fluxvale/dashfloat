# 0007 — Tool calls & execution: the agent loop, five tools, safety policy, confirmations

- **Status:** Accepted (§4's confirmation lists are amended by [ADR 0016](0016-interaction-modes.md))
- **Date:** 2026-10-24
- **Implements:** [issue #18](https://github.com/fluxvale/dashfloat/issues/18) — Phase 3 of the
  [ADR 0001](0001-founding-stack-and-architecture.md) roadmap.
- **Extends:** [ADR 0002](0002-tui-skeleton.md) (message contract), [ADR 0005](0005-llm-streaming-engine.md)
  (ChatStream), [ADR 0006](0006-ui-truth-and-rendering.md) (rendering vocabulary, phases,
  activity line). Nothing is superseded; one ADR-0006 display rule is amended below
  (usage forwarding across multi-episode turns).

## Context

Phases 1–2 stream prose into a terminal. This slice makes DashFloat an agent: the model's
tool calls parse out of the stream, execute against the local machine under a path policy,
mutations wait for a human keypress, and results ride back into the conversation so the
model sees outcomes. The fourth ADR-0001 process — the Subprocess Executor — is built here
and wired into the second, the Agent Manager, which until now existed only as a roadmap
line. Non-negotiables inherited from the earlier ADRs: the UI process performs zero I/O
and owns the only timer (the ADR-0006 tick); everything crossing a process boundary is a
plain message; a tool failure is a *result*, never a crash.

## Decision

### 1. Tool protocol (OpenAI-compatible)

**Request side.** Every completion request carries the fixed five-tool catalogue
(ADR 0001's core toolset) as the `tools` array, plain JSON-schema parameters, no
`tool_choice` (provider default = auto), no `parallel_tool_calls` pin:

| Tool | Parameters |
| --- | --- |
| `read_file` | `path` (string, required), `offset` (int ≥ 1, default 1), `limit` (int 1–10 000, default 2 000) — 1-based line window |
| `write_file` | `path` (required), `content` (required) — creates parent directories |
| `edit_file` | `path`, `search_block`, `replace_block` (all required) — exact-string match, must match exactly once |
| `execute_command` | `command` (required), `cwd` (default `"."`) — a shell command line, run with `sh -c` semantics |
| `list_directory` | `path` (default `"."`) |

Providers without tool support fail through ADR-0005's HTTP error taxonomy — a chat entry,
not a crash.

**Response side — incremental `tool_calls` delta assembly.** OpenAI-compatible streams
deliver tool calls as `choices[0].delta.tool_calls` fragments: the first fragment for an
index carries `id`, `type`, `function.name` and the opening of `function.arguments`;
subsequent fragments carry only `index` and an `arguments` string fragment to concatenate.
Multiple calls interleave by `index`. `DashFloat.LLM.ToolCalls` is a pure accumulator:

```
new() :: t()
feed(t(), [delta_map()]) :: t()          # merge by index: id/name set once, arguments appended
finish(t()) :: [%{id: id, name: name, args: map() | nil, error: nil | String.t()}]
```

Rules, each driven by a test:

- Arguments are concatenated as **binaries** before any JSON parse, so a chunk boundary
  inside a multi-byte UTF-8 sequence or inside an escaped quote reassembles correctly.
  The suite feeds fixtures split at every byte offset.
- After `[DONE]`, each call's argument buffer is JSON-decoded. Malformed JSON is **not** a
  stream error: the call finishes with `error: "invalid JSON arguments"` and becomes an
  error *result to the model* (the stream itself stayed clean).
- A call that never received an `id` gets a synthesized `"call_<index>"` — the round trip
  must work even with a sloppy provider. Duplicate ids are not repaired; providers own id
  uniqueness.
- A call with arguments but no `name`, or a delta that is not a map, is dropped (an
  ADR-0005-style shape miss, skipped silently). A call that assembled arguments but
  never a name keeps its id and surfaces as an **error result** (`missing function
  name`) — round-trip safety beats dropping; the assistant message carries it with an
  empty name so the tool reply is never orphaned.
- `finish_reason` is ignored — the assembled calls alone decide whether an episode is a
  tool episode. A `tool_calls` finish with zero assembled calls is just a final turn.

**Round trip.** When an episode yields calls, the agent appends the assistant message
(canonical form: `arguments` re-encoded as a JSON *string*) and, after execution, one
`role: "tool"` message per call, in call order, `tool_call_id` echoing the provider id,
`content` a JSON-encoded result object. Results are structured, bounded, and honest:

```
{"ok":true,"path":"lib/foo.ex","content":"...","lines":120,"truncated":false}
{"ok":false,"error":"path escapes the working directory: ../../etc/passwd"}
{"ok":false,"rejected":true}                    # user pressed Esc on the confirmation
{"ok":false,"cancelled":true}                   # user interrupted a running command
{"ok":false,"error":"timed out after 30s","output":"...partial..."}
```

Every terminal path of the loop appends a tool message for every announced call — a
conversation with dangling `tool_calls` and no results is an API error waiting to happen;
cancel and interrupt therefore synthesize `rejected`/`cancelled` results for all
unresolved calls.

### 2. Execution architecture

The ADR-0001 four-process shape, filled in:

```
UI process (ExRatatui)      DashFloat.Agent (GenServer)         Tasks under DashFloat.TaskSupervisor
  submit ──{:prompt,ui,text}─▶ append to conversation ──start──▶ DashFloat.LLM.ChatStream (SSE + parse)
  ◀──display contract───────  forwards tokens, phases,            │ {:token}/{:usage}/
  {:confirm_decision,ref,──▶  orchestrates the tool loop,         │ {:stream_failed}/{:stream_done}
   :approved|:rejected}       builds previews, dispatches         ▼
  {:cancel} ────────────────▶ execution                        DashFloat.Tools.Runner (one Task per call)
                                 │                                 file tools: File module
                                 │                                 execute_command: Port (Exec)
                                 └─ {:tool_result, id, result} ◀───
```

- **`DashFloat.Agent`** is the Agent Manager: a GenServer owning the conversation message
  list, the episode loop (stream → tools → stream → … → idle), confirmation state, and
  the working directory that scopes every path. It is the *only* process that talks to
  the UI (single voice: ordering in the log is exactly the agent's ordering) and the only
  one ChatStream reports to. It holds no timers — timeouts live in ChatStream (network)
  and the runner Tasks (ports). It performs bounded file reads while building edit/write
  previews (engine-side I/O is sanctioned; the *UI* process still does none).
- **`DashFloat.LLM.ChatStream`** keeps its ADR-0005 body — SSE loop, error taxonomy,
  cancellation, frame cap — but now takes the full `messages` history plus `tools`, and
  reports to the agent instead of the UI: `{:token, text}` (forwarded verbatim),
  `{:usage, map}` (agent-gated, below), `{:stream_failed, text}` (engine-authored
  taxonomy text), and the terminal `{:stream_done, %{content: binary, tool_calls: [call],
  cancelled: boolean}}`. Token streaming latency stays one hop: ChatStream → agent → UI
  are two `send/2`s on one node.
- **`DashFloat.Tools.Runner`** executes one validated call inside a `restart: :temporary`
  Task: `read_file`/`write_file`/`edit_file`/`list_directory` via the `File` module,
  `execute_command` via `DashFloat.Tools.Exec` (a `Port.open({:spawn, …}, …)` with
  `:use_stdio`, `:stderr_to_stdout`, `:exit_status`, `cd:` the resolved cwd). Every
  failure — bad args, denied path, timeout, non-zero exit — is a normal result map
  returned to the agent. The runner never raises into the tree: anticipated errors are
  clause-matched; anything unexpected is caught by the Task's monitor and degrades to a
  `{:tool_result, id, {:crashed, reason}}` result.
- **`DashFloat.TaskSupervisor`** replaces `DashFloat.StreamSupervisor` (renamed: it now
  hosts tool-runner tasks as well as stream tasks — the old name would lie).

**Exec reality, verified against the runtime (not the docs):** `Port.open({:spawn,
command}, …)` prepends `exec` — a single command, no shell; `;`-chained tails are
silently dropped and builtins rejected. `Exec` therefore wraps every command in a
POSIX-quoted `/bin/sh -c` so the model's command lines mean what they say.
And `Port.close/1` closes the port but **never kills the port program**: a
busy-looping or backgrounded child would outlive it. Every exec completion path
(exit, timeout, cancel-kill) therefore also SIGKILLs the command's whole process
group (`setsid`-spawned under its own group) — no leaked grandchildren. What a
`setsid`-escaping child does beyond that is out of scope: a process sandbox is a
recorded future hardening option, not this slice. One accepted consequence: a
grandchild that inherits stdio and outlives the command holds the pipe open, so
`exit_status` may wait until the timeout — bounded, visible, honest.

**Write hardening:** `write_file`/`edit_file` write through an exclusive temp file
(`O_EXCL`, cryptographically random name, created in the target's own directory) and
`rename/2` into place — an attacker cannot pre-place a symlink at the temp name
between resolve and write, and an existing file's mode is preserved (no widening).
The residual parent-directory race (swapping a *directory* component between
realpath and open) remains accepted per §3's standing judgment.

Boundaries: exec output is head-capped at **32 KiB** with a trailing marker naming the
total byte count; `read_file` caps at 2 000 lines *and* 64 KiB (marker reports both
totals) — and reads are bounded, not just output: files above 256 KiB stream only the
requested line window (the exact line total is traded away; `truncated` is learned
from a one-line probe past the window); `edit_file` refuses files over 8 MiB by
stat, before reading; `list_directory` stats at most 501 entries (the alphabetical head of the sorted
names — a listing beyond the cap hides later-named entries, disclosed by
`truncated`; on this runtime `File.ls` silently skips non-UTF-8 names); edit
previews are window-capped at 50 lines with a marker, write previews likewise;
the episode's own accumulations (content plus tool-call ids, names, and
argument fragments — ids/names counted per fragment as conservative headroom)
abort the stream at **4 MiB** and
**64 distinct tool calls** — a trickling endpoint that never trips the idle timeout or
the frame cap still cannot grow memory without bound (the call cap counts distinct
stream indices, so one call split into a thousand fragments is one call). Exec timeout
default **30 s** (agent opt `:exec_timeout`, injectable for tests). Nothing buffers
without a bound.

### 3. Safety policy

**Path policy.** All five tools take paths relative to the agent's working directory
(the process cwd at startup; `:cwd` opt for tests). `DashFloat.Tools.PathPolicy.resolve/2`
runs before any file operation:

1. Lexical expand (`Path.expand(path, root)`) — collapses `..`, handles absolute paths.
2. Byte-prefix scope check against the root with a `/` boundary (`/home/u/root` must not
   admit `/home/u/root-evil`). An absolute path *inside* the root is fine; anything
   lexically outside is rejected.
3. Symlink check: realpath the deepest *existing* ancestor and require it to stay inside
   `realpath(root)`; the not-yet-existing lexical remainder cannot be a symlink. A
   symlink inside the tree pointing outside is therefore rejected — as is a `..` chain,
   an absolute outside path, or an escape via a symlinked intermediate directory.
   (`:file.realpath/1` does not exist on this OTP; the resolution is implemented once,
   in `PathPolicy`, on top of `:file.read_link_info/1`.) Mutations additionally write
   through an exclusive temp + atomic rename (§2), closing the check-then-open window
   at the file itself.

Residual risk, accepted and recorded: check-then-open is a TOCTOU window against an
attacker who can mutate the tree between resolve and open — an attacker who already has
local write access to the working directory, at which point DashFloat's boundary is not
the perimeter that matters. Byte-exact comparison (no case folding, no Unicode
normalization) is sound on case-sensitive filesystems and errs *strict* on
case-insensitive ones — a lexically-inside string can only resolve outside via a
symlink, which step 3 catches. `execute_command` is scoped only in its `cwd` argument;
the command itself is arbitrary — that is exactly why it sits behind a confirmation.

Rejections are *results to the model* and *rows in the chat log* — the failure is
visible in both places, never silent, never a crash.

**edit_file's search-block protocol.** `DashFloat.Tools.Edit.locate/2` counts exact
byte matches of `search_block` in the file: zero matches → error result
`search block not found`; two or more → error result naming the count. Only a unique
match mutates. Empty `search_block` is an error by construction (it matches everywhere);
`search_block == replace_block` is an error (a no-op write is a model bug worth
reporting back). Preview and runner share `locate/2`, so what the user approved is
byte-identical to what lands.

**Arg validation.** `DashFloat.Tools.validate/2` checks name against the catalogue and
every parameter's presence/type/range before execution; unknown tool or bad args →
error result, no execution, no confirmation.

### 4. Confirmation semantics

- **Automatic:** `read_file`, `list_directory`.
- **Blocked on a keypress:** `write_file`, `edit_file`, `execute_command`. The agent
  builds preview *content* (engine truth), the UI styles it (display truth):
  - `edit_file` — a real unified hunk, exact by construction (the anchor is the unique
    `search_block` match): `@@ -l,c +l,c @@`, `-` lines, `+` lines, 3 context lines.
    An ambiguous or missing block never reaches the user — it is a straight error
    result; there is nothing to confirm.
  - `write_file` — a `create`/`overwrite` label line plus the content as `+` lines
    (bounded to 50 lines; oversized files get a summary label).
  - `execute_command` — the command line and the resolved cwd.
- **Keys:** while a confirmation is pending, the phase is `:confirming`; **Enter or
  Ctrl+Enter approves** (mirroring the submit keys), **Esc rejects**, every other key
  is swallowed (typing mid-decision must not turn into an accidental approve; Ctrl+Q/
  Ctrl+C still quit). The preview renders as a tool-kind entry in the log; the 1-row
  activity line becomes the prompt (`Approve this change?` + dim `⏎ approve · esc
  reject`). Approval flips the phase back to `:executing_tool` before the runner
  starts — the activity line never keeps asking a question the user already answered.
- **No mutation without the keypress:** the runner Task for a mutating tool is started
  only after the agent receives `{:confirm_decision, ref, :approved}`. Rejection sends
  `{"ok":false,"rejected":true}` to the model — the model learns the human said no and
  can re-plan. A `ref` mismatch (stale decision from a superseded confirmation) is
  ignored.
- **Esc always interrupts**, consistently across phases: while `:streaming` it cancels
  the episode (ADR-0005 order preserved: partial content finalized, `[cancelled]`
  entry, idle); while `:confirming` it is the rejection above; while `:executing_tool`
  it **cancels the running tool by message** — the exec loop SIGKILLs the command's
  process group on `:cancel` (killing the runner Task instead would close the port
  and leak the OS process spinning; a mid-flight file tool simply completes — it was
  approved seconds earlier) — the completed or cancelled call records its real
  result, the remaining queue gets `cancelled` results, the transcript stays valid,
  and the loop ends without re-prompting the model.

### 5. UI contract

The ADR-0002/0006 vocabulary stands; the additions:

| Message (agent → UI) | Effect |
| --- | --- |
| `{:tool_call, %{id, name, args}}` | a dim tool row: accent `⚙` glyph, tool name, args summary (`read_file lib/foo.ex`), built by the UI from `args` |
| `{:tool_result, %{id, name, ok, status, output}}` | a dim outcome row under the call (`→ ok`, `→ rejected`, `→ error: …`), `output` an engine-bounded excerpt (≤ 30 lines) rendered verbatim, dim |
| `{:confirm, ref, %{id, name, args, lines}}` | appends the preview as a styled tool entry (`+`/`-` prefixed lines per the diff vocabulary), stores `confirm`, phase → `:confirming` |

UI → agent: `{:prompt, ui_pid, text}` on submit, `{:confirm_decision, ref, decision}`
on the keypress, `{:cancel}` on Esc — plain sends, no casts (fake agents in tests are
plain processes). The state gains `agent` (pid or name, mount opt, default
`DashFloat.Agent`), a monitor on it (`agent_down` degrades exactly like the old
`task_down`: system entry + idle, input keeps working), and `confirm`. The old
`task_pid`/`task_ref` pair goes — the agent owns the stream task now. Phase
`:confirming` joins the vocabulary: status bar `Confirm` (tool yellow), spinner keeps
stepping (it is an active phase — the tick discipline is untouched). Tool *output* is
plain dim text, not markdown — it is verbatim machine/file content, and markdown-styling
it would misrepresent it (headings inside a source file); assistant prose stays the only
markdown-rendered kind. No new Theme roles: the `⚙` glyph uses `:accent`, diff `+`
prefixes `:inline_code`, `-` prefixes `:dim` — the ADR-0006 warm-dim palette, no rainbow.

**ADR-0006 amendment (usage across episodes).** A turn is now multi-episode (stream →
tools → stream), and each episode's usage frame counts the whole conversation again —
banking every episode would inflate the context display. The agent forwards **only the
final episode's** usage frame to the UI; intermediate ones are dropped engine-side. The
in-contract ordering rule (usage before the phase change) is unchanged.

### 6. Conversation and lifecycle

The agent's message list starts `[user]` and grows: assistant (content and/or
`tool_calls`), tool results, next user turn. History is whole-conversation per request
(truncation is Phase 4's problem, per ADR-0001). Empty episodes (no content, no calls)
degrade to a `[model returned nothing]` system entry. A crashed ChatStream (abnormal
DOWN) mirrors ADR-0002's producer rules: finalize partial content, system entry, idle —
the agent itself never crashes the UI. The Application starts `DashFloat.TaskSupervisor`,
the named `DashFloat.Agent` (with the loaded provider), then the TUI (which receives the
agent name as a mount opt); in `Mix.env() == :test` only the task supervisor starts —
tests own their agents.

### 7. Testing

- `ToolCalls`: recorded delta fixtures fed whole, per-frame, and split at **every byte
  offset** (adversarial reassembly), malformed argument JSON, missing id, interleaved
  indices, shape misses.
- `PathPolicy` / tools: sandbox trees under `System.tmp_dir`; `..` escapes, absolute
  paths inside/outside, symlink escapes (file and intermediate directory), edit
  ambiguity (0 and N matches), exec timeout (short-timeout `sleep`), output truncation
  (a fast multi-MiB producer), non-zero exit codes.
- `Agent`: the end-to-end round trip against the loopback SSE server — episode 1 streams
  a recorded `tool_calls` response, the test process (as UI) receives the confirmation
  and approves, the executor writes into the sandbox, and the server's *second*
  connection is asserted to carry the `role: "tool"` message with the result JSON; a
  rejection test proves **no file mutation happens without the keypress**.
- TUI: contract messages drive the state directly (existing pattern); the idle-tick
  discipline test stays the animation proof — the agent adds no UI timers, so
  idle ⇒ no timers ⇒ no renders still holds.

## Interface freeze

- `Tools.schema/0`; `Tools.validate(name, args_map) :: {:ok, args} | {:error, msg}`
  (string keys throughout tools land); `Runner.run(name, args, cwd, opts) :: result_map`
  (atom-keyed, Jason-ready); `PathPolicy.resolve(root, path) :: {:ok, abs} | {:error, msg}`;
  `Edit.locate(content, search_block) :: {:ok, %{count: 1, start: pos}} | {:error, {:no_match | :ambiguous | :empty | :identical, detail}}`;
  `Exec.run(command, cwd, timeout, cap) :: result_map`; `Preview.build(name, args, cwd) :: {:ok, %{lines: [String.t()]}} | {:error, result_map}`;
  `ToolCalls.new/feed/finish`.
- `Agent` opts: `provider`, `cwd`, `exec_timeout` (default 30 000). Casts/sends in
  §5. `ChatStream.run(agent, provider, messages, tools, opts)`; reports per §2.
- `State` fields `agent`, `agent_ref`, `confirm`; `stream_message` clauses for the three
  new messages; actions `{:confirm, :approved | :rejected}`; `agent_down/3`;
  phase `:confirming` in `View`/`State`.

## Alternatives considered

- **ChatStream as the agent loop** — the streamer would grow conversation state,
  confirmation waits, and dispatch; the ADR-0001 manager exists precisely to own that,
  and a Task is the wrong shape for a process that must outlive a stream and receive
  keypress decisions. Rejected.
- **Agent forwards nothing; ChatStream talks to the UI directly (two voices)** — one
  fewer hop, but two senders into the UI mailbox make log ordering an argument instead
  of a fact, and ChatStream stays coupled to TUI vocabulary. Single voice chosen.
- **Modal confirmation UI** — ADR-0006 deferred modals; log-entry preview + activity-row
  prompt delivers the semantics with zero new layout machinery.
- **Concurrent tool execution** — parallel calls executed in parallel complicate
  confirmation order and result ordering for no user-visible gain at five tools;
  sequential-in-call-order is deterministic and testable. A Phase-4+ concern if ever.
- **Line-number edits / fuzzy matching** — the founding spec fixed the search-block
  protocol; fuzzy would break the "approved diff == landed diff" guarantee (the
  preview may be window-capped at 50 lines with a disclosed marker — what it
  SHOWS is exactly what lands).
- **Esc no-op during tool execution** — would leave the `esc interrupt` hint lying and a
  30 s timeout unskippable; cancellation is message-based and reaps the process group.
  Interrupt implemented.
- **System-level sandboxing (containers, landlock)** — out of scale for a single-user
  local harness whose mutations are human-confirmed; the path policy plus confirmations
  is the designed boundary. Recorded as a future hardening option, not this slice.

## Consequences

- The UI seam grows by three messages and a phase; everything else renders through the
  existing entry/Theme machinery — ADR-0006's "Phase 3 extends the vocabulary by adding
  roles, not code" holds (no new roles were even needed).
- The conversation is unbounded in memory until Phase 4; usage display is honest (final
  episode only) but context management is still the model's provider window to waste.
- Tool execution makes DashFloat able to mutate the user's tree by design; the safety
  story is path scoping + exact-match edits + human-confirmed mutations + bounded
  everything, documented here as the review lens for later phases.
- `StreamSupervisor` is renamed; any external reference breaks loudly at compile time
  (none exists outside `lib/` and `test/`).

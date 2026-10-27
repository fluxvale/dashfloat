# Issue #27 implementation plan — worker slices

Design record: [ADR 0014](../decisions/0014-session-persistence.md). Read it
first — it is the contract every slice below builds against, and this file
does not repeat its rationale. Issue:
[#27 (Phase 4: session persistence)](https://github.com/fluxvale/dashfloat/issues/27).

Work order: **Slice 1 → (Slice 2 ∥ Slice 3) → Slice 4.** Slices 2 and 3 are
independent of each other once Slice 1's `DashFloat.Session` + `DashFloat.Tools`
helpers exist; Slice 4 wires everything and lands last. Each slice is a
separate PR-sized change; every one runs `mix ci` green before review.

File ownership (keep slices disjoint):

| Slice | New files | Edited files |
| --- | --- | --- |
| 1 | `lib/dash_float/session.ex`, `test/dash_float/session_test.exs` | `lib/dash_float/tools.ex`, `test/dash_float/tools_test.exs` |
| 2 | — | `lib/dash_float/agent.ex`, `test/dash_float/agent_test.exs` |
| 3 | — | `lib/dash_float/tui/state.ex`, `test/dash_float/tui/state_test.exs` |
| 4 | — | `lib/dash_float/cli.ex`, `lib/dash_float/application.ex`, `test/dash_float/application_test.exs`, `test/dash_float/cli_test.exs`, `README.md` |

Shared vocabulary (pinned here; ADR 0014 §3 is normative):

- A **message** is provider-shaped — in memory the agent builds atom-keyed
  maps (`%{role: "user", content: text}`); after a JSON round-trip the same
  message has string keys (`%{"role" => "user", ...}`). Jason encodes both
  identically, so they mix freely. **Never atomize loaded messages**
  (dynamic atoms are a leak; tool ids are provider strings).
- The canonical assistant tool-call and tool-result shapes, exactly as
  `DashFloat.Agent` builds them today (`begin_tool_batch/3`,
  `flush_tool_messages/1`):

  ```elixir
  %{role: "assistant", content: nil | binary,
    tool_calls: [%{id: id, type: "function",
                   function: %{name: name, arguments: args_json_string}}]}

  %{role: "tool", tool_call_id: id, content: result_json_string}
  ```

- The cancelled result shape (one source of truth from Slice 1 on):
  `DashFloat.Tools.cancelled_result()` → `%{ok: false, cancelled: true}`.

---

## Slice 1 — `DashFloat.Session`: the store

**Builds** `lib/dash_float/session.ex` per ADR 0014 §2–§4 and the three
small `DashFloat.Tools` helpers. Knows nothing about the agent, the TUI, or
the Application.

### `DashFloat.Tools` helpers (additive only; do not touch `agent.ex`)

`agent.ex` currently holds these as privates — extract them to
`DashFloat.Tools` unchanged in behavior, so the store (this slice) and the
replayer (Slice 3) share one derivation with the agent's display messages.
`agent.ex` keeps calling its own privates until Slice 2 swaps it.

- `cancelled_result() :: %{ok: false, cancelled: true}` (the literal the
  agent's `abort_tool_run/2` / `fill_cancelled/1` write today).
- `display_status(result) :: String.t()` — `agent.ex`'s `result_status/1`
  verbatim (`"rejected"` / `"cancelled"` / `"ok"` /
  `"error: " <> first 160 chars` / `"error"`).
- `display_excerpt(result) :: String.t() | nil` — `agent.ex`'s
  `display_excerpt/1` verbatim, including the 30-line cap constant
  (`@display_lines 30` moves here).

### `DashFloat.Session`

```elixir
@type pin :: %{profile: String.t() | nil, model: String.t() | nil,
               base_url: String.t() | nil}
@type t :: %{version: 1, id: String.t(), created_at: String.t(),
             pin: pin(), messages: [map()]}

@spec dir() :: String.t()                      # XDG data: .../dashfloat/sessions
@spec new_id() :: String.t()                   # "YYYYMMDD-HHMMSS-xxxxxx" UTC + 6 hex
@spec save(Path.t(), t()) :: :ok | {:error, String.t()}
@spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
```

- `dir/0`: `:filename.basedir(:user_data, "dashfloat") |> Path.join("sessions")`.
- `new_id/0`: `Calendar`/`:calendar` UTC `YYYYMMDD-HHMMSS` + `-` +
  `:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)`.
- `save/2`: `File.mkdir_p` the directory on demand, encode the session as
  compact JSON + `\n` via `Jason.encode!`, write through
  `DashFloat.Config.Posture.write_private/2` (this is where 0600 + atomic
  tmp/rename + the `.tmp` symlink refusal come from — do not reimplement
  them). Errors name paths only.
- `load/2` (never writes):
  - Read `<dir>/<id>.json`. Missing file **or missing directory** →
    `{:error, "no session <id> under <dir> — list sessions with: ls <dir>"}`.
  - Unreadable / undecodable JSON → error naming the path and reason
    (never echo file contents).
  - Validate the top level: map, `version == 1` (an integer `> 1` → error
    naming the field and both values — "written by a newer DashFloat";
    absent / non-integer → malformed error), string `id` equal to the
    requested id (else malformed), `messages` a list. Unknown top-level
    keys: ignore silently.
  - Validate each message's role shape (ADR 0014 §4): `user` → binary
    `content`; `assistant` → binary-or-nil `content`, optional list
    `tool_calls` whose entries have binary `id`, `type`, `function.name`,
    `function.arguments`; `tool` → binary `tool_call_id`, binary
    `content`. Violation → error naming the message index and field
    (string keys post-decode — validate the `"role"` value, not atoms).
    `function.arguments` is opaque from here on.
  - **Orphan rule:** a tool message whose `tool_call_id` matches no
    announced call in the nearest preceding assistant `tool_calls` batch →
    malformed error naming the index.
  - **Dangling repair (in memory):** for each assistant `tool_calls` batch,
    every announced id lacking a matching tool message before the next
    user/assistant message gains a synthesized
    `%{"role" => "tool", "tool_call_id" => id, "content" => Jason.encode!(Tools.cancelled_result())}`
    appended at the end of that batch's tool block. Works wherever the
    batch sits (only the last batch is producible by a crash, but do not
    special-case it).
  - Return the string-keyed messages as decoded (plus repairs) — do not
    atomize, do not rewrite the file.

### Tests (`test/dash_float/session_test.exs`, plus the Tools helpers in `tools_test.exs`)

tmp-dir discipline (`ctx.tmp_dir`) — the real XDG dir is off-limits. Cover
at least: save→load round-trip equality (including nil content, a tool_calls
batch, multi-line/UTF-8 content); id sortability/uniqueness (two `new_id/0`
in the same second differ); dir created on demand by `save`; `stat -c '%a'`
is `600` for a fresh file and after rewriting an existing one; a pre-planted
`<id>.json.tmp` symlink is refused by `save` and the target is untouched; a
stale regular `.tmp` left behind leaves the previous file loadable; unknown
id and missing dir errors name the dir; truncated and garbage files error
naming the path, never raise, and are byte-identical afterwards; `version: 2`
refuses naming the field; `id` mismatch refuses; each per-message shape
violation (bad role, non-binary content, tool_calls entry missing
`function.name`, tool message missing `tool_call_id`) refuses naming the
index; orphan tool message refuses; dangling batch (one call, two calls, one
of two results present, dangling-mid-file) loads with exactly one cancelled
result per missing id in call order; no `api_key` key appears in any written
file.

**Done when:** `mix test test/dash_float/session_test.exs
test/dash_float/tools_test.exs` passes with the tests above;
`stat -c '%a' <tmp>/<id>.json` prints `600`;
`grep -R "api_key" <tmp sessions dir> 2>/dev/null` prints nothing (exit 1);
`mix ci` green.

---

## Slice 2 — Agent persistence wiring

**Edits** `lib/dash_float/agent.ex` (+ its test). Depends on Slice 1.

### Changes

- New opts in `start_link/1` → `init`: `:session_dir` (default **nil**) and
  `:resume` (`%{id: _, pin: _, messages: _}`, default nil). State gains
  `:session_dir`, `:session_id`, `:session_pin`; `init` seeds them from
  `resume` (id/pin/messages all three) or leaves them nil. **The nil
  default is deliberate:** persistence is opt-in so tests and embedded
  starters never write to the user's real XDG dir — do not "fix" it.
- Swap the private `result_status/1`, `display_excerpt/1`, and the
  `%{ok: false, cancelled: true}` literals to the Slice-1
  `DashFloat.Tools` helpers; delete the privates.
- **Persist at the five message-list mutation sites** — inside the mutating
  helper, right after the messages update, via one private `persist/1`:

  1. the `{:prompt, _ui, _text}` `{:ok, _config}` arm, after appending the
     user message (before `start_episode`);
  2. `begin_tool_batch/3` (the deliberately-dangling write);
  3. `flush_tool_messages/1`, after appending tool messages (before the
     next `start_episode`);
  4. `finalize_episode/2`, after appending assistant content;
  5. `fill_cancelled/1`, after appending the cancelled results.

- `persist/1` is a no-op when `session_dir` is nil. Otherwise: if
  `session_id` is nil, mint it (`Session.new_id/0`), set `created_at`
  (ISO8601 UTC), and capture `session_pin` from the **current provider** —
  `{:ok, %Config{}}` → `%{profile: c.profile, model: c.model, base_url:
  c.base_url}` picked field-by-field (never the struct, never the key —
  the writer must not even see `api_key`); an error provider never reaches
  a persist (the prompt arm guards it). Then
  `Session.save(session_dir, %{version: 1, id: id, created_at: created_at,
  pin: pin, messages: state.messages})`.
- **Save failure degrades:** on `{:error, msg}`, `Logger.warning(msg)` and
  `display(ui, {:entry, :system, "[session not saved: " <> path-name-only
  summary <> "]"})` — the turn continues; persist failures must never
  crash or block the episode loop.
- A resumed agent (`resume:`) treats the loaded messages as its history:
  the first prompt's episode starts from them (no other change —
  `start_episode` already sends `state.messages`).

### Tests (extend `test/dash_float/agent_test.exs`)

Follow the existing loopback-SSE patterns (scripted episodes, the test
process as UI, sandbox cwd). Cover at least: no file appears before the
first prompt (agent started, quit); after a completed tool turn
(read_file), the file's messages equal the expected five-message shape
(user, assistant+tool_calls, tool, assistant final) with full untruncated
result content; a mutating-tool turn paused at the confirmation persists
the dangling shape (assistant+tool_calls, no tool message) — assert the
file bytes; approving then completing appends the real result and the next
save carries it; cancel mid-batch persists the cancelled results
(`fill_cancelled`); a save failure (point `session_dir` at a path where a
file blocks `mkdir_p`, e.g. a regular file at the dir path) degrades to a
system entry and the turn still completes; `session_dir: nil` (default)
writes nothing anywhere; sentinel api_key never reaches the file; and the
**kill round-trip**: script episode 1 to announce a `write_file` call,
receive the `{:confirm, ref, _}` display message, then
`Process.exit(agent, :kill)` (uncatchable), load the file with
`Session.load`, assert the dangling shape, start a fresh agent with
`resume:` + a scripted final episode, send a prompt, and assert the
server's forwarded request body carries the original `tool_calls` ids,
matching `tool_call_id`s (the synthesized cancelled results), and the
user/assistant messages in order.

**Done when:** `mix test test/dash_float/agent_test.exs` passes with the
kill round-trip and the persist-point tests above; `session_dir: nil`
proves no writes (no files under a tmp dir after a full turn); `mix ci`
green.

---

## Slice 3 — Transcript replay in the TUI

**Edits** `lib/dash_float/tui/state.ex` (+ its test). Independent of Slice 2;
needs Slice 1's `Tools.display_status/1` / `display_excerpt/1`.

### Changes

`State.new/1` gains two opts:

- `:transcript` — a message list in the **decoded (string-keyed) form**
  `Session.load` returns, default `[]`;
- `:resume_note` — `String.t() | nil`, default nil.

When a transcript is present, build `entries` by replaying it through the
exact render path live entries use (per message type — the tool builders do
not round-trip through `entry_lines/2`):

- `%{"role" => "user", "content" => text}` → append a `:user` entry
  (`append_entry(state, :user, text)` — the existing private; same as
  submit's echo).
- `%{"role" => "assistant"}` with non-nil, non-empty `content` → append an
  `:assistant` entry (markdown path via `append_entry`).
- `%{"role" => "assistant"}` with `tool_calls` (after the content entry,
  when both exist) → per call: `name = call["function"]["name"]`,
  `args = Jason.decode(call["function"]["arguments"])` (on error, pass
  `nil` — `Render.tool_call/2`'s "(invalid arguments)" arm), then
  `{text, lines} = Render.tool_call(name, args)` and `put_entry` — the
  same call the `{:tool_call, _}` contract message makes.
- `%{"role" => "tool"}` → find the call name by `tool_call_id` in the
  nearest preceding `tool_calls` batch (walk with an id→name map; the
  loader guarantees no orphans), decode `content` (a decode failure
  renders `"error"` status with no output — never a crash), derive
  `status = Tools.display_status(result)` and
  `output = Tools.display_excerpt(result)`, then
  `{text, lines} = Render.tool_result(name, status, output)` and
  `put_entry` — the same call the `{:tool_result, _}` contract message
  makes.

Everything lands through the existing `put_entry` (so `logical` is freshly
built and `lines` wraps at the current width — loaded entries are never
read from disk). After replay, append `resume_note` as a `:system` entry
when non-nil. `follow?` stays `true` / scroll `0` (defaults) so the
resumed log opens pinned at the bottom. Stats stay zeroed (usage is not
persisted — the context total honestly shows `—` until the next usage
frame). Keep it pure: no processes, no I/O — `new/1` stays side-effect
free (replay calls only Render/Markdown/Wrap, as live appends already do).

### Tests (extend `test/dash_float/tui/state_test.exs`)

Cover at least: a transcript of (user, assistant prose, assistant
tool_calls ×2, tool ×2, assistant final) yields one entry per message plus
the two tool rows — entries' `text`/`logical` equal what the live contract
messages (`append_entry` + `stream_message({:tool_call, _})` /
`({:tool_result, _})`) produce for the same data (differential assertion:
build a live state through the contract messages, assert the replayed
entries match kind-for-kind, text-for-text); `lines` are wrapped at the
current width (change the size opt, assert re-wrap works as for live
entries); markdown renders in assistant rows; `arguments` JSON that does
not decode renders the "(invalid arguments)" arm; a tool content that does
not decode renders an error row; `follow?` is true and
`effective_scroll/2` pins to the bottom; `resume_note` lands as the last
`:system` entry; empty transcript (default) behaves exactly as today;
nil-content assistant-with-calls produces no empty assistant entry.

**Done when:** `mix test test/dash_float/tui/state_test.exs` passes with
the differential replay tests above (the loaded state's entries are built
by the render pipeline, not read from disk); `mix ci` green.

---

## Slice 4 — CLI flag, boot wiring, end-to-end

**Edits** `lib/dash_float/cli.ex`, `lib/dash_float/application.ex`, their
tests, `README.md`. Depends on Slices 1–3.

### CLI (`cli.ex`)

Add `--resume` to the flag set: `--resume <id>` and `--resume=<id>` →
`[resume: id]`, exactly `--profile`'s parse discipline (valueless switch →
warn + ignore; repeats → first wins; the value is an id string, not a
secret — but keep the flag-name-only warning hygiene). Update the moduledoc.

### Application (`application.ex`)

- New args seam: `:sessions_dir` (default `DashFloat.Session.dir()`), for
  tests — mirroring `:config_dir`.
- After `classification`, when `cli[:resume]` is set **and not test?**:
  - `Session.load(sessions_dir, id)` → `{:error, msg}` →
    `IO.binwrite(:stderr, msg <> "\n")` and return
    `{:error, :session_resume_failed}` (no children start; the refused
    file is untouched — load never writes). Same shape as the
    interactive-setup refusal two branches up.
  - `{:ok, session}` → **pin compare** when classification is
    `{:ok, config}`: for each of `profile`/`model` where both
    `session.pin` and the config field are non-nil and differ, collect the
    mismatch. Any mismatch → `note = "[resuming session pinned to
    <profile>/<model> under active <profile>/<model> — continuing; the
    session keeps its pin]"` (name both sides of every mismatched field;
    fields that matched or are nil-pinned are omitted), announced as
    `Logger.warning(note)` and passed to the TUI (below). No mismatch →
    note nil. Never refuses, never rewrites the pin.
  - Hand-off: `engine_children` passes the agent
    `session_dir: sessions_dir` (always, outside test) and
    `resume: %{id: session.id, pin: session.pin, messages:
    session.messages}`; `tui_child` passes the TUI
    `transcript: session.messages` and `resume_note: note`. With a setup
    classification (`{:select, _}` / `:onboard`), resume still hands off
    (the pin compare is skipped — nothing to compare) and the wizard/modal
    flow proceeds as today once setup clears.

### README

New short paragraph in the usage section: sessions persist under
`~/.local/share/dashfloat/sessions/` (XDG_DATA_HOME respected), one JSON
file per session, 0600 (they contain code and tool output from your disk);
list ids with `ls`, resume with `--resume <id>`; a session records the
profile and model it started under — resuming under a different one warns
and continues; malformed or newer-version session files refuse loudly and
are never auto-deleted. Link ADR 0014.

### Tests

- `cli_test.exs`: both flag forms parse; valueless warns + ignores; repeat
  keeps first; `--version` path unaffected.
- `application_test.exs` (args-seam pattern, tmp sessions dir): unknown id
  → stderr names the dir, start returns `{:error, :session_resume_failed}`,
  no children; garbage / truncated / unreadable file and missing dir under
  `--resume` → same refusal, file byte-identical after the attempt;
  `version: 2` file → refusal names the field; successful resume → the
  agent child spec carries `session_dir` + `resume` with the loaded
  messages and the TUI child spec carries `transcript` + `resume_note`
  (assert via the started children / a test-mode instantiation of the
  mount opts, following the existing boot-test patterns); pin mismatch →
  note names both profiles/models; matching pin → note nil; a hand-written
  dangling session resumes with synthesized cancelled results (boot-level:
  the handed-off messages contain them).
- End-to-end (in `application_test.exs` or a sibling): the Slice-2 kill
  round-trip asserted through the boot seam — `--resume` of the killed
  session's id hands the repaired messages to a fresh agent, whose first
  request (loopback server) carries the ids and full results, and whose
  next save rewrites the same file under the same id.

**Done when:** `mix test test/dash_float/application_test.exs
test/dash_float/cli_test.exs` passes with the cases above;
`dashfloat --resume does-not-exist` on a real (non-test) run prints the
sessions directory to stderr and exits non-zero without starting a session;
`grep -R "<sentinel>" <sessions dir>` after a sentinel-keyed turn is empty;
`mix ci` green.

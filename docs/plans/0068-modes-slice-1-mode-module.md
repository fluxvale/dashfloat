# Slice 1 — `DashFloat.Mode` and tool risk classes (pure, no wiring)

Issue [#68](https://github.com/fluxvale/dashfloat/issues/68). Design:
[ADR 0016](../decisions/0016-interaction-modes.md) — read it first; this slice
implements §2 (taxonomy) and §3 (matrix) plus the naming surface of §7.

Read this whole document before writing code. You need zero context beyond it,
ADR 0016, and the two files you touch.

## Goal

Two pure additions, no behavior change anywhere yet:

1. `lib/dash_float/mode.ex` — a new module `DashFloat.Mode`.
2. `lib/dash_float/tools.ex` — add `class/1` to the existing `DashFloat.Tools`
   (touch nothing else in it).

Slices 3 and 4 wire these into the agent and the TUI; nothing calls them yet,
which is expected.

## Spec

### `DashFloat.Mode`

```elixir
defmodule DashFloat.Mode do
  # @modes is the cycle order (ADR 0016 §1): plan → build → auto → unchained
  @modes [:plan, :build, :auto, :unchained]

  def modes, do: @modes
  def cycle(mode)          # next mode in cycle order, wraps around
  def valid?(term)         # true iff term is one of the four atoms
  def from_string(s)       # "plan"|"build"|"auto"|"unchained" (exact, case-sensitive) -> {:ok, atom} | :error
  def label(mode)          # "Plan" | "Build" | "Auto" | "Unchained"
  def gate(mode, class)    # the 12-cell matrix below
end
```

`gate/2` returns `:run | :confirm | :propose | :vet` (ADR 0016 §3):

| class \ mode | plan | build | auto | unchained |
| --- | --- | --- | --- | --- |
| `:safe` | run | run | run | run |
| `:mutating` | propose | confirm | **vet** | run |
| `:risky` | propose | confirm | **vet** | run |

`:vet` is the dynamic outcome — ADR 0016 §6 resolves it to run (allow) or
confirm (ask or any check failure). The module just returns the symbol; no
processes, no I/O, no exceptions on valid input. Match the codebase style:
`@spec` on every public function, `@moduledoc` citing ADR 0016, plain module.

### `DashFloat.Tools.class/1`

Add to the existing `DashFloat.Tools` module (do not reorder or restructure the
existing `@params`/`@descriptions` tables — add alongside):

```elixir
@doc "Risk class per ADR 0016 §2. Unknown names are :risky (fail closed)."
@spec class(String.t()) :: :safe | :mutating | :risky
def class(name) # read_file, list_directory -> :safe
               # write_file, edit_file -> :mutating
               # execute_command -> :risky
               # anything else -> :risky
```

Implement it from the same source of truth as the catalogue: the tool names
already live in `@order`/`@params` — a class map keyed by name next to them is
the natural shape. Unknown → `:risky` regardless.

## Tests

New file `test/dash_float/mode_test.exs`; add class tests to the existing
`test/dash_float/tools_test.exs` (follow its current style). Cover:

- `gate/2`: all 12 cells, as an exhaustive table test
  (`for mode <- Mode.modes(), class <- [:safe, :mutating, :risky]`) — including
  `gate(:auto, :mutating) == :vet` and `gate(:auto, :risky) == :vet`.
- `cycle/1`: all four, including the wrap `:unchained -> :plan`.
- `valid?/1`: each mode true; `:buidl`, `"build"`, nil false.
- `from_string/1`: each of the four names; `"Build"`, `"b"`, `""`, `"nonsense"`
  → `:error`.
- `label/1`: all four.
- `Tools.class/1`: all five catalogue names plus one unknown name (e.g.
  `"rm_rf"` → `:risky`).

## Done when

```
mix deps.get && mix test test/dash_float/mode_test.exs test/dash_float/tools_test.exs
```

exits 0 with all tests passing (the new ones visible in the output), and

```
mix ci
```

exits 0. Paste both transcripts in your report. No other file is modified
(`git diff --stat main -- lib test` shows exactly two lib files, two test
files).

defmodule DashFloat.RigNeedleTest do
  @moduledoc false
  # The capture rig's reply-end needles are exchange-unique (#125, ADR
  # 0029): the mock numbers every stock reply and each reply-end wait
  # rides its own exchange's closing sentinel — a needle the stock body
  # can satisfy ("rest") matches the FIRST reply's stale output and lets
  # a still shoot mid-race. The rig is python (CI has no pyte), so these
  # are source invariants over scripts/capture.py; the behavioral proof
  # is the 0/20 loop in the lane's PR.

  use ExUnit.Case, async: true

  # Read at RUNTIME, not via a module attribute: an attribute bakes the
  # file into the compiled module, and a cached build can mask the very
  # regression under test (verified live during this lane).
  defp source do
    "../../scripts/capture.py"
    |> Path.expand(__DIR__)
    |> File.read!()
  end

  # Every literal wait needle in the rig, frozen (hostile-review finding:
  # refuting one spelling is trivially evadable). A new literal needle is
  # a visible diff to this list — prove it unique to its act (or fixture,
  # or footer span) before adding it. Mid-stream markers ("processes",
  # "independently", "thinking") fire DURING a stream by design; they are
  # never reply-end gates. Fragments are first-line segments of the
  # multi-line literals in the source; f-string entries are the literal
  # templates with their interpolation braces.
  @needle_allowlist MapSet.new([
                      "Models",
                      "Profiles",
                      "Sessions",
                      "Session title",
                      "first run",
                      "base URL",
                      "Streaming",
                      "↑↓ scroll",
                      "attach",
                      "[images:",
                      "hi there",
                      "independently",
                      "processes",
                      "thinking",
                      "supervised by",
                      "think about elixir",
                      "❯ what is elixir?",
                      "❯ fixture question two",
                      "Fixture answer two, also replayed.",
                      "dropped 1 oldest turn(s)",
                      "at or under the 80% trigger",
                      "of 1048576",
                      "window assumed",
                      "DASHFLOAT_CONTEXT_TOKENS",
                      "write_file → ok",
                      "File written.",
                      "Approve write_file?",
                      "Which database should the config target?",
                      "SQLite it is",
                      "question → answered: SQLite",
                      "Which runtimes need setup docs?",
                      "answered: Elixir, Python",
                      "Docs for Elixir and Python",
                      "[mode: Build → Auto]",
                      "auto-rejected: deletes files outside the project",
                      "[auto: rejected execute_command — deletes files ",
                      "Understood — that command",
                      "[session titled: {TITLE_TEXT}]",
                      "[session titled: {TITLE_FREE_TITLE}]",
                      "[session titled: {TITLE_INLINE_TITLE}]"
                    ])

  # One definition, an f-string over the exchange number: distinct
  # exchanges cannot render the same closing.
  @stock_closing_def "return f\"turn-{n}.\""
  @sentinel_wait "wait_for(stock_closing("
  @flat_wait "if needle in self.flat_text():"

  test "every literal wait needle is frozen-known — none ad-hoc, none from the stock body's tail" do
    calls = Regex.scan(~r/wait_(?:for|gone)\(\s*f?["']([^"']*)["']/, source())
    assert calls != [], "the needle scan found no wait calls — regex rot"

    for [_match, literal] <- calls do
      assert MapSet.member?(@needle_allowlist, literal),
             "unfrozen literal needle #{inspect(literal)} — add it to " <>
               "@needle_allowlist after proving it unique to its act, or " <>
               "wait on stock_closing(n) (ADR 0029)"
    end

    # the #125 class, directly: the stock reply's tail may never be a
    # needle, and no wait may draw from the reply token list at all
    for [_match, literal] <- calls do
      refute literal in ["rest", "rest.", "the rest", "the rest."],
             "the stock body's tail is a wait needle again (the #125 class)"
    end

    assert source() =~ "REPLY_TOKENS" and
             not Regex.match?(~r/wait_(?:for|gone)\([^)]*REPLY_TOKENS/, source()),
           "a wait draws its needle from REPLY_TOKENS — the stock body " <>
             "is byte-identical every exchange (ADR 0029)"
  end

  test "the stock reply's closing is exchange-unique, stamped by the mock, ridden by every reply-end wait" do
    assert source() =~ "def stock_closing(n: int)"
    assert source() =~ @stock_closing_def

    # the mock drips the n-th closing as the n-th stock reply's last words
    assert source() =~ "REPLY_TOKENS[:-1] + stock_closing_tokens(n)"

    # every reply-end site (nine scenarios today) rides the sentinel —
    # new ones grow the count, never shrink it
    sentinel_sites = count_occurrences(source(), @sentinel_wait)

    assert sentinel_sites >= 9,
           "only #{sentinel_sites} sentinel wait sites — a reply-end wait " <>
             "regressed to a literal (ADR 0029)"
  end

  test "both waits match wrap-collapsed text (a needle may wrap at any pty width)" do
    assert source() =~ "def flat_text(self)"
    # wait_for AND wait_gone both match through flat_text — either alone
    # leaves the other's needles wrap-fragile
    assert count_occurrences(source(), @flat_wait) >= 2
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end

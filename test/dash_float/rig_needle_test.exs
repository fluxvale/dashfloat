defmodule DashFloat.RigNeedleTest do
  @moduledoc false
  # The capture rig's reply-end needles are exchange-unique (#125, ADR
  # 0029): the mock numbers every stock reply and each reply-end wait
  # rides its own exchange's closing sentinel — a needle the stock body
  # can satisfy ("rest") matches the FIRST reply's stale output and lets
  # a still shoot mid-race. The rig is python (CI has no pyte), so these
  # are source invariants; the behavioral proof is the 0/20 loop in the
  # lane's PR.

  use ExUnit.Case, async: true

  @source File.read!(Path.expand("../../scripts/capture.py", __DIR__))

  test "no reply-end wait rides the stock body's text (the #125 class)" do
    refute @source =~ ~s{wait_for("rest")},
           "a bare wait_for(\"rest\") is back — the stock reply's body is " <>
             "byte-identical every exchange, so this needle is satisfied " <>
             "by any earlier exchange's stale output (ADR 0029)"
  end

  test "the stock reply's closing is exchange-unique, stamped by the mock, waited on by scenarios" do
    # one definition, an f-string over the exchange number: distinct
    # exchanges cannot render the same closing
    assert @source =~ "def stock_closing(n: int)"
    assert @source =~ "return f\"turn-{n}.\""

    # the mock drips the n-th closing as the n-th stock reply's last words
    assert @source =~ "REPLY_TOKENS[:-1] + stock_closing_tokens(n)"

    # reply-end waits go through it
    assert @source =~ "wait_for(stock_closing("
  end

  test "waits match wrap-collapsed text (a needle may wrap at any pty width)" do
    assert @source =~ "def flat_text(self)"
    assert @source =~ ~s{if needle in self.flat_text():}
  end
end

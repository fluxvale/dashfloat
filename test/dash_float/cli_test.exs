defmodule DashFloat.CLITest do
  @moduledoc false
  # Sync: this module asserts TOTAL log silence (a --version parse must warn
  # about nothing). ExUnit's capture is unscoped — its handler writes every
  # event to every active capture — so an async run here can read a
  # concurrent test's CLI warnings (issue #55). Sync modules start only
  # after every async module has finished, which makes the silence real
  # without weakening the assertion to a partial match.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DashFloat.CLI

  test "space and equals forms parse for both flags" do
    assert CLI.parse(["--profile", "work"]) == [profile: "work"]
    assert CLI.parse(["--profile=work"]) == [profile: "work"]
    assert CLI.parse(["--model", "Sol"]) == [model: "Sol"]
    assert CLI.parse(["--model=Sol"]) == [model: "Sol"]
  end

  test "both flags together keep their order" do
    assert CLI.parse(["--profile", "personal", "--model", "Sol"]) == [
             profile: "personal",
             model: "Sol"
           ]

    # Keyword order follows argv order; lookups are order-agnostic.
    assert CLI.parse(["--model=Sol", "--profile=personal"]) == [model: "Sol", profile: "personal"]
  end

  test "empty argv is empty opts" do
    assert CLI.parse([]) == []
  end

  test "version?/1 detects the version flag anywhere in argv" do
    refute CLI.version?([])
    refute CLI.version?(["--profile", "work"])
    assert CLI.version?(["--version"])
    assert CLI.version?(["--profile", "work", "--version"])
  end

  test "a version query is never parsed as a selection and never warns" do
    logs = capture_log(fn -> assert CLI.parse(["--version"]) == [] end)
    assert logs == ""
  end

  test "a switch without a value warns and is ignored" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--profile"]) == []
      end)

    assert logs =~ "--profile given without a value"

    model_logs =
      capture_log(fn ->
        assert CLI.parse(["--model"]) == []
      end)

    assert model_logs =~ "--model given without a value"
  end

  test "unrecognized arguments warn by flag name only — values are never logged" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--api-key=PLACEHOLDER-SECRET", "--token=PLACEHOLDER-TOKEN", "plain"]) ==
                 []
      end)

    assert logs =~ ~s(unrecognized argument "--api-key")
    assert logs =~ ~s(unrecognized argument "--token")
    assert logs =~ ~s(unrecognized argument "plain")
    refute logs =~ "PLACEHOLDER"
  end

  test "a repeated switch keeps the first value and warns" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--profile", "work", "--profile", "personal"]) == [profile: "work"]
      end)

    assert logs =~ "given more than once"
  end

  test "an equals-looking value for one flag does not confuse the other" do
    assert CLI.parse(["--profile", "--model=Sol"]) == [profile: "--model=Sol"]
  end

  # ADR 0014 §6: --resume rides the same parse discipline as the selection
  # flags; the boot consumes the id after config classification.
  test "--resume parses in space and equals forms" do
    assert CLI.parse(["--resume", "20261027-143052-a1b2c3"]) == [
             resume: "20261027-143052-a1b2c3"
           ]

    assert CLI.parse(["--resume=20261027-143052-a1b2c3"]) == [
             resume: "20261027-143052-a1b2c3"
           ]
  end

  test "--resume sits alongside the selection flags in argv order" do
    assert CLI.parse(["--profile", "work", "--resume=abc123", "--model", "Sol"]) == [
             profile: "work",
             resume: "abc123",
             model: "Sol"
           ]
  end

  test "--resume without a value warns and is ignored" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--resume"]) == []
      end)

    assert logs =~ "--resume given without a value"
  end

  test "a repeated --resume keeps the first value and warns" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--resume", "first-id", "--resume", "second-id"]) == [
                 resume: "first-id"
               ]
      end)

    assert logs =~ "given more than once"
  end

  test "a version flag around --resume is skipped by the parser, not taken as its value" do
    logs =
      capture_log(fn ->
        assert CLI.parse(["--resume", "abc123", "--version"]) == [resume: "abc123"]
      end)

    assert logs == ""
  end
end

defmodule DashFloat.CLITest do
  @moduledoc false
  use ExUnit.Case, async: true

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
end

defmodule DashFloatTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "ADR 0002 exists and is accepted" do
    path = Path.expand("../docs/decisions/0002-tui-skeleton.md", __DIR__)
    assert File.exists?(path)
    assert File.read!(path) =~ "- **Status:** Accepted"
  end
end

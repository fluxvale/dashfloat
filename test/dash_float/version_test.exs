defmodule DashFloatTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "version/0 reports the mix.exs version" do
    assert DashFloat.version() == Mix.Project.config()[:version]
    assert DashFloat.version() =~ ~r/^\d+\.\d+\.\d+$/
  end
end

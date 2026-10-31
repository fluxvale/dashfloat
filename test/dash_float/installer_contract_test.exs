defmodule DashFloat.InstallerContractTest do
  @moduledoc false
  # The glibc-floor refusal contract pinned at mix ci time (ADR 0032): the
  # installer's die message and the smokes' shared assertion carry the same
  # fragment, the floor preflight precedes the library preflight, and both
  # negative smokes assert through the contract script — so the wording and
  # the test cannot drift apart between releases, and the false green of
  # issue #52 (a below-floor install accepted on any failure) cannot return
  # unnoticed.
  use ExUnit.Case, async: true

  @floor_fragment "is below the GLIBC_2.34 floor"

  test "install.sh refuses below-floor glibc with the contract message" do
    assert File.read!("install.sh") =~ ~s(die "glibc $ver is below the GLIBC_2.34 floor)
  end

  test "the floor preflight runs before the by-name library preflight" do
    # On an old-glibc host the floor refusal must be the one that fires,
    # whatever libraries are present — a missing-library hint there is
    # wrong advice (ADR 0032).
    assert File.read!("install.sh") =~ "require_glibc_floor\nrequire_linux_libs"
  end

  test "the shared contract script asserts every clause of the refusal" do
    contract = File.read!("scripts/refusal-contract.sh")

    assert contract =~ @floor_fragment
    assert contract =~ ~s([ "$status" -eq 1 ])
    assert contract =~ ~s([ ! -e "$data_home" ])
    assert contract =~ ~s([ ! -e "$bin_dir/dashfloat" ])
  end

  test "both negative smokes assert through the contract script" do
    release = File.read!(".github/workflows/release.yml")

    assert length(String.split(release, "sh scripts/refusal-contract.sh")) == 3
  end
end

defmodule DashFloat.InstallerContractTest do
  @moduledoc false
  # The glibc-floor refusal contract pinned at mix ci time (ADR 0032): the
  # installer's die message and the smokes' shared assertion must agree, the
  # floor preflight must precede the library preflight, and both negative
  # smokes must assert through the contract script — so the wording and the
  # test cannot drift apart between releases, and the false green of
  # issue #52 (a below-floor install accepted on any failure) cannot return
  # unnoticed. The pins are tripwires against accidental drift, not against
  # a deliberate edit that preserves these strings while disabling the
  # clauses; the smokes' own runs are the backstop (ADR 0032 § Consequences).
  use ExUnit.Case, async: true

  test "the contract's grep matches the installer's rendered glibc-floor die line" do
    # Extract the die message template from install.sh, render it the way
    # die/1 prints it for a sample host, and require the contract script's
    # grep pattern to match — a wording change on either side reds here.
    installer = File.read!("install.sh")
    [_installer_head, raw_template] = :binary.split(installer, ~s(die "glibc $ver ))

    template =
      raw_template
      |> String.split(~s("))
      |> hd()

    die_line = "dashfloat: glibc 2.31 " <> template

    contract = File.read!("scripts/refusal-contract.sh")
    [_contract_head, raw_pattern] = :binary.split(contract, "grep -Eq '")

    pattern =
      raw_pattern
      |> String.split("'")
      |> hd()

    compiled = Regex.compile!(pattern)

    assert Regex.match?(compiled, die_line)
  end

  test "the floor preflight runs before the by-name library preflight" do
    # On an old-glibc host the floor refusal must be the one that fires,
    # whatever libraries are present — a missing-library hint there is
    # wrong advice (ADR 0032).
    assert File.read!("install.sh") =~ "require_glibc_floor\nrequire_linux_libs"
  end

  test "the shared contract script asserts every clause of the refusal" do
    contract = File.read!("scripts/refusal-contract.sh")

    assert contract =~ ~s([ "$status" -eq 1 ])
    assert contract =~ ~s([ ! -e "$data_home" ])
    assert contract =~ ~s([ ! -e "$bin_dir/dashfloat" ])
    # The data-dir clause mirrors the installer's full override set.
    assert contract =~
             ~s(data_home="${DASHFLOAT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/dashfloat}")
  end

  test "both negative smokes assert through the contract script" do
    # Count real invocations only: a commented-out call must red this, not
    # satisfy it.
    invocations =
      ".github/workflows/release.yml"
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(&invokes_contract?/1)

    assert invocations == 2
  end

  defp invokes_contract?(line) do
    trimmed = String.trim(line)

    String.contains?(line, "sh scripts/refusal-contract.sh") and
      not String.starts_with?(trimmed, "#")
  end
end

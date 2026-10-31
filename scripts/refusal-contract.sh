#!/bin/sh
# The installer's glibc-floor refusal contract (ADR 0032), shared by the
# release pipeline's negative smokes — the tag-run bullseye arm in
# smoke-linux and the rehearsal arm in smoke-rehearsal. A below-floor host
# must be refused by the SPECIFIC refusal: the floor message, exit 1, and
# nothing written. Any-failure acceptance is a false green (issue #52): on
# the v0.4.0 tag the libcrypto.so.3 preflight fired first and the job
# passed without the floor ever being exercised.
#
# Usage: refusal-contract.sh <installer-exit-status> <output-log>
# Exits 0 when the contract holds, 1 naming the broken clause when not.
set -eu

status=$1
log=$2

fail() { printf 'refusal contract: %s\n' "$1" >&2; exit 1; }

[ "$status" -eq 1 ] ||
  fail "expected the installer to refuse with exit 1, got $status"
grep -q 'is below the GLIBC_2.34 floor' "$log" ||
  fail "the glibc-floor refusal message is absent from the output above — the failure is not the floor refusal"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/dashfloat"
bin_dir="${DASHFLOAT_BIN_DIR:-$HOME/.local/bin}"
[ ! -e "$data_home" ] ||
  fail "a refused install left $data_home behind"
[ ! -e "$bin_dir/dashfloat" ] ||
  fail "a refused install left the $bin_dir/dashfloat shim behind"
echo "glibc-floor refusal contract holds: the specific message, exit 1, nothing installed"

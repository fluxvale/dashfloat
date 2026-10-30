#!/bin/sh
# DashFloat installer — https://github.com/fluxvale/dashfloat
#
#   curl -fsSL https://github.com/fluxvale/dashfloat/releases/latest/download/install.sh | sh
#
# Installs a self-contained release (ERTS included — no Erlang or Elixir
# needed) into a versioned directory and puts a `dashfloat` shim on PATH.
# No root, no package manager. Design and trade-offs: ADR 0010.
#
# Environment:
#   DASHFLOAT_VERSION           install this version instead of the latest
#   DASHFLOAT_HOME              data dir (default ${XDG_DATA_HOME:-$HOME/.local/share}/dashfloat)
#   DASHFLOAT_BIN_DIR           shim dir (default $HOME/.local/bin)
#   DASHFLOAT_RELEASE_BASE_URL  asset base URL (default: the GitHub release for the version)
#   DASHFLOAT_REPO              GitHub repo (default fluxvale/dashfloat)
#
# Requires curl. The tarball's sha256 is verified against the release's
# checksums file before anything is extracted. Re-running it upgrades in place
# and removes every other installed version.

set -eu

REPO="${DASHFLOAT_REPO:-fluxvale/dashfloat}"
REQUESTED_VERSION="${DASHFLOAT_VERSION:-}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
HOME_DIR="${DASHFLOAT_HOME:-$DATA_HOME/dashfloat}"
BIN_DIR="${DASHFLOAT_BIN_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'dashfloat: %s\n' "$*" >&2; exit 1; }

# --- platform -------------------------------------------------------------

detect_target() {
  os=$(uname -s 2>/dev/null || true)
  arch=$(uname -m 2>/dev/null || true)

  case "$os" in
    Linux)
      if ldd --version 2>&1 | grep -qi musl; then
        die "this is a musl system (Alpine?). DashFloat ships a glibc build and does not run on musl yet."
      fi

      case "$arch" in
        x86_64 | amd64) printf '%s\n' "x86_64-unknown-linux-gnu" ;;
        *) die "unsupported Linux architecture: $arch (v0.3.0 ships x86_64 only)" ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64) printf '%s\n' "aarch64-apple-darwin" ;;
        x86_64) printf '%s\n' "x86_64-apple-darwin" ;;
        *) die "unsupported macOS architecture: $arch" ;;
      esac
      ;;
    *)
      die "unsupported operating system: $os (v0.3.0 ships Linux x86_64 and macOS)"
      ;;
  esac
}

# --- version --------------------------------------------------------------

resolve_version() {
  if [ -n "$REQUESTED_VERSION" ]; then
    printf '%s\n' "${REQUESTED_VERSION#v}"
    return 0
  fi

  url=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)

  case "$url" in
    */tag/v*) printf '%s\n' "${url##*/tag/v}" ;;
    *) die "could not resolve the latest release — set DASHFLOAT_VERSION to pick one" ;;
  esac
}

check_version() {
  if ! printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "invalid version: $1"
  fi
}

# --- download + verify ----------------------------------------------------

proto_for() {
  case "$1" in
    http://*) printf '%s\n' "=https,http" ;;
    *) printf '%s\n' "=https" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "no sha256 tool found (need sha256sum or shasum)"
  fi
}

expected_sum() {
  awk -v asset="$2" '
    {
      name = $2
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      if (name == asset) { print $1; exit }
    }
  ' "$1"
}

# The release bundles ERTS but not the system libraries the BEAM and the crypto
# NIF link against. Check them before downloading 30 MB, and name the package:
# a minimal container has glibc but none of these (proved on debian:slim-style
# images). fuser/ldd checks are avoided — a missing lib is what we are asking.
require_linux_libs() {
  [ "$(uname -s)" = "Linux" ] || return 0

  missing=""
  for lib in libcrypto.so.3 libtinfo.so.6 libstdc++.so.6; do
    # ldconfig covers a normal system; the find covers minimal images without
    # it, and both 64-bit layouts (Debian/Ubuntu /usr/lib, Fedora /usr/lib64).
    if ! ldconfig -p 2>/dev/null | grep -q "$lib" &&
      ! find /lib /lib64 /usr/lib /usr/lib64 -name "$lib*" -print -quit 2>/dev/null | grep -q .; then
      missing="$missing $lib"
    fi
  done

  if [ -n "$missing" ]; then
    die "missing system libraries:$missing
The release needs OpenSSL 3, ncurses terminfo, and libstdc++. On Debian/Ubuntu:
  sudo apt-get install -y libssl3 libtinfo6 libstdc++6
(Alpine/musl is not supported.)"
  fi
}

# --- install --------------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl is required"

target=$(detect_target)
[ -n "$target" ] || die "could not detect this platform"
require_linux_libs

version=$(resolve_version)
check_version "$version"

base_url="${DASHFLOAT_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download/v$version}"
asset="dashfloat-$version-$target.tar.gz"
sums="dashfloat-$version-sha256sums.txt"
proto=$(proto_for "$base_url")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dashfloat.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

say "Downloading DashFloat $version ($target)…"
curl -fsSL --retry 3 --proto "$proto" -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL --retry 3 --proto "$proto" -o "$tmp/$sums" "$base_url/$sums"

expected=$(expected_sum "$tmp/$sums" "$asset")
[ -n "$expected" ] || die "no checksum for $asset in $sums"

actual=$(sha256_of "$tmp/$asset")
if [ "$actual" != "$expected" ]; then
  die "checksum mismatch for $asset
  expected: $expected
  actual:   $actual
Refusing to install."
fi

versions_dir="$HOME_DIR/versions"
target_dir="$versions_dir/$version"
staging="$target_dir.tmp.$$"

rm -rf "$staging"
mkdir -p "$staging"
tar -xzf "$tmp/$asset" -C "$staging"
[ -x "$staging/bin/dashfloat" ] || die "archive did not contain bin/dashfloat"

mkdir -p "$versions_dir"
rm -rf "$target_dir"
mv "$staging" "$target_dir"
ln -sfn "$target_dir" "$HOME_DIR/current"

# Prune on upgrade: one version on disk, so an old self-contained runtime is
# never left behind. Re-installing is seconds; rollback is a re-install.
for dir in "$versions_dir"/*; do
  [ -d "$dir" ] || continue
  if [ "$dir" = "$target_dir" ]; then
    continue
  fi
  rm -rf "$dir"
done

mkdir -p "$BIN_DIR"
printf '#!/bin/sh\nexec "%s/current/bin/dashfloat" "$@"\n' "$HOME_DIR" >"$BIN_DIR/dashfloat"
chmod 755 "$BIN_DIR/dashfloat"

# The point of the shim and the versioned dir: prove the installed artifact
# actually runs on this host before claiming success.
if ! installed=$("$target_dir/bin/dashfloat" --version 2>&1); then
  die "installed, but the binary failed to run on this host.
On Linux the release needs glibc 2.34+, OpenSSL 3 (libcrypto.so.3),
libtinfo.so.6, and libstdc++.so.6; the error above names what is missing."
fi

# stderr warnings (locale) are not a failed install; the artifact bundles the
# libraries the VM needs, so nothing SCTP-related should appear either.
installed=$(printf '%s\n' "$installed" | grep -E '^dashfloat ' | head -1)

say ""
say "$installed installed."
say ""
say "  binary: $BIN_DIR/dashfloat"
say "  data:   $HOME_DIR"

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "$BIN_DIR is not on PATH. Add it to your shell profile:"
    say ""
    say "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

if [ "$(uname -s)" = "Darwin" ]; then
  say ""
  say "macOS note: this build is not notarized. A copy downloaded with a"
  say "browser is quarantined; right-click it in Finder and choose Open once."
  say "Installing with curl or Homebrew sets no quarantine flag."
fi

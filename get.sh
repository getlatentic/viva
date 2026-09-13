#!/bin/sh
# Install viva from a released binary. Needs no SBCL, no Quicklisp, no checkout.
#
#     curl -fsSL https://raw.githubusercontent.com/getlatentic/viva/main/get.sh | sh
#
# VIVA_VERSION pins a tag, VIVA_PREFIX names the directory to link into, and
# VIVA_HOME moves the whole machine directory.
#
# Downloads two files -- the engine and the full-screen client -- into
# ~/.viva/bin, checks them against the release's own checksums, and then hands
# the PATH step to `viva install`, which already refuses to replace a stranger's
# binary and says the export line when a directory is not on PATH.
#
# To build from source instead, and to develop viva, use install.sh.
set -eu

REPO="${VIVA_REPO_SLUG:-getlatentic/viva}"
VERSION="${VIVA_VERSION:-latest}"

VIVA_HOME="${VIVA_HOME:-$HOME/.viva}"
store="$VIVA_HOME/bin"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\n%s\n' "$*" >&2; exit 1; }

step "your machine"
os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
  Darwin/arm64)       platform=macos-arm64 ;;
  Linux/x86_64|Linux/amd64) platform=linux-x86_64 ;;
  *)
    die "there is no released binary for $os/$arch.

Built binaries exist for macOS on Apple silicon and Linux on x86_64. On
anything else, build from source -- it needs SBCL:

  git clone https://github.com/$REPO && cd viva && sh install.sh"
    ;;
esac
say "  $os $arch -> $platform"

# A RELEASE ASSET, NOT A WORKFLOW ARTIFACT. Artifacts need a token to download
# and expire after ninety days, so a curl installer cannot use them.
if [ "$VERSION" = latest ]; then
  base="${VIVA_RELEASE_URL:-https://github.com/$REPO/releases/latest/download}"
else
  base="${VIVA_RELEASE_URL:-https://github.com/$REPO/releases/download/$VERSION}"
fi

sums="SHA256SUMS-$platform"
engine="viva-$platform"
client="viva-tui-$platform"

step "downloading $VERSION"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
for file in "$engine" "$client" "$sums"; do
  say "  $file"
  curl -fsSL -o "$tmp/$file" "$base/$file" \
    || die "could not download $base/$file

If $VERSION is not a release yet, there is nothing to install. Build from
source instead: git clone https://github.com/$REPO && cd viva && sh install.sh"
done

# A CHECK THAT CANNOT RUN MUST SAY SO. Skipping it quietly would turn a
# truncated download into a binary that fails later for no stated reason.
step "checking what arrived"
if command -v sha256sum >/dev/null 2>&1; then
  verify="sha256sum -c"
elif command -v shasum >/dev/null 2>&1; then
  verify="shasum -a 256 -c"
else
  die "neither sha256sum nor shasum is on this PATH, so the download cannot be
checked. Install one, or download the binaries by hand from
https://github.com/$REPO/releases"
fi
(cd "$tmp" && $verify "$sums") >/dev/null \
  || die "the download does not match the release's checksums. Try again; if it
keeps happening, say so at https://github.com/$REPO/issues"
say "  both files match $sums"

# WHAT IS THERE NOW, asked before anything is replaced. A re-run is the normal
# way to upgrade, and "installed" is the wrong word for it.
was=
if [ -x "$store/viva" ]; then
  was=$("$store/viva" --version 2>/dev/null || true)
fi

# INTO PLACE ONLY AFTER CHECKING, and by rename: a running daemon keeps the file
# it started from, so replacing the binary under it cannot kill it.
step "installing into $store"
mkdir -p "$store"
chmod 755 "$tmp/$engine" "$tmp/$client"
mv "$tmp/$engine" "$store/viva"
mv "$tmp/$client" "$store/viva-tui"
now=$("$store/viva" --version 2>/dev/null || true)
if [ -z "$was" ]; then
  say "  ${now:-viva} installed"
elif [ "$was" = "$now" ]; then
  say "  ${now:-viva} was already here, and has been replaced with the same"
else
  say "  $was -> $now"
fi

# `viva install` owns the PATH question: it refuses to replace anything it did
# not put there, and prints the export line when it has to. It also knows to
# link ITSELF rather than a checkout, which is what makes this work at all.
# A DAEMON KEEPS THE CODE IT STARTED WITH. It survives the replacement, which is
# the point of renaming rather than writing in place -- but it goes on serving
# the previous build until somebody says otherwise, and a new client talking to
# an old daemon is the kind of mismatch that gets blamed on the new build.
if [ -n "$was" ] && [ "$was" != "$now" ] && "$store/viva" daemon status >/dev/null 2>&1; then
  step "a daemon is still running $was"
  say "  it keeps serving that until it restarts. When the work in it can stop:"
  say ""
  say "      viva daemon restart"
fi

step "putting viva on your PATH"
# VIVA_PREFIX names the directory, for a machine where the guess would be
# wrong -- and so this script can be tested without writing to a real PATH.
if [ -n "${VIVA_PREFIX:-}" ]; then
  "$store/viva" install --prefix "$VIVA_PREFIX"
else
  "$store/viva" install
fi

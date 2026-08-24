#!/bin/sh
# Install vivarium on a machine that has never seen it.
#
#     sh install.sh                     from a clone
#     curl -fsSL <raw-url> | sh         from nothing
#
# Does four things, says each one, and stops at the first that fails:
# checks for SBCL, installs Quicklisp if it is missing, clones or updates the
# repository, and links `vivarium` onto PATH. It never touches your keys.
set -eu

REPO="${VIVARIUM_REPO:-https://github.com/getlatentic/viva}"

# Where viva keeps its own files. A machine installed before the rename still
# holds the former directory, and its keys and sessions are in it, so that one
# is used where it is the only one there.
VIVA_HOME="$HOME/.viva"
if [ ! -d "$VIVA_HOME" ] && [ -d "$HOME/.vivarium" ]; then
  VIVA_HOME="$HOME/.vivarium"
fi

DEST="${VIVARIUM_DEST:-$VIVA_HOME/src}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\n%s\n' "$*" >&2; exit 1; }

step "SBCL"
if ! command -v sbcl >/dev/null 2>&1; then
  die "vivarium needs SBCL, and there is none on your PATH.

  macOS          brew install sbcl
  Debian/Ubuntu  sudo apt install sbcl
  Fedora         sudo dnf install sbcl

Then run this again."
fi
say "  $(sbcl --version)"

step "Quicklisp"
if [ -f "$HOME/quicklisp/setup.lisp" ]; then
  say "  already at ~/quicklisp"
else
  say "  installing to ~/quicklisp"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/quicklisp.lisp" https://beta.quicklisp.org/quicklisp.lisp \
    || die "could not download Quicklisp. Check your network and run this again."
  sbcl --non-interactive --load "$tmp/quicklisp.lisp" \
       --eval '(quicklisp-quickstart:install)' >/dev/null 2>&1 \
    || die "Quicklisp would not install. Try it by hand:
  curl -O https://beta.quicklisp.org/quicklisp.lisp
  sbcl --non-interactive --load quicklisp.lisp --eval '(quicklisp-quickstart:install)'"
  rm -rf "$tmp"
  say "  done"
fi

step "vivarium"
# A clone this script is being run FROM is the one to use: somebody who cloned
# and ran `sh install.sh` means that checkout, not a second copy of it.
here=$(cd "$(dirname "$0")" && pwd)
if [ -f "$here/bin/viva" ] && [ -f "$here/vivarium.asd" ]; then
  root=$here
  say "  using this clone: $root"
elif [ -d "$DEST/.git" ]; then
  root=$DEST
  say "  updating $root"
  git -C "$root" pull --ff-only --quiet || say "  (could not pull; using what is there)"
else
  root=$DEST
  say "  cloning into $root"
  mkdir -p "$(dirname "$root")"
  git clone --quiet "$REPO" "$root" || die "could not clone $REPO"
fi

step "package ordering"
# Before anything is loaded, because this is the one class of fault that stops
# the load: a local nickname pointing at a package defined below it. Both
# obvious homes for this check are dead -- the suite never runs, and
# `vivarium check` dies in the loader -- so it is a script that reads text.
sbcl --script "$root/tools/check-package-order.lisp" || exit 1

step "compiling, and running the tests"
say "  the first run fetches dependencies and takes a few minutes"
"$root/bin/viva" test >/tmp/vivarium-install-test.log 2>&1 || {
  tail -20 /tmp/vivarium-install-test.log >&2
  die "the test suite did not pass. The full log is /tmp/vivarium-install-test.log"
}
grep -E "^(Passed|Failed):" /tmp/vivarium-install-test.log | sed 's/^/  /'

step "putting vivarium on your PATH"
"$root/bin/viva" install | sed 's/^/  /'

step "credentials"
if [ -f "$VIVA_HOME/.env" ]; then
  say "  $VIVA_HOME/.env is already there; leaving it alone"
else
  mkdir -p "$VIVA_HOME"
  cp "$root/.env.example" "$VIVA_HOME/.env"
  chmod 600 "$VIVA_HOME/.env"
  say "  wrote $VIVA_HOME/.env from the example -- open it and fill in ONE key"
fi

cat <<EOF

Done. Next:

  1. put a provider key in $VIVA_HOME/.env
  2. cd into any project and run:  viva
  3. see what it has learned:      vivarium learned
  4. watch it learn something:     $root/demo/retention

\`vivarium config\` shows every setting and which file decided it.
EOF

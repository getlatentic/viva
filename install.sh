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

REPO="${VIVARIUM_REPO:-https://github.com/tosinamuda/vivarium}"
DEST="${VIVARIUM_DEST:-$HOME/.vivarium/src}"

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
if [ -f "$here/bin/vivarium" ] && [ -f "$here/vivarium.asd" ]; then
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

step "compiling, and running the tests"
say "  the first run fetches dependencies and takes a few minutes"
"$root/bin/vivarium" test >/tmp/vivarium-install-test.log 2>&1 || {
  tail -20 /tmp/vivarium-install-test.log >&2
  die "the test suite did not pass. The full log is /tmp/vivarium-install-test.log"
}
grep -E "^(Passed|Failed):" /tmp/vivarium-install-test.log | sed 's/^/  /'

step "putting vivarium on your PATH"
"$root/bin/vivarium" install | sed 's/^/  /'

step "credentials"
if [ -f "$HOME/.vivarium/.env" ]; then
  say "  ~/.vivarium/.env is already there; leaving it alone"
else
  mkdir -p "$HOME/.vivarium"
  cp "$root/.env.example" "$HOME/.vivarium/.env"
  chmod 600 "$HOME/.vivarium/.env"
  say "  wrote ~/.vivarium/.env from the example -- open it and fill in ONE key"
fi

cat <<EOF

Done. Next:

  1. put a provider key in ~/.vivarium/.env
  2. cd into any project and run:  vivarium
  3. see what it has learned:      vivarium learned
  4. watch it learn something:     $root/demo/retention

\`vivarium config\` shows every setting and which file decided it.
EOF

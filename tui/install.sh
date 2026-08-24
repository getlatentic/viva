#!/bin/sh
# Build vivarium-tui and link it next to `vivarium` on your PATH.
#
#     sh tui/install.sh
#
# Separate from the Lisp installer on purpose: this one needs a Rust toolchain,
# and someone who only wants the engine and the line client should not be told
# to install one.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

command -v cargo >/dev/null 2>&1 || {
  echo "vivarium-tui needs a Rust toolchain, and there is no cargo on your PATH." >&2
  echo "  https://rustup.rs" >&2
  exit 1
}

echo "== building"
cargo build --release --manifest-path "$here/Cargo.toml"

# NOT linked onto the PATH under its own name. `vivarium` is the command; the
# launcher finds this binary in the tree and runs it. A second name to install,
# find, keep in step and explain buys nothing -- the person running it does not
# care which language drew the frame.
echo "== built"
echo "  $here/target/release/vivarium-tui"
echo
echo "Run it with:  $root/bin/viva tui"

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

binary="$here/target/release/vivarium-tui"
for candidate in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
  if [ -d "$candidate" ] && [ -w "$candidate" ]; then
    target="$candidate"
    break
  fi
done
target=${target:-$HOME/.local/bin}
mkdir -p "$target"
ln -sf "$binary" "$target/vivarium-tui"

echo "== linked"
echo "  $target/vivarium-tui -> $binary"
case ":$PATH:" in
  *":$target:"*) echo "  run: vivarium-tui" ;;
  *) echo "  $target is not on your PATH; add it, or run $target/vivarium-tui" ;;
esac
echo
echo "It needs a daemon: $root/bin/vivarium daemon start --background"

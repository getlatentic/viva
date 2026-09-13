#!/bin/sh
# Save viva as one executable, from wherever this script lives.
#
# A wrapper because the image has to be built from the repository root -- the
# build pushes it onto Quicklisp's local projects -- and a caller in CI or a
# release should not have to know that.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-viva}
case $out in
  /*) target=$out ;;
  *)  target=$(pwd)/$out ;;
esac
cd "$root"
. "$root/tools/sbcl.sh"
# What this build IS, asked here rather than inside the image: git is a command,
# and the checkout exists now but will not exist wherever the binary ends up.
: "${VIVA_BUILD_VERSION:=$(git describe --tags --always --dirty 2>/dev/null || true)}"
export VIVA_BUILD_VERSION
"$sbcl_bin" --script tools/build-image.lisp "$target"
printf '%s\n' "$target"

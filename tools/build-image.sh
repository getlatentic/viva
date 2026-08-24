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
sbcl --script tools/build-image.lisp "$target"
printf '%s\n' "$target"

#!/bin/sh
# Terminal conformance: the invariants, checked where the terminal actually is.
#
# WHY THIS EXISTS. The previous harness ignored ESC[2J, so its replay
# accumulated every frame ever drawn -- including frames from before a resize,
# at a different width -- and interleaved them. It reported corruption the
# terminal never had, which means it could never have told us the terminal was
# clean. Once a testing abstraction is found to be an unfaithful model of the
# thing it models, every assertion made through it is suspect until shown
# otherwise. This file is that showing.
#
# THE EMULATOR'S SCOPE, stated rather than assumed. Every sequence the TUI
# emits, and what the replay below does with it:
#
#   ESC[<r>;<c>H   CUP          moves the cursor            MODELLED
#   ESC[2J         ED           clears the grid             MODELLED
#   ESC[?1049h/l   alt screen   clears the grid on entry    MODELLED
#   ESC[0m, ESC[..m SGR         colour and weight           IGNORED, knowingly:
#                                                           these assertions are
#                                                           about layout, and
#                                                           colour is asserted
#                                                           in-process instead
#   ESC[?25h/l     cursor show/hide                         IGNORED, no cell effect
#   ESC[?1000/1002/1006 h/l  mouse modes                    IGNORED, no cell effect
#   ESC[>1u ESC[<u kitty flags                              IGNORED, no cell effect
#   ESC[?u         kitty query                              IGNORED, no cell effect
#
# Anything NOT on that list appearing in the output is a failure, because it
# means the TUI grew a sequence this model has never been checked against.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python3 "$root/tools/pty_conformance.py" "$root"

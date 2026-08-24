#!/bin/sh
# Does the full-screen client behave inside a tmux pane?
#
# #45 says it works in a pane "which is where it will actually live", and #17
# ratified riding somebody else's terminal rather than building one. A pane is
# the honest test of both: tmux is a real emulator with its own size, its own
# capabilities, and its own opinion about what the inner program may do.
#
# tmux is asked what it sees with capture-pane, so the assertion is on the
# rendered pane rather than on bytes this program emitted.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
session="vivarium-pane-check-$$"
width=${1:-90}
height=${2:-24}

cleanup() { tmux kill-session -t "$session" 2>/dev/null || true; }
trap cleanup EXIT

tmux new-session -d -s "$session" -x "$width" -y "$height" \
     "cd $root && ./bin/viva live"

# The first run compiles; wait for a frame rather than guessing a duration.
tries=0
until tmux capture-pane -p -t "$session" 2>/dev/null | grep -q vivarium; do
  tries=$((tries + 1))
  if [ "$tries" -gt 300 ]; then
    echo "no frame after 300 seconds:"
    tmux capture-pane -p -t "$session" 2>/dev/null || echo "(pane is gone)"
    exit 1
  fi
  sleep 1
done
echo "a frame rendered in a ${width}x${height} pane"

tmux send-keys -t "$session" "typed in tmux"
sleep 2
pane=$(tmux capture-pane -p -t "$session")
echo "$pane" | grep -q "> typed in tmux" || {
  echo "typing did not reach the input line:"; echo "$pane"; exit 1; }
echo "typing reaches the input line"

# Narrow it while it runs. A client that cannot survive a resize is no use in a
# multiplexer, where resizing is how panes are made.
tmux resize-window -t "$session" -x 50 -y 15
sleep 3
narrow=$(tmux capture-pane -p -t "$session")
echo "$narrow" | grep -q vivarium || {
  echo "the frame did not survive being narrowed to 50 columns:"
  echo "$narrow"; exit 1; }
echo "$narrow" | grep -q "tasks" && {
  echo "the task pane survived into 50 columns, squeezing the output"; exit 1; }
echo "narrowing to 50 columns dropped the side pane and kept drawing"

# And back out again.
tmux resize-window -t "$session" -x "$width" -y "$height"
sleep 3
tmux capture-pane -p -t "$session" | grep -q vivarium || {
  echo "widening lost the frame"; exit 1; }
echo "widening again keeps the frame"

tmux send-keys -t "$session" C-c
sleep 3
tmux capture-pane -p -t "$session" 2>/dev/null | grep -q "is still running" && {
  echo "detached cleanly, leaving the session running"; exit 0; }
echo "note: pane already closed after Ctrl-C"

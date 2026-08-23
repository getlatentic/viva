#!/bin/sh
# Re-prove the proven layer, and prove the witnesses still bite.
#
# Every config here carries an EXPECTATION, and half of them expect a
# violation. That is the point: a witness that stops violating has stopped
# being evidence, and would otherwise rot silently into a green line. The same
# rule the attack tests live under -- an attack that cannot lose is not an
# attack -- applied to the layer that claims to be proven.
#
#   ./verify.sh                one line per config, non-zero if any disagrees
#   TLA_TOOLS=/path/to.jar ./verify.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
jar=${TLA_TOOLS:-$HOME/tla2tools.jar}

if ! command -v java >/dev/null 2>&1; then
  echo "TLC needs a JVM, and there is no java on PATH." >&2
  echo "Install one (brew install openjdk, or your distribution's) and retry." >&2
  exit 2
fi

if [ ! -f "$jar" ]; then
  # An actionable failure. The README offers this script as a receipt a reader
  # can run, and a clean machine has no jar -- so saying only `set TLA_TOOLS`
  # tells someone who has never heard of TLA+ exactly nothing.
  cat >&2 <<MSG
tla2tools.jar not found at $jar.

It is TLC, the TLA+ model checker, and it is a single file:

  curl -L -o ~/tla2tools.jar \\
    https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar

Then run this again, or point at it with TLA_TOOLS=/path/to/tla2tools.jar.
MSG
  exit 2
fi

# config : module : expectation : what the expectation means
cases='
CellLifecycle:CellLifecycle:holds:the cell lifecycle, complete space
ReplayBarrier:ReplayBarrier:holds:no subscriber misses an event across the barrier
ReplayBarrierBroken:ReplayBarrier:violates:without the barrier, the gap is reachable
TaskTreeSafety:TaskTree:holds:scoped children cannot outlive their parent
TaskTreeLiveness:TaskTree:holds:every task reaches a terminal
TaskTreeWitnessOrphan:TaskTree:violates:without the drain, a scoped child orphans
TaskTreeWitnessDetached:TaskTree:violates:detached lifetimes are genuinely different
EvolutionSafety:Evolution:holds:the seven lifecycle laws
EvolutionLiveness:Evolution:holds:a candidate always reaches a terminal
EvolutionWitnessLeak:Evolution:violates:activation must not touch the lineage
EvolutionWitnessDiscard:Evolution:violates:unguarded discard is resolvable
EvolutionClosed:Evolution:holds:KC6 arm B is inert, and still lively
EvolutionWitnessDoor:Evolution:violates:the door guard is load-bearing
ReconcileSafety:Reconcile:holds:the ledger never claims more than the world holds
ReconcileLiveness:Reconcile:holds:nothing is left mid-flight forever
ReconcileWitnessAtomic:Reconcile:violates:assumed-atomic compensation reports reverted while effects remain
TaskMessagingSafety:TaskMessaging:holds:no message vanishes without the sender being told
TaskMessagingWitnessDrop:TaskMessaging:violates:a full inbox that drops silently is reachable
StreamOpeningSafety:StreamOpening:holds:a session stream opens with the session opening
StreamOpeningWitnessRace:StreamOpening:violates:published from two threads, the transcript can precede the start
RecoverySafety:Recovery:holds:a session can outlive the daemon without losing an event or a name
RecoveryWitnessOrder:Recovery:violates:the arrangement the daemon has today: told before written, a crash loses what was read
RecoveryWitnessName:Recovery:violates:a counter-minted name points a client at a different conversation
'

failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Fed by redirection, never by a pipe: a piped while runs in a subshell and
# every failure it counted would be discarded at the done.
printf '%s\n' "$cases" > "$work/cases"

printf '%-28s %-9s %s\n' CONFIG EXPECTED RESULT
while IFS=: read -r config module expect meaning; do
  [ -n "$config" ] || continue
  log="$work/$config.log"
  # TLC writes states/ into the working directory; keep it out of the tree.
  # -deadlock disables the deadlock CHECK: these are finite models whose
  # terminal states are the point (versions exhausted, every task ended), and
  # a state with no successor there is the model finishing, not a defect.
  # </dev/null because java would otherwise eat the rest of the case list.
  if (cd "$work" && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -config "$here/$config.cfg" -workers auto -deadlock -cleanup \
        "$here/$module.tla" >"$log" 2>&1 </dev/null); then
    actual=holds
  else
    if grep -q 'Invariant .* is violated\|Temporal properties were violated' "$log"; then
      actual=violates
    else
      actual=error
    fi
  fi

  # The state count is the evidence; a bare "ok" hides a model that shrank.
  # Exhaustive runs report a stable number. A violating witness stops at its
  # counterexample, so its count is "states explored before the violation" and
  # moves between runs with worker scheduling -- not drift.
  states=$(sed -n 's/.*, \([0-9]*\) distinct states found.*/\1/p' "$log" | tail -1)

  if [ "$actual" = "$expect" ]; then
    printf '%-28s %-9s ok  %8s states  %s\n' \
      "$config" "$expect" "${states:-n/a}" "$meaning"
  else
    printf '%-28s %-9s FAIL  got %s\n' "$config" "$expect" "$actual"
    sed -n '1,25p' "$log"
    failures=$((failures + 1))
  fi
done < "$work/cases"

if [ "$failures" -ne 0 ]; then
  echo "$failures config(s) disagreed with their expectation" >&2
  exit 1
fi
echo "all configs agreed with their expectations"

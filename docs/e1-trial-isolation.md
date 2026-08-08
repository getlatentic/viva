# E1 — trial isolation and cost

**Status: done.** Result summarised in the [README](README.md#e1-result-which-reshapes-everything-downstream);
this file holds the method and the things the measurement does not cover.

## Claim

An isolated trial — install a candidate definition, run a scored workload, discard
the world — costs milliseconds in a live image, against seconds for any loop that
starts a process.

## Method

[probes/fork-probe.lisp](probes/fork-probe.lisp) forks at three thread counts and
reports whether the child can compile and call a function.
[probes/zygote-probe.lisp](probes/zygote-probe.lisp) loads genera-lab
single-threaded and times 20 trials sequentially, 20 in parallel, and 20 in-process.
[probes/save-core.lisp](probes/save-core.lisp) builds a preloaded core for the
fresh-process row.

Reproduce:

```bash
cd ~/workspace/research/live-image-harness/probes && sbcl --non-interactive --load zygote-probe.lisp
```

## Verdict

Claim holds, with the design consequence that fork requires a single-threaded
process, so a zygote is mandatory. Numbers and the resulting three-process
architecture are in the README.

## What this does not settle

- **Fixture fidelity.** The zygote scores against fixtures, not live sessions.
  Whether a fixture-scored win survives contact with real traffic is E2's problem.
- **Trial independence within a child.** Each child here runs exactly one trial and
  exits. Reusing a child for several trials would amortise the 30 ms but reintroduce
  the warm-state confound that fork was bought to avoid. Not tested; assume it is
  unsafe until measured.
- **Heap growth.** Fork cost scales with resident heap. Measured at ~100 MB. A
  zygote holding large fixtures will get slower, and the 28 ms figure is a floor,
  not a constant.
- **`_exit` vs unwinding.** Children exit with `sb-ext:exit :abort t` to skip exit
  hooks and shared buffer flushes. If a trial needs to report more than an exit code,
  the write path has to be a pipe or file the parent reads — not stdout, which the
  child shares with the parent.

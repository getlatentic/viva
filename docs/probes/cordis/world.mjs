// The mutable runtime a component acts on, and the introspection a reconciler
// gets. Stands in for the part of an agent harness a self-edit actually touches:
// vivarium's tool table, its event subscriptions, its policy config, and the
// resources a capability holds open.
//
// THE OBSERVATIONAL BOUNDARY IS DECLARED HERE, BEFORE ANY MEASUREMENT, because
// Cordis's equivalence is up to coeffect projection (S3.3.2: "the part of a
// state that no key binds is thereby forgotten") and a probe that compares
// everything would report a failure the paradigm never claimed to prevent.
//
//   INSIDE   tools, listeners, policy, handles   snapshot() compares these
//   OUTSIDE  emitted                             an append-only external log
//
// `emitted` is the acquisition/emission split of S6.1 made concrete: a write
// that has left for somewhere other parties can read. Nothing in this probe
// asks Cordis to revert it, and a clean unload that leaves it standing has not
// failed.

export function createWorld() {
  return {
    tools: new Map(),
    listeners: new Map(),
    policy: new Map(),
    handles: new Map(),
    emitted: [],
    log: [],
  }
}

export function trace(world, line) {
  world.log.push(line)
}

// --- the four inside locations, each with an honest inverse ----------------
//
// Every mutator returns the inverse that undoes it. A component is free to
// register that inverse with ctx.effect, register a DIFFERENT one, or not
// register anything at all -- which is precisely the author obligation the
// runtime does not check (S5.1.1).

export function registerTool(world, name, handler) {
  world.tools.set(name, handler)
  return () => world.tools.delete(name)
}

export function subscribe(world, event, listener) {
  if (!world.listeners.has(event)) world.listeners.set(event, new Set())
  world.listeners.get(event).add(listener)
  return () => world.listeners.get(event).delete(listener)
}

export function setPolicy(world, key, value) {
  const had = world.policy.has(key)
  const previous = world.policy.get(key)
  world.policy.set(key, value)
  return () => (had ? world.policy.set(key, previous) : world.policy.delete(key))
}

export function openHandle(world, id) {
  world.handles.set(id, { open: true })
  return () => world.handles.get(id) && (world.handles.get(id).open = false)
}

// --- outside the boundary --------------------------------------------------

export function emit(world, line) {
  world.emitted.push(line)
}

// --- introspection ---------------------------------------------------------
//
// What a reconciler can see. Sorted so two snapshots compare as text, and
// confined to the inside locations declared above.

export function snapshot(world) {
  return {
    tools: [...world.tools.keys()].sort(),
    listeners: [...world.listeners.entries()]
      .map(([event, set]) => [event, set.size])
      .filter(([, size]) => size > 0)
      .sort(),
    policy: [...world.policy.entries()].sort(),
    handles: [...world.handles.entries()]
      .filter(([, handle]) => handle.open)
      .map(([id]) => id)
      .sort(),
  }
}

export function difference(before, after) {
  const out = []
  for (const location of ['tools', 'listeners', 'policy', 'handles']) {
    const b = JSON.stringify(before[location])
    const a = JSON.stringify(after[location])
    if (b !== a) out.push({ location, before: before[location], after: after[location] })
  }
  return out
}

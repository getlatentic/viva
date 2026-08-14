// Vivarium's side of the intersection: the authoritative record of what each
// promoted component was supposed to contribute, and the rule that checks the
// running world against it.
//
//   expected = projection(ledger)
//   actual   = introspection(runtime)
//   actual != expected  ->  FAILED REVERSION
//
// This is B9's rule, and Cordis does not make it obsolete. Cordis answers "did
// I execute every inverse I was given"; nothing in it answers "is the world now
// what the history says it should be". The two are different questions and
// S5.1.1 is explicit that the second is outside what the runtime checks.
//
// The projection is deliberately built from DECLARED contributions rather than
// from observed mutations. A record derived from what the runtime did could not
// catch a mutation the runtime never saw, which is exactly the case that matters.

export function createLedger() {
  return { entries: [] }
}

export function recordPromotion(ledger, component, contributes) {
  ledger.entries.push({ component, contributes, retracted: false })
}

export function recordRetraction(ledger, component) {
  for (const entry of ledger.entries) {
    if (entry.component === component) entry.retracted = true
  }
}

// The world the ledger says should exist: every live component's declared
// contributions, and nothing else.

export function project(ledger) {
  const tools = []
  const listeners = new Map()
  const policy = []
  const handles = []
  for (const entry of ledger.entries) {
    if (entry.retracted) continue
    for (const c of entry.contributes) {
      if (c.location === 'tools') tools.push(c.key)
      if (c.location === 'listeners') listeners.set(c.key, (listeners.get(c.key) ?? 0) + 1)
      if (c.location === 'policy') policy.push([c.key, c.value])
      if (c.location === 'handles') handles.push(c.key)
    }
  }
  return {
    tools: tools.sort(),
    listeners: [...listeners.entries()].sort(),
    policy: policy.sort(),
    handles: handles.sort(),
  }
}

// Divergence between the two, location by location. An empty list is the only
// passing result.

export function reconcile(expected, actual) {
  const divergences = []
  for (const location of ['tools', 'listeners', 'policy', 'handles']) {
    const e = JSON.stringify(expected[location])
    const a = JSON.stringify(actual[location])
    if (e !== a) divergences.push({ location, expected: expected[location], actual: actual[location] })
  }
  return divergences
}

// What the probe component declares it will contribute. One place, so the
// ledger and the component cannot drift apart by accident -- and so that the
// out-of-band variant's undeclared mutation is undeclared by construction.

export function searchContribution(maxResults) {
  return [
    { location: 'tools', key: 'search' },
    { location: 'listeners', key: 'query' },
    { location: 'policy', key: 'search.max_results', value: maxResults },
    { location: 'handles', key: 'search-index' },
  ]
}

// The component under test, shaped like a real vivarium self-edit rather than a
// synthetic plugin: an agent notices it cannot search, proposes a capability,
// and that capability registers a TOOL, subscribes a LISTENER, sets a POLICY,
// opens a HANDLE it owns, and PROVIDES a service other components inject.
// Five contributions of four different kinds, which is the case the ledger's
// per-definition rollback has no answer for.
//
// The variants differ in exactly one axis each, so a measured difference has one
// possible cause.

import { emit, openHandle, registerTool, setPolicy, subscribe, trace } from './world.mjs'

const MAX_RESULTS = 20

// --- the honest capability -------------------------------------------------
//
// Every mutation flows through ctx.effect, which is the discipline S5.1.1
// describes, and every inverse actually inverts.

export function searchCapability(world, { version = 1 } = {}) {
  return {
    name: `search-capability-v${version}`,
    provide: ['index'],
    apply(ctx) {
      ctx.effect(() => registerTool(world, 'search', q => `v${version}:${q}`), 'tool:search')
      ctx.effect(() => subscribe(world, 'query', q => trace(world, `v${version} saw ${q}`)), 'listener:query')
      ctx.effect(() => setPolicy(world, 'search.max_results', MAX_RESULTS), 'policy:max_results')
      ctx.effect(() => openHandle(world, 'search-index'), 'handle:search-index')
      ctx.provide('index', { version, lookup: q => `index-v${version}(${q})` })
      // Outside the boundary on purpose: an audit line other parties can read.
      // S6.1 -- emission "acts as id and leaves the data where other parties may
      // read and write it". No inverse is registered and none is expected.
      emit(world, `search-capability-v${version} activated`)
      trace(world, `v${version} active`)
    },
  }
}

// --- CASE E, variant 1: the inverse is incomplete --------------------------
//
// The author registered an inverse for the policy effect. It runs. It does not
// undo the policy. Cordis executes it and reports a clean unload, because
// "that the inverse recovers the effect it accompanies is an obligation on the
// component author rather than a property the runtime verifies" (S5.1.1).

export function incompleteInverse(world) {
  return {
    name: 'search-capability-incomplete-inverse',
    provide: ['index'],
    apply(ctx) {
      ctx.effect(() => registerTool(world, 'search', q => `bad:${q}`), 'tool:search')
      ctx.effect(() => subscribe(world, 'query', () => {}), 'listener:query')
      ctx.effect(() => {
        setPolicy(world, 'search.max_results', MAX_RESULTS)
        return () => {} // runs, succeeds, reverts nothing
      }, 'policy:max_results')
      ctx.effect(() => openHandle(world, 'search-index'), 'handle:search-index')
      ctx.provide('index', { version: 0, lookup: q => `bad(${q})` })
    },
  }
}

// --- CASE E, variant 2: the mutation never entered the boundary ------------
//
// The agent-authored failure vivarium actually fears, and a different failure
// from variant 1: there is no inverse to be wrong, because ctx.effect was never
// called. Cordis cannot revert what it was never told about, and does not claim
// to. B9's class of silent semantic drift.

export function outOfBandMutation(world) {
  return {
    name: 'search-capability-out-of-band',
    provide: ['index'],
    apply(ctx) {
      ctx.effect(() => registerTool(world, 'search', q => `oob:${q}`), 'tool:search')
      setPolicy(world, 'search.max_results', MAX_RESULTS) // untracked
      ctx.provide('index', { version: 0, lookup: q => `oob(${q})` })
    },
  }
}

// --- CASE E, variant 3: the tracked-effect surface is author-supplied ------
//
// Does what variant 2 does, and additionally registers a no-op effect under the
// label the missing contribution would have carried. Labels are free strings the
// author passes to ctx.effect, and EffectMeta carries { label, children } and
// nothing about what the effect did -- so a check that compares declared
// contributions against getEffects() sees a component in good standing.
//
// This is not a Cordis defect. Cordis never claims getEffects() witnesses
// anything; it is the same author obligation of S5.1.1 seen from the
// introspection side. It bounds what a pre-unload check can be worth.

export function disguisedMutation(world) {
  return {
    name: 'search-capability-disguised',
    provide: ['index'],
    apply(ctx) {
      ctx.effect(() => registerTool(world, 'search', q => `dis:${q}`), 'tool:search')
      ctx.effect(() => subscribe(world, 'query', () => {}), 'listener:query')
      ctx.effect(() => () => {}, 'policy:max_results') // the label without the deed
      ctx.effect(() => openHandle(world, 'search-index'), 'handle:search-index')
      setPolicy(world, 'search.max_results', MAX_RESULTS) // untracked
      ctx.provide('index', { version: 0, lookup: q => `dis(${q})` })
    },
  }
}

// --- CASE B: activation fails after installing part of itself --------------

export function failsPartway(world) {
  return {
    name: 'search-capability-fails-partway',
    apply(ctx) {
      ctx.effect(() => registerTool(world, 'search', q => `partial:${q}`), 'tool:search')
      ctx.effect(() => subscribe(world, 'query', () => {}), 'listener:query')
      ctx.effect(() => openHandle(world, 'search-index'), 'handle:search-index')
      throw new Error('index format unrecognised')
    },
  }
}

// --- CASE D: a consumer whose teardown NEEDS the coeffect it is losing -----
//
// The discriminating case. Closing a connection pool hands its connections back,
// so the teardown has to run while the provider's binding is still resolvable.
// A disposer stack alone cannot order this.

export function poolProvider(world, { registerProvideLast = false } = {}) {
  return {
    name: 'pool-provider',
    provide: ['pool'],
    apply(ctx) {
      const provide = () =>
        ctx.provide('pool', {
          handBack: n => trace(world, `pool received ${n} connections back`),
        })
      // Registering the provision LAST makes LIFO and the guard disagree: pure
      // LIFO would revert it FIRST, before this component's own body and long
      // before any consumer had torn down.
      if (!registerProvideLast) provide()
      ctx.effect(() => {
        trace(world, 'provider body up')
        return () => trace(world, 'provider body inverse')
      }, 'provider:body')
      if (registerProvideLast) provide()
    },
  }
}

export function poolConsumer(world) {
  return {
    name: 'pool-consumer',
    inject: ['pool'],
    apply(ctx) {
      ctx.effect(() => {
        trace(world, 'consumer up')
        return () => {
          const visible = !!ctx.pool
          trace(world, `consumer teardown; pool binding visible=${visible}`)
          try {
            ctx.pool.handBack(3)
          } catch (error) {
            trace(world, `consumer teardown FAILED to hand back: ${error.constructor.name}`)
          }
        }
      }, 'consumer:body')
    },
  }
}

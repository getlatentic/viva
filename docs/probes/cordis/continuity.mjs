// What a promoted component's ACCUMULATED STATE costs at replacement.
//
// S7.3 is explicit, and against DSU and Erlang/OTP: Cordis "reverts the old
// component's tracked effects and reapplies the new component's from a clean
// slate, so a component's own in-memory state does not survive a reload unless
// placed in a longer-lived dependency", with forward migration named as future
// work. What it buys instead is complete retraction and the ability to unload a
// component entirely rather than only update one in place.
//
// This matters to vivarium more than to a plugin host, because vivarium's whole
// premise is accumulated live state -- so the escape hatch is measured, not just
// the loss. Two arms, one variable: where the state lives.
//
//   LOCAL       the component holds its own cache
//   DEPENDENCY  the same cache lives in a longer-lived provider the component
//               injects, which is the hatch S7.3 names

import { Context } from 'cordis'

const settle = () => new Promise(resolve => setTimeout(resolve, 30))

export async function caseStateContinuity() {
  return {
    case: 'H',
    title: 'accumulated state across replacement',
    local: await replaceWithState('local'),
    dependency: await replaceWithState('dependency'),
  }
}

async function replaceWithState(placement) {
  const ctx = new Context()
  const observed = []

  // The longer-lived dependency. Loaded once, outlives both versions of the
  // component that uses it, and is never itself replaced.
  if (placement === 'dependency') {
    await ctx.plugin({
      name: 'index-store',
      provide: ['store'],
      apply(ctx) {
        ctx.provide('store', { entries: [] })
      },
    })
  }

  const capability = version => ({
    name: `indexer-v${version}`,
    inject: placement === 'dependency' ? ['store'] : [],
    apply(ctx) {
      const local = { entries: [] }
      const cache = placement === 'dependency' ? ctx.store : local
      observed.push({ version, entries_on_activation: cache.entries.length })
      ctx.effect(() => {
        // The work the component did while it was live: an index it built up
        // and would have to rebuild if it were lost.
        cache.entries.push(`indexed-by-v${version}`)
        return () => {}
      }, 'index:build')
    },
  })

  const v1 = await ctx.plugin(capability(1))
  await settle()
  await v1.dispose()
  await ctx.plugin(capability(2))
  await settle()

  const v2 = observed.find(o => o.version === 2)
  return {
    placement,
    observed,
    state_survived_replacement: v2.entries_on_activation > 0,
    work_v2_had_to_redo: v2.entries_on_activation === 0 ? 'the whole index' : 'none',
  }
}

// STAGE 1 -- where the actual Cordis boundary lies.
//
// Measured against Cordis as it exists, with no vivarium machinery layered on
// top. Reconciliation belongs to stage 2 and is deliberately absent here: a
// checker run against a runtime whose own guarantees have not been characterised
// reports on the checker, not on the composition.
//
// Cases A and C are the CONTROLS. Without them a failure in B or D cannot be
// told from a probe that never worked.

import { Context } from 'cordis'
import {
  failsPartway, poolConsumer, poolProvider, searchCapability,
} from './components.mjs'
import { createWorld, difference, snapshot, trace } from './world.mjs'

const STATE = ['PENDING', 'LOADING', 'ACTIVE', 'FAILED', 'DISPOSED', 'UNLOADING']
const named = fiber => STATE[fiber.state]
const settle = () => new Promise(resolve => setTimeout(resolve, 30))

// --- A. CLEAN UNLOAD (control) ---------------------------------------------

export async function caseCleanUnload() {
  const world = createWorld()
  const ctx = new Context()
  const before = snapshot(world)

  const fiber = await ctx.plugin(searchCapability(world))
  const installed = snapshot(world)
  const toolWorked = world.tools.get('search')?.('lisp')
  const serviceWorked = ctx.index?.lookup('lisp')
  const registryWhileActive = ctx.registry.size

  await fiber.dispose()
  await settle()
  const after = snapshot(world)

  return {
    case: 'A',
    title: 'clean unload',
    installed,
    operated: { tool: toolWorked, service: serviceWorked },
    state: named(fiber),
    residue_inside_boundary: difference(before, after),
    outside_boundary: world.emitted,
    service_binding_after: ctx.index === undefined ? 'withdrawn' : 'STILL BOUND',
    registry: { while_active: registryWhileActive, after_unload: ctx.registry.size },
  }
}

// --- B. PARTIAL ACTIVATION FAILURE -----------------------------------------
//
// Predicted by L-Raise (S4.3.4, p38): the fiber routes into Unloading carrying
// the error, the accumulator applies, and it arrives Inactive "having installed
// nothing". Three further predictions the paper makes and vivarium has no
// equivalent for: the failure is recorded PER FIBER so siblings keep running;
// the lifecycle is not re-entered from an error outcome, so the component is
// withheld rather than retried against an unchanged environment; and a failed
// fiber obstructs nothing.

export async function casePartialFailure() {
  const world = createWorld()
  const ctx = new Context()
  const before = snapshot(world)

  let siblingAlive = false
  const sibling = await ctx.plugin({
    name: 'sibling',
    apply(ctx) {
      ctx.effect(() => {
        siblingAlive = true
        return () => (siblingAlive = false)
      }, 'sibling:body')
    },
  })

  // Held without awaiting: awaiting a failed activation rejects, and the fiber
  // object is what carries the outcome.
  const fiber = ctx.plugin(failsPartway(world))
  const rejection = await Promise.resolve(fiber).then(() => null, error => error.message)
  await settle()

  const afterFailure = snapshot(world)

  // Does anything re-enter the lifecycle? Poke the context and look again.
  await ctx.plugin({ name: 'poke', apply() {} })
  await settle()

  return {
    case: 'B',
    title: 'partial activation failure',
    state: named(fiber),
    rejected_with: rejection,
    effects_retained: fiber.getEffects(),
    residue_inside_boundary: difference(before, afterFailure),
    sibling: { state: named(sibling), alive: siblingAlive },
    retried_after_poke: named(fiber) !== 'FAILED',
    registry_still_holds_plugin: ctx.registry.size,
  }
}

// --- C. REPLACEMENT (control) ----------------------------------------------
//
// S6.2 distinguishes exclusive binding, where switching implementations
// "momentarily perturb[s] every consumer's dependency", from a service broker
// that "absorbs this perturbation". Which one an agent-generated replacement
// gets is a design choice vivarium would have to make too, so both are measured.

export async function caseReplacement() {
  return {
    case: 'C',
    title: 'replacement',
    exclusive: await replaceUnderExclusiveBinding(),
    broker: await replaceBehindBroker(),
  }
}

function countingConsumer(counters, key) {
  return {
    name: `consumer-of-${key}`,
    inject: [key],
    apply(ctx) {
      ctx.effect(() => {
        counters.activations++
        const seen = ctx[key]
        counters.versions.push(seen.version ?? seen.current?.().version)
        return () => counters.teardowns++
      }, 'consumer:body')
    },
  }
}

async function replaceUnderExclusiveBinding() {
  const world = createWorld()
  const ctx = new Context()
  const counters = { activations: 0, teardowns: 0, versions: [] }

  const v1 = await ctx.plugin(searchCapability(world, { version: 1 }))
  await ctx.plugin(countingConsumer(counters, 'index'))
  await settle()

  await v1.dispose()
  await ctx.plugin(searchCapability(world, { version: 2 }))
  await settle()

  return {
    consumer_activations: counters.activations,
    consumer_teardowns: counters.teardowns,
    versions_seen: counters.versions,
    tool_after_replacement: world.tools.get('search')?.('lisp'),
  }
}

async function replaceBehindBroker() {
  const world = createWorld()
  const ctx = new Context()
  const counters = { activations: 0, teardowns: 0, versions: [] }
  const backings = new Map()

  // The broker is the injected key. Backing providers register into it, so
  // replacing one leaves the consumer's dependency untouched.
  await ctx.plugin({
    name: 'index-broker',
    provide: ['index'],
    apply(ctx) {
      ctx.provide('index', {
        current: () => [...backings.values()].at(-1),
        register(impl) {
          backings.set(impl.version, impl)
          return () => backings.delete(impl.version)
        },
      })
    },
  })

  const backing = version => ({
    name: `index-backing-v${version}`,
    inject: ['index'],
    apply(ctx) {
      ctx.effect(() => ctx.index.register({ version, lookup: q => `v${version}(${q})` }), 'backing')
      trace(world, `backing v${version} registered`)
    },
  })

  const b1 = await ctx.plugin(backing(1))
  await ctx.plugin(countingConsumer(counters, 'index'))
  await settle()

  await b1.dispose()
  await ctx.plugin(backing(2))
  await settle()

  return {
    consumer_activations: counters.activations,
    consumer_teardowns: counters.teardowns,
    versions_seen: counters.versions,
    version_now_served: [...backings.keys()],
  }
}

// --- D. DEPENDENCY WITHDRAWAL ----------------------------------------------
//
// S5.1.3: a provider that has entered UNLOADING has stopped providing, so
// dependents "recompute an unsatisfied target view and begin their own teardown
// while its bindings are all still in place", and the guard of Theorem 63 holds
// the withdrawal back "until every consumer that resolves it to n has gone".
//
// THE DISCRIMINATING CONTROL is registerProvideLast. Registered last, pure LIFO
// would revert the provision FIRST -- before the provider's own body, and long
// before any consumer tore down. If the consumer's teardown still resolves the
// binding, the ordering came from the guard and not from a disposer stack.

export async function caseDependencyWithdrawal() {
  return {
    case: 'D',
    title: 'dependency withdrawal',
    provide_first: await withdrawProvider({ registerProvideLast: false }),
    provide_last: await withdrawProvider({ registerProvideLast: true }),
    parent_child: await parentChildOrdering(),
  }
}

// The limit of the guarantee, and the paper states it plainly (p35): "the guard
// orders deactivations along coeffects and not along the fiber tree: a parent
// may run its inverse while a child of it is still Unloading, since relied
// speaks only of committed views. Parent and child are accordingly ordered more
// weakly than Theorem 63 orders a provider and its consumer."
//
// So the same shape that is ordered correctly through a coeffect key is NOT
// ordered when the dependency is a parent-held resource the child merely closes
// over. Measured because an agent writing its own components will reach for
// whichever is convenient, and only one of the two is protected.

async function parentChildOrdering() {
  const world = createWorld()
  const ctx = new Context()

  const child = {
    name: 'child',
    apply(ctx) {
      ctx.effect(() => () => {
        const handle = world.handles.get('parent-resource')
        trace(world, `child teardown; parent resource open=${handle?.open}`)
      }, 'child:body')
    },
  }

  const parent = {
    name: 'parent',
    apply(ctx) {
      ctx.effect(() => {
        world.handles.set('parent-resource', { open: true })
        return () => {
          world.handles.get('parent-resource').open = false
          trace(world, 'parent resource closed')
        }
      }, 'parent:resource')
      ctx.plugin(child)
    },
  }

  const fiber = await ctx.plugin(parent)
  await settle()
  await fiber.dispose()
  await settle()

  const childSawItOpen = world.log.some(l => l.includes('parent resource open=true'))
  return {
    order: world.log,
    child_teardown_saw_resource_open: childSawItOpen,
    ordered_like_a_coeffect: childSawItOpen,
  }
}

async function withdrawProvider({ registerProvideLast }) {
  const world = createWorld()
  const ctx = new Context()

  const provider = await ctx.plugin(poolProvider(world, { registerProvideLast }))
  const consumer = await ctx.plugin(poolConsumer(world))
  await settle()

  await provider.dispose()
  await settle()
  const afterWithdrawal = { provider: named(provider), consumer: named(consumer) }

  // Reactive coeffects: a re-provided key should re-satisfy the standing
  // consumer rather than leaving it dead.
  await ctx.plugin(poolProvider(world, { registerProvideLast: false }))
  await settle()

  return {
    registered_provide_last: registerProvideLast,
    order: world.log,
    after_withdrawal: afterWithdrawal,
    consumer_after_reprovision: named(consumer),
    teardown_resolved_binding: world.log.some(l => l.includes('pool binding visible=true')),
    handed_back: world.log.some(l => l.includes('received 3 connections back')),
  }
}

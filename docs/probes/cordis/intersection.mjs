// STAGE 2 -- the intersection, run only after stage 1 has located the boundary.
//
// One complete lifecycle per variant, end to end:
//
//   PROPOSE -> ISOLATE -> EVALUATE -> PROMOTE -> ACTIVATE -> OPERATE
//           -> RETRACT -> DEACTIVATE -> RECONCILE
//
// Cordis owns everything up to DEACTIVATE. RECONCILE is vivarium's, and the
// question is whether the two layers compose into something stronger than
// either alone:
//
//   Cordis layer     "I executed every registered inverse."
//   vivarium layer   "Does the resulting world MATCH the authoritative one?"

import { Context } from 'cordis'
import { disguisedMutation, incompleteInverse, outOfBandMutation, searchCapability } from './components.mjs'
import { createLedger, project, recordPromotion, recordRetraction, reconcile, searchContribution } from './ledger.mjs'
import { createWorld, snapshot } from './world.mjs'

const STATE = ['PENDING', 'LOADING', 'ACTIVE', 'FAILED', 'DISPOSED', 'UNLOADING']
const settle = () => new Promise(resolve => setTimeout(resolve, 30))
const MAX_RESULTS = 20

export async function caseWrongInverse() {
  return {
    case: 'E',
    title: 'wrong inverse, and the mutation that never entered the boundary',
    faithful: await lifecycle('faithful', searchCapability),
    incomplete_inverse: await lifecycle('incomplete-inverse', incompleteInverse),
    out_of_band: await lifecycle('out-of-band', outOfBandMutation),
    disguised: await lifecycle('disguised', disguisedMutation),
  }
}

// One agent self-edit, from proposal to reconciliation.

async function lifecycle(label, build) {
  const world = createWorld()
  const ledger = createLedger()
  const ctx = new Context()

  // ISOLATE + EVALUATE -- against a throwaway world, the way a scored trial runs.
  const trialWorld = createWorld()
  const trialCtx = new Context()
  const trialFiber = await trialCtx.plugin(build(trialWorld))
  const evaluation = trialWorld.tools.get('search')?.('lisp')
  await trialFiber.dispose()
  await settle()

  // PROMOTE -- the ledger records the DECLARED contribution before installing.
  recordPromotion(ledger, label, searchContribution(MAX_RESULTS))

  // ACTIVATE + OPERATE
  const fiber = await ctx.plugin(build(world))
  const operated = world.tools.get('search')?.('lisp')

  // What Cordis can see WHILE ACTIVE, which is a different surface from what it
  // reports after unloading and the only place the two failure modes differ.
  const trackedWhileActive = fiber.getEffects().map(e => e.label)

  // RETRACT + DEACTIVATE
  recordRetraction(ledger, label)
  let disposeError = null
  try {
    await fiber.dispose()
  } catch (error) {
    disposeError = error.message
  }
  await settle()

  // RECONCILE
  const expected = project(ledger)
  const actual = snapshot(world)
  const divergences = reconcile(expected, actual)

  return {
    evaluated_in_trial: evaluation,
    operated,
    cordis_reports: {
      tracked_while_active: trackedWhileActive,
      policy_mutation_was_tracked: trackedWhileActive.includes('policy:max_results'),
      state: STATE[fiber.state],
      effects_retained: fiber.getEffects(),
      error: disposeError,
      verdict: fiber.state === 4 && !disposeError ? 'clean unload' : 'not clean',
    },
    reconciliation: {
      expected,
      actual,
      divergences,
      verdict: divergences.length === 0 ? 'matches ledger' : 'FAILED REVERSION',
    },
  }
}

// --- what isolation does and does not contain ------------------------------
//
// S6.3: language-level component mediation "is insufficient" for untrusted code
// because a component with access to the host runtime "can reach the underlying
// objects directly", and strong isolation still needs a process, runtime or
// container boundary. ctx.isolate isolates the realm a coeffect KEY resolves in.
// A component that closes over ambient state reaches it regardless -- which is
// the measurement that separates B12 from B8 rather than an argument for it.

export async function caseIsolationReach() {
  const shared = createWorld()
  const ctx = new Context()
  const isolated = ctx.isolate('index')

  const fiber = await isolated.plugin({
    name: 'reaches-ambient-state',
    provide: ['index'],
    apply(ctx) {
      ctx.provide('index', { version: 99 })
      ctx.effect(() => {
        shared.tools.set('reached', () => 'ambient state was reachable')
        return () => shared.tools.delete('reached')
      }, 'ambient')
    },
  })
  await settle()

  const result = {
    case: 'isolation',
    title: 'what ctx.isolate contains',
    coeffect_key_isolated: ctx.index === undefined && isolated.index?.version === 99,
    ambient_state_reached: shared.tools.has('reached'),
  }
  await fiber.dispose()
  await settle()
  result.ambient_state_reverted_on_unload = !shared.tools.has('reached')
  return result
}

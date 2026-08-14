// B12 driver. Stage 1 locates the Cordis boundary; stage 2 runs the
// intersection against it. The order is load-bearing and not a presentation
// choice: reconciliation layered on a runtime whose own guarantees have not
// been characterised measures vivarium's checker, not the composition.

import { caseCleanUnload, caseDependencyWithdrawal, casePartialFailure, caseReplacement } from './boundary.mjs'
import { caseStateContinuity } from './continuity.mjs'
import { caseIsolationReach, caseWrongInverse } from './intersection.mjs'

const results = { stage1_boundary: {}, stage2_intersection: {} }

results.stage1_boundary.A = await caseCleanUnload()
results.stage1_boundary.B = await casePartialFailure()
results.stage1_boundary.C = await caseReplacement()
results.stage1_boundary.D = await caseDependencyWithdrawal()
results.stage1_boundary.H = await caseStateContinuity()

results.stage2_intersection.E = await caseWrongInverse()
results.stage2_intersection.isolation = await caseIsolationReach()

console.log(JSON.stringify(results, null, 2))

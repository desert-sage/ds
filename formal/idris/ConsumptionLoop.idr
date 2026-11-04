-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The fire phase of the consumption loop ([RARC.5.6.6]), stated over the
||| engine model of Rete/FireLoop.idr.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
|||
||| WHY THIS LANE AND NOT ANOTHER. Alloy proves structure, TLA+ behaviour, K
||| dynamic semantics, SAW bit-exact C equivalence, CBMC bounded C properties.
||| None of them has a totality checker, and the property [RARC.5.6.6] asserts
||| is TERMINATION.
|||
||| THE CLAUSE, in full: "The conflict resolver fires activations, one at a
||| time, until the agenda is empty or a firing limit is reached; each fire
||| records a `RuleFired` event inline."
|||
||| That is a disjunction. `iret_11_4__run` is the loop it describes: one
||| firing per step (`iret_11_4__step`), fuel for the limit, and `Quiescent`
||| or `FuelOut` for which disjunct stopped it. Proven here about that loop:
|||
|||   * the limit is a limit: a run fires at most `fuel` times
|||     (`rtct_7_1__fires_within_cap`);
|||   * the halt reason is honest: a run reporting `Quiescent` stopped in a
|||     state with no pending activation (`rarc_5_6_6__quiescent_means_no_step`),
|||     so a loop cannot exit on its counter and report that it drained.
|||
||| WHAT THE CLAUSE LEAVES OPEN, and where the corpus now answers it:
|||
|||   * "a firing limit" is defined nowhere in [RARC]. The only one in the
|||     corpus is `max_fires_per_pump` in the OPTIONAL realtime contract
|||     ([RTCT.7.1]); the fuel here is that cap. Without a contract the limit
|||     disjunct does not exist, and libds was measured enforcing it nowhere —
|||     `budget_ns=0` runs a cascade to completion. Hence `verdict: "partial"` on the [RARC.5.6.6] and
|||     [RTCT.7.1] ties: the mechanism is sound and unused.
|||   * "the agenda is empty" is not guaranteed to arrive. When this module
|||     was first written nothing in the corpus bounded a rule whose RHS
|||     re-triggers its own LHS, and the unbounded loop could not be written
|||     under `%default total` at all. [LCYC.1.1] now bounds it: a program
|||     certified under [LCYC.3.1.1] quiesces (`lcyc_1_1__certified_terminates`,
|||     Lcyc/Termination.idr), and Lcyc/Witnesses.idr exhibits programs outside
|||     the certificate that never do. The first disjunct holds under the
|||     certificate and fails without it.
|||
||| Earlier versions carried their own agenda, activation and pump under
||| [RARC.5.6.5]; those duplicated Rete/FireLoop.idr's model of the same
||| clause and were retired in favour of stating the properties over the
||| engine the rest of the lane proves things about.
module ConsumptionLoop

import Rete.FireLoop
import Data.Nat

%default total

--@spec [RARC.5.6.6]
||| The fire phase, as the engine model runs it: one firing per step, the
||| limit as fuel, and which of the clause's two conditions stopped it. The
||| fire count comes out of the same recursion as the run, so it cannot drift
||| from the loop it counts.
public export
rarc_5_6_6__fire_phase : Lcyc_3_2_1__program -> (fuel : Nat) -> Rarc_5_6_5__state ->
                         (Rarc_5_6_5__state, Iret_11_4__halt, Nat)
rarc_5_6_6__fire_phase = iret_11_4__run

--@derives [RARC.5.6.6]
||| The halt reason is honest: a run that reports `Quiescent` stopped in a
||| state with no pending activation, so a loop cannot exit on its counter and
||| report that it drained.
export
rarc_5_6_6__quiescent_means_no_step : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st : Rarc_5_6_5__state) ->
  fst (snd (iret_11_4__run p fuel st)) = Quiescent ->
  iret_11_4__step p (fst (iret_11_4__run p fuel st)) = Nothing
rarc_5_6_6__quiescent_means_no_step p Z st = absurd
rarc_5_6_6__quiescent_means_no_step p (S fuel) st with (iret_11_4__step p st) proof eq
  rarc_5_6_6__quiescent_means_no_step p (S fuel) st | Nothing = \_ => eq
  rarc_5_6_6__quiescent_means_no_step p (S fuel) st | (Just st') with (iret_11_4__run p fuel st') proof eq2
    rarc_5_6_6__quiescent_means_no_step p (S fuel) st | (Just st') | (s, h, n) =
      replace {p = \r => fst (snd r) = Quiescent -> iret_11_4__step p (fst r) = Nothing}
              eq2 (rarc_5_6_6__quiescent_means_no_step p fuel st')

--@derives [RTCT.7.1]
||| THE CAP IS A CAP: a bounded run fires at most `fuel` times.
|||
||| [RTCT.7.1] enforces `max_fires_per_pump` at "the pump fire loop", breaching
||| when `fires this pump + 1 > max_fires_per_pump`. This is the property that
||| makes such a cap meaningful — that the loop cannot outrun it — and it is
||| what [RARC.5.6.6]'s undefined "firing limit" would mean if the corpus
||| defined it. Proving it here is what connects the two documents: the thing
||| RARC calls a firing limit is the thing RTCT caps.
|||
||| WHAT THIS DOES NOT ESTABLISH, and the distinction is the whole reason the
||| tie carries `verdict: "partial"`: that any implementation ENFORCES the cap.
||| This is a theorem about a loop written with fuel. libds was measured
||| enforcing it nowhere, so the mechanism is sound and unused, which is
||| a different failure from the mechanism being wrong.
export
rtct_7_1__fires_within_cap : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st : Rarc_5_6_5__state) ->
  LTE (snd (snd (iret_11_4__run p fuel st))) fuel
rtct_7_1__fires_within_cap p Z st = LTEZero
rtct_7_1__fires_within_cap p (S fuel) st with (iret_11_4__step p st)
  rtct_7_1__fires_within_cap p (S fuel) st | Nothing = LTEZero
  rtct_7_1__fires_within_cap p (S fuel) st | (Just st') with (iret_11_4__run p fuel st') proof eq
    rtct_7_1__fires_within_cap p (S fuel) st | (Just st') | (s, h, n) =
      LTESucc (replace {p = \r => LTE (snd (snd r)) fuel} eq (rtct_7_1__fires_within_cap p fuel st'))

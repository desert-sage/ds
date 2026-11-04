-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Contract-cap enforcement, and the one cap that reads the host rather than
||| the program ([RTCT.7.1], [RTCT.7.3]).
|||
||| `Replay.idr` refuted [RARC.5.6.10]'s IMPLICATION — loop determinism does not
||| give byte-identical replay, because the stream carries values the loop did
||| not compute. This module attacks the same clause's ANTECEDENT from the other
||| side: there is an engine OUTPUT that is not a function of the replayed state
||| at all.
|||
||| [RTCT.7.1] tabulates twelve caps, each with an enforcement point and a
||| breach condition. Eleven read logical state:
|||
|||     wm_max            live fact count + 1 > wm_max
|||     agenda_cap        activations queued + 1 > agenda_cap
|||     token_pool_cap    live tokens + 1 > token_pool_cap
|||     intern_bytes_cap  interned bytes + N > intern_bytes_cap
|||
||| The same observed count against the same cap gives the same answer, every
||| time. The twelfth reads something else:
|||
|||     pump_wcet_ns      observed pump elapsed ns > pump_wcet_ns
|||
||| [RTCT.7.3] is candid about the mechanism — measured at pump completion,
||| "The engine cannot interrupt a pump mid-execution" — and the consequence:
||| A BREACH IS AN OUTPUT THAT DEPENDS ON HOW FAST THE MACHINE WAS. Same rules,
||| same fact stream, slower host, different answer. The clause now says so
||| itself: this cap "reads a measurement, and it is the only one of the twelve
||| that does", and "no clause promises that two live runs agree on this cap".
|||
||| Nor is the breach advisory: [RTCT.7.3] halts the tier, with
||| `DS_ERR_CONTRACT_WCET_HALT` out of the pump that breached, and whether the
||| caller sees that halt depends on machine speed.
|||
||| WHAT IS PROVEN HERE. Both decisions are given the SAME observation — the
||| logical count the row names and the wall-clock time the pump took — and the
||| two theorems say which half each reads. The eleven logical caps are a function
||| of the count alone: two observations with one count and any two elapsed
||| times decide alike (`rtct_7_1__logical_breach_is_replay_stable`). The
||| `pump_wcet_ns` decision is not: two observations with one count and two
||| elapsed times decide differently (`rtct_7_3__wcet_breach_varies_with_the_host`).
||| Stated over one type so the difference is a property the corpus carries
||| rather than an observation somebody made once. The first theorem used to be
||| written as `f x = f x`; it now says what it meant — the
||| decision ignores the host — and a definition that read `elapsedNs` would
||| fail it.
|||
||| WHAT IS NOT CLAIMED, since this module once claimed it. That [RTCT.7.3] is
||| false. Machine speed decides what a LIVE run does; it does not reach into a
||| recorded stream, and [LDET.1.1] scopes the determinism guarantee to the
||| stream. Two hosts produce two streams, each an honest record of its run.
|||
||| WHAT IT DOES COST, which is not nothing. `BNDS` is a compare-class atom, so
||| a verify replayer RE-DERIVES a recorded breach and byte-compares it — and
||| the theorem below is exactly the statement that this one cannot be
||| re-derived. So a stream recording a `pump_wcet_ns` breach is not
||| verify-replayable, and [LFST.9.2.1] carries that as a precondition rather
||| than leaving a replayer to discover it as a Divergence.
module CapBreach

%default total

--@spec [RTCT.7.1]
||| What a cap check can see at its enforcement point: the logical count the
||| row names, and the wall-clock time the pump took ([RTCT.7.3]). Eleven rows of
||| the table read the first field; one reads the second. Giving both decisions
||| the whole observation is what lets the theorems below say which field each
||| one is a function of.
record Rtct_7_1__observation where
  constructor MkObservation
  count     : Nat
  elapsedNs : Nat

--@spec [RTCT.7.1]
||| A cap decision that reads only LOGICAL state: the count the enforcement
||| point observes, against the declared cap. `wm_max`, `agenda_cap`,
||| `token_pool_cap`, `intern_cap`, `intern_bytes_cap`, the per-node and
||| per-series capacities, a slot's declared `capacity`, `cache_cap`,
||| `cache_bytes_cap` and `max_fires_per_pump` are all this shape.
rtct_7_1__logical_breach : Rtct_7_1__observation -> (cap : Nat) -> Bool
rtct_7_1__logical_breach o cap = count o > cap

--@derives [RTCT.7.1]
||| The eleven logical caps are REPLAY-STABLE: two observations with the same
||| count decide alike whatever the host measured, because the decision is a
||| function of the count and of nothing else. A definition that read
||| `elapsedNs` would fail this statement; the one above discharges it by
||| rewriting the count.
|||
||| This is the baseline the twelfth cap fails to meet, and without it written
||| down the failure below looks like a property no cap has.
rtct_7_1__logical_breach_is_replay_stable :
  (o1, o2 : Rtct_7_1__observation) -> (cap : Nat) ->
  count o1 = count o2 ->
  rtct_7_1__logical_breach o1 cap = rtct_7_1__logical_breach o2 cap
rtct_7_1__logical_breach_is_replay_stable o1 o2 cap same =
  cong (\c => c > cap) same

--@spec [RTCT.7.3]
||| The `pump_wcet_ns` decision. What it reads is not logical state: it is the
||| wall-clock time the pump took, measured at completion ([RTCT.7.3]).
rtct_7_3__wcet_breach : Rtct_7_1__observation -> (cap : Nat) -> Bool
rtct_7_3__wcet_breach o cap = elapsedNs o > cap

--@derives [RTCT.7.3]
||| The `pump_wcet_ns` decision varies with the HOST: two runs against one
||| contract can disagree about whether the cap was breached.
|||
||| The logical state is identical by construction — the same `count` appears
||| in both observations, universally quantified, which is the point. Only
||| `elapsedNs` differs, and `elapsedNs` is a property of the machine rather
||| than of the program. A host under load breaches; the same run on an idle
||| host does not.
|||
||| [RTCT.7.3]'s halt is what makes this an OUTPUT rather than a diagnostic:
||| the breaching pump returns `DS_ERR_CONTRACT_WCET_HALT` and the tier halts,
||| or it does not, and which one the caller sees is decided by machine speed.
|||
||| WHAT THIS IS NOT. It is not a refutation of [RTCT.7.3]. The two runs here are two LIVE runs, so they
||| produce two DIFFERENT streams — one recording a breach and one not — and
||| [LDET.1.1] scopes the determinism guarantee to the fact stream rather than
||| to live reality. What the refutation attacked was a property the corpus
||| never granted.
|||
||| WHAT IT IS, restated for the replayer. Read with `BNDS` compare-class
||| ([RFCS.3.4]), this theorem says a recorded `pump_wcet_ns` breach cannot be
||| re-derived — which is why [LFST.9.2.1] makes "no recorded `pump_wcet_ns`
||| breach" a verify-replay precondition. The lemma is the reason that
||| precondition exists, not a finding against the clause.
rtct_7_3__wcet_breach_varies_with_the_host :
  (n : Nat) ->
  Not (rtct_7_3__wcet_breach (MkObservation n 5) 3 =
       rtct_7_3__wcet_breach (MkObservation n 1) 3)
rtct_7_3__wcet_breach_varies_with_the_host n Refl impossible

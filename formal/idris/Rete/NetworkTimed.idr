-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TIME-DEPENDENT `where` ON THE IDRIS MODEL'S ENGINE: `dwell` and a
||| positive pattern's `within` as join tests over the entry stamps,
||| re-evaluated at the pump's sample, under the rate gate ([LTIM.2.4.1],
||| [LTIM.2.4.2], [LTIM.2.4.3], [LTIM.2.5.1], [LTIM.2.5.3], [LTIM.2.5.4],
||| [LTIM.2.6.1], [LTIM.2.7.1], [LTIM.2.7.2], [LTIM.2.8.2], [LTIM.2.8.4],
||| [LTIM.2.8.6], [LEXP.9.5.1], [LCDB.3.2.3], [RLOW.5.4], [IRET.19.5],
||| [RDSC.4a.8.2.1] to [RDSC.4a.8.2.3]).
|||
||| NORMATIVE COMPANION to Rete/NetworkCooldown.idr, whose gated firing this
||| file stamps and whose gated pump it re-times, and to
||| Rete/NetworkTwoClocks.idr, whose sampled state it runs on the Idris model's
||| engine and whose `within` and `dwell` gates it computes from a lowered
||| `where`.
|||
||| WHAT IS MODELLED. Beside the gated state of Rete/NetworkCooldown.idr the
||| WALL SAMPLE and the ENTRY STAMPS ([LTIM.2.8.6]) of Rete/NetworkTwoClocks.idr's
||| sampled net. A `where` is Rete/Eval.idr's expression, now with a CLOCK
||| LEAF (`EClock`: `now()`, `monotonic_ns()`, `t.dwell`); under a sample and
||| the stamp table every leaf is SUBSTITUTED by its literal
||| (`ltim_2_4_1__at_sample`) before the plain evaluator runs, so the
||| evaluator reads no clock ([LTIM.2.8.4]) and a `where` with no leaf is
||| evaluated as it was (`ltim_2_4_1__clock_free_unchanged`). `t.dwell` is
||| the monotonic sample less the fact's stamp ([LEXP.9.5.1],
||| `ltim_2_4_1__read_at`); a fact with no stamp reads `null`, which no
||| positive node admits, as Rete/NetworkTwoClocks.idr's gates fail it; a
||| pattern's `within d` is the lowering's `dwell < d` ([RLOW.5.4]). A
||| rule's TIMED TEST (`ltim_2_4_1__test_of`) is the substituted `where` as a
||| function of the stamps and the sample, given per rule by ordinal as the
||| cooldowns are; a rule with none runs as it did. THE STAMPED RHS
||| (`rarc_5_6_7__do_actions_stamped`) is Rete/NetworkTtl.idr's action fold
||| with the stamp table updated at every mint beside the deadline table,
||| through Rete/EntryStamp.idr's assert at the net's clock with the fresh id
||| the deadline stamp uses: a fact a pump mints is stamped with the held
||| sample ([IRET.19.1] step 4), so a timed rule over an emitted kind is
||| modelled and not refused. THE GATED FIRING (`ltim_2_5_4__fire_timed`)
||| is Rete/NetworkCooldown.idr's -- select, mark, the gate at the clock --
||| with the stamped RHS; the rate gate is evaluated only for an activation
||| the sample admitted, which is [LTIM.2.5.4]'s conjunction and
||| [RDSC.4a.8.2.3]'s "whose condition was true", by construction: an
||| activation exists only where the re-timed test holds. A TICK is
||| Rete/NetworkTtl.idr's prepare (the clock takes the sample, the sweep runs
||| where Rete/TtlSweep.idr's header says); a DATA INPUT is that prepare with the
||| stamps as Rete/NetworkTwoClocks.idr's `ltim_2_8_4__apply_sampled` has
||| them, at the held sample; neither moves a tracker, and neither re-times.
||| A PUMP re-times every timed chain at the held sample over the stamps as
||| they then stand -- Rete/NetworkClocked.idr's re-time stage with its
||| cascade, [IRET.19.5] steps 1 to 3 -- then runs the gated stamped fold
||| (step 4). Between two pumps the engine re-evaluates once, at the pump:
||| [LTIM.2.4.2]'s "every engine tick (each pump)", and what libds does; a
||| tick that advances and a tick that samples at a data input are one
||| sample to the next pump. (An engine that re-timed at every input would
||| agree on every cadence the Idris model runs, a tick then a pump, and
||| differ only where two ticks precede one pump and a gate closes and
||| reopens between them, a case no clause's cycle has and no fixture
||| drives.)
|||
||| THE READING WHERE THE MODEL AND THE COMPILER PART. The compiler moves a
||| timed `where` into the terminal's fire guard, read at selection under the
||| pump's sample ([RDSC.4a.8.2.1], [RDSC.4a.8.2.2]); this model keeps it as
||| the single positive node's join test ([LTIM.2.6.1]), re-timed at the
||| pump. At every pump boundary the two agree: a condition false at the
||| sample is no activation here and a withheld activation there; neither
||| fires or counts ([RDSC.4a.8.2.2]), and the justification of an ended match
||| is dropped on both ([LTIM.2.7.2]). The RDSC.4a.8.2.1 and .2 ties are
||| `partial` for the mechanism.
|||
||| PROVED, each over every program, state, test list and tracker table.
|||
|||   * THE LEAVES. `dwell` is the sample less the stamp, TwoClocks.idr's
|||     `lexp_9_5_1__dwell` ([LEXP.9.5.1], `lexp_9_5_1__dwell_leaf`: a
|||     transcription, said so); a leaf that reads no wall sample is
|||     substituted alike at two wall samples (`ltim_2_8_2__subst_ignores_wall`),
|||     so the timed test of a `where` with no `now()` is a MONOTONIC GATE of
|||     Rete/NetworkTwoClocks.idr (`ltim_2_8_2__test_of_monotonic`), which is
|||     [LTIM.2.8.2]'s "reads the monotonic clock and no other" for `dwell` and
|||     `within` as lowered; and a `where` with no leaf is unchanged by the
|||     substitution (`ltim_2_4_1__clock_free_unchanged`).
|||   * THE PROJECTION. Dropping the stamps and the wall, the stamped RHS is
|||     Rete/NetworkTtl.idr's (`rarc_5_6_7__do_actions_stamped_net`), the gated
|||     stamped RHS is Rete/NetworkCooldown.idr's (`ltim_2_5_4__rhs_gated_drops`),
|||     the firing is its firing (`ltim_2_5_4__fire_timed_projects`), and the
|||     run after the entry re-time is its gated run, state, halt and trace
|||     (`ltim_2_4_2__run_timed_projects`); a tick and a data input are its
|||     prepare (`ltim_2_8_4__tick_timed_projects`,
|||     `ltim_2_8_6__input_timed_projects`).
|||   * THE FRAME. With no timed rule the entry re-time is the cascade alone,
|||     the identity on a state between actions (`ltim_2_4_1__tick_untimed`,
|||     `ltim_2_4_3__entry_retime_untimed`), so the timed pump's net, trackers,
|||     halt and trace are Rete/NetworkCooldown.idr's gated pump's from the
|||     same net and trackers (`ltim_2_4_1__no_timed_rule_is_the_gated_pump`),
|||     the stamps beside. Every fixture the Idris model compared before this rung
|||     runs through the timed engine, and its agreement holds by this
|||     theorem and Rete/NetworkCooldown.idr's; the eighteen smoke pairs
|||     stay byte for byte.
|||   * A TICK THEN A PUMP IS THE CLOCKED PUMP: with no rule cooled, the net
|||     a tick and the pump after it leave is Rete/NetworkClocked.idr's
|||     `iret_19_5__pump_clocked` at the tick with the tests fixed at the wall
|||     sample over the stamps (`ltim_2_4_3__tick_then_pump_is_clocked`), which
|||     is Rete/NetworkTwoClocks.idr's `ltim_2_8_4__pump_sampled` -- so C2 (the
|||     wall clock moves no monotonic gate), C3a (a rising gate fires at most
|||     once) and Rete/NetworkEdges.idr's B2 (the counts are the edges) hold
|||     of this engine's tick-then-pump cycle by instantiation, with the tests
|||     this file builds in place of the gates those files take.
|||   * THE GATE UNDER THE CONDITION ([LTIM.2.5.4], [RDSC.4a.8.2.3]): the
|||     selection is of the re-timed chains, so a firing exists only for a
|||     match the sample admits; an admitted firing runs the stamped RHS and
|||     stamps the key at the clock, a refused one marks the activation and
|||     nothing else (`ltim_2_5_4__allowed_is_the_stamped_firing`,
|||     `ltim_2_5_4__suppressed_runs_no_action`), Rete/NetworkCooldown.idr's
|||     two lemmas on this engine.
|||   * EXECUTED, `Refl` through the loader, the stamps and the gated pump,
|||     the fixtures' shapes: [LCDB.3.2.3]'s on-delay fires once at the first
|||     pump whose sample reaches T and never again, and a retract before T
|||     fires nothing; a `within` justifying a logical emit fires once when
|||     it opens and the fact is retracted at the pump whose sample closes it
|||     ([LTIM.2.7.2], [LTIM.2.5.1]); under a cooldown a second maturity
|||     inside the window is gated and the match does not refire past it
|||     ([LTIM.2.4.2], [LTIM.2.5.4]); a `null` need withholds while an untimed
|||     rule fires ([RDSC.4a.8.2.2]); a `dwell` window that shuts and reopens
|||     fires once per opening ([LTIM.2.5.1]); a condition true at the assert
|||     fires on the next pump if it still holds there and not if the pump's
|||     sample refuses it ([LTIM.2.5.3]).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. That the stamps cover
||| every live fact: the stamp update reads Rete/FireLoop.idr's assert on the
||| network's working memory, which decides as the network's assert decides
||| (`rlow_4_2_1__assert_agree`, the transfer); the invariant is not stated
||| here. The value of a lowered comparison on Integer literals is run, not
||| proved: `within d` as `dwell < d` answers Rete/NetworkTwoClocks.idr's
||| `ltim_2_7_1__within_at` on the executed shapes, and the evaluator's
||| Integer order does not reduce on variables. The wall sample is held and
||| moved by nothing in this half of the rung (`now()` is R4b's). One timed
||| test per single-positive-pattern chain, as Rete/NetworkTick.idr has it
||| ([LTIM.2.6.1]); the lowering refuses any other shape. The sweep's
||| placement is Rete/TtlSweep.idr's. The edge-once set of [IRET.11.3.5] is the
||| `fired` flag here. A series or zone read is outside the fragment.
module Rete.NetworkTimed

-- The imports are Rete/NetworkCooldown.idr's whole: a run evaluated in a
-- witness unfolds only through modules the file imports.
import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkCorollaries
import Rete.NetworkAgree
import Rete.NetworkTransferTable
import Rete.NetworkTransferAgree
import Rete.NetworkTransfer
import Rete.NetworkTmsCascade
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTraced
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkTwoClocks
import Rete.NetworkCooldown
import Rete.EntryStamp
import Rete.Eval
import Rete.RunFold
import Rete.RateGate
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import TwoClocks
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The clock leaf under a sample [LTIM.2.4.1], [LEXP.9.5.1], [LTIM.2.8.4]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LEXP.9.5.1]
--@spec [LTIM.2.8.6]
||| A CLOCK READ UNDER A SAMPLE: `now()` the wall sample, `monotonic_ns()`
||| the monotonic one, `t.dwell` the monotonic sample less the entry stamp
||| of the `b`-th fact of the extended token ([LEXP.9.5.1], TwoClocks.idr's
||| `lexp_9_5_1__dwell`). A fact the token does not hold, or one with no
||| stamp, reads `null`: the header's residue.
public export
ltim_2_4_1__read_at : Ltim_2_8_1__sample -> Ltim_2_8_6__stamps -> List Lfac_1_7_1__fact -> Ltim_2_4_1__read -> Lnul_2_1__value
ltim_2_4_1__read_at sm st fs ReadNow        = VInt (cast (snd sm))
ltim_2_4_1__read_at sm st fs ReadMono       = VInt (cast (fst sm))
ltim_2_4_1__read_at sm st fs (ReadDwell b)  = case rarc_5_6_5__nth b fs of
  Nothing => VNull
  Just f  => case ltim_2_8_6__stamp_of (fid f) st of
    Nothing => VNull
    Just s  => VInt (cast (lexp_9_5_1__dwell sm s))

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.8.4]
||| THE SUBSTITUTION: every clock leaf replaced by its literal under the
||| sample and the stamps, the rest of the expression as it is. Every read
||| between two samples returns the sample ([LTIM.2.8.4]), and the plain
||| evaluator then reads no clock.
public export
ltim_2_4_1__at_sample : Ltim_2_8_1__sample -> Ltim_2_8_6__stamps -> List Lfac_1_7_1__fact -> Iret_7_5__expr -> Iret_7_5__expr
ltim_2_4_1__at_sample sm st fs (ELit v)         = ELit v
ltim_2_4_1__at_sample sm st fs (ESlot b k s)    = ESlot b k s
ltim_2_4_1__at_sample sm st fs (EClock r)       = ELit (ltim_2_4_1__read_at sm st fs r)
ltim_2_4_1__at_sample sm st fs (ECmp op l r)    = ECmp op (ltim_2_4_1__at_sample sm st fs l) (ltim_2_4_1__at_sample sm st fs r)
ltim_2_4_1__at_sample sm st fs (EArith op l r)  = EArith op (ltim_2_4_1__at_sample sm st fs l) (ltim_2_4_1__at_sample sm st fs r)
ltim_2_4_1__at_sample sm st fs (ENeg e)         = ENeg (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (EAnd l r)       = EAnd (ltim_2_4_1__at_sample sm st fs l) (ltim_2_4_1__at_sample sm st fs r)
ltim_2_4_1__at_sample sm st fs (EOr l r)        = EOr (ltim_2_4_1__at_sample sm st fs l) (ltim_2_4_1__at_sample sm st fs r)
ltim_2_4_1__at_sample sm st fs (ENot e)         = ENot (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (EIs neg s e)    = EIs neg s (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (ECoalesce x d)  = ECoalesce (ltim_2_4_1__at_sample sm st fs x) (ltim_2_4_1__at_sample sm st fs d)
ltim_2_4_1__at_sample sm st fs (ECast f t e)    = ECast f t (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (EPath segs e)   = EPath segs (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (EHas segs e)    = EHas segs (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (ELen e)         = ELen (ltim_2_4_1__at_sample sm st fs e)
ltim_2_4_1__at_sample sm st fs (ELenStr e)      = ELenStr (ltim_2_4_1__at_sample sm st fs e)

--@spec [LTIM.2.4.1]
--@spec [LEXP.9.5.3]
||| WHETHER A `where` READS A CLOCK: the clause's criterion for a
||| time-dependent condition, read off the expression. A leaf anywhere in
||| it makes the condition time-dependent; a `dwell` leaf does, since it
||| reads `monotonic_ns()` ([LEXP.9.5.3]).
public export
ltim_2_4_1__reads_clock : Iret_7_5__expr -> Bool
ltim_2_4_1__reads_clock (ELit v)         = False
ltim_2_4_1__reads_clock (ESlot b k s)    = False
ltim_2_4_1__reads_clock (EClock r)       = True
ltim_2_4_1__reads_clock (ECmp op l r)    = ltim_2_4_1__reads_clock l || ltim_2_4_1__reads_clock r
ltim_2_4_1__reads_clock (EArith op l r)  = ltim_2_4_1__reads_clock l || ltim_2_4_1__reads_clock r
ltim_2_4_1__reads_clock (ENeg e)         = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (EAnd l r)       = ltim_2_4_1__reads_clock l || ltim_2_4_1__reads_clock r
ltim_2_4_1__reads_clock (EOr l r)        = ltim_2_4_1__reads_clock l || ltim_2_4_1__reads_clock r
ltim_2_4_1__reads_clock (ENot e)         = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (EIs neg s e)    = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (ECoalesce x d)  = ltim_2_4_1__reads_clock x || ltim_2_4_1__reads_clock d
ltim_2_4_1__reads_clock (ECast f t e)    = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (EPath segs e)   = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (EHas segs e)    = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (ELen e)         = ltim_2_4_1__reads_clock e
ltim_2_4_1__reads_clock (ELenStr e)      = ltim_2_4_1__reads_clock e

--@spec [LTIM.2.8.2]
--@spec [LTIM.2.8.3]
||| WHETHER A `where` READS THE WALL CLOCK: a `now()` leaf anywhere in it.
||| `dwell` and `within` read the monotonic clock and no other
||| ([LTIM.2.8.2]); only `now()` observes the wall ([LTIM.2.8.3]).
public export
ltim_2_8_2__reads_wall : Iret_7_5__expr -> Bool
ltim_2_8_2__reads_wall (ELit v)         = False
ltim_2_8_2__reads_wall (ESlot b k s)    = False
ltim_2_8_2__reads_wall (EClock ReadNow) = True
ltim_2_8_2__reads_wall (EClock ReadMono) = False
ltim_2_8_2__reads_wall (EClock (ReadDwell b)) = False
ltim_2_8_2__reads_wall (ECmp op l r)    = ltim_2_8_2__reads_wall l || ltim_2_8_2__reads_wall r
ltim_2_8_2__reads_wall (EArith op l r)  = ltim_2_8_2__reads_wall l || ltim_2_8_2__reads_wall r
ltim_2_8_2__reads_wall (ENeg e)         = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (EAnd l r)       = ltim_2_8_2__reads_wall l || ltim_2_8_2__reads_wall r
ltim_2_8_2__reads_wall (EOr l r)        = ltim_2_8_2__reads_wall l || ltim_2_8_2__reads_wall r
ltim_2_8_2__reads_wall (ENot e)         = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (EIs neg s e)    = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (ECoalesce x d)  = ltim_2_8_2__reads_wall x || ltim_2_8_2__reads_wall d
ltim_2_8_2__reads_wall (ECast f t e)    = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (EPath segs e)   = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (EHas segs e)    = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (ELen e)         = ltim_2_8_2__reads_wall e
ltim_2_8_2__reads_wall (ELenStr e)      = ltim_2_8_2__reads_wall e

--@derives [LTIM.2.4.1]
||| A Bool disjunction false on both sides.
export
ltim_2_4_1__or_false : (a, b : Bool) -> (a || b) = False -> (a = False, b = False)
ltim_2_4_1__or_false False False h = (Refl, Refl)
ltim_2_4_1__or_false False True h = absurd h
ltim_2_4_1__or_false True b h = absurd h

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.8.4]
||| A `where` THAT READS NO CLOCK IS UNCHANGED by the substitution, under
||| every sample, stamp table and token: every untimed test of the Idris model
||| is evaluated as it was before this rung.
export
ltim_2_4_1__clock_free_unchanged : (sm : Ltim_2_8_1__sample) -> (st : Ltim_2_8_6__stamps) -> (fs : List Lfac_1_7_1__fact) -> (e : Iret_7_5__expr) ->
                                    ltim_2_4_1__reads_clock e = False -> ltim_2_4_1__at_sample sm st fs e = e
ltim_2_4_1__clock_free_unchanged sm st fs (ELit v) h = Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ESlot b k s) h = Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EClock r) h = absurd h
ltim_2_4_1__clock_free_unchanged sm st fs (ECmp op l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in rewrite ltim_2_4_1__clock_free_unchanged sm st fs l hl in rewrite ltim_2_4_1__clock_free_unchanged sm st fs r hr in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EArith op l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in rewrite ltim_2_4_1__clock_free_unchanged sm st fs l hl in rewrite ltim_2_4_1__clock_free_unchanged sm st fs r hr in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ENeg e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EAnd l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in rewrite ltim_2_4_1__clock_free_unchanged sm st fs l hl in rewrite ltim_2_4_1__clock_free_unchanged sm st fs r hr in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EOr l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in rewrite ltim_2_4_1__clock_free_unchanged sm st fs l hl in rewrite ltim_2_4_1__clock_free_unchanged sm st fs r hr in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ENot e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EIs neg s e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ECoalesce x d) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in rewrite ltim_2_4_1__clock_free_unchanged sm st fs x hl in rewrite ltim_2_4_1__clock_free_unchanged sm st fs d hr in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ECast f t e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EPath segs e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (EHas segs e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ELen e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl
ltim_2_4_1__clock_free_unchanged sm st fs (ELenStr e) h = rewrite ltim_2_4_1__clock_free_unchanged sm st fs e h in Refl

--@derives [LEXP.9.5.1]
--@derives [LTIM.2.8.6]
||| THE `dwell` LEAF IS THE SAMPLE LESS THE STAMP: for a fact the token
||| holds and the table stamps, `t.dwell` reads TwoClocks.idr's
||| `lexp_9_5_1__dwell` at the sample and that stamp. A TRANSCRIPTION of
||| `ltim_2_4_1__read_at`'s third clause, said so: it fails if the leaf is
||| changed to read a slot or the wall and refutes nothing else.
export
lexp_9_5_1__dwell_leaf : (sm : Ltim_2_8_1__sample) -> (st : Ltim_2_8_6__stamps) -> (fs : List Lfac_1_7_1__fact) -> (b : Nat) ->
                         (f : Lfac_1_7_1__fact) -> (s : Nat) ->
                         rarc_5_6_5__nth b fs = Just f -> ltim_2_8_6__stamp_of (fid f) st = Just s ->
                         ltim_2_4_1__at_sample sm st fs (EClock (ReadDwell b)) = ELit (VInt (cast (lexp_9_5_1__dwell sm s)))
lexp_9_5_1__dwell_leaf sm st fs b f s nf ns = rewrite nf in rewrite ns in Refl

--@derives [LTIM.2.8.2]
||| A LEAF THAT READS NO WALL SAMPLE IS SUBSTITUTED ALIKE AT TWO WALL
||| SAMPLES: `monotonic_ns()` and `dwell` read the monotonic component and
||| the stamps, and nothing of the wall.
export
ltim_2_8_2__read_ignores_wall : (m, w, w' : Nat) -> (st : Ltim_2_8_6__stamps) -> (fs : List Lfac_1_7_1__fact) -> (r : Ltim_2_4_1__read) ->
                                ltim_2_8_2__reads_wall (EClock r) = False ->
                                ltim_2_4_1__read_at (m, w) st fs r = ltim_2_4_1__read_at (m, w') st fs r
ltim_2_8_2__read_ignores_wall m w w' st fs ReadNow h = absurd h
ltim_2_8_2__read_ignores_wall m w w' st fs ReadMono h = Refl
ltim_2_8_2__read_ignores_wall m w w' st fs (ReadDwell b) h with (rarc_5_6_5__nth b fs)
  ltim_2_8_2__read_ignores_wall m w w' st fs (ReadDwell b) h | Nothing = Refl
  ltim_2_8_2__read_ignores_wall m w w' st fs (ReadDwell b) h | (Just f) with (ltim_2_8_6__stamp_of (fid f) st)
    ltim_2_8_2__read_ignores_wall m w w' st fs (ReadDwell b) h | (Just f) | Nothing = Refl
    ltim_2_8_2__read_ignores_wall m w w' st fs (ReadDwell b) h | (Just f) | (Just s) = Refl

--@derives [LTIM.2.8.2]
||| AND SO IS A `where` WITH NO `now()`: substituted at `(m, w)` and at
||| `(m, w')` it is one expression. By induction on the expression.
export
ltim_2_8_2__subst_ignores_wall : (m, w, w' : Nat) -> (st : Ltim_2_8_6__stamps) -> (fs : List Lfac_1_7_1__fact) -> (e : Iret_7_5__expr) ->
                                 ltim_2_8_2__reads_wall e = False ->
                                 ltim_2_4_1__at_sample (m, w) st fs e = ltim_2_4_1__at_sample (m, w') st fs e
ltim_2_8_2__subst_ignores_wall m w w' st fs (ELit v) h = Refl
ltim_2_8_2__subst_ignores_wall m w w' st fs (ESlot b k s) h = Refl
ltim_2_8_2__subst_ignores_wall m w w' st fs (EClock r) h = cong ELit (ltim_2_8_2__read_ignores_wall m w w' st fs r h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ECmp op l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in cong2 (ECmp op) (ltim_2_8_2__subst_ignores_wall m w w' st fs l hl) (ltim_2_8_2__subst_ignores_wall m w w' st fs r hr)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EArith op l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in cong2 (EArith op) (ltim_2_8_2__subst_ignores_wall m w w' st fs l hl) (ltim_2_8_2__subst_ignores_wall m w w' st fs r hr)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ENeg e) h = cong ENeg (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EAnd l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in cong2 EAnd (ltim_2_8_2__subst_ignores_wall m w w' st fs l hl) (ltim_2_8_2__subst_ignores_wall m w w' st fs r hr)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EOr l r) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in cong2 EOr (ltim_2_8_2__subst_ignores_wall m w w' st fs l hl) (ltim_2_8_2__subst_ignores_wall m w w' st fs r hr)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ENot e) h = cong ENot (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EIs neg s e) h = cong (EIs neg s) (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ECoalesce x d) h =
  let (hl, hr) = ltim_2_4_1__or_false _ _ h
  in cong2 ECoalesce (ltim_2_8_2__subst_ignores_wall m w w' st fs x hl) (ltim_2_8_2__subst_ignores_wall m w w' st fs d hr)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ECast f t e) h = cong (ECast f t) (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EPath segs e) h = cong (EPath segs) (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (EHas segs e) h = cong (EHas segs) (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ELen e) h = cong ELen (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)
ltim_2_8_2__subst_ignores_wall m w w' st fs (ELenStr e) h = cong ELenStr (ltim_2_8_2__subst_ignores_wall m w w' st fs e h)

-- ---------------------------------------------------------------------
-- The timed test of a `where` [LTIM.2.4.1], [LTIM.2.6.1], [IRET.7.6]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.8.4]
||| A TIMED TEST: a two-clock test of Rete/NetworkTwoClocks.idr read from
||| the stamp table. What a time-dependent `where` is to the engine: a
||| function of the stamps and the sample, with the facts fixed.
public export
Ltim_2_4_1__ttest : Type
Ltim_2_4_1__ttest = Ltim_2_8_6__stamps -> Ltim_2_8_4__timed

--@spec [LTIM.2.4.1]
--@spec [IRET.7.6]
--@spec [LNUL.4.3]
||| THE TIMED TEST OF A `where`: under the stamps and the sample, the
||| substituted expression evaluated over the token and the candidate by
||| Rete/Eval.idr, admitting on `true` ([LNUL.4.3]) -- the positive node's
||| join relation, re-timed.
public export
ltim_2_4_1__test_of : Iret_7_6__env -> Iret_7_5__expr -> Ltim_2_4_1__ttest
ltim_2_4_1__test_of env e = \st, sm, tok, f => iret_7_6__admits_join env (ltim_2_4_1__at_sample sm st (tok ++ [f]) e) tok f

--@spec [LTIM.2.8.2]
--@spec [LTIM.2.4.1]
||| THE MONOTONIC TIMED TEST OF A `where`: the test read at the monotonic
||| sample with the wall fixed at zero -- what the runner builds for a
||| `where` with no `now()`, so that it is a monotonic gate of
||| Rete/NetworkTwoClocks.idr BY CONSTRUCTION, as that module's `dwell` and
||| `within` gates are, and C2 instantiates on it.
public export
ltim_2_8_2__mono_test_of : Iret_7_6__env -> Iret_7_5__expr -> Ltim_2_4_1__ttest
ltim_2_8_2__mono_test_of env e st = \sm => ltim_2_4_1__test_of env e st (fst sm, 0)

--@derives [LTIM.2.8.2]
||| THE MONOTONIC TIMED TEST IS A MONOTONIC GATE: at one monotonic sample
||| it is one function of the pair, whatever the wall. A TRANSCRIPTION by
||| construction on the monotonic component, as Rete/NetworkTwoClocks.idr's
||| `ltim_2_7_1__within_gate_monotonic` is; it fails if the test is changed
||| to read the wall and refutes nothing else.
export
ltim_2_8_2__mono_test_of_monotonic : (env : Iret_7_6__env) -> (e : Iret_7_5__expr) -> (st : Ltim_2_8_6__stamps) ->
                                     Ltim_2_8_2__monotonic (ltim_2_8_2__mono_test_of env e st)
ltim_2_8_2__mono_test_of_monotonic env e st m w w' = Refl

--@derives [LTIM.2.8.2]
||| AND IT IS THE TIMED TEST, PAIR BY PAIR, for a `where` with no `now()`:
||| at every sample, every token and every candidate the two answer alike,
||| since a leaf that reads no wall sample is substituted alike at any
||| wall. (Stated pointwise: two join functions that agree on every pair are
||| not identified by the checker without extensionality, which is why the
||| runner builds the monotonic form and does not derive it.)
export
ltim_2_8_2__mono_test_of_agrees : (env : Iret_7_6__env) -> (e : Iret_7_5__expr) -> (st : Ltim_2_8_6__stamps) -> ltim_2_8_2__reads_wall e = False ->
                                  (sm : Ltim_2_8_1__sample) -> (tok : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                                  ltim_2_8_2__mono_test_of env e st sm tok f = ltim_2_4_1__test_of env e st sm tok f
ltim_2_8_2__mono_test_of_agrees env e st h (m, w) tok f =
  cong (\x => iret_7_6__admits_join env x tok f) (ltim_2_8_2__subst_ignores_wall m 0 w st (tok ++ [f]) e h)

-- ---------------------------------------------------------------------
-- The tests of a program, by ordinal
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.6.1]
||| THE TIMED TESTS OF A PROGRAM, by rule ordinal: a test for a rule whose
||| single positive pattern carries a time-dependent `where`, none for any
||| other. What the lowering builds and Rete/NetworkClocked.idr's tick
||| takes, fixed at a wall sample over a stamp table.
public export
ltim_2_4_1__tests_fn : List (Maybe Ltim_2_4_1__ttest) -> Ltim_2_8_6__stamps -> List (Maybe Ltim_2_8_4__timed)
ltim_2_4_1__tests_fn tests st = map (map (\tt => tt st)) tests

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.6.1]
--@spec [LTIM.2.8.4]
||| The tests fixed at a wall sample over the stamps: Rete/NetworkTwoClocks.idr's
||| `ltim_2_8_4__tests_at` at the program's tests.
public export
ltim_2_4_1__tests_at : Nat -> Ltim_2_8_6__stamps -> List (Maybe Ltim_2_4_1__ttest) -> List (Maybe Ltim_2_4_1__timed)
ltim_2_4_1__tests_at w st tests = ltim_2_8_4__tests_at w st (ltim_2_4_1__tests_fn tests)

--@spec [LTIM.2.4.1]
||| No rule timed: the frame theorem's hypothesis.
public export
ltim_2_4_1__untimed : List (Maybe Ltim_2_4_1__ttest) -> Bool
ltim_2_4_1__untimed [] = True
ltim_2_4_1__untimed (Nothing :: ts) = ltim_2_4_1__untimed ts
ltim_2_4_1__untimed (Just _ :: ts) = False

-- ---------------------------------------------------------------------
-- The state, and the stamped RHS [LTIM.2.8.6], [IRET.19.1]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LTIM.2.8.6]
||| THE TIMED STATE: Rete/NetworkTwoClocks.idr's sampled net -- the clocked
||| net, the wall sample, the entry stamps -- with Rete/NetworkCooldown.idr's
||| trackers beside it. What the Idris model runs on.
public export
Ltim_2_4_1__timed_state : Type
Ltim_2_4_1__timed_state = (Ltim_2_8_1__sampled_net, Iret_10_4__trackers)

--@spec [LTIM.2.4.1]
||| The clocked net of a timed state. By projections, so that it reduces on
||| a state that is not yet a pair.
public export
ltim_2_4_1__net_of : Ltim_2_4_1__timed_state -> Iret_19_3__clocked_net
ltim_2_4_1__net_of x = snet (fst x)

--@spec [LTIM.2.4.1]
||| The gated state under a timed state: the stamps and the wall dropped.
||| By projections, so that it reduces on a state that is not yet a pair.
public export
ltim_2_4_1__proj : Ltim_2_4_1__timed_state -> Lcdb_3_2_1__gated_state
ltim_2_4_1__proj x = (ltim_2_4_1__net_of x, snd x)

--@spec [LTIM.2.8.6]
--@spec [IRET.19.1]
||| WHAT ONE RHS ACTION DOES TO THE STAMPS: an emit stamps the fact it mints
||| with the clock, through Rete/EntryStamp.idr's assert under the kind's
||| lifecycle with the fresh id the deadline stamp uses (the token's ids
||| avoided, as Rete/NetworkTtl.idr's `iret_4_3__record_action_net`); a
||| suppressed no-op keeps every stamp, a replace restamps. A withdraw
||| stamps nothing: the rows of what it retracts go at the next restamp.
public export
ltim_2_8_6__record_action : Lcyc_3_2_1__program -> Nat -> Iret_8_1__act -> Lgra_10_1__action -> Rarc_5_6_4__wm -> Ltim_2_8_6__stamps -> Ltim_2_8_6__stamps
ltim_2_8_6__record_action pg now a (Withdraw _) wm st = st
ltim_2_8_6__record_action pg now a (Emit k value) wm st =
  ltim_2_8_6__assert_stamps (life pg k) (iret_11_3__fact_ids (atuple a)) k (fst (value (atuple a))) (snd (value (atuple a))) now wm st

--@spec [RARC.5.6.7]
--@spec [LTIM.2.8.6]
||| ONE ACTION, STAMPED: Rete/NetworkTtl.idr's action on the net, and the
||| stamps updated at the net's clock over the working memory the action
||| read.
public export
rarc_5_6_7__do_action_stamped : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> Lgra_10_1__action ->
                                (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> (Iret_19_3__clocked_net, Ltim_2_8_6__stamps)
rarc_5_6_7__do_action_stamped pg ttl r a act (cs, st) =
  (rarc_5_6_7__do_action_ttl_net pg ttl r a act cs, ltim_2_8_6__record_action pg (nclock cs) a act (ewm (ncore (nengine cs))) st)

--@spec [RARC.5.6.7]
--@spec [LTIM.2.8.6]
||| THE RHS, STAMPED, action by action.
public export
rarc_5_6_7__do_actions_stamped : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> List Lgra_10_1__action ->
                                 (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> (Iret_19_3__clocked_net, Ltim_2_8_6__stamps)
rarc_5_6_7__do_actions_stamped pg ttl r a [] x = x
rarc_5_6_7__do_actions_stamped pg ttl r a (act :: acts) x = rarc_5_6_7__do_actions_stamped pg ttl r a acts (rarc_5_6_7__do_action_stamped pg ttl r a act x)

--@derives [RARC.5.6.7]
||| THE STAMPED RHS'S NET IS Rete/NetworkTtl.idr's: the stamps ride beside
||| and change nothing the actions compute.
export
rarc_5_6_7__do_actions_stamped_net : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (a : Iret_8_1__act) -> (acts : List Lgra_10_1__action) ->
                                     (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) ->
                                     fst (rarc_5_6_7__do_actions_stamped pg ttl r a acts (cs, st)) = rarc_5_6_7__do_actions_ttl_net pg ttl r a acts cs
rarc_5_6_7__do_actions_stamped_net pg ttl r a [] cs st = Refl
rarc_5_6_7__do_actions_stamped_net pg ttl r a (act :: acts) cs st with (rarc_5_6_7__do_action_ttl_net pg ttl r a act cs)
  rarc_5_6_7__do_actions_stamped_net pg ttl r a (act :: acts) cs st | (MkClockedNet s dl c) =
    rarc_5_6_7__do_actions_stamped_net pg ttl r a acts (MkClockedNet s dl c) (ltim_2_8_6__record_action pg (nclock cs) a act (ewm (ncore (nengine cs))) st)

-- ---------------------------------------------------------------------
-- The gated firing with stamps [LTIM.2.5.4], [RDSC.4a.8.2.3]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.4]
--@spec [LCDB.3.2.1.1]
--@spec [LTIM.2.8.6]
||| THE STAMPED RHS UNDER A VERDICT: admitted, the actions run and stamp on
||| the marked net; refused, the marked net and the stamps stand. The
||| trackers are the verdict's.
public export
ltim_2_5_4__run_if : (Bool, Iret_10_4__trackers) -> Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> List Lgra_10_1__action ->
                     (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> (Bool, ((Iret_19_3__clocked_net, Ltim_2_8_6__stamps), Iret_10_4__trackers))
ltim_2_5_4__run_if (True, trk)  pg ttl r a acts x = (True, (rarc_5_6_7__do_actions_stamped pg ttl r a acts x, trk))
ltim_2_5_4__run_if (False, trk) pg ttl r a acts x = (False, (x, trk))

--@spec [LTIM.2.5.4]
--@spec [RDSC.4a.8.2.3]
--@spec [LCDB.3.2.1.1]
||| THE STAMPED RHS GATED: a rule with no cooldown runs its actions with
||| the trackers untouched; otherwise Rete/NetworkCooldown.idr's gate
||| decides at the net's clock with the key of the fired match, once, and
||| the stamped RHS runs on its `true`. The maturity gate is before this:
||| the activation it fires exists only because the sample admitted it.
public export
ltim_2_5_4__rhs_gated : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Lcdb_3_2_1__cool -> Nat -> Iret_8_1__act -> List Lgra_10_1__action ->
                        Nat -> Iret_10_4__trackers -> (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) ->
                        (Bool, ((Iret_19_3__clocked_net, Ltim_2_8_6__stamps), Iret_10_4__trackers))
ltim_2_5_4__rhs_gated pg ttl Nothing r a acts c trk x = (True, (rarc_5_6_7__do_actions_stamped pg ttl r a acts x, trk))
ltim_2_5_4__rhs_gated pg ttl (Just (window, kf)) r a acts c trk x =
  ltim_2_5_4__run_if (iret_10_4__allow window c (r, kf (atuple a)) trk) pg ttl r a acts x

--@spec [LTIM.2.5.4]
||| A verdict with its stamps dropped: what Rete/NetworkCooldown.idr's RHS
||| returns. By projections, so that it reduces on a result that is not yet
||| a pair.
public export
ltim_2_5_4__drop : (Bool, ((Iret_19_3__clocked_net, Ltim_2_8_6__stamps), Iret_10_4__trackers)) -> (Bool, (Iret_19_3__clocked_net, Iret_10_4__trackers))
ltim_2_5_4__drop x = (fst x, (fst (fst (snd x)), snd (snd x)))

--@derives [LTIM.2.5.4]
--@derives [LCDB.3.2.1.1]
||| THE STAMPED RHS UNDER A VERDICT, DROPPED, IS Rete/NetworkCooldown.idr's.
export
ltim_2_5_4__run_if_drops : (d : (Bool, Iret_10_4__trackers)) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (a : Iret_8_1__act) ->
                           (acts : List Lgra_10_1__action) -> (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) ->
                           ltim_2_5_4__drop (ltim_2_5_4__run_if d pg ttl r a acts (cs, st)) = lcdb_3_2_1_1__run_if d pg ttl r a acts cs
ltim_2_5_4__run_if_drops (True, trk)  pg ttl r a acts cs st =
  cong (\n => (True, (n, trk))) (rarc_5_6_7__do_actions_stamped_net pg ttl r a acts cs st)
ltim_2_5_4__run_if_drops (False, trk) pg ttl r a acts cs st = Refl

--@derives [LTIM.2.5.4]
--@derives [RDSC.4a.8.2.3]
||| THE STAMPED RHS GATED, DROPPED, IS Rete/NetworkCooldown.idr's GATED
||| RHS: the same gate, the same verdict, the same net and trackers.
export
ltim_2_5_4__rhs_gated_drops : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (co : Lcdb_3_2_1__cool) -> (r : Nat) -> (a : Iret_8_1__act) ->
                              (acts : List Lgra_10_1__action) -> (c : Nat) -> (trk : Iret_10_4__trackers) -> (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) ->
                              ltim_2_5_4__drop (ltim_2_5_4__rhs_gated pg ttl co r a acts c trk (cs, st)) = lcdb_3_2_1_1__rhs_gated pg ttl co r a acts c trk cs
ltim_2_5_4__rhs_gated_drops pg ttl Nothing r a acts c trk cs st =
  cong (\n => (True, (n, trk))) (rarc_5_6_7__do_actions_stamped_net pg ttl r a acts cs st)
ltim_2_5_4__rhs_gated_drops pg ttl (Just (window, kf)) r a acts c trk cs st =
  ltim_2_5_4__run_if_drops (iret_10_4__allow window c (r, kf (atuple a)) trk) pg ttl r a acts cs st

--@spec [LTIM.2.5.4]
||| A firing named: the ordinal, the fired facts and the verdict, with the
||| timed state after it -- the net and the stamps the RHS left, the wall
||| sample kept. By projections, as Rete/NetworkCooldown.idr's label is.
public export
ltim_2_5_4__label : Nat -> Iret_7_1__token -> Nat -> (Bool, ((Iret_19_3__clocked_net, Ltim_2_8_6__stamps), Iret_10_4__trackers)) ->
                    Maybe ((Nat, Iret_7_1__token, Bool), Ltim_2_4_1__timed_state)
ltim_2_5_4__label r fs w x = Just ((r, fs, fst x), (MkSampled (fst (fst (snd x))) w (snd (fst (snd x))), snd (snd x)))

--@spec [LTIM.2.5.4]
||| THE FIRING AT A SELECTION, stamped: mark the activation fired, then the
||| gated stamped RHS.
public export
ltim_2_5_4__fire_at : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_19__engine -> Iret_12_4__table -> Iret_4_3__deadlines -> Nat ->
                      Nat -> Ltim_2_8_6__stamps -> Iret_10_4__trackers -> Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act) ->
                      Maybe ((Nat, Iret_7_1__token, Bool), Ltim_2_4_1__timed_state)
ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk Nothing = Nothing
ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk (Just (r, j, ch, a)) =
  ltim_2_5_4__label r (atuple a) w
    (ltim_2_5_4__rhs_gated pg ttl (lcdb_3_2_1__cool_at cools r) r a (cactions ch) c trk (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c, st))

--@spec [LTIM.2.5.4]
--@spec [RDSC.4a.8.2.3]
--@spec [LCDB.3.2.1.1]
||| THE GATED FIRING WITH STAMPS: Rete/NetworkCooldown.idr's selection and
||| mark, then the gated stamped RHS; named with its ordinal, its facts and
||| the verdict, as a firing Rete/RunFold.idr's traced fold takes.
public export
ltim_2_5_4__fire_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Ltim_2_4_1__timed_state ->
                         Maybe ((Nat, Iret_7_1__token, Bool), Ltim_2_4_1__timed_state)
ltim_2_5_4__fire_timed pg ttl cools (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk) =
  ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk (lcdb_3_2_1__selected eng)

--@spec [LTIM.2.5.4]
||| A named firing with its state projected.
public export
ltim_2_5_4__proj_firing : ((Nat, Iret_7_1__token, Bool), Ltim_2_4_1__timed_state) -> ((Nat, Iret_7_1__token, Bool), Lcdb_3_2_1__gated_state)
ltim_2_5_4__proj_firing (l, s) = (l, ltim_2_4_1__proj s)

--@derives [LTIM.2.5.4]
||| THE FIRING AT A SELECTION PROJECTS to Rete/NetworkCooldown.idr's firing
||| at the same selection.
export
ltim_2_5_4__fire_at_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                               (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) ->
                               (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) -> (m : Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act)) ->
                               map ltim_2_5_4__proj_firing (ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk m)
                                 = lcdb_3_2_1__fire_at pg ttl cools eng rows dl c trk m
ltim_2_5_4__fire_at_projects pg ttl cools eng rows dl c w st trk Nothing = Refl
ltim_2_5_4__fire_at_projects pg ttl cools eng rows dl c w st trk (Just (r, j, ch, a)) =
  cong (\z => Just ((r, atuple a, fst z), snd z))
       (ltim_2_5_4__rhs_gated_drops pg ttl (lcdb_3_2_1__cool_at cools r) r a (cactions ch) c trk (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) st)

--@derives [LTIM.2.5.4]
--@derives [RDSC.4a.8.2.3]
||| THE TIMED FIRING PROJECTS TO THE GATED FIRING: on every timed state,
||| dropping the stamps and the wall from what it fires gives
||| Rete/NetworkCooldown.idr's firing on the projected state.
export
ltim_2_5_4__fire_timed_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (s : Ltim_2_4_1__timed_state) ->
                                  map ltim_2_5_4__proj_firing (ltim_2_5_4__fire_timed pg ttl cools s) = lcdb_3_2_1__fire_gated pg ttl cools (ltim_2_4_1__proj s)
ltim_2_5_4__fire_timed_projects pg ttl cools (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk) =
  ltim_2_5_4__fire_at_projects pg ttl cools eng rows dl c w st trk (lcdb_3_2_1__selected eng)

--@derives [LTIM.2.5.4]
--@derives [LCDB.3.2.1.1]
||| AN ADMITTED FIRING IS THE STAMPED FIRING: with the gate's verdict `true`
||| on the fired match's key at the clock, the firing's net and stamps are
||| what the stamped RHS leaves on the marked net (named `n` and `st'`),
||| and the trackers gain the key at the clock. Rete/NetworkCooldown.idr's
||| `allowed_is_the_firing` with the stamps.
export
ltim_2_5_4__allowed_is_the_stamped_firing : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                            (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) ->
                                            (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
                                            (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) -> (window : Nat) -> (kf : Iret_7_1__token -> Nat) ->
                                            (n : Iret_19_3__clocked_net) -> (st' : Ltim_2_8_6__stamps) ->
                                            iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                            lcdb_3_2_1__cool_at cools r = Just (window, kf) ->
                                            rlow_4_6_2_2__allows window c (rlow_4_6_2_2__lookup trk (r, kf (atuple a))) = True ->
                                            rarc_5_6_7__do_actions_stamped pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c, st) = (n, st') ->
                                            ltim_2_5_4__fire_timed pg ttl cools (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk)
                                              = Just ((r, atuple a, True), (MkSampled n w st', ((r, kf (atuple a)), c) :: trk))
ltim_2_5_4__allowed_is_the_stamped_firing pg ttl cools eng rows dl c w st trk r j ch a window kf n st' sel nc na co ok e =
  rewrite sel in rewrite nc in rewrite na in rewrite co in rewrite ok in rewrite e in Refl

--@derives [LTIM.2.5.4]
--@derives [LCDB.3.2.1.1]
--@derives [RDSC.4a.8.2.3]
||| A REFUSED FIRING RUNS NO ACTION AND STAMPS NOTHING: with the verdict
||| `false`, the firing's net is the marked net, the stamps and the
||| trackers are the ones before. Rete/NetworkCooldown.idr's
||| `suppressed_runs_no_action` with the stamps.
export
ltim_2_5_4__suppressed_runs_no_action : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                        (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) ->
                                        (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
                                        (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) -> (window : Nat) -> (kf : Iret_7_1__token -> Nat) ->
                                        iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                        lcdb_3_2_1__cool_at cools r = Just (window, kf) ->
                                        rlow_4_6_2_2__allows window c (rlow_4_6_2_2__lookup trk (r, kf (atuple a))) = False ->
                                        ltim_2_5_4__fire_timed pg ttl cools (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk)
                                          = Just ((r, atuple a, False), (MkSampled (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) w st, trk))
ltim_2_5_4__suppressed_runs_no_action pg ttl cools eng rows dl c w st trk r j ch a window kf sel nc na co no =
  rewrite sel in rewrite nc in rewrite na in rewrite co in rewrite no in Refl

-- ---------------------------------------------------------------------
-- The pump: the re-time at entry, then the run [IRET.19.5], [LTIM.2.4.2]
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.3]
--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
--@spec [RDSC.4a.8.2.1]
--@spec [IRET.11.3.5]
||| THE RE-TIME AT THE PUMP'S ENTRY: every timed chain re-evaluated at the
||| held sample over the stamps as they stand, then the cascade for the
||| rows of the activations it ended ([LTIM.2.7.2]) --
||| Rete/NetworkClocked.idr's re-time stage, [IRET.19.5] steps 1 to 3 with
||| the sample the state holds. Re-evaluation reads the sample taken when
||| the pump began ([LTIM.2.4.3]): the state's clock and wall sample. Where
||| the compiler carries the condition in the terminal's fire guard
||| ([RDSC.4a.8.2.1]) this engine keeps it as the single positive node's
||| join test, so a match the sample refuses is no activation here and a
||| withheld one there; a match that persists is one activation, its `fired`
||| flag the edge-once set ([IRET.11.3.5]), and a test that goes
||| false ends it.
public export
ltim_2_4_3__retime_at_entry : Lcyc_3_2_1__program -> List (Maybe Ltim_2_4_1__ttest) -> Ltim_2_8_1__sampled_net -> Ltim_2_8_1__sampled_net
ltim_2_4_3__retime_at_entry pg tests (MkSampled net w st) = MkSampled (iret_19_5__retime_clocked pg (ltim_2_4_1__tests_at w st tests) net) w st

--@spec [LTIM.2.4.2]
--@spec [IRET.11.4]
||| THE RUN, TRACED: Rete/RunFold.idr's traced fold over the timed firing.
public export
ltim_2_4_2__run_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Nat -> Ltim_2_4_1__timed_state ->
                        (Ltim_2_4_1__timed_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool))
ltim_2_4_2__run_timed pg ttl cools fuel s = iret_11_4__trace_by (ltim_2_5_4__fire_timed pg ttl cools) fuel s

--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
--@spec [LTIM.2.4.3]
||| THE PUMP: the re-time at entry, then the run (step 4). A rate modifier
||| does not exempt a rule from the re-time ([LTIM.2.4.2]): the cooldowns
||| are read by the firing alone.
public export
ltim_2_4_2__pump_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> Ltim_2_4_1__timed_state ->
                         (Ltim_2_4_1__timed_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool))
ltim_2_4_2__pump_timed pg ttl cools tests fuel (s, trk) = ltim_2_4_2__run_timed pg ttl cools fuel (ltim_2_4_3__retime_at_entry pg tests s, trk)

--@spec [LTIM.2.8.4]
--@spec [RARC.5.6.3]
--@spec [IRET.19.3]
||| A TICK: the clock takes the sample and the sweep runs, as
||| Rete/NetworkTtl.idr's prepare has it; the wall sample, the stamps and
||| the trackers stand. A tick enters no fact, so it stamps nothing
||| ([LTIM.2.8.6]), and it re-times nothing: the pump does.
public export
ltim_2_8_4__tick_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Ltim_2_4_1__timed_state -> Ltim_2_4_1__timed_state
ltim_2_8_4__tick_timed pg ttl t (MkSampled net w st, trk) = (MkSampled (rarc_5_6_3__prepare_net pg ttl (Tick t) net) w st, trk)

--@spec [RARC.5.6.4]
--@spec [LTIM.2.8.6]
--@spec [LTIM.2.8.4]
||| A DATA INPUT at the held sample: swept for, applied and stamped --
||| Rete/NetworkTwoClocks.idr's `ltim_2_8_4__apply_sampled` on the swept net,
||| so the net component is Rete/NetworkTtl.idr's prepare of the event. A
||| suppressed reassertion keeps its stamp, an entered fact takes the
||| clock, a replace restamps; the trackers stand.
public export
ltim_2_8_6__input_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_1__event -> Ltim_2_4_1__timed_state -> Ltim_2_4_1__timed_state
ltim_2_8_6__input_timed pg ttl ev (MkSampled net w st, trk) = (ltim_2_8_4__apply_sampled pg ttl ev (MkSampled (rarc_5_6_3__sweep_net pg net) w st), trk)

--@spec [LTIM.2.4.1]
--@spec [RARC.5.6.1]
||| A FIXTURE'S STEPS on the timed engine, in its cadence: a tick, a data
||| input, a pump under its fuel; the verdicts of every pump, one list per
||| pump, in order.
public export
ltim_2_4_1__run_steps_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) -> List Rarc_5_6_2__step ->
                              Ltim_2_4_1__timed_state -> (Ltim_2_4_1__timed_state, List (List (Nat, Bool)))
ltim_2_4_1__run_steps_timed pg ttl cools tests [] s = (s, [])
ltim_2_4_1__run_steps_timed pg ttl cools tests (SInput (Tick t) :: ss) s =
  ltim_2_4_1__run_steps_timed pg ttl cools tests ss (ltim_2_8_4__tick_timed pg ttl t s)
ltim_2_4_1__run_steps_timed pg ttl cools tests (SInput (Data ev) :: ss) s =
  ltim_2_4_1__run_steps_timed pg ttl cools tests ss (ltim_2_8_6__input_timed pg ttl ev s)
ltim_2_4_1__run_steps_timed pg ttl cools tests (SPumpT fuel :: ss) s = case ltim_2_4_2__pump_timed pg ttl cools tests fuel s of
  (s', h, tr) => case ltim_2_4_1__run_steps_timed pg ttl cools tests ss s' of
    (s'', vs) => (s'', lcdb_3_2_1__verdicts tr :: vs)

-- ---------------------------------------------------------------------
-- The projections of the inputs and the run
-- ---------------------------------------------------------------------

--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
||| A TICK PROJECTS to Rete/NetworkCooldown.idr's prepared tick.
export
ltim_2_8_4__tick_timed_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (t : Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                  ltim_2_4_1__proj (ltim_2_8_4__tick_timed pg ttl t s) = iret_10_4__prepare_gated pg ttl (Tick t) (ltim_2_4_1__proj s)
ltim_2_8_4__tick_timed_projects pg ttl t (MkSampled net w st, trk) = Refl

--@derives [LTIM.2.8.6]
--@derives [RARC.5.6.4]
||| A DATA INPUT PROJECTS to Rete/NetworkCooldown.idr's prepared data event:
||| the stamps ride beside the sweep and the apply.
export
ltim_2_8_6__input_timed_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ev : Rarc_5_6_1__event) -> (s : Ltim_2_4_1__timed_state) ->
                                   ltim_2_4_1__proj (ltim_2_8_6__input_timed pg ttl ev s) = iret_10_4__prepare_gated pg ttl (Data ev) (ltim_2_4_1__proj s)
ltim_2_8_6__input_timed_projects pg ttl (Assert k key pay) (MkSampled net w st, trk) = Refl
ltim_2_8_6__input_timed_projects pg ttl (Retract i) (MkSampled net w st, trk) = Refl

--@derives [LTIM.2.5.4]
||| A timed firing that resolves to nothing: so does the gated firing on
||| the projected state.
export
ltim_2_5_4__fire_timed_nothing : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (s : Ltim_2_4_1__timed_state) ->
                                 ltim_2_5_4__fire_timed pg ttl cools s = Nothing -> lcdb_3_2_1__fire_gated pg ttl cools (ltim_2_4_1__proj s) = Nothing
ltim_2_5_4__fire_timed_nothing pg ttl cools s e =
  trans (sym (ltim_2_5_4__fire_timed_projects pg ttl cools s)) (cong (map ltim_2_5_4__proj_firing) e)

--@derives [LTIM.2.5.4]
||| A timed firing that names a firing: the gated firing on the projected
||| state names the same firing, with the state projected.
export
ltim_2_5_4__fire_timed_just : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (s : Ltim_2_4_1__timed_state) ->
                              (l : (Nat, Iret_7_1__token, Bool)) -> (s1 : Ltim_2_4_1__timed_state) ->
                              ltim_2_5_4__fire_timed pg ttl cools s = Just (l, s1) ->
                              lcdb_3_2_1__fire_gated pg ttl cools (ltim_2_4_1__proj s) = Just (l, ltim_2_4_1__proj s1)
ltim_2_5_4__fire_timed_just pg ttl cools s l s1 e =
  trans (sym (ltim_2_5_4__fire_timed_projects pg ttl cools s)) (cong (map ltim_2_5_4__proj_firing) e)

--@derives [LTIM.2.4.2]
--@derives [IRET.11.4]
||| THE RUN PROJECTS: the timed run's state, halt and trace, with the state
||| projected, are Rete/NetworkCooldown.idr's gated run's from the projected
||| state, for any fuel. By induction on the fuel through the firing's
||| projection.
export
ltim_2_4_2__run_timed_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (fuel : Nat) -> (s : Ltim_2_4_1__timed_state) ->
                                 (s' : Ltim_2_4_1__timed_state ** (h : Iret_11_4__halt ** (tr : List (Nat, Iret_7_1__token, Bool) **
                                   ( ltim_2_4_2__run_timed pg ttl cools fuel s = (s', h, tr)
                                   , lcdb_3_2_1__run_gated_traced pg ttl cools fuel (ltim_2_4_1__proj s) = (ltim_2_4_1__proj s', h, tr) ))))
ltim_2_4_2__run_timed_projects pg ttl cools Z s = (s ** (FuelOut ** ([] ** (Refl, Refl))))
ltim_2_4_2__run_timed_projects pg ttl cools (S fuel) s with (ltim_2_5_4__fire_timed pg ttl cools s) proof e
  ltim_2_4_2__run_timed_projects pg ttl cools (S fuel) s | Nothing =
    (s ** (Quiescent ** ([] ** ( Refl
                               , iret_11_4__trace_by_end (lcdb_3_2_1__fire_gated pg ttl cools) fuel (ltim_2_4_1__proj s)
                                   (ltim_2_5_4__fire_timed_nothing pg ttl cools s e) ))))
  ltim_2_4_2__run_timed_projects pg ttl cools (S fuel) s | (Just (l, s1)) =
    let (s' ** (h ** (tr ** (rE, gE)))) = ltim_2_4_2__run_timed_projects pg ttl cools fuel s1
    in (s' ** (h ** ((l :: tr) ** ( rewrite rE in Refl
                                  , iret_11_4__trace_by_cons (lcdb_3_2_1__fire_gated pg ttl cools) fuel (ltim_2_4_1__proj s) (ltim_2_4_1__proj s1) l (ltim_2_4_1__proj s') h tr
                                      (ltim_2_5_4__fire_timed_just pg ttl cools s l s1 e) gE ))))

-- ---------------------------------------------------------------------
-- The frame: no rule timed, the gated pump [LTIM.2.4.1]
-- ---------------------------------------------------------------------

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.6.1]
||| WITH NO RULE TIMED THE TESTS ARE NONE: the fixed list is every ordinal's
||| `Nothing`, however the wall and the stamps stand.
export
ltim_2_4_1__tests_at_untimed : (w : Nat) -> (st : Ltim_2_8_6__stamps) -> (tests : List (Maybe Ltim_2_4_1__ttest)) ->
                               ltim_2_4_1__untimed tests = True ->
                               (wm : Rarc_5_6_4__wm) -> (al : List Iret_6_1__alpha) -> (c : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                               iret_19_5__tick_chains wm al (ltim_2_4_1__tests_at w st tests) c chains = chains
ltim_2_4_1__tests_at_untimed w st [] u wm al c chains = Refl
ltim_2_4_1__tests_at_untimed w st (Nothing :: ts) u wm al c [] = Refl
ltim_2_4_1__tests_at_untimed w st (Nothing :: ts) u wm al c (ch :: chs) =
  cong (ch ::) (ltim_2_4_1__tests_at_untimed w st ts u wm al c chs)
ltim_2_4_1__tests_at_untimed w st (Just _ :: ts) u wm al c chains = absurd u

--@derives [LTIM.2.4.1]
--@derives [IRET.19.5]
||| WITH NO RULE TIMED THE RE-TIME IS THE IDENTITY on the engine: every
||| chain is left alone.
export
ltim_2_4_1__tick_untimed : (w : Nat) -> (st : Ltim_2_8_6__stamps) -> (tests : List (Maybe Ltim_2_4_1__ttest)) -> ltim_2_4_1__untimed tests = True ->
                           (c : Nat) -> (eng : Iret_19__engine) -> iret_19_5__tick (ltim_2_4_1__tests_at w st tests) c eng = eng
ltim_2_4_1__tick_untimed w st tests u c (MkEngine wm (MkNetwork al chains)) =
  cong (\chs => MkEngine wm (MkNetwork al chs)) (ltim_2_4_1__tests_at_untimed w st tests u wm al c chains)

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.4.3]
--@derives [IRET.12.2]
||| WITH NO RULE TIMED THE RE-TIME AT ENTRY IS THE CASCADE ALONE, the
||| identity on a state between actions -- one where no row has ended,
||| which every pump boundary is (Rete/TmsRun.idr's fixpoint; the cascade
||| after every action and every input reaches it).
export
ltim_2_4_3__entry_retime_untimed : (pg : Lcyc_3_2_1__program) -> (tests : List (Maybe Ltim_2_4_1__ttest)) -> ltim_2_4_1__untimed tests = True ->
                                   (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) -> (st : Ltim_2_8_6__stamps) ->
                                   iret_12_2__ended_net eng rows = [] ->
                                   ltim_2_4_3__retime_at_entry pg tests (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st)
                                     = MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st
ltim_2_4_3__entry_retime_untimed pg tests u eng rows dl c w st noEnd =
  cong (\x => MkSampled (MkClockedNet x dl c) w st)
       (trans (cong (\e => iret_12_2__phase_net pg (MkTmsNet e rows)) (ltim_2_4_1__tick_untimed w st tests u c eng))
              (iret_12_2__phase_n_net_quiet (S (length rows)) pg eng rows noEnd))

--@derives [LTIM.2.4.1]
--@derives [LTIM.2.5.4]
||| THE FRAME: with no rule timed, from a state between actions, the timed
||| pump's net, trackers, halt and trace are Rete/NetworkCooldown.idr's
||| gated pump's from the same net and trackers, the stamps and the wall
||| beside. Every fixture the Idris model compared before this rung runs through
||| the timed engine, and its agreement holds by this theorem and
||| Rete/NetworkCooldown.idr's frame rather than by a rerun.
export
ltim_2_4_1__no_timed_rule_is_the_gated_pump : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                              (tests : List (Maybe Ltim_2_4_1__ttest)) -> ltim_2_4_1__untimed tests = True -> (fuel : Nat) ->
                                              (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) ->
                                              (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
                                              iret_12_2__ended_net eng rows = [] ->
                                              (s' : Ltim_2_4_1__timed_state ** (h : Iret_11_4__halt ** (tr : List (Nat, Iret_7_1__token, Bool) **
                                                ( ltim_2_4_2__pump_timed pg ttl cools tests fuel (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk) = (s', h, tr)
                                                , lcdb_3_2_1__run_gated_traced pg ttl cools fuel (MkClockedNet (MkTmsNet eng rows) dl c, trk) = (ltim_2_4_1__proj s', h, tr) ))))
ltim_2_4_1__no_timed_rule_is_the_gated_pump pg ttl cools tests u fuel eng rows dl c w st trk noEnd =
  let (s' ** (h ** (tr ** (rE, gE)))) = ltim_2_4_2__run_timed_projects pg ttl cools fuel (MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk)
  in (s' ** (h ** (tr ** ( trans (cong (\x => ltim_2_4_2__run_timed pg ttl cools fuel (x, trk)) (ltim_2_4_3__entry_retime_untimed pg tests u eng rows dl c w st noEnd)) rE
                         , gE ))))

-- ---------------------------------------------------------------------
-- A tick then a pump is the clocked pump [IRET.19.5], [LTIM.2.8.4]
-- ---------------------------------------------------------------------

--@derives [LTIM.2.4.3]
--@derives [IRET.19.5]
--@derives [LTIM.2.8.4]
--@derives [RARC.5.6.3]
||| A TICK THEN A PUMP IS THE CLOCKED PUMP: with no rule cooled, the net the
||| tick and the pump after it leave is Rete/NetworkClocked.idr's
||| `iret_19_5__pump_clocked` at the tick with the tests fixed at the wall
||| sample over the stamps, which is Rete/NetworkTwoClocks.idr's
||| `ltim_2_8_4__pump_sampled` at the sample `(t, w)`. The re-time at entry
||| after the tick's advance and sweep is that module's composed tick, by
||| definition; the gated run with nothing cooled is the plain traced run,
||| whose state is the pump's (Rete/NetworkCooldown.idr's frame and
||| Rete/NetworkTraced.idr's `_traced_core`). What lets C2, C3a and B2 be
||| read on this engine's tick-then-pump cycle.
export
ltim_2_4_3__tick_then_pump_is_clocked : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> lcdb_3_2_1__uncooled cools = True ->
                                        (tests : List (Maybe Ltim_2_4_1__ttest)) -> (fuel, t : Nat) -> (net : Iret_19_3__clocked_net) -> (w : Nat) ->
                                        (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
                                        ltim_2_4_1__net_of (fst (ltim_2_4_2__pump_timed pg ttl cools tests fuel (ltim_2_8_4__tick_timed pg ttl t (MkSampled net w st, trk))))
                                          = fst (iret_19_5__pump_clocked pg ttl (ltim_2_4_1__tests_at w st tests) fuel (Tick t) net)
ltim_2_4_3__tick_then_pump_is_clocked pg ttl cools u tests fuel t net w st trk =
  let (s' ** (h ** (tr ** (rE, gE)))) = ltim_2_4_2__run_timed_projects pg ttl cools fuel
                                          (MkSampled (iret_19_5__tick_clocked pg ttl (ltim_2_4_1__tests_at w st tests) t net) w st, trk)
      (t2 ** (h2 ** (tr2 ** (tE, gE2)))) = lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools fuel
                                             (iret_19_5__tick_clocked pg ttl (ltim_2_4_1__tests_at w st tests) t net) trk u
      (t3 ** h3 ** tr3 ** (tE3, pE)) = iret_11_4__run_ttl_net_traced_core pg ttl fuel
                                         (iret_19_5__tick_clocked pg ttl (ltim_2_4_1__tests_at w st tests) t net)
      projEq = the (ltim_2_4_1__proj s' = (t2, trk)) (cong fst (trans (sym gE) gE2))
      tEq = the (t2 = t3) (cong fst (trans (sym tE) tE3))
  in trans (cong (\z => ltim_2_4_1__net_of (fst z)) rE)
           (trans (cong fst projEq) (trans tEq (sym (cong fst pE))))

-- ---------------------------------------------------------------------
-- Executed: the fixtures' shapes on this engine
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
||| THE WITNESSES' ENVIRONMENT: an id stands for the one-slot tuple of the
||| Int it is, except 7, which stands for `null` -- the `need` slot
||| [RDSC.4a.8.2.2]'s shape asserts `null`.
public export
ltim_2_4_1__wenv : Iret_7_6__env
ltim_2_4_1__wenv i = if i == 7 then Just [VNull] else Just [VInt (cast i)]

--@spec [LEXP.9.5.1]
||| `t.dwell` of the single positive pattern's fact: rank 0.
public export
lexp_9_5_1__dwell_of_head : Iret_7_5__expr
lexp_9_5_1__dwell_of_head = EClock (ReadDwell 0)

--@spec [LCDB.3.2.3]
||| THE ON-DELAY: `where x.dwell >= 2`, on the matched fact.
public export
lcdb_3_2_3__on_delay : Iret_7_5__expr
lcdb_3_2_3__on_delay = ECmp OpGe lexp_9_5_1__dwell_of_head (ELit (VInt 2))

--@spec [LTIM.2.7.1]
--@spec [RLOW.5.4]
||| A PATTERN'S `within 3` as the lowering writes it: `dwell < 3`.
public export
ltim_2_7_1__within_three : Iret_7_5__expr
ltim_2_7_1__within_three = ECmp OpLt lexp_9_5_1__dwell_of_head (ELit (VInt 3))

--@spec [LTIM.2.5.1]
||| A `dwell` WINDOW that shuts and reopens: `(dwell >= 2 and dwell < 4) or
||| dwell >= 6`, logical/LTIM.2.5.1_window_reopens's gate.
public export
ltim_2_5_1__dwell_window : Iret_7_5__expr
ltim_2_5_1__dwell_window = EOr (EAnd (ECmp OpGe lexp_9_5_1__dwell_of_head (ELit (VInt 2))) (ECmp OpLt lexp_9_5_1__dwell_of_head (ELit (VInt 4))))
                               (ECmp OpGe lexp_9_5_1__dwell_of_head (ELit (VInt 6)))

--@spec [RDSC.4a.8.2.2]
||| A CONDITION AGAINST A SLOT: `dwell >= m.need`, `need` the payload's one
||| slot.
public export
rdsc_4a_8_2_2__need_gate : Iret_7_5__expr
rdsc_4a_8_2_2__need_gate = ECmp OpGe lexp_9_5_1__dwell_of_head (ESlot 0 False 0)

--@spec [LTIM.2.5.3]
||| A CONDITION TRUE AT THE ASSERT: `dwell < 2`, logical/LTIM.2.5.3_true_at_assert_false_at_pump's
||| `young`.
public export
ltim_2_5_3__young : Iret_7_5__expr
ltim_2_5_3__young = ECmp OpLt lexp_9_5_1__dwell_of_head (ELit (VInt 2))

--@spec [LTIM.2.4.1]
||| ONE TIMED RULE over kind 0, action-free, its node loaded with the test
||| at the sample (0, 0) and no stamps: a fixture family.
public export
ltim_2_4_1__one_timed_rule : Iret_7_5__expr -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_4_1__one_timed_rule e = [([(0, ltim_2_4_1__test_of ltim_2_4_1__wenv e [] (0, 0), False)], [])]

--@spec [LTIM.2.4.1]
||| The one timed rule's tests, by ordinal.
public export
ltim_2_4_1__one_timed_tests : Iret_7_5__expr -> List (Maybe Ltim_2_4_1__ttest)
ltim_2_4_1__one_timed_tests e = [Just (ltim_2_4_1__test_of ltim_2_4_1__wenv e)]

--@spec [LTIM.2.4.1]
||| THE LOADED TIMED STATE of a program: no rows, no deadlines, the clock at
||| 0, the wall at 0, no stamps, no tracker.
public export
ltim_2_4_1__loaded : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Ltim_2_4_1__timed_state
ltim_2_4_1__loaded alphas rules = (MkSampled (MkClockedNet (MkTmsNet (rdsc_4a_5__load alphas rules) []) [] 0) 0 [], [])

--@spec [LTIM.2.4.1]
||| THE VERDICTS OF A SCHEDULE from the loaded network: one list per pump.
public export
ltim_2_4_1__verdicts_of : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                          List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) ->
                          List Rarc_5_6_2__step -> List (List (Nat, Bool))
ltim_2_4_1__verdicts_of life ttl alphas rules cools tests steps =
  snd (ltim_2_4_1__run_steps_timed (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl cools tests steps (ltim_2_4_1__loaded alphas rules))

--@spec [LTIM.2.4.1]
||| THE WORKING MEMORY after a schedule from the loaded network.
public export
ltim_2_4_1__wm_after : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                       List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) ->
                       List Rarc_5_6_2__step -> Rarc_5_6_4__wm
ltim_2_4_1__wm_after life ttl alphas rules cools tests steps =
  ewm (ncore (nengine (ltim_2_4_1__net_of (fst (ltim_2_4_1__run_steps_timed (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl cools tests steps (ltim_2_4_1__loaded alphas rules))))))

--@derives [LCDB.3.2.3]
--@derives [LTIM.2.4.2]
--@derives [LTIM.2.5.1]
||| THE ON-DELAY FIRES ONCE, AT THE FIRST PUMP WHOSE SAMPLE REACHES T, AND
||| NEVER AGAIN: a Motion asserted at 0 under `dwell >= 2`; the pump at 0
||| fires nothing, the pump at 3 fires, the pump at 6 does not --
||| logical/LCDB.3.2.3_dwell_on_delay's shape. Executed: `[[], [(0, True)], []]`.
export
lcdb_3_2_3__on_delay_fires_once :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule lcdb_3_2_3__on_delay) [Nothing]
    (ltim_2_4_1__one_timed_tests lcdb_3_2_3__on_delay)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 3), SPumpT 3, SInput (Tick 6), SPumpT 3]
    = [[], [(0, True)], []]
lcdb_3_2_3__on_delay_fires_once = Refl

--@derives [LCDB.3.2.3]
--@derives [LTIM.2.5.1]
||| RETRACTED BEFORE T, NOTHING FIRES: the Motion asserted at 0, retracted
||| at 1, the pump at 3 -- logical/LCDB.3.2.3_dwell_on_delay_retracted's
||| shape. The match ends with the fact. Executed: `[[]]`.
export
lcdb_3_2_3__retracted_before_t_fires_nothing :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule lcdb_3_2_3__on_delay) [Nothing]
    (ltim_2_4_1__one_timed_tests lcdb_3_2_3__on_delay)
    [SInput (Data (Assert 0 1 0)), SInput (Tick 1), SInput (Data (Retract 0)), SInput (Tick 3), SPumpT 3]
    = [[]]
lcdb_3_2_3__retracted_before_t_fires_nothing = Refl

--@spec [LTIM.2.7.2]
||| THE LIFECYCLES OF THE `within` FIXTURE: kind 0 the Sensor, an entity;
||| kind 1 the Occupied it justifies, a relation -- `logical`, so the emit
||| records a row.
public export
ltim_2_7_2__life : Nat -> Lscp_1_3__lifecycle
ltim_2_7_2__life Z = Entity
ltim_2_7_2__life (S _) = Relation

--@spec [LTIM.2.7.2]
||| Two alphas, kinds 0 and 1.
public export
ltim_2_7_2__alphas_two : List (Nat, Lfac_1_7_1__fact -> Bool)
ltim_2_7_2__alphas_two = [(0, lcdb_3_2_1__admits_all), (1, lcdb_3_2_1__admits_all)]

--@spec [LTIM.2.7.2]
--@spec [LTIM.2.7.1]
||| `occupy`: `Sensor within 3_s`, emitting Occupied logical --
||| logical/LTIM.2.5.1_logical_within_fires_once's rule, the node loaded
||| with the test at the sample (0, 0).
public export
ltim_2_7_2__occupy : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_7_2__occupy = [([(0, ltim_2_4_1__test_of ltim_2_4_1__wenv ltim_2_7_1__within_three [] (0, 0), False)], [Emit 1 (\_ => (0, 0))])]

--@derives [LTIM.2.7.2]
--@derives [LTIM.2.7.1]
--@derives [LTIM.2.5.1]
--@derives [LTIM.2.4.2]
||| A `within` THAT JUSTIFIES A LOGICAL EMIT FIRES ONCE WHEN IT OPENS AND
||| NOT WHILE IT HOLDS: the Sensor asserted at 0 under `within 3`; the pump
||| at 0 fires and emits, the pump at 1 fires nothing (the match persists
||| across the tick), the pump at 4 fires nothing. Executed:
||| `[[(0, True)], [], []]`.
export
ltim_2_7_2__within_fires_once :
  ltim_2_4_1__verdicts_of ltim_2_7_2__life lcdb_3_2_1__no_ttl ltim_2_7_2__alphas_two ltim_2_7_2__occupy [Nothing]
    (ltim_2_4_1__one_timed_tests ltim_2_7_1__within_three)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 1), SPumpT 3, SInput (Tick 4), SPumpT 3]
    = [[(0, True)], [], []]
ltim_2_7_2__within_fires_once = Refl

--@derives [LTIM.2.7.2]
--@derives [LLOG.15.1]
||| AND THE JUSTIFIED FACT IS RETRACTED WHEN THE WINDOW CLOSES: after the
||| pump at 1 the Occupied stands beside the Sensor; after the pump at 4,
||| whose re-time ends the match and whose cascade drops the row, the
||| Sensor alone is live. Executed.
export
ltim_2_7_2__lapsed_fact_retracted :
  ( ltim_2_4_1__wm_after ltim_2_7_2__life lcdb_3_2_1__no_ttl ltim_2_7_2__alphas_two ltim_2_7_2__occupy [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_7_1__within_three)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 1), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 1 1 0 0]
  , ltim_2_4_1__wm_after ltim_2_7_2__life lcdb_3_2_1__no_ttl ltim_2_7_2__alphas_two ltim_2_7_2__occupy [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_7_1__within_three)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 1), SPumpT 3, SInput (Tick 4), SPumpT 3]
      = [MkFact 0 0 1 0] )
ltim_2_7_2__lapsed_fact_retracted = (Refl, Refl)

--@derives [LTIM.2.5.4]
--@derives [LTIM.2.4.2]
--@derives [RDSC.4a.8.2.3]
||| UNDER A COOLDOWN A SECOND MATURITY INSIDE THE WINDOW IS GATED, AND THE
||| MATCH DOES NOT REFIRE PAST IT: the on-delay under `cooldown 60`; the
||| Motion asserted at 0 matures at 2 and acts; retracted and asserted
||| again at 10, a new match, it matures at 12 inside the minute, fires and
||| is gated; at 70 the match persists and nothing fires --
||| logical/LTIM.2.4.2_cooldown_still_gates_across_ticks's shape. Executed:
||| `[[], [(0, True)], [], [(0, False)], []]`.
export
ltim_2_5_4__second_maturity_is_gated :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule lcdb_3_2_3__on_delay)
    (lcdb_3_2_1__cooled 60 lcdb_3_3_1__key_of_head) (ltim_2_4_1__one_timed_tests lcdb_3_2_3__on_delay)
    [ SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 2), SPumpT 3
    , SInput (Tick 10), SInput (Data (Retract 0)), SInput (Data (Assert 0 1 0)), SPumpT 3
    , SInput (Tick 12), SPumpT 3, SInput (Tick 70), SPumpT 3 ]
    = [[], [(0, True)], [], [(0, False)], []]
ltim_2_5_4__second_maturity_is_gated = Refl

--@spec [RDSC.4a.8.2.2]
||| The null-need fixture's rules: `settled` under `dwell >= m.need`, and
||| `steady` with no condition, both over kind 0.
public export
rdsc_4a_8_2_2__rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
rdsc_4a_8_2_2__rules = [ ([(0, ltim_2_4_1__test_of ltim_2_4_1__wenv rdsc_4a_8_2_2__need_gate [] (0, 0), False)], [])
                       , ([(0, lcdb_3_2_1__any_join, False)], []) ]

--@derives [RDSC.4a.8.2.2]
--@derives [LNUL.4.3]
||| A `null` CONDITION WITHHOLDS: the Motion's `need` is `null`, so
||| `dwell >= need` answers `null` at every sample and `settled` never
||| fires, while `steady` fires at the first pump --
||| logical/RDSC.4a.8.2.2_null_condition_withholds's shape. Executed:
||| `[[(1, True)], []]`.
export
rdsc_4a_8_2_2__null_condition_withholds :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one rdsc_4a_8_2_2__rules [Nothing, Nothing]
    [Just (ltim_2_4_1__test_of ltim_2_4_1__wenv rdsc_4a_8_2_2__need_gate), Nothing]
    [SInput (Data (Assert 0 1 7)), SPumpT 3, SInput (Tick 3), SPumpT 3]
    = [[(1, True)], []]
rdsc_4a_8_2_2__null_condition_withholds = Refl

--@derives [LTIM.2.5.1]
--@derives [LTIM.2.8.6]
||| A `dwell` WINDOW THAT SHUTS AND REOPENS FIRES ONCE PER OPENING: ticks
||| 1 to 6 each followed by a pump; the window opens at 2, shuts at 4,
||| reopens at 6 -- logical/LTIM.2.5.1_window_reopens's shape. Executed:
||| `[[], [(0, True)], [], [], [], [(0, True)]]`.
export
ltim_2_5_1__dwell_window_reopens :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_1__dwell_window) [Nothing]
    (ltim_2_4_1__one_timed_tests ltim_2_5_1__dwell_window)
    [ SInput (Data (Assert 0 1 0)), SInput (Tick 1), SPumpT 3, SInput (Tick 2), SPumpT 3, SInput (Tick 3), SPumpT 3
    , SInput (Tick 4), SPumpT 3, SInput (Tick 5), SPumpT 3, SInput (Tick 6), SPumpT 3 ]
    = [[], [(0, True)], [], [], [], [(0, True)]]
ltim_2_5_1__dwell_window_reopens = Refl

--@derives [LTIM.2.5.3]
--@derives [LTIM.2.4.3]
||| TRUE AT THE ASSERT, FALSE UNDER THE PUMP'S SAMPLE, NOTHING FIRES: the
||| Ping asserted at 0 under `dwell < 2`, the clock advanced to 3, one pump
||| -- logical/LTIM.2.5.3_true_at_assert_false_at_pump's `young`. And the
||| other half: advanced to 1, the condition still holds under the pump's
||| sample and it fires. Executed: `[[]]` and `[[(0, True)]]`.
export
ltim_2_5_3__true_at_assert_decided_at_the_pump :
  ( ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_3__young) [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_5_3__young)
      [SInput (Data (Assert 0 1 0)), SInput (Tick 3), SPumpT 3]
      = [[]]
  , ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_3__young) [Nothing]
      (ltim_2_4_1__one_timed_tests ltim_2_5_3__young)
      [SInput (Data (Assert 0 1 0)), SInput (Tick 1), SPumpT 3]
      = [[(0, True)]] )
ltim_2_5_3__true_at_assert_decided_at_the_pump = (Refl, Refl)

--@derives [LTIM.2.5.3]
||| AND A CONDITION TRUE AT THE ASSERT FIRES ON THE NEXT PUMP with no tick
||| between: the pump's re-time at the held sample decides it. Executed:
||| `[[(0, True)]]`.
export
ltim_2_5_3__fires_on_the_next_pump :
  ltim_2_4_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl lcdb_3_2_1__alphas_one (ltim_2_4_1__one_timed_rule ltim_2_5_3__young) [Nothing]
    (ltim_2_4_1__one_timed_tests ltim_2_5_3__young)
    [SInput (Data (Assert 0 1 0)), SPumpT 3]
    = [[(0, True)]]
ltim_2_5_3__fires_on_the_next_pump = Refl

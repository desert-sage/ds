-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Clock ticks and TTL expiry: the engine clock RARC.5.5, a fact's
||| deadline [IRET.4.3], the TTL sweep [IRET.19.3], and the consumption
||| loop's clock advance RARC.5.6.3, layered over Rete/PumpBoundary.idr's
||| boundary model.
|||
||| NORMATIVE COMPANION, on the same mechanisms as Rete/FireLoopTms.idr.
|||
||| ⚠ WHERE THE SWEEP RUNS, AND WHERE THE CLAUSE PUTS IT.
||| RARC.5.6.3 (with RARC.7.15 and RARC.5.2.4): a PUMP, at its entry and before
||| anything fires, retracts the expired `ttl` facts; an assert, a retract
||| or a clock move retracts nothing, and an expired fact stays in working
||| memory until the next pump. This module sweeps as each INPUT is consumed
||| (`rarc_5_6_3__prepare`: a tick advances the clock and sweeps; a data
||| event is swept for, then applied) and its pump (`iret_11_4__run_ttl`)
||| sweeps nothing; every engine built on it (Rete/NetworkTtl.idr,
||| Rete/NetworkClocked.idr and their frames) inherits the placement. On a
||| tick followed by a pump the two agree:
||| advance, sweep, run is the clause's advance, then the pump's sweep and
||| run. On a data event they differ inside the boundary: the clause applies
||| the event to a working memory still holding the expired fact, which it
||| joins until the pump's sweep ends the match (RARC.7.15); here the sweep
||| runs first and no such match exists. No theorem relates the two orders.
||| The ties that place the sweep are `partial` for it; the sweep's own
||| mechanics -- what expires, the retraction, the cascade, the invariant it
||| re-establishes -- are the clause's and stay `proven`. The Idris model
||| compares the runtimes with this model at pump boundaries alone and by
||| content, where the two coincide.
|||
||| WHAT IS MODELLED. Beside the engine sits the deadline table
||| (`Iret_4_3__deadlines`: fact id to `deadline_ns`) and the clock. A
||| schema's default TTL is a table `Iret_4_2__ttl` (zero: no TTL). Every
||| mint -- an emit in a firing, an adapter assert -- records the fresh id's
||| deadline as the clock plus the kind's TTL, clearing any stale row of
||| that id first (`iret_4_3__stamp`); the mint is exact because a TTL
||| schema is explicit [LFAC.1.3.5], so its assert always mints the fresh
||| id. A tick carries the monotonic sample the clock source gave when the
||| input was consumed (RARC.5.6.3, [LTIM.2.8.4]) and the clock takes it;
||| a sample is never below the clock ([LTIM.2.8.2]), which the advance
||| guards structurally; the sweep then retracts every live fact whose deadline
||| is at or before the clock, propagates, and cascades [IRET.19.3]; the
||| input is applied RARC.5.6.4 and the pump fires RARC.5.6.6. The
||| firing loop is Rete/FireLoopTms.idr's with the table threaded through
||| (`iret_11_4__step_ttl`, `iret_11_4__run_ttl`), and it agrees with it on
||| the engine (`iret_11_4__step_ttl_engine`, `rarc_5_6_6__pump_ttl_engine`),
||| so everything proved of the engine holds here.
|||
||| WHAT IS PROVED. The deadline table is well-formed throughout
||| (`Iret_4_3__deadlines_ok`): one row per id, every live TTL fact has
||| its row, no other live fact has one, and every live fact's deadline
||| is in the future -- which the sweep re-establishes after a clock
||| advance. [IRET.22.6]'s three properties: a TTL fact is not retracted
||| before its deadline (`iret_22_6__not_before_deadline`: the sweep skips
||| it and the cascade never removes an explicit fact); it is retracted at
||| or after its deadline on the next tick (`iret_22_6__at_or_after_deadline`);
||| and the retraction propagates and cascades (`iret_22_6__cascade`, by
||| construction). The clock never runs backwards
||| (`rarc_5_6_3__clock_monotone`). Every input sequence with ticks has a
||| canonical replay for a certified positive program
||| (`lfst_9_2_1__canonical_ttl_exists`, `lfst_9_2_1__canonical_ttl_from_input`).
|||
||| SCOPE. Positive programs and [LCYC.3.1.1]'s certificate, as before. TTL
||| schemas are explicit-lifecycle (`Lfac_1_3_5__ttl_explicit`). The
||| default TTL only: `+dynamic_ttl`'s per-emit `retain:` [LDTL.4] would
||| make the deadline a function of the emit, not the kind. The clock is
||| the mock clock of a canonical stream: it moves only at ticks, so a
||| pump's mints share its clock, which is [IRET.25.4.1]'s one read per
||| fire made exact. `__ClockTick__` [IRET.19.5] and `within` windows are
||| not modelled.
module Rete.TtlSweep

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.PumpBoundary
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- The TTL table, the deadline table, the clocked state
-- ---------------------------------------------------------------------

--@spec [IRET.4.2]
||| The schema descriptor's default TTL, by kind: zero for a schema
||| without one.
public export
Iret_4_2__ttl : Type
Iret_4_2__ttl = Nat -> Nat

--@derives [LFAC.1.3.5]
||| A schema with a TTL is not `logical`: `emit X logical` into a `ttl`
||| schema is a compile error. In the model, a TTL kind has the explicit
||| lifecycle, so its assert always mints and records no justification.
public export
Lfac_1_3_5__ttl_explicit : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Type
Lfac_1_3_5__ttl_explicit p ttl = (k : Nat) -> Not (ttl k = 0) -> life p k = Explicit

--@spec [IRET.4.3]
||| The deadline table beside the engine: fact id to `deadline_ns`. A
||| fact without a row has no deadline.
public export
Iret_4_3__deadlines : Type
Iret_4_3__deadlines = List (Nat, Nat)

--@spec [IRET.4.3]
||| Drop an id's rows.
public export
iret_4_3__clear : Nat -> Iret_4_3__deadlines -> Iret_4_3__deadlines
iret_4_3__clear i dl = filter (\e => not (fst e == i)) dl

--@spec [IRET.4.3]
||| Record a fresh fact's deadline: the id's stale rows go, and a row is
||| added when the kind has a TTL -- `assert_ns` plus the schema's TTL.
public export
iret_4_3__stamp : Iret_4_2__ttl -> Nat -> Nat -> Nat -> Iret_4_3__deadlines -> Iret_4_3__deadlines
iret_4_3__stamp ttl now i k dl = if ttl k == 0 then iret_4_3__clear i dl else iret_4_3__clear i dl ++ [(i, now + ttl k)]

--@spec [IRET.4.3]
||| What one RHS action mints: an emit mints the fresh id [LFAC.2.5.3]
||| when it mints at all, and its deadline is the clock plus the kind's TTL.
public export
iret_4_3__record_action : Iret_4_2__ttl -> Nat -> Iret_11__tok -> Lgra_10_1__action -> Rarc_5_6_4__wm -> Iret_4_3__deadlines -> Iret_4_3__deadlines
iret_4_3__record_action ttl now tok (Withdraw _) wm dl = dl
iret_4_3__record_action ttl now tok (Emit k _) wm dl = iret_4_3__stamp ttl now (lfac_2_5_3__fresh_id (iret_11_3__ids tok) wm) k dl

--@spec [IRET.4.3]
||| An input fact's deadline row: none for a kind without a TTL.
public export
iret_4_3__row : Iret_4_2__ttl -> Nat -> Lfac_1_7_1__fact -> Maybe (Nat, Nat)
iret_4_3__row ttl c f = if ttl (fkind f) == 0 then Nothing else Just (fid f, c + ttl (fkind f))

--@spec [IRET.4.3]
||| The input's deadlines: every input fact of a TTL kind, asserted at
||| the start clock.
public export
iret_4_3__init : Iret_4_2__ttl -> Nat -> Rarc_5_6_4__wm -> Iret_4_3__deadlines
iret_4_3__init ttl c wm0 = mapMaybe (iret_4_3__row ttl c) wm0

--@spec [IRET.19.3]
||| The engine with truth maintenance, its deadline table, and its clock
||| RARC.5.5.
public export
record Iret_19_3__clocked where
  constructor MkClocked
  engine    : Iret_12__state
  deadlines : Iret_4_3__deadlines
  clock     : Nat

-- ---------------------------------------------------------------------
-- The firing loop with the deadline table threaded through
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.7]
||| One action: the engine's, and the deadline the emit mints.
public export
rarc_5_6_7__do_action_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_11__tok -> Lgra_10_1__action -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_7__do_action_ttl p ttl r tok a (MkClocked (MkTms st rows) dl c) =
  MkClocked (rarc_5_6_7__do_action_tms p r tok a (MkTms st rows)) (iret_4_3__record_action ttl c tok a (wm st) dl) c

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_11__tok -> List Lgra_10_1__action -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_7__do_actions_ttl p ttl r tok [] cs = cs
rarc_5_6_7__do_actions_ttl p ttl r tok (a :: as) cs = case rarc_5_6_7__do_action_ttl p ttl r tok a cs of
  MkClocked s dl c => rarc_5_6_7__do_actions_ttl p ttl r tok as (MkClocked s dl c)

--@spec [IRET.11.4]
||| One firing, the deadline table threaded through.
public export
iret_11_4__step_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked -> Maybe Iret_19_3__clocked
iret_11_4__step_ttl p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) = case ldet_5_1__select_next tables of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (rules p) of
    Nothing => Nothing
    Just rule => case rarc_5_6_5__nth j (iret_11__table_at r tables) of
      Nothing => Nothing
      Just tok => Just (rarc_5_6_7__do_actions_ttl p ttl r tok (actions rule) (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows) dl c))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The bounded run, the deadline table threaded through.
public export
iret_11_4__run_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_19_3__clocked -> (Iret_19_3__clocked, Iret_11_4__halt, Nat)
iret_11_4__run_ttl p ttl Z cs = (cs, FuelOut, 0)
iret_11_4__run_ttl p ttl (S fuel) cs = case iret_11_4__step_ttl p ttl cs of
  Nothing => (cs, Quiescent, 0)
  Just cs' => let (t, h, n) = iret_11_4__run_ttl p ttl fuel cs' in (t, h, S n)

-- ---------------------------------------------------------------------
-- The sweep, the clock, the inputs
-- ---------------------------------------------------------------------

--@spec [IRET.19.3]
||| The ids whose deadline is at or before now.
public export
iret_19_3__expired : Nat -> Iret_4_3__deadlines -> List Nat
iret_19_3__expired now dl = map fst (filter (\e => iret_12__lte_b (snd e) now) dl)

--@spec [IRET.19.3]
--@spec [RARC.5.6.3]
||| THE SWEEP. Retract every live fact whose deadline is at or before the
||| clock, propagate, and run the cascade the ended activations demand.
||| One batch retracts them all: their deadlines are decided by the clock
||| the sweep reads, and a retraction creates no new deadline.
public export
rarc_5_6_3__sweep : Lcyc_3_2_1__program -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c) =
  MkClocked (iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
                                                 (rarc_5_6_5__propagate p (iret_12_2__retract_ids (iret_19_3__expired c dl) wm) tables)) rows)) dl c

--@spec [RARC.5.6.3]
||| The clock after a tick whose sample is t: t. A `Tick t` is the sample the
||| source gave when the input was consumed, and a sample is never below the
||| clock ([LTIM.2.8.2]), so the `else` arm is a guard no conforming source
||| reaches; it is written so that the proofs of monotonicity are
||| structural. Named, so that another engine's advance can share it.
public export
rarc_5_6_3__next_clock : Nat -> Nat -> Nat
rarc_5_6_3__next_clock c t = if iret_12__lte_b c t then t else c

--@spec [RARC.5.6.3]
||| Advance the clock to the tick's sample.
public export
rarc_5_6_3__advance : Nat -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_3__advance t (MkClocked s dl c) = MkClocked s dl (rarc_5_6_3__next_clock c t)

--@spec [RARC.5.6.2]
||| The input a call carries ([RARC.5.6.2]): a clock tick, the new clock
||| value, or a data event.
public export
data Rarc_5_6_2__input : Type where
  Tick : (clock_ns : Nat) -> Rarc_5_6_2__input
  Data : Rarc_5_6_1__event -> Rarc_5_6_2__input

--@derives [RARC.5.6.2]
public export
Rarc_5_6_2__input_in_dom : List (Nat, Nat) -> Rarc_5_6_2__input -> Type
Rarc_5_6_2__input_in_dom dom (Tick _) = ()
Rarc_5_6_2__input_in_dom dom (Data ev) = Rarc_5_6_1__event_in_dom dom ev

--@spec [RARC.5.6.4]
||| Apply a data event: the engine's application, and an adapter assert
||| mints the fresh id at the clock.
public export
rarc_5_6_4__apply_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_1__event -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_4__apply_ttl p ttl (Assert k key pay) (MkClocked (MkTms (MkState wm tables) rows) dl c) =
  MkClocked (rarc_5_6_4__apply p (Assert k key pay) (MkTms (MkState wm tables) rows)) (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] wm) k dl) c
rarc_5_6_4__apply_ttl p ttl (Retract i) (MkClocked s dl c) = MkClocked (rarc_5_6_4__apply p (Retract i) s) dl c

--@spec [RARC.5.6.3]
||| The loop's steps before firing, as this model orders them: advance the
||| clock if the input is a tick, sweep, apply the data event if any. The
||| clause sweeps at the pump's entry and not as the input is consumed
||| (the header's ⚠): on a tick the two agree once the pump
||| runs, on a data event the clause applies before it sweeps and this
||| model sweeps before it applies.
public export
rarc_5_6_3__prepare : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_2__input -> Iret_19_3__clocked -> Iret_19_3__clocked
rarc_5_6_3__prepare p ttl (Tick t) cs = rarc_5_6_3__sweep p (rarc_5_6_3__advance t cs)
rarc_5_6_3__prepare p ttl (Data ev) cs = rarc_5_6_4__apply_ttl p ttl ev (rarc_5_6_3__sweep p cs)

--@spec [LFST.9.2.1]
||| The canonical cadence with ticks: one input, then a pump.
public export
lfst_9_2_1__boundary_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Rarc_5_6_2__input -> Iret_19_3__clocked -> Iret_19_3__clocked
lfst_9_2_1__boundary_ttl p ttl fuel inp cs = fst (iret_11_4__run_ttl p ttl fuel (rarc_5_6_3__prepare p ttl inp cs))

--@spec [LFST.9.2.1]
||| A canonical replay with ticks: each input pumped to quiescence.
public export
data Lfst_9_2_1__canonical_ttl : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked -> List Rarc_5_6_2__input -> Iret_19_3__clocked -> Type where
  CanonTtlNil  : Lfst_9_2_1__canonical_ttl p ttl cs [] cs
  CanonTtlStep : (fuel : Nat) -> fst (snd (iret_11_4__run_ttl p ttl fuel (rarc_5_6_3__prepare p ttl inp cs))) = Quiescent ->
                 Lfst_9_2_1__canonical_ttl p ttl (lfst_9_2_1__boundary_ttl p ttl fuel inp cs) inps cs' ->
                 Lfst_9_2_1__canonical_ttl p ttl cs (inp :: inps) cs'

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [IRET.12]
iret_12__lte_b_false_lt : (a, b : Nat) -> iret_12__lte_b a b = False -> LT b a
iret_12__lte_b_false_lt Z b prf = absurd prf
iret_12__lte_b_false_lt (S a) Z _ = LTESucc LTEZero
iret_12__lte_b_false_lt (S a) (S b) prf = LTESucc (iret_12__lte_b_false_lt a b prf)

--@derives [IRET.12]
export
iret_12__lte_b_true_lte : (a, b : Nat) -> iret_12__lte_b a b = True -> LTE a b
iret_12__lte_b_true_lte Z b _ = LTEZero
iret_12__lte_b_true_lte (S a) Z prf = absurd prf
iret_12__lte_b_true_lte (S a) (S b) prf = LTESucc (iret_12__lte_b_true_lte a b prf)

--@derives [IRET.12]
iret_12__lt_lte_b_false : (a, b : Nat) -> LT b a -> iret_12__lte_b a b = False
iret_12__lt_lte_b_false Z b lt = absurd lt
iret_12__lt_lte_b_false (S a) Z _ = Refl
iret_12__lt_lte_b_false (S a) (S b) (LTESucc lt) = iret_12__lt_lte_b_false a b lt

--@derives [IRET.4.3]
iret_4_3__lt_ttl : (c, d : Nat) -> Not (d = 0) -> LT c (c + d)
iret_4_3__lt_ttl c Z nz = void (nz Refl)
iret_4_3__lt_ttl c (S m) _ = replace {p = \x => LTE (S c) x} (plusSuccRightSucc c m) (LTESucc (lteAddRight c))

--@derives [IRET.4.3]
iret_4_3__emit_inj : {k, k' : Nat} -> {v, v' : List Lfac_1_7_1__fact -> (Nat, Nat)} -> Emit k v = Emit k' v' -> (k = k', v = v')
iret_4_3__emit_inj Refl = (Refl, Refl)

--@derives [IRET.4.3]
iret_4_3__withdraw_not_emit : {i, k : Nat} -> {v : List Lfac_1_7_1__fact -> (Nat, Nat)} -> Withdraw i = Emit k v -> Void
iret_4_3__withdraw_not_emit Refl impossible

--@derives [IRET.4.3]
iret_4_3__clear_elem : (i, j, t : Nat) -> (dl : Iret_4_3__deadlines) -> Elem (j, t) (iret_4_3__clear i dl) -> (Elem (j, t) dl, Not (j = i))
iret_4_3__clear_elem i j t dl e =
  let (e', ne) = lcyc_1_1__elem_filter_inv (\x => not (fst x == i)) dl e
  in (e', \eq => lcyc_1_1__bool_not_both (j == i) (rewrite eq in lcyc_1_1__nat_eq_refl i) (lcyc_1_1__not_true_is_false _ ne))

--@derives [IRET.4.3]
iret_4_3__clear_keeps : (i, j, t : Nat) -> Not (j = i) -> (dl : Iret_4_3__deadlines) -> Elem (j, t) dl -> Elem (j, t) (iret_4_3__clear i dl)
iret_4_3__clear_keeps i j t ne dl e = lcyc_1_1__elem_filter_fwd (\x => not (fst x == i)) dl e (iret_12__not_false _ (lcyc_1_1__nat_eq_false j i ne))

--@derives [IRET.4.3]
||| A row of the stamped table is an untouched row of another id, or the new row.
iret_4_3__stamp_elem : (ttl : Iret_4_2__ttl) -> (now, i, k : Nat) -> (dl : Iret_4_3__deadlines) -> (j, t : Nat) -> Elem (j, t) (iret_4_3__stamp ttl now i k dl) ->
                       Either (Elem (j, t) dl, Not (j = i)) (j = i, t = now + ttl k, Not (ttl k = 0))
iret_4_3__stamp_elem ttl now i k dl j t e with (ttl k == 0) proof z
  iret_4_3__stamp_elem ttl now i k dl j t e | True = Left (iret_4_3__clear_elem i j t dl e)
  iret_4_3__stamp_elem ttl now i k dl j t e | False = case lcyc_1_1__elem_append_inv (iret_4_3__clear i dl) e of
    Left e' => Left (iret_4_3__clear_elem i j t dl e')
    Right e1 => let pe = iret_12__elem_singleton e1 in Right (cong fst pe, cong snd pe, lcyc_1_1__nat_neq_false _ 0 z)

--@derives [IRET.4.3]
iret_4_3__stamp_new : (ttl : Iret_4_2__ttl) -> (now, i, k : Nat) -> (dl : Iret_4_3__deadlines) -> Not (ttl k = 0) -> Elem (i, now + ttl k) (iret_4_3__stamp ttl now i k dl)
iret_4_3__stamp_new ttl now i k dl nz with (ttl k == 0) proof z
  iret_4_3__stamp_new ttl now i k dl nz | True = void (nz (lcyc_1_1__nat_eq_true _ _ z))
  iret_4_3__stamp_new ttl now i k dl nz | False = lcyc_1_1__elem_append_right (iret_4_3__clear i dl) Here

--@derives [IRET.4.3]
iret_4_3__stamp_keeps : (ttl : Iret_4_2__ttl) -> (now, i, k : Nat) -> (dl : Iret_4_3__deadlines) -> (j, t : Nat) -> Not (j = i) -> Elem (j, t) dl ->
                        Elem (j, t) (iret_4_3__stamp ttl now i k dl)
iret_4_3__stamp_keeps ttl now i k dl j t ne e with (ttl k == 0)
  iret_4_3__stamp_keeps ttl now i k dl j t ne e | True = iret_4_3__clear_keeps i j t ne dl e
  iret_4_3__stamp_keeps ttl now i k dl j t ne e | False = lcyc_1_1__elem_append_left (iret_4_3__clear_keeps i j t ne dl e)

--@derives [IRET.4.3]
iret_4_3__stamp_unique : (ttl : Iret_4_2__ttl) -> (now, i, k : Nat) -> (dl : Iret_4_3__deadlines) ->
                         ((j, t, t' : Nat) -> Elem (j, t) dl -> Elem (j, t') dl -> t = t') ->
                         (j, t, t' : Nat) -> Elem (j, t) (iret_4_3__stamp ttl now i k dl) -> Elem (j, t') (iret_4_3__stamp ttl now i k dl) -> t = t'
iret_4_3__stamp_unique ttl now i k dl uq j t t' e e' =
  case (iret_4_3__stamp_elem ttl now i k dl j t e, iret_4_3__stamp_elem ttl now i k dl j t' e') of
    (Left (a, _), Left (b, _)) => uq j t t' a b
    (Left (_, ne), Right (ji, _, _)) => void (ne ji)
    (Right (ji, _, _), Left (_, ne)) => void (ne ji)
    (Right (_, te, _), Right (_, te', _)) => trans te (sym te')

-- ---------------------------------------------------------------------
-- The deadline table's invariant
-- ---------------------------------------------------------------------

--@derives [IRET.4.3]
||| One row per id; every live TTL fact has its row; no other live fact
||| has one; every live fact's deadline is after the clock.
public export
record Iret_4_3__deadlines_ok (ttl : Iret_4_2__ttl) (wm : Rarc_5_6_4__wm) (dl : Iret_4_3__deadlines) (clock : Nat) where
  constructor MkDeadlinesOk
  dlUnique  : (i, t, t' : Nat) -> Elem (i, t) dl -> Elem (i, t') dl -> t = t'
  dlStamped : (f : Lfac_1_7_1__fact) -> Elem f wm -> Not (ttl (fkind f) = 0) -> (t : Nat ** Elem (fid f, t) dl)
  dlPlain   : (f : Lfac_1_7_1__fact) -> Elem f wm -> ttl (fkind f) = 0 -> (t : Nat) -> Not (Elem (fid f, t) dl)
  dlFuture  : (f : Lfac_1_7_1__fact) -> (t : Nat) -> Elem f wm -> Elem (fid f, t) dl -> LT clock t

--@derives [IRET.19.3]
||| The clocked state's invariant: the engine's run invariant and target
||| kinds, and the deadline table's.
public export
Iret_19_3__inv : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List (Nat, Nat) -> Iret_19_3__clocked -> Type
Iret_19_3__inv p ttl dom cs =
  (Iret_12__run_inv_s p dom (engine cs), Iret_12_4__run_kind_s p (engine cs), Iret_4_3__deadlines_ok ttl (core (engine cs)).wm (deadlines cs) (clock cs))

--@derives [IRET.4.3]
||| Fewer facts, same table: still well-formed.
iret_4_3__deadlines_sub : (ttl : Iret_4_2__ttl) -> (wm, wm' : Rarc_5_6_4__wm) -> ((f : Lfac_1_7_1__fact) -> Elem f wm' -> Elem f wm) ->
                          (dl : Iret_4_3__deadlines) -> (c : Nat) -> Iret_4_3__deadlines_ok ttl wm dl c -> Iret_4_3__deadlines_ok ttl wm' dl c
iret_4_3__deadlines_sub ttl wm wm' sub dl c dok =
  MkDeadlinesOk (dlUnique dok) (\f, e, nz => dlStamped dok f (sub f e) nz) (\f, e, z, t, ne => dlPlain dok f (sub f e) z t ne) (\f, t, e, et => dlFuture dok f t (sub f e) et)

--@derives [IRET.4.3]
||| A mint keeps the table well-formed: the fresh id was not live, so its
||| old rows belonged to no live fact; the new fact's row, if any, is in
||| the future.
iret_4_3__deadlines_mint : (ttl : Iret_4_2__ttl) -> (c, i0, k : Nat) -> (w, w1 : Rarc_5_6_4__wm) -> (dl : Iret_4_3__deadlines) ->
                           rarc_5_6_4__is_live i0 w = False ->
                           ((g : Lfac_1_7_1__fact) -> Elem g w1 -> Either (Elem g w) (fid g = i0, fkind g = k)) ->
                           Iret_4_3__deadlines_ok ttl w dl c -> Iret_4_3__deadlines_ok ttl w1 (iret_4_3__stamp ttl c i0 k dl) c
iret_4_3__deadlines_mint ttl c i0 k w w1 dl fresh mint dok =
  MkDeadlinesOk
    (iret_4_3__stamp_unique ttl c i0 k dl (dlUnique dok))
    (\f, ef, nz => case mint f ef of
       Left efw => let (t ** e) = dlStamped dok f efw nz in (t ** iret_4_3__stamp_keeps ttl c i0 k dl (fid f) t (notFresh f efw) e)
       Right (fi, fk) => (c + ttl k ** replace {p = \x => Elem (x, c + ttl k) (iret_4_3__stamp ttl c i0 k dl)} (sym fi)
                                          (iret_4_3__stamp_new ttl c i0 k dl (\z => nz (trans (cong ttl fk) z)))))
    (\f, ef, z, t, e => case iret_4_3__stamp_elem ttl c i0 k dl (fid f) t e of
       Left (e', ne) => case mint f ef of
         Left efw => dlPlain dok f efw z t e'
         Right (fi, _) => ne fi
       Right (fi, _, nz) => case mint f ef of
         Left efw => notFresh f efw fi
         Right (_, fk) => nz (trans (sym (cong ttl fk)) z))
    (\f, t, ef, e => case iret_4_3__stamp_elem ttl c i0 k dl (fid f) t e of
       Left (e', ne) => case mint f ef of
         Left efw => dlFuture dok f t efw e'
         Right (fi, _) => void (ne fi)
       Right (_, te, nz) => replace {p = \x => LT c x} (sym te) (iret_4_3__lt_ttl c (ttl k) nz))
  where
    notFresh : (f : Lfac_1_7_1__fact) -> Elem f w -> Not (fid f = i0)
    notFresh f efw eq = lcyc_1_1__bool_not_both _ (replace {p = \j => rarc_5_6_4__is_live j w = True} eq (rarc_5_6_4__is_live_of f w efw)) fresh

--@derives [IRET.4.3]
||| What a row of the input's table says of its fact.
iret_4_3__row_of : (ttl : Iret_4_2__ttl) -> (c : Nat) -> (f : Lfac_1_7_1__fact) -> (i, t : Nat) ->
                   iret_4_3__row ttl c f = Just (i, t) -> (fid f = i, t = c + ttl (fkind f), Not (ttl (fkind f) = 0))
iret_4_3__row_of ttl c f i t gf with (ttl (fkind f) == 0) proof z
  iret_4_3__row_of ttl c f i t gf | True = void (absurd (sym gf))
  iret_4_3__row_of ttl c f i t gf | False = let pe = lcyc_1_1__just_injective gf in (cong fst pe, sym (cong snd pe), lcyc_1_1__nat_neq_false _ 0 z)

--@derives [IRET.4.3]
||| A TTL fact has its row.
iret_4_3__row_for : (ttl : Iret_4_2__ttl) -> (c : Nat) -> (f : Lfac_1_7_1__fact) -> Not (ttl (fkind f) = 0) ->
                    iret_4_3__row ttl c f = Just (fid f, c + ttl (fkind f))
iret_4_3__row_for ttl c f nz with (ttl (fkind f) == 0) proof z
  iret_4_3__row_for ttl c f nz | True = void (nz (lcyc_1_1__nat_eq_true _ _ z))
  iret_4_3__row_for ttl c f nz | False = Refl

--@derives [IRET.4.3]
||| The input's table is well-formed, given unique ids.
iret_4_3__init_ok : (ttl : Iret_4_2__ttl) -> (c : Nat) -> (wm0 : Rarc_5_6_4__wm) -> Iret_4_4__unique wm0 -> Iret_4_3__deadlines_ok ttl wm0 (iret_4_3__init ttl c wm0) c
iret_4_3__init_ok ttl c wm0 uniq =
  MkDeadlinesOk
    (\i, t, t', e, e' => let (f ** (ef, gf)) = lcyc_1_1__map_maybe_elem_inv (iret_4_3__row ttl c) wm0 e
                         in let (f' ** (ef', gf')) = lcyc_1_1__map_maybe_elem_inv (iret_4_3__row ttl c) wm0 e'
                         in let (fi, ft, _) = iret_4_3__row_of ttl c f i t gf
                         in let (fi', ft', _) = iret_4_3__row_of ttl c f' i t' gf'
                         in let ff' : (f = f')
                                ff' = uniq f f' ef ef' (trans fi (sym fi'))
                            in trans ft (trans (cong (\g => c + ttl (fkind g)) ff') (sym ft')))
    (\f, ef, nz => (c + ttl (fkind f) ** lcyc_1_1__map_maybe_elem_fwd (iret_4_3__row ttl c) wm0 ef (iret_4_3__row_for ttl c f nz)))
    (\f, ef, z, t, e => let (f' ** (ef', gf')) = lcyc_1_1__map_maybe_elem_inv (iret_4_3__row ttl c) wm0 e
                        in let (fi', _, nz') = iret_4_3__row_of ttl c f' (fid f) t gf'
                        in let ff' : (f = f')
                               ff' = uniq f f' ef ef' (sym fi')
                           in nz' (trans (cong (\g => ttl (fkind g)) (sym ff')) z))
    (\f, t, ef, e => let (f' ** (ef', gf')) = lcyc_1_1__map_maybe_elem_inv (iret_4_3__row ttl c) wm0 e
                     in let (_, ft', nz') = iret_4_3__row_of ttl c f' (fid f) t gf'
                     in replace {p = \x => LT c x} (sym ft') (iret_4_3__lt_ttl c (ttl (fkind f')) nz'))

-- ---------------------------------------------------------------------
-- Agreement with the engine
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
rarc_5_6_7__action_ttl_engine : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) -> (cs : Iret_19_3__clocked) ->
                                engine (rarc_5_6_7__do_action_ttl p ttl r tok a cs) = rarc_5_6_7__do_action_tms p r tok a (engine cs)
rarc_5_6_7__action_ttl_engine p ttl r tok a (MkClocked (MkTms st rows) dl c) = Refl

--@derives [RARC.5.6.7]
rarc_5_6_7__actions_ttl_succ : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) -> (as : List Lgra_10_1__action) ->
                               (cs : Iret_19_3__clocked) -> (s : Iret_12__state) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                               rarc_5_6_7__do_action_ttl p ttl r tok a cs = MkClocked s dl c ->
                               rarc_5_6_7__do_actions_ttl p ttl r tok (a :: as) cs = rarc_5_6_7__do_actions_ttl p ttl r tok as (MkClocked s dl c)
rarc_5_6_7__actions_ttl_succ p ttl r tok a as cs s dl c eq with (rarc_5_6_7__do_action_ttl p ttl r tok a cs)
  rarc_5_6_7__actions_ttl_succ p ttl r tok a as cs s dl c eq | (MkClocked s' dl' c') = cong (rarc_5_6_7__do_actions_ttl p ttl r tok as) eq

--@derives [RARC.5.6.7]
rarc_5_6_7__actions_ttl_engine : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (as : List Lgra_10_1__action) -> (cs : Iret_19_3__clocked) ->
                                 engine (rarc_5_6_7__do_actions_ttl p ttl r tok as cs) = rarc_5_6_7__do_actions_tms p r tok as (engine cs)
rarc_5_6_7__actions_ttl_engine p ttl r tok [] cs = Refl
rarc_5_6_7__actions_ttl_engine p ttl r tok (a :: as) cs with (rarc_5_6_7__do_action_ttl p ttl r tok a cs) proof eq
  rarc_5_6_7__actions_ttl_engine p ttl r tok (a :: as) cs | (MkClocked (MkTms st rows) dl c) =
    let da : (rarc_5_6_7__do_action_tms p r tok a (engine cs) = MkTms st rows)
        da = trans (sym (rarc_5_6_7__action_ttl_engine p ttl r tok a cs)) (cong engine eq)
    in trans (rarc_5_6_7__actions_ttl_engine p ttl r tok as (MkClocked (MkTms st rows) dl c))
             (sym (rarc_5_6_7__actions_tms_succ p r tok a as (engine cs) st rows da))

--@derives [IRET.11.4]
||| One firing with the deadline table is the engine's firing on the engine.
iret_11_4__step_ttl_engine : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cs : Iret_19_3__clocked) ->
                             map (\s => engine s) (iret_11_4__step_ttl p ttl cs) = iret_11_4__step_tms p (engine cs)
iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) with (ldet_5_1__select_next tables)
  iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | Nothing = Refl
  iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | (Just (r, j)) with (rarc_5_6_5__nth r (rules p))
    iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | (Just (r, j)) | Nothing = Refl
    iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | (Just (r, j)) | (Just rule) with (rarc_5_6_5__nth j (iret_11__table_at r tables))
      iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | (Just (r, j)) | (Just rule) | Nothing = Refl
      iret_11_4__step_ttl_engine p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) | (Just (r, j)) | (Just rule) | (Just tok) =
        cong Just (rarc_5_6_7__actions_ttl_engine p ttl r tok (actions rule) (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows) dl c))

--@derives [IRET.11.4]
iret_11_4__step_tms_unfold : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             (r, j : Nat) -> (rule : Lgra_6_1__rule) -> (tok : Iret_11__tok) ->
                             ldet_5_1__select_next tables = Just (r, j) -> rarc_5_6_5__nth r (rules p) = Just rule -> rarc_5_6_5__nth j (iret_11__table_at r tables) = Just tok ->
                             iret_11_4__step_tms p (MkTms (MkState wm tables) rows) = Just (rarc_5_6_7__do_actions_tms p r tok (actions rule) (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows))
iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok with (ldet_5_1__select_next tables)
  iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | Nothing = void (absurd (sym sel))
  iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | (Just (r', j')) with (rarc_5_6_5__nth r' (rules p)) proof nr'
    iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | (Just (r', j')) | Nothing =
      let (re, _) = lcyc_1_1__pair_just sel in void (absurd (trans (sym nr) (trans (cong (\x => rarc_5_6_5__nth x (rules p)) (sym re)) nr')))
    iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | (Just (r', j')) | (Just rule') with (rarc_5_6_5__nth j' (iret_11__table_at r' tables)) proof ntok'
      iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | (Just (r', j')) | (Just rule') | Nothing =
        let (re, je) = lcyc_1_1__pair_just sel
        in void (absurd (trans (sym ntok) (trans (cong (\x => rarc_5_6_5__nth j (iret_11__table_at x tables)) (sym re))
                                                                       (trans (cong (\y => rarc_5_6_5__nth y (iret_11__table_at r' tables)) (sym je)) ntok'))))
      iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok | (Just (r', j')) | (Just rule') | (Just tok') =
        let (re, je) = lcyc_1_1__pair_just sel
        in let ruleEq : (rule' = rule)
               ruleEq = lcyc_1_1__just_injective (trans (sym nr') (trans (cong (\x => rarc_5_6_5__nth x (rules p)) re) nr))
               tokEq : (tok' = tok)
               tokEq = lcyc_1_1__just_injective (trans (sym ntok') (trans (cong (\x => rarc_5_6_5__nth j' (iret_11__table_at x tables)) re)
                                                                           (trans (cong (\y => rarc_5_6_5__nth y (iret_11__table_at r tables)) je) ntok)))
        in rewrite re in rewrite je in rewrite ruleEq in rewrite tokEq in Refl

--@derives [RARC.5.6.6]
||| A pump with the deadline table is the engine's pump on the engine:
||| the same state and the same halt.
rarc_5_6_6__pump_ttl_engine : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (cs : Iret_19_3__clocked) ->
                              ( engine (fst (iret_11_4__run_ttl p ttl fuel cs)) = fst (iret_11_4__run_tms p fuel (engine cs))
                              , fst (snd (iret_11_4__run_ttl p ttl fuel cs)) = fst (snd (iret_11_4__run_tms p fuel (engine cs))) )
rarc_5_6_6__pump_ttl_engine p ttl Z cs = (Refl, Refl)
rarc_5_6_6__pump_ttl_engine p ttl (S fuel) cs with (iret_11_4__step_ttl p ttl cs) proof st
  rarc_5_6_6__pump_ttl_engine p ttl (S fuel) cs | Nothing =
    let rn = iret_11_4__run_tms_nothing p fuel (engine cs) (trans (sym (iret_11_4__step_ttl_engine p ttl cs)) (cong (map (\s => engine s)) st))
    in (sym (cong fst rn), sym (cong (\x => fst (snd x)) rn))
  rarc_5_6_6__pump_ttl_engine p ttl (S fuel) cs | (Just cs1) with (iret_11_4__run_ttl p ttl fuel cs1) proof r1
    rarc_5_6_6__pump_ttl_engine p ttl (S fuel) cs | (Just cs1) | (t1, h1, n1) with (iret_11_4__run_tms p fuel (engine cs1)) proof r2
      rarc_5_6_6__pump_ttl_engine p ttl (S fuel) cs | (Just cs1) | (t1, h1, n1) | (t2, h2, n2) =
        let (ih1, ih2) = rarc_5_6_6__pump_ttl_engine p ttl fuel cs1
            rj = iret_11_4__run_tms_just p fuel (engine cs) (engine cs1) (trans (sym (iret_11_4__step_ttl_engine p ttl cs)) (cong (map (\s => engine s)) st)) t2 h2 n2 r2
        in ( trans (replace {p = \x => engine (fst x) = t2} r1 (replace {p = \y => engine (fst (iret_11_4__run_ttl p ttl fuel cs1)) = fst y} r2 ih1)) (sym (cong fst rj))
           , trans (replace {p = \x => fst (snd x) = h2} r1 (replace {p = \y => fst (snd (iret_11_4__run_ttl p ttl fuel cs1)) = fst (snd y)} r2 ih2)) (sym (cong (\x => fst (snd x)) rj)) )

--@derives [RARC.5.6.7]
||| The clock is untouched by an RHS.
rarc_5_6_7__actions_ttl_clock : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (as : List Lgra_10_1__action) -> (s : Iret_19_3__clocked) ->
                                clock (rarc_5_6_7__do_actions_ttl p ttl r tok as s) = clock s
rarc_5_6_7__actions_ttl_clock p ttl r tok [] s = Refl
rarc_5_6_7__actions_ttl_clock p ttl r tok (a :: as) (MkClocked (MkTms st rows) dl c) =
  rarc_5_6_7__actions_ttl_clock p ttl r tok as (MkClocked (rarc_5_6_7__do_action_tms p r tok a (MkTms st rows)) (iret_4_3__record_action ttl c tok a (wm st) dl) c)

--@derives [IRET.11.4]
||| Nor by a firing.
iret_11_4__step_ttl_clock : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (s, s' : Iret_19_3__clocked) -> iret_11_4__step_ttl p ttl s = Just s' -> clock s' = clock s
iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq with (ldet_5_1__select_next tables)
  iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | Nothing = void (absurd (sym eq))
  iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p))
    iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | (Just (r, j)) | Nothing = void (absurd (sym eq))
    iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | (Just (r, j)) | (Just rule) with (rarc_5_6_5__nth j (iret_11__table_at r tables))
      iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | (Just (r, j)) | (Just rule) | Nothing = void (absurd (sym eq))
      iret_11_4__step_ttl_clock p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) s' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        replace {p = \x => clock x = c} (iret_11_4__just_inj eq)
          (rarc_5_6_7__actions_ttl_clock p ttl r tok (actions rule) (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows) dl c))

--@derives [IRET.11.4]
||| Nor by a pump.
iret_11_4__pump_ttl_clock : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (cs : Iret_19_3__clocked) ->
                            clock (fst (iret_11_4__run_ttl p ttl fuel cs)) = clock cs
iret_11_4__pump_ttl_clock p ttl Z cs = Refl
iret_11_4__pump_ttl_clock p ttl (S fuel) cs with (iret_11_4__step_ttl p ttl cs) proof st
  iret_11_4__pump_ttl_clock p ttl (S fuel) cs | Nothing = Refl
  iret_11_4__pump_ttl_clock p ttl (S fuel) cs | (Just cs1) with (iret_11_4__run_ttl p ttl fuel cs1) proof r1
    iret_11_4__pump_ttl_clock p ttl (S fuel) cs | (Just cs1) | (t1, h1, n1) =
      trans (replace {p = \x => clock (fst x) = clock cs1} r1 (iret_11_4__pump_ttl_clock p ttl fuel cs1)) (iret_11_4__step_ttl_clock p ttl cs cs1 st)

-- ---------------------------------------------------------------------
-- The invariant through actions, firings and pumps
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
rarc_5_6_7__do_action_tms_unfold : (p : Lcyc_3_2_1__program) -> (r : Nat) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) ->
                                   (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                   (wm1 : Rarc_5_6_4__wm) -> (tables1 : List (List Iret_11__tok)) ->
                                   rarc_5_6_7__do_action p (tfacts tok) a (MkState wm tables) = MkState wm1 tables1 ->
                                   rarc_5_6_7__do_action_tms p r tok a (MkTms (MkState wm tables) rows)
                                     = iret_12_2__phase p (MkTms (MkState wm1 tables1) (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows))
rarc_5_6_7__do_action_tms_unfold p r tok a wm tables rows wm1 tables1 da with (rarc_5_6_7__do_action p (tfacts tok) a (MkState wm tables))
  rarc_5_6_7__do_action_tms_unfold p r tok a wm tables rows wm1 tables1 da | (MkState w t) =
    let (we, te) = rarc_5_6_5__state_inj da in rewrite we in rewrite te in Refl

--@derives [IRET.12.2]
||| The cascade only removes facts.
iret_12_2__phase_n_facts_sub : (n : Nat) -> (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                               (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                               iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                               (f : Lfac_1_7_1__fact) -> Elem f wm' -> Elem f wm
iret_12_2__phase_n_facts_sub Z p wm tables rows wm' tables' rows' eq f ef =
  let (se, _) = iret_12__tms_inj eq in let (we, _) = rarc_5_6_5__state_inj se in replace {p = \w => Elem f w} (sym we) ef
iret_12_2__phase_n_facts_sub (S n) p wm tables rows wm' tables' rows' eq f ef with (iret_12_2__phase_step p (MkTms (MkState wm tables) rows)) proof ps
  iret_12_2__phase_n_facts_sub (S n) p wm tables rows wm' tables' rows' eq f ef | (MkTms (MkState wm1 tables1) rows1) =
    iret_12_2__phase_facts_sub p wm tables rows wm1 tables1 rows1 ps f (iret_12_2__phase_n_facts_sub n p wm1 tables1 rows1 wm' tables' rows' eq f ef)

--@derives [IRET.4.3]
||| The deadline table through one core action: nothing minted, or the
||| fresh id minted with the emitted kind.
iret_4_3__deadlines_core : (p : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (rule : Lgra_6_1__rule) -> (tok : Iret_11__tok) -> (a : Lgra_10_1__action) ->
                           (wm, wm1 : Rarc_5_6_4__wm) -> (tables, tables1 : List (List Iret_11__tok)) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                           Either (wm1 = wm, tables1 = tables) (Rarc_5_6_7__action_shape rule (tfacts tok) a wm wm1, tables1 = rarc_5_6_5__propagate p wm1 tables) ->
                           Iret_4_3__deadlines_ok ttl wm dl c -> Iret_4_3__deadlines_ok ttl wm1 (iret_4_3__record_action ttl c tok a wm dl) c
iret_4_3__deadlines_core p ttl rule tok (Withdraw idx) wm wm1 tables tables1 dl c (Left (we, _)) dok = replace {p = \w => Iret_4_3__deadlines_ok ttl w dl c} (sym we) dok
iret_4_3__deadlines_core p ttl rule tok (Withdraw idx) wm wm1 tables tables1 dl c (Right (sh, _)) dok =
  iret_4_3__deadlines_sub ttl wm wm1 (\g, eg => case shMint sh g eg of
                                        Left x => x
                                        Right (k ** (v ** (aeq, _))) => void (iret_4_3__withdraw_not_emit aeq)) dl c dok
iret_4_3__deadlines_core p ttl rule tok (Emit k v) wm wm1 tables tables1 dl c (Left (we, _)) dok =
  iret_4_3__deadlines_mint ttl c (lfac_2_5_3__fresh_id (iret_11_3__ids tok) wm) k wm wm1 dl (fst (lfac_2_5_3__fresh_id_free (iret_11_3__ids tok) wm))
    (\g, eg => Left (replace {p = \w => Elem g w} we eg)) dok
iret_4_3__deadlines_core p ttl rule tok (Emit k v) wm wm1 tables tables1 dl c (Right (sh, _)) dok =
  iret_4_3__deadlines_mint ttl c (lfac_2_5_3__fresh_id (iret_11_3__ids tok) wm) k wm wm1 dl (fst (lfac_2_5_3__fresh_id_free (iret_11_3__ids tok) wm))
    (\g, eg => case shMint sh g eg of
       Left x => Left x
       Right (k' ** (v' ** (aeq, geq))) => let (ke, _) = iret_4_3__emit_inj aeq in Right (cong fid geq, trans (cong fkind geq) (sym ke)))
    dok

--@derives [RARC.5.6.7]
||| One action with the deadline table keeps the firing invariant and the
||| deadline table's well-formedness.
rarc_5_6_7__action_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                             (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                             (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                             (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                             Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Iret_4_3__deadlines_ok ttl wm dl c ->
                             (wm' ** (tables' ** (rows' **
                               ( rarc_5_6_7__do_action_ttl p ttl r tok a (MkClocked (MkTms (MkState wm tables) rows) dl c)
                                   = MkClocked (MkTms (MkState wm' tables') rows') (iret_4_3__record_action ttl c tok a wm dl) c
                               , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                               , Iret_4_3__deadlines_ok ttl wm' (iret_4_3__record_action ttl c tok a wm dl) c ))))
rarc_5_6_7__action_ttl_inv p pos ttl dom range r rule nr tok bk bd a ea wm tables rows dl c finv dok =
  case iret_12_2__action_cascade p pos dom range r rule nr tok bk bd a ea wm tables rows finv of
    (wm1 ** (tables1 ** (wmF ** (tablesF ** (rowsF ** (da, eq, _, _, finvF)))))) =>
      let (_, shape) = rarc_5_6_7__action_core p dom range r rule nr (tfacts tok) bk bd a ea wm tables (runCore (fireRun finv)) (runUniq (fireRun finv)) wm1 tables1 da
      in let dok1 : Iret_4_3__deadlines_ok ttl wm1 (iret_4_3__record_action ttl c tok a wm dl) c
             dok1 = iret_4_3__deadlines_core p ttl rule tok a wm wm1 tables tables1 dl c shape dok
             phEq : (iret_12_2__phase p (MkTms (MkState wm1 tables1) (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)) = MkTms (MkState wmF tablesF) rowsF)
             phEq = trans (sym (rarc_5_6_7__do_action_tms_unfold p r tok a wm tables rows wm1 tables1 da)) eq
             sub : (f : Lfac_1_7_1__fact) -> Elem f wmF -> Elem f wm1
             sub = iret_12_2__phase_n_facts_sub (S (length (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows))) p wm1 tables1
                     (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) wmF tablesF rowsF phEq
         in (wmF ** (tablesF ** (rowsF ** (cong (\s => MkClocked s (iret_4_3__record_action ttl c tok a wm dl) c) eq, finvF, iret_4_3__deadlines_sub ttl wm1 wmF sub _ c dok1))))

--@derives [RARC.5.6.7]
||| The whole RHS keeps them.
rarc_5_6_7__actions_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) -> Lcyc_3_1_1__range p dom ->
                              (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                              (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                              (as : List Lgra_10_1__action) -> All (\a => Elem a (actions rule)) as ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                              Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Iret_4_3__deadlines_ok ttl wm dl c ->
                              (wm' ** (tables' ** (rows' ** (dl' **
                                ( rarc_5_6_7__do_actions_ttl p ttl r tok as (MkClocked (MkTms (MkState wm tables) rows) dl c) = MkClocked (MkTms (MkState wm' tables') rows') dl' c
                                , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                                , Iret_4_3__deadlines_ok ttl wm' dl' c )))))
rarc_5_6_7__actions_ttl_inv p pos ttl dom range r rule nr tok bk bd [] [] wm tables rows dl c finv dok = (wm ** (tables ** (rows ** (dl ** (Refl, finv, dok)))))
rarc_5_6_7__actions_ttl_inv p pos ttl dom range r rule nr tok bk bd (a :: as) (ea :: eas) wm tables rows dl c finv dok =
  case rarc_5_6_7__action_ttl_inv p pos ttl dom range r rule nr tok bk bd a ea wm tables rows dl c finv dok of
    (wm1 ** (tables1 ** (rows1 ** (eq1, finv1, dok1)))) =>
      case rarc_5_6_7__actions_ttl_inv p pos ttl dom range r rule nr tok bk bd as eas wm1 tables1 rows1 (iret_4_3__record_action ttl c tok a wm dl) c finv1 dok1 of
        (wm2 ** (tables2 ** (rows2 ** (dl2 ** (eq2, finv2, dok2))))) =>
          (wm2 ** (tables2 ** (rows2 ** (dl2 **
            ( trans (rarc_5_6_7__actions_ttl_succ p ttl r tok a as (MkClocked (MkTms (MkState wm tables) rows) dl c) (MkTms (MkState wm1 tables1) rows1)
                       (iret_4_3__record_action ttl c tok a wm dl) c eq1) eq2
            , finv2, dok2 )))))

--@derives [IRET.11.4]
||| One firing with the deadline table keeps the invariant and the clock.
iret_11_4__step_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                          ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                          Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> Iret_4_3__deadlines_ok ttl wm dl c ->
                          (cs' : Iret_19_3__clocked) -> iret_11_4__step_ttl p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) = Just cs' ->
                          (Iret_19_3__inv p ttl dom cs', clock cs' = c)
iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq with (ldet_5_1__select_next tables) proof sel
  iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | Nothing = void (absurd (sym eq))
  iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | (Just (r, j)) | Nothing = void (absurd (sym eq))
    iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r tables)) proof ntok
      iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | (Just (r, j)) | (Just rule) | Nothing = void (absurd (sym eq))
      iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, _))) = ldet_5_1__select_next_pending tables r j sel
        in let njtok : (rarc_5_6_5__nth j ts = Just tok)
               njtok = replace {p = \tbl => rarc_5_6_5__nth j tbl = Just tok} (iret_11__table_at_nth r tables ts nt) ntok
               okTok : Iret_7_4__tok_ok rule dom tok
               okTok = lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok)
        in case rarc_5_6_7__actions_ttl_inv p pos ttl dom (lcyc_3_1_1__range_widen p (tmsLits ct) dom litsIn (tmsRange ct)) r rule nr tok (fst okTok) (snd okTok)
                  (actions rule) (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                  wm (idat_6_2_2__mark_fired r j tables) rows dl c (iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njtok) dok of
             (wm' ** (tables' ** (rows' ** (dl' ** (eq', finv', dok'))))) =>
               let csEq : (cs' = MkClocked (MkTms (MkState wm' tables') rows') dl' c)
                   csEq = trans (sym (iret_11_4__just_inj eq)) eq'
                   es : (iret_11_4__step_tms p (MkTms (MkState wm tables) rows) = Just (engine cs'))
                   es = trans (iret_11_4__step_tms_unfold p wm tables rows r j rule tok sel nr ntok)
                              (cong Just (trans (sym (rarc_5_6_7__actions_ttl_engine p ttl r tok (actions rule) (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows) dl c)))
                                                (cong (\s => engine s) (iret_11_4__just_inj eq))))
               in let (_, _, rk') = lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk (engine cs') es
               in replace {p = \x => (Iret_19_3__inv p ttl dom x, clock x = c)} (sym csEq)
                    ((fireRun finv', replace {p = \x => Iret_12_4__run_kind_s p (engine x)} csEq rk', dok'), Refl)

--@derives [IRET.11.4]
||| A pump with the deadline table keeps the invariant and the clock,
||| however it halts.
iret_11_4__run_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                         ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                         (fuel : Nat) -> (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                         (Iret_19_3__inv p ttl dom (fst (iret_11_4__run_ttl p ttl fuel cs)), clock (fst (iret_11_4__run_ttl p ttl fuel cs)) = clock cs)
iret_11_4__run_ttl_inv p pos ct ttl dom litsIn Z cs inv = (inv, Refl)
iret_11_4__run_ttl_inv p pos ct ttl dom litsIn (S fuel) (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok)
  with (iret_11_4__step_ttl p ttl (MkClocked (MkTms (MkState wm tables) rows) dl c)) proof st
  iret_11_4__run_ttl_inv p pos ct ttl dom litsIn (S fuel) (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) | Nothing = ((rinv, rk, dok), Refl)
  iret_11_4__run_ttl_inv p pos ct ttl dom litsIn (S fuel) (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) | (Just cs1)
    with (iret_11_4__run_ttl p ttl fuel cs1) proof r1
    iret_11_4__run_ttl_inv p pos ct ttl dom litsIn (S fuel) (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) | (Just cs1) | (t1, h1, n1) =
      let (inv1, ce1) = iret_11_4__step_ttl_inv p pos ct ttl dom litsIn wm tables rows dl c rinv rk dok cs1 st
      in let (inv2, ce2) = iret_11_4__run_ttl_inv p pos ct ttl dom litsIn fuel cs1 inv1
      in ( replace {p = \x => Iret_19_3__inv p ttl dom (fst x)} r1 inv2
         , trans (replace {p = \x => clock (fst x) = clock cs1} r1 ce2) ce1 )

-- ---------------------------------------------------------------------
-- The sweep and the clock advance
-- ---------------------------------------------------------------------

--@derives [IRET.19.3]
||| The sweep's cascade: the engine's invariants hold after, the facts
||| only shrink, and explicit-kind facts among the survivors of the
||| retraction are kept.
iret_19_3__sweep_cascade : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                           (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                           Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> (gone : List Nat) ->
                           (wmF ** (tablesF ** (rowsF **
                             ( iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids gone wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables)) rows)
                                 = MkTms (MkState wmF tablesF) rowsF
                             , Iret_12__run_inv p dom wmF tablesF rowsF
                             , Iret_12_4__run_kind p wmF rowsF
                             , (f : Lfac_1_7_1__fact) -> Elem f wmF -> Elem f (iret_12_2__retract_ids gone wm)
                             , (f : Lfac_1_7_1__fact) -> Elem f (iret_12_2__retract_ids gone wm) -> life p (fkind f) = Explicit -> Elem f wmF ))))
iret_19_3__sweep_cascade p pos dom wm tables rows rinv rk gone =
  iret_12_2__external_cascade p pos dom wm tables rows rinv rk (iret_12_2__retract_ids gone wm)
    (lcyc_1_1__all_filter (\g => not (rarc_5_6_5__elem (fid g) gone)) wm (wmDom (runCore rinv)))
    (iret_4_4__keeps_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))
    (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (rarc_5_6_5__elem (fid h) gone)) wm eg)))
    (iret_4_4__unique_filter wm (runUniq rinv) (\g => not (rarc_5_6_5__elem (fid g) gone)))

--@derives [IRET.22.6]
||| A fact whose deadline is after the clock is not among the sweep's retractions.
iret_22_6__not_expired : (dl : Iret_4_3__deadlines) -> (c : Nat) -> ((i, t, t' : Nat) -> Elem (i, t) dl -> Elem (i, t') dl -> t = t') ->
                         (i, t : Nat) -> Elem (i, t) dl -> iret_12__lte_b t c = False -> rarc_5_6_5__elem i (iret_19_3__expired c dl) = False
iret_22_6__not_expired dl c uq i t e late = iret_12__bool_false_of _ (\inExp =>
  let (x ** (ex, xi)) = lcyc_1_1__elem_map_inv fst (filter (\e => iret_12__lte_b (snd e) c) dl) (lcyc_1_1__elem_l_elem i _ inExp)
  in let (ex', early) = lcyc_1_1__elem_filter_inv (\e => iret_12__lte_b (snd e) c) dl ex
  in let ex'' : Elem (i, snd x) dl
         ex'' = replace {p = \y => Elem y dl} (trans (sym (lcyc_1_1__pair_eta x)) (cong (\j => (j, snd x)) xi)) ex'
  in lcyc_1_1__bool_not_both _ (replace {p = \u => iret_12__lte_b u c = True} (uq i (snd x) t ex'' e) early) late)

--@derives [IRET.22.6]
||| FACT NOT RETRACTED BEFORE ITS DEADLINE. A live TTL fact whose deadline
||| is after the clock is live after the sweep: the sweep skips it, since
||| its deadline row is unique and later, and the cascade retracts only
||| `logical` facts, which a TTL fact is not.
iret_22_6__not_before_deadline : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> Lfac_1_3_5__ttl_explicit p ttl -> (dom : List (Nat, Nat)) ->
                                 (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                 Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows -> Iret_4_3__deadlines_ok ttl wm dl c ->
                                 (f : Lfac_1_7_1__fact) -> (t : Nat) -> Elem f wm -> Not (ttl (fkind f) = 0) -> Elem (fid f, t) dl -> LT c t ->
                                 Elem f (core (engine (rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c)))).wm
iret_22_6__not_before_deadline p pos ttl tex dom wm tables rows dl c rinv rk dok f t ef nz e late =
  case iret_19_3__sweep_cascade p pos dom wm tables rows rinv rk (iret_19_3__expired c dl) of
    (wmF ** (tablesF ** (rowsF ** (eq, _, _, _, kept)))) =>
      let survives : Elem f (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
          survives = lcyc_1_1__elem_filter_fwd (\g => not (rarc_5_6_5__elem (fid g) (iret_19_3__expired c dl))) wm ef
                       (iret_12__not_false _ (iret_22_6__not_expired dl c (dlUnique dok) (fid f) t e (iret_12__lt_lte_b_false t c late)))
      in replace {p = \x => Elem f (core x).wm} (sym eq) (kept f survives (tex (fkind f) nz))

--@derives [IRET.22.6]
||| FACT RETRACTED AT OR AFTER ITS DEADLINE ON THE NEXT TICK. After the
||| sweep at clock c, every live fact's deadline is after c: whatever had
||| expired is gone, in one batch.
iret_22_6__at_or_after_deadline : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (dom : List (Nat, Nat)) ->
                                  (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                  Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                                  (f : Lfac_1_7_1__fact) -> (t : Nat) -> Elem f (core (engine (rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c)))).wm ->
                                  Elem (fid f, t) dl -> LT c t
iret_22_6__at_or_after_deadline p pos dom wm tables rows dl c rinv rk f t ef e =
  case iret_19_3__sweep_cascade p pos dom wm tables rows rinv rk (iret_19_3__expired c dl) of
    (wmF ** (tablesF ** (rowsF ** (eq, _, _, sub, _)))) =>
      let ef' : Elem f (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
          ef' = sub f (replace {p = \x => Elem f (core x).wm} eq ef)
      in let (_, ne) = lcyc_1_1__elem_filter_inv (\g => not (rarc_5_6_5__elem (fid g) (iret_19_3__expired c dl))) wm ef'
      in iret_12__lte_b_false_lt t c (iret_12__bool_false_of _ (\early =>
           lcyc_1_1__bool_not_both _
             (lcyc_1_1__elem_l_true (fid f) _ (lcyc_1_1__elem_map_fwd fst (lcyc_1_1__elem_filter_fwd (\e => iret_12__lte_b (snd e) c) dl e early)))
             (lcyc_1_1__not_true_is_false _ ne)))

--@derives [IRET.22.6]
||| THE RETRACTION CASCADES: the sweep's retraction is propagated through
||| the network and followed by the truth-maintenance cascade, by
||| construction.
iret_22_6__cascade : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                     engine (rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c))
                       = iret_12_2__phase p (MkTms (MkState (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
                                                            (rarc_5_6_5__propagate p (iret_12_2__retract_ids (iret_19_3__expired c dl) wm) tables)) rows)
iret_22_6__cascade p wm tables rows dl c = Refl

--@derives [RARC.5.6.3]
||| The sweep keeps the invariant, and re-establishes that every live
||| deadline is in the future, whatever the clock was set to.
rarc_5_6_3__sweep_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                        (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                        Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                        ((i, t, t' : Nat) -> Elem (i, t) dl -> Elem (i, t') dl -> t = t') ->
                        ((f : Lfac_1_7_1__fact) -> Elem f wm -> Not (ttl (fkind f) = 0) -> (t : Nat ** Elem (fid f, t) dl)) ->
                        ((f : Lfac_1_7_1__fact) -> Elem f wm -> ttl (fkind f) = 0 -> (t : Nat) -> Not (Elem (fid f, t) dl)) ->
                        (Iret_19_3__inv p ttl dom (rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c)), clock (rarc_5_6_3__sweep p (MkClocked (MkTms (MkState wm tables) rows) dl c)) = c)
rarc_5_6_3__sweep_inv p pos ttl dom wm tables rows dl c rinv rk uq stamped plain =
  case iret_19_3__sweep_cascade p pos dom wm tables rows rinv rk (iret_19_3__expired c dl) of
    (wmF ** (tablesF ** (rowsF ** (eq, rinvF, rkF, sub, _)))) =>
      let sub' : (f : Lfac_1_7_1__fact) -> Elem f wmF -> Elem f wm
          sub' f e = fst (lcyc_1_1__elem_filter_inv (\g => not (rarc_5_6_5__elem (fid g) (iret_19_3__expired c dl))) wm (sub f e))
          dokF : Iret_4_3__deadlines_ok ttl wmF dl c
          dokF = MkDeadlinesOk uq (\f, e, nz => stamped f (sub' f e) nz) (\f, e, z, t, ne => plain f (sub' f e) z t ne)
                   (\f, t, e, et => iret_22_6__at_or_after_deadline p pos dom wm tables rows dl c rinv rk f t
                                      (replace {p = \x => Elem f (core x).wm} (sym eq) e) et)
      in (replace {p = \x => Iret_19_3__inv p ttl dom (MkClocked x dl c)} (sym eq) (rinvF, rkF, dokF), Refl)

--@derives [RARC.5.6.3]
||| The clock only advances.
rarc_5_6_3__advance_lte : (t : Nat) -> (cs : Iret_19_3__clocked) -> LTE (clock cs) (clock (rarc_5_6_3__advance t cs))
rarc_5_6_3__advance_lte t (MkClocked s dl c) with (iret_12__lte_b c t) proof le
  rarc_5_6_3__advance_lte t (MkClocked s dl c) | True = iret_12__lte_b_true_lte c t le
  rarc_5_6_3__advance_lte t (MkClocked s dl c) | False = reflexive {x = c}

--@derives [RARC.5.6.3]
||| Advancing then sweeping keeps the invariant: the advance touches only
||| the clock, the sweep restores the future-deadline part.
rarc_5_6_3__tick_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                       (t : Nat) -> (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                       Iret_19_3__inv p ttl dom (rarc_5_6_3__sweep p (rarc_5_6_3__advance t cs))
rarc_5_6_3__tick_inv p pos ttl dom t (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) with (iret_12__lte_b c t)
  rarc_5_6_3__tick_inv p pos ttl dom t (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) | True =
    fst (rarc_5_6_3__sweep_inv p pos ttl dom wm tables rows dl t rinv rk (dlUnique dok) (dlStamped dok) (dlPlain dok))
  rarc_5_6_3__tick_inv p pos ttl dom t (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) | False =
    fst (rarc_5_6_3__sweep_inv p pos ttl dom wm tables rows dl c rinv rk (dlUnique dok) (dlStamped dok) (dlPlain dok))

--@derives [RARC.5.6.3]
||| Sweeping at the current clock keeps the invariant.
rarc_5_6_3__sweep_here_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                             (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs -> (Iret_19_3__inv p ttl dom (rarc_5_6_3__sweep p cs), clock (rarc_5_6_3__sweep p cs) = clock cs)
rarc_5_6_3__sweep_here_inv p pos ttl dom (MkClocked (MkTms (MkState wm tables) rows) dl c) (rinv, rk, dok) =
  rarc_5_6_3__sweep_inv p pos ttl dom wm tables rows dl c rinv rk (dlUnique dok) (dlStamped dok) (dlPlain dok)

-- ---------------------------------------------------------------------
-- Data events with the deadline table
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.4]
||| Applying a data event keeps the invariant and the clock: an adapter
||| assert mints the fresh id and stamps it; a retraction only removes.
rarc_5_6_4__apply_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                            (ev : Rarc_5_6_1__event) -> Rarc_5_6_1__event_in_dom dom ev ->
                            (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                            (Iret_19_3__inv p ttl dom (rarc_5_6_4__apply_ttl p ttl ev cs), clock (rarc_5_6_4__apply_ttl p ttl ev cs) = clock cs)
rarc_5_6_4__apply_ttl_inv p pos ttl dom (Assert k key pay) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok)
  with (iret_19_1__assert_fact (life p k) [] k key pay w) proof af
  rarc_5_6_4__apply_ttl_inv p pos ttl dom (Assert k key pay) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok) | Nothing =
    ((rinv, rk, iret_4_3__deadlines_mint ttl c (lfac_2_5_3__fresh_id [] w) k w w dl (fst (lfac_2_5_3__fresh_id_free [] w)) (\g, eg => Left eg) dok), Refl)
  rarc_5_6_4__apply_ttl_inv p pos ttl dom (Assert k key pay) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok) | (Just wm1) =
    let (fresh, _) = lfac_2_5_3__fresh_id_free [] w
    in case iret_19_1__emit_shape (life p k) [] k key pay w wm1 af of
         Left eq =>
           case iret_12_2__external_cascade p pos dom w tables rows rinv rk wm1
                  (replace {p = \x => All (\f => Elem (lfac_2_5_1__val f) dom) x} (sym eq) (lcyc_1_1__all_append (wmDom (runCore rinv)) [inDom]))
                  (replace {p = \x => Iret_4_4__keeps w x} (sym eq) (iret_4_4__keeps_append w _))
                  (replace {p = \x => (g : Lfac_1_7_1__fact) -> Elem g x -> Either (Elem g w) (rarc_5_6_4__is_live (fid g) w = False)} (sym eq)
                     (\g, eg => case lcyc_1_1__elem_append_inv w eg of
                        Left e => Left e
                        Right e1 => Right (replace {p = \x => rarc_5_6_4__is_live (fid x) w = False} (sym (iret_12__elem_singleton e1)) fresh)))
                  (replace {p = \x => Iret_4_4__unique x} (sym eq) (iret_4_4__unique_append w (runUniq rinv) _ fresh)) of
             (wmF ** (tablesF ** (rowsF ** (eq', rinvF, rkF, sub, _)))) =>
               let mint : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g w) (fid g = lfac_2_5_3__fresh_id [] w, fkind g = k)
                   mint g eg = case lcyc_1_1__elem_append_inv w (replace {p = \x => Elem g x} eq eg) of
                     Left e => Left e
                     Right e1 => Right (cong fid (iret_12__elem_singleton e1), cong fkind (iret_12__elem_singleton e1))
               in ( replace {p = \x => Iret_19_3__inv p ttl dom (MkClocked x (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] w) k dl) c)} (sym eq')
                      (rinvF, rkF, iret_4_3__deadlines_sub ttl wm1 wmF sub _ c (iret_4_3__deadlines_mint ttl c (lfac_2_5_3__fresh_id [] w) k w wm1 dl fresh mint dok))
                  , Refl )
         Right (old ** (_, eq)) =>
           case iret_12_2__external_cascade p pos dom w tables rows rinv rk wm1
                  (replace {p = \x => All (\f => Elem (lfac_2_5_1__val f) dom) x} (sym eq)
                     (lcyc_1_1__all_append (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g old)) w (wmDom (runCore rinv))) [inDom]))
                  (replace {p = \x => Iret_4_4__keeps w x} (sym eq) (iret_4_4__keeps_replace w (runUniq rinv) old _ fresh))
                  (replace {p = \x => (g : Lfac_1_7_1__fact) -> Elem g x -> Either (Elem g w) (rarc_5_6_4__is_live (fid g) w = False)} (sym eq)
                     (\g, eg => case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old w) eg of
                        Left e => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) w e))
                        Right e1 => Right (replace {p = \x => rarc_5_6_4__is_live (fid x) w = False} (sym (iret_12__elem_singleton e1)) fresh)))
                  (replace {p = \x => Iret_4_4__unique x} (sym eq) (iret_4_4__unique_replace w (runUniq rinv) old _ fresh)) of
             (wmF ** (tablesF ** (rowsF ** (eq', rinvF, rkF, sub, _)))) =>
               let mint : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g w) (fid g = lfac_2_5_3__fresh_id [] w, fkind g = k)
                   mint g eg = case lcyc_1_1__elem_append_inv (rarc_5_6_4__remove_exact old w) (replace {p = \x => Elem g x} eq eg) of
                     Left e => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h old)) w e))
                     Right e1 => Right (cong fid (iret_12__elem_singleton e1), cong fkind (iret_12__elem_singleton e1))
               in ( replace {p = \x => Iret_19_3__inv p ttl dom (MkClocked x (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] w) k dl) c)} (sym eq')
                      (rinvF, rkF, iret_4_3__deadlines_sub ttl wm1 wmF sub _ c (iret_4_3__deadlines_mint ttl c (lfac_2_5_3__fresh_id [] w) k w wm1 dl fresh mint dok))
                  , Refl )
rarc_5_6_4__apply_ttl_inv p pos ttl dom (Retract i) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok)
  with (rarc_5_6_4__lookup_fact i w) proof lk
  rarc_5_6_4__apply_ttl_inv p pos ttl dom (Retract i) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok) | Nothing = ((rinv, rk, dok), Refl)
  rarc_5_6_4__apply_ttl_inv p pos ttl dom (Retract i) inDom (MkClocked (MkTms (MkState w tables) rows) dl c) (rinv, rk, dok) | (Just f) =
    case iret_12_2__external_cascade p pos dom w tables rows rinv rk (rarc_5_6_4__remove_exact f w)
           (lcyc_1_1__all_filter (\g => not (lfac_2_5_4__same_fact g f)) w (wmDom (runCore rinv)))
           (iret_4_4__keeps_filter w (runUniq rinv) (\g => not (lfac_2_5_4__same_fact g f)))
           (\g, eg => Left (fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) w eg)))
           (iret_4_4__unique_filter w (runUniq rinv) (\g => not (lfac_2_5_4__same_fact g f))) of
      (wmF ** (tablesF ** (rowsF ** (eq', rinvF, rkF, sub, _)))) =>
        ( replace {p = \x => Iret_19_3__inv p ttl dom (MkClocked x dl c)} (sym eq')
            (rinvF, rkF, iret_4_3__deadlines_sub ttl w wmF (\g, eg => fst (lcyc_1_1__elem_filter_inv (\h => not (lfac_2_5_4__same_fact h f)) w (sub g eg))) dl c dok)
        , Refl )

-- ---------------------------------------------------------------------
-- Boundaries and canonical replays with ticks
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.3]
||| The loop's steps before firing keep the invariant, and never turn the
||| clock back.
rarc_5_6_3__prepare_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                          (inp : Rarc_5_6_2__input) -> Rarc_5_6_2__input_in_dom dom inp -> (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                          (Iret_19_3__inv p ttl dom (rarc_5_6_3__prepare p ttl inp cs), LTE (clock cs) (clock (rarc_5_6_3__prepare p ttl inp cs)))
rarc_5_6_3__prepare_inv p pos ttl dom (Tick t) _ cs inv =
  ( rarc_5_6_3__tick_inv p pos ttl dom t cs inv
  , replace {p = \x => LTE (clock cs) x} (sym (sweepClock (rarc_5_6_3__advance t cs))) (rarc_5_6_3__advance_lte t cs) )
  where
    sweepClock : (s : Iret_19_3__clocked) -> clock (rarc_5_6_3__sweep p s) = clock s
    sweepClock (MkClocked (MkTms (MkState wm tables) rows) dl c) = Refl
rarc_5_6_3__prepare_inv p pos ttl dom (Data ev) evd cs inv =
  let (inv1, ce1) = rarc_5_6_3__sweep_here_inv p pos ttl dom cs inv
  in let (inv2, ce2) = rarc_5_6_4__apply_ttl_inv p pos ttl dom ev evd (rarc_5_6_3__sweep p cs) inv1
  in (inv2, replace {p = \x => LTE (clock cs) x} (sym (trans ce2 ce1)) (reflexive {x = clock cs}))

--@derives [RARC.5.6.3]
||| THE CLOCK NEVER RUNS BACKWARDS: across a boundary it only advances.
rarc_5_6_3__clock_monotone : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                             (fuel : Nat) -> (inp : Rarc_5_6_2__input) -> Rarc_5_6_2__input_in_dom dom inp -> (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                             LTE (clock cs) (clock (lfst_9_2_1__boundary_ttl p ttl fuel inp cs))
rarc_5_6_3__clock_monotone p pos ttl dom fuel inp inpd cs inv =
  replace {p = \x => LTE (clock cs) x} (sym (iret_11_4__pump_ttl_clock p ttl fuel (rarc_5_6_3__prepare p ttl inp cs))) (snd (rarc_5_6_3__prepare_inv p pos ttl dom inp inpd cs inv))

--@derives [LFST.9.2.1]
||| One boundary with ticks keeps the invariant.
lfst_9_2_1__boundary_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                               ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                               (fuel : Nat) -> (inp : Rarc_5_6_2__input) -> Rarc_5_6_2__input_in_dom dom inp -> (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                               Iret_19_3__inv p ttl dom (lfst_9_2_1__boundary_ttl p ttl fuel inp cs)
lfst_9_2_1__boundary_ttl_inv p pos ct ttl dom litsIn fuel inp inpd cs inv =
  fst (iret_11_4__run_ttl_inv p pos ct ttl dom litsIn fuel (rarc_5_6_3__prepare p ttl inp cs) (fst (rarc_5_6_3__prepare_inv p pos ttl dom inp inpd cs inv)))

--@derives [LFST.9.2.1]
||| A canonical replay with ticks keeps the invariant to its end.
export
lfst_9_2_1__canonical_ttl_inv : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                                ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                (cs : Iret_19_3__clocked) -> (inps : List Rarc_5_6_2__input) -> (cs' : Iret_19_3__clocked) ->
                                Lfst_9_2_1__canonical_ttl p ttl cs inps cs' -> All (Rarc_5_6_2__input_in_dom dom) inps -> Iret_19_3__inv p ttl dom cs -> Iret_19_3__inv p ttl dom cs'
lfst_9_2_1__canonical_ttl_inv p pos ct ttl dom litsIn cs [] cs CanonTtlNil [] inv = inv
lfst_9_2_1__canonical_ttl_inv p pos ct ttl dom litsIn cs (inp :: inps) cs' (CanonTtlStep fuel _ rest) (inpd :: inpds) inv =
  lfst_9_2_1__canonical_ttl_inv p pos ct ttl dom litsIn (lfst_9_2_1__boundary_ttl p ttl fuel inp cs) inps cs' rest inpds
    (lfst_9_2_1__boundary_ttl_inv p pos ct ttl dom litsIn fuel inp inpd cs inv)

--@derives [RARC.5.6.6]
||| The pump with the deadline table quiesces for a certified positive program.
rarc_5_6_6__pump_ttl_quiesces : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                                ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs ->
                                (fuel : Nat ** (fst (snd (iret_11_4__run_ttl p ttl fuel cs)) = Quiescent, Iret_19_3__inv p ttl dom (fst (iret_11_4__run_ttl p ttl fuel cs))))
rarc_5_6_6__pump_ttl_quiesces p pos ct ttl dom litsIn cs (rinv, rk, dok) =
  let (n ** (quiet, _, _)) = rarc_5_6_6__pump_quiesces p pos ct dom litsIn (engine cs) rinv rk
  in (n ** (trans (snd (rarc_5_6_6__pump_ttl_engine p ttl n cs)) quiet, fst (iret_11_4__run_ttl_inv p pos ct ttl dom litsIn n cs (rinv, rk, dok))))

--@derives [LFST.9.2.1]
||| THE CANONICAL REPLAY WITH TICKS EXISTS.
lfst_9_2_1__canonical_ttl_exists : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                                   ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                   (cs : Iret_19_3__clocked) -> Iret_19_3__inv p ttl dom cs -> (inps : List Rarc_5_6_2__input) -> All (Rarc_5_6_2__input_in_dom dom) inps ->
                                   (cs' ** (Lfst_9_2_1__canonical_ttl p ttl cs inps cs', Iret_19_3__inv p ttl dom cs'))
lfst_9_2_1__canonical_ttl_exists p pos ct ttl dom litsIn cs inv [] [] = (cs ** (CanonTtlNil, inv))
lfst_9_2_1__canonical_ttl_exists p pos ct ttl dom litsIn cs inv (inp :: inps) (inpd :: inpds) =
  let inv1 = fst (rarc_5_6_3__prepare_inv p pos ttl dom inp inpd cs inv)
  in let (fuel ** (quiet, inv2)) = rarc_5_6_6__pump_ttl_quiesces p pos ct ttl dom litsIn (rarc_5_6_3__prepare p ttl inp cs) inv1
  in let (cs' ** (rest, inv')) = lfst_9_2_1__canonical_ttl_exists p pos ct ttl dom litsIn (lfst_9_2_1__boundary_ttl p ttl fuel inp cs) inv2 inps inpds
  in (cs' ** (CanonTtlStep fuel quiet rest, inv'))

--@derives [LFST.9.2.1]
--@derives [IRET.19.3]
||| FROM THE INPUT, with the start clock: a certified positive program
||| replays any canonical stream with ticks from any input with unique
||| ids, every pump quiescent, the clocked invariant at every boundary.
export
lfst_9_2_1__canonical_ttl_from_input : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (ttl : Iret_4_2__ttl) -> (dom : List (Nat, Nat)) ->
                                       ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                       (wm0 : Rarc_5_6_4__wm) -> All (\f => Elem (lfac_2_5_1__val f) dom) wm0 -> Iret_4_4__unique wm0 -> (c0 : Nat) ->
                                       (inps : List Rarc_5_6_2__input) -> All (Rarc_5_6_2__input_in_dom dom) inps ->
                                       (cs' ** ( Lfst_9_2_1__canonical_ttl p ttl (MkClocked (rarc_5_6_5__init_tms p wm0) (iret_4_3__init ttl c0 wm0) c0) inps cs'
                                               , Iret_19_3__inv p ttl dom cs' ))
lfst_9_2_1__canonical_ttl_from_input p pos ct ttl dom litsIn wm0 wd uniq c0 inps inpds =
  lfst_9_2_1__canonical_ttl_exists p pos ct ttl dom litsIn (MkClocked (rarc_5_6_5__init_tms p wm0) (iret_4_3__init ttl c0 wm0) c0)
    ( rarc_5_6_5__init_tms_inv p dom wm0
        (lcyc_1_1__inv_widen p (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) dom widen (rarc_5_6_5__init_state p wm0)
           (lcyc_1_1__init_inv p (lcyc_3_1_1__tms_to_core p ct) wm0))
        uniq
    , \row, e => absurd e
    , iret_4_3__init_ok ttl c0 wm0 uniq )
    inps inpds
  where
    widen : (x : (Nat, Nat)) -> Elem x (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) -> Elem x dom
    widen x e = case lcyc_1_1__elem_append_inv (tmsLits ct) e of
      Left l => litsIn x l
      Right r => case lcyc_1_1__elem_map_inv (\f => lfac_2_5_1__val f) wm0 r of
        (f ** (ef, eq)) => replace {p = \v => Elem v dom} eq (lcyc_1_1__all_lookup wd ef)

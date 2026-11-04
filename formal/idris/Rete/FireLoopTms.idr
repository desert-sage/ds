-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The truth-maintenance system inside the fire loop: Rete/FireLoop.idr's
||| deterministic engine, plus the dependency table of [IRET.12.4] and the
||| justification bookkeeping of [IRET.12.1] / [IRET.12.2], layered on top
||| so that nothing already proved about the core engine moves.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| Elements are named under the clause they formalize: the table and its
||| rows under [IRET.12.4], recording under [IRET.10.2] / [IRET.12.1],
||| the end of an activation under [IRET.7.8], the count and the
||| retraction under [IRET.12.2] / [IRET.4.5], the dispatch and the loop
||| under the same RARC.5.6.7 / [IRET.11.4] clauses as the core.
|||
||| WHAT IS MODELLED, and the clause each choice is read from:
|||
|||   * THE TABLE. A row per (rule, token identity, fact id): the
|||     activation is the (rule, token) pair of [IRET.11], the fact is one
|||     its RHS emitted into a `logical` schema [IRET.12.4]. A logical emit
|||     adds a row whether or not the assert was a no-op, since
|||     [IRET.12.1] increments `justif_count` either way; the row targets
|||     the fact that is live afterwards, which for an entity replace is
|||     the fresh one [LFAC.2.5.3]. An explicit emit adds nothing
|||     [IRET.8.3].
|||   * AN ACTIVATION ENDS when its token is no longer in its rule's table
|||     fired and unblocked: dropped because a constituent was retracted
|||     [IRET.7.8], or blocked because a `no` pattern was broken, which
|||     [LLOG.11.5] / [LLOG.15.1] make the same ending (absence-justified
|||     semantics). A token released again fires again and justifies
|||     afresh [IDAT.6.2.2].
|||   * THE COUNT is the number of rows targeting the fact whose
|||     activation is live [IRET.12.1]. When an activation ends, the facts
|||     it supported whose count is now zero are retracted [IRET.12.2 3],
|||     all of them at once, and the retraction propagates through the
|||     core's `rarc_5_6_5__propagate`, which may end further activations:
|||     the cascade, iterated to its fixpoint. The engine does this depth
|||     first, one fact at a time; the fixpoint is the same, because a
|||     retraction creates no positive match and only ever drops or
|||     unblocks tokens.
|||   * WHEN. After every action of a firing, before the next action, on
|||     the same immediate propagation as the core. A no-op action, or a phase that ends no activation, touches
|||     nothing [IRET.11.3.2].
|||   * BASE FACTS. An input fact never justified has count zero and is
|||     never retracted: [IRET.12.2] retracts on a decrement reaching zero,
|||     not on zero. A fact that acquired a justification and lost its last
|||     one is retracted whatever its origin, which is [IRET.12.2] read
|||     literally; the model follows the text.
|||   * WITHDRAW OF A LOGICAL BINDING is a compile refusal [LLOG.11.8]. The
|||     model still has to be total when the core removes a justified
|||     fact: rows targeting a fact no longer live are dropped in the next
|||     phase. Theorems that need [LLOG.11.8] assume it as a premise.
|||
||| WHAT IS NOT MODELLED: `+nological` [IRET.8.4] (the table is simply
||| empty there, which `iret_11_4__step_n_agrees` covers), plain
||| external retract of a logical fact [IRET.19.2 3], and cross-tier
||| justification by arrival [LLOG.11.7]. Those are pump-boundary events
||| and belong to that model.
|||
||| EVALUATION SHAPE. Every loop here takes a state apart and rebuilds it
||| (`case ... of MkTms st rows => ... (MkTms st rows)`). The type-level
||| evaluator shares no work between reads of a closure, so without this a
||| four-firing witness re-ran each phase once per field read of the next
||| and did not finish; with it a run evaluates once per step.
module Rete.FireLoopTms

import Rete.FireLoop
import Rete.Refcount
import Data.List
import Data.Maybe
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- The dependency table
-- ---------------------------------------------------------------------

--@spec [IRET.12.4]
||| One dependency: the activation (rule ordinal, token identity) and the
||| logical fact it justifies.
public export
record Iret_12_4__row where
  constructor MkRow
  rrule   : Nat
  rids    : List Nat
  rtarget : Nat

public export
Eq Iret_12_4__row where
  a == b = rrule a == rrule b && rids a == rids b && rtarget a == rtarget b

public export
Show Iret_12_4__row where
  show r = "(" ++ show (rrule r) ++ "," ++ show (rids r) ++ "->" ++ show (rtarget r) ++ ")"

--@spec [IRET.12.4]
public export
Iret_12_4__table : Type
Iret_12_4__table = List Iret_12_4__row

--@spec [IRET.12.4]
||| The dependency table read as Rete/Refcount.idr's justifications: an
||| activation's antecedents are the facts its token binds, its target
||| the fact it justified. The bridge from the engine to the fixpoint
||| theorems.
public export
iret_12_4__justifs : Iret_12_4__table -> List Iret_12_1__justif
iret_12_4__justifs rows = map (\row => MkJustif (rids row) (rtarget row)) rows

--@spec [IRET.12]
||| The engine state with truth maintenance: the core state and the table.
public export
record Iret_12__state where
  constructor MkTms
  core : Rarc_5_6_5__state
  deps : Iret_12_4__table

public export
Eq Iret_12__state where
  a == b = core a == core b && deps a == deps b

public export
Show Iret_12__state where
  show s = show (core s) ++ " DEPS " ++ show (deps s)

-- ---------------------------------------------------------------------
-- Live activations and the count
-- ---------------------------------------------------------------------

--@spec [IRET.7.8]
--@spec [LLOG.11.5]
||| An activation is live while its token sits in its rule's table, fired
||| and unblocked. Dropped or blocked, it has ended.
public export
iret_7_8__activation_live : List (List Iret_11__tok) -> Iret_12_4__row -> Bool
iret_7_8__activation_live tables row =
  rarc_5_6_5__any (\t => (iret_11_3__ids t == rids row) && (fired t && not (blocked t)))
                  (iret_11__table_at (rrule row) tables)

--@spec [IRET.12.2]
||| The rows whose activation has ended, and those still live. A row
||| whose target is no longer live has nothing left to support and goes
||| with the ended ones (see the header on [LLOG.11.8]).
public export
iret_12_2__ended : Rarc_5_6_5__state -> Iret_12_4__table -> Iret_12_4__table
iret_12_2__ended st = filter (\row => not (iret_7_8__activation_live (toks st) row && rarc_5_6_4__is_live (rtarget row) (wm st)))

--@spec [IRET.12.2]
public export
iret_12_2__kept : Rarc_5_6_5__state -> Iret_12_4__table -> Iret_12_4__table
iret_12_2__kept st = filter (\row => iret_7_8__activation_live (toks st) row && rarc_5_6_4__is_live (rtarget row) (wm st))

--@spec [IRET.12.1]
||| `justif_count`: the rows of the table targeting the fact.
public export
iret_12_1__count : Iret_12_4__table -> Nat -> Nat
iret_12_1__count rows f = length (filter (\row => rtarget row == f) rows)

--@spec [IRET.12.2]
--@spec [IRET.4.5]
||| The facts an ended activation supported whose count against the
||| remaining rows is zero: [IRET.12.2] step 3, for every ending at once.
public export
iret_12_2__zeroed : Iret_12_4__table -> Iret_12_4__table -> List Nat
iret_12_2__zeroed ended kept = filter (\f => iret_12_1__count kept f == 0) (map rtarget ended)

--@spec [IRET.12.2]
||| Retract the facts with those ids.
public export
iret_12_2__retract_ids : List Nat -> Rarc_5_6_4__wm -> Rarc_5_6_4__wm
iret_12_2__retract_ids ids = filter (\f => not (rarc_5_6_5__elem (fid f) ids))

-- ---------------------------------------------------------------------
-- The cascade: one phase, iterated to its fixpoint
-- ---------------------------------------------------------------------

--@spec [IRET.12.2]
||| The end of a phase that ended something: with the surviving rows and
||| the facts to retract, either nothing to retract (the table alone
||| changes) or the retraction and its propagation.
public export
iret_12_2__phase_after : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> List (List Iret_11__tok) -> Iret_12_4__table -> List Nat -> Iret_12__state
iret_12_2__phase_after p wm tables kept [] = MkTms (MkState wm tables) kept
iret_12_2__phase_after p wm tables kept (g :: gs) =
  MkTms (MkState (iret_12_2__retract_ids (g :: gs) wm) (rarc_5_6_5__propagate p (iret_12_2__retract_ids (g :: gs) wm) tables)) kept

--@spec [IRET.12.2]
||| One phase: drop the rows of ended activations, retract what they
||| alone supported, propagate. A phase that ends nothing touches nothing.
public export
iret_12_2__phase_step : Lcyc_3_2_1__program -> Iret_12__state -> Iret_12__state
iret_12_2__phase_step p (MkTms (MkState wm tables) rows) =
  case iret_12_2__ended (MkState wm tables) rows of
    [] => MkTms (MkState wm tables) rows
    ended => iret_12_2__phase_after p wm tables (iret_12_2__kept (MkState wm tables) rows)
                                    (iret_12_2__zeroed ended (iret_12_2__kept (MkState wm tables) rows))

--@spec [IRET.12.2]
||| Iterate. Each phase's result is taken apart and rebuilt so that the
||| type-level evaluator, which shares no work between uses of a closure,
||| evaluates a phase once rather than once per field read of the next.
public export
iret_12_2__phase_n : Nat -> Lcyc_3_2_1__program -> Iret_12__state -> Iret_12__state
iret_12_2__phase_n Z p s = s
iret_12_2__phase_n (S n) p s = case iret_12_2__phase_step p s of
  MkTms st rows => iret_12_2__phase_n n p (MkTms st rows)

--@spec [IRET.12.2]
||| The cascade to its fixpoint. Fuel: a phase that changes anything drops
||| at least one row, so one more than the number of rows suffices.
public export
iret_12_2__phase : Lcyc_3_2_1__program -> Iret_12__state -> Iret_12__state
iret_12_2__phase p s = iret_12_2__phase_n (S (length (deps s))) p s

-- ---------------------------------------------------------------------
-- Recording a justification
-- ---------------------------------------------------------------------

--@spec [IRET.10.2]
--@spec [IRET.12.1]
--@spec [IRET.8.3]
||| After a logical emit by activation (r, ids), the row for the fact now
||| live with that identity: the one just minted, or the one the no-op
||| left in place. An explicit emit records nothing.
public export
iret_10_2__record : Lcyc_3_2_1__program -> Nat -> List Nat -> List Lfac_1_7_1__fact -> Lgra_10_1__action -> Rarc_5_6_4__wm -> Iret_12_4__table -> Iret_12_4__table
iret_10_2__record p r ids bound (Withdraw _) wm rows = rows
iret_10_2__record p r ids bound (Emit k value) wm rows =
  case life p k of
    Explicit => rows
    Relation => case iret_19_1__find_relation k (fst (value bound)) (snd (value bound)) wm of
      Nothing => rows
      Just f  => rows ++ [MkRow r ids (fid f)]
    Entity => case iret_19_1__find_entity k (fst (value bound)) wm of
      Nothing => rows
      Just f  => rows ++ [MkRow r ids (fid f)]

-- ---------------------------------------------------------------------
-- Dispatch and the loop
-- ---------------------------------------------------------------------

--@spec [RARC.5.6.7]
||| One action: the core's dispatch, the justification it records, then
||| the cascade its retraction started, all before the next action.
public export
rarc_5_6_7__do_action_tms : Lcyc_3_2_1__program -> Nat -> Iret_11__tok -> Lgra_10_1__action -> Iret_12__state -> Iret_12__state
rarc_5_6_7__do_action_tms p r tok a (MkTms st rows) =
  case rarc_5_6_7__do_action p (tfacts tok) a st of
    MkState wm' tables' =>
      iret_12_2__phase p (MkTms (MkState wm' tables') (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm' rows))

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_tms : Lcyc_3_2_1__program -> Nat -> Iret_11__tok -> List Lgra_10_1__action -> Iret_12__state -> Iret_12__state
rarc_5_6_7__do_actions_tms p r tok [] s = s
rarc_5_6_7__do_actions_tms p r tok (a :: as) s = case rarc_5_6_7__do_action_tms p r tok a s of
  MkTms st rows => rarc_5_6_7__do_actions_tms p r tok as (MkTms st rows)

--@spec [IRET.11.4]
||| One firing with truth maintenance: the core's selection and pop, then
||| the RHS with the table and the cascade in the loop.
public export
iret_11_4__step_tms : Lcyc_3_2_1__program -> Iret_12__state -> Maybe Iret_12__state
iret_11_4__step_tms p (MkTms (MkState wm tables) rows) = case ldet_5_1__select_next tables of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (rules p) of
    Nothing => Nothing
    Just rule => case rarc_5_6_5__nth j (iret_11__table_at r tables) of
      Nothing => Nothing
      Just tok => Just (rarc_5_6_7__do_actions_tms p r tok (actions rule)
                          (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows))

--@spec [IRET.11.4]
public export
iret_11_4__step_n_tms : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> Maybe Iret_12__state
iret_11_4__step_n_tms p Z s = Just s
iret_11_4__step_n_tms p (S n) s = case iret_11_4__step_tms p s of
  Nothing => Nothing
  Just (MkTms st rows) => iret_11_4__step_n_tms p n (MkTms st rows)

--@spec [IRET.11.4]
--@spec [IRET.11.5]
public export
iret_11_4__run_tms : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> (Iret_12__state, Iret_11_4__halt, Nat)
iret_11_4__run_tms p Z s = (s, FuelOut, 0)
iret_11_4__run_tms p (S fuel) s = case iret_11_4__step_tms p s of
  Nothing => (s, Quiescent, 0)
  Just s' => let (t, h, n) = iret_11_4__run_tms p fuel s' in (t, h, S n)

--@spec [RARC.5.6.5]
||| The initial state: the core's, with an empty table.
public export
rarc_5_6_5__init_tms : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> Iret_12__state
rarc_5_6_5__init_tms p wm0 = MkTms (rarc_5_6_5__init_state p wm0) []

-- ---------------------------------------------------------------------
-- Agreement: without logical kinds the two engines coincide
-- ---------------------------------------------------------------------

--@spec [IRET.8.4]
||| A program that emits into no `logical` schema: every emitted kind is
||| explicit. `+nological` programs are these by [LNOG.3.2]; so is every
||| witness of Lcyc/Witnesses.idr that the core proofs run.
public export
Iret_8_4__explicit_only : Lcyc_3_2_1__program -> Type
Iret_8_4__explicit_only p = (k : Nat) -> life p k = Explicit

--@derives [IRET.12.2]
||| An empty table ends nothing, so a phase on it is the identity.
export
iret_12_2__phase_empty : (n : Nat) -> (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                         iret_12_2__phase_n n p (MkTms (MkState wm tables) []) = MkTms (MkState wm tables) []
iret_12_2__phase_empty Z p wm tables = Refl
iret_12_2__phase_empty (S n) p wm tables = iret_12_2__phase_empty n p wm tables

--@derives [LSCP.1.3]
export
lscp_1_3__relation_not_explicit : Relation = Explicit -> Void
lscp_1_3__relation_not_explicit Refl impossible

--@derives [LSCP.1.3]
export
lscp_1_3__entity_not_explicit : Entity = Explicit -> Void
lscp_1_3__entity_not_explicit Refl impossible

--@derives [IRET.8.3]
||| An explicit emit records nothing.
export
iret_8_3__record_explicit : (p : Lcyc_3_2_1__program) -> Iret_8_4__explicit_only p -> (r : Nat) -> (ids : List Nat) ->
                            (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (wm : Rarc_5_6_4__wm) ->
                            iret_10_2__record p r ids bound a wm [] = []
iret_8_3__record_explicit p ex r ids bound (Withdraw _) wm = Refl
iret_8_3__record_explicit p ex r ids bound (Emit k value) wm with (life p k) proof e
  iret_8_3__record_explicit p ex r ids bound (Emit k value) wm | Explicit = Refl
  iret_8_3__record_explicit p ex r ids bound (Emit k value) wm | Relation = void (lscp_1_3__relation_not_explicit (trans (sym e) (ex k)))
  iret_8_3__record_explicit p ex r ids bound (Emit k value) wm | Entity = void (lscp_1_3__entity_not_explicit (trans (sym e) (ex k)))

--@derives [RARC.5.6.7]
||| On an explicit-only program with an empty table, one action with truth
||| maintenance is the core's action.
export
rarc_5_6_7__action_agrees : (p : Lcyc_3_2_1__program) -> Iret_8_4__explicit_only p -> (r : Nat) -> (tok : Iret_11__tok) ->
                                  (a : Lgra_10_1__action) -> (st : Rarc_5_6_5__state) ->
                                  rarc_5_6_7__do_action_tms p r tok a (MkTms st []) = MkTms (rarc_5_6_7__do_action p (tfacts tok) a st) []
rarc_5_6_7__action_agrees p ex r tok a st with (rarc_5_6_7__do_action p (tfacts tok) a st)
  rarc_5_6_7__action_agrees p ex r tok a st | MkState wm' tables' =
    replace {p = \rows => iret_12_2__phase p (MkTms (MkState wm' tables') rows) = MkTms (MkState wm' tables') []}
            (sym (iret_8_3__record_explicit p ex r (iret_11_3__ids tok) (tfacts tok) a wm'))
            (iret_12_2__phase_empty 1 p wm' tables')

--@derives [RARC.5.6.7]
export
rarc_5_6_7__actions_agree : (p : Lcyc_3_2_1__program) -> Iret_8_4__explicit_only p -> (r : Nat) -> (tok : Iret_11__tok) ->
                                   (as : List Lgra_10_1__action) -> (st : Rarc_5_6_5__state) ->
                                   rarc_5_6_7__do_actions_tms p r tok as (MkTms st []) = MkTms (rarc_5_6_7__do_actions p (tfacts tok) as st) []
rarc_5_6_7__actions_agree p ex r tok [] st = Refl
rarc_5_6_7__actions_agree p ex r tok (a :: as) st with (rarc_5_6_7__do_action_tms p r tok a (MkTms st [])) proof eq
  rarc_5_6_7__actions_agree p ex r tok (a :: as) st | MkTms st1 rows1 =
    let e1 : (MkTms st1 rows1 = MkTms (rarc_5_6_7__do_action p (tfacts tok) a st) [])
        e1 = trans (sym eq) (rarc_5_6_7__action_agrees p ex r tok a st)
    in replace {p = \s1 => rarc_5_6_7__do_actions_tms p r tok as s1 = MkTms (rarc_5_6_7__do_actions p (tfacts tok) as (rarc_5_6_7__do_action p (tfacts tok) a st)) []}
               (sym e1)
               (rarc_5_6_7__actions_agree p ex r tok as (rarc_5_6_7__do_action p (tfacts tok) a st))

--@derives [IRET.11.4]
export
iret_11_4__just_inj : {a, b : t} -> Just a = Just b -> a = b
iret_11_4__just_inj Refl = Refl

--@derives [IRET.11.4]
--@derives [IRET.8.4]
||| THE AGREEMENT THEOREM: on an explicit-only program the engine
||| with truth maintenance takes exactly the core engine's steps, with an
||| empty table throughout. Everything proved about Rete/FireLoop.idr --
||| `lcyc_1_1__certified_terminates`, the witness runs -- is therefore a
||| statement about this engine too, for those programs; and [LNOG.4.2]'s
||| no-cascade guarantee is this theorem read on a `+nological` program.
export
iret_11_4__step_agrees : (p : Lcyc_3_2_1__program) -> Iret_8_4__explicit_only p -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                               iret_11_4__step_tms p (MkTms (MkState wm tables) []) = map (\st' => MkTms st' []) (iret_11_4__step p (MkState wm tables))
iret_11_4__step_agrees p ex wm tables with (ldet_5_1__select_next tables)
  iret_11_4__step_agrees p ex wm tables | Nothing = Refl
  iret_11_4__step_agrees p ex wm tables | Just (r, j) with (rarc_5_6_5__nth r (rules p))
    iret_11_4__step_agrees p ex wm tables | Just (r, j) | Nothing = Refl
    iret_11_4__step_agrees p ex wm tables | Just (r, j) | Just rule with (rarc_5_6_5__nth j (iret_11__table_at r tables))
      iret_11_4__step_agrees p ex wm tables | Just (r, j) | Just rule | Nothing = Refl
      iret_11_4__step_agrees p ex wm tables | Just (r, j) | Just rule | Just tok =
        cong Just (rarc_5_6_7__actions_agree p ex r tok (actions rule) (MkState wm (idat_6_2_2__mark_fired r j tables)))

--@derives [IRET.11.4]
export
iret_11_4__step_n_agrees : (p : Lcyc_3_2_1__program) -> Iret_8_4__explicit_only p -> (n : Nat) -> (st : Rarc_5_6_5__state) ->
                                 iret_11_4__step_n_tms p n (MkTms st []) = map (\st' => MkTms st' []) (iret_11_4__step_n p n st)
iret_11_4__step_n_agrees p ex Z st = Refl
iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) with (iret_11_4__step p (MkState wm tables)) proof eqC
  iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Nothing with (iret_11_4__step_tms p (MkTms (MkState wm tables) [])) proof eqT
    iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Nothing | Nothing = Refl
    iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Nothing | Just t =
      absurd (trans (sym eqT) (trans (iret_11_4__step_agrees p ex wm tables) (cong (map (\s => MkTms s [])) eqC)))
  iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Just st' with (iret_11_4__step_tms p (MkTms (MkState wm tables) [])) proof eqT
    iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Just st' | Nothing =
      absurd (trans (sym eqT) (trans (iret_11_4__step_agrees p ex wm tables) (cong (map (\s => MkTms s [])) eqC)))
    iret_11_4__step_n_agrees p ex (S n) (MkState wm tables) | Just st' | Just (MkTms t rows) =
      let e1 : (MkTms t rows = MkTms st' [])
          e1 = iret_11_4__just_inj (trans (sym eqT) (trans (iret_11_4__step_agrees p ex wm tables) (cong (map (\s => MkTms s [])) eqC)))
      in replace {p = \t' => iret_11_4__step_n_tms p n t' = map (\s => MkTms s []) (iret_11_4__step_n p n st')}
                 (sym e1)
                 (iret_11_4__step_n_agrees p ex n st')

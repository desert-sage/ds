-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Witness programs for the engine with truth maintenance
||| (Rete/FireLoopTms.idr), and the machine-checked claims about them.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| The programs exercise [IRET.12.1] (a justification per logical emit,
||| a no-op emit included), [IRET.12.2] (an ended activation decrements,
||| and a count that does not reach zero retracts nothing) and the bridge
||| to Rete/Refcount.idr ([IRET.12.4]: the table read as a justification
||| list), on the `+recursive` proposal's own shape: a seed emits a
||| `logical` Reach relation, a recursive rule closes it over the edges,
||| and the seed is withdrawn.
|||
||| HOW THE PROOFS ARE SHAPED: as in Lcyc/WitnessProofs.idr. The run's
||| states are a where-local function `s : Nat -> state` of literals
||| printed by `iret_11_4__trace_tms`, and each claim is a chain of
||| single-firing `Refl`s. Nothing is assumed about the literals: a wrong
||| one fails its `Refl`.
module Lcyc.TmsWitnesses

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Lcyc.Witnesses
import Data.List
import Data.Maybe
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- Printing and running
-- ---------------------------------------------------------------------

--@spec [IRET.12]
||| A TMS state as an Idris expression, for pasting back as a literal.
public export
iret_12__show_idris : Iret_12__state -> String
iret_12__show_idris s = "MkTms (" ++ rarc_5_6_5__show_idris (core s) ++ ") " ++ showRows (deps s)
  where
    showRow : Iret_12_4__row -> String
    showRow r = "MkRow " ++ show (rrule r) ++ " " ++ show (rids r) ++ " " ++ show (rtarget r)
    showRows : Iret_12_4__table -> String
    showRows rows = "[" ++ concat (intersperse ", " (map showRow rows)) ++ "]"

--@spec [IRET.11.4]
||| The states of a run with truth maintenance, one per line.
public export
iret_11_4__trace_tms : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> List String
iret_11_4__trace_tms p Z s = [iret_12__show_idris s]
iret_11_4__trace_tms p (S n) s = iret_12__show_idris s :: (case iret_11_4__step_tms p s of
  Nothing => ["-- quiescent"]
  Just s' => iret_11_4__trace_tms p n s')

-- ---------------------------------------------------------------------
-- Chaining single firings
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| Quiescent after exactly n firings, with truth maintenance.
public export
Iret_11_4__halts_at_tms : Lcyc_3_2_1__program -> Nat -> Iret_12__state -> Type
Iret_11_4__halts_at_tms p n s = (IsJust (iret_11_4__step_n_tms p n s), iret_11_4__step_n_tms p (S n) s = Nothing)

--@derives [IRET.11.4]
export
iret_11_4__step_n_tms_cons : (p : Lcyc_3_2_1__program) -> (n : Nat) -> (s, s' : Iret_12__state) -> (r : Maybe Iret_12__state) ->
                             iret_11_4__step_tms p s = Just s' -> iret_11_4__step_n_tms p n s' = r ->
                             iret_11_4__step_n_tms p (S n) s = r
iret_11_4__step_n_tms_cons p n s (MkTms st rows) r eq rest = rewrite eq in rest

--@derives [IRET.11.4]
export
iret_11_4__step_n_tms_end : (p : Lcyc_3_2_1__program) -> (n : Nat) -> (s : Iret_12__state) ->
                            iret_11_4__step_tms p s = Nothing -> iret_11_4__step_n_tms p (S n) s = Nothing
iret_11_4__step_n_tms_end p n s eq = rewrite eq in Refl

-- ---------------------------------------------------------------------
-- The reach shape with a logical Reach: seed, close, withdraw the seed
-- ---------------------------------------------------------------------

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_seed : Nat
lcyc_3_2_2__k_seed = 7

--@spec [IRET.12.1]
||| `Seed s -> emit Reach(1, 2) logical`: the seed justification.
public export
iret_12_1__seed_rule : Lgra_6_1__rule
iret_12_1__seed_rule = MkRule [lcyc_3_2_2__k_seed] (const True) [] [Emit lcyc_3_2_2__k_reach (\_ => (1, 2))]

--@spec [LSCP.2.1.1]
||| `Seed s -> withdraw s`: the input the derivation rested on goes away.
public export
lscp_2_1_1__spend_rule : Lgra_6_1__rule
lscp_2_1_1__spend_rule = MkRule [lcyc_3_2_2__k_seed] (const True) [] [Withdraw 0]

--@spec [IRET.12.1]
||| Seed first, then `gap__grow` (Reach r, Edge e where e.from == r.to
||| -> emit Reach(r.from, e.to)), then the withdrawal; Reach is a
||| `logical` relation, everything else explicit.
public export
iret_12_1__reach_prog : Lcyc_3_2_1__program
iret_12_1__reach_prog = MkProgram (gap__reach_life Relation) [iret_12_1__seed_rule, gap__grow, lscp_2_1_1__spend_rule]

--@spec [IRET.12.1]
||| One seed and the two edges of a 2-cycle: Edge(1,2), Edge(2,1).
public export
iret_12_1__reach_input : Rarc_5_6_4__wm
iret_12_1__reach_input = [MkFact 0 lcyc_3_2_2__k_seed 0 0, MkFact 1 lcyc_3_2_2__k_edge 1 2, MkFact 2 lcyc_3_2_2__k_edge 2 1]

--@derives [IRET.12.1]
--@derives [IRET.12.2]
||| Executed and checked, firing by firing: the seed emits Reach(1,2)
||| and justifies it; `grow` derives Reach(1,1) and justifies it; `grow`
||| re-emits Reach(1,2) as a no-op and justifies it a second time
||| [IRET.12.1 2]; the seed is withdrawn, its activation ends, Reach(1,2)
||| drops to one justification and is kept [IRET.12.2 3]. After four
||| firings both Reach facts are live and the table holds the two
||| justifications that hold each other up.
export
iret_12_2__reach_engine_run :
  iret_11_4__step_n_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog 4
    (rarc_5_6_5__init_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog Lcyc.TmsWitnesses.iret_12_1__reach_input)
  = Just (MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1]
                         [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []])
                [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])
iret_12_2__reach_engine_run =
  replace {p = \x => iret_11_4__step_n_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog 4 x
                     = Just (MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1]
                                            [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []])
                                   [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3])} (sym init)
    (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 3 (s 0) (s 1) _ step0
      (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 2 (s 1) (s 2) _ step1
        (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 1 (s 2) (s 3) _ step2
          (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 0 (s 3) (s 4) _ step3 Refl))))
  where
    s : Nat -> Iret_12__state
    s 0 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1] [[MkTok [MkFact 0 7 0 0] False False], [], [MkTok [MkFact 0 7 0 0] False False]]) []
    s 1 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] False False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3]
    s 2 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] False False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3, MkRow 1 [3, 2] 4]
    s 3 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3, MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3]
    s 4 = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []]) [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3]
    s _ = MkTms (MkState [] []) []
    init : rarc_5_6_5__init_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog Lcyc.TmsWitnesses.iret_12_1__reach_input = s 0
    init = Refl
    step0 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 2) = Just (s 3)
    step2 = Refl
    step3 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 3) = Just (s 4)
    step3 = Refl

--@derives [IRET.11.4]
||| And nothing is pending after the fourth firing: quiescent, on the
||| engine with truth maintenance, in the shape of Lcyc/WitnessProofs.idr.
export
iret_11_4__reach_engine_halts :
  Iret_11_4__halts_at_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog 4
    (rarc_5_6_5__init_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog Lcyc.TmsWitnesses.iret_12_1__reach_input)
iret_11_4__reach_engine_halts = replace {p = \x => Iret_11_4__halts_at_tms iret_12_1__reach_prog 4 x} (sym init)
  ( replace {p = \m => IsJust m}
      (sym (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 3 (s 0) (s 1) (Just (s 4)) step0
              (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 2 (s 1) (s 2) (Just (s 4)) step1
                (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 1 (s 2) (s 3) (Just (s 4)) step2
                  (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 0 (s 3) (s 4) (Just (s 4)) step3 Refl))))) ItIsJust
  , iret_11_4__step_n_tms_cons iret_12_1__reach_prog 4 (s 0) (s 1) Nothing step0
      (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 3 (s 1) (s 2) Nothing step1
        (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 2 (s 2) (s 3) Nothing step2
          (iret_11_4__step_n_tms_cons iret_12_1__reach_prog 1 (s 3) (s 4) Nothing step3
            (iret_11_4__step_n_tms_end iret_12_1__reach_prog 0 (s 4) step4)))) )
  where
    s : Nat -> Iret_12__state
    s 0 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1] [[MkTok [MkFact 0 7 0 0] False False], [], [MkTok [MkFact 0 7 0 0] False False]]) []
    s 1 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] False False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3]
    s 2 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] False False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3, MkRow 1 [3, 2] 4]
    s 3 = MkTms (MkState [MkFact 0 7 0 0, MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[MkTok [MkFact 0 7 0 0] True False], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], [MkTok [MkFact 0 7 0 0] False False]]) [MkRow 0 [0] 3, MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3]
    s 4 = MkTms (MkState [MkFact 1 5 1 2, MkFact 2 5 2 1, MkFact 3 4 1 2, MkFact 4 4 1 1] [[], [MkTok [MkFact 3 4 1 2, MkFact 2 5 2 1] True False, MkTok [MkFact 4 4 1 1, MkFact 1 5 1 2] True False], []]) [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3]
    s _ = MkTms (MkState [] []) []
    init : rarc_5_6_5__init_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog Lcyc.TmsWitnesses.iret_12_1__reach_input = s 0
    init = Refl
    step0 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 0) = Just (s 1)
    step0 = Refl
    step1 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 1) = Just (s 2)
    step1 = Refl
    step2 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 2) = Just (s 3)
    step2 = Refl
    step3 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 3) = Just (s 4)
    step3 = Refl
    step4 : iret_11_4__step_tms Lcyc.TmsWitnesses.iret_12_1__reach_prog (s 4) = Nothing
    step4 = Refl

--@derives [IRET.12.4]
||| The table the run leaves, read as justifications: Reach(1,1) from
||| Reach(1,2) with Edge(2,1); Reach(1,2) from Reach(1,1) with Edge(1,2).
export
iret_12_4__reach_engine_justifs :
  iret_12_4__justifs [MkRow 1 [3, 2] 4, MkRow 1 [4, 1] 3] = [MkJustif [3, 2] 4, MkJustif [4, 1] 3]
iret_12_4__reach_engine_justifs = Refl

--@derives [LLOG.2.5]
||| Over the surviving inputs (the two edges), the well-founded answer
||| for that table retracts both Reach facts...
export
llog_2_5__reach_engine_well_founded :
  llog_2_5__well_founded [1, 2] [MkJustif [3, 2] 4, MkJustif [4, 1] 3] [1, 2, 3, 4] = [1, 2]
llog_2_5__reach_engine_well_founded = Refl

--@derives [IRET.12.2]
||| ...and the refcount cascade keeps both: the engine's final working
||| memory above is Rete/Refcount.idr's cascade on the engine's own
||| table. `iret_12_2__cascade_unfounded` then says the two Reach facts
||| are an unfounded set, in the engine.
export
iret_12_2__reach_engine_cascade :
  iret_12_2__cascade [1, 2] [MkJustif [3, 2] 4, MkJustif [4, 1] 3] [1, 2, 3, 4] = [1, 2, 3, 4]
iret_12_2__reach_engine_cascade = Refl

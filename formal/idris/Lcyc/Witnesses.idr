-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Witness programs for the LCYC termination characterization, run on
||| Rete/FireLoop.idr's deterministic model. Each program is small enough
||| to read, and each claim about it is either an executed run (Quiescent
||| with a stated final state) or a divergence proof by literal
||| periodicity (`lcyc_1_1__periodic_diverges`).
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| A program that exercises a clause's own example or claim is
||| named under it: refill/drain under [LSCO.4.5.9] (the oscillation that
||| clause names), the keyed-replace churn under [LFAC.2.5.3], the defeat
||| pair under [LCYC.2.3.1], the same-literal self-emit under [LCYC.6.1.2].
||| The row-2 SCC and the join wave are programs the certificate
||| [LCYC.3.1.1] REFUSES — a schema emitted and matched inside one SCC — and
||| are named under it: one diverges (the refusal is not gratuitous), one
||| quiesces under source order (the certificate is conservative, knowingly).
||| The grow/reap family exercises a recursive rule graph, which no clause
||| admits; those are `--@gap`.
module Lcyc.Witnesses

import Rete.FireLoop
import Data.List
import Data.Maybe
import Data.Nat

%default total

-- Kind names used throughout. Values are (key, payload).
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_x : Nat
lcyc_3_2_2__k_x = 0
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_y : Nat
lcyc_3_2_2__k_y = 1
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_w : Nat
lcyc_3_2_2__k_w = 2
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_v : Nat
lcyc_3_2_2__k_v = 3
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_reach : Nat
lcyc_3_2_2__k_reach = 4
--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_edge : Nat
lcyc_3_2_2__k_edge = 5

--@spec [LSCP.2.1.1]
public export
lscp_2_1_1__all_explicit : Nat -> Lscp_1_3__lifecycle
lscp_2_1_1__all_explicit _ = Explicit

--@spec [LGRA.10.1]
||| Constant-value emit.
public export
lgra_10_1__emit_const : Nat -> Lgra_10_1__action
lgra_10_1__emit_const k = Emit k (const (0, 0))

--@spec [LGRA.8.1]
||| A `no K` pattern with no where-clause: any live K blocks.
public export
lgra_8_1__no_pat : Nat -> (Nat, List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool)
lgra_8_1__no_pat k = (k, \_, _ => True)

-- ---------------------------------------------------------------------
-- W1. refill / drain: withdraw re-enabling a `no` pattern.
--     refill: no X -> emit X        drain: X x -> withdraw x
-- ---------------------------------------------------------------------

--@spec [LSCO.4.5.9]
public export
lsco_4_5_9__refill : Lgra_6_1__rule
lsco_4_5_9__refill = MkRule [] (const True) [lgra_8_1__no_pat lcyc_3_2_2__k_x] [lgra_10_1__emit_const lcyc_3_2_2__k_x]

--@spec [LSCO.4.5.9]
public export
lsco_4_5_9__drain : Lgra_6_1__rule
lsco_4_5_9__drain = MkRule [lcyc_3_2_2__k_x] (const True) [] [Withdraw 0]

--@spec [LSCO.4.5.9]
public export
lsco_4_5_9__refill_drain : Lcyc_3_2_1__program
lsco_4_5_9__refill_drain = MkProgram lscp_2_1_1__all_explicit [lsco_4_5_9__refill, lsco_4_5_9__drain]

--@spec [LSCO.4.5.9]
public export
lsco_4_5_9__refill_drain0 : Rarc_5_6_5__state
lsco_4_5_9__refill_drain0 = rarc_5_6_5__init_state lsco_4_5_9__refill_drain []

-- ---------------------------------------------------------------------
-- W2. Entity upsert churn: a keyed `logical` fact re-emitted with a new
--     payload replaces itself, the replacement is a new token, and the
--     rule fires again. No withdraw, no `no`, one rule.
--     churn: C c where c.key == 1 -> emit C key: 1 pay: flip(c.pay)
-- ---------------------------------------------------------------------

--@spec [LFAC.2.5.3]
public export
lfac_2_5_3__flip_pay : Nat -> Nat
lfac_2_5_3__flip_pay Z = 1
lfac_2_5_3__flip_pay _ = 0

--@spec [LFAC.2.5.3]
public export
lfac_2_5_3__churn : Lgra_6_1__rule
lfac_2_5_3__churn = MkRule [lcyc_3_2_2__k_x]
               (\fs => case fs of
                         [c] => fkey c == 1
                         _   => False)
               []
               [Emit lcyc_3_2_2__k_x (\fs => case fs of
                                  [c] => (1, lfac_2_5_3__flip_pay (fpay c))
                                  _   => (1, 0))]

--@spec [LFAC.2.5.3]
public export
lfac_2_5_3__churn_prog : Lcyc_3_2_1__program
lfac_2_5_3__churn_prog = MkProgram (\k => if k == lcyc_3_2_2__k_x then Entity else Explicit) [lfac_2_5_3__churn]

--@spec [LFAC.2.5.3]
public export
lfac_2_5_3__churn0 : Rarc_5_6_5__state
lfac_2_5_3__churn0 = rarc_5_6_5__init_state lfac_2_5_3__churn_prog [MkFact 0 lcyc_3_2_2__k_x 1 0]

-- ---------------------------------------------------------------------
-- W3. The SCC the cycle-admission proposal filed under its row 2, and
--     [LCYC.3.1.1] refuses (W is emitted by A and C and
--     matched by B, inside one SCC). It loops:
--     A: X x, Y y -> withdraw x, emit W     (the consumption)
--     B: W w      -> emit V                 (positive)
--     C: V v      -> emit W, emit Y         (positive; Y closes C -> A)
--     Every negative edge is a consumption (A withdraws X, nothing emits
--     X), no `no` pattern anywhere. The measure bounds A's firings and
--     says nothing about B <-> C, which is why the row-based admission
--     was declined and the certificate refuses this shape.
--     W and V are Entity kinds with an alternating payload so the loop
--     recurs literally; with the default Explicit lifecycle it diverges
--     by accumulation instead (see W7 and the characterization document).
-- ---------------------------------------------------------------------

--@spec [LCYC.3.1.1]
||| Copy the bound fact's payload; flip it. B copies, C flips, so every
||| emit around the B <-> C loop is a meaningful change (a replace).
public export
lcyc_3_1_1__emit_copy : Nat -> Lgra_10_1__action
lcyc_3_1_1__emit_copy k = Emit k (\fs => case fs of
                              [f] => (0, fpay f)
                              _   => (0, 0))

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__emit_flip : Nat -> Lgra_10_1__action
lcyc_3_1_1__emit_flip k = Emit k (\fs => case fs of
                              [f] => (0, lfac_2_5_3__flip_pay (fpay f))
                              _   => (0, 0))

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_a : Lgra_6_1__rule
lcyc_3_1_1__rule_a = MkRule [lcyc_3_2_2__k_x, lcyc_3_2_2__k_y] (const True) [] [Withdraw 0, lgra_10_1__emit_const lcyc_3_2_2__k_w]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_b : Lgra_6_1__rule
lcyc_3_1_1__rule_b = MkRule [lcyc_3_2_2__k_w] (const True) [] [lcyc_3_1_1__emit_copy lcyc_3_2_2__k_v]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_c : Lgra_6_1__rule
lcyc_3_1_1__rule_c = MkRule [lcyc_3_2_2__k_v] (const True) [] [lcyc_3_1_1__emit_flip lcyc_3_2_2__k_w, lgra_10_1__emit_const lcyc_3_2_2__k_y]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__row2_prog : Lcyc_3_2_1__program
lcyc_3_1_1__row2_prog = MkProgram (\k => if k == lcyc_3_2_2__k_w || k == lcyc_3_2_2__k_v then Entity
                            else if k == lcyc_3_2_2__k_y then Relation
                            else Explicit)
                     [lcyc_3_1_1__rule_a, lcyc_3_1_1__rule_b, lcyc_3_1_1__rule_c]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__row2_s0 : Rarc_5_6_5__state
lcyc_3_1_1__row2_s0 = rarc_5_6_5__init_state lcyc_3_1_1__row2_prog [MkFact 0 lcyc_3_2_2__k_x 0 0, MkFact 1 lcyc_3_2_2__k_y 0 0]

-- ---------------------------------------------------------------------
-- W4 / W5. grow / reap (the cycle-admission proposal's own example):
--     grow: Reach r, Edge e where e.from == r.to -> emit Reach(r.from, e.to)
--     reap: Reach r where r.from == r.to         -> withdraw r
--     over the cyclic input Edge(1,2), Edge(2,1), Reach(1,2).
--     Reach as Relation (dedup) vs Explicit (accumulate), grow-first vs
--     reap-first order.
-- ---------------------------------------------------------------------

--@gap
public export
gap__grow : Lgra_6_1__rule
gap__grow = MkRule [lcyc_3_2_2__k_reach, lcyc_3_2_2__k_edge]
              (\fs => case fs of
                        [r, e] => fkey e == fpay r
                        _      => False)
              []
              [Emit lcyc_3_2_2__k_reach (\fs => case fs of
                                     [r, e] => (fkey r, fpay e)
                                     _      => (0, 0))]

--@gap
public export
gap__reap : Lgra_6_1__rule
gap__reap = MkRule [lcyc_3_2_2__k_reach]
              (\fs => case fs of
                        [r] => fkey r == fpay r
                        _   => False)
              []
              [Withdraw 0]

--@gap
public export
gap__reach_life : Lscp_1_3__lifecycle -> Nat -> Lscp_1_3__lifecycle
gap__reach_life l k = if k == lcyc_3_2_2__k_reach then l else Explicit

--@gap
public export
gap__cyclic_input : Rarc_5_6_4__wm
gap__cyclic_input = [MkFact 0 lcyc_3_2_2__k_edge 1 2, MkFact 1 lcyc_3_2_2__k_edge 2 1, MkFact 2 lcyc_3_2_2__k_reach 1 2]

--@gap
public export
gap__grow_reap_rel : Lcyc_3_2_1__program
gap__grow_reap_rel = MkProgram (gap__reach_life Relation) [gap__grow, gap__reap]

--@gap
public export
gap__grow_reap_exp : Lcyc_3_2_1__program
gap__grow_reap_exp = MkProgram (gap__reach_life Explicit) [gap__grow, gap__reap]

--@gap
public export
gap__reap_grow_exp : Lcyc_3_2_1__program
gap__reap_grow_exp = MkProgram (gap__reach_life Explicit) [gap__reap, gap__grow]

--@gap
public export
gap__grow_only_exp : Lcyc_3_2_1__program
gap__grow_only_exp = MkProgram (gap__reach_life Explicit) [gap__grow]

--@gap
public export
gap__grow_only_rel : Lcyc_3_2_1__program
gap__grow_only_rel = MkProgram (gap__reach_life Relation) [gap__grow]

-- ---------------------------------------------------------------------
-- W6. Rules that defeat each other [LCYC.2.3.1], over explicit facts:
--     x: no Y -> emit X        y: no X -> emit Y
-- ---------------------------------------------------------------------

--@spec [LCYC.2.3.1]
public export
lcyc_2_3_1__defeat_x : Lgra_6_1__rule
lcyc_2_3_1__defeat_x = MkRule [] (const True) [lgra_8_1__no_pat lcyc_3_2_2__k_y] [lgra_10_1__emit_const lcyc_3_2_2__k_x]

--@spec [LCYC.2.3.1]
public export
lcyc_2_3_1__defeat_y : Lgra_6_1__rule
lcyc_2_3_1__defeat_y = MkRule [] (const True) [lgra_8_1__no_pat lcyc_3_2_2__k_x] [lgra_10_1__emit_const lcyc_3_2_2__k_y]

--@spec [LCYC.2.3.1]
public export
lcyc_2_3_1__defeat_prog : Lcyc_3_2_1__program
lcyc_2_3_1__defeat_prog = MkProgram lscp_2_1_1__all_explicit [lcyc_2_3_1__defeat_x, lcyc_2_3_1__defeat_y]

--@spec [LCYC.2.3.1]
public export
lcyc_2_3_1__defeat0 : Rarc_5_6_5__state
lcyc_2_3_1__defeat0 = rarc_5_6_5__init_state lcyc_2_3_1__defeat_prog []

-- ---------------------------------------------------------------------
-- W7. The bare self-loop over an explicit kind:  X x -> emit X
-- ---------------------------------------------------------------------

--@spec [LCYC.6.1.2]
public export
lcyc_6_1_2__self_loop : Lgra_6_1__rule
lcyc_6_1_2__self_loop = MkRule [lcyc_3_2_2__k_x] (const True) [] [lgra_10_1__emit_const lcyc_3_2_2__k_x]

--@spec [LCYC.6.1.2]
public export
lcyc_6_1_2__self_loop_prog : Lcyc_3_2_1__program
lcyc_6_1_2__self_loop_prog = MkProgram lscp_2_1_1__all_explicit [lcyc_6_1_2__self_loop]

--@spec [LCYC.6.1.2]
public export
lcyc_6_1_2__self_loop0 : Rarc_5_6_5__state
lcyc_6_1_2__self_loop0 = rarc_5_6_5__init_state lcyc_6_1_2__self_loop_prog [MkFact 0 lcyc_3_2_2__k_x 0 0]

-- ---------------------------------------------------------------------
-- W8. Positive matches + withdraw only, no `no`, with a join whose two
--     constituents are each withdrawn and re-emitted — the shape a fair
--     scheduler can drive forever. Under source-order priority it stops.
--     WY: Y y -> withdraw y     RY: X x -> emit Y
--     WX: X x -> withdraw x     RX: Y y, Z z -> emit X
--     WZ: Z z -> withdraw z     RZ: X x -> emit Z
-- ---------------------------------------------------------------------

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__k_z : Nat
lcyc_3_2_2__k_z = 6

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__wdr : Nat -> Lgra_6_1__rule
lcyc_3_1_1__wdr k = MkRule [k] (const True) [] [Withdraw 0]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_ry : Lgra_6_1__rule
lcyc_3_1_1__rule_ry = MkRule [lcyc_3_2_2__k_x] (const True) [] [lgra_10_1__emit_const lcyc_3_2_2__k_y]
--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_rz : Lgra_6_1__rule
lcyc_3_1_1__rule_rz = MkRule [lcyc_3_2_2__k_x] (const True) [] [lgra_10_1__emit_const lcyc_3_2_2__k_z]
--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__rule_rx : Lgra_6_1__rule
lcyc_3_1_1__rule_rx = MkRule [lcyc_3_2_2__k_y, lcyc_3_2_2__k_z] (const True) [] [lgra_10_1__emit_const lcyc_3_2_2__k_x]

--@spec [LCYC.3.1.1]
||| The six rules, in a fixed reference order; a source order is a
||| permutation of this list.
public export
lcyc_3_1_1__join_wave_rules : List Lgra_6_1__rule
lcyc_3_1_1__join_wave_rules = [lcyc_3_1_1__rule_rx, lcyc_3_1_1__rule_ry, lcyc_3_1_1__rule_rz, lcyc_3_1_1__wdr lcyc_3_2_2__k_x, lcyc_3_1_1__wdr lcyc_3_2_2__k_y, lcyc_3_1_1__wdr lcyc_3_2_2__k_z]

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__join_wave : Lscp_1_3__lifecycle -> List Lgra_6_1__rule -> Lcyc_3_2_1__program
lcyc_3_1_1__join_wave l rs = MkProgram (const l) rs

--@spec [LCYC.3.1.1]
||| The join wave over dedup'd kinds in the reference source order — the
||| instance Lcyc/WitnessProofs.idr runs to quiescence.
public export
lcyc_3_1_1__join_wave_rel : Lcyc_3_2_1__program
lcyc_3_1_1__join_wave_rel = lcyc_3_1_1__join_wave Relation lcyc_3_1_1__join_wave_rules

--@spec [LCYC.3.1.1]
public export
lcyc_3_1_1__join_wave_input : Rarc_5_6_4__wm
lcyc_3_1_1__join_wave_input = [MkFact 0 lcyc_3_2_2__k_x 0 0, MkFact 1 lcyc_3_2_2__k_y 0 0, MkFact 2 lcyc_3_2_2__k_z 0 0]

--@spec [LCYC.3.1.1]
||| All permutations of a list (n! of them; six rules give 720).
public export
lcyc_3_1_1__perms : List a -> List (List a)
lcyc_3_1_1__perms [] = [[]]
lcyc_3_1_1__perms (x :: xs) = concatMap (insertEverywhere x) (lcyc_3_1_1__perms xs)
  where
    insertEverywhere : a -> List a -> List (List a)
    insertEverywhere y [] = [[y]]
    insertEverywhere y (z :: zs) = (y :: z :: zs) :: map (z ::) (insertEverywhere y zs)

--@spec [LCYC.3.1.1]
||| How many source orders of the join wave fail to quiesce within `fuel`
||| firings, under lifecycle `l` for every kind, and the first few that do.
public export
lcyc_3_1_1__sweep_join_wave : Lscp_1_3__lifecycle -> Nat -> (Nat, Nat, List (List Nat))
lcyc_3_1_1__sweep_join_wave l fuel =
  let idx     = [0, 1, 2, 3, 4, 5]
      orders  = lcyc_3_1_1__perms idx
      pick    = \is => mapMaybe (\i => rarc_5_6_5__nth i lcyc_3_1_1__join_wave_rules) is
      isOut   = \is => case iret_11_4__run (lcyc_3_1_1__join_wave l (pick is)) fuel (rarc_5_6_5__init_state (lcyc_3_1_1__join_wave l (pick is)) lcyc_3_1_1__join_wave_input) of
                         (_, FuelOut, _) => True
                         _               => False
      bad     = filter isOut orders
  in (length orders, length bad, take 6 bad)

-- ---------------------------------------------------------------------
-- Helpers for the REPL.
-- ---------------------------------------------------------------------

public export
Show Iret_11_4__halt where
  show Quiescent = "Quiescent"
  show FuelOut   = "FuelOut"

--@spec [IRET.11.4]
||| Run with fuel and report (halt reason, firings, final WM, pending per rule).
public export
iret_11_4__report : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> (Iret_11_4__halt, Nat, Rarc_5_6_4__wm, List Nat)
iret_11_4__report p fuel st =
  let (s, h, n) = iret_11_4__run p fuel st
  in (h, n, wm s, map (\ts => length (filter iret_11_3_1__pending_tok ts)) (toks s))

--@spec [RARC.5.6.4]
||| Live-fact count per kind 0..6.
public export
rarc_5_6_4__counts_by_kind : Rarc_5_6_4__wm -> List (Nat, Nat)
rarc_5_6_4__counts_by_kind w = map (\k => (k, rarc_5_6_4__count_kind k w)) [0, 1, 2, 3, 4, 5, 6]

--@spec [RARC.5.6.5]
||| Print a state as an Idris expression, so a run's states can be pasted
||| back as literals for step-by-step `Refl` proofs (the type-level
||| evaluator shares no work, so one multi-step `Refl` is far slower than
||| a chain of single-step ones against literal states).
public export
rarc_5_6_5__show_idris : Rarc_5_6_5__state -> String
rarc_5_6_5__show_idris s = "MkState [" ++ joinBy ", " (map showFact (wm s)) ++ "] ["
              ++ joinBy ", " (map showTable (toks s)) ++ "]"
  where
    joinBy : String -> List String -> String
    joinBy sep [] = ""
    joinBy sep [x] = x
    joinBy sep (x :: xs) = x ++ sep ++ joinBy sep xs
    showFact : Lfac_1_7_1__fact -> String
    showFact f = "MkFact " ++ show (fid f) ++ " " ++ show (fkind f) ++ " " ++ show (fkey f) ++ " " ++ show (fpay f)
    showTok : Iret_11__tok -> String
    showTok t = "MkTok [" ++ joinBy ", " (map showFact (tfacts t)) ++ "] " ++ show (fired t) ++ " " ++ show (blocked t)
    showTable : List Iret_11__tok -> String
    showTable ts = "[" ++ joinBy ", " (map showTok ts) ++ "]"

--@spec [IRET.11.4]
||| The states of a run, one per line, as Idris expressions.
public export
iret_11_4__trace : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> List String
iret_11_4__trace p Z st = [rarc_5_6_5__show_idris st]
iret_11_4__trace p (S n) st = rarc_5_6_5__show_idris st :: (case iret_11_4__step p st of
                                      Nothing => ["-- quiescent"]
                                      Just st' => iret_11_4__trace p n st')

--@spec [IRET.11.4]
||| Compact run report: (halt reason, firings, count per kind, pending per rule).
public export
iret_11_4__summary : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> (Iret_11_4__halt, Nat, List (Nat, Nat), List Nat)
iret_11_4__summary p fuel st =
  let (s, h, n) = iret_11_4__run p fuel st
  in (h, n, rarc_5_6_4__counts_by_kind (wm s), map (\ts => length (filter iret_11_3_1__pending_tok ts)) (toks s))


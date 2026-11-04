-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE V5 READING OF `and` WITH FAULTS, proved for every `where`.
||| Its tied V5 siblings are formal/alloy/where_v5.als and formal/k/dswherev5.k.
|||
||| NORMATIVE COMPANION to Rete/Eval.idr and Rete/NetworkAnswer.idr. The clauses
||| state V5: [LNUL.4.2] (absorption, the tie-break),
||| [IRET.9.5] and [IRET.7.6] (evaluation order), [LERR.1.4.11] (only the
||| yielded fault reaches a surface), [LDET.1.11] (the guarantee is for an
||| artefact that does not lie), RLOW.5.5 (decided conjuncts only) and
||| RLOW.6.1.4 (no absorption or distributivity rewrites).
|||
||| THE READING. A conjunct answers true, false, null, or faults; a fault is a
||| trap, a TypeError or an EngineError ([LERR.1]) and carries the BODY of the
||| atom it records ([RFCS.21.1]). A `where`'s answer is the fold of
||| `lnul_4_2__and5`: a `false` decides; otherwise the faults are resolved by
||| kind (EngineError over TypeError over trap), then by the recorded body --
||| never by position (T2I); otherwise null; otherwise true. Only that one
||| fault is recorded (M1).
|||
||| PREMISE: A CONJUNCT IS A FUNCTION OF THE PAIR. Its outcome depends on the
||| token, the candidate and engine state, and state does not change during one
||| evaluation; evaluating it emits nothing but the fault it may yield. The
||| impure reads a `where` admits ([LGRA.9.8.4], [LEXP.9.6.1]) keep this: a
||| `cached()` read is a pure read of engine state, emitted by nothing
||| ([LFST.9.2], [NCBK.7.6], [LSTO.4.3.1b]); a clock read is a read of state
||| once the engine holds one clock value per step, as [LTIM.2.4.3] does for a
||| tick. An operand whose evaluation emitted an
||| observable would be a log of the shape of M2, and
||| `gap__m2_order_dependent` is the witness that such a log is not order
||| independent.
|||
||| AN ENGINEERROR HERE is only a conjunct's own outcome -- the third arm of
||| [IRET.9.6], a value the artefact lied about. Resource exhaustion, recorder
||| failure and a `pump_wcet_ns` overrun are conditions of the engine, not
||| outcomes of a conjunct, and are not modelled.
|||
||| PROVED, for conjunct lists of every length:
|||   * `lnul_4_2__and5` projects onto Rete/Eval.idr's absorbing `and` -- the
|||     [LNUL.4.2] table -- so V5 refines what the model already has;
|||   * ORDER INDEPENDENCE: evaluating the conjuncts left to right, stopping at
|||     a false, in ANY permutation of the source, gives the same answer and
|||     the same record (`iret_9_5__any_order`);
|||   * recording every evaluated fault instead (M2) is not order independent
|||     (`gap__m2_order_dependent`, a counterexample tied to no clause);
|||   * HOISTING AND PROBING: conjuncts run first as filters -- an alpha test,
|||     an index probe -- in [IRET.6.4]'s order: a false among them rejects the candidate whatever the others
|||     answer (`iret_6_4__false_rejects`); otherwise a fault among them is
|||     raised there, the one T2I selects of two, and nothing of the rest is
|||     evaluated; otherwise the rest. The phase reads no source order
|||     (`iret_6_4__filters_order_free`). Filters that each answer true or
|||     false leave the decision of a positive and of a `no` pattern and the
|||     record unchanged, wherever they stood (`rlow_5_5__hoist_sound`); a
|||     filter that answers null, or faults with no false beside it, does not
|||     (`rlow_5_5__null_filter_differs`, `rlow_5_5__faulting_filter_differs`)
|||     -- which is why hoisting and anchors must be restricted to non-nullable
|||     slots that cannot raise by declared types, and why the determinism
|||     guarantee holds only for an artefact that does not lie: an EngineError
|||     from evaluation ends the trace as its cause of death ([LFST.9.2.1]'s
|||     terminal fault);
|||   * THE RECORDED BODY IS THE KEY: two faults of one kind from one node and
|||     slot -- a self-join -- record different atoms, and a key that stops at
|||     node and slot picks between them by order
|||     (`gap__selfjoin_coarse_differs`); keyed by the body, V5 records
|||     the same atom in either order (`rfcs_21_1__selfjoin_v5_agrees`);
|||   * NARROWING: a false guard decides whatever its tail would raise;
|||   * CONSISTENCY WITH THE NETWORK: a V5 `where` over a (token, candidate)
|||     pair is a Rete/NetworkAnswer.idr four-valued test
|||     (`iret_7_6__v5_is_conj_test`), a node over it joins what NetworkAnswer's
|||     node joins (`iret_7_6__v5_joining`), and NetworkAnswer's anchor-probe
|||     theorems carry over to it by application, not restatement
|||     (`iret_7_5_1__v5_probe_positive`, `iret_7_5_1__v5_probe_negated`, the
|||     latter under the same decided-anchor condition as hoisting,
|||     `rlow_5_5__decided_answer`); and the fault a pair
|||     records is a function of the pair, whatever order its conjuncts are
|||     evaluated in.
module Rete.WhereV5

import Rete.FireLoop
import Rete.Network
import Rete.NetworkView
import Rete.Refcount
import Rete.Eval
import Rete.NetworkAnswer
import Lcyc.Lemmas
import Data.List
import Data.List.Elem

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Faults: kind, identity, and the order that picks one (T2I)
-- ---------------------------------------------------------------------

--@spec [LERR.1]
||| The three fault kinds a `where` can meet: a trap (rung 6), a TypeError
||| (rung 5), an EngineError (rung 7).
public export
data Lerr_1__kind = KdTrap | KdTE | KdEE

--@spec [LERR.1]
||| The priority of a kind: smaller wins. EngineError, then TypeError, then trap.
||| EngineError first is [LERR.1]'s own order -- it abandons the tier, the
||| other two the activation. TypeError before trap is [LNUL.4.2]'s choice:
||| [LERR.1] ties rungs 5 and 6 on cost, and any fixed order of the two serves
||| every theorem below; only that the order is total matters. The trap kinds
||| among themselves are ordered by `proto/engine_error.proto#TrapKind` value,
||| which is the first field of the recorded body (`Rfcs_21_1__fault`).
public export
lerr_1__prio : Lerr_1__kind -> Nat
lerr_1__prio KdEE = 0
lerr_1__prio KdTE = 1
lerr_1__prio KdTrap = 2

--@derives [LERR.1]
export
lerr_1__prio_inj : (a, b : Lerr_1__kind) -> lerr_1__prio a = lerr_1__prio b -> a = b
lerr_1__prio_inj KdTrap KdTrap _ = Refl
lerr_1__prio_inj KdTE KdTE _ = Refl
lerr_1__prio_inj KdEE KdEE _ = Refl
lerr_1__prio_inj KdTrap KdTE Refl impossible
lerr_1__prio_inj KdTrap KdEE Refl impossible
lerr_1__prio_inj KdTE KdTrap Refl impossible
lerr_1__prio_inj KdTE KdEE Refl impossible
lerr_1__prio_inj KdEE KdTrap Refl impossible
lerr_1__prio_inj KdEE KdTE Refl impossible

--@spec [RFCS.21.1]
||| A fault: its kind and the body of the atom it records -- every field of
||| `proto/engine_error.proto#ComputationError` or `proto/type_error.proto`
||| after the kind, in a fixed order, recording provenance (`clock_ns`, `seq`)
||| excluded -- encoded injectively as a natural, so the order on naturals is
||| the lexicographic order on those fields. Two faults with one kind and one
||| body record the same atom; that is what makes the key total over what is
||| recorded rather than over the conjuncts that raised it.
public export
record Rfcs_21_1__fault where
  constructor MkFlt
  fltKind : Lerr_1__kind
  fltId   : Nat

--@derives [RFCS.21.1]
export
rfcs_21_1__fault_eq : (f, g : Rfcs_21_1__fault) -> fltKind f = fltKind g -> fltId f = fltId g -> f = g
rfcs_21_1__fault_eq (MkFlt k i) (MkFlt k i) Refl Refl = Refl

--@spec [LNUL.4.2]
||| Strict order on Nat, by structural recursion.
public export
lnul_4_2__ltN : Nat -> Nat -> Bool
lnul_4_2__ltN _ Z = False
lnul_4_2__ltN Z (S _) = True
lnul_4_2__ltN (S a) (S b) = lnul_4_2__ltN a b

--@derives [LNUL.4.2]
export
lnul_4_2__ltN_asym : (a, b : Nat) -> lnul_4_2__ltN a b = True -> lnul_4_2__ltN b a = False
lnul_4_2__ltN_asym _ Z p = absurd p
lnul_4_2__ltN_asym Z (S _) _ = Refl
lnul_4_2__ltN_asym (S a) (S b) p = lnul_4_2__ltN_asym a b p

--@derives [LNUL.4.2]
export
lnul_4_2__ltN_trans : (a, b, c : Nat) -> lnul_4_2__ltN a b = True -> lnul_4_2__ltN b c = True -> lnul_4_2__ltN a c = True
lnul_4_2__ltN_trans _ Z _ p _ = absurd p
lnul_4_2__ltN_trans _ (S _) Z _ q = absurd q
lnul_4_2__ltN_trans Z (S _) (S _) _ _ = Refl
lnul_4_2__ltN_trans (S a) (S b) (S c) p q = lnul_4_2__ltN_trans a b c p q

--@derives [LNUL.4.2]
export
lnul_4_2__ltN_tri : (a, b : Nat) -> lnul_4_2__ltN a b = False -> lnul_4_2__ltN b a = False -> a = b
lnul_4_2__ltN_tri Z Z _ _ = Refl
lnul_4_2__ltN_tri Z (S _) p _ = absurd p
lnul_4_2__ltN_tri (S _) Z _ q = absurd q
lnul_4_2__ltN_tri (S a) (S b) p q = cong S (lnul_4_2__ltN_tri a b p q)

--@spec [LNUL.4.2]
||| Lexicographic strict order on (priority, identity).
public export
lnul_4_2__lexLt : Nat -> Nat -> Nat -> Nat -> Bool
lnul_4_2__lexLt Z b1 Z b2 = lnul_4_2__ltN b1 b2
lnul_4_2__lexLt Z _ (S _) _ = True
lnul_4_2__lexLt (S _) _ Z _ = False
lnul_4_2__lexLt (S a1) b1 (S a2) b2 = lnul_4_2__lexLt a1 b1 a2 b2

--@derives [LNUL.4.2]
export
lnul_4_2__lex_asym : (a1, b1, a2, b2 : Nat) -> lnul_4_2__lexLt a1 b1 a2 b2 = True -> lnul_4_2__lexLt a2 b2 a1 b1 = False
lnul_4_2__lex_asym Z b1 Z b2 p = lnul_4_2__ltN_asym b1 b2 p
lnul_4_2__lex_asym Z _ (S _) _ _ = Refl
lnul_4_2__lex_asym (S _) _ Z _ p = absurd p
lnul_4_2__lex_asym (S a1) b1 (S a2) b2 p = lnul_4_2__lex_asym a1 b1 a2 b2 p

--@derives [LNUL.4.2]
export
lnul_4_2__lex_trans : (a1, b1, a2, b2, a3, b3 : Nat) ->
                      lnul_4_2__lexLt a1 b1 a2 b2 = True -> lnul_4_2__lexLt a2 b2 a3 b3 = True -> lnul_4_2__lexLt a1 b1 a3 b3 = True
lnul_4_2__lex_trans Z b1 Z b2 Z b3 p q = lnul_4_2__ltN_trans b1 b2 b3 p q
lnul_4_2__lex_trans Z _ Z _ (S _) _ _ _ = Refl
lnul_4_2__lex_trans Z _ (S _) _ Z _ _ q = absurd q
lnul_4_2__lex_trans Z _ (S _) _ (S _) _ _ _ = Refl
lnul_4_2__lex_trans (S _) _ Z _ _ _ p _ = absurd p
lnul_4_2__lex_trans (S _) _ (S _) _ Z _ _ q = absurd q
lnul_4_2__lex_trans (S a1) b1 (S a2) b2 (S a3) b3 p q = lnul_4_2__lex_trans a1 b1 a2 b2 a3 b3 p q

--@derives [LNUL.4.2]
export
lnul_4_2__lex_tri : (a1, b1, a2, b2 : Nat) -> lnul_4_2__lexLt a1 b1 a2 b2 = False -> lnul_4_2__lexLt a2 b2 a1 b1 = False ->
                    (a1 = a2, b1 = b2)
lnul_4_2__lex_tri Z b1 Z b2 p q = (Refl, lnul_4_2__ltN_tri b1 b2 p q)
lnul_4_2__lex_tri Z _ (S _) _ p _ = absurd p
lnul_4_2__lex_tri (S _) _ Z _ _ q = absurd q
lnul_4_2__lex_tri (S a1) b1 (S a2) b2 p q = let (ea, eb) = lnul_4_2__lex_tri a1 b1 a2 b2 p q in (cong S ea, eb)

--@spec [LNUL.4.2]
||| T2I: `f` beats `g` when its kind has priority, or the kinds tie and its
||| recorded body is smaller. Position never enters.
public export
lnul_4_2__beats : Rfcs_21_1__fault -> Rfcs_21_1__fault -> Bool
lnul_4_2__beats f g = lnul_4_2__lexLt (lerr_1__prio (fltKind f)) (fltId f) (lerr_1__prio (fltKind g)) (fltId g)

--@derives [LNUL.4.2]
export
lnul_4_2__beats_asym : (f, g : Rfcs_21_1__fault) -> lnul_4_2__beats f g = True -> lnul_4_2__beats g f = False
lnul_4_2__beats_asym f g = lnul_4_2__lex_asym _ _ _ _

--@derives [LNUL.4.2]
export
lnul_4_2__beats_trans : (f, g, h : Rfcs_21_1__fault) -> lnul_4_2__beats f g = True -> lnul_4_2__beats g h = True -> lnul_4_2__beats f h = True
lnul_4_2__beats_trans f g h = lnul_4_2__lex_trans _ _ _ _ _ _

--@derives [LNUL.4.2]
||| Two faults neither of which beats the other are the same fault.
export
lnul_4_2__beats_tri : (f, g : Rfcs_21_1__fault) -> lnul_4_2__beats f g = False -> lnul_4_2__beats g f = False -> f = g
lnul_4_2__beats_tri f g p q =
  let (ek, ei) = lnul_4_2__lex_tri _ _ _ _ p q
  in rfcs_21_1__fault_eq f g (lerr_1__prio_inj _ _ ek) ei

--@spec [LNUL.4.2]
||| The first fault if the flag holds, else the second -- `if` by pattern, so
||| the lemmas below reduce without `Lazy`.
public export
lnul_4_2__pick : Bool -> Rfcs_21_1__fault -> Rfcs_21_1__fault -> Rfcs_21_1__fault
lnul_4_2__pick True x _ = x
lnul_4_2__pick False _ y = y

--@spec [LNUL.4.2]
||| The fault of two that is recorded.
public export
lnul_4_2__bestF : Rfcs_21_1__fault -> Rfcs_21_1__fault -> Rfcs_21_1__fault
lnul_4_2__bestF f g = lnul_4_2__pick (lnul_4_2__beats g f) g f

--@derives [LNUL.4.2]
export
lnul_4_2__if_true : (x, y : Rfcs_21_1__fault) -> (b : Bool) -> b = True -> lnul_4_2__pick b x y = x
lnul_4_2__if_true x y True Refl = Refl

--@derives [LNUL.4.2]
export
lnul_4_2__if_false : (x, y : Rfcs_21_1__fault) -> (b : Bool) -> b = False -> lnul_4_2__pick b x y = y
lnul_4_2__if_false x y False Refl = Refl

--@derives [LNUL.4.2]
export
lnul_4_2__bestF_right : (f, g : Rfcs_21_1__fault) -> lnul_4_2__beats g f = True -> lnul_4_2__bestF f g = g
lnul_4_2__bestF_right f g p = lnul_4_2__if_true g f (lnul_4_2__beats g f) p

--@derives [LNUL.4.2]
export
lnul_4_2__bestF_left : (f, g : Rfcs_21_1__fault) -> lnul_4_2__beats g f = False -> lnul_4_2__bestF f g = f
lnul_4_2__bestF_left f g p = lnul_4_2__if_false g f (lnul_4_2__beats g f) p

--@derives [LNUL.4.2]
export
lnul_4_2__bestF_comm : (f, g : Rfcs_21_1__fault) -> lnul_4_2__bestF f g = lnul_4_2__bestF g f
lnul_4_2__bestF_comm f g =
  case iret_12__bool_split (lnul_4_2__beats g f) of
    Left gf => trans (lnul_4_2__bestF_right f g gf) (sym (lnul_4_2__bestF_left g f (lnul_4_2__beats_asym g f gf)))
    Right gf => case iret_12__bool_split (lnul_4_2__beats f g) of
      Left fg => trans (lnul_4_2__bestF_left f g gf) (sym (lnul_4_2__bestF_right g f fg))
      Right fg => let eq = lnul_4_2__beats_tri f g fg gf in
                  trans (lnul_4_2__bestF_left f g gf) (trans eq (sym (lnul_4_2__bestF_left g f fg)))

--@derives [LNUL.4.2]
||| If h does not beat g, g beats h or they are the same fault.
export
lnul_4_2__not_beats : (g, h : Rfcs_21_1__fault) -> lnul_4_2__beats h g = False -> Either (lnul_4_2__beats g h = True) (g = h)
lnul_4_2__not_beats g h p = case iret_12__bool_split (lnul_4_2__beats g h) of
  Left q => Left q
  Right q => Right (lnul_4_2__beats_tri g h q p)

--@derives [LNUL.4.2]
export
lnul_4_2__bestF_assoc : (f, g, h : Rfcs_21_1__fault) ->
                        lnul_4_2__bestF f (lnul_4_2__bestF g h) = lnul_4_2__bestF (lnul_4_2__bestF f g) h
lnul_4_2__bestF_assoc f g h =
  case iret_12__bool_split (lnul_4_2__beats h g) of
    Left hg => case iret_12__bool_split (lnul_4_2__beats g f) of
      Left gf =>
        -- h beats g beats f: both sides are h.
        let hf = lnul_4_2__beats_trans h g f hg gf in
        trans (cong (lnul_4_2__bestF f) (lnul_4_2__bestF_right g h hg))
              (trans (lnul_4_2__bestF_right f h hf)
                     (sym (trans (cong (\x => lnul_4_2__bestF x h) (lnul_4_2__bestF_right f g gf)) (lnul_4_2__bestF_right g h hg))))
      Right gf =>
        -- h beats g, g does not beat f: both sides are bestF f h.
        trans (cong (lnul_4_2__bestF f) (lnul_4_2__bestF_right g h hg))
              (sym (cong (\x => lnul_4_2__bestF x h) (lnul_4_2__bestF_left f g gf)))
    Right hg => case iret_12__bool_split (lnul_4_2__beats g f) of
      Left gf =>
        -- g beats f, h does not beat g: both sides are g.
        trans (cong (lnul_4_2__bestF f) (lnul_4_2__bestF_left g h hg))
              (trans (lnul_4_2__bestF_right f g gf)
                     (sym (trans (cong (\x => lnul_4_2__bestF x h) (lnul_4_2__bestF_right f g gf)) (lnul_4_2__bestF_left g h hg))))
      Right gf =>
        -- neither: both sides are f, since h cannot beat f.
        let hf : (lnul_4_2__beats h f = False)
            hf = case iret_12__bool_split (lnul_4_2__beats h f) of
                   Right q => q
                   Left q => case lnul_4_2__not_beats g h hg of
                     Left gh => absurd (trans (sym (lnul_4_2__beats_trans g h f gh q)) gf)
                     Right eq => absurd (trans (sym (replace {p = \z => lnul_4_2__beats z f = True} (sym eq) q)) gf)
        in trans (cong (lnul_4_2__bestF f) (lnul_4_2__bestF_left g h hg))
                 (trans (lnul_4_2__bestF_left f g gf)
                        (sym (trans (cong (\x => lnul_4_2__bestF x h) (lnul_4_2__bestF_left f g gf)) (lnul_4_2__bestF_left f h hf))))

-- ---------------------------------------------------------------------
-- Outcomes, and the V5 `and`
-- ---------------------------------------------------------------------

--@spec [IRET.7.6]
||| What one conjunct yields for a pair.
public export
data Iret_7_6__out = OYes | ONo | ONull | OFault Rfcs_21_1__fault

--@spec [LNUL.4.2]
--@spec [IRET.9.5]
||| V5: a false decides wherever it stands; otherwise the faults are resolved
||| by T2I; otherwise null; otherwise true.
public export
lnul_4_2__and5 : Iret_7_6__out -> Iret_7_6__out -> Iret_7_6__out
lnul_4_2__and5 ONo _ = ONo
lnul_4_2__and5 _ ONo = ONo
lnul_4_2__and5 (OFault f) (OFault g) = OFault (lnul_4_2__bestF f g)
lnul_4_2__and5 (OFault f) _ = OFault f
lnul_4_2__and5 _ (OFault g) = OFault g
lnul_4_2__and5 ONull _ = ONull
lnul_4_2__and5 _ ONull = ONull
lnul_4_2__and5 OYes OYes = OYes

--@spec [LNUL.4.2]
||| An outcome as Rete/Eval.idr's answer: every fault is a trap there.
public export
lnul_4_2__toAnswer : Iret_7_6__out -> Lnul_4_2__answer
lnul_4_2__toAnswer OYes = KTrue
lnul_4_2__toAnswer ONo = KFalse
lnul_4_2__toAnswer ONull = KNull
lnul_4_2__toAnswer (OFault _) = KTrap

--@derives [LNUL.4.2]
||| V5 REFINES THE TABLE: projected onto answers, `and5` is
||| Rete/Eval.idr's absorbing `and`.
export
lnul_4_2__and5_refines : (a, b : Iret_7_6__out) ->
                         lnul_4_2__toAnswer (lnul_4_2__and5 a b) = lnul_4_2__and (lnul_4_2__toAnswer a) (lnul_4_2__toAnswer b)
lnul_4_2__and5_refines OYes OYes = Refl
lnul_4_2__and5_refines OYes ONo = Refl
lnul_4_2__and5_refines OYes ONull = Refl
lnul_4_2__and5_refines OYes (OFault _) = Refl
lnul_4_2__and5_refines ONo OYes = Refl
lnul_4_2__and5_refines ONo ONo = Refl
lnul_4_2__and5_refines ONo ONull = Refl
lnul_4_2__and5_refines ONo (OFault _) = Refl
lnul_4_2__and5_refines ONull OYes = Refl
lnul_4_2__and5_refines ONull ONo = Refl
lnul_4_2__and5_refines ONull ONull = Refl
lnul_4_2__and5_refines ONull (OFault _) = Refl
lnul_4_2__and5_refines (OFault _) OYes = Refl
lnul_4_2__and5_refines (OFault _) ONo = Refl
lnul_4_2__and5_refines (OFault _) ONull = Refl
lnul_4_2__and5_refines (OFault _) (OFault _) = Refl

--@derives [LNUL.4.2]
export
lnul_4_2__and5_comm : (a, b : Iret_7_6__out) -> lnul_4_2__and5 a b = lnul_4_2__and5 b a
lnul_4_2__and5_comm OYes OYes = Refl
lnul_4_2__and5_comm OYes ONo = Refl
lnul_4_2__and5_comm OYes ONull = Refl
lnul_4_2__and5_comm OYes (OFault _) = Refl
lnul_4_2__and5_comm ONo OYes = Refl
lnul_4_2__and5_comm ONo ONo = Refl
lnul_4_2__and5_comm ONo ONull = Refl
lnul_4_2__and5_comm ONo (OFault _) = Refl
lnul_4_2__and5_comm ONull OYes = Refl
lnul_4_2__and5_comm ONull ONo = Refl
lnul_4_2__and5_comm ONull ONull = Refl
lnul_4_2__and5_comm ONull (OFault _) = Refl
lnul_4_2__and5_comm (OFault _) OYes = Refl
lnul_4_2__and5_comm (OFault _) ONo = Refl
lnul_4_2__and5_comm (OFault _) ONull = Refl
lnul_4_2__and5_comm (OFault f) (OFault g) = cong OFault (lnul_4_2__bestF_comm f g)

--@derives [LNUL.4.2]
export
lnul_4_2__and5_assoc : (a, b, c : Iret_7_6__out) -> lnul_4_2__and5 a (lnul_4_2__and5 b c) = lnul_4_2__and5 (lnul_4_2__and5 a b) c
lnul_4_2__and5_assoc ONo _ _ = Refl
lnul_4_2__and5_assoc OYes ONo _ = Refl
lnul_4_2__and5_assoc ONull ONo _ = Refl
lnul_4_2__and5_assoc (OFault _) ONo _ = Refl
lnul_4_2__and5_assoc OYes OYes ONo = Refl
lnul_4_2__and5_assoc OYes ONull ONo = Refl
lnul_4_2__and5_assoc OYes (OFault _) ONo = Refl
lnul_4_2__and5_assoc ONull OYes ONo = Refl
lnul_4_2__and5_assoc ONull ONull ONo = Refl
lnul_4_2__and5_assoc ONull (OFault _) ONo = Refl
lnul_4_2__and5_assoc (OFault _) OYes ONo = Refl
lnul_4_2__and5_assoc (OFault _) ONull ONo = Refl
lnul_4_2__and5_assoc (OFault _) (OFault _) ONo = Refl
lnul_4_2__and5_assoc OYes OYes OYes = Refl
lnul_4_2__and5_assoc OYes OYes ONull = Refl
lnul_4_2__and5_assoc OYes OYes (OFault _) = Refl
lnul_4_2__and5_assoc OYes ONull OYes = Refl
lnul_4_2__and5_assoc OYes ONull ONull = Refl
lnul_4_2__and5_assoc OYes ONull (OFault _) = Refl
lnul_4_2__and5_assoc OYes (OFault _) OYes = Refl
lnul_4_2__and5_assoc OYes (OFault _) ONull = Refl
lnul_4_2__and5_assoc OYes (OFault _) (OFault _) = Refl
lnul_4_2__and5_assoc ONull OYes OYes = Refl
lnul_4_2__and5_assoc ONull OYes ONull = Refl
lnul_4_2__and5_assoc ONull OYes (OFault _) = Refl
lnul_4_2__and5_assoc ONull ONull OYes = Refl
lnul_4_2__and5_assoc ONull ONull ONull = Refl
lnul_4_2__and5_assoc ONull ONull (OFault _) = Refl
lnul_4_2__and5_assoc ONull (OFault _) OYes = Refl
lnul_4_2__and5_assoc ONull (OFault _) ONull = Refl
lnul_4_2__and5_assoc ONull (OFault _) (OFault _) = Refl
lnul_4_2__and5_assoc (OFault _) OYes OYes = Refl
lnul_4_2__and5_assoc (OFault _) OYes ONull = Refl
lnul_4_2__and5_assoc (OFault _) OYes (OFault _) = Refl
lnul_4_2__and5_assoc (OFault _) ONull OYes = Refl
lnul_4_2__and5_assoc (OFault _) ONull ONull = Refl
lnul_4_2__and5_assoc (OFault _) ONull (OFault _) = Refl
lnul_4_2__and5_assoc (OFault _) (OFault _) OYes = Refl
lnul_4_2__and5_assoc (OFault _) (OFault _) ONull = Refl
lnul_4_2__and5_assoc (OFault f) (OFault g) (OFault h) = cong OFault (lnul_4_2__bestF_assoc f g h)

--@derives [LNUL.4.2]
||| A true conjunct changes nothing.
export
lnul_4_2__and5_yes : (a : Iret_7_6__out) -> lnul_4_2__and5 OYes a = a
lnul_4_2__and5_yes OYes = Refl
lnul_4_2__and5_yes ONo = Refl
lnul_4_2__and5_yes ONull = Refl
lnul_4_2__and5_yes (OFault _) = Refl

--@derives [LNUL.4.2]
export
lnul_4_2__and5_left_comm : (a, b, c : Iret_7_6__out) -> lnul_4_2__and5 a (lnul_4_2__and5 b c) = lnul_4_2__and5 b (lnul_4_2__and5 a c)
lnul_4_2__and5_left_comm a b c =
  trans (lnul_4_2__and5_assoc a b c)
        (trans (cong (\x => lnul_4_2__and5 x c) (lnul_4_2__and5_comm a b)) (sym (lnul_4_2__and5_assoc b a c)))

-- ---------------------------------------------------------------------
-- A `where`: its answer, its evaluation, what it records
-- ---------------------------------------------------------------------

--@spec [IRET.7.6]
--@spec [LNUL.4.2]
||| The answer of a `where`: its conjuncts combined by `and5`.
public export
lnul_4_2__v5 : List Iret_7_6__out -> Iret_7_6__out
lnul_4_2__v5 [] = OYes
lnul_4_2__v5 (o :: os) = lnul_4_2__and5 o (lnul_4_2__v5 os)

--@derives [IRET.7.6]
||| And projected onto answers, NetworkAnswer's combined test.
export
iret_7_6__v5_refines : (os : List Iret_7_6__out) -> lnul_4_2__toAnswer (lnul_4_2__v5 os) = iret_7_6__conj (map lnul_4_2__toAnswer os)
iret_7_6__v5_refines [] = Refl
iret_7_6__v5_refines (o :: os) =
  trans (lnul_4_2__and5_refines o (lnul_4_2__v5 os)) (cong (lnul_4_2__and (lnul_4_2__toAnswer o)) (iret_7_6__v5_refines os))

--@spec [IRET.9.5]
||| EVALUATION, left to right, stopping at the first false. [IRET.9.5]: the
||| operands may be evaluated "in any order", evaluation "may stop once the
||| result is decided", and a faulting operand "does not end the evaluation:
||| the evaluator holds the fault, evaluates the remaining operands, and a
||| `false` ... among them decides the result and discards every held fault".
public export
iret_9_5__seq : List Iret_7_6__out -> Iret_7_6__out
iret_9_5__seq [] = OYes
iret_9_5__seq (ONo :: _) = ONo
iret_9_5__seq (OYes :: os) = lnul_4_2__and5 OYes (iret_9_5__seq os)
iret_9_5__seq (ONull :: os) = lnul_4_2__and5 ONull (iret_9_5__seq os)
iret_9_5__seq (OFault f :: os) = lnul_4_2__and5 (OFault f) (iret_9_5__seq os)

--@derives [IRET.9.5]
||| Stopping at a false loses nothing.
export
iret_9_5__seq_v5 : (os : List Iret_7_6__out) -> iret_9_5__seq os = lnul_4_2__v5 os
iret_9_5__seq_v5 [] = Refl
iret_9_5__seq_v5 (ONo :: _) = Refl
iret_9_5__seq_v5 (OYes :: os) = cong (lnul_4_2__and5 OYes) (iret_9_5__seq_v5 os)
iret_9_5__seq_v5 (ONull :: os) = cong (lnul_4_2__and5 ONull) (iret_9_5__seq_v5 os)
iret_9_5__seq_v5 (OFault f :: os) = cong (lnul_4_2__and5 (OFault f)) (iret_9_5__seq_v5 os)

--@spec [IRET.9.5]
||| One list a reordering of another.
public export
data Iret_9_5__perm : {a : Type} -> List a -> List a -> Type where
  PNil   : {a : Type} -> Iret_9_5__perm {a} [] []
  PSkip  : {a : Type} -> {x : a} -> {xs, ys : List a} -> Iret_9_5__perm xs ys -> Iret_9_5__perm (x :: xs) (x :: ys)
  PSwap  : {a : Type} -> {x, y : a} -> {xs : List a} -> Iret_9_5__perm (x :: y :: xs) (y :: x :: xs)
  PTrans : {a : Type} -> {xs, ys, zs : List a} -> Iret_9_5__perm xs ys -> Iret_9_5__perm ys zs -> Iret_9_5__perm xs zs

--@derives [IRET.9.5]
export
iret_9_5__perm_refl : {a : Type} -> (xs : List a) -> Iret_9_5__perm xs xs
iret_9_5__perm_refl [] = PNil
iret_9_5__perm_refl (x :: xs) = PSkip (iret_9_5__perm_refl xs)

--@derives [IRET.9.5]
export
iret_9_5__perm_sym : {a : Type} -> {xs, ys : List a} -> Iret_9_5__perm xs ys -> Iret_9_5__perm ys xs
iret_9_5__perm_sym PNil = PNil
iret_9_5__perm_sym (PSkip p) = PSkip (iret_9_5__perm_sym p)
iret_9_5__perm_sym PSwap = PSwap
iret_9_5__perm_sym (PTrans p q) = PTrans (iret_9_5__perm_sym q) (iret_9_5__perm_sym p)

--@derives [IRET.9.5]
export
iret_9_5__perm_map : {a, b : Type} -> {xs, ys : List a} -> (g : a -> b) -> Iret_9_5__perm xs ys -> Iret_9_5__perm (map g xs) (map g ys)
iret_9_5__perm_map g PNil = PNil
iret_9_5__perm_map g (PSkip p) = PSkip (iret_9_5__perm_map g p)
iret_9_5__perm_map g PSwap = PSwap
iret_9_5__perm_map g (PTrans p q) = PTrans (iret_9_5__perm_map g p) (iret_9_5__perm_map g q)

--@derives [LNUL.4.2]
--@derives [IRET.9.5]
||| The answer does not depend on the order of the conjuncts.
export
lnul_4_2__v5_perm : {xs, ys : List Iret_7_6__out} -> Iret_9_5__perm xs ys -> lnul_4_2__v5 xs = lnul_4_2__v5 ys
lnul_4_2__v5_perm PNil = Refl
lnul_4_2__v5_perm (PSkip {x} p) = cong (lnul_4_2__and5 x) (lnul_4_2__v5_perm p)
lnul_4_2__v5_perm (PSwap {x} {y} {xs}) = lnul_4_2__and5_left_comm x y (lnul_4_2__v5 xs)
lnul_4_2__v5_perm (PTrans p q) = trans (lnul_4_2__v5_perm p) (lnul_4_2__v5_perm q)

--@spec [RFCS.21.1]
--@spec [LERR.1.4.11]
||| M1: the fault recorded is the one the `where` yields, if it yields one.
||| [LERR.1.4.11] holds every fault surface -- the record, the callback, the
||| metric -- to that one fault, so this list stands for all three.
public export
rfcs_21_1__record : Iret_7_6__out -> List Rfcs_21_1__fault
rfcs_21_1__record (OFault f) = [f]
rfcs_21_1__record _ = []

--@derives [IRET.9.5]
--@derives [RFCS.21.1]
--@derives [LERR.1.4.11]
||| ORDER INDEPENDENCE: evaluating ANY reordering of the source, left to right
||| and stopping at a false, gives the `where`'s answer and records its fault.
export
iret_9_5__any_order : (src, order : List Iret_7_6__out) -> Iret_9_5__perm src order ->
                      (iret_9_5__seq order = lnul_4_2__v5 src,
                       rfcs_21_1__record (iret_9_5__seq order) = rfcs_21_1__record (lnul_4_2__v5 src))
iret_9_5__any_order src order p =
  let eq = trans (iret_9_5__seq_v5 order) (sym (lnul_4_2__v5_perm p)) in (eq, cong rfcs_21_1__record eq)

-- ---------------------------------------------------------------------
-- COUNTEREXAMPLES to other readings. `gap__` elements:
-- they tie to no clause and state no requirement; they are the evidence for
-- why V5 records only the yielded fault (M1) and keys T2I on the recorded
-- body. The multi-variant models are formal/{alloy,k}/counterexamples/.
-- ---------------------------------------------------------------------

--@gap
||| M2: every fault evaluated before the stop is recorded (what libds does).
public export
gap__m2_evaluated : List Iret_7_6__out -> List Rfcs_21_1__fault
gap__m2_evaluated [] = []
gap__m2_evaluated (ONo :: _) = []
gap__m2_evaluated (OFault f :: os) = f :: gap__m2_evaluated os
gap__m2_evaluated (OYes :: os) = gap__m2_evaluated os
gap__m2_evaluated (ONull :: os) = gap__m2_evaluated os

--@gap
||| M2 IS NOT ORDER INDEPENDENT: `false and trap` and `trap and false` have one
||| answer, and M2 records the trap in one order only.
export
gap__m2_order_dependent :
  ( lnul_4_2__v5 [ONo, OFault (MkFlt KdTrap 1)] = lnul_4_2__v5 [OFault (MkFlt KdTrap 1), ONo]
  , gap__m2_evaluated [ONo, OFault (MkFlt KdTrap 1)] = []
  , gap__m2_evaluated [OFault (MkFlt KdTrap 1), ONo] = [MkFlt KdTrap 1] )
gap__m2_order_dependent = (Refl, Refl, Refl)

--@gap
||| A raised fault as a node sees it: its kind, the node and slot that raised
||| it, and the body of the atom it records. In a self-join two conjuncts
||| share the node and the slot and differ in the fact, so in the body.
public export
record Gap__raised where
  constructor MkRaised
  rsKind     : Lerr_1__kind
  rsNodeSlot : Nat
  rsBody     : Nat

--@gap
||| A tie-break keyed on kind, then node and slot -- the key that is not total
||| over what is recorded.
public export
gap__coarse_best : Gap__raised -> Gap__raised -> Gap__raised
gap__coarse_best f g =
  if lnul_4_2__lexLt (lerr_1__prio (rsKind g)) (rsNodeSlot g) (lerr_1__prio (rsKind f)) (rsNodeSlot f) then g else f

--@gap
||| THE SELF-JOIN: `S a`, `S b where a.x / a.y > 1 and b.x / b.y > 1`, both
||| divisors zero -- two traps from one node and one slot, over facts 1 and 2.
||| Keyed on node and slot, the atom recorded is whichever conjunct came first.
export
gap__selfjoin_coarse_differs :
  ( rsBody (gap__coarse_best (MkRaised KdTrap 7 1) (MkRaised KdTrap 7 2)) = 1
  , rsBody (gap__coarse_best (MkRaised KdTrap 7 2) (MkRaised KdTrap 7 1)) = 2 )
gap__selfjoin_coarse_differs = (Refl, Refl)

--@derives [RFCS.21.1]
--@derives [LNUL.4.2]
||| Keyed on the body, as `lnul_4_2__beats` is, V5 records the same atom in
||| either order.
export
rfcs_21_1__selfjoin_v5_agrees :
  ( rfcs_21_1__record (lnul_4_2__v5 [OFault (MkFlt KdTrap 1), OFault (MkFlt KdTrap 2)]) = [MkFlt KdTrap 1]
  , rfcs_21_1__record (lnul_4_2__v5 [OFault (MkFlt KdTrap 2), OFault (MkFlt KdTrap 1)]) = [MkFlt KdTrap 1] )
rfcs_21_1__selfjoin_v5_agrees = (Refl, Refl)

-- ---------------------------------------------------------------------
-- `or`, and the laws the compiler may not use (RLOW.6.1.4)
-- ---------------------------------------------------------------------

--@spec [LNUL.4.2]
||| The dual of `and5`: a true decides wherever it stands; otherwise the faults
||| are resolved by T2I; otherwise null; otherwise false.
public export
lnul_4_2__or5 : Iret_7_6__out -> Iret_7_6__out -> Iret_7_6__out
lnul_4_2__or5 OYes _ = OYes
lnul_4_2__or5 _ OYes = OYes
lnul_4_2__or5 (OFault f) (OFault g) = OFault (lnul_4_2__bestF f g)
lnul_4_2__or5 (OFault f) _ = OFault f
lnul_4_2__or5 _ (OFault g) = OFault g
lnul_4_2__or5 ONull _ = ONull
lnul_4_2__or5 _ ONull = ONull
lnul_4_2__or5 ONo ONo = ONo

--@derives [LNUL.4.2]
||| Projected onto answers, `or5` is Rete/Eval.idr's absorbing `or`.
export
lnul_4_2__or5_refines : (a, b : Iret_7_6__out) ->
                        lnul_4_2__toAnswer (lnul_4_2__or5 a b) = lnul_4_2__or (lnul_4_2__toAnswer a) (lnul_4_2__toAnswer b)
lnul_4_2__or5_refines OYes OYes = Refl
lnul_4_2__or5_refines OYes ONo = Refl
lnul_4_2__or5_refines OYes ONull = Refl
lnul_4_2__or5_refines OYes (OFault _) = Refl
lnul_4_2__or5_refines ONo OYes = Refl
lnul_4_2__or5_refines ONo ONo = Refl
lnul_4_2__or5_refines ONo ONull = Refl
lnul_4_2__or5_refines ONo (OFault _) = Refl
lnul_4_2__or5_refines ONull OYes = Refl
lnul_4_2__or5_refines ONull ONo = Refl
lnul_4_2__or5_refines ONull ONull = Refl
lnul_4_2__or5_refines ONull (OFault _) = Refl
lnul_4_2__or5_refines (OFault _) OYes = Refl
lnul_4_2__or5_refines (OFault _) ONo = Refl
lnul_4_2__or5_refines (OFault _) ONull = Refl
lnul_4_2__or5_refines (OFault _) (OFault _) = Refl

--@derives [RLOW.6.1.4]
--@derives [LNUL.4.2]
||| ABSORPTION DOES NOT HOLD: `null and (null or t)` is the fault t, where the
||| law would rewrite it to `null`.
export
rlow_6_1_4__absorption_fails :
  lnul_4_2__and5 ONull (lnul_4_2__or5 ONull (OFault (MkFlt KdTrap 1))) = OFault (MkFlt KdTrap 1)
rlow_6_1_4__absorption_fails = Refl

--@derives [RLOW.6.1.4]
--@derives [LNUL.4.2]
||| DISTRIBUTIVITY DOES NOT HOLD: `null and (true or e)` is null, and
||| `(null and true) or (null and e)` is the EngineError e.
export
rlow_6_1_4__distributivity_fails :
  ( lnul_4_2__and5 ONull (lnul_4_2__or5 OYes (OFault (MkFlt KdEE 1))) = ONull
  , lnul_4_2__or5 (lnul_4_2__and5 ONull OYes) (lnul_4_2__and5 ONull (OFault (MkFlt KdEE 1))) = OFault (MkFlt KdEE 1) )
rlow_6_1_4__distributivity_fails = (Refl, Refl)

--@derives [LNUL.5.4]
--@derives [LNUL.4.2]
--@derives [RLOW.6.1.4]
||| NARROWING: a false guard decides the `where`, wherever it stands, whatever
||| any other conjunct -- the guarded tail included -- would raise; nothing is
||| recorded. So folding a literal `false` operand to `false` is sound
||| (RLOW.6.1.4).
export
lnul_5_4__false_decides : (os : List Iret_7_6__out) -> Elem ONo os ->
                          (lnul_4_2__v5 os = ONo, rfcs_21_1__record (lnul_4_2__v5 os) = [])
lnul_5_4__false_decides (ONo :: _) Here = (Refl, Refl)
lnul_5_4__false_decides (o :: os) (There e) =
  let (eq, _) = lnul_5_4__false_decides os e
      v : (lnul_4_2__v5 (o :: os) = ONo)
      v = trans (cong (lnul_4_2__and5 o) eq) (trans (lnul_4_2__and5_comm o ONo) Refl)
  in (v, cong rfcs_21_1__record v)

-- ---------------------------------------------------------------------
-- Filters: alpha hoisting and index probing
-- ---------------------------------------------------------------------

--@spec [IRET.6.4]
||| What a node does with a candidate: it evaluated the `where`, or a filter
||| rejected it.
public export
data Iret_6_4__res = Evaluated Iret_7_6__out | Rejected

--@spec [IRET.6.4]
||| What the filter phase's answer does with the candidate: a false rejects
||| it; a fault is raised there, and nothing of the rest is evaluated (no
||| conjunct beside the node's tests can absorb it); a null rejects it, the
||| model's own extension -- no alpha test answers null for an artefact that
||| does not lie (RLOW.5.5), so the clause never presents one; a true passes
||| it to the rest.
public export
iret_6_4__filter_res : Iret_7_6__out -> List Iret_7_6__out -> Iret_6_4__res
iret_6_4__filter_res ONo _ = Rejected
iret_6_4__filter_res (OFault f) _ = Evaluated (OFault f)
iret_6_4__filter_res ONull _ = Rejected
iret_6_4__filter_res OYes rest = Evaluated (lnul_4_2__v5 rest)

--@spec [IRET.6.4]
--@spec [IRET.7.5.1]
||| FILTERS FIRST -- an alpha test, an index probe -- as a `where` of their
||| own under V5, then the rest. [IRET.6.4]: two alpha tests may fault, the engine must not short-circuit on
||| either, the fact is rejected if another test of the node answers false,
||| and the fault is raised only if none does. The V5 fold of the filters is
||| that order: a false among them decides wherever it stands
||| ([LNUL.4.2]); otherwise the faults among them resolve by T2I -- the
||| tests being hoisted conjuncts of the `where` (RLOW.5.5), [LNUL.4.2]
||| says which of two is raised; otherwise null, the model's own; otherwise
||| every filter passed. Source order never enters
||| (`iret_6_4__filters_order_free`); the short-circuit the clause's first
||| paragraph allows over decided tests loses nothing, by
||| `iret_9_5__seq_v5`.
public export
iret_6_4__filtered : List Iret_7_6__out -> List Iret_7_6__out -> Iret_6_4__res
iret_6_4__filtered fs rest = iret_6_4__filter_res (lnul_4_2__v5 fs) rest

--@spec [LNUL.4.3]
--@spec [LNUL.4.7]
||| The decision: a positive pattern (neg = False) fires on true; a `no`
||| pattern is blocked unless false; a rejected candidate neither fires nor
||| blocks.
public export
lnul_4_7__decide : Bool -> Iret_6_4__res -> Bool
lnul_4_7__decide False (Evaluated o) = lnul_4_3__admits (lnul_4_2__toAnswer o)
lnul_4_7__decide True (Evaluated o) = lnul_4_7__blocks (lnul_4_2__toAnswer o)
lnul_4_7__decide _ Rejected = False

--@spec [RFCS.21.1]
||| What a node records.
public export
rfcs_21_1__recordOf : Iret_6_4__res -> List Rfcs_21_1__fault
rfcs_21_1__recordOf (Evaluated o) = rfcs_21_1__record o
rfcs_21_1__recordOf Rejected = []

--@spec [RLOW.5.5]
||| A filter's outcome is decided: true or false. What a conjunct on a
||| non-nullable slot that cannot raise by declared types yields, for an
||| artefact that did not lie.
public export
data Rlow_5_5__decided : Iret_7_6__out -> Type where
  DYes : Rlow_5_5__decided OYes
  DNo  : Rlow_5_5__decided ONo

--@derives [RLOW.5.5]
--@derives [IRET.7.5.1]
||| A decided outcome is a decided answer in Rete/NetworkAnswer.idr's sense:
||| the hoisting condition here is the anchor-probe condition there.
export
rlow_5_5__decided_answer : (o : Iret_7_6__out) -> Rlow_5_5__decided o -> Iret_7_5_1__decided (lnul_4_2__toAnswer o)
rlow_5_5__decided_answer OYes DYes = DecTrue
rlow_5_5__decided_answer ONo DNo = DecFalse

--@spec [RLOW.5.5]
||| Every filter of a list decided -- by its own constructors, one per
||| decided outcome, so coverage needs no `impossible` clause.
public export
data Rlow_5_5__all_decided : List Iret_7_6__out -> Type where
  ADNil : Rlow_5_5__all_decided []
  ADYes : {fs : List Iret_7_6__out} -> Rlow_5_5__all_decided fs -> Rlow_5_5__all_decided (OYes :: fs)
  ADNo  : {fs : List Iret_7_6__out} -> Rlow_5_5__all_decided fs -> Rlow_5_5__all_decided (ONo :: fs)

--@derives [RLOW.5.5]
export
rlow_5_5__filtered_prefix : {fs : List Iret_7_6__out} -> (rest : List Iret_7_6__out) -> Rlow_5_5__all_decided fs -> (neg : Bool) ->
                            ( lnul_4_7__decide neg (iret_6_4__filtered fs rest) = lnul_4_7__decide neg (Evaluated (lnul_4_2__v5 (fs ++ rest)))
                            , rfcs_21_1__recordOf (iret_6_4__filtered fs rest) = rfcs_21_1__record (lnul_4_2__v5 (fs ++ rest)) )
rlow_5_5__filtered_prefix rest ADNil neg = (Refl, Refl)
rlow_5_5__filtered_prefix {fs = OYes :: fs0} rest (ADYes ds) neg =
  -- A true filter changes neither the filters' fold nor the whole's.
  let (d, r) = rlow_5_5__filtered_prefix {fs = fs0} rest ds neg
      ey = lnul_4_2__and5_yes (lnul_4_2__v5 fs0)
      ez = lnul_4_2__and5_yes (lnul_4_2__v5 (fs0 ++ rest))
  in (trans (cong (\x => lnul_4_7__decide neg (iret_6_4__filter_res x rest)) ey)
            (trans d (cong (\x => lnul_4_7__decide neg (Evaluated x)) (sym ez))),
      trans (cong (\x => rfcs_21_1__recordOf (iret_6_4__filter_res x rest)) ey)
            (trans r (cong rfcs_21_1__record (sym ez))))
rlow_5_5__filtered_prefix rest (ADNo _) False = (Refl, Refl)
rlow_5_5__filtered_prefix rest (ADNo _) True = (Refl, Refl)

--@derives [RLOW.5.5]
--@derives [IRET.7.5.1]
--@derives [IRET.6.4]
||| HOISTING AND PROBING ARE SOUND: filters taken from ANYWHERE in the
||| source, each true or false, then the rest, give the decision of a
||| positive and of a `no` pattern, and the record, of the whole `where`.
export
rlow_5_5__hoist_sound : (hs, rest, src : List Iret_7_6__out) -> Iret_9_5__perm (hs ++ rest) src ->
                        Rlow_5_5__all_decided hs -> (neg : Bool) ->
                        ( lnul_4_7__decide neg (iret_6_4__filtered hs rest) = lnul_4_7__decide neg (Evaluated (lnul_4_2__v5 src))
                        , rfcs_21_1__recordOf (iret_6_4__filtered hs rest) = rfcs_21_1__record (lnul_4_2__v5 src) )
rlow_5_5__hoist_sound hs rest src p ds neg =
  let (d, r) = rlow_5_5__filtered_prefix {fs = hs} rest ds neg
      eq = lnul_4_2__v5_perm p
  in (trans d (cong (\x => lnul_4_7__decide neg (Evaluated x)) eq), trans r (cong rfcs_21_1__record eq))

--@derives [RLOW.5.5]
--@derives [LNUL.4.7]
||| WHY NOT NULLABLE: a filter that answers null rejects, but the `where`
||| answers null, which blocks a `no` pattern ([LNUL.4.7]).
export
rlow_5_5__null_filter_differs :
  ( lnul_4_7__decide True (iret_6_4__filtered [ONull] []) = False
  , lnul_4_7__decide True (Evaluated (lnul_4_2__v5 [ONull])) = True )
rlow_5_5__null_filter_differs = (Refl, Refl)

--@derives [RLOW.5.5]
--@derives [IRET.9.6]
--@derives [LDET.1.11]
||| WHY NOT A FAULT: a filter that faults with no false beside it among the
||| filters -- an EngineError from a typed conjunct over an artefact that
||| lied -- raises it alone and blocks a `no` pattern, where the `where`,
||| whose false conjunct was not hoisted, would have been false. So two
||| engines may differ on an artefact that lies, which is why [LDET.1.11]
||| scopes the guarantee to one that does not. The amended order of
||| [IRET.6.4] does not close this: only another test OF THE NODE can
||| reject past the fault (`iret_6_4__fault_then_false_rejects`), and the
||| false here is in the rest.
export
rlow_5_5__faulting_filter_differs :
  ( lnul_4_7__decide True (iret_6_4__filtered [OFault (MkFlt KdEE 0)] [ONo]) = True
  , lnul_4_7__decide True (Evaluated (lnul_4_2__v5 [OFault (MkFlt KdEE 0), ONo])) = False )
rlow_5_5__faulting_filter_differs = (Refl, Refl)

--@derives [IRET.6.4]
||| A FALSE AMONG THE FILTERS REJECTS, whatever the others answer -- a fault
||| among them included -- and nothing is recorded: the amended clause's
||| "the fact is rejected if another test of the node answers false", for
||| every list of filters and every rest.
export
iret_6_4__false_rejects : (fs, rest : List Iret_7_6__out) -> Elem ONo fs ->
                          ( iret_6_4__filtered fs rest = Rejected
                          , rfcs_21_1__recordOf (iret_6_4__filtered fs rest) = [] )
iret_6_4__false_rejects fs rest e =
  let (eq, _) = lnul_5_4__false_decides fs e
      v : (iret_6_4__filtered fs rest = Rejected)
      v = cong (\x => iret_6_4__filter_res x rest) eq
  in (v, cong rfcs_21_1__recordOf v)

--@derives [IRET.6.4]
||| THE FILTER PHASE READS NO SOURCE ORDER: the filters in any order reject,
||| raise and pass alike, so "another test of the node" is any other, before
||| or after the faulting one. The short-circuit the clause allows over
||| decided tests is `iret_9_5__seq`, which `iret_9_5__seq_v5` says loses
||| nothing.
export
iret_6_4__filters_order_free : {fs, fs' : List Iret_7_6__out} -> Iret_9_5__perm fs fs' -> (rest : List Iret_7_6__out) ->
                               iret_6_4__filtered fs rest = iret_6_4__filtered fs' rest
iret_6_4__filters_order_free p rest = cong (\x => iret_6_4__filter_res x rest) (lnul_4_2__v5_perm p)

--@derives [IRET.6.4]
||| THE AMENDED ORDER, EXECUTED: a faulting alpha test beside a false one
||| rejects, whichever stands first in the source; two faulting tests with no
||| false beside them raise the one T2I selects -- the EngineError over the
||| trap, as [LNUL.4.2] has it; and a lone faulting test is raised there,
||| with a false in the REST of the `where` not evaluated -- only the node's
||| own tests reject past it.
export
iret_6_4__fault_then_false_rejects :
  ( iret_6_4__filtered [OFault (MkFlt KdTrap 1), ONo] [] = Rejected
  , iret_6_4__filtered [ONo, OFault (MkFlt KdTrap 1)] [] = Rejected
  , iret_6_4__filtered [OFault (MkFlt KdTrap 1), OFault (MkFlt KdEE 0)] [] = Evaluated (OFault (MkFlt KdEE 0))
  , iret_6_4__filtered [OYes, OFault (MkFlt KdTrap 1), OYes] [ONo] = Evaluated (OFault (MkFlt KdTrap 1)) )
iret_6_4__fault_then_false_rejects = (Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- Consistency with the network
-- ---------------------------------------------------------------------

--@spec [IRET.7.6]
||| One conjunct of a join, as V5 sees it: an outcome per (token, candidate).
public export
Iret_7_6__conjunct : Type
Iret_7_6__conjunct = Iret_7_1__token -> Lfac_1_7_1__fact -> Iret_7_6__out

--@spec [IRET.7.6]
||| A V5 `where` as a NetworkAnswer four-valued test.
public export
iret_7_6__v5_test : List Iret_7_6__conjunct -> Iret_7_5__test
iret_7_6__v5_test cs = \t, f => lnul_4_2__toAnswer (lnul_4_2__v5 (map (\c => c t f) cs))

--@spec [IRET.7.6]
||| A conjunct as a NetworkAnswer test.
public export
iret_7_6__as_test : Iret_7_6__conjunct -> Iret_7_5__test
iret_7_6__as_test c = \t, f => lnul_4_2__toAnswer (c t f)

--@derives [IRET.7.6]
export
iret_7_6__map_fuse : (cs : List Iret_7_6__conjunct) -> (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                     map (\x => x t f) (map iret_7_6__as_test cs) = map lnul_4_2__toAnswer (map (\c => c t f) cs)
iret_7_6__map_fuse [] t f = Refl
iret_7_6__map_fuse (c :: cs) t f = cong (lnul_4_2__toAnswer (c t f) ::) (iret_7_6__map_fuse cs t f)

--@derives [IRET.7.6]
--@derives [LNUL.4.2]
||| A V5 `where` IS NetworkAnswer's combined test of its conjuncts, pointwise:
||| so the four-valued network and its view theorem
||| (`iret_7_6__recompute_after_history_4`), which quantify over every test,
||| take V5 wheres as they stand; the probe theorems are applied below.
export
iret_7_6__v5_is_conj_test : (cs : List Iret_7_6__conjunct) -> (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                            iret_7_6__v5_test cs t f = iret_7_6__conj_test (map iret_7_6__as_test cs) t f
iret_7_6__v5_is_conj_test cs t f =
  trans (iret_7_6__v5_refines (map (\c => c t f) cs)) (cong iret_7_6__conj (sym (iret_7_6__map_fuse cs t f)))

--@derives [LNUL.4.3]
--@derives [LNUL.4.7]
||| And the node's decision is the node join of Rete/NetworkAnswer.idr.
export
lnul_4_7__decide_is_node_join : (neg : Bool) -> (cs : List Iret_7_6__conjunct) -> (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                                lnul_4_7__decide neg (Evaluated (lnul_4_2__v5 (map (\c => c t f) cs))) = iret_7_6__node_join neg (iret_7_6__v5_test cs) t f
lnul_4_7__decide_is_node_join False cs t f = Refl
lnul_4_7__decide_is_node_join True cs t f = Refl

--@derives [IRET.7.6]
||| A node over a V5 `where` joins exactly what the node over NetworkAnswer's
||| combined test of the same conjuncts joins.
export
iret_7_6__v5_joining : (neg : Bool) -> (cs : List Iret_7_6__conjunct) -> (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                       iret_7_6__joining (iret_7_6__node_join neg (iret_7_6__v5_test cs)) mem t
                         = iret_7_6__joining (iret_7_6__node_join neg (iret_7_6__conj_test (map iret_7_6__as_test cs))) mem t
iret_7_6__v5_joining False cs mem t =
  lcyc_1_1__filter_ext_on (iret_7_6__node_join False (iret_7_6__v5_test cs) t)
                         (iret_7_6__node_join False (iret_7_6__conj_test (map iret_7_6__as_test cs)) t) mem
                         (\f, _ => cong lnul_4_3__admits (iret_7_6__v5_is_conj_test cs t f))
iret_7_6__v5_joining True cs mem t =
  lcyc_1_1__filter_ext_on (iret_7_6__node_join True (iret_7_6__v5_test cs) t)
                         (iret_7_6__node_join True (iret_7_6__conj_test (map iret_7_6__as_test cs)) t) mem
                         (\f, _ => cong lnul_4_7__blocks (iret_7_6__v5_is_conj_test cs t f))

--@derives [IRET.7.5.1]
--@derives [IRET.7.6]
||| ANCHOR PROBING, AT THE NETWORK: a positive node over a V5 `where` joins
||| what probing its memory on any one conjunct, then joining the rest, joins
||| -- `iret_7_5_1__probe_positive` applied to V5, not restated.
export
iret_7_5_1__v5_probe_positive : (pre : List Iret_7_6__conjunct) -> (anc : Iret_7_6__conjunct) -> (post : List Iret_7_6__conjunct) ->
                                (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                                iret_7_6__joining (iret_7_6__node_join False (iret_7_6__v5_test (pre ++ anc :: post))) mem t
                                  = iret_7_6__joining (iret_7_6__node_join False (iret_7_6__v5_test (pre ++ post)))
                                                      (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t
iret_7_5_1__v5_probe_positive pre anc post mem t =
  trans (iret_7_6__v5_joining False (pre ++ anc :: post) mem t)
  (trans (cong (\ts => iret_7_6__joining (iret_7_6__node_join False (iret_7_6__conj_test ts)) mem t)
               (iret_7_6__map_append iret_7_6__as_test pre (anc :: post)))
  (trans (iret_7_5_1__probe_positive (map iret_7_6__as_test pre) (iret_7_6__as_test anc) (map iret_7_6__as_test post) mem t)
  (trans (cong (\ts => iret_7_6__joining (iret_7_6__node_join False (iret_7_6__conj_test ts)) (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t)
               (sym (iret_7_6__map_append iret_7_6__as_test pre post)))
         (sym (iret_7_6__v5_joining False (pre ++ post) (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t)))))

--@derives [IRET.7.5.1]
--@derives [LNUL.4.7]
||| And for a `no` pattern, when the anchor is decided on every candidate --
||| the same hoisting condition as `rlow_5_5__hoist_sound`, carried across by
||| `rlow_5_5__decided_answer`.
export
iret_7_5_1__v5_probe_negated : (pre : List Iret_7_6__conjunct) -> (anc : Iret_7_6__conjunct) -> (post : List Iret_7_6__conjunct) ->
                               (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                               ((f : Lfac_1_7_1__fact) -> Elem f mem -> Rlow_5_5__decided (anc t f)) ->
                               iret_7_6__joining (iret_7_6__node_join True (iret_7_6__v5_test (pre ++ anc :: post))) mem t
                                 = iret_7_6__joining (iret_7_6__node_join True (iret_7_6__v5_test (pre ++ post)))
                                                     (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t
iret_7_5_1__v5_probe_negated pre anc post mem t dec =
  trans (iret_7_6__v5_joining True (pre ++ anc :: post) mem t)
  (trans (cong (\ts => iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test ts)) mem t)
               (iret_7_6__map_append iret_7_6__as_test pre (anc :: post)))
  (trans (iret_7_5_1__probe_negated (map iret_7_6__as_test pre) (iret_7_6__as_test anc) (map iret_7_6__as_test post) mem t
                                    (\f, e => rlow_5_5__decided_answer (anc t f) (dec f e)))
  (trans (cong (\ts => iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test ts)) (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t)
               (sym (iret_7_6__map_append iret_7_6__as_test pre post)))
         (sym (iret_7_6__v5_joining True (pre ++ post) (iret_7_5_1__probe (iret_7_6__as_test anc) mem t) t)))))

--@spec [RFCS.21.1]
||| The fault a (token, candidate) pair records under a V5 `where`.
public export
rfcs_21_1__pair_record : List Iret_7_6__conjunct -> Iret_7_1__token -> Lfac_1_7_1__fact -> List Rfcs_21_1__fault
rfcs_21_1__pair_record cs t f = rfcs_21_1__record (lnul_4_2__v5 (map (\c => c t f) cs))

--@derives [RFCS.21.1]
--@derives [IRET.9.5]
--@derives [LERR.1.4.11]
||| A PAIR'S RECORD IS A FUNCTION OF THE PAIR: however its conjuncts are
||| ordered or evaluated -- which is what lets the trap record to be a function of the join relation.
export
rfcs_21_1__pair_record_order_free : (cs, cs' : List Iret_7_6__conjunct) -> Iret_9_5__perm cs cs' ->
                                    (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                                    rfcs_21_1__pair_record cs t f = rfcs_21_1__pair_record cs' t f
rfcs_21_1__pair_record_order_free cs cs' p t f =
  cong rfcs_21_1__record (lnul_4_2__v5_perm (iret_9_5__perm_map (\c => c t f) p))

-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The network with FOUR-VALUED join tests, and the `nolinscan` anchor probe they
||| make provable.
|||
||| NORMATIVE COMPANION to Rete/Network.idr and Rete/Eval.idr.
|||
||| A join test answers a (token, candidate) pair `true`, `false`, `null` or
||| a trap ([IRET.7.5], [LNUL.4.2]). Rete/Network.idr's nodes carry a Bool
||| relation, and every propagation lemma and the view theorem
||| (`rarc_5_6_5__recompute_after_history`) hold for ANY relation, so a node
||| built from a four-valued test reads its own: a positive node the pairs
||| answering `true` ([LNUL.4.3]), a `no` node the candidates answering
||| anything but `false` as blockers ([LNUL.4.7]). The view theorem then
||| holds for the loaded four-valued network as it stands
||| (`iret_7_6__recompute_after_history_4`); what this module adds is that the
||| two relations are the clauses' — a match extends a token by exactly the
||| candidates answering `true`, and a `no` node passes a token exactly when
||| every candidate answers `false` — and RLOW.5.3's "the same join tests as
||| the positive form": one test, two relations.
|||
||| THE ANCHOR PROBE ([IRET.7.5.1]). A node's tests combine as the absorbing
||| `and` ([IRET.7.6]); the `nolinscan` loader probes an index on one equality
||| test, wherever it stands, and runs the rest on the bucket. For a positive
||| node that is transparent unconditionally (`iret_7_5_1__probe_positive`).
||| For a `no` node it is transparent when the anchor is DECIDED — `true` or
||| `false` — on every candidate (`iret_7_5_1__probe_negated`), and not
||| otherwise: a candidate whose anchor answers `null` blocks under
||| [LNUL.4.7] but is in no bucket (`iret_7_5_1__null_anchor_escapes_probe`).
||| Under `nolinscan` a `no` node HAS an anchor: [LNLS.3.3] says every
||| pattern after the first is anchored to an earlier one, positive or
||| negated, exempting only a `no` pattern whose `where` reads no earlier
||| binding -- which has no anchor and probes nothing; its blockers are its
||| whole memory, and `lnul_4_7__no_blockers_iff_false` is all there is to
||| say of it. This module once ASSUMED that reading; the clause now states
||| it, and `lnls_3_3__negated_anchor_probe` is the claim as a theorem: the
||| probe is transparent at a `no` node whose anchor compares two non-null
||| values of one type on every candidate. The clause's keyed form gives
||| that premise for free -- the anchor pins `key` slots to `key` slots, and
||| a `key` slot is never `null` ([LNUL.8.10]) -- so for it the condition
||| holds by construction. The clause's SINGLETON form does not: it pins the
||| keyed side's `key` slots to slots of the singleton, which are payload
||| slots, and nothing forbids a nullable one; a `no` pattern on a keyed
||| schema anchored to a singleton's null slot is exactly the candidate the
||| escape above exhibits, and [IRET.7.5.1] forbids probing on it. That gap
||| is reported to the coordinator, not closed here. An engine that indexes
||| a `no` join on a NULLABLE slot outside `nolinscan` must still count the
||| null-keyed candidates; nothing in the spec says so, because nothing
||| specifies that index.
module Rete.NetworkAnswer

import Rete.FireLoop
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.Eval
import Lcyc.Lemmas
import Data.List
import Data.List.Elem

%default total

-- ---------------------------------------------------------------------
-- Four-valued tests, and the relation each node kind reads
-- ---------------------------------------------------------------------

--@spec [IRET.7.5]
--@spec [LNUL.4.2]
||| A join test: an answer for each (positive prefix, candidate) pair.
public export
Iret_7_5__test : Type
Iret_7_5__test = Iret_7_1__token -> Lfac_1_7_1__fact -> Lnul_4_2__answer

--@spec [IRET.7.6]
--@spec [LNUL.4.3]
--@spec [LNUL.4.7]
--@spec [RLOW.5.3]
||| The relation a node reads from its test: a positive node admits a pair
||| answering `true`; for a `no` node a candidate blocks unless it answers
||| `false`. One test, two relations.
public export
iret_7_6__node_join : Bool -> Iret_7_5__test -> Iret_7_5__join
iret_7_6__node_join True  test = \t, f => lnul_4_7__blocks (test t f)
iret_7_6__node_join False test = \t, f => lnul_4_3__admits (test t f)

--@spec [IRET.16.5]
||| A beta node as the loader receives it, with a four-valued test.
public export
iret_16_5__node4 : (Nat, Iret_7_5__test, Bool) -> (Nat, Iret_7_5__join, Bool)
iret_16_5__node4 (a, test, neg) = (a, iret_7_6__node_join neg test, neg)

--@spec [RDSC.4a.5]
--@spec [IRET.16.5]
||| LOAD, with four-valued tests.
public export
rdsc_4a_5__load4 : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__test, Bool), List Lgra_10_1__action) -> Iret_19__engine
rdsc_4a_5__load4 alphas rules = rdsc_4a_5__load alphas (map (\r => (map iret_16_5__node4 (fst r), snd r)) rules)

--@derives [RARC.5.6.5]
--@derives [IRET.7.6]
||| THE VIEW THEOREM WITH FOUR-VALUED TESTS: after any history, every alpha
||| memory and every terminal of the loaded four-valued network is the
||| recompute over working memory. The view theorem is over any relation,
||| so this is its instance; the content is in the two lemmas below, which
||| say the relations are the clauses'.
export
iret_7_6__recompute_after_history_4 : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                      (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__test, Bool), List Lgra_10_1__action)) ->
                                      Rarc_5_6_5__recomputed (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load4 alphas rules))
iret_7_6__recompute_after_history_4 life fuel evs alphas rules =
  rarc_5_6_5__recompute_after_history life fuel evs alphas (map (\r => (map iret_16_5__node4 (fst r), snd r)) rules)

--@derives [LNUL.4.3]
--@derives [IRET.7.2]
||| A positive node extends a token by EXACTLY the candidates answering
||| `true`: every extension it passes is one, and every one is passed.
export
lnul_4_3__extends_iff_true : (test : Iret_7_5__test) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) ->
                             (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                             ( Elem t front -> Elem f mem -> test t f = KTrue -> Elem (t ++ [f]) (iret_7_7__next_of False (iret_7_6__node_join False test) mem front)
                             , (y : Iret_7_1__token) -> Elem y (iret_7_7__next_of False (iret_7_6__node_join False test) mem front) ->
                                 (u ** (g ** (Elem u front, Elem g mem, test u g = KTrue, y = u ++ [g]))) )
lnul_4_3__extends_iff_true test mem front t f =
  ( \et, ef, tt => iret_7_7__extend_elem_fwd (iret_7_6__node_join False test) mem front t f et ef (cong lnul_4_3__admits tt)
  , \y, e => let (u ** (g ** (eu, eg, j, eq))) = iret_7_7__extend_elem_inv (iret_7_6__node_join False test) mem front y e
             in (u ** (g ** (eu, eg, lnul_4_3__admits_only_true (test u g) j, eq))) )

--@derives [LNUL.4.2]
||| The undecided and the true answers are not `false`.
export
lnul_4_2__true_not_false : KTrue = KFalse -> Void
lnul_4_2__true_not_false Refl impossible

--@derives [LNUL.4.2]
export
lnul_4_2__null_not_false : KNull = KFalse -> Void
lnul_4_2__null_not_false Refl impossible

--@derives [LNUL.4.2]
export
lnul_4_2__trap_not_false : KTrap = KFalse -> Void
lnul_4_2__trap_not_false Refl impossible

--@derives [LNUL.4.7]
||| A count with a blocker in it is not zero.
export
lnul_4_7__succ_not_zero : {n : Nat} -> S n = 0 -> Void
lnul_4_7__succ_not_zero Refl impossible

--@derives [LNUL.4.7]
||| No candidate blocks a token iff every candidate answers `false`.
export
lnul_4_7__no_blockers_iff_false : (test : Iret_7_5__test) -> (t : Iret_7_1__token) -> (mem : List Lfac_1_7_1__fact) ->
                                  ( iret_7_9_1__blockers (iret_7_6__node_join True test) mem t = 0 -> (f : Lfac_1_7_1__fact) -> Elem f mem -> test t f = KFalse
                                  , ((f : Lfac_1_7_1__fact) -> Elem f mem -> test t f = KFalse) -> iret_7_9_1__blockers (iret_7_6__node_join True test) mem t = 0 )
lnul_4_7__no_blockers_iff_false test t [] = (\_, f, e => absurd e, \_ => Refl)
lnul_4_7__no_blockers_iff_false test t (g :: gs) with (test t g) proof pg
  lnul_4_7__no_blockers_iff_false test t (g :: gs) | KFalse =
    let (fwd, bwd) = lnul_4_7__no_blockers_iff_false test t gs
    in ( \z, f, e => case e of
                       Here => pg
                       There e' => fwd z f e'
       , \all => bwd (\f, e => all f (There e)) )
  lnul_4_7__no_blockers_iff_false test t (g :: gs) | KTrue =
    (\z, _, _ => absurd (lnul_4_7__succ_not_zero z), \all => absurd (lnul_4_2__true_not_false (trans (sym pg) (all g Here))))
  lnul_4_7__no_blockers_iff_false test t (g :: gs) | KNull =
    (\z, _, _ => absurd (lnul_4_7__succ_not_zero z), \all => absurd (lnul_4_2__null_not_false (trans (sym pg) (all g Here))))
  lnul_4_7__no_blockers_iff_false test t (g :: gs) | KTrap =
    (\z, _, _ => absurd (lnul_4_7__succ_not_zero z), \all => absurd (lnul_4_2__trap_not_false (trans (sym pg) (all g Here))))

--@derives [LNUL.4.7]
--@derives [IRET.7.9.1]
||| A `NOT (P where C)` IS SATISFIED IFF, FOR EVERY FACT MATCHING P, C
||| EVALUATES TO `false` — [LNUL.4.7]'s sentence, at the node: the node
||| passes a token it receives exactly when every candidate of its right
||| memory answers `false`.
export
lnul_4_7__passes_iff_all_false : (test : Iret_7_5__test) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> (t : Iret_7_1__token) ->
                                 ( Elem t (iret_7_7__next_of True (iret_7_6__node_join True test) mem front) ->
                                     (Elem t front, (f : Lfac_1_7_1__fact) -> Elem f mem -> test t f = KFalse)
                                 , Elem t front -> ((f : Lfac_1_7_1__fact) -> Elem f mem -> test t f = KFalse) ->
                                     Elem t (iret_7_7__next_of True (iret_7_6__node_join True test) mem front) )
lnul_4_7__passes_iff_all_false test mem front t =
  ( \e => let (et, z) = iret_7_9_1__pass_elem_inv (iret_7_6__node_join True test) mem front t e
          in (et, fst (lnul_4_7__no_blockers_iff_false test t mem) z)
  , \et, all => iret_7_9_1__pass_elem_fwd (iret_7_6__node_join True test) mem front t et
                  (snd (lnul_4_7__no_blockers_iff_false test t mem) all) )

-- ---------------------------------------------------------------------
-- The absorbing `and` is a semilattice: tests combine in any order
-- ---------------------------------------------------------------------

--@derives [LNUL.4.2]
--@derives [IRET.7.6]
||| The absorbing `and` is ASSOCIATIVE, traps included. With
||| `lnul_4_2__and_commutes` (Rete/Eval.idr), a node's tests combine to one
||| answer whatever order they are evaluated in.
export
lnul_4_2__and_assoc : (a, b, c : Lnul_4_2__answer) -> lnul_4_2__and a (lnul_4_2__and b c) = lnul_4_2__and (lnul_4_2__and a b) c
lnul_4_2__and_assoc KFalse b c = Refl
lnul_4_2__and_assoc KTrue  KFalse c = Refl
lnul_4_2__and_assoc KNull  KFalse c = Refl
lnul_4_2__and_assoc KTrap  KFalse c = Refl
lnul_4_2__and_assoc KTrue  KTrue  KTrue  = Refl
lnul_4_2__and_assoc KTrue  KTrue  KFalse = Refl
lnul_4_2__and_assoc KTrue  KTrue  KNull  = Refl
lnul_4_2__and_assoc KTrue  KTrue  KTrap  = Refl
lnul_4_2__and_assoc KTrue  KNull  KTrue  = Refl
lnul_4_2__and_assoc KTrue  KNull  KFalse = Refl
lnul_4_2__and_assoc KTrue  KNull  KNull  = Refl
lnul_4_2__and_assoc KTrue  KNull  KTrap  = Refl
lnul_4_2__and_assoc KTrue  KTrap  KTrue  = Refl
lnul_4_2__and_assoc KTrue  KTrap  KFalse = Refl
lnul_4_2__and_assoc KTrue  KTrap  KNull  = Refl
lnul_4_2__and_assoc KTrue  KTrap  KTrap  = Refl
lnul_4_2__and_assoc KNull  KTrue  KTrue  = Refl
lnul_4_2__and_assoc KNull  KTrue  KFalse = Refl
lnul_4_2__and_assoc KNull  KTrue  KNull  = Refl
lnul_4_2__and_assoc KNull  KTrue  KTrap  = Refl
lnul_4_2__and_assoc KNull  KNull  KTrue  = Refl
lnul_4_2__and_assoc KNull  KNull  KFalse = Refl
lnul_4_2__and_assoc KNull  KNull  KNull  = Refl
lnul_4_2__and_assoc KNull  KNull  KTrap  = Refl
lnul_4_2__and_assoc KNull  KTrap  KTrue  = Refl
lnul_4_2__and_assoc KNull  KTrap  KFalse = Refl
lnul_4_2__and_assoc KNull  KTrap  KNull  = Refl
lnul_4_2__and_assoc KNull  KTrap  KTrap  = Refl
lnul_4_2__and_assoc KTrap  KTrue  KTrue  = Refl
lnul_4_2__and_assoc KTrap  KTrue  KFalse = Refl
lnul_4_2__and_assoc KTrap  KTrue  KNull  = Refl
lnul_4_2__and_assoc KTrap  KTrue  KTrap  = Refl
lnul_4_2__and_assoc KTrap  KNull  KTrue  = Refl
lnul_4_2__and_assoc KTrap  KNull  KFalse = Refl
lnul_4_2__and_assoc KTrap  KNull  KNull  = Refl
lnul_4_2__and_assoc KTrap  KNull  KTrap  = Refl
lnul_4_2__and_assoc KTrap  KTrap  KTrue  = Refl
lnul_4_2__and_assoc KTrap  KTrap  KFalse = Refl
lnul_4_2__and_assoc KTrap  KTrap  KNull  = Refl
lnul_4_2__and_assoc KTrap  KTrap  KTrap  = Refl

--@derives [LNUL.4.2]
export
lnul_4_2__and_left_comm : (a, b, c : Lnul_4_2__answer) -> lnul_4_2__and a (lnul_4_2__and b c) = lnul_4_2__and b (lnul_4_2__and a c)
lnul_4_2__and_left_comm a b c =
  trans (lnul_4_2__and_assoc a b c)
        (trans (cong (\x => lnul_4_2__and x c) (lnul_4_2__and_commutes a b)) (sym (lnul_4_2__and_assoc b a c)))

--@spec [IRET.7.6]
--@spec [LNUL.4.2]
||| A node's tests, combined: the absorbing `and` of their answers, `true`
||| for none.
public export
iret_7_6__conj : List Lnul_4_2__answer -> Lnul_4_2__answer
iret_7_6__conj [] = KTrue
iret_7_6__conj (a :: as) = lnul_4_2__and a (iret_7_6__conj as)

--@spec [IRET.7.6]
||| A node's test list as one test.
public export
iret_7_6__conj_test : List Iret_7_5__test -> Iret_7_5__test
iret_7_6__conj_test tests = \t, f => iret_7_6__conj (map (\x => x t f) tests)

--@derives [IRET.7.6]
--@derives [IRET.7.5.1]
||| A test WHEREVER IT STANDS in the list can be taken first: the combined
||| answer is that test's `and` the rest's.
export
iret_7_6__conj_pull : (pre : List Lnul_4_2__answer) -> (a : Lnul_4_2__answer) -> (post : List Lnul_4_2__answer) ->
                      iret_7_6__conj (pre ++ a :: post) = lnul_4_2__and a (iret_7_6__conj (pre ++ post))
iret_7_6__conj_pull [] a post = Refl
iret_7_6__conj_pull (p :: ps) a post =
  trans (cong (lnul_4_2__and p) (iret_7_6__conj_pull ps a post)) (lnul_4_2__and_left_comm p a (iret_7_6__conj (ps ++ post)))

--@derives [IRET.7.6]
||| Answering a split list of tests is answering each part.
export
iret_7_6__map_append : (g : a -> b) -> (xs, ys : List a) -> map g (xs ++ ys) = map g xs ++ map g ys
iret_7_6__map_append g [] ys = Refl
iret_7_6__map_append g (x :: xs) ys = cong (g x ::) (iret_7_6__map_append g xs ys)

--@derives [IRET.7.6]
export
iret_7_6__conj_test_pull : (pre : List Iret_7_5__test) -> (anc : Iret_7_5__test) -> (post : List Iret_7_5__test) ->
                           (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) ->
                           iret_7_6__conj_test (pre ++ anc :: post) t f = lnul_4_2__and (anc t f) (iret_7_6__conj_test (pre ++ post) t f)
iret_7_6__conj_test_pull pre anc post t f =
  trans (cong iret_7_6__conj (iret_7_6__map_append (\x => x t f) pre (anc :: post)))
        (trans (iret_7_6__conj_pull (map (\x => x t f) pre) (anc t f) (map (\x => x t f) post))
               (cong (lnul_4_2__and (anc t f)) (cong iret_7_6__conj (sym (iret_7_6__map_append (\x => x t f) pre post)))))

-- ---------------------------------------------------------------------
-- The anchor probe [IRET.7.5.1]
-- ---------------------------------------------------------------------

--@spec [IRET.7.5.1]
||| THE INDEX PROBE on an equality anchor: the bucket of candidates whose
||| anchor holds against the token. The rest of the tests run on the
||| bucket only.
public export
iret_7_5_1__probe : Iret_7_5__test -> List Lfac_1_7_1__fact -> Iret_7_1__token -> List Lfac_1_7_1__fact
iret_7_5_1__probe anc mem t = filter (\f => lnul_4_3__admits (anc t f)) mem

--@derives [LNUL.4.3]
--@derives [LNUL.4.2]
||| A positive node admits an `and` iff it admits both sides.
export
lnul_4_3__admits_and : (a, b : Lnul_4_2__answer) -> lnul_4_3__admits (lnul_4_2__and a b) = (lnul_4_3__admits a && lnul_4_3__admits b)
lnul_4_3__admits_and KFalse b = Refl
lnul_4_3__admits_and KTrue  KTrue  = Refl
lnul_4_3__admits_and KTrue  KFalse = Refl
lnul_4_3__admits_and KTrue  KNull  = Refl
lnul_4_3__admits_and KTrue  KTrap  = Refl
lnul_4_3__admits_and KNull  KTrue  = Refl
lnul_4_3__admits_and KNull  KFalse = Refl
lnul_4_3__admits_and KNull  KNull  = Refl
lnul_4_3__admits_and KNull  KTrap  = Refl
lnul_4_3__admits_and KTrap  KTrue  = Refl
lnul_4_3__admits_and KTrap  KFalse = Refl
lnul_4_3__admits_and KTrap  KNull  = Refl
lnul_4_3__admits_and KTrap  KTrap  = Refl

--@spec [IRET.7.5.1]
||| A decided answer: what an anchor must give every candidate for the
||| probe to be transparent at a `no` node.
public export
data Iret_7_5_1__decided : Lnul_4_2__answer -> Type where
  DecTrue  : Iret_7_5_1__decided KTrue
  DecFalse : Iret_7_5_1__decided KFalse

--@derives [LNUL.4.7]
--@derives [LNUL.4.2]
||| A candidate whose first conjunct is decided blocks iff that conjunct
||| holds and the rest blocks.
export
lnul_4_7__blocks_and_decided : (a, b : Lnul_4_2__answer) -> Iret_7_5_1__decided a ->
                               lnul_4_7__blocks (lnul_4_2__and a b) = (lnul_4_3__admits a && lnul_4_7__blocks b)
lnul_4_7__blocks_and_decided KFalse b DecFalse = Refl
lnul_4_7__blocks_and_decided KTrue KTrue  DecTrue = Refl
lnul_4_7__blocks_and_decided KTrue KFalse DecTrue = Refl
lnul_4_7__blocks_and_decided KTrue KNull  DecTrue = Refl
lnul_4_7__blocks_and_decided KTrue KTrap  DecTrue = Refl

-- Filters agreeing on the list (`lcyc_1_1__filter_ext_on`) and two
-- filters as one on the conjunction (`lcyc_1_1__filter_filter`) are
-- Rete/NetworkView.idr's.

--@derives [IRET.7.5.1]
--@derives [IRET.7.6]
--@derives [LNUL.4.3]
||| THE PROBE IS TRANSPARENT AT A POSITIVE NODE, for an anchor wherever it
||| stands: probing the bucket and running the other tests on it admits
||| exactly the candidates the whole test list admits — traps included.
export
iret_7_5_1__probe_positive : (pre : List Iret_7_5__test) -> (anc : Iret_7_5__test) -> (post : List Iret_7_5__test) ->
                             (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                             iret_7_6__joining (iret_7_6__node_join False (iret_7_6__conj_test (pre ++ anc :: post))) mem t
                               = iret_7_6__joining (iret_7_6__node_join False (iret_7_6__conj_test (pre ++ post))) (iret_7_5_1__probe anc mem t) t
iret_7_5_1__probe_positive pre anc post mem t =
  trans (lcyc_1_1__filter_ext_on (iret_7_6__node_join False (iret_7_6__conj_test (pre ++ anc :: post)) t)
                                 (\f => lnul_4_3__admits (anc t f) && lnul_4_3__admits (iret_7_6__conj_test (pre ++ post) t f)) mem (\f, _ =>
           trans (cong lnul_4_3__admits (iret_7_6__conj_test_pull pre anc post t f))
                 (lnul_4_3__admits_and (anc t f) (iret_7_6__conj_test (pre ++ post) t f))))
        (sym (lcyc_1_1__filter_filter (\f => lnul_4_3__admits (anc t f)) (\f => lnul_4_3__admits (iret_7_6__conj_test (pre ++ post) t f)) mem))

--@derives [IRET.7.5.1]
--@derives [IRET.7.6]
--@derives [LNUL.4.7]
||| THE PROBE IS TRANSPARENT AT A `no` NODE WHEN THE ANCHOR IS DECIDED on
||| every candidate: the blockers found in the bucket are exactly the
||| blockers of the whole test list, so the count, and whether the token
||| passes, are the same.
export
iret_7_5_1__probe_negated : (pre : List Iret_7_5__test) -> (anc : Iret_7_5__test) -> (post : List Iret_7_5__test) ->
                            (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                            ((f : Lfac_1_7_1__fact) -> Elem f mem -> Iret_7_5_1__decided (anc t f)) ->
                            iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ anc :: post))) mem t
                              = iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ post))) (iret_7_5_1__probe anc mem t) t
iret_7_5_1__probe_negated pre anc post mem t dec =
  trans (lcyc_1_1__filter_ext_on (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ anc :: post)) t)
                                 (\f => lnul_4_3__admits (anc t f) && lnul_4_7__blocks (iret_7_6__conj_test (pre ++ post) t f)) mem (\f, e =>
           trans (cong lnul_4_7__blocks (iret_7_6__conj_test_pull pre anc post t f))
                 (lnul_4_7__blocks_and_decided (anc t f) (iret_7_6__conj_test (pre ++ post) t f) (dec f e))))
        (sym (lcyc_1_1__filter_filter (\f => lnul_4_3__admits (anc t f)) (\f => lnul_4_7__blocks (iret_7_6__conj_test (pre ++ post) t f)) mem))

--@derives [IRET.7.5.1]
--@derives [IRET.7.9.1]
||| And so the block count.
export
iret_7_5_1__probe_negated_count : (pre : List Iret_7_5__test) -> (anc : Iret_7_5__test) -> (post : List Iret_7_5__test) ->
                                  (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                                  ((f : Lfac_1_7_1__fact) -> Elem f mem -> Iret_7_5_1__decided (anc t f)) ->
                                  iret_7_9_1__blockers (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ anc :: post))) mem t
                                    = iret_7_9_1__blockers (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ post))) (iret_7_5_1__probe anc mem t) t
iret_7_5_1__probe_negated_count pre anc post mem t dec = cong length (iret_7_5_1__probe_negated pre anc post mem t dec)

--@derives [IRET.7.5.1]
--@derives [LNUL.4.7]
||| WHY THE CONDITION: a candidate whose anchor answers `null` blocks the
||| token under the whole test ([LNUL.4.7]: `null` blocks), and the probe,
||| which finds only candidates whose anchor holds, never sees it — one
||| blocker against none, so the node would pass a token it must hold back.
export
iret_7_5_1__null_anchor_escapes_probe :
  ( iret_7_9_1__blockers (iret_7_6__node_join True (iret_7_6__conj_test [\_, _ => KNull])) [MkFact 1 1 1 0] [] = 1
  , iret_7_9_1__blockers (iret_7_6__node_join True (iret_7_6__conj_test [])) (iret_7_5_1__probe (\_, _ => KNull) [MkFact 1 1 1 0] []) [] = 0 )
iret_7_5_1__null_anchor_escapes_probe = (Refl, Refl)

--@spec [LNUL.8.10]
--@spec [LNLS.3.3]
||| Two non-null values of one type: what a `nolinscan` anchor compares,
||| since it pins `key` slots of one schema's type on each side and a `key`
||| slot is never `null`.
public export
data Lnul_8_10__same_typed : Lnul_2_1__value -> Lnul_2_1__value -> Type where
  BothInt  : (a, b : Integer) -> Lnul_8_10__same_typed (VInt a) (VInt b)
  BothStr  : (a, b : Lstr_1_1__text) -> Lnul_8_10__same_typed (VStr a) (VStr b)
  BothBool : (a, b : Bool) -> Lnul_8_10__same_typed (VBool a) (VBool b)

--@derives [IRET.7.5.1]
||| A Bool as an answer is decided.
export
iret_7_5_1__bool_decided : (b : Bool) -> Iret_7_5_1__decided (lnul_4_2__answer_of (RVal (VBool b)))
iret_7_5_1__bool_decided True = DecTrue
iret_7_5_1__bool_decided False = DecFalse

--@derives [IRET.7.5.1]
--@derives [LNUL.8.10]
--@derives [LNLS.3.3]
||| A `nolinscan` ANCHOR IS DECIDED: an equality of two non-null values of
||| one type answers `true` or `false`, never `null` and never a trap — so
||| `iret_7_5_1__probe_negated`'s condition holds for every `no` node a
||| `nolinscan` program can load.
export
iret_7_5_1__typed_anchor_decided : (x, y : Lnul_2_1__value) -> Lnul_8_10__same_typed x y ->
                                   Iret_7_5_1__decided (lnul_4_2__answer_of (lnul_4_1__cmp OpEq x y))
iret_7_5_1__typed_anchor_decided (VInt a) (VInt b) (BothInt a b) = iret_7_5_1__bool_decided (a == b)
iret_7_5_1__typed_anchor_decided (VStr a) (VStr b) (BothStr a b) = iret_7_5_1__bool_decided (lstr_3_1__eq a b)
iret_7_5_1__typed_anchor_decided (VBool a) (VBool b) (BothBool a b) = iret_7_5_1__bool_decided (a == b)

--@spec [LNLS.3.3]
--@spec [IRET.7.5.1]
||| THE ANCHOR AS A TEST: the equality of the slot the token pins against
||| the slot of the candidate, read by two slot functions. The equality of
||| [IRET.7.5.1]'s `BINOP(EQ, VAR(left, i, j), VAR(right, k))`, with the
||| slot reads abstracted.
public export
lnls_3_3__anchor_test : (Iret_7_1__token -> Lnul_2_1__value) -> (Lfac_1_7_1__fact -> Lnul_2_1__value) -> Iret_7_5__test
lnls_3_3__anchor_test keyT keyF = \t, f => lnul_4_2__answer_of (lnul_4_1__cmp OpEq (keyT t) (keyF f))

--@derives [LNLS.3.3]
--@derives [IRET.7.5.1]
--@derives [LNUL.8.10]
||| A `no` NODE UNDER `nolinscan` PROBES ON ITS ANCHOR WITHOUT LOSS, when
||| the two slots the anchor compares are non-null and of one type on every
||| candidate: the blockers found in the bucket are the blockers of the
||| whole test list. [LNLS.3.3]'s negated case, composed with
||| `iret_7_5_1__probe_negated` through `iret_7_5_1__typed_anchor_decided`.
||| The premise is [LNUL.8.10]'s gift when both slots are `key` slots -- the
||| clause's keyed form -- and is NOT given by the clause's singleton form,
||| whose anchor pins a `key` slot to a payload slot of the singleton that
||| nothing forbids being nullable (header).
export
lnls_3_3__negated_anchor_probe : (pre, post : List Iret_7_5__test) ->
                                 (keyT : Iret_7_1__token -> Lnul_2_1__value) -> (keyF : Lfac_1_7_1__fact -> Lnul_2_1__value) ->
                                 (mem : List Lfac_1_7_1__fact) -> (t : Iret_7_1__token) ->
                                 ((f : Lfac_1_7_1__fact) -> Elem f mem -> Lnul_8_10__same_typed (keyT t) (keyF f)) ->
                                 iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ lnls_3_3__anchor_test keyT keyF :: post))) mem t
                                   = iret_7_6__joining (iret_7_6__node_join True (iret_7_6__conj_test (pre ++ post))) (iret_7_5_1__probe (lnls_3_3__anchor_test keyT keyF) mem t) t
lnls_3_3__negated_anchor_probe pre post keyT keyF mem t typed =
  iret_7_5_1__probe_negated pre (lnls_3_3__anchor_test keyT keyF) post mem t
    (\f, e => iret_7_5_1__typed_anchor_decided (keyT t) (keyF f) (typed f e))

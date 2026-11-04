-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, PART ONE: THE TWO RECOMPUTES AGREE. Rete/FireLoop.idr
||| recomputes a rule's matches from working memory as the tuples of its
||| positive kinds that pass the guard, marking those a `no` pattern
||| blocks ([IRET.7.4], [IRET.7.9]); Rete/Network.idr's recompute walks
||| the chain, extending at each positive node and dropping at each NOT
||| node what the memory blocks ([IRET.7.7], [IRET.7.9.1]). Through the
||| rule a chain lowers to (RLOW.4.2.1, RLOW.5.1, RLOW.5.3,
||| RLOW.5.5) the two agree as sets: the network's recompute is
||| FireLoop's match set less the blocked. With the view theorem, every
||| terminal of the network holds exactly the unblocked matches FireLoop's
||| table holds; the transfer of the TMS, termination, pump-boundary and
||| TTL results is then a statement about order and flags alone.
module Rete.NetworkAgree

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
import Rete.NetworkCorollaries
import Rete.NetworkRefraction
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Positions in a token
-- ---------------------------------------------------------------------

--@derives [RLOW.5.5]
||| The fact at the position after a prefix.
export
rlow_5_5__nth_append : (u : List a) -> (x : a) -> (s : List a) -> rarc_5_6_5__nth (length u) (u ++ x :: s) = Just x
rlow_5_5__nth_append [] x s = Refl
rlow_5_5__nth_append (y :: u) x s = rlow_5_5__nth_append u x s

--@derives [RLOW.5.5]
||| The prefix of its own length.
export
rlow_5_5__take_append : (u, s : List a) -> take (length u) (u ++ s) = u
rlow_5_5__take_append [] s = Refl
rlow_5_5__take_append (y :: u) s = cong (y ::) (rlow_5_5__take_append u s)

--@derives [IRET.7.9]
export
iret_7_9__any_false : (p : a -> Bool) -> (xs : List a) -> ((x : a) -> Elem x xs -> p x = False) -> rarc_5_6_5__any p xs = False
iret_7_9__any_false p [] h = Refl
iret_7_9__any_false p (x :: xs) h with (p x) proof px
  iret_7_9__any_false p (x :: xs) h | True = absurd (trans (sym px) (h x Here))
  iret_7_9__any_false p (x :: xs) h | False = iret_7_9__any_false p xs (\y, ey => h y (There ey))

-- ---------------------------------------------------------------------
-- Blocking, one `no` pattern at a time
-- ---------------------------------------------------------------------

--@derives [RLOW.5.3]
--@derives [IRET.7.9]
||| The tests of a rule's `no` patterns; named so that no statement
||| mentions a projection unapplied.
public export
rlow_5_3__tests : List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> List (Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)
rlow_5_3__tests negs = map snd negs

--@derives [RLOW.5.3]
--@derives [IRET.7.9]
||| The live facts of each `no` pattern's kind, as Rete/FireLoop.idr reads them.
public export
rlow_5_3__facts : Rarc_5_6_4__wm -> List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> List (List Lfac_1_7_1__fact)
rlow_5_3__facts wm negs = map (\nb => rarc_5_6_4__facts_of_kind (fst nb) wm) negs

--@derives [IRET.7.9]
||| Unblocked by a list of `no` patterns: unblocked by the first and by the rest.
export
iret_7_9__blocked_cons_inv : (test : Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> (bs : List (Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                             (fk : List Lfac_1_7_1__fact) -> (fss : List (List Lfac_1_7_1__fact)) -> (tok : Iret_7_1__token) ->
                             iret_7_9__is_blocked_with (test :: bs) (fk :: fss) tok = False ->
                             (rarc_5_6_5__any (test tok) fk = False, iret_7_9__is_blocked_with bs fss tok = False)
iret_7_9__blocked_cons_inv test bs fk fss tok h =
  let (pHead :: pTail) = lcyc_1_1__any_false_all (\bfl => rarc_5_6_5__any (fst bfl tok) (snd bfl)) ((test, fk) :: zip bs fss) h
  in (pHead, iret_7_9__any_false (\bfl => rarc_5_6_5__any (fst bfl tok) (snd bfl)) (zip bs fss) (\x, ex => lcyc_1_1__all_lookup pTail ex))

--@derives [IRET.7.9]
export
iret_7_9__blocked_cons : (test : Iret_7_1__token -> Lfac_1_7_1__fact -> Bool) -> (bs : List (Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)) ->
                         (fk : List Lfac_1_7_1__fact) -> (fss : List (List Lfac_1_7_1__fact)) -> (tok : Iret_7_1__token) ->
                         rarc_5_6_5__any (test tok) fk = False -> iret_7_9__is_blocked_with bs fss tok = False ->
                         iret_7_9__is_blocked_with (test :: bs) (fk :: fss) tok = False
iret_7_9__blocked_cons test bs fk fss tok h1 h2 =
  iret_7_9__any_false (\bfl => rarc_5_6_5__any (fst bfl tok) (snd bfl)) ((test, fk) :: zip bs fss) (\x, ex =>
    case iret_11_3__elem_cons ex of
      Left p  => replace {p = \z => rarc_5_6_5__any (fst z tok) (snd z) = False} (sym p) h1
      Right e => lcyc_1_1__all_lookup (lcyc_1_1__any_false_all (\bfl => rarc_5_6_5__any (fst bfl tok) (snd bfl)) (zip bs fss) h2) e)

--@derives [IRET.7.9.1]
||| A prefix with zero blockers in the node's memory is joined by no
||| fact of the node's kind that the alpha admits.
export
iret_7_9_1__none_of_kind : (alpha : Iret_6_1__alpha) -> (j : Iret_7_5__join) -> (wm : Rarc_5_6_4__wm) -> (u : Iret_7_1__token) ->
                           iret_7_9_1__blockers j (iret_6_5__view alpha wm) u = 0 ->
                           (f : Lfac_1_7_1__fact) -> Elem f (rarc_5_6_4__facts_of_kind (akind alpha) wm) -> (iret_6_4__admits alpha f && j u f) = False
iret_7_9_1__none_of_kind alpha j wm u z f ef with (iret_6_4__admits alpha f) proof adm
  iret_7_9_1__none_of_kind alpha j wm u z f ef | False = Refl
  iret_7_9_1__none_of_kind alpha j wm u z f ef | True =
    iret_7_9_1__blockers_zero j (iret_6_5__view alpha wm) u z f
      (lcyc_1_1__elem_filter_fwd (iret_6_4__admits alpha) wm (fst (lcyc_1_1__elem_filter_inv (\g => fkind g == akind alpha) wm ef)) adm)

--@derives [IRET.7.9.1]
||| Conversely, a prefix joined by no admitted fact of the kind has zero blockers.
export
iret_7_9_1__zero_of_none : (alpha : Iret_6_1__alpha) -> (j : Iret_7_5__join) -> (wm : Rarc_5_6_4__wm) -> (u : Iret_7_1__token) ->
                           ((f : Lfac_1_7_1__fact) -> Elem f (rarc_5_6_4__facts_of_kind (akind alpha) wm) -> (iret_6_4__admits alpha f && j u f) = False) ->
                           iret_7_9_1__blockers j (iret_6_5__view alpha wm) u = 0
iret_7_9_1__zero_of_none alpha j wm u h =
  cong length (lcyc_1_1__filter_all_false (j u) (iret_6_5__view alpha wm)
    (lcyc_1_1__all_from_elem (iret_6_5__view alpha wm) (\f, ef =>
       let (efw, adm) = lcyc_1_1__elem_filter_inv (iret_6_4__admits alpha) wm ef
           efk : Elem f (rarc_5_6_4__facts_of_kind (akind alpha) wm)
           efk = lcyc_1_1__elem_filter_fwd (\g => fkind g == akind alpha) wm efw (lcyc_1_1__and_true_l _ _ adm)
       in replace {p = \b => (b && j u f) = False} adm (h f efk))))

-- ---------------------------------------------------------------------
-- The two recomputes, from a front
-- ---------------------------------------------------------------------

--@spec [RLOW.4.2.1]
--@spec [IRET.7.4]
||| A token of Rete/FireLoop.idr's recompute from a front: a prefix of
||| the front extended by a tuple of the remaining positive kinds, passing
||| the guard from position i, blocked by no `no` pattern from position i.
public export
Rlow_4_2_1__from_front : List Iret_6_1__alpha -> Rarc_5_6_4__wm -> List Iret_7_4__beta -> Nat -> List Iret_7_1__token -> Iret_7_1__token -> Type
Rlow_4_2_1__from_front alphas wm nodes i front tok =
  (u ** (s ** ( Elem u front
              , Elem s (iret_7_4__tuples (rlow_5_1__pos_kinds alphas nodes) wm)
              , tok = u ++ s
              , rlow_5_5__guard_from alphas nodes i tok = True
              , iret_7_9__is_blocked_with (rlow_5_3__tests (rlow_5_3__negs_from alphas nodes i)) (rlow_5_3__facts wm (rlow_5_3__negs_from alphas nodes i)) tok = False )))

--@derives [RLOW.4.2.1]
--@derives [IRET.7.7]
||| Extending a front of prefixes of one length gives prefixes one longer.
export
rlow_4_2_1__extend_lengths : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (front : List Iret_7_1__token) -> (i : Nat) ->
                             All (\u => length u = i) front -> All (\u => length u = S i) (iret_7_7__extend_front j mem front)
rlow_4_2_1__extend_lengths j mem front i lens =
  lcyc_1_1__all_from_elem (iret_7_7__extend_front j mem front) (\u', e =>
    let (u ** (f ** (eu, _, _, ueq))) = iret_7_7__extend_elem_inv j mem front u' e
    in replace {p = \x => length x = S i} (sym ueq) (trans (iret_7_9_1__length_snoc u f) (cong S (lcyc_1_1__all_lookup lens eu))))

--@derives [RLOW.5.5]
||| The prefix of a token from a front is the front's token.
export
rlow_5_5__prefix_of : (u, s, tok : Iret_7_1__token) -> (i : Nat) -> length u = i -> tok = u ++ s -> take i tok = u
rlow_5_5__prefix_of u s tok i lu teq =
  replace {p = \n => take n tok = u} lu (replace {p = \t => take (length u) t = u} (sym teq) (rlow_5_5__take_append u s))

--@derives [RLOW.5.5]
||| The fact at a position of a token from a front.
export
rlow_5_5__fact_at : (u : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> (s, tok : Iret_7_1__token) -> (i : Nat) -> length u = i -> tok = u ++ (f :: s) ->
                    rarc_5_6_5__nth i tok = Just f
rlow_5_5__fact_at u f s tok i lu teq =
  replace {p = \n => rarc_5_6_5__nth n tok = Just f} lu (replace {p = \t => rarc_5_6_5__nth (length u) t = Just f} (sym teq) (rlow_5_5__nth_append u f s))

--@derives [RLOW.4.2.1]
--@derives [IRET.7.7]
--@derives [IRET.7.9.1]
||| EVERY TOKEN OF THE NETWORK'S RECOMPUTE from a front is a token of
||| FireLoop's: at a positive node the joining fact is a fact of the
||| kind passing the guard; at a NOT node zero blockers is the `no`
||| pattern not blocking.
export
rlow_4_2_1__view_from_front : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (nodes : List Iret_7_4__beta) -> (i : Nat) ->
                              (front : List Iret_7_1__token) -> All (\u => length u = i) front ->
                              (tok : Iret_7_1__token) -> Elem tok (iret_7_7__view alphas wm nodes front) -> Rlow_4_2_1__from_front alphas wm nodes i front tok
rlow_4_2_1__view_from_front alphas wm [] i front lens tok e =
  (tok ** ([] ** (e, Here, sym (appendNilRightNeutral tok), Refl, Refl)))
rlow_4_2_1__view_from_front alphas wm (MkBeta a j True lm cs :: rest) i front lens tok e =
  let (u ** (s ** (eu, es, teq, gd, nb))) =
        rlow_4_2_1__view_from_front alphas wm rest i (iret_7_9_1__pass j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front)
          (lcyc_1_1__all_filter _ front lens) tok e
      (eu', z) = iret_7_9_1__pass_elem_inv j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front u eu
      takeEq : (take i tok = u)
      takeEq = rlow_5_5__prefix_of u s tok i (lcyc_1_1__all_lookup lens eu') teq
      noneHere : (rarc_5_6_5__any ((\tuple, f => iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j (take i tuple) f) tok)
                                  (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm) = False)
      noneHere = iret_7_9__any_false _ _ (\f, ef =>
                   replace {p = \v => (iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j v f) = False} (sym takeEq)
                     (iret_7_9_1__none_of_kind (iret_6_6__alpha_at alphas a) j wm u z f ef))
  in (u ** (s ** (eu', es, teq, gd,
        iret_7_9__blocked_cons (\tuple, f => iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j (take i tuple) f)
          (rlow_5_3__tests (rlow_5_3__negs_from alphas rest i))
          (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm)
          (rlow_5_3__facts wm (rlow_5_3__negs_from alphas rest i)) tok noneHere nb)))
rlow_4_2_1__view_from_front alphas wm (MkBeta a j False lm cs :: rest) i front lens tok e =
  let (u' ** (s ** (eu', es, teq, gd, nb))) =
        rlow_4_2_1__view_from_front alphas wm rest (S i) (iret_7_7__extend_front j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front)
          (rlow_4_2_1__extend_lengths j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front i lens) tok e
      (u ** (f ** (eu, ef, jf, ueq))) = iret_7_7__extend_elem_inv j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front u' eu'
      (efw, adm) = lcyc_1_1__elem_filter_inv (iret_6_4__admits (iret_6_6__alpha_at alphas a)) wm ef
      efk : Elem f (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm)
      efk = lcyc_1_1__elem_filter_fwd (\g => fkind g == akind (iret_6_6__alpha_at alphas a)) wm efw (lcyc_1_1__and_true_l _ _ adm)
      lu : (length u = i)
      lu = lcyc_1_1__all_lookup lens eu
      tokEq : (tok = u ++ (f :: s))
      tokEq = trans teq (trans (cong (\x => x ++ s) ueq) (sym (appendAssociative u [f] s)))
      nthEq : (rarc_5_6_5__nth i tok = Just f)
      nthEq = rlow_5_5__fact_at u f s tok i lu tokEq
      takeEq : (take i tok = u)
      takeEq = rlow_5_5__prefix_of u (f :: s) tok i lu tokEq
      jf' : (j (take i tok) f = True)
      jf' = replace {p = \v => j v f = True} (sym takeEq) jf
      es' : Elem (f :: s) (iret_7_4__tuples (akind (iret_6_6__alpha_at alphas a) :: rlow_5_1__pos_kinds alphas rest) wm)
      es' = iret_12_2__elem_concat_map (\g => map (g ::) (iret_7_4__tuples (rlow_5_1__pos_kinds alphas rest) wm))
              (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm) efk (lcyc_1_1__elem_map_fwd (f ::) es)
      gdHere : (rlow_5_5__guard_at alphas (MkBeta a j False lm cs) i tok (rlow_5_5__guard_from alphas rest (S i) tok) (Just f) = True)
      gdHere = iret_12__and_both _ _ (iret_12__and_both _ _ adm jf') gd
  in (u ** ((f :: s) ** (eu, es', tokEq,
        replace {p = \m => rlow_5_5__guard_at alphas (MkBeta a j False lm cs) i tok (rlow_5_5__guard_from alphas rest (S i) tok) m = True} (sym nthEq) gdHere,
        nb)))

--@derives [RLOW.4.2.1]
--@derives [IRET.7.4]
--@derives [IRET.7.9]
||| EVERY TOKEN OF FIRELOOP'S RECOMPUTE from a front is a token of the
||| network's: the guard's fact at each position is the join the node
||| makes, and an unblocking `no` pattern is a NOT node with zero
||| blockers.
export
rlow_4_2_1__from_front_view : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (nodes : List Iret_7_4__beta) -> (i : Nat) ->
                              (front : List Iret_7_1__token) -> All (\u => length u = i) front ->
                              (tok : Iret_7_1__token) -> Rlow_4_2_1__from_front alphas wm nodes i front tok -> Elem tok (iret_7_7__view alphas wm nodes front)
rlow_4_2_1__from_front_view alphas wm [] i front lens tok (u ** (s ** (eu, es, teq, gd, nb))) =
  let sNil : (s = [])
      sNil = iret_12__elem_singleton es
      tokU : (tok = u)
      tokU = trans teq (trans (cong (u ++) sNil) (appendNilRightNeutral u))
  in replace {p = \z => Elem z front} (sym tokU) eu
rlow_4_2_1__from_front_view alphas wm (MkBeta a j True lm cs :: rest) i front lens tok (u ** (s ** (eu, es, teq, gd, nb))) =
  let (hereF, restF) = iret_7_9__blocked_cons_inv (\tuple, f => iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j (take i tuple) f)
                         (rlow_5_3__tests (rlow_5_3__negs_from alphas rest i))
                         (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm)
                         (rlow_5_3__facts wm (rlow_5_3__negs_from alphas rest i)) tok nb
      takeEq : (take i tok = u)
      takeEq = rlow_5_5__prefix_of u s tok i (lcyc_1_1__all_lookup lens eu) teq
      noneAll = lcyc_1_1__any_false_all ((\tuple, f => iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j (take i tuple) f) tok)
                  (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm) hereF
      z : (iret_7_9_1__blockers j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) u = 0)
      z = iret_7_9_1__zero_of_none (iret_6_6__alpha_at alphas a) j wm u (\f, ef =>
            replace {p = \v => (iret_6_4__admits (iret_6_6__alpha_at alphas a) f && j v f) = False} takeEq (lcyc_1_1__all_lookup noneAll ef))
  in rlow_4_2_1__from_front_view alphas wm rest i (iret_7_9_1__pass j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front)
       (lcyc_1_1__all_filter _ front lens) tok
       (u ** (s ** (iret_7_9_1__pass_elem_fwd j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front u eu z, es, teq, gd, restF)))
rlow_4_2_1__from_front_view alphas wm (MkBeta a j False lm cs :: rest) i front lens tok (u ** (s ** (eu, es, teq, gd, nb))) =
  let (f ** (efk, esm)) = iret_7_7__elem_concat_inv (\g => map (g ::) (iret_7_4__tuples (rlow_5_1__pos_kinds alphas rest) wm))
                            (rarc_5_6_4__facts_of_kind (akind (iret_6_6__alpha_at alphas a)) wm) es
      (s' ** (es', seq)) = lcyc_1_1__elem_map_inv (f ::) (iret_7_4__tuples (rlow_5_1__pos_kinds alphas rest) wm) esm
      lu : (length u = i)
      lu = lcyc_1_1__all_lookup lens eu
      tokEq : (tok = u ++ (f :: s'))
      tokEq = trans teq (cong (u ++) (sym seq))
      nthEq : (rarc_5_6_5__nth i tok = Just f)
      nthEq = rlow_5_5__fact_at u f s' tok i lu tokEq
      takeEq : (take i tok = u)
      takeEq = rlow_5_5__prefix_of u (f :: s') tok i lu tokEq
      gdHere : (rlow_5_5__guard_at alphas (MkBeta a j False lm cs) i tok (rlow_5_5__guard_from alphas rest (S i) tok) (Just f) = True)
      gdHere = replace {p = \m => rlow_5_5__guard_at alphas (MkBeta a j False lm cs) i tok (rlow_5_5__guard_from alphas rest (S i) tok) m = True} nthEq gd
      adm : (iret_6_4__admits (iret_6_6__alpha_at alphas a) f = True)
      adm = lcyc_1_1__and_true_l _ _ (lcyc_1_1__and_true_l _ _ gdHere)
      jf : (j u f = True)
      jf = replace {p = \v => j v f = True} takeEq (lcyc_1_1__and_true_r _ _ (lcyc_1_1__and_true_l _ _ gdHere))
      gd' : (rlow_5_5__guard_from alphas rest (S i) tok = True)
      gd' = lcyc_1_1__and_true_r _ _ gdHere
      efm : Elem f (iret_6_5__view (iret_6_6__alpha_at alphas a) wm)
      efm = lcyc_1_1__elem_filter_fwd (iret_6_4__admits (iret_6_6__alpha_at alphas a)) wm
              (fst (lcyc_1_1__elem_filter_inv (\g => fkind g == akind (iret_6_6__alpha_at alphas a)) wm efk)) adm
      eu' : Elem (u ++ [f]) (iret_7_7__extend_front j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front)
      eu' = iret_7_7__extend_elem_fwd j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front u f eu efm jf
  in rlow_4_2_1__from_front_view alphas wm rest (S i) (iret_7_7__extend_front j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front)
       (rlow_4_2_1__extend_lengths j (iret_6_5__view (iret_6_6__alpha_at alphas a) wm) front i lens) tok
       ((u ++ [f]) ** (s' ** (eu', es', trans tokEq (appendAssociative u [f] s'), gd', nb)))

-- ---------------------------------------------------------------------
-- The agreement, closed
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
--@derives [IRET.7.4]
--@derives [IRET.7.9]
||| THE TWO RECOMPUTES AGREE: the network's recompute of a chain over
||| working memory is, as a set, FireLoop's match set of the rule the
||| chain lowers to, less the matches a `no` pattern blocks.
export
rlow_4_2_1__recompute_agrees : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (c : Rlow_4_2_1__chain) ->
                               Iret_7_4__same_set (iret_7_7__view alphas wm (cnodes c) [[]])
                                                  (filter (\t => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of alphas c) wm t))
                                                          (iret_7_4__match_tuples (rlow_4_2_1__rule_of alphas c) wm))
rlow_4_2_1__recompute_agrees alphas wm c = \t =>
  ( \e => let (u ** (s ** (eu, es, teq, gd, nb))) = rlow_4_2_1__view_from_front alphas wm (cnodes c) 0 [[]] [Refl] t e
              uNil : (u = [])
              uNil = iret_12__elem_singleton eu
              tS : (t = s)
              tS = trans teq (cong (\x => x ++ s) uNil)
          in lcyc_1_1__elem_filter_fwd (\x => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of alphas c) wm x)) (iret_7_4__match_tuples (rlow_4_2_1__rule_of alphas c) wm)
               (lcyc_1_1__elem_filter_fwd (rlow_5_5__guard_from alphas (cnodes c) 0) (iret_7_4__tuples (rlow_5_1__pos_kinds alphas (cnodes c)) wm)
                  (replace {p = \z => Elem z (iret_7_4__tuples (rlow_5_1__pos_kinds alphas (cnodes c)) wm)} (sym tS) es) gd)
               (cong not nb)
  , \e => let (em, unb) = lcyc_1_1__elem_filter_inv (\x => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of alphas c) wm x)) (iret_7_4__match_tuples (rlow_4_2_1__rule_of alphas c) wm) e
              (es, gd) = lcyc_1_1__elem_filter_inv (rlow_5_5__guard_from alphas (cnodes c) 0) (iret_7_4__tuples (rlow_5_1__pos_kinds alphas (cnodes c)) wm) em
          in rlow_4_2_1__from_front_view alphas wm (cnodes c) 0 [[]] [Refl] t
               ([] ** (t ** (Here, es, Refl, gd, lcyc_1_1__not_true_is_false _ unb))) )

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
--@derives [IRET.8.1]
||| UNDER THE VIEW every terminal holds, as a set, exactly the unblocked
||| matches of the rule its chain lowers to -- what Rete/FireLoop.idr's
||| table holds with `blocked` clear.
export
rlow_4_2_1__terminal_agrees : (eng : Iret_19__engine) -> Iret_19__view eng -> (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet eng)) ->
                              Iret_7_4__same_set (iret_8_1__tuples (cacts c))
                                                 (filter (\t => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of (nalphas (enet eng)) c) (ewm eng) t))
                                                         (iret_7_4__match_tuples (rlow_4_2_1__rule_of (nalphas (enet eng)) c) (ewm eng)))
rlow_4_2_1__terminal_agrees eng v c ec =
  iret_7_4__same_set_trans _ _ _ (fst (snd (rarc_5_6_5__view_recomputed eng v) c ec)) (rlow_4_2_1__recompute_agrees (nalphas (enet eng)) (ewm eng) c)

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
--@derives [LFST.9.2.1]
||| THE TRANSFER OF CONTENT, closed at the top: after any history from a
||| loaded network, every terminal holds exactly the unblocked matches
||| FireLoop's recompute gives the rule its chain lowers to.
export
rlow_4_2_1__agree_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                  (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                  (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                  Iret_7_4__same_set (iret_8_1__tuples (cacts c))
                                    (filter (\t => not (iret_7_9__is_blocked (rlow_4_2_1__rule_of (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) c)
                                                                             (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))) t))
                                            (iret_7_4__match_tuples (rlow_4_2_1__rule_of (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) c)
                                                                    (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))))
rlow_4_2_1__agree_after_history life fuel evs alphas rules c ec =
  rlow_4_2_1__terminal_agrees _ (lfst_9_2_1__replay_net_view life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules)) c ec

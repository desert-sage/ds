-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| TWO COROLLARIES OF THE VIEW. Theorem 5: under [LNLS.3.3]'s anchor, in
||| each of its forms, a join admits at most one candidate per token --
||| J_max = 1, the semantic content of [LNLS.5.1]'s left-activation half --
||| because working memory holds at most one live fact per identity key
||| ([LFAC.1.2.2]), an invariant of the lifecycle assert this module proves
||| through every history. The forms: a FULL-KEY ANCHOR on a keyed
||| candidate (`Lnls_3_3__anchor`: one equality per `key` slot, so the key
||| is a function of the token, whether the token's side is a keyed
||| pattern's key or a singleton's slots), and a SINGLETON candidate
||| (`Lfac_1_7_2__singleton`: `logical` with an empty key, so every live
||| fact of the kind carries the one key the lowering gives the empty tuple
||| and the kind holds at most one live fact), which needs no equality at
||| all. Both give `Lnls_3_3__pinned`, the one hypothesis the J_max chain
||| reads. The singleton form is closed at the top under what "no `key`
||| slot" means for a history -- every adapter assert and every `emit` of
||| the kind carries the one key (`Lnls_3_3__keyless_events`,
||| `Lnls_3_3__keyless_program`) -- carried through every operation, as
||| uniqueness is; the chains' actions never change, which the `_actions`
||| equations state. Theorem 6: once a fact is in working memory, no
||| activation of any rule has a NOT node whose alpha admits the fact and
||| whose prefix the fact joins: the network of [IRET.7.9.2] has already
||| retracted it. So a fact one rule asserts retracts, before the next
||| selection, every activation of another rule whose `no` it satisfies --
||| read off the view: a terminal holds exactly its recompute, and the
||| recompute passes a NOT node only with zero blockers.
|||
||| WHAT THIS FILE RELIES ON BUT DOES NOT ESTABLISH: that a keyless schema
||| lowers to one key value is the abstraction, not a theorem -- a fact's
||| `fkey` stands for the key tuple, and the empty tuple has one value. The
||| keyless hypotheses state that reading for the events and the actions;
||| nothing here checks a program against its schemas. The right-activation
||| half of [LNLS.5.1] is not here, in either form (see the tie note on
||| `lnls_5_1__j_max_1_after_history`).
module Rete.NetworkCorollaries

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
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
-- One live fact per identity key [LFAC.1.2.2]
-- ---------------------------------------------------------------------

--@spec [LFAC.1.2.2]
--@spec [LFAC.1.7]
||| ONE LIVE FACT PER IDENTITY KEY for every kind under the entity
||| lifecycle -- `scope logical` with a declared key: two live facts of
||| one such kind with one key are one fact.
public export
Lfac_1_2_2__unique : (Nat -> Lscp_1_3__lifecycle) -> Rarc_5_6_4__wm -> Type
Lfac_1_2_2__unique life wm =
  (f, g : Lfac_1_7_1__fact) -> Elem f wm -> Elem g wm -> life (fkind f) = Entity -> fkind f = fkind g -> fkey f = fkey g -> f = g

--@spec [LFAC.1.2.2]
||| What a fact about to enter working memory must not clash with, by
||| its kind's lifecycle: under the entity lifecycle, no live fact of its
||| kind and key; under the others, nothing.
public export
Lfac_1_2_2__fresh_for : Lscp_1_3__lifecycle -> Nat -> Nat -> Rarc_5_6_4__wm -> Type
Lfac_1_2_2__fresh_for Entity k key wm = (g : Lfac_1_7_1__fact) -> Elem g wm -> fkind g = k -> fkey g = key -> Void
Lfac_1_2_2__fresh_for Explicit k key wm = ()
Lfac_1_2_2__fresh_for Relation k key wm = ()

--@derives [LSCP.1.3]
export
lscp_1_3__entity_not_relation : Entity = Relation -> Void
lscp_1_3__entity_not_relation Refl impossible

--@derives [LFAC.1.2.2]
||| Removing facts keeps uniqueness.
export
lfac_1_2_2__remove_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (wm : Rarc_5_6_4__wm) -> (h : Lfac_1_7_1__fact) ->
                            Lfac_1_2_2__unique life wm -> Lfac_1_2_2__unique life (rarc_5_6_4__remove_exact h wm)
lfac_1_2_2__remove_unique life wm h u f g ef eg le kk ky =
  u f g (fst (rarc_5_6_4__remove_exact_elem_inv h wm f ef)) (fst (rarc_5_6_4__remove_exact_elem_inv h wm g eg)) le kk ky

--@derives [LFAC.1.2.2]
||| A fresh fact clashes with no live fact: under the entity lifecycle by
||| freshness, under the others because no fact of its kind is an entity.
export
lfac_1_2_2__clash : (life : Nat -> Lscp_1_3__lifecycle) -> (wm : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) ->
                    (lc : Lscp_1_3__lifecycle) -> life (fkind new) = lc -> Lfac_1_2_2__fresh_for lc (fkind new) (fkey new) wm ->
                    (g : Lfac_1_7_1__fact) -> Elem g wm -> life (fkind new) = Entity -> fkind new = fkind g -> fkey new = fkey g -> Void
lfac_1_2_2__clash life wm new Entity lce fresh g eg ln kn yn = fresh g eg (sym kn) (sym yn)
lfac_1_2_2__clash life wm new Explicit lce fresh g eg ln kn yn = lscp_1_3__entity_not_explicit (trans (sym ln) lce)
lfac_1_2_2__clash life wm new Relation lce fresh g eg ln kn yn = lscp_1_3__entity_not_relation (trans (sym ln) lce)

--@derives [LFAC.1.2.2]
||| Appending a fact fresh for its kind's lifecycle keeps uniqueness.
export
lfac_1_2_2__append_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (wm : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) -> Lfac_1_2_2__unique life wm ->
                            (lc : Lscp_1_3__lifecycle) -> life (fkind new) = lc -> Lfac_1_2_2__fresh_for lc (fkind new) (fkey new) wm ->
                            Lfac_1_2_2__unique life (wm ++ [new])
lfac_1_2_2__append_unique life wm new u lc lce fresh f g ef eg le kk ky =
  case (lcyc_1_1__elem_append_inv wm ef, lcyc_1_1__elem_append_inv wm eg) of
    (Left ef', Left eg') => u f g ef' eg' le kk ky
    (Left ef', Right eg') =>
      let gn : (g = new)
          gn = iret_12__elem_singleton eg'
          kn : (fkind new = fkind f)
          kn = sym (trans kk (cong fkind gn))
          yn : (fkey new = fkey f)
          yn = sym (trans ky (cong fkey gn))
          ln : (life (fkind new) = Entity)
          ln = replace {p = \z => life z = Entity} (sym kn) le
      in void (lfac_1_2_2__clash life wm new lc lce fresh f ef' ln kn yn)
    (Right ef', Left eg') =>
      let fn : (f = new)
          fn = iret_12__elem_singleton ef'
          kn : (fkind new = fkind g)
          kn = trans (cong fkind (sym fn)) kk
          yn : (fkey new = fkey g)
          yn = trans (cong fkey (sym fn)) ky
          ln : (life (fkind new) = Entity)
          ln = replace {p = \z => life (fkind z) = Entity} fn le
      in void (lfac_1_2_2__clash life wm new lc lce fresh g eg' ln kn yn)
    (Right ef', Right eg') => trans (iret_12__elem_singleton ef') (sym (iret_12__elem_singleton eg'))

--@derives [IRET.19.1]
||| The entity an assert finds has the key asked for.
export
iret_19_1__entity_key : (k, key : Nat) -> (w : Rarc_5_6_4__wm) -> (old : Lfac_1_7_1__fact) -> iret_19_1__find_entity k key w = Just old -> fkey old = key
iret_19_1__entity_key k key w old prf =
  lcyc_1_1__nat_eq_true (fkey old) key (lcyc_1_1__and_true_r (fkind old == k) (fkey old == key) (fst (lcyc_1_1__find_just _ w prf)))

--@derives [IRET.19.1]
||| When an assert finds no entity, no live fact has the kind and key.
export
iret_19_1__find_entity_nothing : (k, key : Nat) -> (w : Rarc_5_6_4__wm) -> iret_19_1__find_entity k key w = Nothing ->
                                 (g : Lfac_1_7_1__fact) -> Elem g w -> fkind g = k -> fkey g = key -> Void
iret_19_1__find_entity_nothing k key [] prf g eg kg yg = absurd eg
iret_19_1__find_entity_nothing k key (x :: xs) prf g eg kg yg =
  let (px, rest) = lcyc_1_1__find_nothing_cons (\f => (fkind f == k) && (fkey f == key)) x xs prf
  in case iret_11_3__elem_cons eg of
       Left p =>
         let t : (((fkind g == k) && (fkey g == key)) = True)
             t = rewrite kg in rewrite yg in rewrite lcyc_1_1__nat_eq_refl k in rewrite lcyc_1_1__nat_eq_refl key in Refl
         in absurd (trans (sym (replace {p = \z => ((fkind z == k) && (fkey z == key)) = True} p t)) px)
       Right e => iret_19_1__find_entity_nothing k key xs rest g e kg yg

--@derives [LFAC.1.2.2]
--@derives [IRET.19.2]
export
iret_19_2__retract_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                            Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (iret_19_2__retract f eng))
iret_19_2__retract_unique life f eng u = lfac_1_2_2__remove_unique life (ewm eng) f u

--@derives [LFAC.1.2.2]
--@derives [IRET.19.1]
export
iret_19_1__insert_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (new : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                           Lfac_1_2_2__unique life (ewm eng) -> (lc : Lscp_1_3__lifecycle) -> life (fkind new) = lc ->
                           Lfac_1_2_2__fresh_for lc (fkind new) (fkey new) (ewm eng) ->
                           Lfac_1_2_2__unique life (ewm (iret_19_1__insert new eng))
iret_19_1__insert_unique life new eng u lc lce fresh = lfac_1_2_2__append_unique life (ewm eng) new u lc lce fresh

--@derives [LFAC.1.2.2]
--@derives [IRET.19.1]
--@derives [LFAC.2.5.3]
||| ASSERT UNDER THE LIFECYCLE keeps one live fact per key: an entity
||| assert that finds nothing inserts the only fact of its key; one that
||| finds a different value retracts the one fact of its key, then
||| inserts; the other lifecycles never insert an entity.
export
iret_19_1__assert_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                           Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (iret_19_1__assert life avoid k key pay eng))
iret_19_1__assert_unique life avoid k key pay eng u with (life k) proof lk
  iret_19_1__assert_unique life avoid k key pay eng u | Explicit = iret_19_1__insert_unique life (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng u Explicit lk ()
  iret_19_1__assert_unique life avoid k key pay eng u | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_unique life avoid k key pay eng u | Relation | (Just old) = u
    iret_19_1__assert_unique life avoid k key pay eng u | Relation | Nothing = iret_19_1__insert_unique life (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng u Relation lk ()
  iret_19_1__assert_unique life avoid k key pay eng u | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_19_1__assert_unique life avoid k key pay eng u | Entity | Nothing =
      iret_19_1__insert_unique life (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng u Entity lk (iret_19_1__find_entity_nothing k key (ewm eng) fe)
    iret_19_1__assert_unique life avoid k key pay eng u | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_unique life avoid k key pay eng u | Entity | (Just old) | True = u
      iret_19_1__assert_unique life avoid k key pay eng u | Entity | (Just old) | False =
        iret_19_1__insert_unique life (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (iret_19_2__retract old eng) (iret_19_2__retract_unique life old eng u) Entity lk
          (\g, eg, kg, yg =>
             let (eg', ne) = rarc_5_6_4__remove_exact_elem_inv old (ewm eng) g eg
                 eo : Elem old (ewm eng)
                 eo = snd (lcyc_1_1__find_just _ (ewm eng) fe)
                 lg : (life (fkind g) = Entity)
                 lg = replace {p = \z => life z = Entity} (sym (the (fkind g = k) kg)) lk
             in ne (u g old eg' eo lg (trans kg (sym (iret_19_1__entity_kind k key (ewm eng) old fe)))
                                      (trans yg (sym (iret_19_1__entity_key k key (ewm eng) old fe)))))

--@derives [LFAC.1.2.2]
--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                              Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (lscp_2_1_1__withdraw f eng))
lscp_2_1_1__withdraw_unique life f eng u with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_unique life f eng u | True = iret_19_2__retract_unique life f eng u
  lscp_2_1_1__withdraw_unique life f eng u | False = u

--@derives [LFAC.1.2.2]
--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                               Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (rarc_5_6_7__do_action_net life bound a eng))
rarc_5_6_7__do_action_unique life bound (Emit k value) eng u =
  iret_19_1__assert_unique life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng u
rarc_5_6_7__do_action_unique life bound (Withdraw i) eng u with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_unique life bound (Withdraw i) eng u | Nothing = u
  rarc_5_6_7__do_action_unique life bound (Withdraw i) eng u | (Just f) = lscp_2_1_1__withdraw_unique life f eng u

--@derives [LFAC.1.2.2]
--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (rarc_5_6_7__do_actions_net life bound as eng))
rarc_5_6_7__do_actions_unique life bound [] eng u = u
rarc_5_6_7__do_actions_unique life bound (a :: as) eng u =
  rarc_5_6_7__do_actions_unique life bound as (rarc_5_6_7__do_action_net life bound a eng) (rarc_5_6_7__do_action_unique life bound a eng u)

--@derives [LFAC.1.2.2]
--@derives [IRET.11.4]
export
iret_11_4__step_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> Lfac_1_2_2__unique life (ewm eng) ->
                         (eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' -> Lfac_1_2_2__unique life (ewm eng')
iret_11_4__step_unique life eng u eng' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_unique life eng u eng' eq | Nothing = void (absurd eq)
  iret_11_4__step_unique life eng u eng' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__step_unique life eng u eng' eq | (Just (r, j)) | Nothing = void (absurd eq)
    iret_11_4__step_unique life eng u eng' eq | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__step_unique life eng u eng' eq | (Just (r, j)) | (Just c) | Nothing = void (absurd eq)
      iret_11_4__step_unique life eng u eng' eq | (Just (r, j)) | (Just c) | (Just a) =
        replace {p = \e => Lfac_1_2_2__unique life (ewm e)} (iret_11_4__just_inj eq)
          (rarc_5_6_7__do_actions_unique life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng) u)

--@derives [LFAC.1.2.2]
--@derives [IRET.11.4]
export
iret_11_4__run_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) -> Lfac_1_2_2__unique life (ewm eng) ->
                        Lfac_1_2_2__unique life (ewm (fst (iret_11_4__run_net life fuel eng)))
iret_11_4__run_unique life Z eng u = u
iret_11_4__run_unique life (S fuel) eng u with (iret_11_4__step_net life eng) proof st
  iret_11_4__run_unique life (S fuel) eng u | Nothing = u
  iret_11_4__run_unique life (S fuel) eng u | (Just eng') with (iret_11_4__run_net life fuel eng') proof rr
    iret_11_4__run_unique life (S fuel) eng u | (Just eng') | (e, h, n) =
      replace {p = \x => Lfac_1_2_2__unique life (ewm (fst x))} rr (iret_11_4__run_unique life fuel eng' (iret_11_4__step_unique life eng u eng' st))

--@derives [LFAC.1.2.2]
--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                           Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (rarc_5_6_4__apply_net life ev eng))
rarc_5_6_4__apply_unique life (Assert k key pay) eng u = iret_19_1__assert_unique life [] k key pay eng u
rarc_5_6_4__apply_unique life (Retract i) eng u with (rarc_5_6_4__lookup_fact i (ewm eng))
  rarc_5_6_4__apply_unique life (Retract i) eng u | Nothing = u
  rarc_5_6_4__apply_unique life (Retract i) eng u | (Just f) = iret_19_2__retract_unique life f eng u

--@derives [LFAC.1.2.2]
--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                              Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (lfst_9_2_1__boundary_net life fuel ev eng))
lfst_9_2_1__boundary_unique life fuel ev eng u = iret_11_4__run_unique life fuel _ (rarc_5_6_4__apply_unique life ev eng u)

--@derives [LFAC.1.2.2]
--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps one live fact per identity key.
export
lfst_9_2_1__replay_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                          Lfac_1_2_2__unique life (ewm eng) -> Lfac_1_2_2__unique life (ewm (lfst_9_2_1__replay_net life fuel evs eng))
lfst_9_2_1__replay_unique life fuel [] eng u = u
lfst_9_2_1__replay_unique life fuel (ev :: evs) eng u = lfst_9_2_1__replay_unique life fuel evs _ (lfst_9_2_1__boundary_unique life fuel ev eng u)

--@derives [LFAC.1.2.2]
--@derives [RDSC.4a.5]
export
rdsc_4a_5__load_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) ->
                         (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                         Lfac_1_2_2__unique life (ewm (rdsc_4a_5__load alphas rules))
rdsc_4a_5__load_unique life alphas rules f g ef eg le kk ky = absurd ef

-- ---------------------------------------------------------------------
-- Theorem 5: J_max = 1 under the anchor, in each of its forms
-- [LNLS.3.3], [LNLS.5.1], [LFAC.1.7.2]
-- ---------------------------------------------------------------------

--@spec [LNLS.3.3]
--@spec [LFAC.1.7]
||| A FULL-KEY ANCHOR on a keyed candidate: the join test admits a
||| candidate for a token only with the key the token determines -- one
||| equality per `key` slot, so the candidate's whole key is a function of
||| the token. Which slots of the token the equalities read is the
||| clause's business, not this definition's: the `key` slots of a keyed
||| pattern in the prefix, or the slots of a singleton there, both pin.
||| Further constraints on top are allowed, as the clause allows them: the
||| test may be stronger, never weaker. The candidate's kind and its
||| lifecycle are the alpha's, read where the anchor is used.
public export
Lnls_3_3__anchor : (Iret_7_1__token -> Nat) -> Iret_7_5__join -> Type
Lnls_3_3__anchor keyOf j = (t : Iret_7_1__token) -> (f : Lfac_1_7_1__fact) -> j t f = True -> fkey f = keyOf t

--@spec [LFAC.1.7.2]
--@spec [LNLS.3.3]
||| EVERY LIVE FACT OF A KIND CARRIES ONE KEY: what a schema with no `key`
||| slot leaves of the key. The empty tuple has one value, so the lowering
||| gives every fact of the kind the same key, here `c`.
public export
Lnls_3_3__keyless_wm : Nat -> Nat -> Rarc_5_6_4__wm -> Type
Lnls_3_3__keyless_wm k c wm = (f : Lfac_1_7_1__fact) -> Elem f wm -> fkind f = k -> fkey f = c

--@spec [LFAC.1.7.2]
--@spec [LNLS.3.3]
||| A SINGLETON KIND, pinned by construction: `logical` with an empty key.
||| Under the entity lifecycle one key means at most one live fact
||| (`lfac_1_7_2__one_live`), so the kind's side of a join resolves to at
||| most one fact under any join test, equality or none.
public export
Lfac_1_7_2__singleton : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Nat -> Rarc_5_6_4__wm -> Type
Lfac_1_7_2__singleton life k c wm = (life k = Entity, Lnls_3_3__keyless_wm k c wm)

--@derives [LFAC.1.7.2]
--@derives [LFAC.1.2.2]
||| ONE LIVE FACT: two live facts of a singleton kind are one fact -- the
||| clause's "key = ∅: a singleton, one live fact", from one live fact per
||| key.
export
lfac_1_7_2__one_live : (life : Nat -> Lscp_1_3__lifecycle) -> (k, c : Nat) -> (wm : Rarc_5_6_4__wm) ->
                       Lfac_1_2_2__unique life wm -> Lfac_1_7_2__singleton life k c wm ->
                       (f, g : Lfac_1_7_1__fact) -> Elem f wm -> Elem g wm -> fkind f = k -> fkind g = k -> f = g
lfac_1_7_2__one_live life k c wm u (lk, one) f g ef eg kf kg =
  u f g ef eg (replace {p = \z => life z = Entity} (sym kf) lk) (trans kf (sym kg)) (trans (one f ef kf) (sym (one g eg kg)))

--@spec [LNLS.3.3]
||| WHAT EVERY FORM OF THE ANCHOR BUYS -- the clause's "each side resolves
||| to at most one live fact", as the key: two live candidates of the
||| node's kind that one token joins carry one key. A full-key anchor
||| gives it against any working memory (`lnls_3_3__anchor_pins`); a
||| singleton kind gives it under any join test (`lnls_3_3__singleton_pins`).
||| With one live fact per key ([LFAC.1.2.2]) the two candidates are one
||| fact: `lnls_5_1__j_max_1`.
public export
Lnls_3_3__pinned : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Iret_7_5__join -> Rarc_5_6_4__wm -> Type
Lnls_3_3__pinned life k j wm =
  ( life k = Entity
  , (t : Iret_7_1__token) -> (f, g : Lfac_1_7_1__fact) -> Elem f wm -> Elem g wm -> fkind f = k -> fkind g = k ->
    j t f = True -> j t g = True -> fkey f = fkey g )

--@derives [LNLS.3.3]
||| THE KEYED FORM PINS: under a full-key anchor on an entity-lifecycle
||| kind, two candidates one token joins carry the token's key, whatever
||| is live.
export
lnls_3_3__anchor_pins : (life : Nat -> Lscp_1_3__lifecycle) -> (k : Nat) -> (keyOf : Iret_7_1__token -> Nat) -> (j : Iret_7_5__join) ->
                        life k = Entity -> Lnls_3_3__anchor keyOf j -> (wm : Rarc_5_6_4__wm) -> Lnls_3_3__pinned life k j wm
lnls_3_3__anchor_pins life k keyOf j lk an wm = (lk, \t, f, g, _, _, _, _, jf, jg => trans (an t f jf) (sym (an t g jg)))

--@derives [LNLS.3.3]
--@derives [LFAC.1.7.2]
||| THE SINGLETON FORM PINS, under ANY join test -- equalities to the
||| singleton's slots, a range test, or none ("between two singletons, no
||| equality is required"): every live fact of the kind has the one key.
export
lnls_3_3__singleton_pins : (life : Nat -> Lscp_1_3__lifecycle) -> (k, c : Nat) -> (wm : Rarc_5_6_4__wm) ->
                           Lfac_1_7_2__singleton life k c wm -> (j : Iret_7_5__join) -> Lnls_3_3__pinned life k j wm
lnls_3_3__singleton_pins life k c wm (lk, one) j = (lk, \t, f, g, ef, eg, kf, kg, _, _ => trans (one f ef kf) (sym (one g eg kg)))

--@derives [LNLS.5.1]
--@derives [LNLS.3.3]
--@derives [LFAC.1.2.2]
||| J_MAX = 1: under either form of the anchor, two candidates of a live
||| memory of the node's kind joining one token are one fact.
export
lnls_5_1__j_max_1 : (life : Nat -> Lscp_1_3__lifecycle) -> (k : Nat) -> (j : Iret_7_5__join) -> (wm : Rarc_5_6_4__wm) ->
                    Lnls_3_3__pinned life k j wm -> Lfac_1_2_2__unique life wm ->
                    (mem : List Lfac_1_7_1__fact) -> ((g : Lfac_1_7_1__fact) -> Elem g mem -> (Elem g wm, fkind g = k)) ->
                    (t : Iret_7_1__token) -> (f, g : Lfac_1_7_1__fact) ->
                    Elem f (iret_7_6__joining j mem t) -> Elem g (iret_7_6__joining j mem t) -> f = g
lnls_5_1__j_max_1 life k j wm (lk, pin) u mem sub t f g ef eg =
  let (ef', jf) = lcyc_1_1__elem_filter_inv (j t) mem ef
      (eg', jg) = lcyc_1_1__elem_filter_inv (j t) mem eg
      (wf, kf) = sub f ef'
      (wg, kg) = sub g eg'
  in u f g wf wg (replace {p = \z => life z = Entity} (sym kf) lk) (trans kf (sym kg)) (pin t f g wf wg kf kg jf jg)

--@derives [IRET.11.3]
||| A distinct list whose members are pairwise equal has at most one.
export
iret_11_3__distinct_pairwise_short : (xs : List a) -> Iret_11_3__distinct xs -> ((x, y : a) -> Elem x xs -> Elem y xs -> x = y) -> LTE (length xs) 1
iret_11_3__distinct_pairwise_short [] _ _ = LTEZero
iret_11_3__distinct_pairwise_short [x] _ _ = LTESucc LTEZero
iret_11_3__distinct_pairwise_short (x :: y :: rest) (DCons nx _) h =
  void (nx (replace {p = \z => Elem z (y :: rest)} (sym (h x y Here (There Here))) Here))

--@derives [LNLS.5.1]
||| The candidate list has at most one member.
export
lnls_5_1__at_most_one : (life : Nat -> Lscp_1_3__lifecycle) -> (k : Nat) -> (j : Iret_7_5__join) -> (wm : Rarc_5_6_4__wm) ->
                        Lnls_3_3__pinned life k j wm -> Lfac_1_2_2__unique life wm ->
                        (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem -> ((g : Lfac_1_7_1__fact) -> Elem g mem -> (Elem g wm, fkind g = k)) ->
                        (t : Iret_7_1__token) -> LTE (length (iret_7_6__joining j mem t)) 1
lnls_5_1__at_most_one life k j wm pin u mem dm sub t =
  iret_11_3__distinct_pairwise_short _ (iret_11_3__distinct_filter (j t) mem dm) (\f, g, ef, eg => lnls_5_1__j_max_1 life k j wm pin u mem sub t f g ef eg)

--@derives [LNLS.5.1]
--@derives [IRET.7.2]
||| Left-activation of a pinned node extends a token by at most one
||| candidate: the clause's `beta_left_activate` in O(1).
export
lnls_5_1__extend_at_most_one : (life : Nat -> Lscp_1_3__lifecycle) -> (k : Nat) -> (j : Iret_7_5__join) -> (wm : Rarc_5_6_4__wm) ->
                               Lnls_3_3__pinned life k j wm -> Lfac_1_2_2__unique life wm ->
                               (mem : List Lfac_1_7_1__fact) -> Iret_11_3__distinct mem -> ((g : Lfac_1_7_1__fact) -> Elem g mem -> (Elem g wm, fkind g = k)) ->
                               (t : Iret_7_1__token) -> LTE (length (iret_7_2__extend_tok j mem t)) 1
lnls_5_1__extend_at_most_one life k j wm pin u mem dm sub t =
  replace {p = \n => LTE n 1} (sym (lengthMap {f = \f => t ++ [f]} (iret_7_6__joining j mem t)))
    (lnls_5_1__at_most_one life k j wm pin u mem dm sub t)

--@derives [IRET.6.4]
||| A fact an alpha admits is of the alpha's kind.
export
iret_6_4__admits_kind : (a : Iret_6_1__alpha) -> (f : Lfac_1_7_1__fact) -> iret_6_4__admits a f = True -> fkind f = akind a
iret_6_4__admits_kind a f adm = lcyc_1_1__nat_eq_true (fkind f) (akind a) (lcyc_1_1__and_true_l (fkind f == akind a) (atest a f) adm)

--@derives [IRET.6.5]
||| A member of an alpha's view is live, and of the alpha's kind.
export
iret_6_5__view_kind : (a : Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (g : Lfac_1_7_1__fact) -> Elem g (iret_6_5__view a wm) -> (Elem g wm, fkind g = akind a)
iret_6_5__view_kind a wm g e =
  let (e', adm) = lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm e
  in (e', iret_6_4__admits_kind a g adm)

--@derives [LNLS.5.1]
--@derives [LNLS.3.3]
||| At any engine with the view and one live fact per key, a node pinned in
||| either form -- its alpha's kind against its join test -- offers each
||| token at most one candidate.
export
lnls_5_1__j_max_1_engine : (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> Iret_19__view eng -> Lfac_1_2_2__unique life (ewm eng) ->
                           (b : Iret_7_4__beta) -> Lnls_3_3__pinned life (akind (iret_6_6__alpha_at (nalphas (enet eng)) (balpha b))) (bjoin b) (ewm eng) ->
                           (t : Iret_7_1__token) ->
                           LTE (length (iret_7_6__joining (bjoin b) (iret_6_6__mem_at (nalphas (enet eng)) (balpha b)) t)) 1
lnls_5_1__j_max_1_engine life (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) u b pin t =
  lnls_5_1__at_most_one life (akind (iret_6_6__alpha_at alphas (balpha b))) (bjoin b) wm pin u (iret_6_6__mem_at alphas (balpha b)) (dm (balpha b))
    (\g, e => iret_6_5__view_kind (iret_6_6__alpha_at alphas (balpha b)) wm g (replace {p = \z => Elem g z} (mv (balpha b)) e))
    t

--@derives [LNLS.5.1]
--@derives [LNLS.3.3]
--@derives [LFAC.1.2.2]
||| THEOREM 5, THE KEYED FORM, closed at the top. After any history from a
||| loaded network, at every node whose candidates are of an
||| entity-lifecycle kind and whose join test is a full-key anchor, every
||| token joins at most one fact of the node's memory. J_max = 1 is
||| enforced by the lifecycle, as [LNLS.3.3] says, not by the programmer's
||| discipline.
export
lnls_5_1__j_max_1_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                  (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                  (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                  (b : Iret_7_4__beta) -> Elem b (cnodes c) ->
                                  (k : Nat) -> akind (iret_6_6__alpha_at (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (balpha b)) = k ->
                                  life k = Entity -> (keyOf : Iret_7_1__token -> Nat) -> Lnls_3_3__anchor keyOf (bjoin b) ->
                                  (t : Iret_7_1__token) ->
                                  LTE (length (iret_7_6__joining (bjoin b) (iret_6_6__mem_at (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (balpha b)) t)) 1
lnls_5_1__j_max_1_after_history life fuel evs alphas rules c ec b eb k ak lk keyOf an t =
  lnls_5_1__j_max_1_engine life (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))
    (lfst_9_2_1__replay_net_view life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules))
    (lfst_9_2_1__replay_unique life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_unique life alphas rules))
    b
    (replace {p = \z => Lnls_3_3__pinned life z (bjoin b) (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))} (sym ak)
       (lnls_3_3__anchor_pins life k keyOf (bjoin b) lk an (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))))
    t

-- ---------------------------------------------------------------------
-- The singleton form through a history: a keyless kind stays keyless
-- [LNLS.3.3], [LFAC.1.7.2]
-- ---------------------------------------------------------------------

--@spec [LNLS.3.3]
--@spec [LFAC.1.7.2]
||| A KEYLESS KIND'S INPUTS: every adapter assert of the kind carries the
||| one key. What "the schema declares no `key` slot" means for the events
||| of a history.
public export
Lnls_3_3__keyless_events : Nat -> Nat -> List Rarc_5_6_1__event -> Type
Lnls_3_3__keyless_events k c evs = (key, pay : Nat) -> Elem (Assert k key pay) evs -> key = c

--@spec [LNLS.3.3]
--@spec [LFAC.1.7.2]
||| A KEYLESS KIND'S EMITS: every `emit` of the kind, whatever it binds,
||| carries the one key. What "no `key` slot" means for a rule's actions.
public export
Lnls_3_3__keyless_actions : Nat -> Nat -> List Lgra_10_1__action -> Type
Lnls_3_3__keyless_actions k c as =
  (value : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Elem (Emit k value) as -> (bound : List Lfac_1_7_1__fact) -> fst (value bound) = c

--@spec [LNLS.3.3]
||| A KEYLESS PROGRAM: every rule's actions are keyless for the kind.
||| Stated over the action lists, so it reads the same on the rules a
||| loader is handed and on the chains of a running engine.
public export
Lnls_3_3__keyless_program : Nat -> Nat -> List (List Lgra_10_1__action) -> Type
Lnls_3_3__keyless_program k c actss = (as : List Lgra_10_1__action) -> Elem as actss -> Lnls_3_3__keyless_actions k c as

--@derives [LNLS.3.3]
||| Removing facts keeps a kind keyless.
export
lnls_3_3__remove_keyless : (k, c : Nat) -> (wm : Rarc_5_6_4__wm) -> (h : Lfac_1_7_1__fact) ->
                           Lnls_3_3__keyless_wm k c wm -> Lnls_3_3__keyless_wm k c (rarc_5_6_4__remove_exact h wm)
lnls_3_3__remove_keyless k c wm h one f ef kf = one f (fst (rarc_5_6_4__remove_exact_elem_inv h wm f ef)) kf

--@derives [LNLS.3.3]
||| Appending a fact that carries the one key if it is of the kind keeps
||| the kind keyless.
export
lnls_3_3__append_keyless : (k, c : Nat) -> (wm : Rarc_5_6_4__wm) -> (new : Lfac_1_7_1__fact) ->
                           Lnls_3_3__keyless_wm k c wm -> (fkind new = k -> fkey new = c) -> Lnls_3_3__keyless_wm k c (wm ++ [new])
lnls_3_3__append_keyless k c wm new one kn f ef kf = case lcyc_1_1__elem_append_inv wm ef of
  Left ef' => one f ef' kf
  Right en =>
    let fn : (f = new)
        fn = iret_12__elem_singleton en
    in replace {p = \z => fkey z = c} (sym fn) (kn (trans (cong fkind (sym fn)) kf))

--@derives [LNLS.3.3]
--@derives [IRET.19.2]
export
iret_19_2__retract_keyless : (k, c : Nat) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                             Lnls_3_3__keyless_wm k c (ewm eng) -> Lnls_3_3__keyless_wm k c (ewm (iret_19_2__retract f eng))
iret_19_2__retract_keyless k c f eng one = lnls_3_3__remove_keyless k c (ewm eng) f one

--@derives [LNLS.3.3]
--@derives [IRET.19.1]
export
iret_19_1__insert_keyless : (k, c : Nat) -> (new : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                            Lnls_3_3__keyless_wm k c (ewm eng) -> (fkind new = k -> fkey new = c) -> Lnls_3_3__keyless_wm k c (ewm (iret_19_1__insert new eng))
iret_19_1__insert_keyless k c new eng one kn = lnls_3_3__append_keyless k c (ewm eng) new one kn

--@derives [LNLS.3.3]
--@derives [IRET.19.1]
||| ASSERT keeps a kind keyless when an assert of that kind carries the one
||| key: the fact inserted, if of the kind, carries it; a replaced entity
||| leaves; a no-op changes nothing.
export
iret_19_1__assert_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k', key, pay : Nat) -> (eng : Iret_19__engine) ->
                            Lnls_3_3__keyless_wm k c (ewm eng) -> (k' = k -> key = c) ->
                            Lnls_3_3__keyless_wm k c (ewm (iret_19_1__assert life avoid k' key pay eng))
iret_19_1__assert_keyless k c life avoid k' key pay eng one kn with (life k')
  iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Explicit =
    iret_19_1__insert_keyless k c (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k' key pay) eng one kn
  iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Relation with (iret_19_1__find_relation k' key pay (ewm eng))
    iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Relation | (Just old) = one
    iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Relation | Nothing =
      iret_19_1__insert_keyless k c (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k' key pay) eng one kn
  iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Entity with (iret_19_1__find_entity k' key (ewm eng))
    iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Entity | Nothing =
      iret_19_1__insert_keyless k c (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k' key pay) eng one kn
    iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Entity | (Just old) | True = one
      iret_19_1__assert_keyless k c life avoid k' key pay eng one kn | Entity | (Just old) | False =
        iret_19_1__insert_keyless k c (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k' key pay) (iret_19_2__retract old eng)
          (iret_19_2__retract_keyless k c old eng one) kn

--@derives [LNLS.3.3]
--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_keyless : (k, c : Nat) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                               Lnls_3_3__keyless_wm k c (ewm eng) -> Lnls_3_3__keyless_wm k c (ewm (lscp_2_1_1__withdraw f eng))
lscp_2_1_1__withdraw_keyless k c f eng one with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_keyless k c f eng one | True = iret_19_2__retract_keyless k c f eng one
  lscp_2_1_1__withdraw_keyless k c f eng one | False = one

--@derives [LNLS.3.3]
--@derives [RARC.5.6.7]
||| An action keeps a kind keyless when, if it is an emit of the kind, it
||| emits the one key for the match it fires on.
export
rarc_5_6_7__do_action_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                Lnls_3_3__keyless_wm k c (ewm eng) ->
                                ((value : List Lfac_1_7_1__fact -> (Nat, Nat)) -> a = Emit k value -> fst (value bound) = c) ->
                                Lnls_3_3__keyless_wm k c (ewm (rarc_5_6_7__do_action_net life bound a eng))
rarc_5_6_7__do_action_keyless k c life bound (Emit k' value) eng one ka =
  iret_19_1__assert_keyless k c life (iret_11_3__fact_ids bound) k' (fst (value bound)) (snd (value bound)) eng one
    (\kk => ka value (cong (\z => Emit z value) kk))
rarc_5_6_7__do_action_keyless k c life bound (Withdraw i) eng one ka with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_keyless k c life bound (Withdraw i) eng one ka | Nothing = one
  rarc_5_6_7__do_action_keyless k c life bound (Withdraw i) eng one ka | (Just f) = lscp_2_1_1__withdraw_keyless k c f eng one

--@derives [LNLS.3.3]
--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                 Lnls_3_3__keyless_wm k c (ewm eng) -> Lnls_3_3__keyless_actions k c as ->
                                 Lnls_3_3__keyless_wm k c (ewm (rarc_5_6_7__do_actions_net life bound as eng))
rarc_5_6_7__do_actions_keyless k c life bound [] eng one ka = one
rarc_5_6_7__do_actions_keyless k c life bound (a :: as) eng one ka =
  rarc_5_6_7__do_actions_keyless k c life bound as (rarc_5_6_7__do_action_net life bound a eng)
    (rarc_5_6_7__do_action_keyless k c life bound a eng one (\value, eq => ka value (replace {p = \z => Elem z (a :: as)} eq Here) bound))
    (\value, e, bound' => ka value (There e) bound')

-- The chains' actions never change: one equation per operation, so the
-- keyless program read off the loaded rules is read off every engine of
-- the history.

--@derives [IRET.7.7]
||| Right activation changes no chain's actions.
export
iret_7_7__activate_chain_actions : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) -> (ch : Rlow_4_2_1__chain) ->
                                   cactions (iret_7_7__activate_chain wm alphas a f ch) = cactions ch
iret_7_7__activate_chain_actions wm alphas a f ch = Refl

--@derives [IRET.7.7]
||| Right retraction changes no chain's actions.
export
iret_7_7__retract_chain_actions : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (a : Nat) -> (f : Lfac_1_7_1__fact) -> (ch : Rlow_4_2_1__chain) ->
                                  cactions (iret_7_7__retract_chain wm alphas a f ch) = cactions ch
iret_7_7__retract_chain_actions wm alphas a f ch = Refl

--@derives [IDAT.6.2.2]
||| Marking an activation fired changes no chain's actions.
export
idat_6_2_2__mark_chain_actions : (j : Nat) -> (ch : Rlow_4_2_1__chain) -> cactions (idat_6_2_2__mark_chain j ch) = cactions ch
idat_6_2_2__mark_chain_actions j ch = Refl

--@spec [LNLS.3.3]
||| THE CHAINS' ACTION LISTS, in order: what a keyless program is read off,
||| on the chains of an engine as on the rules a loader is handed. Named,
||| rather than written as the map of the projection, so the projection is
||| never passed unapplied.
public export
lnls_3_3__actions_of : List Rlow_4_2_1__chain -> List (List Lgra_10_1__action)
lnls_3_3__actions_of chains = map (\ch => cactions ch) chains

--@derives [LNLS.3.3]
||| Mapping a function that keeps each chain's actions keeps the list of
||| them.
export
lnls_3_3__map_actions : (g : Rlow_4_2_1__chain -> Rlow_4_2_1__chain) -> ((ch : Rlow_4_2_1__chain) -> cactions (g ch) = cactions ch) ->
                        (chs : List Rlow_4_2_1__chain) -> lnls_3_3__actions_of (map g chs) = lnls_3_3__actions_of chs
lnls_3_3__map_actions g gk [] = Refl
lnls_3_3__map_actions g gk (ch :: chs) = cong2 (::) (gk ch) (lnls_3_3__map_actions g gk chs)

--@derives [IRET.6.4]
||| Alpha dispatch on assert changes no chain's actions.
export
iret_6_4__dispatch_assert_actions : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                    lnls_3_3__actions_of (nchains (iret_6_4__dispatch_assert wm f is net)) = lnls_3_3__actions_of (nchains net)
iret_6_4__dispatch_assert_actions wm f [] net = Refl
iret_6_4__dispatch_assert_actions wm f (i :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f)
  iret_6_4__dispatch_assert_actions wm f (i :: is) (MkNetwork alphas chains) | False = iret_6_4__dispatch_assert_actions wm f is (MkNetwork alphas chains)
  iret_6_4__dispatch_assert_actions wm f (i :: is) (MkNetwork alphas chains) | True =
    trans (iret_6_4__dispatch_assert_actions wm f is
             (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas)
                        (map (iret_7_7__activate_chain wm (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains)))
          (lnls_3_3__map_actions (iret_7_7__activate_chain wm (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f)
             (iret_7_7__activate_chain_actions wm (rarc_5_6_5__set_at i (iret_6_5__insert f) alphas) i f) chains)

--@derives [IRET.19.2]
||| Alpha dispatch on retract changes no chain's actions.
export
iret_19_2__dispatch_retract_actions : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                      lnls_3_3__actions_of (nchains (iret_19_2__dispatch_retract wm f is net)) = lnls_3_3__actions_of (nchains net)
iret_19_2__dispatch_retract_actions wm f [] net = Refl
iret_19_2__dispatch_retract_actions wm f (i :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas i) f)
  iret_19_2__dispatch_retract_actions wm f (i :: is) (MkNetwork alphas chains) | False = iret_19_2__dispatch_retract_actions wm f is (MkNetwork alphas chains)
  iret_19_2__dispatch_retract_actions wm f (i :: is) (MkNetwork alphas chains) | True =
    trans (iret_19_2__dispatch_retract_actions wm f is
             (MkNetwork (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas)
                        (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains)))
          (lnls_3_3__map_actions (iret_7_7__retract_chain wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f)
             (iret_7_7__retract_chain_actions wm (rarc_5_6_5__set_at i (iret_6_5__remove f) alphas) i f) chains)

--@derives [IRET.19.1]
export
iret_19_1__insert_actions : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                            lnls_3_3__actions_of (nchains (enet (iret_19_1__insert f eng))) = lnls_3_3__actions_of (nchains (enet eng))
iret_19_1__insert_actions f eng = iret_6_4__dispatch_assert_actions (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)

--@derives [IRET.19.2]
export
iret_19_2__retract_actions : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                             lnls_3_3__actions_of (nchains (enet (iret_19_2__retract f eng))) = lnls_3_3__actions_of (nchains (enet eng))
iret_19_2__retract_actions f eng = iret_19_2__dispatch_retract_actions (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)

--@derives [IRET.19.1]
export
iret_19_1__assert_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                            lnls_3_3__actions_of (nchains (enet (iret_19_1__assert life avoid k key pay eng))) = lnls_3_3__actions_of (nchains (enet eng))
iret_19_1__assert_actions life avoid k key pay eng with (life k)
  iret_19_1__assert_actions life avoid k key pay eng | Explicit = iret_19_1__insert_actions (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng
  iret_19_1__assert_actions life avoid k key pay eng | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_actions life avoid k key pay eng | Relation | (Just old) = Refl
    iret_19_1__assert_actions life avoid k key pay eng | Relation | Nothing = iret_19_1__insert_actions (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng
  iret_19_1__assert_actions life avoid k key pay eng | Entity with (iret_19_1__find_entity k key (ewm eng))
    iret_19_1__assert_actions life avoid k key pay eng | Entity | Nothing = iret_19_1__insert_actions (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng
    iret_19_1__assert_actions life avoid k key pay eng | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_actions life avoid k key pay eng | Entity | (Just old) | True = Refl
      iret_19_1__assert_actions life avoid k key pay eng | Entity | (Just old) | False =
        trans (iret_19_1__insert_actions (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (iret_19_2__retract old eng)) (iret_19_2__retract_actions old eng)

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_actions : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) ->
                               lnls_3_3__actions_of (nchains (enet (lscp_2_1_1__withdraw f eng))) = lnls_3_3__actions_of (nchains (enet eng))
lscp_2_1_1__withdraw_actions f eng with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_actions f eng | True = iret_19_2__retract_actions f eng
  lscp_2_1_1__withdraw_actions f eng | False = Refl

--@derives [IDAT.6.2.2]
export
idat_6_2_2__mark_net_actions : (r, j : Nat) -> (eng : Iret_19__engine) ->
                               lnls_3_3__actions_of (nchains (enet (idat_6_2_2__mark_net r j eng))) = lnls_3_3__actions_of (nchains (enet eng))
idat_6_2_2__mark_net_actions r j eng = lcyc_1_1__map_set_at (idat_6_2_2__mark_chain j) (\ch => cactions ch) (idat_6_2_2__mark_chain_actions j) r (nchains (enet eng))

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                lnls_3_3__actions_of (nchains (enet (rarc_5_6_7__do_action_net life bound a eng))) = lnls_3_3__actions_of (nchains (enet eng))
rarc_5_6_7__do_action_actions life bound (Emit k value) eng = iret_19_1__assert_actions life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng
rarc_5_6_7__do_action_actions life bound (Withdraw i) eng with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_actions life bound (Withdraw i) eng | Nothing = Refl
  rarc_5_6_7__do_action_actions life bound (Withdraw i) eng | (Just f) = lscp_2_1_1__withdraw_actions f eng

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                 lnls_3_3__actions_of (nchains (enet (rarc_5_6_7__do_actions_net life bound as eng))) = lnls_3_3__actions_of (nchains (enet eng))
rarc_5_6_7__do_actions_actions life bound [] eng = Refl
rarc_5_6_7__do_actions_actions life bound (a :: as) eng =
  trans (rarc_5_6_7__do_actions_actions life bound as (rarc_5_6_7__do_action_net life bound a eng)) (rarc_5_6_7__do_action_actions life bound a eng)

--@derives [IRET.11.4]
export
iret_11_4__step_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (eng, eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' ->
                          lnls_3_3__actions_of (nchains (enet eng')) = lnls_3_3__actions_of (nchains (enet eng))
iret_11_4__step_actions life eng eng' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_actions life eng eng' eq | Nothing = absurd eq
  iret_11_4__step_actions life eng eng' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__step_actions life eng eng' eq | (Just (r, j)) | Nothing = absurd eq
    iret_11_4__step_actions life eng eng' eq | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__step_actions life eng eng' eq | (Just (r, j)) | (Just c) | Nothing = absurd eq
      iret_11_4__step_actions life eng eng' eq | (Just (r, j)) | (Just c) | (Just a) =
        replace {p = \e => lnls_3_3__actions_of (nchains (enet e)) = lnls_3_3__actions_of (nchains (enet eng))} (iret_11_4__just_inj eq)
          (trans (rarc_5_6_7__do_actions_actions life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng)) (idat_6_2_2__mark_net_actions r j eng))

--@derives [IRET.11.4]
export
iret_11_4__run_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                         lnls_3_3__actions_of (nchains (enet (fst (iret_11_4__run_net life fuel eng)))) = lnls_3_3__actions_of (nchains (enet eng))
iret_11_4__run_actions life Z eng = Refl
iret_11_4__run_actions life (S fuel) eng with (iret_11_4__step_net life eng) proof st
  iret_11_4__run_actions life (S fuel) eng | Nothing = Refl
  iret_11_4__run_actions life (S fuel) eng | (Just eng') with (iret_11_4__run_net life fuel eng') proof rr
    iret_11_4__run_actions life (S fuel) eng | (Just eng') | (e, h, n) =
      trans (replace {p = \x => lnls_3_3__actions_of (nchains (enet (fst x))) = lnls_3_3__actions_of (nchains (enet eng'))} rr (iret_11_4__run_actions life fuel eng'))
            (iret_11_4__step_actions life eng eng' st)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                            lnls_3_3__actions_of (nchains (enet (rarc_5_6_4__apply_net life ev eng))) = lnls_3_3__actions_of (nchains (enet eng))
rarc_5_6_4__apply_actions life (Assert k key pay) eng = iret_19_1__assert_actions life [] k key pay eng
rarc_5_6_4__apply_actions life (Retract i) eng with (rarc_5_6_4__lookup_fact i (ewm eng))
  rarc_5_6_4__apply_actions life (Retract i) eng | Nothing = Refl
  rarc_5_6_4__apply_actions life (Retract i) eng | (Just f) = iret_19_2__retract_actions f eng

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                               lnls_3_3__actions_of (nchains (enet (lfst_9_2_1__boundary_net life fuel ev eng))) = lnls_3_3__actions_of (nchains (enet eng))
lfst_9_2_1__boundary_actions life fuel ev eng = trans (iret_11_4__run_actions life fuel (rarc_5_6_4__apply_net life ev eng)) (rarc_5_6_4__apply_actions life ev eng)

--@derives [LFST.9.2.1]
||| A HISTORY changes no chain's actions.
export
lfst_9_2_1__replay_actions : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                             lnls_3_3__actions_of (nchains (enet (lfst_9_2_1__replay_net life fuel evs eng))) = lnls_3_3__actions_of (nchains (enet eng))
lfst_9_2_1__replay_actions life fuel [] eng = Refl
lfst_9_2_1__replay_actions life fuel (ev :: evs) eng =
  trans (lfst_9_2_1__replay_actions life fuel evs (lfst_9_2_1__boundary_net life fuel ev eng)) (lfst_9_2_1__boundary_actions life fuel ev eng)

--@derives [RDSC.4a.5]
||| Seeding a root changes no chain's actions.
export
rdsc_4a_5__seed_actions : (alphas : List Iret_6_1__alpha) -> (ch : Rlow_4_2_1__chain) -> cactions (rdsc_4a_5__seed alphas ch) = cactions ch
rdsc_4a_5__seed_actions alphas (MkChain nodes acts actions) = Refl

--@spec [IRET.16.6]
||| A rule as the loader is handed it: its actions. Named, so the pair's
||| projection is never written unapplied.
public export
iret_16_6__rule_actions : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List Lgra_10_1__action
iret_16_6__rule_actions (nodes, actions) = actions

--@derives [IRET.16.6]
||| The loaded terminals' actions are the rules'.
export
iret_16_6__terminals_actions : (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                               lnls_3_3__actions_of (map (\r => iret_16_6__terminal r) rules) = map (\r => iret_16_6__rule_actions r) rules
iret_16_6__terminals_actions [] = Refl
iret_16_6__terminals_actions ((nodes, actions) :: rs) = cong (actions ::) (iret_16_6__terminals_actions rs)

--@derives [RDSC.4a.5]
||| THE LOADED CHAINS' ACTIONS ARE THE RULES'.
export
rdsc_4a_5__load_actions : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          lnls_3_3__actions_of (nchains (enet (rdsc_4a_5__load alphas rules))) = map (\r => iret_16_6__rule_actions r) rules
rdsc_4a_5__load_actions alphas rules =
  trans (lnls_3_3__map_actions (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas)) (rdsc_4a_5__seed_actions (iret_16_4__alpha_nodes alphas)) (map (\r => iret_16_6__terminal r) rules))
        (iret_16_6__terminals_actions rules)

--@spec [LNLS.3.3]
||| A KEYLESS ENGINE: the kind is keyless in working memory, and every
||| chain's actions are keyless for it.
public export
Lnls_3_3__keyless_engine : Nat -> Nat -> Iret_19__engine -> Type
Lnls_3_3__keyless_engine k c eng = (Lnls_3_3__keyless_wm k c (ewm eng), Lnls_3_3__keyless_program k c (lnls_3_3__actions_of (nchains (enet eng))))

--@derives [LNLS.3.3]
--@derives [IRET.11.4]
||| A firing keeps a keyless engine keyless: the actions it runs are a
||| chain's, and so keyless; the chains' actions do not change.
export
iret_11_4__step_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> Lnls_3_3__keyless_engine k c eng ->
                          (eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' -> Lnls_3_3__keyless_engine k c eng'
iret_11_4__step_keyless k c life eng (one, prog) eng' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_keyless k c life eng (one, prog) eng' eq | Nothing = absurd eq
  iret_11_4__step_keyless k c life eng (one, prog) eng' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng))) proof nc
    iret_11_4__step_keyless k c life eng (one, prog) eng' eq | (Just (r, j)) | Nothing = absurd eq
    iret_11_4__step_keyless k c life eng (one, prog) eng' eq | (Just (r, j)) | (Just ch) with (rarc_5_6_5__nth j (cacts ch))
      iret_11_4__step_keyless k c life eng (one, prog) eng' eq | (Just (r, j)) | (Just ch) | Nothing = absurd eq
      iret_11_4__step_keyless k c life eng (one, prog) eng' eq | (Just (r, j)) | (Just ch) | (Just a) =
        replace {p = \e => Lnls_3_3__keyless_engine k c e} (iret_11_4__just_inj eq)
          ( rarc_5_6_7__do_actions_keyless k c life (atuple a) (cactions ch) (idat_6_2_2__mark_net r j eng) one
              (prog (cactions ch) (lcyc_1_1__elem_map_fwd (\ch => cactions ch) (lcyc_1_1__nth_elem r (nchains (enet eng)) nc)))
          , replace {p = \xs => Lnls_3_3__keyless_program k c xs}
              (sym (trans (rarc_5_6_7__do_actions_actions life (atuple a) (cactions ch) (idat_6_2_2__mark_net r j eng)) (idat_6_2_2__mark_net_actions r j eng)))
              prog )

--@derives [LNLS.3.3]
--@derives [IRET.11.4]
export
iret_11_4__run_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) -> Lnls_3_3__keyless_engine k c eng ->
                         Lnls_3_3__keyless_engine k c (fst (iret_11_4__run_net life fuel eng))
iret_11_4__run_keyless k c life Z eng ke = ke
iret_11_4__run_keyless k c life (S fuel) eng ke with (iret_11_4__step_net life eng) proof st
  iret_11_4__run_keyless k c life (S fuel) eng ke | Nothing = ke
  iret_11_4__run_keyless k c life (S fuel) eng ke | (Just eng') with (iret_11_4__run_net life fuel eng') proof rr
    iret_11_4__run_keyless k c life (S fuel) eng ke | (Just eng') | (e, h, n) =
      replace {p = \x => Lnls_3_3__keyless_engine k c (fst x)} rr (iret_11_4__run_keyless k c life fuel eng' (iret_11_4__step_keyless k c life eng ke eng' st))

--@derives [LNLS.3.3]
--@derives [RARC.5.6.4]
||| An input keeps a keyless engine keyless when an assert of the kind
||| carries the one key.
export
rarc_5_6_4__apply_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) -> Lnls_3_3__keyless_engine k c eng ->
                            ((key, pay : Nat) -> ev = Assert k key pay -> key = c) -> Lnls_3_3__keyless_engine k c (rarc_5_6_4__apply_net life ev eng)
rarc_5_6_4__apply_keyless k c life (Assert k' key pay) eng (one, prog) kev =
  ( iret_19_1__assert_keyless k c life [] k' key pay eng one (\kk => kev key pay (cong (\z => Assert z key pay) kk))
  , replace {p = \xs => Lnls_3_3__keyless_program k c xs} (sym (iret_19_1__assert_actions life [] k' key pay eng)) prog )
rarc_5_6_4__apply_keyless k c life (Retract i) eng (one, prog) kev with (rarc_5_6_4__lookup_fact i (ewm eng))
  rarc_5_6_4__apply_keyless k c life (Retract i) eng (one, prog) kev | Nothing = (one, prog)
  rarc_5_6_4__apply_keyless k c life (Retract i) eng (one, prog) kev | (Just f) =
    (iret_19_2__retract_keyless k c f eng one, replace {p = \xs => Lnls_3_3__keyless_program k c xs} (sym (iret_19_2__retract_actions f eng)) prog)

--@derives [LNLS.3.3]
--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (eng : Iret_19__engine) -> Lnls_3_3__keyless_engine k c eng ->
                               ((key, pay : Nat) -> ev = Assert k key pay -> key = c) -> Lnls_3_3__keyless_engine k c (lfst_9_2_1__boundary_net life fuel ev eng)
lfst_9_2_1__boundary_keyless k c life fuel ev eng ke kev = iret_11_4__run_keyless k c life fuel _ (rarc_5_6_4__apply_keyless k c life ev eng ke kev)

--@derives [LNLS.3.3]
--@derives [LFST.9.2.1]
||| EVERY HISTORY of keyless inputs keeps a keyless engine keyless.
export
lfst_9_2_1__replay_keyless : (k, c : Nat) -> (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (eng : Iret_19__engine) ->
                             Lnls_3_3__keyless_engine k c eng -> Lnls_3_3__keyless_events k c evs -> Lnls_3_3__keyless_engine k c (lfst_9_2_1__replay_net life fuel evs eng)
lfst_9_2_1__replay_keyless k c life fuel [] eng ke kev = ke
lfst_9_2_1__replay_keyless k c life fuel (ev :: evs) eng ke kev =
  lfst_9_2_1__replay_keyless k c life fuel evs _
    (lfst_9_2_1__boundary_keyless k c life fuel ev eng ke (\key, pay, eq => kev key pay (replace {p = \z => Elem z (ev :: evs)} eq Here)))
    (\key, pay, e => kev key pay (There e))

--@derives [LNLS.3.3]
--@derives [RDSC.4a.5]
||| A LOADED KEYLESS PROGRAM is a keyless engine: nothing is live, and the
||| chains' actions are the rules'.
export
rdsc_4a_5__load_keyless : (k, c : Nat) -> (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          Lnls_3_3__keyless_program k c (map (\r => iret_16_6__rule_actions r) rules) -> Lnls_3_3__keyless_engine k c (rdsc_4a_5__load alphas rules)
rdsc_4a_5__load_keyless k c alphas rules prog =
  (\f, ef, _ => absurd ef, replace {p = \xs => Lnls_3_3__keyless_program k c xs} (sym (rdsc_4a_5__load_actions alphas rules)) prog)

--@derives [LNLS.5.1]
--@derives [LNLS.3.3]
--@derives [LFAC.1.7.2]
||| THEOREM 5, THE SINGLETON FORM, closed at the top. After any history of
||| a program keyless for an entity-lifecycle kind, from keyless inputs,
||| at every node whose candidates are of that kind, every token joins at
||| most one fact of the node's memory -- under ANY join test. Pinned by
||| construction, as [LNLS.3.3] says: no equality is needed, so this is
||| also "between two singletons, no equality is required".
export
lnls_5_1__j_max_1_singleton_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                            (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                            (k, c : Nat) -> life k = Entity -> Lnls_3_3__keyless_events k c evs -> Lnls_3_3__keyless_program k c (map (\r => iret_16_6__rule_actions r) rules) ->
                                            (ch : Rlow_4_2_1__chain) -> Elem ch (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                            (b : Iret_7_4__beta) -> Elem b (cnodes ch) ->
                                            akind (iret_6_6__alpha_at (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (balpha b)) = k ->
                                            (t : Iret_7_1__token) ->
                                            LTE (length (iret_7_6__joining (bjoin b) (iret_6_6__mem_at (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (balpha b)) t)) 1
lnls_5_1__j_max_1_singleton_after_history life fuel evs alphas rules k c lk kev prog ch ec b eb ak t =
  lnls_5_1__j_max_1_engine life (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))
    (lfst_9_2_1__replay_net_view life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules))
    (lfst_9_2_1__replay_unique life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_unique life alphas rules))
    b
    (replace {p = \z => Lnls_3_3__pinned life z (bjoin b) (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))} (sym ak)
       (lnls_3_3__singleton_pins life k c (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))
          (lk, fst (lfst_9_2_1__replay_keyless k c life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_keyless k c alphas rules prog) kev))
          (bjoin b)))
    t

-- ---------------------------------------------------------------------
-- Theorem 6: a live fact blocks every NOT node it joins [IRET.7.9.2]
-- ---------------------------------------------------------------------

--@spec [IRET.7.9.1]
--@spec [IRET.7.7]
||| A TOKEN'S PASSAGE through a chain from a prefix: at a positive node it
||| grows by one fact of the memory the join admits; at a NOT node its
||| prefix has no blocker in the memory.
public export
Iret_7_9_1__clear : List Iret_6_1__alpha -> List Iret_7_4__beta -> Iret_7_1__token -> Iret_7_1__token -> Type
Iret_7_9_1__clear alphas [] u tok = (u = tok)
Iret_7_9_1__clear alphas (MkBeta a j True lm cs :: rest) u tok =
  (iret_7_9_1__blockers j (iret_6_6__mem_at alphas a) u = 0, Iret_7_9_1__clear alphas rest u tok)
Iret_7_9_1__clear alphas (MkBeta a j False lm cs :: rest) u tok =
  (f ** (Elem f (iret_6_6__mem_at alphas a), j u f = True, Iret_7_9_1__clear alphas rest (u ++ [f]) tok))

--@derives [IRET.7.7]
--@derives [IRET.7.9.1]
||| Every token a chain passes came through it clear from some token of
||| the front.
export
iret_7_7__through_clear : (alphas : List Iret_6_1__alpha) -> (nodes : List Iret_7_4__beta) -> (front : List Iret_7_1__token) -> (tok : Iret_7_1__token) ->
                          Elem tok (iret_7_7__through alphas nodes front) -> (u ** (Elem u front, Iret_7_9_1__clear alphas nodes u tok))
iret_7_7__through_clear alphas [] front tok e = (tok ** (e, Refl))
iret_7_7__through_clear alphas (MkBeta a j True lm cs :: rest) front tok e =
  let (u ** (eu, cl)) = iret_7_7__through_clear alphas rest _ tok e
      (eu', z) = iret_7_9_1__pass_elem_inv j (iret_6_6__mem_at alphas a) front u eu
  in (u ** (eu', (z, cl)))
iret_7_7__through_clear alphas (MkBeta a j False lm cs :: rest) front tok e =
  let (u' ** (eu', cl)) = iret_7_7__through_clear alphas rest _ tok e
      (t ** (f ** (et, ef, jf, ueq))) = iret_7_7__extend_elem_inv j (iret_6_6__mem_at alphas a) front u' eu'
  in (t ** (et, (f ** (ef, jf, replace {p = \z => Iret_7_9_1__clear alphas rest z tok} ueq cl))))

--@derives [IRET.7.9.1]
export
iret_7_9_1__length_zero_nil : (xs : List a) -> length xs = 0 -> xs = []
iret_7_9_1__length_zero_nil [] _ = Refl
iret_7_9_1__length_zero_nil (x :: xs) prf = absurd prf

--@derives [IRET.7.9.1]
||| With zero blockers, no fact of the memory joins the prefix.
export
iret_7_9_1__blockers_zero : (j : Iret_7_5__join) -> (mem : List Lfac_1_7_1__fact) -> (u : Iret_7_1__token) -> iret_7_9_1__blockers j mem u = 0 ->
                            (f : Lfac_1_7_1__fact) -> Elem f mem -> j u f = False
iret_7_9_1__blockers_zero j mem u z f ef with (j u f) proof jf
  iret_7_9_1__blockers_zero j mem u z f ef | False = Refl
  iret_7_9_1__blockers_zero j mem u z f ef | True =
    absurd (replace {p = \zs => Elem f zs} (iret_7_9_1__length_zero_nil (filter (j u) mem) z) (lcyc_1_1__elem_filter_fwd (j u) mem ef jf))

--@spec [IRET.7.9.2]
||| WHAT A LIVE FACT CANNOT MEET: along a token's passage, at every NOT
||| node whose alpha admits the fact, the prefix and the fact fail the
||| join test.
public export
Iret_7_9_2__rejects : Lfac_1_7_1__fact -> List Iret_6_1__alpha -> List Iret_7_4__beta -> Iret_7_1__token -> Iret_7_1__token -> Type
Iret_7_9_2__rejects f alphas [] u tok = (u = tok)
Iret_7_9_2__rejects f alphas (MkBeta a j True lm cs :: rest) u tok =
  (iret_6_4__admits (iret_6_6__alpha_at alphas a) f = True -> j u f = False, Iret_7_9_2__rejects f alphas rest u tok)
Iret_7_9_2__rejects f alphas (MkBeta a j False lm cs :: rest) u tok =
  (g ** (Elem g (iret_6_6__mem_at alphas a), j u g = True, Iret_7_9_2__rejects f alphas rest (u ++ [g]) tok))

--@derives [IRET.7.9.1]
||| A clear passage rejects every live fact at each NOT node admitting
||| it: the memory shows working memory, so the fact is among the
||| candidates counted, and the count is zero.
export
iret_7_9_1__clear_rejects : (f : Lfac_1_7_1__fact) -> (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) ->
                            ((i : Nat) -> iret_6_6__mem_at alphas i = iret_6_5__view (iret_6_6__alpha_at alphas i) wm) -> Elem f wm ->
                            (nodes : List Iret_7_4__beta) -> (u, tok : Iret_7_1__token) ->
                            Iret_7_9_1__clear alphas nodes u tok -> Iret_7_9_2__rejects f alphas nodes u tok
iret_7_9_1__clear_rejects f wm alphas mv ef [] u tok cl = cl
iret_7_9_1__clear_rejects f wm alphas mv ef (MkBeta a j True lm cs :: rest) u tok (z, cl) =
  ( \adm => iret_7_9_1__blockers_zero j (iret_6_6__mem_at alphas a) u z f
              (replace {p = \zs => Elem f zs} (sym (mv a)) (lcyc_1_1__elem_filter_fwd (iret_6_4__admits (iret_6_6__alpha_at alphas a)) wm ef adm))
  , iret_7_9_1__clear_rejects f wm alphas mv ef rest u tok cl )
iret_7_9_1__clear_rejects f wm alphas mv ef (MkBeta a j False lm cs :: rest) u tok (g ** (eg, jg, cl)) =
  (g ** (eg, jg, iret_7_9_1__clear_rejects f wm alphas mv ef rest (u ++ [g]) tok cl))

--@derives [IRET.7.9.2]
--@derives [RARC.5.6.5]
||| UNDER THE VIEW, no activation of any rule has a NOT node whose alpha
||| admits a live fact and whose prefix the fact joins: every such match
||| is blocked, and a blocked match is not on the agenda.
export
iret_7_9_2__live_rejected : (eng : Iret_19__engine) -> Iret_19__view eng -> (f : Lfac_1_7_1__fact) -> Elem f (ewm eng) ->
                            (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet eng)) -> (a : Iret_8_1__act) -> Elem a (cacts c) ->
                            Iret_7_9_2__rejects f (nalphas (enet eng)) (cnodes c) [] (atuple a)
iret_7_9_2__live_rejected (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) f ef c ec a ea =
  let k = lcyc_1_1__all_lookup cons ec
      et = fst (iret_7_7__consistent_through alphas [[]] (cnodes c) (cacts c) k (atuple a)) (lcyc_1_1__elem_map_fwd atuple ea)
      (u ** (eu, cl)) = iret_7_7__through_clear alphas (cnodes c) [[]] (atuple a) et
  in iret_7_9_1__clear_rejects f wm alphas mv ef (cnodes c) [] (atuple a)
       (replace {p = \z => Iret_7_9_1__clear alphas (cnodes c) z (atuple a)} (iret_12__elem_singleton eu) cl)

--@derives [IRET.7.9.2]
--@derives [IRET.19.1]
||| THE MOMENT A FACT ENTERS working memory -- asserted by one rule's RHS,
||| before the next selection -- every activation of every rule has, at
||| each NOT node admitting the fact, a prefix the fact does not join. An
||| activation of another rule whose `no` the fact satisfies is no longer on
||| the agenda.
export
iret_7_9_2__acquire : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Not (Elem f (ewm eng)) -> Iret_19__view eng ->
                      (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (iret_19_1__insert f eng))) -> (a : Iret_8_1__act) -> Elem a (cacts c) ->
                      Iret_7_9_2__rejects f (nalphas (enet (iret_19_1__insert f eng))) (cnodes c) [] (atuple a)
iret_7_9_2__acquire f eng nf v c ec a ea =
  iret_7_9_2__live_rejected (iret_19_1__insert f eng) (iret_19_1__insert_view f eng nf v) f (lcyc_1_1__elem_append_right (ewm eng) Here) c ec a ea

--@derives [IRET.7.9.2]
--@derives [LFST.9.2.1]
||| THEOREM 6, closed at the top: after any history from a loaded
||| network, every live fact is rejected by every activation's NOT nodes
||| that admit it.
export
iret_7_9_2__acquire_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                    (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                    (f : Lfac_1_7_1__fact) -> Elem f (ewm (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules))) ->
                                    (c : Rlow_4_2_1__chain) -> Elem c (nchains (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) ->
                                    (a : Iret_8_1__act) -> Elem a (cacts c) ->
                                    Iret_7_9_2__rejects f (nalphas (enet (lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)))) (cnodes c) [] (atuple a)
iret_7_9_2__acquire_after_history life fuel evs alphas rules f ef c ec a ea =
  iret_7_9_2__live_rejected _ (lfst_9_2_1__replay_net_view life fuel evs (rdsc_4a_5__load alphas rules) (rdsc_4a_5__load_view alphas rules)) f ef c ec a ea

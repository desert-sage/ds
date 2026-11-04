-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| REFRACTION IS THE `fired` FLAG. The specs state refraction five ways:
||| [IRET.11.3] keeps, per terminal, the set of token identities that
||| fired in the current agenda cycle and [IRET.11.3.1] skips them at
||| selection; [IRET.11.3.2] clears the set when a fact is asserted or
||| retracted; [IRET.11.4] 1a pops the first non-refracted activation and
||| 1e marks its identity; [IRET.8.2] resets the table when a run starts
||| on an empty agenda and clears an identity on its re-activation;
||| [IDAT.6.2.2] and the header of [IRET.11] keep a flag on the activation
||| instead, until its LHS changes; [LTIM.2.5.1] says the model "resets
||| each pump". [LDET.5.3] states the rule: an identity that fired is not
||| eligible again until its LHS changes.
|||
||| This module carries the set of [IRET.11.3] as a ghost beside the
||| engine through every operation, cleared exactly where [IRET.11.3.2]
||| clears it, and proves that in the tick-free fragment it never refuses
||| an activation the flag does not already refuse: every identity in the
||| set belongs to an activation carrying `fired`. So the selection of
||| [IRET.11.4] 1a -- the first activation neither popped nor refracted,
||| `fired` being the pop -- is the model's first unfired activation at
||| every reachable state; the five statements are observationally the
||| same here; and the `fired` flag that Rete/FireLoop.idr abstracts
||| refraction to is the whole of it. The argument is short because it is
||| structural: between two changes of working memory the terminals
||| change only by marking, and a change of working memory clears the
||| set. [LDET.5.8]'s synthesised tick, the one case where the set and the
||| flag could part, is outside this fragment.
module Rete.NetworkRefraction

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.Refcount
import Rete.TmsBridge
import Rete.RunFold
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
-- The refraction set of [IRET.11.3], as a ghost beside the engine
-- ---------------------------------------------------------------------

--@spec [IRET.11.3]
||| Every terminal's refraction set, as one list of (ordinal, identity):
||| the token identities that fired in the current cycle.
public export
Iret_11_3__refraction : Type
Iret_11_3__refraction = List (Nat, Iret_7_1__token)

--@spec [IRET.11.3]
||| The engine with the set beside it.
public export
Iret_11_3__ghost : Type
Iret_11_3__ghost = (Iret_19__engine, Iret_11_3__refraction)

--@spec [IRET.11.3]
||| The engine of a possible ghost; named so that no statement mentions
||| a projection unapplied.
public export
iret_11_3__engine_maybe : Maybe Iret_11_3__ghost -> Maybe Iret_19__engine
iret_11_3__engine_maybe m = map fst m

--@spec [IRET.11.3.1]
||| Whether an identity is in the set.
public export
iret_11_3_1__refracted : Nat -> Iret_7_1__token -> Iret_11_3__refraction -> Bool
iret_11_3_1__refracted r t rs = rarc_5_6_5__any (\p => (fst p == r) && (snd p == t)) rs

--@spec [IRET.11.3.2]
||| A fact asserted begins a new cycle: the set is cleared.
public export
iret_11_3_2__insert_g : Lfac_1_7_1__fact -> Iret_11_3__ghost -> Iret_11_3__ghost
iret_11_3_2__insert_g f (eng, rs) = (iret_19_1__insert f eng, [])

--@spec [IRET.11.3.2]
||| A fact retracted begins a new cycle: the set is cleared.
public export
iret_11_3_2__retract_g : Lfac_1_7_1__fact -> Iret_11_3__ghost -> Iret_11_3__ghost
iret_11_3_2__retract_g f (eng, rs) = (iret_19_2__retract f eng, [])

--@spec [IRET.19.1]
--@spec [IRET.11.3.2]
||| What assert does to the set: cleared on every path that changes
||| working memory, kept on a suppressed reassertion [LFAC.2.5.1].
public export
iret_19_1__assert_r : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Nat -> Nat -> Rarc_5_6_4__wm -> Iret_11_3__refraction -> Iret_11_3__refraction
iret_19_1__assert_r life k key pay wm rs = case life k of
  Explicit => []
  Relation => case iret_19_1__find_relation k key pay wm of
    Just _  => rs
    Nothing => []
  Entity => case iret_19_1__find_entity k key wm of
    Nothing  => []
    Just old => if fpay old == pay then rs else []

--@spec [IRET.19.1]
public export
iret_19_1__assert_g : (Nat -> Lscp_1_3__lifecycle) -> List Nat -> Nat -> Nat -> Nat -> Iret_11_3__ghost -> Iret_11_3__ghost
iret_19_1__assert_g life avoid k key pay (eng, rs) =
  (iret_19_1__assert life avoid k key pay eng, iret_19_1__assert_r life k key pay (ewm eng) rs)

--@spec [LSCP.2.1.1]
--@spec [IRET.11.3.2]
||| What withdraw does to the set: cleared when a live fact leaves, kept
||| when there was nothing to withdraw.
public export
lscp_2_1_1__withdraw_r : Lfac_1_7_1__fact -> Rarc_5_6_4__wm -> Iret_11_3__refraction -> Iret_11_3__refraction
lscp_2_1_1__withdraw_r f wm rs = if rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm then [] else rs

--@spec [LSCP.2.1.1]
public export
lscp_2_1_1__withdraw_g : Lfac_1_7_1__fact -> Iret_11_3__ghost -> Iret_11_3__ghost
lscp_2_1_1__withdraw_g f (eng, rs) = (lscp_2_1_1__withdraw f eng, lscp_2_1_1__withdraw_r f (ewm eng) rs)

--@spec [IRET.11.4]
--@spec [IRET.11.3.1]
||| Step 1e: the fired activation's identity enters its terminal's set,
||| beside the flag the model sets.
public export
iret_11_4__mark_g : Nat -> Nat -> Iret_7_1__token -> Iret_11_3__ghost -> Iret_11_3__ghost
iret_11_4__mark_g r j t (eng, rs) = (idat_6_2_2__mark_net r j eng, (r, t) :: rs)

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_action_g : (Nat -> Lscp_1_3__lifecycle) -> List Lfac_1_7_1__fact -> Lgra_10_1__action -> Iret_11_3__ghost -> Iret_11_3__ghost
rarc_5_6_7__do_action_g life bound (Emit k value) g =
  iret_19_1__assert_g life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) g
rarc_5_6_7__do_action_g life bound (Withdraw i) g = case rarc_5_6_5__nth i bound of
  Nothing => g
  Just f  => lscp_2_1_1__withdraw_g f g

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_g : (Nat -> Lscp_1_3__lifecycle) -> List Lfac_1_7_1__fact -> List Lgra_10_1__action -> Iret_11_3__ghost -> Iret_11_3__ghost
rarc_5_6_7__do_actions_g life bound [] g = g
rarc_5_6_7__do_actions_g life bound (a :: as) g = rarc_5_6_7__do_actions_g life bound as (rarc_5_6_7__do_action_g life bound a g)

--@spec [IRET.11.4]
||| One firing with the set beside it: 1a select, 1e mark, 1c the RHS.
public export
iret_11_4__step_g : (Nat -> Lscp_1_3__lifecycle) -> Iret_11_3__ghost -> Maybe Iret_11_3__ghost
iret_11_4__step_g life (eng, rs) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just c => case rarc_5_6_5__nth j (cacts c) of
      Nothing => Nothing
      Just a  => Just (rarc_5_6_7__do_actions_g life (atuple a) (cactions c) (iret_11_4__mark_g r j (atuple a) (eng, rs)))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
public export
iret_11_4__run_g : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Iret_11_3__ghost -> Iret_11_3__ghost
iret_11_4__run_g life Z g = g
iret_11_4__run_g life (S fuel) g = case iret_11_4__step_g life g of
  Nothing => g
  Just g' => iret_11_4__run_g life fuel g'

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__apply_g : (Nat -> Lscp_1_3__lifecycle) -> Rarc_5_6_1__event -> Iret_11_3__ghost -> Iret_11_3__ghost
rarc_5_6_4__apply_g life (Assert k key pay) g = iret_19_1__assert_g life [] k key pay g
rarc_5_6_4__apply_g life (Retract i) (eng, rs) = case rarc_5_6_4__lookup_fact i (ewm eng) of
  Nothing => (eng, rs)
  Just f  => iret_11_3_2__retract_g f (eng, rs)

--@spec [LFST.9.2.1]
public export
lfst_9_2_1__boundary_g : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Rarc_5_6_1__event -> Iret_11_3__ghost -> Iret_11_3__ghost
lfst_9_2_1__boundary_g life fuel ev g = iret_11_4__run_g life fuel (rarc_5_6_4__apply_g life ev g)

--@spec [LFST.9.2.1]
public export
lfst_9_2_1__replay_g : (Nat -> Lscp_1_3__lifecycle) -> Nat -> List Rarc_5_6_1__event -> Iret_11_3__ghost -> Iret_11_3__ghost
lfst_9_2_1__replay_g life fuel [] g = g
lfst_9_2_1__replay_g life fuel (ev :: evs) g = lfst_9_2_1__replay_g life fuel evs (lfst_9_2_1__boundary_g life fuel ev g)

--@spec [IRET.8.2]
--@spec [RDSC.4a.5]
||| The loaded network with an empty set: the table before any cycle.
public export
rdsc_4a_5__load_g : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Iret_11_3__ghost
rdsc_4a_5__load_g alphas rules = (rdsc_4a_5__load alphas rules, [])

-- ---------------------------------------------------------------------
-- The ghost shadows the engine
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) ->
                              (eng : Iret_19__engine) -> (rs : Iret_11_3__refraction) ->
                              fst (rarc_5_6_7__do_action_g life bound a (eng, rs)) = rarc_5_6_7__do_action_net life bound a eng
rarc_5_6_7__do_action_g_fst life bound (Emit k value) eng rs = Refl
rarc_5_6_7__do_action_g_fst life bound (Withdraw i) eng rs with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_g_fst life bound (Withdraw i) eng rs | Nothing = Refl
  rarc_5_6_7__do_action_g_fst life bound (Withdraw i) eng rs | (Just f) = Refl

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) ->
                               (g : Iret_11_3__ghost) ->
                               fst (rarc_5_6_7__do_actions_g life bound as g) = rarc_5_6_7__do_actions_net life bound as (fst g)
rarc_5_6_7__do_actions_g_fst life bound [] g = Refl
rarc_5_6_7__do_actions_g_fst life bound (a :: as) (eng, rs) =
  trans (rarc_5_6_7__do_actions_g_fst life bound as (rarc_5_6_7__do_action_g life bound a (eng, rs)))
        (cong (rarc_5_6_7__do_actions_net life bound as) (rarc_5_6_7__do_action_g_fst life bound a eng rs))

--@derives [IRET.11.4]
export
iret_11_4__step_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (g : Iret_11_3__ghost) ->
                        iret_11_3__engine_maybe (iret_11_4__step_g life g) = iret_11_4__step_net life (fst g)
iret_11_4__step_g_fst life (eng, rs) with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_g_fst life (eng, rs) | Nothing = Refl
  iret_11_4__step_g_fst life (eng, rs) | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__step_g_fst life (eng, rs) | (Just (r, j)) | Nothing = Refl
    iret_11_4__step_g_fst life (eng, rs) | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c))
      iret_11_4__step_g_fst life (eng, rs) | (Just (r, j)) | (Just c) | Nothing = Refl
      iret_11_4__step_g_fst life (eng, rs) | (Just (r, j)) | (Just c) | (Just a) =
        cong Just (rarc_5_6_7__do_actions_g_fst life (atuple a) (cactions c) (iret_11_4__mark_g r j (atuple a) (eng, rs)))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE NETWORK'S RUN IS THE ONE FOLD at its step (Rete/RunFold.idr's
||| `iret_11_4__run_by`), by induction on the fuel. Rete/NetworkTransfer.idr's
||| and Rete/NetworkOnce.idr's unfoldings of the run are RunFold's through it.
export
iret_11_4__run_net_by : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) ->
                        iret_11_4__run_net life fuel eng = iret_11_4__run_by (iret_11_4__step_net life) fuel eng
iret_11_4__run_net_by life Z eng = Refl
iret_11_4__run_net_by life (S fuel) eng with (iret_11_4__step_net life eng)
  iret_11_4__run_net_by life (S fuel) eng | Nothing = Refl
  iret_11_4__run_net_by life (S fuel) eng | (Just eng') with (iret_11_4__run_by (iret_11_4__step_net life) fuel eng') proof rr
    iret_11_4__run_net_by life (S fuel) eng | (Just eng') | (t, h, n) = rewrite trans (iret_11_4__run_net_by life fuel eng') rr in Refl

--@derives [IRET.11.4]
||| THE GHOST'S RUN IS THE STATE OF THE ONE FOLD at its step: it keeps no
||| halt and no count.
export
iret_11_4__run_g_by : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (g : Iret_11_3__ghost) ->
                      iret_11_4__run_g life fuel g = fst (iret_11_4__run_by (iret_11_4__step_g life) fuel g)
iret_11_4__run_g_by life Z g = Refl
iret_11_4__run_g_by life (S fuel) g with (iret_11_4__step_g life g)
  iret_11_4__run_g_by life (S fuel) g | Nothing = Refl
  iret_11_4__run_g_by life (S fuel) g | (Just g') with (iret_11_4__run_by (iret_11_4__step_g life) fuel g') proof rr
    iret_11_4__run_g_by life (S fuel) g | (Just g') | (t, h, n) =
      replace {p = \z => iret_11_4__run_g life fuel g' = fst z} rr (iret_11_4__run_g_by life fuel g')

--@derives [IRET.11.4]
||| The ghost's run shadows the engine's: Rete/RunFold.idr's simulation at the
||| engine projection, with `iret_11_4__step_g_fst` as the step's shadowing,
||| through the two bridges.
export
iret_11_4__run_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (g : Iret_11_3__ghost) ->
                       fst (iret_11_4__run_g life fuel g) = fst (iret_11_4__run_net life fuel (fst g))
iret_11_4__run_g_fst life fuel g =
  trans (cong fst (iret_11_4__run_g_by life fuel g))
        (trans (iret_11_4__run_by_sim fst (iret_11_4__step_g life) (iret_11_4__step_net life) (\x => iret_11_4__step_g_fst life x) fuel g)
               (cong fst (sym (iret_11_4__run_net_by life fuel (fst g)))))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                          fst (rarc_5_6_4__apply_g life ev g) = rarc_5_6_4__apply_net life ev (fst g)
rarc_5_6_4__apply_g_fst life (Assert k key pay) (eng, rs) = Refl
rarc_5_6_4__apply_g_fst life (Retract i) (eng, rs) with (rarc_5_6_4__lookup_fact i (ewm eng))
  rarc_5_6_4__apply_g_fst life (Retract i) (eng, rs) | Nothing = Refl
  rarc_5_6_4__apply_g_fst life (Retract i) (eng, rs) | (Just f) = Refl

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                             fst (lfst_9_2_1__boundary_g life fuel ev g) = lfst_9_2_1__boundary_net life fuel ev (fst g)
lfst_9_2_1__boundary_g_fst life fuel ev g =
  trans (iret_11_4__run_g_fst life fuel (rarc_5_6_4__apply_g life ev g))
        (cong (\e => fst (iret_11_4__run_net life fuel e)) (rarc_5_6_4__apply_g_fst life ev g))

--@derives [LFST.9.2.1]
||| THE GHOST SHADOWS THE ENGINE through every history: its engine
||| component is the engine of Rete/Network.idr.
export
lfst_9_2_1__replay_g_fst : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                         fst (lfst_9_2_1__replay_g life fuel evs g) = lfst_9_2_1__replay_net life fuel evs (fst g)
lfst_9_2_1__replay_g_fst life fuel [] g = Refl
lfst_9_2_1__replay_g_fst life fuel (ev :: evs) g =
  trans (lfst_9_2_1__replay_g_fst life fuel evs (lfst_9_2_1__boundary_g life fuel ev g))
        (cong (lfst_9_2_1__replay_net life fuel evs) (lfst_9_2_1__boundary_g_fst life fuel ev g))

-- ---------------------------------------------------------------------
-- The set refuses nothing the flag does not
-- ---------------------------------------------------------------------

--@spec [IRET.11.3]
--@spec [IDAT.6.2.2]
||| Every identity in the set belongs to an activation carrying `fired`.
public export
Iret_11_3__refracted_fired : Iret_11_3__ghost -> Type
Iret_11_3__refracted_fired g =
  (r : Nat) -> (t : Iret_7_1__token) -> Elem (r, t) (snd g) ->
  (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r (nchains (enet (fst g))) = Just c ->
  (a : Iret_8_1__act) -> Elem a (cacts c) -> atuple a = t -> afired a = True

--@spec [IRET.11.3]
--@spec [LDET.5.3]
||| THE SOUND GHOST: the view, and the set refusing nothing the flag does
||| not.
public export
Iret_11_3__sound : Iret_11_3__ghost -> Type
Iret_11_3__sound g = (Iret_19__view (fst g), Iret_11_3__refracted_fired g)

--@derives [IRET.11.3]
||| A member of a list after an update at one position is an old member
||| or the update of one.
export
iret_11_3__elem_set_at : {b : a} -> (j : Nat) -> (g : a -> a) -> (xs : List a) -> Elem b (rarc_5_6_5__set_at j g xs) ->
                         Either (Elem b xs) (x ** (Elem x xs, b = g x))
iret_11_3__elem_set_at j g [] e = absurd e
iret_11_3__elem_set_at Z g (x :: xs) e = case iret_11_3__elem_cons e of
  Left p  => Right (x ** (Here, p))
  Right e' => Left (There e')
iret_11_3__elem_set_at (S j) g (x :: xs) e = case iret_11_3__elem_cons e of
  Left p  => Left (replace {p = \z => Elem z (x :: xs)} (sym p) Here)
  Right e' => case iret_11_3__elem_set_at j g xs e' of
    Left e'' => Left (There e'')
    Right (y ** (ey, q)) => Right (y ** (There ey, q))

--@derives [IDAT.6.2.2]
||| A marked activation carries `fired`.
export
idat_6_2_2__mark_fired : (a : Iret_8_1__act) -> afired (idat_6_2_2__mark_act a) = True
idat_6_2_2__mark_fired a with (a)
  idat_6_2_2__mark_fired a | (MkAct t fr) = Refl

--@derives [IDAT.6.2.2]
--@derives [IRET.11.3.3]
||| After marking activation j, every activation with its identity
||| carries `fired`: with distinct identities, there is only the one.
export
idat_6_2_2__marked_fired : (j : Nat) -> (acts : List Iret_8_1__act) -> Iret_11_3__distinct (iret_8_1__tuples acts) ->
                           (a : Iret_8_1__act) -> rarc_5_6_5__nth j acts = Just a ->
                           (b : Iret_8_1__act) -> Elem b (idat_6_2_2__mark_acts j acts) -> atuple b = atuple a -> afired b = True
idat_6_2_2__marked_fired j [] d a nt b eb eq = void (absurd nt)
idat_6_2_2__marked_fired Z (x :: xs) (DCons nx d) a nt b eb eq = case iret_11_3__elem_cons eb of
  Left p  => replace {p = \z => afired z = True} (sym p) (idat_6_2_2__mark_fired x)
  Right e => void (nx (replace {p = \z => Elem z (iret_8_1__tuples xs)}
                          (trans eq (cong atuple (sym (iret_11_4__just_inj nt))))
                          (lcyc_1_1__elem_map_fwd atuple e)))
idat_6_2_2__marked_fired (S j) (x :: xs) (DCons nx d) a nt b eb eq = case iret_11_3__elem_cons eb of
  Left p  => void (nx (replace {p = \z => Elem z (iret_8_1__tuples xs)}
                          (sym (trans (cong atuple (sym p)) eq))
                          (lcyc_1_1__elem_map_fwd atuple (lcyc_1_1__nth_elem j xs nt))))
  Right e => idat_6_2_2__marked_fired j xs d a nt b e eq

--@derives [IRET.11.3.2]
||| A FACT ASSERTED keeps the ghost sound: the view is kept, and the
||| cleared set refuses nothing.
export
iret_11_3_2__insert_sound : (f : Lfac_1_7_1__fact) -> (g : Iret_11_3__ghost) -> Not (Elem f (ewm (fst g))) ->
                            Iret_11_3__sound g -> Iret_11_3__sound (iret_11_3_2__insert_g f g)
iret_11_3_2__insert_sound f (eng, rs) nf (v, rf) = (iret_19_1__insert_view f eng nf v, \r, t, e => absurd e)

--@derives [IRET.11.3.2]
||| A FACT RETRACTED keeps the ghost sound.
export
iret_11_3_2__retract_sound : (f : Lfac_1_7_1__fact) -> (g : Iret_11_3__ghost) -> Elem f (ewm (fst g)) ->
                             Iret_11_3__sound g -> Iret_11_3__sound (iret_11_3_2__retract_g f g)
iret_11_3_2__retract_sound f (eng, rs) ef (v, rf) = (iret_19_2__retract_view f eng ef v, \r, t, e => absurd e)

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT UNDER THE LIFECYCLE keeps the ghost sound: a suppressed
||| reassertion changes neither engine nor set; every other path changes
||| working memory and clears the set.
export
iret_19_1__assert_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (g : Iret_11_3__ghost) ->
                          Iret_11_3__sound g -> Iret_11_3__sound (iret_19_1__assert_g life avoid k key pay g)
iret_19_1__assert_sound life avoid k key pay (eng, rs) s with (life k)
  iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Explicit =
    iret_11_3_2__insert_sound _ (eng, rs) (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) s
  iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Relation | (Just old) = s
    iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Relation | Nothing =
      iret_11_3_2__insert_sound _ (eng, rs) (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) s
  iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Entity with (iret_19_1__find_entity k key (ewm eng)) proof fe
    iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Entity | Nothing =
      iret_11_3_2__insert_sound _ (eng, rs) (lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay) s
    iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Entity | (Just old) | True = s
      iret_19_1__assert_sound life avoid k key pay (eng, rs) s | Entity | (Just old) | False =
        iret_11_3_2__insert_sound _ (iret_11_3_2__retract_g old (eng, rs))
          (\e => lfac_2_5_3__fresh_not_elem avoid (ewm eng) k key pay (fst (rarc_5_6_4__remove_exact_elem_inv old (ewm eng) _ e)))
          (iret_11_3_2__retract_sound old (eng, rs) (snd (lcyc_1_1__find_just _ (ewm eng) fe)) s)

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_sound : (f : Lfac_1_7_1__fact) -> (g : Iret_11_3__ghost) -> Iret_11_3__sound g -> Iret_11_3__sound (lscp_2_1_1__withdraw_g f g)
lscp_2_1_1__withdraw_sound f (eng, rs) s with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng)) proof an
  lscp_2_1_1__withdraw_sound f (eng, rs) s | True = iret_11_3_2__retract_sound f (eng, rs) (lscp_2_1_1__any_same_elem f (ewm eng) an) s
  lscp_2_1_1__withdraw_sound f (eng, rs) s | False = s

--@derives [IRET.11.4]
--@derives [IRET.11.3.1]
--@derives [IDAT.6.2.2]
||| MARKING keeps the ghost sound: the identity that enters the set is
||| the marked activation's, which carries `fired` and, identities being
||| distinct, is the only activation with it; the identities already in
||| the set keep their activations, marked or not.
export
iret_11_4__mark_sound : (r, j : Nat) -> (g : Iret_11_3__ghost) -> Iret_11_3__sound g ->
                        (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r (nchains (enet (fst g))) = Just c ->
                        (a : Iret_8_1__act) -> rarc_5_6_5__nth j (cacts c) = Just a ->
                        Iret_11_3__sound (iret_11_4__mark_g r j (atuple a) g)
iret_11_4__mark_sound r j (MkEngine wm (MkNetwork alphas chains), rs) (v, rf) c ntc a nta =
  let (dw, dm, mv, cons) = v
      dt : Iret_11_3__distinct (iret_8_1__tuples (cacts c))
      dt = iret_7_7__consistent_distinct alphas [[]] (cnodes c) (cacts c) (lcyc_1_1__all_lookup cons (lcyc_1_1__nth_elem r chains ntc))
      atR : (c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = Just c' -> c' = idat_6_2_2__mark_chain j c
      atR = \c', ntc' => iret_11_4__just_inj
              (replace {p = \z => Just c' = map (idat_6_2_2__mark_chain j) z} ntc
                 (trans (sym ntc') (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_chain j) chains)))
  in ( idat_6_2_2__mark_net_view r j (MkEngine wm (MkNetwork alphas chains)) v
     , \r', t', e, c', ntc', b, eb, eq => case iret_11_3__elem_cons e of
         Left p =>
           let rEq : (r' = r)
               rEq = cong fst p
               tEq : (t' = atuple a)
               tEq = cong snd p
               ntcR : (rarc_5_6_5__nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = Just c')
               ntcR = replace {p = \z => rarc_5_6_5__nth z (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = Just c'} rEq ntc'
               ebM : Elem b (idat_6_2_2__mark_acts j (cacts c))
               ebM = replace {p = \z => Elem b (cacts z)} (atR c' ntcR) eb
           in idat_6_2_2__marked_fired j (cacts c) dt a nta b ebM (trans eq tEq)
         Right e' => case decEq r' r of
           Yes rEq =>
             let ntcR : (rarc_5_6_5__nth r (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = Just c')
                 ntcR = replace {p = \z => rarc_5_6_5__nth z (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) chains) = Just c'} rEq ntc'
                 ebM : Elem b (idat_6_2_2__mark_acts j (cacts c))
                 ebM = replace {p = \z => Elem b (cacts z)} (atR c' ntcR) eb
                 eR : Elem (r, t') rs
                 eR = replace {p = \z => Elem (z, t') rs} rEq e'
             in case iret_11_3__elem_set_at j idat_6_2_2__mark_act (cacts c) ebM of
                  Left eOld => rf r t' eR c ntc b eOld eq
                  Right (x ** (ex, bx)) => replace {p = \z => afired z = True} (sym bx) (idat_6_2_2__mark_fired x)
           No ne =>
             rf r' t' e' c' (trans (sym (lcyc_1_1__nth_set_at_neq r r' (\q => ne (sym q)) (idat_6_2_2__mark_chain j) chains)) ntc') b eb eq )

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) -> (g : Iret_11_3__ghost) ->
                              Iret_11_3__sound g -> Iret_11_3__sound (rarc_5_6_7__do_action_g life bound a g)
rarc_5_6_7__do_action_sound life bound (Emit k value) g s =
  iret_19_1__assert_sound life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) g s
rarc_5_6_7__do_action_sound life bound (Withdraw i) g s with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_sound life bound (Withdraw i) g s | Nothing = s
  rarc_5_6_7__do_action_sound life bound (Withdraw i) g s | (Just f) = lscp_2_1_1__withdraw_sound f g s

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_actions_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) -> (g : Iret_11_3__ghost) ->
                               Iret_11_3__sound g -> Iret_11_3__sound (rarc_5_6_7__do_actions_g life bound as g)
rarc_5_6_7__do_actions_sound life bound [] g s = s
rarc_5_6_7__do_actions_sound life bound (a :: as) g s =
  rarc_5_6_7__do_actions_sound life bound as (rarc_5_6_7__do_action_g life bound a g) (rarc_5_6_7__do_action_sound life bound a g s)

--@derives [IRET.11.4]
export
iret_11_4__step_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (g : Iret_11_3__ghost) -> Iret_11_3__sound g ->
                        (g' : Iret_11_3__ghost) -> iret_11_4__step_g life g = Just g' -> Iret_11_3__sound g'
iret_11_4__step_sound life (eng, rs) s g' eq with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__step_sound life (eng, rs) s g' eq | Nothing = void (absurd eq)
  iret_11_4__step_sound life (eng, rs) s g' eq | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng))) proof ntc
    iret_11_4__step_sound life (eng, rs) s g' eq | (Just (r, j)) | Nothing = void (absurd eq)
    iret_11_4__step_sound life (eng, rs) s g' eq | (Just (r, j)) | (Just c) with (rarc_5_6_5__nth j (cacts c)) proof nta
      iret_11_4__step_sound life (eng, rs) s g' eq | (Just (r, j)) | (Just c) | Nothing = void (absurd eq)
      iret_11_4__step_sound life (eng, rs) s g' eq | (Just (r, j)) | (Just c) | (Just a) =
        replace {p = Iret_11_3__sound} (iret_11_4__just_inj eq)
          (rarc_5_6_7__do_actions_sound life (atuple a) (cactions c) (iret_11_4__mark_g r j (atuple a) (eng, rs))
             (iret_11_4__mark_sound r j (eng, rs) s c ntc a nta))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
export
iret_11_4__run_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (g : Iret_11_3__ghost) -> Iret_11_3__sound g ->
                       Iret_11_3__sound (iret_11_4__run_g life fuel g)
iret_11_4__run_sound life Z g s = s
iret_11_4__run_sound life (S fuel) g s with (iret_11_4__step_g life g) proof st
  iret_11_4__run_sound life (S fuel) g s | Nothing = s
  iret_11_4__run_sound life (S fuel) g s | (Just g') = iret_11_4__run_sound life fuel g' (iret_11_4__step_sound life g s g' st)

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (ev : Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                          Iret_11_3__sound g -> Iret_11_3__sound (rarc_5_6_4__apply_g life ev g)
rarc_5_6_4__apply_sound life (Assert k key pay) g s = iret_19_1__assert_sound life [] k key pay g s
rarc_5_6_4__apply_sound life (Retract i) (eng, rs) s with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  rarc_5_6_4__apply_sound life (Retract i) (eng, rs) s | Nothing = s
  rarc_5_6_4__apply_sound life (Retract i) (eng, rs) s | (Just f) =
    iret_11_3_2__retract_sound f (eng, rs) (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) s

--@derives [LFST.9.2.1]
export
lfst_9_2_1__boundary_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                             Iret_11_3__sound g -> Iret_11_3__sound (lfst_9_2_1__boundary_g life fuel ev g)
lfst_9_2_1__boundary_sound life fuel ev g s = iret_11_4__run_sound life fuel _ (rarc_5_6_4__apply_sound life ev g s)

--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps the ghost sound.
export
lfst_9_2_1__replay_sound : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (g : Iret_11_3__ghost) ->
                         Iret_11_3__sound g -> Iret_11_3__sound (lfst_9_2_1__replay_g life fuel evs g)
lfst_9_2_1__replay_sound life fuel [] g s = s
lfst_9_2_1__replay_sound life fuel (ev :: evs) g s = lfst_9_2_1__replay_sound life fuel evs _ (lfst_9_2_1__boundary_sound life fuel ev g s)

--@derives [IRET.8.2]
--@derives [RDSC.4a.5]
||| THE LOADED NETWORK with the empty set is sound.
export
rdsc_4a_5__load_sound : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                        Iret_11_3__sound (rdsc_4a_5__load_g alphas rules)
rdsc_4a_5__load_sound alphas rules = (rdsc_4a_5__load_view alphas rules, \r, t, e => absurd e)

-- ---------------------------------------------------------------------
-- The selection of [IRET.11.4] 1a is the model's
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
--@spec [IRET.11.3.1]
||| Step 1a as the clause states it, over the model's terminal: the
||| first activation of a rule that is neither popped -- `fired` is the
||| pop -- nor refracted by the set.
public export
iret_11_4__first_eligible : Nat -> Iret_11_3__refraction -> List Iret_8_1__act -> Maybe Nat
iret_11_4__first_eligible r rs [] = Nothing
iret_11_4__first_eligible r rs (a :: as) =
  if afired a || iret_11_3_1__refracted r (atuple a) rs then map S (iret_11_4__first_eligible r rs as) else Just 0

--@spec [IRET.11.4]
--@spec [IRET.11.1]
||| The lowest ordinal with an eligible activation, from ordinal r on.
public export
iret_11_4__select_from : Nat -> Iret_11_3__refraction -> List Rlow_4_2_1__chain -> Maybe (Nat, Nat)
iret_11_4__select_from r rs [] = Nothing
iret_11_4__select_from r rs (c :: cs) = case iret_11_4__first_eligible r rs (cacts c) of
  Just j  => Just (0, j)
  Nothing => map (\(r', j) => (S r', j)) (iret_11_4__select_from (S r) rs cs)

--@spec [IRET.11.4]
--@spec [IRET.11.1]
||| Step 1a: the first non-refracted, unpopped activation in agenda order.
public export
iret_11_4__select_spec : Iret_11_3__refraction -> List Rlow_4_2_1__chain -> Maybe (Nat, Nat)
iret_11_4__select_spec rs chains = iret_11_4__select_from 0 rs chains

--@derives [IRET.11.3.1]
export
iret_11_3_1__hit : (r : Nat) -> (t : Iret_7_1__token) -> (p : (Nat, Iret_7_1__token)) -> ((fst p == r) && (snd p == t)) = True -> p = (r, t)
iret_11_3_1__hit r t (r', t') q =
  cong2 MkPair (lcyc_1_1__nat_eq_true r' r (lcyc_1_1__and_true_l (r' == r) (t' == t) q))
               (iret_11_3__tok_eq t' t (lcyc_1_1__and_true_r (r' == r) (t' == t) q))

--@derives [IRET.11.3.1]
||| An identity not in the set is not refracted.
export
iret_11_3_1__refracted_false : (r : Nat) -> (t : Iret_7_1__token) -> (rs : Iret_11_3__refraction) -> Not (Elem (r, t) rs) ->
                               iret_11_3_1__refracted r t rs = False
iret_11_3_1__refracted_false r t rs ne with (iret_11_3_1__refracted r t rs) proof p
  iret_11_3_1__refracted_false r t rs ne | False = Refl
  iret_11_3_1__refracted_false r t rs ne | True =
    let (x ** (ex, q)) = iret_12_2__any_true (\p => (fst p == r) && (snd p == t)) rs p
    in void (ne (replace {p = \z => Elem z rs} (iret_11_3_1__hit r t x q) ex))

--@derives [IRET.11.4]
--@derives [IRET.11.3.1]
||| Over a terminal where every refracted identity is fired, step 1a's
||| choice is the first unfired activation.
export
iret_11_4__first_eligible_unfired : (r : Nat) -> (rs : Iret_11_3__refraction) -> (acts : List Iret_8_1__act) ->
                                    ((a : Iret_8_1__act) -> Elem a acts -> Elem (r, atuple a) rs -> afired a = True) ->
                                    iret_11_4__first_eligible r rs acts = iret_11_3_1__first_unfired acts
iret_11_4__first_eligible_unfired r rs [] h = Refl
iret_11_4__first_eligible_unfired r rs (a :: as) h with (afired a) proof fa
  iret_11_4__first_eligible_unfired r rs (a :: as) h | True =
    cong (map S) (iret_11_4__first_eligible_unfired r rs as (\b, eb, e => h b (There eb) e))
  iret_11_4__first_eligible_unfired r rs (a :: as) h | False with (iret_11_3_1__refracted r (atuple a) rs) proof rf
    iret_11_4__first_eligible_unfired r rs (a :: as) h | False | False = Refl
    iret_11_4__first_eligible_unfired r rs (a :: as) h | False | True =
      absurd (trans (sym (iret_11_3_1__refracted_false r (atuple a) rs (\e => absurd (trans (sym fa) (h a Here e))))) rf)

--@derives [IRET.11.4]
||| Two maps over a selection agree when the functions agree on pairs.
export
iret_11_4__map_ext : (f, g : (Nat, Nat) -> (Nat, Nat)) -> (m : Maybe (Nat, Nat)) -> ((x, y : Nat) -> f (x, y) = g (x, y)) -> map f m = map g m
iret_11_4__map_ext f g Nothing h = Refl
iret_11_4__map_ext f g (Just (x, y)) h = cong Just (h x y)

--@derives [IRET.11.4]
||| The head chain's two selections agree, given the hypothesis at
||| ordinal r.
export
iret_11_4__select_head : (r : Nat) -> (rs : Iret_11_3__refraction) -> (c : Rlow_4_2_1__chain) -> {cs : List Rlow_4_2_1__chain} ->
                         ((i : Nat) -> (c' : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (c :: cs) = Just c' ->
                          (a : Iret_8_1__act) -> Elem a (cacts c') -> Elem (r + i, atuple a) rs -> afired a = True) ->
                         {fej, fuj : Maybe Nat} -> iret_11_4__first_eligible r rs (cacts c) = fej -> iret_11_3_1__first_unfired (cacts c) = fuj -> fej = fuj
iret_11_4__select_head r rs c h fe fu =
  trans (sym fe) (trans (iret_11_4__first_eligible_unfired r rs (cacts c)
                          (\a, ea, e => h 0 c Refl a ea (replace {p = \z => Elem (z, atuple a) rs} (sym (plusZeroRightNeutral r)) e)))
                  fu)

--@derives [IRET.11.4]
--@derives [IRET.11.1]
export
iret_11_4__select_from_unfired : (r : Nat) -> (rs : Iret_11_3__refraction) -> (chains : List Rlow_4_2_1__chain) ->
                                 ((i : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i chains = Just c ->
                                  (a : Iret_8_1__act) -> Elem a (cacts c) -> Elem (r + i, atuple a) rs -> afired a = True) ->
                                 iret_11_4__select_from r rs chains = iret_11_1__select chains
iret_11_4__select_from_unfired r rs [] h = Refl
iret_11_4__select_from_unfired r rs (c :: cs) h with (iret_11_4__first_eligible r rs (cacts c)) proof fe
  iret_11_4__select_from_unfired r rs (c :: cs) h | (Just j) with (iret_11_3_1__first_unfired (cacts c)) proof fu
    iret_11_4__select_from_unfired r rs (c :: cs) h | (Just j) | (Just j') =
      cong (\z => Just (0, z)) (iret_11_4__just_inj (iret_11_4__select_head r rs c h fe fu))
    iret_11_4__select_from_unfired r rs (c :: cs) h | (Just j) | Nothing =
      void (absurd (sym (iret_11_4__select_head r rs c h fe fu)))
  iret_11_4__select_from_unfired r rs (c :: cs) h | Nothing with (iret_11_3_1__first_unfired (cacts c)) proof fu
    iret_11_4__select_from_unfired r rs (c :: cs) h | Nothing | (Just j') =
      void (absurd (iret_11_4__select_head r rs c h fe fu))
    iret_11_4__select_from_unfired r rs (c :: cs) h | Nothing | Nothing =
      let tails : (iret_11_4__select_from (S r) rs cs = iret_11_1__select cs)
          tails = iret_11_4__select_from_unfired (S r) rs cs
                    (\i, c', ntc, a, ea, e => h (S i) c' ntc a ea (replace {p = \z => Elem (z, atuple a) rs} (plusSuccRightSucc r i) e))
      in rewrite tails in iret_11_4__map_ext _ _ (iret_11_1__select cs) (\x, y => Refl)

--@derives [IRET.11.3]
--@derives [IRET.11.4]
--@derives [IRET.11.3.1]
--@derives [LDET.5.3]
||| UNDER A SOUND GHOST, STEP 1a IS THE MODEL'S SELECTION: the first
||| activation neither popped nor refracted is the first unfired one.
||| Refraction refuses nothing the flag does not.
export
iret_11_3__select_spec_agrees : (g : Iret_11_3__ghost) -> Iret_11_3__refracted_fired g ->
                                iret_11_4__select_spec (snd g) (nchains (enet (fst g))) = iret_11_1__select (nchains (enet (fst g)))
iret_11_3__select_spec_agrees (eng, rs) rf =
  iret_11_4__select_from_unfired 0 rs (nchains (enet eng)) (\i, c, ntc, a, ea, e => rf i (atuple a) e c ntc a ea Refl)

--@derives [IRET.11.3]
--@derives [IRET.11.3.2]
--@derives [IDAT.6.2.2]
--@derives [LDET.5.3]
--@derives [IRET.8.2]
--@derives [LTIM.2.5.1]
||| THE REFRACTION THEOREM. After any history from a loaded network, with
||| the set of [IRET.11.3] kept beside the engine and cleared as
||| [IRET.11.3.2] clears it: the engine beside the set is the engine of
||| the history; every refracted identity belongs to an activation
||| carrying `fired`; and the selection of [IRET.11.4] 1a is the model's.
||| The `fired` flag is the whole of refraction in the tick-free fragment,
||| under each of the five statements of it.
export
iret_11_3__refraction_after_history : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                                      (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                      ( fst (lfst_9_2_1__replay_g life fuel evs (rdsc_4a_5__load_g alphas rules)) = lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules)
                                      , Iret_11_3__refracted_fired (lfst_9_2_1__replay_g life fuel evs (rdsc_4a_5__load_g alphas rules))
                                      , iret_11_4__select_spec (snd (lfst_9_2_1__replay_g life fuel evs (rdsc_4a_5__load_g alphas rules)))
                                                               (nchains (enet (fst (lfst_9_2_1__replay_g life fuel evs (rdsc_4a_5__load_g alphas rules)))))
                                        = iret_11_1__select (nchains (enet (fst (lfst_9_2_1__replay_g life fuel evs (rdsc_4a_5__load_g alphas rules))))) )
iret_11_3__refraction_after_history life fuel evs alphas rules =
  let s = lfst_9_2_1__replay_sound life fuel evs (rdsc_4a_5__load_g alphas rules) (rdsc_4a_5__load_sound alphas rules)
  in ( lfst_9_2_1__replay_g_fst life fuel evs (rdsc_4a_5__load_g alphas rules)
     , snd s
     , iret_11_3__select_spec_agrees _ (snd s) )

--@derives [IRET.8.2]
--@derives [IRET.8.1]
||| An activation of the list after an insert is the inserted one or an
||| old one.
export
iret_8_2__insert_act_inv : (wm : Rarc_5_6_4__wm) -> (a : Iret_8_1__act) -> (acts : List Iret_8_1__act) -> (b : Iret_8_1__act) ->
                           Elem b (ldet_5_5__insert wm a acts) -> Either (b = a) (Elem b acts)
iret_8_2__insert_act_inv wm a [] b e = case iret_11_3__elem_cons e of
  Left p   => Left p
  Right e' => absurd e'
iret_8_2__insert_act_inv wm a (c :: cs) b e with (ldet_5_5__before wm (atuple a) (atuple c))
  iret_8_2__insert_act_inv wm a (c :: cs) b e | True = iret_11_3__elem_cons e
  iret_8_2__insert_act_inv wm a (c :: cs) b e | False = case iret_11_3__elem_cons e of
    Left p   => Right (replace {p = \z => Elem z (c :: cs)} (sym p) Here)
    Right e' => case iret_8_2__insert_act_inv wm a cs b e' of
      Left q   => Left q
      Right eo => Right (There eo)

--@derives [IRET.8.2]
--@derives [IRET.8.1]
||| ON RE-ACTIVATION THE IDENTITY IS NOT REFRACTED: every activation a
||| terminal gains is unfired -- [IRET.8.2]'s "refraction state for that
||| identity is cleared" is how the model activates.
export
iret_8_2__activated_unfired : (wm : Rarc_5_6_4__wm) -> (ts : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                              (a : Iret_8_1__act) -> Elem a (iret_8_1__activate wm ts acts) -> Either (Elem a acts) (afired a = False)
iret_8_2__activated_unfired wm [] acts a e = Left e
iret_8_2__activated_unfired wm (t :: ts) acts a e = case iret_8_2__activated_unfired wm ts (ldet_5_5__insert wm (MkAct t False) acts) a e of
  Right nf => Right nf
  Left e' => case iret_8_2__insert_act_inv wm (MkAct t False) acts a e' of
    Left p   => Right (cong afired p)
    Right eo => Left eo

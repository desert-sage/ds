-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Clock ticks and TTL expiry on the network: Rete/TtlSweep.idr's clock,
||| deadline table and sweep carried to the spec's network.
|||
||| NORMATIVE COMPANION, on the same mechanisms as Rete/NetworkTmsTransfer.idr.
|||
||| WHAT IS MODELLED. The network engine with truth maintenance
||| (Rete/NetworkTms.idr), the deadline table and the clock beside it, as
||| Rete/TtlSweep.idr keeps them beside FireLoop. Every mint stamps its
||| deadline exactly as there. The sweep retracts the expired facts ONE AT
||| A TIME through alpha dispatch ([IRET.19.3] step 2, `ds_rete_wm_retract`
||| per fact), in the order [LDTL.6.1] fixes for the default mode: by
||| deadline, earliest first, and facts that share a deadline by when each
||| entered working memory (`ldtl_6_1__order`); then the cascade. Advance, a
||| data event, a pump, a boundary and a canonical replay with ticks are
||| Rete/TtlSweep.idr's, on the network.
|||
||| WHAT IS PROVED.
|||
|||   * The order is a permutation of the expired ids
|||     (`ldtl_6_1__order_fwd`, `ldtl_6_1__order_back`), so retracting in it
|||     removes exactly the facts FireLoop's batch removes
|||     (`ldtl_6_1__retract_order`): BOTH SIDES EXPIRE THE SAME FACTS, and
|||     the network does it in [LDTL.6.1]'s order. On FireLoop the batch has
|||     no order; on the network the order is visible only in the sequence
|||     of retractions -- the `FACT_RETRACT` events [NFCT.5.4] -- since any
|||     order ends in the same state.
|||   * THE TRANSFER WITH TICKS (`rlow_4_2_1__canonical_ttl_agree`,
|||     `rlow_4_2_1__transfer_ttl`): a canonical replay with ticks on
|||     FireLoop is one on the network, input by input with the same fuel,
|||     and the two agree at every boundary -- one working memory, one
|||     dependency table, one deadline table, one clock, each table's
|||     unblocked tokens the terminal's activations with their flags. So
|||     Rete/TtlSweep.idr's theorems are theorems of the network: at the end
|||     of every canonical replay with ticks from the loaded network, the
|||     deadline table is well-formed on the network's working memory and
|||     every live fact's deadline is after the clock
|||     (`iret_22_6__network_deadlines`, [IRET.22.6]).
|||   * A TICK THAT EXPIRES NOTHING MOVES ONLY THE CLOCK, on both sides
|||     (`ldet_5_8__quiet_tick_net`): no fact, token, `fired` flag or row
|||     changes, so no activation re-fires on it -- [LDET.5.8]'s "cycling
|||     the tick is not a change to the LHS", for the tick-free tests the
|||     model has.
|||
||| NOT HERE. `__ClockTick__` [IRET.19.5] as a fact: [LDET.5.8]
||| forbids a synthesised tick from being a working-memory fact, so the
||| model has none, and a tick is the clock advance and the sweep alone.
||| Time-dependent tests (`now()`, `within`): the tests of THIS engine are
||| predicates of facts, which is why `ldet_5_8__quiet_tick_net` is
||| `partial`. Rete/NetworkTick.idr carries a test that reads the clock
||| and restates theorem 4 (refraction) under ticks, on the flag reading.
||| `+dynamic_ttl`'s heap
||| order [LDTL.6.2], as Rete/TtlSweep.idr.
module Rete.NetworkTtl

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
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Rete.RunFold
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Lcyc.TmsTermination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat

%default total

-- ---------------------------------------------------------------------
-- [LDTL.6.1]'s expiry order
-- ---------------------------------------------------------------------

--@spec [LDTL.6.1]
||| An id's deadline, from its row of the deadline table. The sweep orders
||| only ids the table holds, so the zero of an id with no row is not read.
public export
ldtl_6_1__deadline_of : Iret_4_3__deadlines -> Nat -> Nat
ldtl_6_1__deadline_of [] i = 0
ldtl_6_1__deadline_of ((j, t) :: dl) i = if j == i then t else ldtl_6_1__deadline_of dl i

--@spec [LDTL.6.1]
||| Place an id before the first whose deadline is the same or later, or
||| after this one.
public export
ldtl_6_1__place : Nat -> Nat -> List Nat -> List Nat -> Bool -> List Nat
ldtl_6_1__place i j js ins True = i :: j :: js
ldtl_6_1__place i j js ins False = j :: ins

--@spec [LDTL.6.1]
||| Insert an id ahead of every id whose deadline is the same or later: the
||| result stays in deadline order, and an id ahead of another with the same
||| deadline stays ahead of it.
public export
ldtl_6_1__insert : Iret_4_3__deadlines -> Nat -> List Nat -> List Nat
ldtl_6_1__insert dl i [] = [i]
ldtl_6_1__insert dl i (j :: js) = ldtl_6_1__place i j js (ldtl_6_1__insert dl i js) (lte (ldtl_6_1__deadline_of dl i) (ldtl_6_1__deadline_of dl j))

--@spec [LDTL.6.1]
||| THE EXPIRY ORDER of the default mode: by deadline, earliest first, and
||| facts that share a deadline by when each entered working memory. A stable
||| sort by deadline of the expired ids: `iret_19_3__expired` yields them in
||| the deadline table's order, and rows are appended as facts are minted, so
||| that order is entry order. Which schema a fact belongs to is not read.
public export
ldtl_6_1__order : Iret_4_3__deadlines -> List Nat -> List Nat
ldtl_6_1__order dl [] = []
ldtl_6_1__order dl (i :: is) = ldtl_6_1__insert dl i (ldtl_6_1__order dl is)

--@derives [LDTL.6.1]
export
ldtl_6_1__place_fwd : (i, j, x : Nat) -> (js, ins : List Nat) -> (Elem x ins -> Either (x = i) (Elem x js)) -> (b : Bool) ->
                      Elem x (ldtl_6_1__place i j js ins b) -> Either (x = i) (Elem x (j :: js))
ldtl_6_1__place_fwd i j i js ins ih True Here = Left Refl
ldtl_6_1__place_fwd i j x js ins ih True (There e) = Right e
ldtl_6_1__place_fwd i j j js ins ih False Here = Right Here
ldtl_6_1__place_fwd i j x js ins ih False (There e) = case ih e of
  Left eq => Left eq
  Right e' => Right (There e')

--@derives [LDTL.6.1]
export
ldtl_6_1__place_back : (i, j, x : Nat) -> (js, ins : List Nat) -> (Either (x = i) (Elem x js) -> Elem x ins) -> (b : Bool) ->
                       Either (x = i) (Elem x (j :: js)) -> Elem x (ldtl_6_1__place i j js ins b)
ldtl_6_1__place_back i j i js ins ih True (Left Refl) = Here
ldtl_6_1__place_back i j j js ins ih True (Right Here) = There Here
ldtl_6_1__place_back i j x js ins ih True (Right (There e)) = There (There e)
ldtl_6_1__place_back i j x js ins ih False (Left eq) = There (ih (Left eq))
ldtl_6_1__place_back i j j js ins ih False (Right Here) = Here
ldtl_6_1__place_back i j x js ins ih False (Right (There e)) = There (ih (Right e))

--@derives [LDTL.6.1]
export
ldtl_6_1__insert_fwd : (dl : Iret_4_3__deadlines) -> (i : Nat) -> (js : List Nat) -> (x : Nat) -> Elem x (ldtl_6_1__insert dl i js) -> Either (x = i) (Elem x js)
ldtl_6_1__insert_fwd dl i [] i Here = Left Refl
ldtl_6_1__insert_fwd dl i [] x (There e) = absurd e
ldtl_6_1__insert_fwd dl i (j :: js) x e =
  ldtl_6_1__place_fwd i j x js (ldtl_6_1__insert dl i js) (ldtl_6_1__insert_fwd dl i js x) (lte (ldtl_6_1__deadline_of dl i) (ldtl_6_1__deadline_of dl j)) e

--@derives [LDTL.6.1]
export
ldtl_6_1__insert_back : (dl : Iret_4_3__deadlines) -> (i : Nat) -> (js : List Nat) -> (x : Nat) -> Either (x = i) (Elem x js) -> Elem x (ldtl_6_1__insert dl i js)
ldtl_6_1__insert_back dl i [] i (Left Refl) = Here
ldtl_6_1__insert_back dl i [] x (Right e) = absurd e
ldtl_6_1__insert_back dl i (j :: js) x e =
  ldtl_6_1__place_back i j x js (ldtl_6_1__insert dl i js) (ldtl_6_1__insert_back dl i js x) (lte (ldtl_6_1__deadline_of dl i) (ldtl_6_1__deadline_of dl j)) e

--@derives [LDTL.6.1]
||| Every id the order yields was expired...
export
ldtl_6_1__order_fwd : (dl : Iret_4_3__deadlines) -> (ids : List Nat) -> (x : Nat) -> Elem x (ldtl_6_1__order dl ids) -> Elem x ids
ldtl_6_1__order_fwd dl [] x e = e
ldtl_6_1__order_fwd dl (i :: is) x e = case ldtl_6_1__insert_fwd dl i (ldtl_6_1__order dl is) x e of
  Left eq => rewrite eq in Here
  Right e' => There (ldtl_6_1__order_fwd dl is x e')

--@derives [LDTL.6.1]
||| ...and every expired id is in the order.
export
ldtl_6_1__order_back : (dl : Iret_4_3__deadlines) -> (ids : List Nat) -> (x : Nat) -> Elem x ids -> Elem x (ldtl_6_1__order dl ids)
ldtl_6_1__order_back dl (x :: is) x Here = ldtl_6_1__insert_back dl x (ldtl_6_1__order dl is) x (Left Refl)
ldtl_6_1__order_back dl (i :: is) x (There e) = ldtl_6_1__insert_back dl i (ldtl_6_1__order dl is) x (Right (ldtl_6_1__order_back dl is x e))

--@derives [LDTL.6.1]
||| Two schemas whose deadlines interleave: kind 0's TTL is 5, kind 1's is 7.
public export
ldtl_6_1__two_ttls : Iret_4_2__ttl
ldtl_6_1__two_ttls Z = 5
ldtl_6_1__two_ttls (S _) = 7

--@derives [LDTL.6.1]
||| Four mints in entry order: id 1 of kind 1 at clock 0 (deadline 7), id 2 of
||| kind 0 at clock 0 (deadline 5), id 3 of kind 0 at clock 2 (deadline 7), id
||| 4 of kind 1 at clock 2 (deadline 9).
public export
ldtl_6_1__interleaved : Iret_4_3__deadlines
ldtl_6_1__interleaved =
  iret_4_3__stamp ldtl_6_1__two_ttls 2 4 1
    (iret_4_3__stamp ldtl_6_1__two_ttls 2 3 0
      (iret_4_3__stamp ldtl_6_1__two_ttls 0 2 0
        (iret_4_3__stamp ldtl_6_1__two_ttls 0 1 1 [])))

--@derives [LDTL.6.1]
||| THE ORDER IS THE CLAUSE'S where the others differ: by deadline, id 2 first;
||| ids 1 and 3 share a deadline and leave in entry order. Entry order alone is
||| 1, 2, 3, 4, and an order by schema is 2, 3, 1, 4.
export
ldtl_6_1__interleaved_order : ldtl_6_1__order Rete.NetworkTtl.ldtl_6_1__interleaved (iret_19_3__expired 9 Rete.NetworkTtl.ldtl_6_1__interleaved) = [2, 1, 3, 4]
ldtl_6_1__interleaved_order = Refl

--@derives [IRET.12.2]
||| Two id lists with the same members are the same membership test.
export
iret_12_2__elem_same : (x : Nat) -> (l1, l2 : List Nat) -> (Elem x l1 -> Elem x l2) -> (Elem x l2 -> Elem x l1) ->
                       rarc_5_6_5__elem x l1 = rarc_5_6_5__elem x l2
iret_12_2__elem_same x l1 l2 f g =
  case iret_12__bool_split (rarc_5_6_5__elem x l1) of
    Left t1 => trans t1 (sym (lcyc_1_1__elem_l_true x l2 (f (lcyc_1_1__elem_l_elem x l1 t1))))
    Right f1 => case iret_12__bool_split (rarc_5_6_5__elem x l2) of
      Left t2 => void (lcyc_1_1__bool_not_both _ (lcyc_1_1__elem_l_true x l1 (g (lcyc_1_1__elem_l_elem x l2 t2))) f1)
      Right f2 => trans f1 (sym f2)

--@derives [LDTL.6.1]
--@derives [IRET.19.3]
||| BOTH SIDES EXPIRE THE SAME FACTS: retracting the expired ids in
||| [LDTL.6.1]'s order removes exactly what the batch removes.
export
ldtl_6_1__retract_order : (dl : Iret_4_3__deadlines) -> (ids : List Nat) -> (wm : Rarc_5_6_4__wm) ->
                          iret_12_2__retract_ids (ldtl_6_1__order dl ids) wm = iret_12_2__retract_ids ids wm
ldtl_6_1__retract_order dl ids wm =
  lcyc_1_1__filter_ext (\g => not (rarc_5_6_5__elem (fid g) (ldtl_6_1__order dl ids))) (\g => not (rarc_5_6_5__elem (fid g) ids))
    (\g => cong not (iret_12_2__elem_same (fid g) (ldtl_6_1__order dl ids) ids (ldtl_6_1__order_fwd dl ids (fid g)) (ldtl_6_1__order_back dl ids (fid g))))
    wm

-- ---------------------------------------------------------------------
-- The clocked network engine
-- ---------------------------------------------------------------------

--@spec [IRET.19.3]
||| The network engine with truth maintenance, its deadline table, and its
||| clock RARC.5.5.
public export
record Iret_19_3__clocked_net where
  constructor MkClockedNet
  nengine    : Iret_12__net_state
  ndeadlines : Iret_4_3__deadlines
  nclock     : Nat

--@spec [IRET.4.3]
||| What one RHS action mints, on the network: the activation's fact ids
||| are what FireLoop's token's are.
public export
iret_4_3__record_action_net : Iret_4_2__ttl -> Nat -> Iret_8_1__act -> Lgra_10_1__action -> Rarc_5_6_4__wm -> Iret_4_3__deadlines -> Iret_4_3__deadlines
iret_4_3__record_action_net ttl now a (Withdraw _) wm dl = dl
iret_4_3__record_action_net ttl now a (Emit k _) wm dl = iret_4_3__stamp ttl now (lfac_2_5_3__fresh_id (iret_11_3__fact_ids (atuple a)) wm) k dl

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_action_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> Lgra_10_1__action -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_7__do_action_ttl_net pg ttl r a act (MkClockedNet (MkTmsNet eng rows) dl c) =
  MkClockedNet (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows)) (iret_4_3__record_action_net ttl c a act (ewm eng) dl) c

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> List Lgra_10_1__action -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_7__do_actions_ttl_net pg ttl r a [] cs = cs
rarc_5_6_7__do_actions_ttl_net pg ttl r a (act :: acts) cs = case rarc_5_6_7__do_action_ttl_net pg ttl r a act cs of
  MkClockedNet s dl c => rarc_5_6_7__do_actions_ttl_net pg ttl r a acts (MkClockedNet s dl c)

--@spec [IRET.11.4]
public export
iret_11_4__step_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked_net -> Maybe Iret_19_3__clocked_net
iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just ch => case rarc_5_6_5__nth j (cacts ch) of
      Nothing => Nothing
      Just a  => Just (rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
public export
iret_11_4__run_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_19_3__clocked_net -> (Iret_19_3__clocked_net, Iret_11_4__halt, Nat)
iret_11_4__run_ttl_net pg ttl Z cs = (cs, FuelOut, 0)
iret_11_4__run_ttl_net pg ttl (S fuel) cs = case iret_11_4__step_ttl_net pg ttl cs of
  Nothing => (cs, Quiescent, 0)
  Just cs' => let (t, h, n) = iret_11_4__run_ttl_net pg ttl fuel cs' in (t, h, S n)

--@spec [IRET.19.3]
--@spec [RARC.5.6.3]
--@spec [LDTL.6.1]
||| THE SWEEP ON THE NETWORK: every live fact whose deadline is at or
||| before the clock retracted one at a time through alpha dispatch, in
||| [LDTL.6.1]'s order, then the cascade.
public export
rarc_5_6_3__sweep_net : Lcyc_3_2_1__program -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__sweep_net pg (MkClockedNet (MkTmsNet eng rows) dl c) =
  MkClockedNet (iret_12_2__phase_net pg (MkTmsNet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng) rows)) dl c

--@spec [RARC.5.6.3]
||| Advance the clock to the tick's sample, by Rete/TtlSweep.idr's
||| `rarc_5_6_3__next_clock`.
public export
rarc_5_6_3__advance_net : Nat -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__advance_net t (MkClockedNet s dl c) = MkClockedNet s dl (rarc_5_6_3__next_clock c t)

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__apply_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_1__event -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_4__apply_ttl_net pg ttl (Assert k key pay) (MkClockedNet (MkTmsNet eng rows) dl c) =
  MkClockedNet (rarc_5_6_4__apply_tms_net pg (Assert k key pay) (MkTmsNet eng rows)) (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] (ewm eng)) k dl) c
rarc_5_6_4__apply_ttl_net pg ttl (Retract i) (MkClockedNet s dl c) = MkClockedNet (rarc_5_6_4__apply_tms_net pg (Retract i) s) dl c

--@spec [RARC.5.6.3]
||| The loop's steps before firing on the network, in Rete/TtlSweep.idr's
||| order: a tick advances and sweeps, a data event is swept for and
||| applied. The clause sweeps at the pump's entry instead (Rete/TtlSweep.idr's
||| header); the agreement with FireLoop below is between
||| two models that place it alike.
public export
rarc_5_6_3__prepare_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__prepare_net pg ttl (Tick t) cs = rarc_5_6_3__sweep_net pg (rarc_5_6_3__advance_net t cs)
rarc_5_6_3__prepare_net pg ttl (Data ev) cs = rarc_5_6_4__apply_ttl_net pg ttl ev (rarc_5_6_3__sweep_net pg cs)

--@spec [LFST.9.2.1]
public export
lfst_9_2_1__boundary_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
lfst_9_2_1__boundary_ttl_net pg ttl fuel inp cs = fst (iret_11_4__run_ttl_net pg ttl fuel (rarc_5_6_3__prepare_net pg ttl inp cs))

--@spec [LFST.9.2.1]
||| A canonical replay with ticks on the network.
public export
data Lfst_9_2_1__canonical_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked_net -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Type where
  CanonTtlNetNil  : Lfst_9_2_1__canonical_ttl_net pg ttl cs [] cs
  CanonTtlNetStep : (fuel : Nat) -> fst (snd (iret_11_4__run_ttl_net pg ttl fuel (rarc_5_6_3__prepare_net pg ttl inp cs))) = Quiescent ->
                    Lfst_9_2_1__canonical_ttl_net pg ttl (lfst_9_2_1__boundary_ttl_net pg ttl fuel inp cs) inps cs' ->
                    Lfst_9_2_1__canonical_ttl_net pg ttl cs (inp :: inps) cs'

-- ---------------------------------------------------------------------
-- One action, the RHS, a firing, a run
-- ---------------------------------------------------------------------

--@derives [IRET.4.3]
||| Both sides stamp the same deadline for one action.
export
iret_4_3__record_action_agree : (ttl : Iret_4_2__ttl) -> (now : Nat) -> (tok : Iret_11__tok) -> (act : Lgra_10_1__action) -> (wm : Rarc_5_6_4__wm) -> (dl : Iret_4_3__deadlines) ->
                                iret_4_3__record_action_net ttl now (iret_11__to_act tok) act wm dl = iret_4_3__record_action ttl now tok act wm dl
iret_4_3__record_action_agree ttl now tok (Withdraw _) wm dl = Refl
iret_4_3__record_action_agree ttl now tok (Emit k _) wm dl = Refl

--@derives [IRET.19.3]
export
iret_19_3__clocked_net_eq : {s, s' : Iret_12__net_state} -> {d, d' : Iret_4_3__deadlines} -> (c : Nat) -> s = s' -> d = d' -> MkClockedNet s d c = MkClockedNet s' d' c
iret_19_3__clocked_net_eq c Refl Refl = Refl

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
||| ONE ACTION AGREES, the deadline it stamps included.
export
rlow_4_2_1__do_action_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (act : Lgra_10_1__action) ->
                                  (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                  (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                                  (wm' ** net' ** toks' ** rows' **
                                    ( rarc_5_6_7__do_action_ttl_net pg ttl r (iret_11__to_act tok) act (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c)
                                        = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') (iret_4_3__record_action ttl c tok act wm dl) c
                                    , rarc_5_6_7__do_action_ttl pg ttl r tok act (MkClocked (MkTms (MkState wm toks) rows) dl c)
                                        = MkClocked (MkTms (MkState wm' toks') rows') (iret_4_3__record_action ttl c tok act wm dl) c
                                    , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__do_action_ttl_agree pg ttl r tok act wm net toks rows dl c ag =
  let (wm' ** net' ** toks' ** rows' ** (eN, eF, ag')) = rlow_4_2_1__do_action_tms_agree pg r tok act wm net toks rows ag
  in (wm' ** net' ** toks' ** rows' **
       ( iret_19_3__clocked_net_eq c eN (iret_4_3__record_action_agree ttl c tok act wm dl)
       , cong (\s => MkClocked s (iret_4_3__record_action ttl c tok act wm dl) c) eF
       , ag' ))

--@derives [RARC.5.6.7]
export
rarc_5_6_7__actions_ttl_net_succ : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (a : Iret_8_1__act) -> (act : Lgra_10_1__action) -> (acts : List Lgra_10_1__action) ->
                                   (cs : Iret_19_3__clocked_net) -> (s : Iret_12__net_state) -> (d : Iret_4_3__deadlines) -> (c : Nat) ->
                                   rarc_5_6_7__do_action_ttl_net pg ttl r a act cs = MkClockedNet s d c ->
                                   rarc_5_6_7__do_actions_ttl_net pg ttl r a (act :: acts) cs = rarc_5_6_7__do_actions_ttl_net pg ttl r a acts (MkClockedNet s d c)
rarc_5_6_7__actions_ttl_net_succ pg ttl r a act acts cs s d c eq with (rarc_5_6_7__do_action_ttl_net pg ttl r a act cs)
  rarc_5_6_7__actions_ttl_net_succ pg ttl r a act acts cs s d c eq | (MkClockedNet s' d' c') = cong (rarc_5_6_7__do_actions_ttl_net pg ttl r a acts) eq

--@derives [RARC.5.6.7]
export
rarc_5_6_7__actions_ttl_fl_succ : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (act : Lgra_10_1__action) -> (acts : List Lgra_10_1__action) ->
                                  (cs : Iret_19_3__clocked) -> (s : Iret_12__state) -> (d : Iret_4_3__deadlines) -> (c : Nat) ->
                                  rarc_5_6_7__do_action_ttl pg ttl r tok act cs = MkClocked s d c ->
                                  rarc_5_6_7__do_actions_ttl pg ttl r tok (act :: acts) cs = rarc_5_6_7__do_actions_ttl pg ttl r tok acts (MkClocked s d c)
rarc_5_6_7__actions_ttl_fl_succ pg ttl r tok act acts cs s d c eq with (rarc_5_6_7__do_action_ttl pg ttl r tok act cs)
  rarc_5_6_7__actions_ttl_fl_succ pg ttl r tok act acts cs s d c eq | (MkClocked s' d' c') = cong (rarc_5_6_7__do_actions_ttl pg ttl r tok acts) eq

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
||| THE RHS AGREES, the deadline table threaded through both.
export
rlow_4_2_1__do_actions_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (tok : Iret_11__tok) -> (acts : List Lgra_10_1__action) ->
                                   (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                   (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                                   (wm' ** net' ** toks' ** rows' ** dl' **
                                     ( rarc_5_6_7__do_actions_ttl_net pg ttl r (iret_11__to_act tok) acts (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c)
                                         = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c
                                     , rarc_5_6_7__do_actions_ttl pg ttl r tok acts (MkClocked (MkTms (MkState wm toks) rows) dl c)
                                         = MkClocked (MkTms (MkState wm' toks') rows') dl' c
                                     , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__do_actions_ttl_agree pg ttl r tok [] wm net toks rows dl c ag = (wm ** net ** toks ** rows ** dl ** (Refl, Refl, ag))
rlow_4_2_1__do_actions_ttl_agree pg ttl r tok (act :: acts) wm net toks rows dl c ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (e1, f1, ag1)) = rlow_4_2_1__do_action_ttl_agree pg ttl r tok act wm net toks rows dl c ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** (e2, f2, ag2)) =
           rlow_4_2_1__do_actions_ttl_agree pg ttl r tok acts wm1 net1 toks1 rows1 (iret_4_3__record_action ttl c tok act wm dl) c ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** dl2 **
          ( trans (rarc_5_6_7__actions_ttl_net_succ pg ttl r (iret_11__to_act tok) act acts (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c)
                     (MkTmsNet (MkEngine wm1 net1) rows1) (iret_4_3__record_action ttl c tok act wm dl) c e1) e2
          , trans (rarc_5_6_7__actions_ttl_fl_succ pg ttl r tok act acts (MkClocked (MkTms (MkState wm toks) rows) dl c)
                     (MkTms (MkState wm1 toks1) rows1) (iret_4_3__record_action ttl c tok act wm dl) c f1) f2
          , ag2 ))

--@derives [IRET.11.4]
export
iret_11_4__step_ttl_net_quiet : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                iret_11_1__select (nchains (enet eng)) = Nothing -> iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = Nothing
iret_11_4__step_ttl_net_quiet pg ttl eng rows dl c h = rewrite h in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_ttl_net_fires : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                                iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c)
                                  = Just (rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))
iret_11_4__step_ttl_net_fires pg ttl eng rows dl c r j ch a s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_ttl_quiet : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                            ldet_5_1__select_next tables = Nothing -> iret_11_4__step_ttl pg ttl (MkClocked (MkTms (MkState wm tables) rows) dl c) = Nothing
iret_11_4__step_ttl_quiet pg ttl wm tables rows dl c h = rewrite h in Refl

--@derives [IRET.11.4]
export
iret_11_4__step_ttl_fires : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            (dl : Iret_4_3__deadlines) -> (c : Nat) -> (r, j : Nat) -> (rule : Lgra_6_1__rule) -> (tok : Iret_11__tok) ->
                            ldet_5_1__select_next tables = Just (r, j) -> rarc_5_6_5__nth r (rules pg) = Just rule -> rarc_5_6_5__nth j (iret_11__table_at r tables) = Just tok ->
                            iret_11_4__step_ttl pg ttl (MkClocked (MkTms (MkState wm tables) rows) dl c)
                              = Just (rarc_5_6_7__do_actions_ttl pg ttl r tok (actions rule) (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j tables)) rows) dl c))
iret_11_4__step_ttl_fires pg ttl wm tables rows dl c r j rule tok s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
||| ONE FIRING AGREES, the deadline table included.
export
rlow_4_2_1__step_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                             (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                             Either ( iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = Nothing
                                    , iret_11_4__step_ttl pg ttl (MkClocked (MkTms (MkState wm toks) rows) dl c) = Nothing )
                                    (wm' ** net' ** toks' ** rows' ** dl' **
                                      ( iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = Just (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c)
                                      , iret_11_4__step_ttl pg ttl (MkClocked (MkTms (MkState wm toks) rows) dl c) = Just (MkClocked (MkTms (MkState wm' toks') rows') dl' c)
                                      , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__step_ttl_agree pg ttl wm net toks rows dl c ag =
  let (ra, ta, ord, well) = ag
  in case rlow_4_2_1__select_agree toks (nchains net) ta of
       Left (sn, sc) => Left (iret_11_4__step_ttl_net_quiet pg ttl (MkEngine wm net) rows dl c sc, iret_11_4__step_ttl_quiet pg ttl wm toks rows dl c sn)
       Right (r ** j ** j' ** ts ** ch ** tok ** (sn, sc, nts, nc, nt, nb, nf, na)) =>
         let (rule ** (nr, sr)) = rlow_4_2_1__rule_at (nalphas net) (nchains net) (rules pg) ra r ch nc
         in let acEq : (actions (rlow_4_2_1__rule_of (nalphas net) ch) = actions rule)
                acEq = snd (snd (snd sr))
                marked : Rlow_4_2_1__agree pg wm (MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net))) (idat_6_2_2__mark_fired r j toks)
                marked = rlow_4_2_1__mark_agree_state pg wm net toks ag r j j' ts ch sn sc nts nc
         in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** (aN, aF, ag2)) =
                  rlow_4_2_1__do_actions_ttl_agree pg ttl r tok (cactions ch) wm (MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net)))
                    (idat_6_2_2__mark_fired r j toks) rows dl c marked
         in let stepN : (iret_11_4__step_ttl_net pg ttl (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = Just (MkClockedNet (MkTmsNet (MkEngine wm2 net2) rows2) dl2 c))
                stepN = trans (iret_11_4__step_ttl_net_fires pg ttl (MkEngine wm net) rows dl c r j' ch (iret_11__to_act tok) sc nc na) (cong Just aN)
                stepF : (iret_11_4__step_ttl pg ttl (MkClocked (MkTms (MkState wm toks) rows) dl c) = Just (MkClocked (MkTms (MkState wm2 toks2) rows2) dl2 c))
                stepF = trans (iret_11_4__step_ttl_fires pg ttl wm toks rows dl c r j rule tok sn nr
                                 (replace {p = \z => rarc_5_6_5__nth j z = Just tok} (sym (iret_11__table_at_nth r toks ts nts)) nt))
                              (cong Just (trans (cong (\acts => rarc_5_6_7__do_actions_ttl pg ttl r tok acts (MkClocked (MkTms (MkState wm (idat_6_2_2__mark_fired r j toks)) rows) dl c))
                                                      (sym acEq)) aF))
            in Right (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** (stepN, stepF, ag2))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE CLOCKED NETWORK'S RUN IS THE ONE FOLD at its step (Rete/RunFold.idr's
||| `iret_11_4__run_by`), by induction on the fuel. Its two unfoldings below
||| are RunFold's through it.
export
iret_11_4__run_ttl_net_by : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s : Iret_19_3__clocked_net) ->
                            iret_11_4__run_ttl_net pg ttl fuel s = iret_11_4__run_by (iret_11_4__step_ttl_net pg ttl) fuel s
iret_11_4__run_ttl_net_by pg ttl Z s = Refl
iret_11_4__run_ttl_net_by pg ttl (S fuel) s with (iret_11_4__step_ttl_net pg ttl s)
  iret_11_4__run_ttl_net_by pg ttl (S fuel) s | Nothing = Refl
  iret_11_4__run_ttl_net_by pg ttl (S fuel) s | (Just s') with (iret_11_4__run_by (iret_11_4__step_ttl_net pg ttl) fuel s') proof rr
    iret_11_4__run_ttl_net_by pg ttl (S fuel) s | (Just s') | (t, h, n) = rewrite trans (iret_11_4__run_ttl_net_by pg ttl fuel s') rr in Refl

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| FIRELOOP'S RUN WITH THE DEADLINE TABLE IS THE ONE FOLD at its step
||| (Rete/TtlSweep.idr's loop), by induction on the fuel. Its two unfoldings
||| below are RunFold's through it.
export
iret_11_4__run_ttl_by : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s : Iret_19_3__clocked) ->
                        iret_11_4__run_ttl pg ttl fuel s = iret_11_4__run_by (iret_11_4__step_ttl pg ttl) fuel s
iret_11_4__run_ttl_by pg ttl Z s = Refl
iret_11_4__run_ttl_by pg ttl (S fuel) s with (iret_11_4__step_ttl pg ttl s)
  iret_11_4__run_ttl_by pg ttl (S fuel) s | Nothing = Refl
  iret_11_4__run_ttl_by pg ttl (S fuel) s | (Just s') with (iret_11_4__run_by (iret_11_4__step_ttl pg ttl) fuel s') proof rr
    iret_11_4__run_ttl_by pg ttl (S fuel) s | (Just s') | (t, h, n) = rewrite trans (iret_11_4__run_ttl_by pg ttl fuel s') rr in Refl

--@derives [IRET.11.4]
export
iret_11_4__run_ttl_net_nothing : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s : Iret_19_3__clocked_net) -> iret_11_4__step_ttl_net pg ttl s = Nothing ->
                                 iret_11_4__run_ttl_net pg ttl (S fuel) s = (s, Quiescent, 0)
iret_11_4__run_ttl_net_nothing pg ttl fuel s eq =
  trans (iret_11_4__run_ttl_net_by pg ttl (S fuel) s) (iret_11_4__run_by_nothing (iret_11_4__step_ttl_net pg ttl) fuel s eq)

--@derives [IRET.11.4]
export
iret_11_4__run_ttl_net_just : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s, s' : Iret_19_3__clocked_net) -> iret_11_4__step_ttl_net pg ttl s = Just s' ->
                              (t : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_ttl_net pg ttl fuel s' = (t, h, n) ->
                              iret_11_4__run_ttl_net pg ttl (S fuel) s = (t, h, S n)
iret_11_4__run_ttl_net_just pg ttl fuel s s' eq t h n rr =
  trans (iret_11_4__run_ttl_net_by pg ttl (S fuel) s)
        (iret_11_4__run_by_just (iret_11_4__step_ttl_net pg ttl) fuel s s' eq t h n (trans (sym (iret_11_4__run_ttl_net_by pg ttl fuel s')) rr))

--@derives [IRET.11.4]
export
iret_11_4__run_ttl_nothing_fl : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s : Iret_19_3__clocked) -> iret_11_4__step_ttl pg ttl s = Nothing ->
                                iret_11_4__run_ttl pg ttl (S fuel) s = (s, Quiescent, 0)
iret_11_4__run_ttl_nothing_fl pg ttl fuel s eq =
  trans (iret_11_4__run_ttl_by pg ttl (S fuel) s) (iret_11_4__run_by_nothing (iret_11_4__step_ttl pg ttl) fuel s eq)

--@derives [IRET.11.4]
export
iret_11_4__run_ttl_just_fl : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (s, s' : Iret_19_3__clocked) -> iret_11_4__step_ttl pg ttl s = Just s' ->
                             (t : Iret_19_3__clocked) -> (h : Iret_11_4__halt) -> (n : Nat) -> iret_11_4__run_ttl pg ttl fuel s' = (t, h, n) ->
                             iret_11_4__run_ttl pg ttl (S fuel) s = (t, h, S n)
iret_11_4__run_ttl_just_fl pg ttl fuel s s' eq t h n rr =
  trans (iret_11_4__run_ttl_by pg ttl (S fuel) s)
        (iret_11_4__run_by_just (iret_11_4__step_ttl pg ttl) fuel s s' eq t h n (trans (sym (iret_11_4__run_ttl_by pg ttl fuel s')) rr))

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| A RUN AGREES under any fuel: the same firings, the same halt, the
||| same count, the same deadlines; the clock is the pump's own.
export
rlow_4_2_1__run_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                            (wm' ** net' ** toks' ** rows' ** dl' ** h ** n **
                              ( iret_11_4__run_ttl_net pg ttl fuel (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c, h, n)
                              , iret_11_4__run_ttl pg ttl fuel (MkClocked (MkTms (MkState wm toks) rows) dl c) = (MkClocked (MkTms (MkState wm' toks') rows') dl' c, h, n)
                              , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__run_ttl_agree pg ttl Z wm net toks rows dl c ag = (wm ** net ** toks ** rows ** dl ** FuelOut ** 0 ** (Refl, Refl, ag))
rlow_4_2_1__run_ttl_agree pg ttl (S fuel) wm net toks rows dl c ag =
  case rlow_4_2_1__step_ttl_agree pg ttl wm net toks rows dl c ag of
    Left (qn, qf) => (wm ** net ** toks ** rows ** dl ** Quiescent ** 0 **
                      ( iret_11_4__run_ttl_net_nothing pg ttl fuel (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) qn
                      , iret_11_4__run_ttl_nothing_fl pg ttl fuel (MkClocked (MkTms (MkState wm toks) rows) dl c) qf
                      , ag ))
    Right (wm1 ** net1 ** toks1 ** rows1 ** dl1 ** (sN, sF, ag1)) =>
      let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** h ** n ** (rN, rF, ag2)) = rlow_4_2_1__run_ttl_agree pg ttl fuel wm1 net1 toks1 rows1 dl1 c ag1
      in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** h ** S n **
           ( iret_11_4__run_ttl_net_just pg ttl fuel (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) (MkClockedNet (MkTmsNet (MkEngine wm1 net1) rows1) dl1 c) sN
               (MkClockedNet (MkTmsNet (MkEngine wm2 net2) rows2) dl2 c) h n rN
           , iret_11_4__run_ttl_just_fl pg ttl fuel (MkClocked (MkTms (MkState wm toks) rows) dl c) (MkClocked (MkTms (MkState wm1 toks1) rows1) dl1 c) sF
               (MkClocked (MkTms (MkState wm2 toks2) rows2) dl2 c) h n rF
           , ag2 ))

-- ---------------------------------------------------------------------
-- The sweep, the advance, a data event, a boundary
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [IRET.19.3]
--@derives [IRET.22.6]
||| THE SWEEP AGREES: the network's retractions one at a time in
||| [LDTL.6.1]'s order and FireLoop's batch end in one working memory, and
||| the cascades after them agree.
export
rlow_4_2_1__sweep_agree : (pg : Lcyc_3_2_1__program) ->
                          (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                          (wm' ** net' ** toks' ** rows' **
                            ( rarc_5_6_3__sweep_net pg (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl c
                            , rarc_5_6_3__sweep pg (MkClocked (MkTms (MkState wm toks) rows) dl c) = MkClocked (MkTms (MkState wm' toks') rows') dl c
                            , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__sweep_agree pg wm net toks rows dl c ag =
  let (ra, ta, ord, (dw, uq, tw)) = ag
  in let sameR : (iret_12_2__retract_ids (ldtl_6_1__order dl (iret_19_3__expired c dl)) wm = iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
         sameR = ldtl_6_1__retract_order dl (iret_19_3__expired c dl) wm
         ag1 : Rlow_4_2_1__agree pg (iret_12_2__retract_ids (ldtl_6_1__order dl (iret_19_3__expired c dl)) wm)
                                    (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net)))
                                    (rarc_5_6_5__propagate pg (iret_12_2__retract_ids (ldtl_6_1__order dl (iret_19_3__expired c dl)) wm) toks)
         ag1 = rlow_4_2_1__retract_ids_agree pg (ldtl_6_1__order dl (iret_19_3__expired c dl)) wm net toks ag
         ag2 : Rlow_4_2_1__agree pg (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
                                    (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net)))
                                    (rarc_5_6_5__propagate pg (iret_12_2__retract_ids (iret_19_3__expired c dl) wm) toks)
         ag2 = replace {p = \w => Rlow_4_2_1__agree pg w (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net)))
                                                     (rarc_5_6_5__propagate pg w toks)} sameR ag1
         engEq : (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net)
                  = MkEngine (iret_12_2__retract_ids (iret_19_3__expired c dl) wm) (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net))))
         engEq = trans (sym (iret_19__engine_eta (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net))))
                       (cong (\w => MkEngine w (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net))))
                             (trans (iret_12_2__retract_ids_net_wm (ldtl_6_1__order dl (iret_19_3__expired c dl)) wm uq net) sameR))
  in let (wm3 ** net3 ** toks3 ** rows3 ** (pN, pF, ag3)) =
           rlow_4_2_1__phase_agree pg (iret_12_2__retract_ids (iret_19_3__expired c dl) wm)
             (enet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) (MkEngine wm net)))
             (rarc_5_6_5__propagate pg (iret_12_2__retract_ids (iret_19_3__expired c dl) wm) toks) rows ag2
     in (wm3 ** net3 ** toks3 ** rows3 **
          ( trans (cong (\e => MkClockedNet (iret_12_2__phase_net pg (MkTmsNet e rows)) dl c) engEq) (cong (\s => MkClockedNet s dl c) pN)
          , cong (\s => MkClocked s dl c) pF
          , ag3 ))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.4]
||| A DATA EVENT AGREES, the adapter assert's deadline included.
export
rlow_4_2_1__apply_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ev : Rarc_5_6_1__event) ->
                              (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                              (wm' ** net' ** toks' ** rows' ** dl' **
                                ( rarc_5_6_4__apply_ttl_net pg ttl ev (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c
                                , rarc_5_6_4__apply_ttl pg ttl ev (MkClocked (MkTms (MkState wm toks) rows) dl c) = MkClocked (MkTms (MkState wm' toks') rows') dl' c
                                , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__apply_ttl_agree pg ttl (Assert k key pay) wm net toks rows dl c ag =
  let (wm' ** net' ** toks' ** rows' ** (aN, aF, ag')) = rlow_4_2_1__apply_tms_agree pg (Assert k key pay) wm net toks rows ag
  in (wm' ** net' ** toks' ** rows' ** iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] wm) k dl **
       ( cong (\s => MkClockedNet s (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] wm) k dl) c) aN
       , cong (\s => MkClocked s (iret_4_3__stamp ttl c (lfac_2_5_3__fresh_id [] wm) k dl) c) aF
       , ag' ))
rlow_4_2_1__apply_ttl_agree pg ttl (Retract i) wm net toks rows dl c ag =
  let (wm' ** net' ** toks' ** rows' ** (aN, aF, ag')) = rlow_4_2_1__apply_tms_agree pg (Retract i) wm net toks rows ag
  in (wm' ** net' ** toks' ** rows' ** dl **
       ( cong (\s => MkClockedNet s dl c) aN
       , cong (\s => MkClocked s dl c) aF
       , ag' ))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.3]
||| THE LOOP'S STEPS BEFORE FIRING AGREE: a tick advances both clocks
||| alike and sweeps alike; a data event is swept for and applied alike.
export
rlow_4_2_1__prepare_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (inp : Rarc_5_6_2__input) ->
                            (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                            (wm' ** net' ** toks' ** rows' ** dl' ** c' **
                              ( rarc_5_6_3__prepare_net pg ttl inp (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c'
                              , rarc_5_6_3__prepare pg ttl inp (MkClocked (MkTms (MkState wm toks) rows) dl c) = MkClocked (MkTms (MkState wm' toks') rows') dl' c'
                              , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__prepare_agree pg ttl (Tick t) wm net toks rows dl c ag =
  let (wm' ** net' ** toks' ** rows' ** (sN, sF, ag')) = rlow_4_2_1__sweep_agree pg wm net toks rows dl (rarc_5_6_3__next_clock c t) ag
  in (wm' ** net' ** toks' ** rows' ** dl ** rarc_5_6_3__next_clock c t ** (sN, sF, ag'))
rlow_4_2_1__prepare_agree pg ttl (Data ev) wm net toks rows dl c ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** (sN, sF, ag1)) = rlow_4_2_1__sweep_agree pg wm net toks rows dl c ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** (aN, aF, ag2)) = rlow_4_2_1__apply_ttl_agree pg ttl ev wm1 net1 toks1 rows1 dl c ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c **
          ( trans (cong (rarc_5_6_4__apply_ttl_net pg ttl ev) sN) aN
          , trans (cong (rarc_5_6_4__apply_ttl pg ttl ev) sF) aF
          , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| AN INPUT PUMPED agrees: the loop's steps before firing, then the run,
||| with the same halt and count.
export
rlow_4_2_1__boundary_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (inp : Rarc_5_6_2__input) ->
                                 (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                 (dl : Iret_4_3__deadlines) -> (c : Nat) -> Rlow_4_2_1__agree pg wm net toks ->
                                 (wm' ** net' ** toks' ** rows' ** dl' ** c' ** h ** n **
                                   ( iret_11_4__run_ttl_net pg ttl fuel (rarc_5_6_3__prepare_net pg ttl inp (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c))
                                       = (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c', h, n)
                                   , iret_11_4__run_ttl pg ttl fuel (rarc_5_6_3__prepare pg ttl inp (MkClocked (MkTms (MkState wm toks) rows) dl c))
                                       = (MkClocked (MkTms (MkState wm' toks') rows') dl' c', h, n)
                                   , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__boundary_ttl_agree pg ttl fuel inp wm net toks rows dl c ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** dl1 ** c1 ** (pN, pF, ag1)) = rlow_4_2_1__prepare_agree pg ttl inp wm net toks rows dl c ag
  in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** h ** n ** (rN, rF, ag2)) = rlow_4_2_1__run_ttl_agree pg ttl fuel wm1 net1 toks1 rows1 dl1 c1 ag1
     in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c1 ** h ** n **
          ( trans (cong (iret_11_4__run_ttl_net pg ttl fuel) pN) rN
          , trans (cong (iret_11_4__run_ttl pg ttl fuel) pF) rF
          , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| A CANONICAL REPLAY WITH TICKS ON FIRELOOP IS ONE ON THE NETWORK, input
||| by input with the same fuel, and the states agree throughout -- one
||| working memory, one dependency table, one deadline table, one clock.
export
rlow_4_2_1__canonical_ttl_agree : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (inps : List Rarc_5_6_2__input) ->
                                  (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                  (dl : Iret_4_3__deadlines) -> (c : Nat) -> (cs' : Iret_19_3__clocked) ->
                                  Lfst_9_2_1__canonical_ttl pg ttl (MkClocked (MkTms (MkState wm toks) rows) dl c) inps cs' -> Rlow_4_2_1__agree pg wm net toks ->
                                  (wm' ** net' ** toks' ** rows' ** dl' ** c' **
                                    ( Lfst_9_2_1__canonical_ttl_net pg ttl (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) inps (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c')
                                    , cs' = MkClocked (MkTms (MkState wm' toks') rows') dl' c'
                                    , Rlow_4_2_1__agree pg wm' net' toks' ))
rlow_4_2_1__canonical_ttl_agree pg ttl [] wm net toks rows dl c _ CanonTtlNil ag = (wm ** net ** toks ** rows ** dl ** c ** (CanonTtlNetNil, Refl, ag))
rlow_4_2_1__canonical_ttl_agree pg ttl (inp :: inps) wm net toks rows dl c cs' (CanonTtlStep fuel q rest) ag =
  let (wm1 ** net1 ** toks1 ** rows1 ** dl1 ** c1 ** h ** n ** (bN, bF, ag1)) = rlow_4_2_1__boundary_ttl_agree pg ttl fuel inp wm net toks rows dl c ag
  in let hq : (h = Quiescent)
         hq = trans (sym (cong (\t => fst (snd t)) bF)) q
         bEq : (lfst_9_2_1__boundary_ttl pg ttl fuel inp (MkClocked (MkTms (MkState wm toks) rows) dl c) = MkClocked (MkTms (MkState wm1 toks1) rows1) dl1 c1)
         bEq = cong fst bF
         bNEq : (lfst_9_2_1__boundary_ttl_net pg ttl fuel inp (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c) = MkClockedNet (MkTmsNet (MkEngine wm1 net1) rows1) dl1 c1)
         bNEq = cong fst bN
         rest1 : Lfst_9_2_1__canonical_ttl pg ttl (MkClocked (MkTms (MkState wm1 toks1) rows1) dl1 c1) inps cs'
         rest1 = replace {p = \s => Lfst_9_2_1__canonical_ttl pg ttl s inps cs'} bEq rest
     in let (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 ** (cn, eq2, ag2)) = rlow_4_2_1__canonical_ttl_agree pg ttl inps wm1 net1 toks1 rows1 dl1 c1 cs' rest1 ag1
        in (wm2 ** net2 ** toks2 ** rows2 ** dl2 ** c2 **
             ( CanonTtlNetStep fuel (trans (cong (\t => fst (snd t)) bN) hq)
                 (replace {p = \s => Lfst_9_2_1__canonical_ttl_net pg ttl s inps (MkClockedNet (MkTmsNet (MkEngine wm2 net2) rows2) dl2 c2)} (sym bNEq) cn)
             , eq2
             , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [IRET.19.3]
--@derives [LFST.9.2.1]
||| THE TRANSFER WITH TICKS. A canonical replay with ticks from
||| FireLoop's empty state under the program the loaded network lowers to
||| is one from the loaded network, with the same fuel per input, and at
||| its end the two agree: one working memory, one dependency table, one
||| deadline table, one clock, each table's unblocked tokens the
||| terminal's activations.
export
rlow_4_2_1__transfer_ttl : (life : Nat -> Lscp_1_3__lifecycle) -> (ttl : Iret_4_2__ttl) -> (c0 : Nat) -> (inps : List Rarc_5_6_2__input) ->
                           (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                           (cs' : Iret_19_3__clocked) ->
                           Lfst_9_2_1__canonical_ttl (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl
                             (MkClocked (rarc_5_6_5__init_tms (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []) [] c0) inps cs' ->
                           (wm' ** net' ** toks' ** rows' ** dl' ** c' **
                             ( Lfst_9_2_1__canonical_ttl_net (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl
                                 (MkClockedNet (MkTmsNet (rdsc_4a_5__load alphas rules) []) [] c0) inps (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c')
                             , cs' = MkClocked (MkTms (MkState wm' toks') rows') dl' c'
                             , Rlow_4_2_1__agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) wm' net' toks' ))
rlow_4_2_1__transfer_ttl life ttl c0 inps alphas rules cs' canon =
  rlow_4_2_1__canonical_ttl_agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl inps [] (enet (rdsc_4a_5__load alphas rules))
    (toks (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) [])) [] [] c0 cs' canon
    (rlow_4_2_1__init_agree life alphas rules)

--@derives [IRET.22.6]
--@derives [RLOW.4.2.1]
||| [IRET.22.6] ON THE NETWORK. For a positive program certified as
||| [LCYC.3.1.1] admits it and lowered from a loaded network, every
||| input stream with ticks has a canonical replay from the loaded network
||| at whose end the deadline table is well-formed on the network's
||| working memory: every live TTL fact has its deadline, no other live
||| fact has one, and every live fact's deadline is after the clock --
||| whatever had expired is gone, and nothing was retracted early.
export
iret_22_6__network_deadlines : (life : Nat -> Lscp_1_3__lifecycle) -> (ttl : Iret_4_2__ttl) -> (c0 : Nat) ->
                               (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                               Iret_7_9__positive (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ->
                               (ct : Lcyc_3_1_1__certified_tms (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules)))) ->
                               (dom : List (Nat, Nat)) -> ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                               (inps : List Rarc_5_6_2__input) -> All (Rarc_5_6_2__input_in_dom dom) inps ->
                               (wm' ** net' ** rows' ** dl' ** c' **
                                 ( Lfst_9_2_1__canonical_ttl_net (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl
                                     (MkClockedNet (MkTmsNet (rdsc_4a_5__load alphas rules) []) [] c0) inps (MkClockedNet (MkTmsNet (MkEngine wm' net') rows') dl' c')
                                 , Iret_4_3__deadlines_ok ttl wm' dl' c' ))
iret_22_6__network_deadlines life ttl c0 alphas rules pos ct dom litsIn inps inpds =
  let (cs' ** (canon, inv)) = lfst_9_2_1__canonical_ttl_from_input (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) pos ct ttl dom litsIn
                                [] [] (\f, g, e, _, _ => absurd e) c0 inps inpds
  in let (wm' ** net' ** toks' ** rows' ** dl' ** c' ** (cn, eq, _)) = rlow_4_2_1__transfer_ttl life ttl c0 inps alphas rules cs' canon
  in let (_, _, dok) = replace {p = \x => Iret_19_3__inv (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) ttl dom x} eq inv
  in (wm' ** net' ** rows' ** dl' ** c' ** (cn, dok))

-- ---------------------------------------------------------------------
-- A tick that expires nothing
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| Phases on the network that end nothing touch nothing.
export
iret_12_2__phase_n_net_quiet : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                               iret_12_2__ended_net eng rows = [] -> iret_12_2__phase_n_net n pg (MkTmsNet eng rows) = MkTmsNet eng rows
iret_12_2__phase_n_net_quiet Z pg eng rows h = Refl
iret_12_2__phase_n_net_quiet (S n) pg eng rows h =
  rewrite iret_12_2__phase_step_net_nil pg eng rows h in iret_12_2__phase_n_net_quiet n pg eng rows h

--@derives [LDET.5.8]
--@derives [RARC.5.6.3]
||| A TICK THAT EXPIRES NOTHING MOVES ONLY THE CLOCK. From a state between
||| actions (no activation ended and not yet cascaded), when no deadline
||| is at or before the new clock, the tick's advance and sweep leave the
||| network's working memory, its terminals -- tokens and `fired` flags --
||| its dependency table and its deadline table as they were: no
||| activation is created, ended or re-armed by it. Cycling the clock is
||| not a change to the LHS, [LDET.5.8]'s requirement, for the tests the
||| model has (predicates of facts).
export
ldet_5_8__quiet_tick_net : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (t : Nat) ->
                           (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (rows : Iret_12_4__table) ->
                           (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                           iret_12_2__ended_net (MkEngine wm net) rows = [] ->
                           iret_19_3__expired (rarc_5_6_3__next_clock c t) dl = [] ->
                           rarc_5_6_3__prepare_net pg ttl (Tick t) (MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl c)
                             = MkClockedNet (MkTmsNet (MkEngine wm net) rows) dl (rarc_5_6_3__next_clock c t)
ldet_5_8__quiet_tick_net pg ttl t wm net rows dl c noEnd noExp =
  rewrite noExp in
  rewrite iret_12_2__phase_n_net_quiet (S (length rows)) pg (MkEngine wm net) rows noEnd in
  Refl

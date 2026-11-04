-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE GENERAL FRAME ON THE CLOCKED NETWORK: a chain no rule writes into
||| fires once per match through the cascades the other rules' endings
||| start, on the engine Rete/NetworkClocked.idr pumps. The clocked-network
||| programme's part B'' -- the lift of Rete/NetworkFrame.idr's part B' from the plain
||| network to the network with truth maintenance and the clock.
|||
||| NORMATIVE COMPANION to Rete/NetworkFrame.idr, which it stands on.
|||
||| WHY. NetworkFrame's theorem is of the plain network: no dependency
||| table, so no cascade retracts a logical fact in the middle of a pump,
||| and no clock, so nothing expires. On the clocked engine every action of
||| a firing is followed by the cascade of [IRET.12.2] -- the rows of the
||| activations that ended are dropped and the facts those rows alone
||| supported are retracted, one at a time through alpha dispatch
||| (Rete/NetworkTms.idr) -- and a cascade could, on its face, retract a
||| fact a framed chain reads. It cannot, and the reason is the frame's
||| own: A CASCADE'S TARGETS ARE EMITTED KINDS. A row is recorded by a
||| logical emit and targets the fact that emit left live, of the emit's
||| kind ([IRET.10.2]); the frame forbids every rule of the program to
||| write a kind the chain reads; so what a cascade retracts is of kinds
||| the chain does not read, and dispatch skips it.
|||
||| What makes that an invariant rather than a remark is fact-id reuse.
||| `lfac_2_5_3__fresh_id` mints the smallest id not live ([LFAC.2.5.3]),
||| so an id a row still names after its fact is gone could be minted
||| again, for a fact of a kind the chain reads, and a later cascade would
||| retract it. The model runs the cascade to its fixpoint after every
||| input and every action; at the fixpoint every row's target is live
||| (`iret_12_2__phase_n_net_fixed`, TmsBridge's fuel argument on the
||| network's phase); a mint happens only at such a state; so no stale row
||| survives to a mint, and a fresh id is no row's target
||| (`ltim_2_5_1__rows_emitted_append`). Unique ids ([IRET.4.4], carried
||| as `Iret_4_4__unique`) make the fact a cascade looks up by a row's
||| target the fact the row was recorded for.
|||
||| PROVED.
|||
|||   * THE ROW INVARIANT (`Ltim_2_5_1__rows_emitted`, `Ltim_2_5_1__rows_live`)
|||     is kept by every working-memory operation, by the record of a
|||     logical emit, and by the cascade; the cascade re-establishes
|||     `rows_live` at its fixpoint (`iret_12_2__phase_net_inv_live`).
|||   * UNIQUE IDS are kept by every operation of the network engine
|||     (`iret_19_1__assert_unique` .. `iret_12_2__retract_ids_net_unique`).
|||   * THE CASCADE SKIPS A FRAMED CHAIN (`iret_12_2__retract_ids_net_frame`,
|||     `iret_12_2__phase_net_frame`): the ids a phase retracts are targets
|||     of rows, so of emitted kinds, so of kinds the chain does not read.
|||   * ONE ACTION, THE RHS, ONE FIRING AND THE RUN UNDER THE FRAME on the
|||     clocked network (`rarc_5_6_7__do_action_tms_frame`,
|||     `rarc_5_6_7__do_actions_ttl_frame`, `ltim_2_5_1__step_frame_ttl`,
|||     `ltim_2_5_1__run_frame_ttl`): NetworkFrame's statements, with the
|||     table and the cascade in the loop, on the traced run
|||     (`iret_11_4__run_ttl_net_traced`, the clocked network's form of
|||     NetworkFrame's). Fuel is not assumed to suffice.
|||   * THE INVARIANT THROUGH A PREPARE WITHOUT A RE-TIME
|||     (`rarc_5_6_3__prepare_net_inv`): a tick's sweep and a data input,
|||     each with its cascade, keep it, and leave every activation of
|||     every chain unfired when all were (`rarc_5_6_3__prepare_net_unfired`).
|||   * THE THEOREM (`iret_11_3__framed_fires_once_per_match_ttl`): from the
|||     loaded clocked network, after any inputs prepared with no run
|||     between them, a run that reaches quiescence fires a framed chain
|||     exactly once per match it holds when the run begins -- whatever the
|||     other rules emit and withdraw, and whatever their endings cascade.
|||   * EXECUTED, TWICE: NetworkFrame's two rules with B's emit made logical
|||     and B loaded first. B reads kind 1, emits kind 2 `logical` and
|||     withdraws its own kind-1 fact; the withdrawal ends B's activation,
|||     and the cascade that follows retracts the kind-2 fact B had just
|||     emitted. One kind-0 input, as one `Refl`: A, framed, fires for its
|||     match, B fires and cascades, the run is quiescent -- `[1, 0]`, and
|||     no kind-2 fact survives (`ltim_2_5_1__one_fact_trace_ttl`); the
|||     theorem applied at the fixture
|||     (`ltim_2_5_1__one_fact_is_an_instance_ttl`) takes the frame and the
|||     prepared chain by computation and the run from that trace,
|||     evaluated once (`iret_11_4__trace_of_ttl_inv`). Two kind-0 inputs,
|||     firing by firing: A, B with its cascade, A again -- minting the
|||     withdrawn kind-1 fact's id again -- and B with its cascade again,
|||     `[1, 0, 1, 0]`, each firing a `Refl` from a literal state, chained
|||     by `iret_11_4__run_ttl_net_traced_cons` as Lcyc/TmsWitnesses.idr
|||     does (`ltim_2_5_1__two_facts_run_ttl`), and the theorem applied at
|||     that fixture (`ltim_2_5_1__two_facts_is_an_instance_ttl`): two
|||     firings for two matches, B's cascade between them. The four-firing
|||     run as one `Refl` is beyond the type-level evaluator within the
|||     lane's wall clock (the one-input fixture's doc says what was
|||     measured), which is what the step-wise form is for.
|||   * EXECUTED, THREE MORE, the witnesses unit S owed: a tick that expires
|||     a fact with a TTL -- the sweep's retraction, the deadline table and
|||     the clock in the literal, and the theorem at it, the expired match
|||     not counted (`ltim_2_5_1__ticked_ready_ttl`,
|||     `ltim_2_5_1__ticked_is_an_instance_ttl`); a run that runs out of
|||     fuel after A's first firing, with the count equation
|||     `ltim_2_5_1__run_frame_ttl` states read at `FuelOut`
|||     (`ltim_2_5_1__two_facts_fuel_out_ttl`, `ltim_2_5_1__fuel_out_count_ttl`);
|||     and an entity replaced and re-asserted unchanged, and a relation
|||     re-asserted, among the inputs, the replacement minted against the
|||     memory the old wrapper was still in, and the theorem at it
|||     (`ltim_2_5_1__entity_ready_ttl`, `ltim_2_5_1__entity_is_an_instance_ttl`).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The re-time stage of
||| NetworkClocked's tick (`iret_19_5__retime_clocked`) replaces a timed
||| node's test by its value at the new clock, and NetworkFrame's
||| `Rlow_4_2_1__shapes_kept` compared tests by equality when this file was
||| written; so a prepare that re-times is outside this file, and the
||| theorem is stated over NetworkTtl's prepare (ticks that sweep, data
||| inputs) and NetworkClocked's run, which has no re-time. The lift over
||| the re-time is Rete/NetworkFrameRetime.idr's: the
||| shapes kept now compare the kinds alone (`Rlow_4_2_1__same_kinds`,
||| alphas and negation flags, no tests), which every proof here holds of
||| unchanged, and the theorem there is this one with NetworkClocked's
||| prepare. The rest is NetworkFrame's: the frame is syntactic over the
||| loaded program, inputs are not framed, and the theorem is about the
||| run after them.
module Rete.NetworkFrameClocked

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkAgree
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkTransferAgree
import Rete.NetworkTransfer
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkOnce
import Rete.NetworkFrame
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
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
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Emitted kinds
-- ---------------------------------------------------------------------

--@spec [IRET.10.2]
--@spec [LTIM.2.5.1]
||| THE KINDS A RULE EMITS: an emit's kind. A withdraw emits nothing.
public export
ltim_2_5_1__emits_of : List Lgra_10_1__action -> List Nat
ltim_2_5_1__emits_of [] = []
ltim_2_5_1__emits_of (Emit k v :: as) = k :: ltim_2_5_1__emits_of as
ltim_2_5_1__emits_of (Withdraw i :: as) = ltim_2_5_1__emits_of as

--@spec [IRET.12.4]
--@spec [LTIM.2.5.1]
||| A KIND SOME RULE OF THE PROGRAM EMITS.
public export
Ltim_2_5_1__emitted : List Rlow_4_2_1__chain -> Nat -> Type
Ltim_2_5_1__emitted chains k = (ch ** (Elem ch chains, Elem k (ltim_2_5_1__emits_of (cactions ch))))

--@derives [LTIM.2.5.1]
||| An emit's kind is among the rule's emits.
export
ltim_2_5_1__emits_elem : (as : List Lgra_10_1__action) -> (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) ->
                         Elem (Emit k v) as -> Elem k (ltim_2_5_1__emits_of as)
ltim_2_5_1__emits_elem (Emit _ _ :: as) k v Here = Here
ltim_2_5_1__emits_elem (Emit k' v' :: as) k v (There e) = There (ltim_2_5_1__emits_elem as k v e)
ltim_2_5_1__emits_elem (Withdraw i :: as) k v (There e) = ltim_2_5_1__emits_elem as k v e

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.7]
||| An emitted kind is a written kind.
export
ltim_2_5_1__emits_writes : (pos : List Nat) -> (as : List Lgra_10_1__action) -> (k : Nat) ->
                           Elem k (ltim_2_5_1__emits_of as) -> Elem k (ltim_2_5_1__writes_of pos as)
ltim_2_5_1__emits_writes pos [] k e = absurd e
ltim_2_5_1__emits_writes pos (Emit _ _ :: as) k Here = Here
ltim_2_5_1__emits_writes pos (Emit k' v :: as) k (There e) = There (ltim_2_5_1__emits_writes pos as k e)
ltim_2_5_1__emits_writes pos (Withdraw i :: as) k e = ltim_2_5_1__kind_or_elem (rarc_5_6_5__nth i pos) _ k (ltim_2_5_1__emits_writes pos as k e)

--@derives [LTIM.2.5.1]
||| UNDER THE FRAME, NO EMITTED KIND IS ONE THE CHAIN READS.
export
ltim_2_5_1__emitted_not_read : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (nodes : List Iret_7_4__beta) ->
                               ltim_2_5_1__framed alphas0 chains0 nodes = True ->
                               (k : Nat) -> Ltim_2_5_1__emitted chains0 k -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 nodes) = False
ltim_2_5_1__emitted_not_read alphas0 chains0 nodes fr k (ch ** (ech, ek)) =
  ltim_2_5_1__framed_rule alphas0 chains0 nodes ch fr ech k
    (ltim_2_5_1__emits_writes (rlow_5_1__pos_kinds alphas0 (cnodes ch)) (cactions ch) k ek)

-- ---------------------------------------------------------------------
-- The row invariant
-- ---------------------------------------------------------------------

--@spec [IRET.12.4]
--@spec [LTIM.2.5.1]
||| EVERY ROW TARGETS AN EMITTED KIND: a live fact carrying a row's target
||| id is of a kind some rule of the program emits. With unique ids, that
||| is the fact a cascade retracts for the row.
public export
Ltim_2_5_1__rows_emitted : List Rlow_4_2_1__chain -> Rarc_5_6_4__wm -> Iret_12_4__table -> Type
Ltim_2_5_1__rows_emitted chains0 wm rows =
  (row : Iret_12_4__row) -> Elem row rows -> (f : Lfac_1_7_1__fact) -> Elem f wm -> fid f = rtarget row -> Ltim_2_5_1__emitted chains0 (fkind f)

--@spec [IRET.12.2]
--@spec [LTIM.2.5.1]
||| EVERY ROW'S TARGET IS LIVE: what the cascade's fixpoint leaves, and
||| what a mint relies on so that a fresh id is no row's target.
public export
Ltim_2_5_1__rows_live : Rarc_5_6_4__wm -> Iret_12_4__table -> Type
Ltim_2_5_1__rows_live wm rows = (row : Iret_12_4__row) -> Elem row rows -> rarc_5_6_4__is_live (rtarget row) wm = True

--@spec [LTIM.2.5.1]
--@spec [IRET.12]
||| THE FRAME INVARIANT WITH TRUTH MAINTENANCE, within an action: the
||| plain frame invariant, unique fact ids, every row targeting an emitted
||| kind.
public export
Ltim_2_5_1__tms_inv : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> Iret_12__net_state -> Type
Ltim_2_5_1__tms_inv alphas0 chains0 s =
  ( Ltim_2_5_1__frame_inv alphas0 chains0 (ncore s)
  , Iret_4_4__unique (ewm (ncore s))
  , Ltim_2_5_1__rows_emitted chains0 (ewm (ncore s)) (ndeps s) )

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| BETWEEN ACTIONS: the above, and every row's target live.
public export
Ltim_2_5_1__tms_inv_live : List Iret_6_1__alpha -> List Rlow_4_2_1__chain -> Iret_12__net_state -> Type
Ltim_2_5_1__tms_inv_live alphas0 chains0 s = (Ltim_2_5_1__tms_inv alphas0 chains0 s, Ltim_2_5_1__rows_live (ewm (ncore s)) (ndeps s))

--@derives [IRET.12.4]
--@derives [LTIM.2.5.1]
||| Fewer facts and fewer rows keep the property.
export
ltim_2_5_1__rows_emitted_sub : (chains0 : List Rlow_4_2_1__chain) -> (wm, wm' : Rarc_5_6_4__wm) -> ((g : Lfac_1_7_1__fact) -> Elem g wm' -> Elem g wm) ->
                               (rows, rows' : Iret_12_4__table) -> ((row : Iret_12_4__row) -> Elem row rows' -> Elem row rows) ->
                               Ltim_2_5_1__rows_emitted chains0 wm rows -> Ltim_2_5_1__rows_emitted chains0 wm' rows'
ltim_2_5_1__rows_emitted_sub chains0 wm wm' sub rows rows' rsub re row er f ef eq = re row (rsub row er) f (sub f ef) eq

--@derives [IRET.12.4]
--@derives [LFAC.2.5.3]
--@derives [LTIM.2.5.1]
||| A FRESH FACT IS NO ROW'S TARGET: with every row's target live in `wm`,
||| a fact whose id is not live in `wm`, appended to any part of `wm`,
||| keeps the property.
export
ltim_2_5_1__rows_emitted_append : (chains0 : List Rlow_4_2_1__chain) -> (wm, wm' : Rarc_5_6_4__wm) -> (rows : Iret_12_4__table) ->
                                  Ltim_2_5_1__rows_emitted chains0 wm' rows -> Ltim_2_5_1__rows_live wm rows ->
                                  (new : Lfac_1_7_1__fact) -> rarc_5_6_4__is_live (fid new) wm = False ->
                                  Ltim_2_5_1__rows_emitted chains0 (wm' ++ [new]) rows
ltim_2_5_1__rows_emitted_append chains0 wm wm' rows re rl new fresh row er f ef eq = case lcyc_1_1__elem_append_inv wm' ef of
  Left ef' => re row er f ef' eq
  Right en =>
    let fn = the (f = new) (iret_12__elem_singleton en)
        liveNew = the (rarc_5_6_4__is_live (fid new) wm = True)
                    (replace {p = \j => rarc_5_6_4__is_live j wm = True} (sym (trans (cong fid (sym fn)) eq)) (rl row er))
    in void (lcyc_1_1__bool_not_both _ liveNew fresh)

--@derives [IRET.10.2]
--@derives [IRET.12.4]
--@derives [IRET.4.4]
--@derives [LTIM.2.5.1]
||| A RECORDED ROW targets a live fact of an emitted kind; with unique ids
||| that fact is the only one carrying the id.
export
ltim_2_5_1__rows_emitted_record : (chains0 : List Rlow_4_2_1__chain) -> (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (rows : Iret_12_4__table) ->
                                  Ltim_2_5_1__rows_emitted chains0 wm rows ->
                                  (r : Nat) -> (ids : List Nat) -> (f : Lfac_1_7_1__fact) -> Elem f wm -> Ltim_2_5_1__emitted chains0 (fkind f) ->
                                  Ltim_2_5_1__rows_emitted chains0 wm (rows ++ [MkRow r ids (fid f)])
ltim_2_5_1__rows_emitted_record chains0 wm uq rows re r ids f ef em row er g eg eq = case lcyc_1_1__elem_append_inv rows er of
  Left er' => re row er' g eg eq
  Right en =>
    let rowEq = the (row = MkRow r ids (fid f)) (iret_12__elem_singleton en)
        gf = the (g = f) (uq g f eg ef (trans eq (cong rtarget rowEq)))
    in replace {p = \z => Ltim_2_5_1__emitted chains0 (fkind z)} (sym gf) em

--@derives [IRET.10.2]
||| THE RECORD keeps the property: a withdraw or an explicit emit records
||| nothing; a logical emit of kind `k` by a rule of the program records a
||| row for the fact of kind `k` it found live.
export
iret_10_2__record_rows_emitted : (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (r : Nat) -> (ids : List Nat) -> (bound : List Lfac_1_7_1__fact) ->
                                 (act : Lgra_10_1__action) -> (ch0 : Rlow_4_2_1__chain) -> Elem ch0 chains0 -> Elem act (cactions ch0) ->
                                 (wm : Rarc_5_6_4__wm) -> Iret_4_4__unique wm -> (rows : Iret_12_4__table) -> Ltim_2_5_1__rows_emitted chains0 wm rows ->
                                 Ltim_2_5_1__rows_emitted chains0 wm (iret_10_2__record pg r ids bound act wm rows)
iret_10_2__record_rows_emitted chains0 pg r ids bound (Withdraw i) ch0 ech ea wm uq rows re = re
iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re with (life pg k)
  iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Explicit = re
  iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Relation with (iret_19_1__find_relation k (fst (value bound)) (snd (value bound)) wm) proof fr
    iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Relation | Nothing = re
    iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Relation | (Just f) =
      let (pf, ef) = lcyc_1_1__find_just (\g => (fkind g == k) && ((fkey g == fst (value bound)) && (fpay g == snd (value bound)))) wm fr
          kf = the (fkind f = k) (lcyc_1_1__nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ pf))
      in ltim_2_5_1__rows_emitted_record chains0 wm uq rows re r ids f ef
           (ch0 ** (ech, replace {p = \z => Elem z (ltim_2_5_1__emits_of (cactions ch0))} (sym kf) (ltim_2_5_1__emits_elem (cactions ch0) k value ea)))
  iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Entity with (iret_19_1__find_entity k (fst (value bound)) wm) proof fe
    iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Entity | Nothing = re
    iret_10_2__record_rows_emitted chains0 pg r ids bound (Emit k value) ch0 ech ea wm uq rows re | Entity | (Just f) =
      let (pf, ef) = lcyc_1_1__find_just (\g => (fkind g == k) && (fkey g == fst (value bound))) wm fe
          kf = the (fkind f = k) (lcyc_1_1__nat_eq_true _ _ (lcyc_1_1__and_true_l _ _ pf))
      in ltim_2_5_1__rows_emitted_record chains0 wm uq rows re r ids f ef
           (ch0 ** (ech, replace {p = \z => Elem z (ltim_2_5_1__emits_of (cactions ch0))} (sym kf) (ltim_2_5_1__emits_elem (cactions ch0) k value ea)))

-- ---------------------------------------------------------------------
-- Unique ids through the network's operations
-- ---------------------------------------------------------------------

--@derives [IRET.4.4]
--@derives [IRET.19.1]
export
iret_19_1__insert_unique : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> rarc_5_6_4__is_live (fid f) (ewm eng) = False ->
                           Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (iret_19_1__insert f eng))
iret_19_1__insert_unique f eng fresh uq = iret_4_4__unique_append (ewm eng) uq f fresh

--@derives [IRET.4.4]
--@derives [IRET.19.2]
export
iret_19_2__retract_unique : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (iret_19_2__retract f eng))
iret_19_2__retract_unique f eng uq = iret_4_4__unique_filter (ewm eng) uq (\g => not (lfac_2_5_4__same_fact g f))

--@derives [IRET.4.4]
--@derives [IRET.19.1]
--@derives [LFAC.2.5.3]
||| ASSERT keeps ids unique under any lifecycle: a mint is fresh, and a
||| replace mints against the memory the old fact is still in.
export
iret_19_1__assert_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) -> (eng : Iret_19__engine) ->
                           Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (iret_19_1__assert life avoid k key pay eng))
iret_19_1__assert_unique life avoid k key pay eng uq with (life k)
  iret_19_1__assert_unique life avoid k key pay eng uq | Explicit =
    iret_19_1__insert_unique (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng))) uq
  iret_19_1__assert_unique life avoid k key pay eng uq | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_unique life avoid k key pay eng uq | Relation | (Just old) = uq
    iret_19_1__assert_unique life avoid k key pay eng uq | Relation | Nothing =
      iret_19_1__insert_unique (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng))) uq
  iret_19_1__assert_unique life avoid k key pay eng uq | Entity with (iret_19_1__find_entity k key (ewm eng))
    iret_19_1__assert_unique life avoid k key pay eng uq | Entity | Nothing =
      iret_19_1__insert_unique (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) eng (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng))) uq
    iret_19_1__assert_unique life avoid k key pay eng uq | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_unique life avoid k key pay eng uq | Entity | (Just old) | True = uq
      iret_19_1__assert_unique life avoid k key pay eng uq | Entity | (Just old) | False =
        iret_4_4__unique_replace (ewm eng) uq old (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng)))

--@derives [IRET.4.4]
--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_unique : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (lscp_2_1_1__withdraw f eng))
lscp_2_1_1__withdraw_unique f eng uq with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_unique f eng uq | True = iret_19_2__retract_unique f eng uq
  lscp_2_1_1__withdraw_unique f eng uq | False = uq

--@derives [IRET.4.4]
--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_net_unique : (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) -> (act : Lgra_10_1__action) -> (eng : Iret_19__engine) ->
                                   Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (rarc_5_6_7__do_action_net life bound act eng))
rarc_5_6_7__do_action_net_unique life bound (Emit k value) eng uq =
  iret_19_1__assert_unique life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng uq
rarc_5_6_7__do_action_net_unique life bound (Withdraw i) eng uq with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_net_unique life bound (Withdraw i) eng uq | Nothing = uq
  rarc_5_6_7__do_action_net_unique life bound (Withdraw i) eng uq | (Just f) = lscp_2_1_1__withdraw_unique f eng uq

--@derives [IRET.4.4]
--@derives [IRET.12.2]
export
iret_12_2__retract_ids_net_unique : (ids : List Nat) -> (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) -> Iret_4_4__unique (ewm (iret_12_2__retract_ids_net ids eng))
iret_12_2__retract_ids_net_unique [] eng uq = uq
iret_12_2__retract_ids_net_unique (i :: is) eng uq with (rarc_5_6_4__lookup_fact i (ewm eng))
  iret_12_2__retract_ids_net_unique (i :: is) eng uq | Nothing = iret_12_2__retract_ids_net_unique is eng uq
  iret_12_2__retract_ids_net_unique (i :: is) eng uq | (Just f) = iret_12_2__retract_ids_net_unique is (iret_19_2__retract f eng) (iret_19_2__retract_unique f eng uq)

--@derives [IRET.12.2]
||| Retracting ids only removes facts.
export
iret_12_2__retract_ids_net_sub : (ids : List Nat) -> (eng : Iret_19__engine) -> (g : Lfac_1_7_1__fact) ->
                                 Elem g (ewm (iret_12_2__retract_ids_net ids eng)) -> Elem g (ewm eng)
iret_12_2__retract_ids_net_sub [] eng g e = e
iret_12_2__retract_ids_net_sub (i :: is) eng g e with (rarc_5_6_4__lookup_fact i (ewm eng))
  iret_12_2__retract_ids_net_sub (i :: is) eng g e | Nothing = iret_12_2__retract_ids_net_sub is eng g e
  iret_12_2__retract_ids_net_sub (i :: is) eng g e | (Just f) =
    fst (rarc_5_6_4__remove_exact_elem_inv f (ewm eng) g (iret_12_2__retract_ids_net_sub is (iret_19_2__retract f eng) g e))

-- ---------------------------------------------------------------------
-- The row invariant through the working-memory operations
-- ---------------------------------------------------------------------

--@derives [IRET.19.2]
export
iret_19_2__retract_rows_emitted : (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                  Ltim_2_5_1__rows_emitted chains0 (ewm eng) rows -> Ltim_2_5_1__rows_emitted chains0 (ewm (iret_19_2__retract f eng)) rows
iret_19_2__retract_rows_emitted chains0 f eng rows re =
  ltim_2_5_1__rows_emitted_sub chains0 (ewm eng) (ewm (iret_19_2__retract f eng))
    (\g, e => fst (rarc_5_6_4__remove_exact_elem_inv f (ewm eng) g e)) rows rows (\row, e => e) re

--@derives [IRET.19.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
||| ASSERT keeps the property under any lifecycle, from a state in which
||| every row's target is live: a mint is fresh against that memory, and
||| a replace mints against the memory the old fact is still in.
export
iret_19_1__assert_rows_emitted : (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (avoid : List Nat) -> (k, key, pay : Nat) ->
                                 (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                 Ltim_2_5_1__rows_emitted chains0 (ewm eng) rows -> Ltim_2_5_1__rows_live (ewm eng) rows ->
                                 Ltim_2_5_1__rows_emitted chains0 (ewm (iret_19_1__assert life avoid k key pay eng)) rows
iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl with (life k)
  iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Explicit =
    ltim_2_5_1__rows_emitted_append chains0 (ewm eng) (ewm eng) rows re rl (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng)))
  iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Relation with (iret_19_1__find_relation k key pay (ewm eng))
    iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Relation | (Just old) = re
    iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Relation | Nothing =
      ltim_2_5_1__rows_emitted_append chains0 (ewm eng) (ewm eng) rows re rl (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng)))
  iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Entity with (iret_19_1__find_entity k key (ewm eng))
    iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Entity | Nothing =
      ltim_2_5_1__rows_emitted_append chains0 (ewm eng) (ewm eng) rows re rl (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng)))
    iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Entity | (Just old) with (fpay old == pay)
      iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Entity | (Just old) | True = re
      iret_19_1__assert_rows_emitted chains0 life avoid k key pay eng rows re rl | Entity | (Just old) | False =
        ltim_2_5_1__rows_emitted_append chains0 (ewm eng) (rarc_5_6_4__remove_exact old (ewm eng)) rows
          (iret_19_2__retract_rows_emitted chains0 old eng rows re) rl
          (MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay) (fst (lfac_2_5_3__fresh_id_free avoid (ewm eng)))

--@derives [LSCP.2.1.1]
export
lscp_2_1_1__withdraw_rows_emitted : (chains0 : List Rlow_4_2_1__chain) -> (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                    Ltim_2_5_1__rows_emitted chains0 (ewm eng) rows -> Ltim_2_5_1__rows_emitted chains0 (ewm (lscp_2_1_1__withdraw f eng)) rows
lscp_2_1_1__withdraw_rows_emitted chains0 f eng rows re with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng))
  lscp_2_1_1__withdraw_rows_emitted chains0 f eng rows re | True = iret_19_2__retract_rows_emitted chains0 f eng rows re
  lscp_2_1_1__withdraw_rows_emitted chains0 f eng rows re | False = re

--@derives [RARC.5.6.7]
export
rarc_5_6_7__do_action_net_rows_emitted : (chains0 : List Rlow_4_2_1__chain) -> (life : Nat -> Lscp_1_3__lifecycle) -> (bound : List Lfac_1_7_1__fact) ->
                                         (act : Lgra_10_1__action) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                         Ltim_2_5_1__rows_emitted chains0 (ewm eng) rows -> Ltim_2_5_1__rows_live (ewm eng) rows ->
                                         Ltim_2_5_1__rows_emitted chains0 (ewm (rarc_5_6_7__do_action_net life bound act eng)) rows
rarc_5_6_7__do_action_net_rows_emitted chains0 life bound (Emit k value) eng rows re rl =
  iret_19_1__assert_rows_emitted chains0 life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng rows re rl
rarc_5_6_7__do_action_net_rows_emitted chains0 life bound (Withdraw i) eng rows re rl with (rarc_5_6_5__nth i bound)
  rarc_5_6_7__do_action_net_rows_emitted chains0 life bound (Withdraw i) eng rows re rl | Nothing = re
  rarc_5_6_7__do_action_net_rows_emitted chains0 life bound (Withdraw i) eng rows re rl | (Just f) = lscp_2_1_1__withdraw_rows_emitted chains0 f eng rows re

-- ---------------------------------------------------------------------
-- The cascade keeps the invariant, and skips a framed chain
-- ---------------------------------------------------------------------

--@derives [IRET.12]
||| A state with truth maintenance is its engine and its table.
export
iret_12__net_state_eta : (s : Iret_12__net_state) -> MkTmsNet (ncore s) (ndeps s) = s
iret_12__net_state_eta (MkTmsNet e r) = Refl

--@derives [IRET.12.2]
--@derives [IRET.19.2]
||| RETRACTING IDS keeps the frame invariant: each is a retraction of a live
||| fact.
export
iret_12_2__retract_ids_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (ids : List Nat) -> (eng : Iret_19__engine) ->
                                 Ltim_2_5_1__frame_inv alphas0 chains0 eng -> Ltim_2_5_1__frame_inv alphas0 chains0 (iret_12_2__retract_ids_net ids eng)
iret_12_2__retract_ids_net_inv alphas0 chains0 [] eng inv = inv
iret_12_2__retract_ids_net_inv alphas0 chains0 (i :: is) eng inv with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  iret_12_2__retract_ids_net_inv alphas0 chains0 (i :: is) eng inv | Nothing = iret_12_2__retract_ids_net_inv alphas0 chains0 is eng inv
  iret_12_2__retract_ids_net_inv alphas0 chains0 (i :: is) eng inv | (Just f) =
    iret_12_2__retract_ids_net_inv alphas0 chains0 is (iret_19_2__retract f eng)
      (iret_19_2__retract_inv alphas0 chains0 f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)) inv)

--@derives [IRET.12.2]
--@derives [IRET.19.2]
--@derives [LTIM.2.5.1]
||| RETRACTING IDS SKIPS A CHAIN that reads none of their kinds: every fact
||| retracted is looked up by its id and is of a kind the chain does not
||| read, so dispatch leaves the chain.
export
iret_12_2__retract_ids_net_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (ids : List Nat) -> (eng : Iret_19__engine) ->
                                   Ltim_2_5_1__frame_inv alphas0 chains0 eng ->
                                   (ci : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth ci (nchains (enet eng)) = Just c ->
                                   ((i : Nat) -> Elem i ids -> (f : Lfac_1_7_1__fact) -> Elem f (ewm eng) -> fid f = i ->
                                      rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads alphas0 (cnodes c)) = False) ->
                                   rarc_5_6_5__nth ci (nchains (enet (iret_12_2__retract_ids_net ids eng))) = Just c
iret_12_2__retract_ids_net_frame alphas0 chains0 [] eng inv ci c n nr = n
iret_12_2__retract_ids_net_frame alphas0 chains0 (i :: is) eng inv ci c n nr with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  iret_12_2__retract_ids_net_frame alphas0 chains0 (i :: is) eng inv ci c n nr | Nothing =
    iret_12_2__retract_ids_net_frame alphas0 chains0 is eng inv ci c n (\i', e, f, ef, eq => nr i' (There e) f ef eq)
  iret_12_2__retract_ids_net_frame alphas0 chains0 (i :: is) eng inv ci c n nr | (Just f) =
    let (ef, fi) = rarc_5_6_4__lookup_elem i (ewm eng) f lk
        nr0 = the (rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads alphas0 (cnodes c)) = False) (nr i Here f ef fi)
        nrE = the (rarc_5_6_5__elem (fkind f) (ltim_2_5_1__reads (nalphas (enet eng)) (cnodes c)) = False)
                (replace {p = \z => rarc_5_6_5__elem (fkind f) z = False} (sym (ltim_2_5_1__reads_same alphas0 (nalphas (enet eng)) (fst (snd inv)) (cnodes c))) nr0)
    in iret_12_2__retract_ids_net_frame alphas0 chains0 is (iret_19_2__retract f eng) (iret_19_2__retract_inv alphas0 chains0 f eng ef inv) ci c
         (iret_19_2__retract_frame f eng ci c n nrE)
         (\i', e, g, eg, eq => nr i' (There e) g (fst (rarc_5_6_4__remove_exact_elem_inv f (ewm eng) g eg)) eq)

--@derives [IRET.12.2]
||| The ids a phase retracts are targets of rows of the table it started
||| with.
export
iret_12_2__zeroed_target : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (x : Iret_12_4__row) -> (xs : Iret_12_4__table) ->
                           iret_12_2__ended_net eng rows = x :: xs -> (i : Nat) -> Elem i (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) ->
                           (row ** (Elem row rows, rtarget row = i))
iret_12_2__zeroed_target eng rows x xs en i ei =
  let (eim, _) = lcyc_1_1__elem_filter_inv (\g => iret_12_1__count (iret_12_2__kept_net eng rows) g == 0) (map rtarget (x :: xs)) ei
      (row ** (erow, rt)) = lcyc_1_1__elem_map_inv rtarget (x :: xs) eim
  in (row ** ( fst (lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng))) rows
                      (replace {p = \l => Elem row l} (sym en) erow))
             , rt ))

--@derives [IRET.12.2]
||| The rows a phase keeps are rows it started with.
export
iret_12_2__kept_net_sub : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (row : Iret_12_4__row) -> Elem row (iret_12_2__kept_net eng rows) -> Elem row rows
iret_12_2__kept_net_sub eng rows row e =
  fst (lcyc_1_1__elem_filter_inv (\row => iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng)) rows e)

--@derives [IRET.12.2]
||| ONE PHASE keeps the invariant: it drops rows and retracts live facts.
export
iret_12_2__phase_step_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                Ltim_2_5_1__tms_inv alphas0 chains0 (MkTmsNet eng rows) ->
                                Ltim_2_5_1__tms_inv alphas0 chains0 (iret_12_2__phase_step_net pg (MkTmsNet eng rows))
iret_12_2__phase_step_net_inv alphas0 chains0 pg eng rows (inv, uq, re) with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_inv alphas0 chains0 pg eng rows (inv, uq, re) | [] = (inv, uq, re)
  iret_12_2__phase_step_net_inv alphas0 chains0 pg eng rows (inv, uq, re) | (x :: xs) =
    ( iret_12_2__retract_ids_net_inv alphas0 chains0 (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng inv
    , iret_12_2__retract_ids_net_unique (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng uq
    , ltim_2_5_1__rows_emitted_sub chains0 (ewm eng) (ewm (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng))
        (iret_12_2__retract_ids_net_sub (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng)
        rows (iret_12_2__kept_net eng rows) (iret_12_2__kept_net_sub eng rows) re )

--@derives [IRET.12.2]
--@derives [LTIM.2.5.1]
||| ONE PHASE SKIPS A FRAMED CHAIN: what it retracts are targets of rows,
||| so facts of emitted kinds, which the chain does not read.
export
iret_12_2__phase_step_net_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                  Ltim_2_5_1__tms_inv alphas0 chains0 (MkTmsNet eng rows) ->
                                  (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                  ltim_2_5_1__framed alphas0 chains0 nodes = True -> rarc_5_6_5__nth ci (nchains (enet eng)) = Just (MkChain nodes acts actions) ->
                                  rarc_5_6_5__nth ci (nchains (enet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))))) = Just (MkChain nodes acts actions)
iret_12_2__phase_step_net_frame alphas0 chains0 pg eng rows (inv, uq, re) ci nodes acts actions fr n with (iret_12_2__ended_net eng rows) proof en
  iret_12_2__phase_step_net_frame alphas0 chains0 pg eng rows (inv, uq, re) ci nodes acts actions fr n | [] = n
  iret_12_2__phase_step_net_frame alphas0 chains0 pg eng rows (inv, uq, re) ci nodes acts actions fr n | (x :: xs) =
    iret_12_2__retract_ids_net_frame alphas0 chains0 (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng inv ci (MkChain nodes acts actions) n
      (\i, ei, f, ef, eq =>
         let (row ** (erow, rt)) = iret_12_2__zeroed_target eng rows x xs en i ei
         in ltim_2_5_1__emitted_not_read alphas0 chains0 nodes fr (fkind f) (re row erow f ef (trans eq (sym rt))))

--@derives [IRET.12.2]
export
iret_12_2__phase_n_net_inv : (n : Nat) -> (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) ->
                             Ltim_2_5_1__tms_inv alphas0 chains0 s -> Ltim_2_5_1__tms_inv alphas0 chains0 (iret_12_2__phase_n_net n pg s)
iret_12_2__phase_n_net_inv Z alphas0 chains0 pg s inv = inv
iret_12_2__phase_n_net_inv (S m) alphas0 chains0 pg (MkTmsNet eng rows) inv =
  let inv1 = iret_12_2__phase_step_net_inv alphas0 chains0 pg eng rows inv
      eq = the (iret_12_2__phase_n_net (S m) pg (MkTmsNet eng rows)
                = iret_12_2__phase_n_net m pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
             (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))
                (sym (iret_12__net_state_eta (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
  in replace {p = \x => Ltim_2_5_1__tms_inv alphas0 chains0 x} (sym eq)
       (iret_12_2__phase_n_net_inv m alphas0 chains0 pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))) inv1)

--@derives [IRET.12.2]
--@derives [LTIM.2.5.1]
export
iret_12_2__phase_n_net_frame : (n : Nat) -> (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) ->
                               Ltim_2_5_1__tms_inv alphas0 chains0 s ->
                               (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                               ltim_2_5_1__framed alphas0 chains0 nodes = True -> rarc_5_6_5__nth ci (nchains (enet (ncore s))) = Just (MkChain nodes acts actions) ->
                               rarc_5_6_5__nth ci (nchains (enet (ncore (iret_12_2__phase_n_net n pg s)))) = Just (MkChain nodes acts actions)
iret_12_2__phase_n_net_frame Z alphas0 chains0 pg s inv ci nodes acts actions fr n = n
iret_12_2__phase_n_net_frame (S m) alphas0 chains0 pg (MkTmsNet eng rows) inv ci nodes acts actions fr n =
  let n1 = iret_12_2__phase_step_net_frame alphas0 chains0 pg eng rows inv ci nodes acts actions fr n
      inv1 = iret_12_2__phase_step_net_inv alphas0 chains0 pg eng rows inv
      eq = the (iret_12_2__phase_n_net (S m) pg (MkTmsNet eng rows)
                = iret_12_2__phase_n_net m pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
             (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))
                (sym (iret_12__net_state_eta (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
  in replace {p = \x => rarc_5_6_5__nth ci (nchains (enet (ncore x))) = Just (MkChain nodes acts actions)} (sym eq)
       (iret_12_2__phase_n_net_frame m alphas0 chains0 pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows))))
          inv1 ci nodes acts actions fr n1)

-- ---------------------------------------------------------------------
-- The cascade's fixpoint, on the network
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
||| A phase on the network either ends nothing and is the identity, or
||| keeps strictly fewer rows.
export
iret_12_2__phase_step_net_shape : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
  Either ( iret_12_2__ended_net eng rows = []
         , iret_12_2__phase_step_net pg (MkTmsNet eng rows) = MkTmsNet eng rows )
         (eng' ** ( iret_12_2__phase_step_net pg (MkTmsNet eng rows) = MkTmsNet eng' (iret_12_2__kept_net eng rows)
                  , LT (length (iret_12_2__kept_net eng rows)) (length rows) ))
iret_12_2__phase_step_net_shape pg eng rows with (iret_12_2__ended_net eng rows) proof en
  iret_12_2__phase_step_net_shape pg eng rows | [] = Left (Refl, Refl)
  iret_12_2__phase_step_net_shape pg eng rows | (x :: xs) =
    let (ex, nq) = lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng))) rows
                     (replace {p = \l => Elem x l} (sym en) Here)
    in Right (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng
              ** ( Refl
                 , iret_12_2__filter_drops (\row => iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng)) rows x ex (iret_12__not_true _ nq) ))

--@derives [IRET.12.2]
||| Nothing ending, nothing changes however many phases run.
export
iret_12_2__phase_n_net_stable : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
                                iret_12_2__ended_net eng rows = [] -> iret_12_2__phase_n_net n pg (MkTmsNet eng rows) = MkTmsNet eng rows
iret_12_2__phase_n_net_stable Z pg eng rows en = Refl
iret_12_2__phase_n_net_stable (S n) pg eng rows en =
  trans (iret_12_2__phase_n_net_succ n pg (MkTmsNet eng rows) eng rows (iret_12_2__phase_step_net_nil pg eng rows en))
        (iret_12_2__phase_n_net_stable n pg eng rows en)

--@derives [IRET.12.2]
||| THE FUEL ON THE NETWORK: with at least as many phases as rows, the
||| cascade reaches a phase that ends nothing, since every other phase
||| drops a row. Rete/TmsBridge.idr's `iret_12_2__phase_n_fixed` for the
||| network's phase, which retracts one fact at a time.
export
iret_12_2__phase_n_net_fixed : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> LTE (length rows) n ->
                               iret_12_2__ended_net (ncore (iret_12_2__phase_n_net n pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_n_net n pg (MkTmsNet eng rows))) = []
iret_12_2__phase_n_net_fixed Z pg eng [] lte = Refl
iret_12_2__phase_n_net_fixed Z pg eng (r :: rs) LTEZero impossible
iret_12_2__phase_n_net_fixed (S m) pg eng rows lte = case iret_12_2__phase_step_net_shape pg eng rows of
  Left (en, eq) => replace {p = \x => iret_12_2__ended_net (ncore x) (ndeps x) = []} (sym (iret_12_2__phase_n_net_stable (S m) pg eng rows en)) en
  Right (eng' ** (eq, lt)) =>
    replace {p = \x => iret_12_2__ended_net (ncore x) (ndeps x) = []}
            (sym (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) eng' (iret_12_2__kept_net eng rows) eq))
            (iret_12_2__phase_n_net_fixed m pg eng' (iret_12_2__kept_net eng rows) (fromLteSucc (transitive lt lte)))

--@derives [IRET.12.2]
||| At the fixpoint every row's target is live.
export
iret_12_2__fixed_rows_live : (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> iret_12_2__ended_net eng rows = [] -> Ltim_2_5_1__rows_live (ewm eng) rows
iret_12_2__fixed_rows_live eng rows en row er =
  lcyc_1_1__and_true_r _ _ (lcyc_1_1__not_false_is_true _
    (iret_12__filter_nil_all (\row => not (iret_7_8__activation_live_net (nchains (enet eng)) row && rarc_5_6_4__is_live (rtarget row) (ewm eng))) rows en row er))

--@derives [IRET.12.2]
||| THE CASCADE keeps the invariant and leaves a state between actions:
||| at its fixpoint every row's target is live.
export
iret_12_2__phase_net_inv_live : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) ->
                                Ltim_2_5_1__tms_inv alphas0 chains0 s -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (iret_12_2__phase_net pg s)
iret_12_2__phase_net_inv_live alphas0 chains0 pg (MkTmsNet eng rows) inv =
  ( iret_12_2__phase_n_net_inv (S (length rows)) alphas0 chains0 pg (MkTmsNet eng rows) inv
  , iret_12_2__fixed_rows_live _ _ (iret_12_2__phase_n_net_fixed (S (length rows)) pg eng rows (iret_12__lte_succ_self (length rows))) )

--@derives [IRET.12.2]
--@derives [LTIM.2.5.1]
||| THE CASCADE SKIPS A FRAMED CHAIN.
export
iret_12_2__phase_net_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) ->
                             Ltim_2_5_1__tms_inv alphas0 chains0 s ->
                             (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                             ltim_2_5_1__framed alphas0 chains0 nodes = True -> rarc_5_6_5__nth ci (nchains (enet (ncore s))) = Just (MkChain nodes acts actions) ->
                             rarc_5_6_5__nth ci (nchains (enet (ncore (iret_12_2__phase_net pg s)))) = Just (MkChain nodes acts actions)
iret_12_2__phase_net_frame alphas0 chains0 pg s inv ci nodes acts actions fr n =
  iret_12_2__phase_n_net_frame (S (length (ndeps s))) alphas0 chains0 pg s inv ci nodes acts actions fr n

-- ---------------------------------------------------------------------
-- One action, the RHS, on the clocked network
-- ---------------------------------------------------------------------

--@derives [IRET.19.3]
||| A clocked network is its engine, its deadlines and its clock.
export
iret_19_3__clocked_net_eta : (cs : Iret_19_3__clocked_net) -> MkClockedNet (nengine cs) (ndeadlines cs) (nclock cs) = cs
iret_19_3__clocked_net_eta (MkClockedNet s d c) = Refl

--@derives [RARC.5.6.7]
--@derives [IRET.10.2]
--@derives [LTIM.2.5.1]
||| ONE ACTION WITH TRUTH MAINTENANCE under the frame, from a state between
||| actions: the core action leaves the framed chain and keeps the frame
||| invariant (Rete/NetworkFrame.idr), unique ids and the row property; the
||| record targets an emitted kind of the firing rule; the cascade leaves
||| the framed chain and ends between actions again.
export
rarc_5_6_7__do_action_tms_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) ->
                                  (r : Nat) -> (a : Iret_8_1__act) -> (ch0 : Rlow_4_2_1__chain) -> Elem ch0 chains0 ->
                                  ((jj : Nat) -> (f : Lfac_1_7_1__fact) -> rarc_5_6_5__nth jj (atuple a) = Just f -> rarc_5_6_5__nth jj (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) = Just (fkind f)) ->
                                  (act : Lgra_10_1__action) -> Elem act (cactions ch0) ->
                                  (s : Iret_12__net_state) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 s ->
                                  (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                  ltim_2_5_1__framed alphas0 chains0 nodes = True -> rarc_5_6_5__nth ci (nchains (enet (ncore s))) = Just (MkChain nodes acts actions) ->
                                  ( Ltim_2_5_1__tms_inv_live alphas0 chains0 (rarc_5_6_7__do_action_tms_net pg r a act s)
                                  , rarc_5_6_5__nth ci (nchains (enet (ncore (rarc_5_6_7__do_action_tms_net pg r a act s)))) = Just (MkChain nodes acts actions) )
rarc_5_6_7__do_action_tms_frame alphas0 chains0 pg r a ch0 ech bk act ea (MkTmsNet eng rows) ((inv, uq, re), rl) ci nodes acts actions fr n =
  let nw = the ((k : Nat) -> Elem k (ltim_2_5_1__writes alphas0 ch0) -> rarc_5_6_5__elem k (ltim_2_5_1__reads alphas0 nodes) = False)
             (\k, ek => ltim_2_5_1__framed_rule alphas0 chains0 nodes ch0 fr ech k ek)
      (inv1, n1) = rarc_5_6_7__do_action_frame alphas0 chains0 (life pg) (atuple a) ch0 bk act ea eng inv ci (MkChain nodes acts actions) n nw
      uq1 = rarc_5_6_7__do_action_net_unique (life pg) (atuple a) act eng uq
      re1 = rarc_5_6_7__do_action_net_rows_emitted chains0 (life pg) (atuple a) act eng rows re rl
      re2 = iret_10_2__record_rows_emitted chains0 pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act ch0 ech ea
              (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) uq1 rows re1
      unf = the (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows)
                 = iret_12_2__phase_net pg (MkTmsNet (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)
                                                     (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) rows)))
              (trans (rarc_5_6_7__do_action_tms_net_unfold pg r a act eng rows
                        (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) (enet (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng))
                        (sym (iret_19__engine_eta (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng))))
                     (cong (\e => iret_12_2__phase_net pg (MkTmsNet e (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) rows)))
                           (iret_19__engine_eta (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng))))
      invL = iret_12_2__phase_net_inv_live alphas0 chains0 pg
               (MkTmsNet (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)
                         (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) rows))
               (inv1, uq1, re2)
      n2 = iret_12_2__phase_net_frame alphas0 chains0 pg
             (MkTmsNet (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)
                       (iret_10_2__record pg r (iret_11_3__fact_ids (atuple a)) (atuple a) act (ewm (rarc_5_6_7__do_action_net (life pg) (atuple a) act eng)) rows))
             (inv1, uq1, re2) ci nodes acts actions fr n1
  in ( replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 x} (sym unf) invL
     , replace {p = \x => rarc_5_6_5__nth ci (nchains (enet (ncore x))) = Just (MkChain nodes acts actions)} (sym unf) n2 )

--@derives [RARC.5.6.7]
--@derives [LTIM.2.5.1]
||| THE RHS on the clocked network leaves a framed chain and keeps the
||| invariant, action by action; the deadline table rides beside.
export
rarc_5_6_7__do_actions_ttl_frame : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                   (r : Nat) -> (a : Iret_8_1__act) -> (ch0 : Rlow_4_2_1__chain) -> Elem ch0 chains0 ->
                                   ((jj : Nat) -> (f : Lfac_1_7_1__fact) -> rarc_5_6_5__nth jj (atuple a) = Just f -> rarc_5_6_5__nth jj (rlow_5_1__pos_kinds alphas0 (cnodes ch0)) = Just (fkind f)) ->
                                   (as : List Lgra_10_1__action) -> ((act : Lgra_10_1__action) -> Elem act as -> Elem act (cactions ch0)) ->
                                   (cs : Iret_19_3__clocked_net) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) ->
                                   (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                   ltim_2_5_1__framed alphas0 chains0 nodes = True -> rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs)))) = Just (MkChain nodes acts actions) ->
                                   ( Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_7__do_actions_ttl_net pg ttl r a as cs))
                                   , rarc_5_6_5__nth ci (nchains (enet (ncore (nengine (rarc_5_6_7__do_actions_ttl_net pg ttl r a as cs))))) = Just (MkChain nodes acts actions) )
rarc_5_6_7__do_actions_ttl_frame alphas0 chains0 pg ttl r a ch0 ech bk [] sub cs inv ci nodes acts actions fr n = (inv, n)
rarc_5_6_7__do_actions_ttl_frame alphas0 chains0 pg ttl r a ch0 ech bk (act :: as) sub (MkClockedNet (MkTmsNet eng rows) dl c) inv ci nodes acts actions fr n =
  let (inv1, n1) = rarc_5_6_7__do_action_tms_frame alphas0 chains0 pg r a ch0 ech bk act (sub act Here) (MkTmsNet eng rows) inv ci nodes acts actions fr n
      eq = the (rarc_5_6_7__do_actions_ttl_net pg ttl r a (act :: as) (MkClockedNet (MkTmsNet eng rows) dl c)
                = rarc_5_6_7__do_actions_ttl_net pg ttl r a as
                    (MkClockedNet (MkTmsNet (ncore (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))) (ndeps (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))))
                                  (iret_4_3__record_action_net ttl c a act (ewm eng) dl) c))
             (rarc_5_6_7__actions_ttl_net_succ pg ttl r a act as (MkClockedNet (MkTmsNet eng rows) dl c)
                (MkTmsNet (ncore (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))) (ndeps (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))))
                (iret_4_3__record_action_net ttl c a act (ewm eng) dl) c
                (cong (\s => MkClockedNet s (iret_4_3__record_action_net ttl c a act (ewm eng) dl) c) (sym (iret_12__net_state_eta (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))))))
      (inv2, n2) = rarc_5_6_7__do_actions_ttl_frame alphas0 chains0 pg ttl r a ch0 ech bk as (\a', e => sub a' (There e))
                     (MkClockedNet (MkTmsNet (ncore (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))) (ndeps (rarc_5_6_7__do_action_tms_net pg r a act (MkTmsNet eng rows))))
                                   (iret_4_3__record_action_net ttl c a act (ewm eng) dl) c)
                     inv1 ci nodes acts actions fr n1
  in ( replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine x)} (sym eq) inv2
     , replace {p = \x => rarc_5_6_5__nth ci (nchains (enet (ncore (nengine x)))) = Just (MkChain nodes acts actions)} (sym eq) n2 )

-- ---------------------------------------------------------------------
-- The clocked run, traced
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| One firing on the clocked network, naming the ordinal that fired: the
||| clocked network's form of Rete/NetworkFrame.idr's `iret_11_4__fire_net`.
public export
iret_11_4__fire_ttl_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_19_3__clocked_net -> Maybe (Nat, Iret_19_3__clocked_net)
iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just ch => case rarc_5_6_5__nth j (cacts ch) of
      Nothing => Nothing
      Just a  => Just (r, rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))

--@derives [IRET.11.4]
||| The named firing is the firing.
export
iret_11_4__fire_ttl_net_step : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cs : Iret_19_3__clocked_net) ->
                               map snd (iret_11_4__fire_ttl_net pg ttl cs) = iret_11_4__step_ttl_net pg ttl cs
iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) with (iret_11_1__select (nchains (enet eng)))
  iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | Nothing = Refl
  iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | Nothing = Refl
    iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) with (rarc_5_6_5__nth j (cacts ch))
      iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) | Nothing = Refl
      iret_11_4__fire_ttl_net_step pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) | (Just (r, j)) | (Just ch) | (Just a) = Refl

--@derives [IRET.11.4]
||| A selection that resolves fires.
export
iret_11_4__fire_ttl_net_fires : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                                iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c)
                                  = Just (r, rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))
iret_11_4__fire_ttl_net_fires pg ttl eng rows dl c r j ch a s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [IRET.11.4]
||| A firing with nothing to fire selected nothing.
export
iret_11_4__fire_ttl_net_nothing_select : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                                         iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = Nothing ->
                                         iret_11_1__select (nchains (enet eng)) = Nothing
iret_11_4__fire_ttl_net_nothing_select pg ttl eng rows dl c fn = case iret_11_1__select_cases (nchains (enet eng)) of
  Left z => z
  Right (r ** j ** sel) =>
    let (ch ** a ** (nt, nj, nf)) = iret_11_1__select_just (nchains (enet eng)) r j sel
    in absurd (trans (sym (iret_11_4__fire_ttl_net_fires pg ttl eng rows dl c r j ch a sel nt nj)) fn)

--@derives [IRET.11.4]
||| What a named firing is: the selection, the chain and activation
||| selected, and the network after the mark and the RHS.
export
iret_11_4__fire_ttl_net_just : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) ->
                               (r : Nat) -> (cs' : Iret_19_3__clocked_net) ->
                               iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) = Just (r, cs') ->
                               (j ** ch ** a ** ( iret_11_1__select (nchains (enet eng)) = Just (r, j)
                                                , rarc_5_6_5__nth r (nchains (enet eng)) = Just ch
                                                , rarc_5_6_5__nth j (cacts ch) = Just a
                                                , cs' = rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) ))
iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq with (iret_11_1__select (nchains (enet eng))) proof sel
  iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | Nothing = absurd eq
  iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | (Just (r0, j)) with (rarc_5_6_5__nth r0 (nchains (enet eng))) proof nr
    iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | (Just (r0, j)) | Nothing = absurd eq
    iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | (Just (r0, j)) | (Just ch) with (rarc_5_6_5__nth j (cacts ch)) proof nj
      iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | (Just (r0, j)) | (Just ch) | Nothing = absurd eq
      iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' eq | (Just (r0, j)) | (Just ch) | (Just a) =
        let pe = the ((r0, rarc_5_6_7__do_actions_ttl_net pg ttl r0 a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r0 j eng) rows) dl c)) = (r, cs')) (iret_11_4__just_inj eq)
            re = the (r0 = r) (cong fst pe)
        in (j ** ch ** a ** ( cong (\z => Just (z, j)) re
                            , replace {p = \z => rarc_5_6_5__nth z (nchains (enet eng)) = Just ch} re nr
                            , nj
                            , trans (sym (cong snd pe))
                                    (cong (\z => rarc_5_6_7__do_actions_ttl_net pg ttl z a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net z j eng) rows) dl c)) re) ))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The clocked run, traced: the ordinals that fired, in order, with the
||| network and the halt.
public export
iret_11_4__run_ttl_net_traced : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_19_3__clocked_net -> (Iret_19_3__clocked_net, Iret_11_4__halt, List Nat)
iret_11_4__run_ttl_net_traced pg ttl Z cs = (cs, FuelOut, [])
iret_11_4__run_ttl_net_traced pg ttl (S fuel) cs = case iret_11_4__fire_ttl_net pg ttl cs of
  Nothing => (cs, Quiescent, [])
  Just (r, cs') => let (t, h, tr) = iret_11_4__run_ttl_net_traced pg ttl fuel cs' in (t, h, r :: tr)

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACED CLOCKED RUN IS THE ONE TRACED FOLD at its named firing
||| (Rete/RunFold.idr's `iret_11_4__trace_by`), by induction on the fuel.
export
iret_11_4__run_ttl_net_traced_by : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (cs : Iret_19_3__clocked_net) ->
                                   iret_11_4__run_ttl_net_traced pg ttl fuel cs = iret_11_4__trace_by (iret_11_4__fire_ttl_net pg ttl) fuel cs
iret_11_4__run_ttl_net_traced_by pg ttl Z cs = Refl
iret_11_4__run_ttl_net_traced_by pg ttl (S fuel) cs with (iret_11_4__fire_ttl_net pg ttl cs)
  iret_11_4__run_ttl_net_traced_by pg ttl (S fuel) cs | Nothing = Refl
  iret_11_4__run_ttl_net_traced_by pg ttl (S fuel) cs | (Just (r, cs')) with (iret_11_4__trace_by (iret_11_4__fire_ttl_net pg ttl) fuel cs') proof rr
    iret_11_4__run_ttl_net_traced_by pg ttl (S fuel) cs | (Just (r, cs')) | (t, h, tr) = rewrite trans (iret_11_4__run_ttl_net_traced_by pg ttl fuel cs') rr in Refl

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACE IS THE RUN'S: the same network, the same halt, as many
||| firings as the run counted. RunFold's `iret_11_4__trace_by_core` at the
||| named firing, through the two bridges.
export
iret_11_4__run_ttl_net_traced_core : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (cs : Iret_19_3__clocked_net) ->
                                     (t ** h ** tr ** ( iret_11_4__run_ttl_net_traced pg ttl fuel cs = (t, h, tr)
                                                      , iret_11_4__run_ttl_net pg ttl fuel cs = (t, h, length tr) ))
iret_11_4__run_ttl_net_traced_core pg ttl fuel cs =
  let (t ** (h ** (tr ** (tE, rE)))) = iret_11_4__trace_by_core (iret_11_4__fire_ttl_net pg ttl) (iret_11_4__step_ttl_net pg ttl) (iret_11_4__fire_ttl_net_step pg ttl) fuel cs
  in (t ** h ** tr ** ( trans (iret_11_4__run_ttl_net_traced_by pg ttl fuel cs) tE
                      , trans (iret_11_4__run_ttl_net_by pg ttl fuel cs) rE ))

-- ---------------------------------------------------------------------
-- One firing and the run under the frame
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [LTIM.2.5.1]
--@derives [IDAT.6.2.2]
||| ONE FIRING UNDER THE FRAME on the clocked network: the invariant is kept,
||| and the framed chain is as it was unless it is the rule that fired, when
||| exactly the activation selected, unfired before, is marked. The cascade
||| of every action is inside.
export
ltim_2_5_1__step_frame_ttl : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                             (cs : Iret_19_3__clocked_net) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) ->
                             (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                             ltim_2_5_1__framed alphas0 chains0 nodes = True ->
                             rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs)))) = Just (MkChain nodes acts actions) ->
                             (r : Nat) -> (cs' : Iret_19_3__clocked_net) -> iret_11_4__fire_ttl_net pg ttl cs = Just (r, cs') ->
                             ( Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs')
                             , Either ( (r == ci) = False, rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs')))) = Just (MkChain nodes acts actions) )
                                      ( (r == ci) = True, (j ** a ** ( rarc_5_6_5__nth j acts = Just a, afired a = False
                                                                    , rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs')))) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions) )) ) )
ltim_2_5_1__step_frame_ttl alphas0 chains0 pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) ((inv, uq, re), rl) ci nodes acts actions fr n r cs' fe =
  let (j ** ch ** a ** (sel, nr, nj, eq)) = iret_11_4__fire_ttl_net_just pg ttl eng rows dl c r cs' fe
      (ch0 ** n0) = lcyc_1_1__nth_length r chains0 (nchains (enet eng)) (fst (snd (snd inv))) nr
      (_, acEq) = snd (snd (snd inv)) r ch0 ch n0 nr
      sub = the ((act : Lgra_10_1__action) -> Elem act (cactions ch) -> Elem act (cactions ch0))
              (\act, e => replace {p = \z => Elem act z} acEq e)
      bk = rlow_5_1__bound_kinds alphas0 chains0 eng inv r ch0 ch n0 nr a (lcyc_1_1__nth_elem j (cacts ch) nj)
      ech = lcyc_1_1__nth_elem r chains0 n0
      invM = the (Ltim_2_5_1__tms_inv_live alphas0 chains0 (MkTmsNet (idat_6_2_2__mark_net r j eng) rows))
               (((idat_6_2_2__mark_net_inv alphas0 chains0 r j eng inv, uq, re), rl))
  in case decEq r ci of
       No ne =>
         let n1 = the (rarc_5_6_5__nth ci (nchains (enet (idat_6_2_2__mark_net r j eng))) = Just (MkChain nodes acts actions))
                    (trans (lcyc_1_1__nth_set_at_neq r ci ne (idat_6_2_2__mark_chain j) (nchains (enet eng))) n)
             (inv2, n2) = rarc_5_6_7__do_actions_ttl_frame alphas0 chains0 pg ttl r a ch0 ech bk (cactions ch) sub
                            (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) invM ci nodes acts actions fr n1
         in ( replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine x)} (sym eq) inv2
            , Left (lcyc_1_1__nat_eq_false r ci ne, replace {p = \x => rarc_5_6_5__nth ci (nchains (enet (ncore (nengine x)))) = Just (MkChain nodes acts actions)} (sym eq) n2) )
       Yes e =>
         let nri = the (rarc_5_6_5__nth ci (nchains (enet eng)) = Just ch) (replace {p = \z => rarc_5_6_5__nth z (nchains (enet eng)) = Just ch} e nr)
             chEq = the (ch = MkChain nodes acts actions) (iret_11_4__just_inj (trans (sym nri) n))
             (ch' ** a' ** (nr', nj', nf')) = iret_11_1__select_just (nchains (enet eng)) r j sel
             chEq' = the (ch' = ch) (iret_11_4__just_inj (trans (sym nr') nr))
             nj'' = the (rarc_5_6_5__nth j (cacts ch) = Just a') (replace {p = \z => rarc_5_6_5__nth j (cacts z) = Just a'} chEq' nj')
             aEq = the (a' = a) (iret_11_4__just_inj (trans (sym nj'') nj))
             nja = the (rarc_5_6_5__nth j acts = Just a) (replace {p = \z => rarc_5_6_5__nth j (cacts z) = Just a} chEq nj)
             nfa = the (afired a = False) (replace {p = \z => afired z = False} aEq nf')
             n1 = the (rarc_5_6_5__nth ci (nchains (enet (idat_6_2_2__mark_net r j eng))) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions))
                    (trans (replace {p = \z => rarc_5_6_5__nth z (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))) = map (idat_6_2_2__mark_chain j) (rarc_5_6_5__nth z (nchains (enet eng)))} e
                              (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_chain j) (nchains (enet eng))))
                           (cong (map (idat_6_2_2__mark_chain j)) n))
             (inv2, n2) = rarc_5_6_7__do_actions_ttl_frame alphas0 chains0 pg ttl r a ch0 ech bk (cactions ch) sub
                            (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) invM ci nodes (idat_6_2_2__mark_acts j acts) actions fr n1
         in ( replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine x)} (sym eq) inv2
            , Right ( replace {p = \z => (z == ci) = True} (sym e) (lcyc_1_1__nat_eq_refl ci)
                    , (j ** a ** (nja, nfa, replace {p = \x => rarc_5_6_5__nth ci (nchains (enet (ncore (nengine x)))) = Just (MkChain nodes (idat_6_2_2__mark_acts j acts) actions)} (sym eq) n2)) ) )

--@derives [IRET.11.4]
--@derives [IRET.11.5]
--@derives [LTIM.2.5.1]
--@derives [LDET.5.3]
||| THE RUN UNDER THE FRAME on the clocked network: over any fuel, from any
||| state between actions with the invariant, a framed chain's tuples never
||| change, its firings in the trace are exactly its activations that went
||| from unfired to fired, and if the run halts `Quiescent` every one of
||| them fired. Whatever the other rules do and whatever their endings
||| cascade, however the run halts.
export
ltim_2_5_1__run_frame_ttl : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) ->
                            (cs : Iret_19_3__clocked_net) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) ->
                            (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                            ltim_2_5_1__framed alphas0 chains0 nodes = True ->
                            rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs)))) = Just (MkChain nodes acts actions) ->
                            (cs' ** h ** tr ** acts' ** ( iret_11_4__run_ttl_net_traced pg ttl fuel cs = (cs', h, tr)
                                                        , Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs')
                                                        , rarc_5_6_5__nth ci (nchains (enet (ncore (nengine cs')))) = Just (MkChain nodes acts' actions)
                                                        , iret_8_1__tuples acts' = iret_8_1__tuples acts
                                                        , iret_11_4__unfired acts' + ltim_2_5_1__count ci tr = iret_11_4__unfired acts
                                                        , h = Quiescent -> iret_11_4__unfired acts' = 0 ))
ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl Z cs inv ci nodes acts actions fr n =
  (cs ** FuelOut ** [] ** acts ** (Refl, inv, n, Refl, plusZeroRightNeutral _, \q => absurd q))
ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl (S fuel) (MkClockedNet (MkTmsNet eng rows) dl c) inv ci nodes acts actions fr n with (iret_11_4__fire_ttl_net pg ttl (MkClockedNet (MkTmsNet eng rows) dl c)) proof fe
  ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl (S fuel) (MkClockedNet (MkTmsNet eng rows) dl c) inv ci nodes acts actions fr n | Nothing =
    let z = iret_11_1__unfired_count_zero_at (nchains (enet eng))
              (iret_11_1__select_nothing (nchains (enet eng)) (iret_11_4__fire_ttl_net_nothing_select pg ttl eng rows dl c fe)) ci (MkChain nodes acts actions) n
    in (MkClockedNet (MkTmsNet eng rows) dl c ** Quiescent ** [] ** acts ** (Refl, inv, n, Refl, plusZeroRightNeutral _, \_ => z))
  ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl (S fuel) (MkClockedNet (MkTmsNet eng rows) dl c) inv ci nodes acts actions fr n | (Just (r, cs1)) =
    case ltim_2_5_1__step_frame_ttl alphas0 chains0 pg ttl (MkClockedNet (MkTmsNet eng rows) dl c) inv ci nodes acts actions fr n r cs1 fe of
      (inv1, Left (rneq, n1)) =>
        let (cs' ** h ** tr ** acts' ** (rt, inv', n', tu, cnt, qz)) = ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl fuel cs1 inv1 ci nodes acts actions fr n1
        in (cs' ** h ** (r :: tr) ** acts' **
             ( rewrite rt in Refl
             , inv', n', tu
             , replace {p = \z => iret_11_4__unfired acts' + z = iret_11_4__unfired acts} (sym (ltim_2_5_1__count_miss ci r tr rneq)) cnt
             , qz ))
      (inv1, Right (req, (j ** a ** (nj, nf, n1)))) =>
        let (cs' ** h ** tr ** acts' ** (rt, inv', n', tu, cnt, qz)) = ltim_2_5_1__run_frame_ttl alphas0 chains0 pg ttl fuel cs1 inv1 ci nodes (idat_6_2_2__mark_acts j acts) actions fr n1
            mc = the (S (iret_11_4__unfired (idat_6_2_2__mark_acts j acts)) = iret_11_4__unfired acts) (idat_6_2_2__mark_acts_count j acts a nj nf)
        in (cs' ** h ** (r :: tr) ** acts' **
             ( rewrite rt in Refl
             , inv', n'
             , trans tu (idat_6_2_2__mark_tuples j acts)
             , trans (cong (iret_11_4__unfired acts' +) (ltim_2_5_1__count_hit ci r tr req))
                     (trans (sym (plusSuccRightSucc (iret_11_4__unfired acts') (ltim_2_5_1__count ci tr)))
                            (trans (cong S cnt) mc))
             , qz ))

-- ---------------------------------------------------------------------
-- The invariant through a prepare without a re-time
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
--@derives [IRET.19.3]
||| A phase keeps every activation unfired when all were: it only retracts.
export
iret_12_2__retract_ids_net_unfired : (ids : List Nat) -> (eng : Iret_19__engine) -> Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                                     Iret_11_3__unfired_all (nchains (enet (iret_12_2__retract_ids_net ids eng)))
iret_12_2__retract_ids_net_unfired [] eng v u = u
iret_12_2__retract_ids_net_unfired (i :: is) eng v u with (rarc_5_6_4__lookup_fact i (ewm eng)) proof lk
  iret_12_2__retract_ids_net_unfired (i :: is) eng v u | Nothing = iret_12_2__retract_ids_net_unfired is eng v u
  iret_12_2__retract_ids_net_unfired (i :: is) eng v u | (Just f) =
    let ef = fst (rarc_5_6_4__lookup_elem i (ewm eng) f lk)
    in iret_12_2__retract_ids_net_unfired is (iret_19_2__retract f eng) (iret_19_2__retract_view f eng ef v) (iret_11_3__retract_unfired f eng ef v u)

--@derives [IRET.12.2]
export
iret_12_2__phase_step_net_unfired : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> Iret_19__view eng -> Iret_11_3__unfired_all (nchains (enet eng)) ->
                                    Iret_11_3__unfired_all (nchains (enet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
iret_12_2__phase_step_net_unfired pg eng rows v u with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_unfired pg eng rows v u | [] = u
  iret_12_2__phase_step_net_unfired pg eng rows v u | (x :: xs) = iret_12_2__retract_ids_net_unfired (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng v u

--@derives [IRET.12.2]
export
iret_12_2__phase_n_net_unfired : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> Iret_19__view (ncore s) -> Iret_11_3__unfired_all (nchains (enet (ncore s))) ->
                                 Iret_11_3__unfired_all (nchains (enet (ncore (iret_12_2__phase_n_net n pg s))))
iret_12_2__phase_n_net_unfired Z pg s v u = u
iret_12_2__phase_n_net_unfired (S m) pg (MkTmsNet eng rows) v u =
  let v1 = iret_12_2__phase_step_net_view pg eng rows v
      u1 = iret_12_2__phase_step_net_unfired pg eng rows v u
      eq = the (iret_12_2__phase_n_net (S m) pg (MkTmsNet eng rows)
                = iret_12_2__phase_n_net m pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
             (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))
                (sym (iret_12__net_state_eta (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))))
  in replace {p = \x => Iret_11_3__unfired_all (nchains (enet (ncore x)))} (sym eq)
       (iret_12_2__phase_n_net_unfired m pg (MkTmsNet (ncore (iret_12_2__phase_step_net pg (MkTmsNet eng rows))) (ndeps (iret_12_2__phase_step_net pg (MkTmsNet eng rows)))) v1 u1)

--@derives [IRET.12.2]
export
iret_12_2__phase_net_unfired : (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> Iret_19__view (ncore s) -> Iret_11_3__unfired_all (nchains (enet (ncore s))) ->
                               Iret_11_3__unfired_all (nchains (enet (ncore (iret_12_2__phase_net pg s))))
iret_12_2__phase_net_unfired pg s v u = iret_12_2__phase_n_net_unfired (S (length (ndeps s))) pg s v u

--@derives [RARC.5.6.3]
--@derives [IRET.19.3]
||| THE SWEEP keeps the invariant: retractions of live facts, then the
||| cascade.
export
rarc_5_6_3__sweep_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (cs : Iret_19_3__clocked_net) ->
                            Ltim_2_5_1__tms_inv alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_3__sweep_net pg cs))
rarc_5_6_3__sweep_net_inv alphas0 chains0 pg (MkClockedNet (MkTmsNet eng rows) dl c) (inv, uq, re) =
  iret_12_2__phase_net_inv_live alphas0 chains0 pg (MkTmsNet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng) rows)
    ( iret_12_2__retract_ids_net_inv alphas0 chains0 (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng inv
    , iret_12_2__retract_ids_net_unique (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng uq
    , ltim_2_5_1__rows_emitted_sub chains0 (ewm eng) (ewm (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng))
        (iret_12_2__retract_ids_net_sub (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng) rows rows (\row, e => e) re )

--@derives [RARC.5.6.3]
export
rarc_5_6_3__sweep_net_unfired : (pg : Lcyc_3_2_1__program) -> (cs : Iret_19_3__clocked_net) -> Iret_19__view (ncore (nengine cs)) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_3__sweep_net pg cs)))))
rarc_5_6_3__sweep_net_unfired pg (MkClockedNet (MkTmsNet eng rows) dl c) v u =
  iret_12_2__phase_net_unfired pg (MkTmsNet (iret_12_2__retract_ids_net (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng) rows)
    (iret_12_2__retract_ids_net_view (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng v)
    (iret_12_2__retract_ids_net_unfired (ldtl_6_1__order dl (iret_19_3__expired c dl)) eng v u)

--@derives [RARC.5.6.4]
--@derives [IRET.19.1]
--@derives [IRET.19.2]
||| A DATA EVENT keeps the invariant: an assert mints against a state in
||| which every row's target is live, a retraction retracts a live fact,
||| and the cascade follows either.
export
rarc_5_6_4__apply_tms_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ev : Rarc_5_6_1__event) -> (s : Iret_12__net_state) ->
                                Ltim_2_5_1__tms_inv_live alphas0 chains0 s -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (rarc_5_6_4__apply_tms_net pg ev s)
rarc_5_6_4__apply_tms_net_inv alphas0 chains0 pg (Assert k key pay) (MkTmsNet eng rows) ((inv, uq, re), rl) =
  case iret_12__maybe_split (iret_19_1__assert_fact (life pg k) [] k key pay (ewm eng)) of
    Left an => replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 x} (sym (rarc_5_6_4__apply_tms_net_assert_nothing pg k key pay eng rows an)) ((inv, uq, re), rl)
    Right (w ** aj) =>
      replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 x} (sym (rarc_5_6_4__apply_tms_net_assert_just pg k key pay eng rows w aj))
        (iret_12_2__phase_net_inv_live alphas0 chains0 pg (MkTmsNet (iret_19_1__assert (life pg) [] k key pay eng) rows)
           ( iret_19_1__assert_inv alphas0 chains0 (life pg) [] k key pay eng inv
           , iret_19_1__assert_unique (life pg) [] k key pay eng uq
           , iret_19_1__assert_rows_emitted chains0 (life pg) [] k key pay eng rows re rl ))
rarc_5_6_4__apply_tms_net_inv alphas0 chains0 pg (Retract i) (MkTmsNet eng rows) ((inv, uq, re), rl) =
  case iret_12__maybe_split (rarc_5_6_4__lookup_fact i (ewm eng)) of
    Left ln => replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 x} (sym (rarc_5_6_4__apply_tms_net_retract_nothing pg i eng rows ln)) ((inv, uq, re), rl)
    Right (f ** lj) =>
      replace {p = \x => Ltim_2_5_1__tms_inv_live alphas0 chains0 x} (sym (rarc_5_6_4__apply_tms_net_retract_just pg i eng rows f lj))
        (iret_12_2__phase_net_inv_live alphas0 chains0 pg (MkTmsNet (iret_19_2__retract f eng) rows)
           ( iret_19_2__retract_inv alphas0 chains0 f eng (fst (rarc_5_6_4__lookup_elem i (ewm eng) f lj)) inv
           , iret_19_2__retract_unique f eng uq
           , iret_19_2__retract_rows_emitted chains0 f eng rows re ))

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_tms_net_unfired : (pg : Lcyc_3_2_1__program) -> (ev : Rarc_5_6_1__event) -> (s : Iret_12__net_state) ->
                                    Iret_19__view (ncore s) -> Iret_11_3__unfired_all (nchains (enet (ncore s))) ->
                                    Iret_11_3__unfired_all (nchains (enet (ncore (rarc_5_6_4__apply_tms_net pg ev s))))
rarc_5_6_4__apply_tms_net_unfired pg (Assert k key pay) (MkTmsNet eng rows) v u =
  case iret_12__maybe_split (iret_19_1__assert_fact (life pg k) [] k key pay (ewm eng)) of
    Left an => replace {p = \x => Iret_11_3__unfired_all (nchains (enet (ncore x)))} (sym (rarc_5_6_4__apply_tms_net_assert_nothing pg k key pay eng rows an)) u
    Right (w ** aj) =>
      replace {p = \x => Iret_11_3__unfired_all (nchains (enet (ncore x)))} (sym (rarc_5_6_4__apply_tms_net_assert_just pg k key pay eng rows w aj))
        (iret_12_2__phase_net_unfired pg (MkTmsNet (iret_19_1__assert (life pg) [] k key pay eng) rows)
           (iret_19_1__assert_view (life pg) [] k key pay eng v) (iret_11_3__assert_unfired (life pg) [] k key pay eng v u))
rarc_5_6_4__apply_tms_net_unfired pg (Retract i) (MkTmsNet eng rows) v u =
  case iret_12__maybe_split (rarc_5_6_4__lookup_fact i (ewm eng)) of
    Left ln => replace {p = \x => Iret_11_3__unfired_all (nchains (enet (ncore x)))} (sym (rarc_5_6_4__apply_tms_net_retract_nothing pg i eng rows ln)) u
    Right (f ** lj) =>
      let ef = fst (rarc_5_6_4__lookup_elem i (ewm eng) f lj)
      in replace {p = \x => Iret_11_3__unfired_all (nchains (enet (ncore x)))} (sym (rarc_5_6_4__apply_tms_net_retract_just pg i eng rows f lj))
           (iret_12_2__phase_net_unfired pg (MkTmsNet (iret_19_2__retract f eng) rows) (iret_19_2__retract_view f eng ef v) (iret_11_3__retract_unfired f eng ef v u))

--@derives [RARC.5.6.4]
||| A data event on the clocked network is the event on the network with
||| truth maintenance; the deadline table rides beside.
export
rarc_5_6_4__apply_ttl_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                (ev : Rarc_5_6_1__event) -> (cs : Iret_19_3__clocked_net) ->
                                Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_4__apply_ttl_net pg ttl ev cs))
rarc_5_6_4__apply_ttl_net_inv alphas0 chains0 pg ttl (Assert k key pay) (MkClockedNet (MkTmsNet eng rows) dl c) inv =
  rarc_5_6_4__apply_tms_net_inv alphas0 chains0 pg (Assert k key pay) (MkTmsNet eng rows) inv
rarc_5_6_4__apply_ttl_net_inv alphas0 chains0 pg ttl (Retract i) (MkClockedNet s dl c) inv =
  rarc_5_6_4__apply_tms_net_inv alphas0 chains0 pg (Retract i) s inv

--@derives [RARC.5.6.4]
export
rarc_5_6_4__apply_ttl_net_unfired : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (ev : Rarc_5_6_1__event) -> (cs : Iret_19_3__clocked_net) ->
                                    Iret_19__view (ncore (nengine cs)) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                    Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_4__apply_ttl_net pg ttl ev cs)))))
rarc_5_6_4__apply_ttl_net_unfired pg ttl (Assert k key pay) (MkClockedNet (MkTmsNet eng rows) dl c) v u =
  rarc_5_6_4__apply_tms_net_unfired pg (Assert k key pay) (MkTmsNet eng rows) v u
rarc_5_6_4__apply_ttl_net_unfired pg ttl (Retract i) (MkClockedNet s dl c) v u =
  rarc_5_6_4__apply_tms_net_unfired pg (Retract i) s v u

--@derives [RARC.5.6.3]
--@derives [RARC.5.6.4]
||| A PREPARE WITHOUT A RE-TIME keeps the invariant and ends between
||| actions: a tick advances and sweeps; a data event sweeps and applies.
export
rarc_5_6_3__prepare_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                              (inp : Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                              Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_3__prepare_net pg ttl inp cs))
rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl (Tick t) (MkClockedNet s dl c) (inv, rl) =
  rarc_5_6_3__sweep_net_inv alphas0 chains0 pg (MkClockedNet s dl (rarc_5_6_3__next_clock c t)) inv
rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl (Data ev) cs (inv, rl) =
  rarc_5_6_4__apply_ttl_net_inv alphas0 chains0 pg ttl ev (rarc_5_6_3__sweep_net pg cs) (rarc_5_6_3__sweep_net_inv alphas0 chains0 pg cs inv)

--@derives [RARC.5.6.3]
--@derives [RARC.5.6.4]
||| A PREPARE WITHOUT A RE-TIME leaves every activation unfired when all
||| were: it retracts, asserts and cascades, and none of those fires.
export
rarc_5_6_3__prepare_net_unfired : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                  (inp : Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                  Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                  Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_3__prepare_net pg ttl inp cs)))))
rarc_5_6_3__prepare_net_unfired alphas0 chains0 pg ttl (Tick t) (MkClockedNet s dl c) (inv, rl) u =
  rarc_5_6_3__sweep_net_unfired pg (MkClockedNet s dl (rarc_5_6_3__next_clock c t)) (fst (fst inv)) u
rarc_5_6_3__prepare_net_unfired alphas0 chains0 pg ttl (Data ev) cs (inv, rl) u =
  rarc_5_6_4__apply_ttl_net_unfired pg ttl ev (rarc_5_6_3__sweep_net pg cs)
    (fst (fst (fst (rarc_5_6_3__sweep_net_inv alphas0 chains0 pg cs inv))))
    (rarc_5_6_3__sweep_net_unfired pg cs (fst (fst inv)) u)

--@spec [RARC.5.6.3]
--@spec [LFST.9.2.1]
||| INPUTS PREPARED WITH NO RUN BETWEEN THEM: the clocked network's form
||| of Rete/NetworkOnce.idr's `rarc_5_6_4__applied`.
public export
rarc_5_6_3__prepared_net : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Rarc_5_6_2__input -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
rarc_5_6_3__prepared_net pg ttl [] cs = cs
rarc_5_6_3__prepared_net pg ttl (inp :: inps) cs = rarc_5_6_3__prepared_net pg ttl inps (rarc_5_6_3__prepare_net pg ttl inp cs)

--@derives [RARC.5.6.3]
export
rarc_5_6_3__prepared_net_inv : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                               (inps : List Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                               Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine (rarc_5_6_3__prepared_net pg ttl inps cs))
rarc_5_6_3__prepared_net_inv alphas0 chains0 pg ttl [] cs inv = inv
rarc_5_6_3__prepared_net_inv alphas0 chains0 pg ttl (inp :: inps) cs inv =
  rarc_5_6_3__prepared_net_inv alphas0 chains0 pg ttl inps (rarc_5_6_3__prepare_net pg ttl inp cs) (rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl inp cs inv)

--@derives [RARC.5.6.3]
export
rarc_5_6_3__prepared_net_unfired : (alphas0 : List Iret_6_1__alpha) -> (chains0 : List Rlow_4_2_1__chain) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) ->
                                   (inps : List Rarc_5_6_2__input) -> (cs : Iret_19_3__clocked_net) ->
                                   Ltim_2_5_1__tms_inv_live alphas0 chains0 (nengine cs) -> Iret_11_3__unfired_all (nchains (enet (ncore (nengine cs)))) ->
                                   Iret_11_3__unfired_all (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps cs)))))
rarc_5_6_3__prepared_net_unfired alphas0 chains0 pg ttl [] cs inv u = u
rarc_5_6_3__prepared_net_unfired alphas0 chains0 pg ttl (inp :: inps) cs inv u =
  rarc_5_6_3__prepared_net_unfired alphas0 chains0 pg ttl inps (rarc_5_6_3__prepare_net pg ttl inp cs)
    (rarc_5_6_3__prepare_net_inv alphas0 chains0 pg ttl inp cs inv) (rarc_5_6_3__prepare_net_unfired alphas0 chains0 pg ttl inp cs inv u)

-- ---------------------------------------------------------------------
-- THE THEOREM
-- ---------------------------------------------------------------------

--@spec [RDSC.4a.5]
--@spec [IRET.19.3]
||| THE LOADED CLOCKED NETWORK: the loaded network, an empty table, no
||| deadlines, the clock at `c0`.
public export
rdsc_4a_5__load_clocked : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Nat -> Iret_19_3__clocked_net
rdsc_4a_5__load_clocked alphas rules c0 = MkClockedNet (MkTmsNet (rdsc_4a_5__load alphas rules) []) [] c0

--@derives [RDSC.4a.5]
--@derives [IRET.4.4]
||| The loaded clocked network has the invariant: the view and its own
||| shapes, no facts and no rows.
export
rdsc_4a_5__load_clocked_inv : (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) -> (c0 : Nat) ->
                              Ltim_2_5_1__tms_inv_live (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) (nengine (rdsc_4a_5__load_clocked alphas rules c0))
rdsc_4a_5__load_clocked_inv alphas rules c0 =
  ( ( (rdsc_4a_5__load_view alphas rules, rlow_4_2_1__shapes_kept_refl (rdsc_4a_5__load alphas rules))
    , \f, g, ef, eg, eq => absurd ef
    , \row, er => absurd er )
  , \row, er => absurd er )

--@derives [IRET.11.3]
--@derives [IRET.7.7]
--@derives [IRET.11.1]
--@derives [LDET.5.3]
--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [RDSC.4a.5]
||| ONCE PER MATCH UNDER THE GENERAL FRAME, WITH TRUTH MAINTENANCE AND THE
||| CLOCK. From the loaded clocked network, after any inputs -- data events
||| and ticks that sweep -- prepared with no run between them, a run that
||| reaches quiescence fires a framed chain exactly as many times as it has
||| matches when the run begins, whatever the other rules emit and
||| withdraw and whatever their endings cascade. Rete/NetworkFrame.idr's
||| theorem on the engine Rete/NetworkClocked.idr runs.
export
iret_11_3__framed_fires_once_per_match_ttl : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (fuel : Nat) -> (c0 : Nat) -> (inps : List Rarc_5_6_2__input) ->
                                             (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                             (ci : Nat) -> (nodes : List Iret_7_4__beta) -> (acts : List Iret_8_1__act) -> (actions : List Lgra_10_1__action) ->
                                             ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) nodes = True ->
                                             rarc_5_6_5__nth ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)))))) = Just (MkChain nodes acts actions) ->
                                             (cs' : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (tr : List Nat) ->
                                             iret_11_4__run_ttl_net_traced pg ttl fuel (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)) = (cs', h, tr) ->
                                             h = Quiescent ->
                                             ltim_2_5_1__count ci tr
                                               = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0))))))
                                                                        (ewm (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0))))) nodes [[]])
iret_11_3__framed_fires_once_per_match_ttl pg ttl fuel c0 inps alphas rules ci nodes acts actions fr n cs' h tr rt hq =
  let inv0 = rarc_5_6_3__prepared_net_inv (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl inps
               (rdsc_4a_5__load_clocked alphas rules c0) (rdsc_4a_5__load_clocked_inv alphas rules c0)
      v = the (Iret_19__view (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0))))) (fst (fst (fst inv0)))
      (e1 ** h1 ** tr1 ** acts' ** (rt1, _, _, _, cnt, qz)) =
        ltim_2_5_1__run_frame_ttl (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl fuel
          (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)) inv0 ci nodes acts actions fr n
      same = the ((e1, h1, tr1) = (cs', h, tr)) (trans (sym rt1) rt)
      trEq = the (tr1 = tr) (cong (\z => snd (snd z)) same)
      hEq = the (h1 = h) (cong (\z => fst (snd z)) same)
      zero = the (iret_11_4__unfired acts' = 0) (qz (trans hEq hq))
      cntTr = the (ltim_2_5_1__count ci tr = iret_11_4__unfired acts)
                (trans (cong (ltim_2_5_1__count ci) (sym trEq)) (trans (sym (plusZeroLeftNeutral _)) (trans (cong (\z => z + ltim_2_5_1__count ci tr1) (sym zero)) cnt)))
      allUnfired = the ((a : Iret_8_1__act) -> Elem a acts -> afired a = False)
                     (lcyc_1_1__all_lookup (rarc_5_6_3__prepared_net_unfired (nalphas (enet (rdsc_4a_5__load alphas rules))) (nchains (enet (rdsc_4a_5__load alphas rules))) pg ttl inps
                                              (rdsc_4a_5__load_clocked alphas rules c0) (rdsc_4a_5__load_clocked_inv alphas rules c0) (rdsc_4a_5__load_unfired alphas rules))
                        (lcyc_1_1__nth_elem ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)))))) n))
      (ss, dt) = snd (rarc_5_6_5__view_recomputed (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)))) v) (MkChain nodes acts actions)
                   (lcyc_1_1__nth_elem ci (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0)))))) n)
      lenView = the (length (iret_8_1__tuples acts)
                     = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0))))))
                                              (ewm (ncore (nengine (rarc_5_6_3__prepared_net pg ttl inps (rdsc_4a_5__load_clocked alphas rules c0))))) nodes [[]]))
                  (iret_11_3__distinct_same_set_length _ _ dt
                     (rarc_5_6_5__view_distinct _ _ (fst v) nodes [[]] (DCons (\e => absurd e) DNil)) ss)
  in trans cntTr (trans (iret_11_4__unfired_is_length acts allUnfired) (trans (sym (lengthMap acts)) lenView))

-- ---------------------------------------------------------------------
-- Executed: a cascade in the middle of a framed chain's pump
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
||| THE ALPHA TEST OF THE FIXTURES: admit every fact. Named, so that a
||| literal state names it rather than spelling a lambda.
public export
ltim_2_5_1__admits_all : Lfac_1_7_1__fact -> Bool
ltim_2_5_1__admits_all _ = True

--@spec [LTIM.2.5.1]
||| THE ALPHAS: three schemas, kinds 0, 1 and 2, admitting every fact.
public export
ltim_2_5_1__alphas_three : List (Nat, Lfac_1_7_1__fact -> Bool)
ltim_2_5_1__alphas_three = [(0, ltim_2_5_1__admits_all), (1, ltim_2_5_1__admits_all), (2, ltim_2_5_1__admits_all)]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE RULES, Rete/NetworkFrame.idr's two with B loaded first: B reads
||| kind 1, emits kind 2 and withdraws its own kind-1 fact; A reads kind 0
||| and emits kind 1. B at the lower ordinal is selected as soon as A's
||| first firing gives it a match, so B's firing, and the cascade its
||| withdrawal starts, fall between A's two firings.
public export
ltim_2_5_1__rules_b_first : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
ltim_2_5_1__rules_b_first =
  [ ([(1, iret_7_7__row, False)], ltim_2_5_1__emit_two_withdraw)
  , ([(0, iret_7_7__row, False)], ltim_2_5_1__emit_one) ]

--@spec [LTIM.2.5.1]
--@spec [IRET.12.2]
||| THE PROGRAM: kind 2 is a relation, so B's emit records a row
||| ([IRET.10.2]) and B's withdrawal ends the activation that recorded it;
||| kinds 0 and 1 are explicit.
public export
ltim_2_5_1__two_rules_tms : Lcyc_3_2_1__program
ltim_2_5_1__two_rules_tms =
  lcyc_3_2_1__program_of (\k => if k == 2 then Relation else Explicit) (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first))

--@spec [LTIM.2.5.1]
||| THE INPUT: one kind-0 fact. One, not two: the type-level evaluator
||| shares no work between uses of a closure, and a clocked firing's
||| cascade multiplies the uses, so the four-firing run of the two-fact
||| fixture does not evaluate within the lane's wall clock (measured:
||| past 1,800 s where the proofs alone take 644 s). The two-fact witness is
||| `ltim_2_5_1__two_facts_run_ttl` below, in the step-wise form with
||| literal intermediate states, as Lcyc/TmsWitnesses.idr has.
public export
ltim_2_5_1__one_input_ttl : List Rarc_5_6_2__input
ltim_2_5_1__one_input_ttl = [Data (Assert 0 1 0)]

--@spec [LTIM.2.5.1]
||| THE NETWORK AS THE INPUT LEFT IT: the loaded clocked network at clock
||| 0, the input prepared, no run after it. A holds one match, unfired; B
||| holds none.
public export
ltim_2_5_1__one_fact_ready : Iret_19_3__clocked_net
ltim_2_5_1__one_fact_ready =
  rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms (\_ => 0) ltim_2_5_1__one_input_ttl
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)

--@derives [LTIM.2.5.1]
||| A IS FRAMED in the loaded program, B first or not: computed.
export
ltim_2_5_1__a_is_framed_ttl :
  ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first)))
                     (nchains (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first)))
                     [MkBeta 0 iret_7_7__row False [[]] []] = True
ltim_2_5_1__a_is_framed_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE INPUT LEFT IT: A, at ordinal 1, holds the one match,
||| unfired, after the prepare's sweep, assert and cascade. Computed.
export
ltim_2_5_1__one_fact_ready_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine ltim_2_5_1__one_fact_ready))))
    = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one)
ltim_2_5_1__one_fact_ready_chain = Refl

--@spec [IRET.11.4]
||| What a traced clocked run shows: its trace, its halt, and the kinds of
||| the facts left live. By pattern matching, so that a run is evaluated
||| once for all three.
public export
iret_11_4__trace_of_ttl : (Iret_19_3__clocked_net, Iret_11_4__halt, List Nat) -> (List Nat, Iret_11_4__halt, List Nat)
iret_11_4__trace_of_ttl (cs, h, tr) = (tr, h, map fkind (ewm (ncore (nengine cs))))

--@derives [IRET.11.4]
||| What a traced run shows determines what the run was: its halt and its
||| trace are the ones shown, and its network is some network. Stated so
||| that a run evaluated once, for what it shows, serves as the run
||| equation the theorem takes, without a second evaluation.
export
iret_11_4__trace_of_ttl_inv : (x : (Iret_19_3__clocked_net, Iret_11_4__halt, List Nat)) -> (tr : List Nat) -> (h : Iret_11_4__halt) -> (ks : List Nat) ->
                              iret_11_4__trace_of_ttl x = (tr, h, ks) -> (cs' ** x = (cs', h, tr))
iret_11_4__trace_of_ttl_inv (cs, h0, tr0) tr h ks eq =
  (cs ** cong2 (\a, b => (cs, a, b)) (cong (\z => fst (snd z)) eq) (cong fst eq))

--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TRACE, AND THE CASCADE: A fires for its match and emits a kind-1
||| fact; B, now matched and at the lower ordinal, fires next, emitting
||| its kind-2 fact and withdrawing the kind-1 fact it matched, which ends
||| its activation, and the cascade that follows retracts the kind-2 fact
||| it had just recorded. `[1, 0]`, quiescent, and only the kind-0 fact
||| remains: no kind-2 fact survives its justifier. Executed, with fuel 3:
||| the third iteration is the one that finds nothing to fire.
export
ltim_2_5_1__one_fact_trace_ttl :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms (\_ => 0) 3 ltim_2_5_1__one_fact_ready)
    = ([1, 0], Quiescent, [0])
ltim_2_5_1__one_fact_trace_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.12.2]
||| THE THEOREM AT THE FIXTURE: the frame and the chain as the input left
||| it discharged by computation, the run and the halt by the trace above,
||| and the count of A's firings is the number of its matches, through B's
||| cascade. Executed.
export
ltim_2_5_1__one_fact_is_an_instance_ttl :
  ltim_2_5_1__count 1 [1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__one_fact_ready)))) (ewm (ncore (nengine ltim_2_5_1__one_fact_ready)))
                             [MkBeta 0 iret_7_7__row False [[]] []] [[]])
ltim_2_5_1__one_fact_is_an_instance_ttl =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms (\_ => 0) 3 ltim_2_5_1__one_fact_ready)
                      [1, 0] Quiescent [0] ltim_2_5_1__one_fact_trace_ttl
  in iret_11_3__framed_fires_once_per_match_ttl ltim_2_5_1__two_rules_tms (\_ => 0) 3 0 ltim_2_5_1__one_input_ttl ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first
       1 [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_ttl ltim_2_5_1__one_fact_ready_chain cs' Quiescent [1, 0] rt Refl

--@derives [LTIM.2.5.1]
||| And the number is one: A had one match when the run began and fired
||| once, through B's cascade. Computed.
export
ltim_2_5_1__one_fact_fires_once_ttl :
  ( ltim_2_5_1__count 1 [1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine ltim_2_5_1__one_fact_ready)))) (ewm (ncore (nengine ltim_2_5_1__one_fact_ready)))
                           [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (1, 1)
ltim_2_5_1__one_fact_fires_once_ttl = Refl

-- ---------------------------------------------------------------------
-- Executed: the two-fact run, firing by firing
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| THE TRACED RUN UNFOLDS ONE NAMED FIRING AT A TIME: a firing that
||| resolves to ordinal `r` and network `cs'` prepends `r` to the trace of
||| the run from `cs'`. What chains single-firing `Refl`s into a run, as
||| Lcyc/TmsWitnesses.idr's `iret_11_4__step_n_tms_cons` does for the
||| engine with truth maintenance.
export
iret_11_4__run_ttl_net_traced_cons : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (n : Nat) -> (cs, cs' : Iret_19_3__clocked_net) -> (r : Nat) ->
                                     (t : Iret_19_3__clocked_net) -> (h : Iret_11_4__halt) -> (tr : List Nat) ->
                                     iret_11_4__fire_ttl_net pg ttl cs = Just (r, cs') -> iret_11_4__run_ttl_net_traced pg ttl n cs' = (t, h, tr) ->
                                     iret_11_4__run_ttl_net_traced pg ttl (S n) cs = (t, h, r :: tr)
iret_11_4__run_ttl_net_traced_cons pg ttl n cs cs' r t h tr fe rest =
  trans (iret_11_4__run_ttl_net_traced_by pg ttl (S n) cs)
        (iret_11_4__trace_by_cons (iret_11_4__fire_ttl_net pg ttl) n cs cs' r t h tr fe
           (trans (sym (iret_11_4__run_ttl_net_traced_by pg ttl n cs')) rest))

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| And a firing that resolves to nothing ends the traced run `Quiescent`,
||| whatever fuel is left.
export
iret_11_4__run_ttl_net_traced_end : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (n : Nat) -> (cs : Iret_19_3__clocked_net) ->
                                    iret_11_4__fire_ttl_net pg ttl cs = Nothing -> iret_11_4__run_ttl_net_traced pg ttl (S n) cs = (cs, Quiescent, [])
iret_11_4__run_ttl_net_traced_end pg ttl n cs fe =
  trans (iret_11_4__run_ttl_net_traced_by pg ttl (S n) cs) (iret_11_4__trace_by_end (iret_11_4__fire_ttl_net pg ttl) n cs fe)

--@spec [LTIM.2.5.1]
||| THE TWO INPUTS: two kind-0 facts, prepared with no run between them;
||| Rete/NetworkFrame.idr's `ltim_2_5_1__two_inputs` on the clocked network.
public export
ltim_2_5_1__two_inputs_ttl : List Rarc_5_6_2__input
ltim_2_5_1__two_inputs_ttl = [Data (Assert 0 1 0), Data (Assert 0 2 0)]

--@spec [LTIM.2.5.1]
||| THE TTL OF THE FIXTURES: none, for every kind. Named, so that every
||| statement about the two-fact run spells the run the same way, and the
||| checker compares two statements of it syntactically rather than by
||| evaluating the run, which is the four-firing evaluation the step-wise
||| form exists to avoid.
public export
ltim_2_5_1__no_ttl : Iret_4_2__ttl
ltim_2_5_1__no_ttl _ = 0

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE NETWORK AS THE TWO INPUTS LEFT IT, as a literal: the loaded clocked
||| network at clock 0, both inputs prepared, no run after them. A holds
||| two matches, unfired, in assertion order; B holds none; no rows, no
||| deadlines. Computed once; the claims below reach the prepared network
||| through this equation rather than evaluating the prepare again.
export
ltim_2_5_1__two_facts_ready_ttl :
  rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)
    = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                       (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                  [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                  , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                             []) [] 0
ltim_2_5_1__two_facts_ready_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TWO-FACT RUN, FIRING BY FIRING. A fires for its first match and
||| emits a kind-1 fact; B, matched and at the lower ordinal, fires next,
||| emits its kind-2 fact and records the row for it, withdraws the kind-1
||| fact it matched -- which ends its activation -- and the cascade that
||| follows retracts the kind-2 fact; A fires for its second match, minting
||| the withdrawn kind-1 fact's id again (the smallest id not live,
||| [LFAC.2.5.3]: the reuse the row invariant is about); B fires and
||| cascades again. Four firings, `[1, 0, 1, 0]`, then quiescence; the two
||| kind-0 facts are all that remains, and no kind-2 fact survives its
||| justifier. Each firing is a `Refl` from a literal state, as
||| Lcyc/TmsWitnesses.idr has them, and the run is the chain of them: the
||| four-firing run as one `Refl` is beyond the type-level evaluator within
||| the lane's wall clock, as `ltim_2_5_1__one_input_ttl` records. Nothing
||| is assumed about the literals: a wrong one fails its `Refl`.
export
ltim_2_5_1__two_facts_run_ttl :
  iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 5
    (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))
    = ( MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                         (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                    [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                    , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] True] ltim_2_5_1__emit_one ]))
                               []) [] 0
      , Quiescent, [1, 0, 1, 0] )
ltim_2_5_1__two_facts_run_ttl =
  replace {p = \x => iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 5 x = (s 4, Quiescent, [1, 0, 1, 0])}
          (sym ltim_2_5_1__two_facts_ready_ttl)
    (iret_11_4__run_ttl_net_traced_cons ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 4 (s 0) (s 1) 1 _ _ _ step0
      (iret_11_4__run_ttl_net_traced_cons ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 3 (s 1) (s 2) 0 _ _ _ step1
        (iret_11_4__run_ttl_net_traced_cons ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 2 (s 2) (s 3) 1 _ _ _ step2
          (iret_11_4__run_ttl_net_traced_cons ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 1 (s 3) (s 4) 0 _ _ _ step3
            (iret_11_4__run_ttl_net_traced_end ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 0 (s 4) step4)))))
  where
    s : Nat -> Iret_19_3__clocked_net
    s 0 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s 1 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 0 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [MkFact 2 1 0 0], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [MkAct [MkFact 2 1 0 0] False] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s 2 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s 3 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 0 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [MkFact 2 1 0 0], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [MkAct [MkFact 2 1 0 0] False] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] True] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s 4 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] True] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s _ = MkClockedNet (MkTmsNet (MkEngine [] (MkNetwork [] [])) []) [] 0
    step0 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 0) = Just (1, s 1)
    step0 = Refl
    step1 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 1) = Just (0, s 2)
    step1 = Refl
    step2 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 2) = Just (1, s 3)
    step2 = Refl
    step3 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 3) = Just (0, s 4)
    step3 = Refl
    step4 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 4) = Nothing
    step4 = Refl

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE TWO INPUTS LEFT IT: A, at ordinal 1, holds its two
||| matches, unfired, in assertion order. Read off the literal.
export
ltim_2_5_1__two_facts_ready_chain :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
    = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one)
ltim_2_5_1__two_facts_ready_chain =
  replace {p = \x => rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine x))))
                     = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one)}
          (sym ltim_2_5_1__two_facts_ready_ttl) Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [IRET.12.2]
||| THE THEOREM AT THE TWO-FACT FIXTURE: the frame and the chain as the
||| inputs left it by computation, the run and the halt by the chain of
||| firings, and the count of A's firings is the number of its matches,
||| through B's two cascades, one of them between A's firings. Executed.
export
ltim_2_5_1__two_facts_is_an_instance_ttl :
  ltim_2_5_1__count 1 [1, 0, 1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                             (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                             [MkBeta 0 iret_7_7__row False [[]] []] [[]])
ltim_2_5_1__two_facts_is_an_instance_ttl =
  iret_11_3__framed_fires_once_per_match_ttl ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 5 0 ltim_2_5_1__two_inputs_ttl ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first
    1 [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one
    ltim_2_5_1__a_is_framed_ttl ltim_2_5_1__two_facts_ready_chain _ Quiescent [1, 0, 1, 0] ltim_2_5_1__two_facts_run_ttl Refl

--@derives [LTIM.2.5.1]
||| And the number is two: A had two matches when the run began and fired
||| twice, with B's firing and cascade between them. Read off the literal.
export
ltim_2_5_1__two_facts_fires_twice_ttl :
  ( ltim_2_5_1__count 1 [1, 0, 1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                           (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                           [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (2, 2)
ltim_2_5_1__two_facts_fires_twice_ttl =
  replace {p = \x => ( ltim_2_5_1__count 1 [1, 0, 1, 0]
                     , length (iret_7_7__view (nalphas (enet (ncore (nengine x)))) (ewm (ncore (nengine x))) [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (2, 2)}
          (sym ltim_2_5_1__two_facts_ready_ttl) Refl

-- ---------------------------------------------------------------------
-- Executed: a tick that expires a fact with a TTL
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
--@spec [IRET.19.3]
||| THE TTL OF THE TICKED FIXTURE: two for kind 0, none for the rest. Named,
||| as `ltim_2_5_1__no_ttl` is, so that every statement spells it the same way.
public export
ltim_2_5_1__ttl_two : Iret_4_2__ttl
ltim_2_5_1__ttl_two Z = 2
ltim_2_5_1__ttl_two (S _) = 0

--@spec [LTIM.2.5.1]
--@spec [RARC.5.6.3]
||| THE TICKED INPUTS: a kind-0 fact at clock 0, whose deadline is 2; a tick
||| to 1, which expires nothing; a second kind-0 fact at clock 1, whose
||| deadline is 3; a tick to 2, which expires the first. Prepared with no run
||| between them.
public export
ltim_2_5_1__ticked_inputs_ttl : List Rarc_5_6_2__input
ltim_2_5_1__ticked_inputs_ttl = [Data (Assert 0 1 0), Tick 1, Data (Assert 0 2 0), Tick 2]

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
--@derives [IRET.19.3]
||| THE NETWORK AS THE TICKED INPUTS LEFT IT, as a literal: the first fact,
||| its deadline 2 at the clock, swept at the second tick -- gone from working
||| memory, from its alpha memory and from A's activations, which the
||| retraction ended; the second fact live, its deadline 3 ahead of the clock;
||| the deadline table keeping the swept fact's row, which the next mint of
||| its id clears (`iret_4_3__stamp`); the clock at 2. The first tick, to 1,
||| expired nothing, and its sweep is in this computation too. Computed once;
||| the claims below reach the prepared network through this equation.
export
ltim_2_5_1__ticked_ready_ttl :
  rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)
    = MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 2 0]
                                       (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                  [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                  , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                             []) [(0, 2), (1, 3)] 2
ltim_2_5_1__ticked_ready_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [RARC.5.6.3]
||| THE CHAIN AS THE TICKED INPUTS LEFT IT: A, at ordinal 1, holds the one
||| match the sweep left, unfired. Read off the literal.
export
ltim_2_5_1__ticked_chain_ttl :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
    = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one)
ltim_2_5_1__ticked_chain_ttl =
  replace {p = \x => rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine x))))
                     = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one)}
          (sym ltim_2_5_1__ticked_ready_ttl) Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TRACE FROM THE TICKED STATE: A fires for the surviving match, B
||| fires and cascades, `[1, 0]`, quiescent, the kind-0 fact alone left live,
||| with the deadline table beside and the clock at 2. Executed from the
||| literal, with fuel 3.
export
ltim_2_5_1__ticked_trace_ttl :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two 3
    (MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 2 0]
                                      (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                 [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                 , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                            []) [(0, 2), (1, 3)] 2))
    = ([1, 0], Quiescent, [0])
ltim_2_5_1__ticked_trace_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
--@derives [RARC.5.6.3]
||| THE THEOREM AT THE TICKED FIXTURE: the frame by computation, the chain
||| as the ticks left it through the literal, the run and the halt by the
||| trace above, and the count of A's firings is the number of its matches
||| after the sweep -- the expired fact's match is not among them. Executed.
export
ltim_2_5_1__ticked_is_an_instance_ttl :
  ltim_2_5_1__count 1 [1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                             (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                             [MkBeta 0 iret_7_7__row False [[]] []] [[]])
ltim_2_5_1__ticked_is_an_instance_ttl =
  let (cs' ** rt0) = iret_11_4__trace_of_ttl_inv
                       (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two 3
                         (MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 2 0]
                                                           (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                                      [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                                      , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                                                 []) [(0, 2), (1, 3)] 2))
                       [1, 0] Quiescent [0] ltim_2_5_1__ticked_trace_ttl
      rt = the (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two 3
                  (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))
                = (cs', Quiescent, [1, 0]))
               (replace {p = \x => iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two 3 x = (cs', Quiescent, [1, 0])}
                        (sym ltim_2_5_1__ticked_ready_ttl) rt0)
  in iret_11_3__framed_fires_once_per_match_ttl ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two 3 0 ltim_2_5_1__ticked_inputs_ttl ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first
       1 [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_ttl ltim_2_5_1__ticked_chain_ttl cs' Quiescent [1, 0] rt Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.19.3]
||| And the number is one: of A's two matches before the second tick the
||| sweep ended one, and A fired once for the other. Read off the literal.
export
ltim_2_5_1__ticked_fires_once_ttl :
  ( ltim_2_5_1__count 1 [1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                           (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__ttl_two ltim_2_5_1__ticked_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                           [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (1, 1)
ltim_2_5_1__ticked_fires_once_ttl =
  replace {p = \x => ( ltim_2_5_1__count 1 [1, 0]
                     , length (iret_7_7__view (nalphas (enet (ncore (nengine x)))) (ewm (ncore (nengine x))) [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (1, 1)}
          (sym ltim_2_5_1__ticked_ready_ttl) Refl

-- ---------------------------------------------------------------------
-- Executed: a run that runs out of fuel
-- ---------------------------------------------------------------------

--@derives [IRET.11.5]
--@derives [IRET.11.4]
--@derives [LTIM.2.5.1]
||| THE RUN THAT RUNS OUT OF FUEL: from the two-fact fixture with fuel 1, A
||| fires for its first match and the fuel is spent -- `FuelOut`, trace
||| `[1]`, B's match made and unfired, A's second match unfired, the kind-1
||| fact live. One firing as a `Refl` from the literal, then the run with no
||| fuel, chained by `iret_11_4__run_ttl_net_traced_cons`; the literals are
||| `ltim_2_5_1__two_facts_run_ttl`'s first two, copied here as
||| Lcyc/TmsWitnesses.idr copies its states per claim.
export
ltim_2_5_1__two_facts_fuel_out_ttl :
  iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 1
    (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl ltim_2_5_1__two_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))
    = ( MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 0 0]
                                         (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [MkFact 2 1 0 0], MkAlpha 2 ltim_2_5_1__admits_all []]
                                                    [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [MkAct [MkFact 2 1 0 0] False] ltim_2_5_1__emit_two_withdraw
                                                    , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                               []) [] 0
      , FuelOut, [1] )
ltim_2_5_1__two_facts_fuel_out_ttl =
  replace {p = \x => iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 1 x = (s 1, FuelOut, [1])}
          (sym ltim_2_5_1__two_facts_ready_ttl)
    (iret_11_4__run_ttl_net_traced_cons ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl 0 (s 0) (s 1) 1 (s 1) FuelOut [] step0 Refl)
  where
    s : Nat -> Iret_19_3__clocked_net
    s 0 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s 1 = MkClockedNet (MkTmsNet (MkEngine [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 0 0]
                                   (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 0 0 1 0, MkFact 1 0 2 0], MkAlpha 1 ltim_2_5_1__admits_all [MkFact 2 1 0 0], MkAlpha 2 ltim_2_5_1__admits_all []]
                                              [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [MkAct [MkFact 2 1 0 0] False] ltim_2_5_1__emit_two_withdraw
                                              , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] False] ltim_2_5_1__emit_one ]))
                         []) [] 0
    s _ = MkClockedNet (MkTmsNet (MkEngine [] (MkNetwork [] [])) []) [] 0
    step0 : iret_11_4__fire_ttl_net ltim_2_5_1__two_rules_tms ltim_2_5_1__no_ttl (s 0) = Just (1, s 1)
    step0 = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.5]
||| THE COUNT EQUATION AT `FuelOut`: what `ltim_2_5_1__run_frame_ttl` says
||| of that run, read at its instance -- A's unfired activations after, 1,
||| plus its firings in the trace `[1]`, 1, are its unfired activations
||| before, 2. The "all fired" conjunct is not claimed, the halt not being
||| `Quiescent`. Computed.
export
ltim_2_5_1__fuel_out_count_ttl :
  ( iret_11_4__unfired [MkAct [MkFact 0 0 1 0] True, MkAct [MkFact 1 0 2 0] False] + ltim_2_5_1__count 1 [1]
  , iret_11_4__unfired [MkAct [MkFact 0 0 1 0] False, MkAct [MkFact 1 0 2 0] False] ) = (2, 2)
ltim_2_5_1__fuel_out_count_ttl = Refl

-- ---------------------------------------------------------------------
-- Executed: an entity replaced and a relation re-asserted among the inputs
-- ---------------------------------------------------------------------

--@spec [LTIM.2.5.1]
--@spec [IRET.19.1]
||| THE LIFECYCLES OF THE ENTITY FIXTURE: kind 0, the kind A reads, an
||| entity; kind 2 a relation, as in `ltim_2_5_1__two_rules_tms`; kind 1
||| explicit. Named, so that the program names it.
public export
ltim_2_5_1__life_entity : Nat -> Lscp_1_3__lifecycle
ltim_2_5_1__life_entity 0 = Entity
ltim_2_5_1__life_entity 1 = Explicit
ltim_2_5_1__life_entity 2 = Relation
ltim_2_5_1__life_entity _ = Explicit

--@spec [LTIM.2.5.1]
--@spec [IRET.19.1]
||| THE ENTITY PROGRAM: the two rules, B first, with kind 0 an entity.
public export
ltim_2_5_1__two_rules_entity : Lcyc_3_2_1__program
ltim_2_5_1__two_rules_entity =
  lcyc_3_2_1__program_of ltim_2_5_1__life_entity (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first))

--@spec [LTIM.2.5.1]
--@spec [LFAC.2.5.1]
--@spec [LFAC.2.5.3]
||| THE ENTITY INPUTS: the entity with key 1 asserted with payload 0, then
||| with payload 7 (a replace, [LFAC.2.5.3]), then with payload 7 again (a
||| suppressed no-op, [LFAC.2.5.1]); a relation asserted, then asserted again
||| (a no-op). Prepared with no run between them.
public export
ltim_2_5_1__entity_inputs_ttl : List Rarc_5_6_2__input
ltim_2_5_1__entity_inputs_ttl = [Data (Assert 0 1 0), Data (Assert 0 1 7), Data (Assert 0 1 7), Data (Assert 2 5 5), Data (Assert 2 5 5)]

--@derives [LTIM.2.5.1]
--@derives [LFAC.2.5.1]
--@derives [LFAC.2.5.3]
--@derives [IRET.19.1]
||| THE NETWORK AS THE ENTITY INPUTS LEFT IT, as a literal: the replace
||| retracted the entity's first wrapper and minted the new one against the
||| memory the old was still in, so its id is 1, and A's activation is the
||| new wrapper's, unfired; the two no-ops changed nothing; the relation took
||| the freed id 0. Computed once; the claims below reach the prepared
||| network through this equation.
export
ltim_2_5_1__entity_ready_ttl :
  rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)
    = MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 1 7, MkFact 0 2 5 5]
                                       (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 1 7], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all [MkFact 0 2 5 5]]
                                                  [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                  , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one ]))
                             []) [] 0
ltim_2_5_1__entity_ready_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [LFAC.2.5.3]
||| THE CHAIN AS THE ENTITY INPUTS LEFT IT: A, at ordinal 1, holds the one
||| match, the replacement's, unfired; the replaced wrapper's match ended
||| with it. Read off the literal.
export
ltim_2_5_1__entity_chain_ttl :
  rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
    = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one)
ltim_2_5_1__entity_chain_ttl =
  replace {p = \x => rarc_5_6_5__nth 1 (nchains (enet (ncore (nengine x))))
                     = Just (MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one)}
          (sym ltim_2_5_1__entity_ready_ttl) Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.12.2]
--@derives [IRET.11.3]
||| THE TRACE FROM THE ENTITY STATE: A fires for the replacement's match, B
||| fires and cascades, `[1, 0]`, quiescent; the entity and the input
||| relation, which no row targets, are left live. Executed from the literal,
||| with fuel 3.
export
ltim_2_5_1__entity_trace_ttl :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl 3
    (MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 1 7, MkFact 0 2 5 5]
                                      (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 1 7], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all [MkFact 0 2 5 5]]
                                                 [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                 , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one ]))
                            []) [] 0))
    = ([1, 0], Quiescent, [0, 2])
ltim_2_5_1__entity_trace_ttl = Refl

--@derives [LTIM.2.5.1]
--@derives [IRET.11.3]
||| THE THEOREM AT THE ENTITY FIXTURE: the frame by computation, the chain
||| as the inputs left it through the literal, the run and the halt by the
||| trace above, and the count of A's firings is the number of its matches:
||| one, the replacement's; the replaced wrapper's is gone and the no-ops
||| made none. Executed.
export
ltim_2_5_1__entity_is_an_instance_ttl :
  ltim_2_5_1__count 1 [1, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                             (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                             [MkBeta 0 iret_7_7__row False [[]] []] [[]])
ltim_2_5_1__entity_is_an_instance_ttl =
  let (cs' ** rt0) = iret_11_4__trace_of_ttl_inv
                       (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl 3
                         (MkClockedNet (MkTmsNet (MkEngine [MkFact 1 0 1 7, MkFact 0 2 5 5]
                                                           (MkNetwork [MkAlpha 0 ltim_2_5_1__admits_all [MkFact 1 0 1 7], MkAlpha 1 ltim_2_5_1__admits_all [], MkAlpha 2 ltim_2_5_1__admits_all [MkFact 0 2 5 5]]
                                                                      [ MkChain [MkBeta 1 iret_7_7__row False [[]] []] [] ltim_2_5_1__emit_two_withdraw
                                                                      , MkChain [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one ]))
                                                 []) [] 0))
                       [1, 0] Quiescent [0, 2] ltim_2_5_1__entity_trace_ttl
      rt = the (iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl 3
                  (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))
                = (cs', Quiescent, [1, 0]))
               (replace {p = \x => iret_11_4__run_ttl_net_traced ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl 3 x = (cs', Quiescent, [1, 0])}
                        (sym ltim_2_5_1__entity_ready_ttl) rt0)
  in iret_11_3__framed_fires_once_per_match_ttl ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl 3 0 ltim_2_5_1__entity_inputs_ttl ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first
       1 [MkBeta 0 iret_7_7__row False [[]] []] [MkAct [MkFact 1 0 1 7] False] ltim_2_5_1__emit_one
       ltim_2_5_1__a_is_framed_ttl ltim_2_5_1__entity_chain_ttl cs' Quiescent [1, 0] rt Refl

--@derives [LTIM.2.5.1]
||| And the number is one: the replacement's match, fired once. Read off the
||| literal.
export
ltim_2_5_1__entity_fires_once_ttl :
  ( ltim_2_5_1__count 1 [1, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0))))))
                           (ewm (ncore (nengine (rarc_5_6_3__prepared_net ltim_2_5_1__two_rules_entity ltim_2_5_1__no_ttl ltim_2_5_1__entity_inputs_ttl (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three ltim_2_5_1__rules_b_first 0)))))
                           [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (1, 1)
ltim_2_5_1__entity_fires_once_ttl =
  replace {p = \x => ( ltim_2_5_1__count 1 [1, 0]
                     , length (iret_7_7__view (nalphas (enet (ncore (nengine x)))) (ewm (ncore (nengine x))) [MkBeta 0 iret_7_7__row False [[]] []] [[]]) ) = (1, 1)}
          (sym ltim_2_5_1__entity_ready_ttl) Refl

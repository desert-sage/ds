-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Termination with truth maintenance: a certified positive program
||| quiesces on Rete/FireLoopTms.idr's engine, logical retraction in the
||| loop, from every input with unique ids.
|||
||| NORMATIVE COMPANION to Lcyc/Certificate.idr and Lcyc/Termination.idr,
||| on the same mechanisms.
|||
||| THE CERTIFICATE is [LCYC.3.1.1]'s: a stratification of the
||| rules in which no kind emitted by a stratum is read by that stratum
||| (`Lcyc_3_1_1__certified_tms`). With the SCC-DAG's topological order,
||| one stratum per SCC, that is the clause's "no schema both emitted and
||| matched in an SCC". It implies Lcyc/Certificate.idr's certificate
||| (`lcyc_3_1_1__tms_to_core`: the recursion disjunct is vacuous), so the
||| core's measure and its progress lemmas apply to the actions unchanged.
|||
||| WHAT IS NEW. Each cascade phase retracts the logical facts whose
||| support ended, and propagates. THE FORWARD-REACHABILITY LEMMA
||| (`lcyc_3_1_1__phase_kinds`): during a firing at stratum i, every fact a
||| phase retracts has a kind emitted by a rule of stratum i or above. The
||| row that lost its support belongs to a rule whose activation ended in
||| this firing, and strata below i are untouched by it
||| (`Lcyc_3_1_1__fire_measure`'s `fmBelowLive`), so that rule is at i or
||| above, and a row's target has a kind its rule emits (`fmKind`). No
||| stratum at or below i reads such a kind -- below i by edge
||| monotonicity, at i by the certificate -- so the phase is a frame for
||| every stratum at or below i (`Rarc_5_6_4__frame_pred`) and the
||| measure's components there are unchanged. The lexicographic decrease
||| of the core proof then goes through (`lcyc_1_1__step_tms_decreases`),
||| and well-founded recursion on the measure gives quiescence
||| (`lcyc_1_1__certified_terminates_tms`).
|||
||| SCOPE. Positive programs, as Rete/TmsRun.idr's run invariant requires.
||| The statement is the core's: some finite number of firings reaches an
||| empty agenda, on the deterministic engine with truth maintenance. The
||| certificate is kind-level: a program [LCYC.3.1.1] admits only through
||| [LCYC.6.1]'s literal break has none, and the theorem does not reach it
||| (Lcyc/Certificate.idr's header says why).
module Lcyc.TmsTermination

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Lcyc.Certificate
import Lcyc.Termination
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality
import Control.WellFounded

%default total

-- ---------------------------------------------------------------------
-- Small lemmas
-- ---------------------------------------------------------------------

--@derives [LCYC.1.1]
export
lcyc_1_1__and_false_of_true : (a, b : Bool) -> b = True -> (a && b) = False -> a = False
lcyc_1_1__and_false_of_true False _ _ _ = Refl
lcyc_1_1__and_false_of_true True True _ prf = absurd prf
lcyc_1_1__and_false_of_true True False bt _ = absurd bt

-- ---------------------------------------------------------------------
-- The certificate
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
||| THE CERTIFICATE. A stratification respecting every edge, in
||| which no kind emitted by a stratum is read by that stratum, and the
||| range restriction. With one stratum per SCC this is the clause:
||| no schema both emitted and matched within an SCC.
public export
record Lcyc_3_1_1__certified_tms (p : Lcyc_3_2_1__program) where
  constructor MkCertifiedTms
  tmsStrata     : Lcyc_3_1__strata
  tmsLits       : List (Nat, Nat)
  tmsEdgeMono   : Lcyc_3_1__edge_mono tmsStrata (rules p)
  tmsInRange    : Lcyc_3_1__in_range tmsStrata (rules p)
  tmsNoEmitRead : (i, k : Nat) -> rarc_5_6_5__elem k (lcyc_3_1__emit_kinds_of tmsStrata i (rules p)) = True ->
                  rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of tmsStrata i (rules p)) = False
  tmsRange      : Lcyc_3_1_1__range p tmsLits

--@derives [LCYC.3.1.1]
||| This certificate is a core certificate: its recursion
||| disjunct is vacuous, since an emitted kind is never read in its stratum.
public export
lcyc_3_1_1__tms_to_core : (p : Lcyc_3_2_1__program) -> Lcyc_3_1_1__certified_tms p -> Lcyc_3_1_1__certified p
lcyc_3_1_1__tms_to_core p ct =
  MkCertified (tmsStrata ct) (tmsLits ct) (tmsEdgeMono ct) (tmsInRange ct)
    (\ri, r, nr, k, ek, rk => void (lcyc_1_1__bool_not_both _ rk
       (tmsNoEmitRead ct (strat (tmsStrata ct) ri) k
          (lcyc_1_1__elem_concat_map lcyc_3_2_2__emit_kinds (lcyc_3_1__rules_in (tmsStrata ct) (strat (tmsStrata ct) ri) (rules p))
             (lcyc_3_1__rules_in_elem (tmsStrata ct) (rules p) (strat (tmsStrata ct) ri) ri r nr Refl) k ek))))
    (tmsRange ct)

--@derives [LCYC.3.1]
||| A kind emitted by a rule of stratum i or above.
public export
Lcyc_3_1__emitted_from : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> Nat -> Type
Lcyc_3_1__emitted_from s i rs k =
  (ri : Nat ** (r : Lgra_6_1__rule ** (rarc_5_6_5__nth ri rs = Just r, rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True, LTE i (strat s ri))))

--@derives [LCYC.3.1]
||| No stratum below i reads a kind emitted at i or above.
export
lcyc_3_1__below_reads_none : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> Lcyc_3_1__edge_mono s rs -> (i, j : Nat) -> LT j i ->
                             (k : Nat) -> Lcyc_3_1__emitted_from s i rs k -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s j rs) = False
lcyc_3_1__below_reads_none s rs mono i j lt k (ri ** (r ** (nr, ek, le))) =
  lcyc_3_1__stratum_below_not_read s rs mono ri r nr k (lcyc_1_1__elem_l_append_left k (lcyc_3_2_2__emit_kinds r) (lcyc_3_2_2__withdraw_kinds r) ek) j
    (transitive lt le)

--@derives [LCYC.3.1.1]
||| Nor does stratum i itself: a reader at i of a kind emitted at i or
||| above puts the emitter at i, which the certificate forbids.
export
lcyc_3_1_1__own_reads_none : (s : Lcyc_3_1__strata) -> (rs : List Lgra_6_1__rule) -> Lcyc_3_1__edge_mono s rs ->
                             ((i, k : Nat) -> rarc_5_6_5__elem k (lcyc_3_1__emit_kinds_of s i rs) = True -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i rs) = False) ->
                             (i, k : Nat) -> Lcyc_3_1__emitted_from s i rs k -> rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i rs) = False
lcyc_3_1_1__own_reads_none s rs mono noER i k (ri ** (r ** (nr, ek, le))) with (rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i rs)) proof e
  lcyc_3_1_1__own_reads_none s rs mono noER i k (ri ** (r ** (nr, ek, le))) | False = Refl
  lcyc_3_1_1__own_reads_none s rs mono noER i k (ri ** (r ** (nr, ek, le))) | True =
    let (q ** (eq, rq)) = lcyc_1_1__elem_concat_map_inv lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in s i rs) k e
    in let (rj ** (nq, sj)) = lcyc_3_1__rules_in_index s rs i q eq
    in let le' : LTE (strat s ri) i
           le' = replace {p = \x => LTE (strat s ri) x} sj
                   (mono ri rj r q nr nq k (lcyc_1_1__elem_l_append_left k (lcyc_3_2_2__emit_kinds r) (lcyc_3_2_2__withdraw_kinds r) ek) rq)
           eqi : (strat s ri = i)
           eqi = antisymmetric le' le
    in absurd (trans (sym e) (noER i k (lcyc_1_1__elem_concat_map lcyc_3_2_2__emit_kinds (lcyc_3_1__rules_in s i rs)
                                          (lcyc_3_1__rules_in_elem s rs i ri r nr eqi) k ek)))

-- ---------------------------------------------------------------------
-- Frames over a set of kinds
-- ---------------------------------------------------------------------

--@derives [RARC.5.6.4]
||| A change confined to the kinds satisfying `pr`: every other kind's
||| facts are the same list. `Rarc_5_6_4__frame k` is the case `pr = (= k)`.
public export
Rarc_5_6_4__frame_pred : (Nat -> Type) -> Rarc_5_6_4__wm -> Rarc_5_6_4__wm -> Type
Rarc_5_6_4__frame_pred pr wm wm' = (k' : Nat) -> Not (pr k') -> rarc_5_6_4__facts_of_kind k' wm' = rarc_5_6_4__facts_of_kind k' wm

--@derives [RARC.5.6.5]
export
rarc_5_6_5__tuples_frame_pred : (pr : Nat -> Type) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' -> (ks : List Nat) ->
                                ((k' : Nat) -> Elem k' ks -> Not (pr k')) -> iret_7_4__tuples ks w' = iret_7_4__tuples ks w
rarc_5_6_5__tuples_frame_pred pr w w' fr [] np = Refl
rarc_5_6_5__tuples_frame_pred pr w w' fr (k1 :: ks) np =
  rewrite fr k1 (np k1 Here) in rewrite rarc_5_6_5__tuples_frame_pred pr w w' fr ks (\k', e => np k' (There e)) in Refl

--@derives [RARC.5.6.5]
export
rarc_5_6_5__neg_facts_frame_pred : (pr : Nat -> Type) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' ->
                                   (nbs : List (Nat, List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool)) ->
                                   ((k' : Nat) -> Elem k' (map (\nb => fst nb) nbs) -> Not (pr k')) ->
                                   map (\nb => rarc_5_6_4__facts_of_kind (fst nb) w') nbs = map (\nb => rarc_5_6_4__facts_of_kind (fst nb) w) nbs
rarc_5_6_5__neg_facts_frame_pred pr w w' fr [] np = Refl
rarc_5_6_5__neg_facts_frame_pred pr w w' fr (nb :: nbs) np =
  rewrite fr (fst nb) (np (fst nb) Here) in
  cong (rarc_5_6_4__facts_of_kind (fst nb) w ::) (rarc_5_6_5__neg_facts_frame_pred pr w w' fr nbs (\k', e => np k' (There e)))

--@derives [RARC.5.6.5]
||| A rule reading no kind of the change keeps its propagation.
export
rarc_5_6_5__prop_rule_frame_pred : (pr : Nat -> Type) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' -> (r : Lgra_6_1__rule) ->
                                   ((k' : Nat) -> pr k' -> rarc_5_6_5__elem k' (lcyc_3_2_2__read_kinds r) = False) ->
                                   (ts : List Iret_11__tok) -> rarc_5_6_5__prop_rule r w' ts = rarc_5_6_5__prop_rule r w ts
rarc_5_6_5__prop_rule_frame_pred pr w w' fr r notRead ts =
  rewrite rarc_5_6_5__tuples_frame_pred pr w w' fr (posKinds r)
            (\k', e, pk => lcyc_1_1__bool_not_both _ (lcyc_1_1__elem_l_append_left k' (posKinds r) (iret_7_9__neg_kinds r) (lcyc_1_1__elem_l_true k' (posKinds r) e)) (notRead k' pk)) in
  rewrite rarc_5_6_5__neg_facts_frame_pred pr w w' fr (negs r)
            (\k', e, pk => lcyc_1_1__bool_not_both _ (lcyc_1_1__elem_l_append_right k' (posKinds r) (iret_7_9__neg_kinds r) (lcyc_1_1__elem_l_true k' (iret_7_9__neg_kinds r) e)) (notRead k' pk)) in
  Refl

--@derives [RARC.5.6.5]
||| A rule reading no kind of the change keeps its table (frame and
||| settledness).
export
rarc_5_6_5__table_frame_pred : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                               Lcyc_1_1__inv p dom (MkState wm tables) -> (pr : Nat -> Type) -> (w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr wm w' ->
                               (ri : Nat) -> ((q : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just q -> (k' : Nat) -> pr k' -> rarc_5_6_5__elem k' (lcyc_3_2_2__read_kinds q) = False) ->
                               rarc_5_6_5__nth ri (rarc_5_6_5__propagate p w' tables) = rarc_5_6_5__nth ri tables
rarc_5_6_5__table_frame_pred p dom wm tables inv pr w' fr ri notRead with (rarc_5_6_5__nth ri tables) proof nt
  rarc_5_6_5__table_frame_pred p dom wm tables inv pr w' fr ri notRead | Nothing =
    lcyc_1_1__nth_zip_with_nothing_r (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) tables nt
  rarc_5_6_5__table_frame_pred p dom wm tables inv pr w' fr ri notRead | (Just ts) =
    let (q ** nq) = lcyc_1_1__nth_length ri (rules p) tables (tokLen inv) nt
    in rewrite lcyc_1_1__nth_zip_with_just (\r, ts => rarc_5_6_5__prop_rule r w' ts) ri (rules p) tables nq nt in
       rewrite rarc_5_6_5__prop_rule_frame_pred pr wm w' fr q (notRead q nq) ts in
       cong Just (iret_8_1__settled_fixed q (iret_7_4__match_tuples q wm) (iret_7_9__neg_facts q wm) ts (settled inv ri q ts nq nt))

--@derives [LCYC.1.1]
||| A stratum reading no kind of the change keeps its comp2.
export
lcyc_1_1__comp2_frame_pred : (p : Lcyc_3_2_1__program) -> (dom : List (Nat, Nat)) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) ->
                             Lcyc_1_1__inv p dom (MkState wm tables) -> (s : Lcyc_3_1__strata) -> (pr : Nat -> Type) -> (w' : Rarc_5_6_4__wm) ->
                             Rarc_5_6_4__frame_pred pr wm w' -> (j : Nat) ->
                             ((k' : Nat) -> pr k' -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p)) = False) ->
                             lcyc_1_1__comp2 s j (rules p) (rarc_5_6_5__propagate p w' tables) = lcyc_1_1__comp2 s j (rules p) tables
lcyc_1_1__comp2_frame_pred p dom wm tables inv s pr w' fr j notReadJ =
  lcyc_1_1__comp2_ext s j (rules p) tables (rarc_5_6_5__propagate p w' tables)
    (\rj, e => let (q ** (nq, eq)) = lcyc_3_1__indices_in_elem s (rules p) j rj e
               in rarc_5_6_5__table_frame_pred p dom wm tables inv pr w' fr rj
                    (\q', nq', k', pk => rewrite lcyc_1_1__just_injective (trans (sym nq') nq) in
                                         lcyc_3_1__not_read_same s (rules p) j k' (notReadJ k' pk) rj q nq eq))

--@derives [LFAC.2.5.1]
export
lfac_2_5_1__live_val_frame_pred : (pr : Nat -> Type) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' -> (k' : Nat) -> Not (pr k') ->
                                  (d : (Nat, Nat)) -> lfac_2_5_1__live_val k' d w' = lfac_2_5_1__live_val k' d w
lfac_2_5_1__live_val_frame_pred pr w w' fr k' np d =
  cong (\fs => rarc_5_6_5__any (\f => lfac_2_5_1__same_val (lfac_2_5_1__val f) d) fs) (fr k' np)

--@derives [LCYC.1.1]
export
lcyc_1_1__headroom_frame_pred : (pr : Nat -> Type) -> (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' -> (k' : Nat) -> Not (pr k') ->
                                (dom : List (Nat, Nat)) -> lcyc_1_1__headroom k' dom w' = lcyc_1_1__headroom k' dom w
lcyc_1_1__headroom_frame_pred pr w w' fr k' np dom =
  cong length (lcyc_1_1__filter_ext (\d => not (lfac_2_5_1__live_val k' d w')) (\d => not (lfac_2_5_1__live_val k' d w))
                 (\d => cong not (lfac_2_5_1__live_val_frame_pred pr w w' fr k' np d)) dom)

--@derives [LCYC.1.1]
||| A stratum reading no kind of the change keeps its comp1: every kind
||| its measure mentions is one it reads.
export
lcyc_1_1__comp1_frame_pred : (p : Lcyc_3_2_1__program) -> (s : Lcyc_3_1__strata) -> (dom : List (Nat, Nat)) -> (j : Nat) -> (pr : Nat -> Type) ->
                             (w, w' : Rarc_5_6_4__wm) -> Rarc_5_6_4__frame_pred pr w w' ->
                             ((k' : Nat) -> pr k' -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p)) = False) ->
                             lcyc_1_1__comp1 p s dom j w' = lcyc_1_1__comp1 p s dom j w
lcyc_1_1__comp1_frame_pred p s dom j pr w w' fr notReadJ =
  cong2 (+)
    (lcyc_1_1__sum_by_ext (\k' => lcyc_1_1__headroom k' dom w') (\k' => lcyc_1_1__headroom k' dom w)
       (filter (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p))) (lcyc_3_1__emit_kinds_of s j (rules p)))
       (lcyc_1_1__all_from_elem _ (\k', e => lcyc_1_1__headroom_frame_pred pr w w' fr k'
           (notP k' (snd (lcyc_1_1__elem_filter_inv (\k' => rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p))) _ e))) dom)))
    (lcyc_1_1__sum_by_ext (\k' => rarc_5_6_4__count_kind k' w') (\k' => rarc_5_6_4__count_kind k' w) (lcyc_3_1__withdraw_kinds_of s j (rules p))
       (lcyc_1_1__all_from_elem _ (\k', e => cong length (fr k'
           (notP k' (lcyc_3_1__withdraw_of_sub_read s (rules p) j k' (lcyc_1_1__elem_l_true k' _ e)))))))
  where
    notP : (k' : Nat) -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of s j (rules p)) = True -> Not (pr k')
    notP k' rd pk = lcyc_1_1__bool_not_both _ rd (notReadJ k' pk)

--@derives [RARC.5.6.4]
||| Retracting ids none of which belongs to a fact of kind k' leaves the
||| facts of kind k' alone.
export
rarc_5_6_4__facts_of_kind_retract : (k' : Nat) -> (gone : List Nat) -> (wm : Rarc_5_6_4__wm) ->
                                    ((f : Lfac_1_7_1__fact) -> Elem f wm -> fkind f = k' -> Not (Elem (fid f) gone)) ->
                                    rarc_5_6_4__facts_of_kind k' (iret_12_2__retract_ids gone wm) = rarc_5_6_4__facts_of_kind k' wm
rarc_5_6_4__facts_of_kind_retract k' gone [] h = Refl
rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h with (rarc_5_6_5__elem (fid f) gone) proof eg
  rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | True with (fkind f == k') proof fk
    rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | True | True =
      void (h f Here (lcyc_1_1__nat_eq_true (fkind f) k' fk) (lcyc_1_1__elem_l_elem (fid f) gone eg))
    rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | True | False =
      rarc_5_6_4__facts_of_kind_retract k' gone fs (\g, e, gk, ge => h g (There e) gk ge)
  rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | False with (fkind f == k')
    rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | False | True =
      cong (f ::) (rarc_5_6_4__facts_of_kind_retract k' gone fs (\g, e, gk, ge => h g (There e) gk ge))
    rarc_5_6_4__facts_of_kind_retract k' gone (f :: fs) h | False | False =
      rarc_5_6_4__facts_of_kind_retract k' gone fs (\g, e, gk, ge => h g (There e) gk ge)

-- ---------------------------------------------------------------------
-- What a phase retracts, exactly
-- ---------------------------------------------------------------------

--@derives [IRET.12.2]
export
iret_12_2__phase_after_gone_shape : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (kept : Iret_12_4__table) -> (gone : List Nat) ->
                                    (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                                    iret_12_2__phase_after p wm tables kept gone = MkTms (MkState wm' tables') rows' ->
                                    Either (wm' = wm, tables' = tables)
                                           (wm' = iret_12_2__retract_ids gone wm, tables' = rarc_5_6_5__propagate p (iret_12_2__retract_ids gone wm) tables)
iret_12_2__phase_after_gone_shape p wm tables kept [] wm' tables' rows' eq =
  let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Left (sym we, sym te)
iret_12_2__phase_after_gone_shape p wm tables kept (g :: gs) wm' tables' rows' eq =
  let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Right (sym we, sym te)

--@derives [IRET.12.2]
||| What a phase does to the core state, with the retracted ids named:
||| nothing, or the retraction of the zeroed targets and its propagation.
export
iret_12_2__phase_gone_shape : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                              iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                              Either (wm' = wm, tables' = tables)
                                     ( wm' = iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm
                                     , tables' = rarc_5_6_5__propagate p (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm) tables )
iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq with (iret_12_2__ended (MkState wm tables) rows)
  iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq | [] =
    let (se, _) = iret_12__tms_inj eq in let (we, te) = rarc_5_6_5__state_inj se in Left (sym we, sym te)
  iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq | (x :: xs) =
    iret_12_2__phase_after_gone_shape p wm tables (iret_12_2__kept (MkState wm tables) rows)
      (iret_12_2__zeroed (x :: xs) (iret_12_2__kept (MkState wm tables) rows)) wm' tables' rows' eq

-- ---------------------------------------------------------------------
-- The measure data carried through a firing
-- ---------------------------------------------------------------------

--@derives [IRET.12.4]
||| Every row's rule exists, and a live fact with the row's target id has
||| a kind that rule emits. A run invariant; what makes a retracted fact's
||| kind one of its row's rule.
public export
Iret_12_4__run_kind : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> Iret_12_4__table -> Type
Iret_12_4__run_kind p wm rows =
  (row : Iret_12_4__row) -> Elem row rows ->
  (rule : Lgra_6_1__rule ** ( rarc_5_6_5__nth (rrule row) (rules p) = Just rule
                            , (f : Lfac_1_7_1__fact) -> Elem f wm -> fid f = rtarget row ->
                                (rarc_5_6_5__elem (fkind f) (lcyc_3_2_2__emit_kinds rule) = True, Not (life p (fkind f) = Explicit)) ))

--@derives [LCYC.3.1.1]
||| What the termination argument carries through a firing at rule r's
||| stratum, relative to the post-pop state and a reference table: the
||| core's progress, that rows of strata below the firing one are live,
||| and the kinds of the rows' targets.
public export
record Lcyc_3_1_1__fire_measure (p : Lcyc_3_2_1__program) (ct : Lcyc_3_1_1__certified_tms p) (dom : List (Nat, Nat)) (r : Nat)
                                (wm0 : Rarc_5_6_4__wm) (tables0 : List (List Iret_11__tok))
                                (wm : Rarc_5_6_4__wm) (tables : List (List Iret_11__tok)) (rows0 : Iret_12_4__table) where
  constructor MkFireMeasure
  fmProgress  : Lcyc_1_1__progress p (lcyc_3_1_1__tms_to_core p ct) dom (strat (tmsStrata ct) r) (MkState wm0 tables0) (MkState wm tables)
  fmBelowLive : (row : Iret_12_4__row) -> Elem row rows0 -> LT (strat (tmsStrata ct) (rrule row)) (strat (tmsStrata ct) r) ->
                iret_7_8__activation_live tables row = True
  fmKind      : Iret_12_4__run_kind p wm rows0

--@derives [LCYC.3.1.1]
||| THE FORWARD-REACHABILITY LEMMA. During a firing at stratum i, a phase
||| retracts only facts of kinds emitted at stratum i or above: a retracted
||| fact is the live target of a row whose activation is dead, that row's
||| rule is not below i (rows below i are live), and the fact's kind is one
||| that rule emits.
export
lcyc_3_1_1__phase_kinds : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) -> (r : Nat) ->
                          (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                          (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                          Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows0 ->
                          Rarc_5_6_4__frame_pred (Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) wm
                            (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm)
lcyc_3_1_1__phase_kinds p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm k' np =
  rarc_5_6_4__facts_of_kind_retract k' _ wm (\f, ef, fk, eg =>
    let (inT, _) = lcyc_1_1__elem_filter_inv (\i => iret_12_1__count (iret_12_2__kept (MkState wm tables) rows) i == 0)
                     (map rtarget (iret_12_2__ended (MkState wm tables) rows)) eg
    in let (row ** (er, ti)) = lcyc_1_1__elem_map_inv rtarget (iret_12_2__ended (MkState wm tables) rows) inT
    in let (e0, ne) = lcyc_1_1__elem_filter_inv (\row => not (iret_7_8__activation_live tables row && rarc_5_6_4__is_live (rtarget row) wm)) rows er
    in let e00 : Elem row rows0
           e00 = rowsSub inv row e0
           tl : (rarc_5_6_4__is_live (rtarget row) wm = True)
           tl = replace {p = \j => rarc_5_6_4__is_live j wm = True} (sym ti) (rarc_5_6_4__is_live_of f wm ef)
           dead : (iret_7_8__activation_live tables row = False)
           dead = lcyc_1_1__and_false_of_true _ _ tl (lcyc_1_1__not_true_is_false _ ne)
           above : LTE (strat (tmsStrata ct) r) (strat (tmsStrata ct) (rrule row))
           above = notLTImpliesGTE (\lt => lcyc_1_1__bool_not_both _ (fmBelowLive fm row e00 lt) dead)
    in let (rule ** (nr, kf)) = fmKind fm row e00
    in np (rrule row ** (rule ** (nr, replace {p = \x => rarc_5_6_5__elem x (lcyc_3_2_2__emit_kinds rule) = True} fk (fst (kf f ef (sym ti))), above))))

--@derives [LCYC.3.1.1]
||| A retraction phase keeps the measure data: it is a frame for every
||| stratum at or below the firing one, so their components are unchanged,
||| rows below stay live, and the kinds of targets are unchanged.
export
lcyc_3_1_1__retract_measure : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) -> (r : Nat) ->
                              (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows0 ->
                              Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0
                                (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm)
                                (rarc_5_6_5__propagate p (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm) tables)
                                rows0
lcyc_3_1_1__retract_measure p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm =
  let fr : Rarc_5_6_4__frame_pred (Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) wm
             (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm)
      fr = lcyc_3_1_1__phase_kinds p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm
      belowNone : (j : Nat) -> LT j (strat (tmsStrata ct) r) -> (k' : Nat) -> Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) k' ->
                  rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (tmsStrata ct) j (rules p)) = False
      belowNone j lt k' pk = lcyc_3_1__below_reads_none (tmsStrata ct) (rules p) (tmsEdgeMono ct) (strat (tmsStrata ct) r) j lt k' pk
      ownNone : (k' : Nat) -> Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) k' ->
                rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) = False
      ownNone k' pk = lcyc_3_1_1__own_reads_none (tmsStrata ct) (rules p) (tmsEdgeMono ct) (tmsNoEmitRead ct) (strat (tmsStrata ct) r) k' pk
      c1 : (j : Nat) -> ((k' : Nat) -> Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) k' -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (tmsStrata ct) j (rules p)) = False) ->
           lcyc_1_1__comp1 p (tmsStrata ct) dom j (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm)
             = lcyc_1_1__comp1 p (tmsStrata ct) dom j wm
      c1 j nrd = lcyc_1_1__comp1_frame_pred p (tmsStrata ct) dom j (Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) wm _ fr nrd
      c2 : (j : Nat) -> ((k' : Nat) -> Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) k' -> rarc_5_6_5__elem k' (lcyc_3_1__read_kinds_of (tmsStrata ct) j (rules p)) = False) ->
           lcyc_1_1__comp2 (tmsStrata ct) j (rules p) (rarc_5_6_5__propagate p (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm) tables)
             = lcyc_1_1__comp2 (tmsStrata ct) j (rules p) tables
      c2 j nrd = lcyc_1_1__comp2_frame_pred p dom wm tables (coreInv inv) (tmsStrata ct) (Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) _ fr j nrd
  in MkFireMeasure
       ( \j, lt => let (e1, e2) = fst (fmProgress fm) j lt in (trans (c1 j (belowNone j lt)) e1, trans (c2 j (belowNone j lt)) e2)
       , case snd (fmProgress fm) of
           Left lt0 => Left (replace {p = \x => LT x (lcyc_1_1__comp1 p (tmsStrata ct) dom (strat (tmsStrata ct) r) wm0)} (sym (c1 (strat (tmsStrata ct) r) ownNone)) lt0)
           Right (e1, e2) => Right (trans (c1 (strat (tmsStrata ct) r) ownNone) e1, trans (c2 (strat (tmsStrata ct) r) ownNone) e2) )
       (\row, e0, lt =>
          replace {p = \m => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (iret_11__from_maybe m) = True}
                  (sym (rarc_5_6_5__table_frame_pred p dom wm tables (coreInv inv) (Lcyc_3_1__emitted_from (tmsStrata ct) (strat (tmsStrata ct) r) (rules p)) _ fr (rrule row)
                          (\q, nq, k', pk => lcyc_3_1__not_read_same (tmsStrata ct) (rules p) (strat (tmsStrata ct) (rrule row)) k'
                                               (belowNone (strat (tmsStrata ct) (rrule row)) lt k' pk) (rrule row) q nq Refl)))
                  (fmBelowLive fm row e0 lt))
       (\row, e0 => let (rule ** (nr, kf)) = fmKind fm row e0
                    in (rule ** (nr, \f, ef, feq => kf f (fst (lcyc_1_1__elem_filter_inv (\g => not (rarc_5_6_5__elem (fid g) (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)))) wm ef)) feq)))

--@derives [LCYC.3.1.1]
||| One cascade phase keeps the measure data.
export
lcyc_3_1_1__phase_measure : (p : Lcyc_3_2_1__program) -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) -> (r : Nat) ->
                            (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                            (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                            Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows0 ->
                            (wm' : Rarc_5_6_4__wm) -> (tables' : List (List Iret_11__tok)) -> (rows' : Iret_12_4__table) ->
                            iret_12_2__phase_step p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows' ->
                            Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm' tables' rows0
lcyc_3_1_1__phase_measure p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm wm' tables' rows' eq =
  case iret_12_2__phase_gone_shape p wm tables rows wm' tables' rows' eq of
    Left (we, te) => replace {p = \w => Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 w tables' rows0} (sym we)
                       (replace {p = \t => Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm t rows0} (sym te) fm)
    Right (we, te) => replace {p = \w => Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 w tables' rows0} (sym we)
                        (replace {p = \t => Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 (iret_12_2__retract_ids (iret_12_2__zeroed (iret_12_2__ended (MkState wm tables) rows) (iret_12_2__kept (MkState wm tables) rows)) wm) t rows0} (sym te)
                           (lcyc_3_1_1__retract_measure p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm))

--@derives [LCYC.3.1.1]
||| And so does any number of phases, alongside the cascade invariant and
||| the tracked activation.
export
lcyc_3_1_1__phase_n_measure : (n : Nat) -> (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) -> (r : Nat) ->
                              (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) -> (rows0 : Iret_12_4__table) -> (live0 : List Nat) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12_2__cascade_inv p dom rows0 live0 wm tables rows -> (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v ->
                              Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows0 ->
                              (wm' ** (tables' ** (rows' **
                                ( iret_12_2__phase_n n p (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                                , Iret_12_2__cascade_inv p dom rows0 live0 wm' tables' rows'
                                , Iret_7_8__tracked p wm' tables' v
                                , Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm' tables' rows0 ))))
lcyc_3_1_1__phase_n_measure Z p pos ct dom r wm0 tables0 rows0 live0 wm tables rows inv v tr fm = (wm ** (tables ** (rows ** (Refl, inv, tr, fm))))
lcyc_3_1_1__phase_n_measure (S n) p pos ct dom r wm0 tables0 rows0 live0 wm tables rows inv v tr fm =
  case iret_12_2__phase_preserves p pos dom rows0 live0 wm tables rows inv of
    (wm1 ** (tables1 ** (rows1 ** (eq, inv1)))) =>
      case lcyc_3_1_1__phase_n_measure n p pos ct dom r wm0 tables0 rows0 live0 wm1 tables1 rows1 inv1 v
             (iret_12_2__phase_tracked p pos dom rows0 live0 wm tables rows inv v tr wm1 tables1 rows1 eq)
             (lcyc_3_1_1__phase_measure p ct dom r wm0 tables0 rows0 live0 wm tables rows inv fm wm1 tables1 rows1 eq) of
        (wm2 ** (tables2 ** (rows2 ** (eq2, inv2, tr2, fm2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (iret_12_2__phase_n_succ n p (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2, inv2, tr2, fm2))))

--@derives [LCYC.3.1.1]
||| The whole cascade: the bridge's fixpoint, the tracked activation, and
||| the measure data, for the rows the cascade keeps.
export
lcyc_3_1_1__cascade_measure : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) -> (r : Nat) ->
                              (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Lcyc_1_1__inv p dom (MkState wm tables) -> Iret_4_4__unique wm ->
                              ((row : Iret_12_4__row) -> Elem row rows -> iret_7_8__activation_live tables row = True -> Iret_12_4__row_facts p wm row) ->
                              ((row : Iret_12_4__row) -> Elem row rows -> iret_12__all_in (rids row) (iret_11_3__fact_ids wm) = True ->
                                 rarc_5_6_4__is_live (rtarget row) wm = True -> iret_7_8__activation_live tables row = True) ->
                              (v : Iret_12_4__row) -> Iret_7_8__tracked p wm tables v -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows ->
                              (wmF ** (tablesF ** (rowsF **
                                ( iret_12_2__phase p (MkTms (MkState wm tables) rows) = MkTms (MkState wmF tablesF) rowsF
                                , Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wmF tablesF rowsF
                                , iret_12_2__ended (MkState wmF tablesF) rowsF = []
                                , Iret_7_8__tracked p wmF tablesF v
                                , Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wmF tablesF rowsF ))))
lcyc_3_1_1__cascade_measure p pos ct dom r wm0 tables0 wm tables rows cinv uq rf rl v tr fm =
  let inv0 : Iret_12_2__cascade_inv p dom rows (iret_11_3__fact_ids wm) wm tables rows
      inv0 = MkCascadeInv cinv uq (\row, e => e) (\i, e => e) rf (\row, e, al, tl => (e, rl row e al tl))
               (iret_12_2__cascade_sub (iret_12_2__base rows (iret_11_3__fact_ids wm)) (iret_12_4__justifs rows) (iret_11_3__fact_ids wm))
               (iret_12_2__base_row rows (iret_11_3__fact_ids wm))
  in case lcyc_3_1_1__phase_n_measure (S (length rows)) p pos ct dom r wm0 tables0 rows (iret_11_3__fact_ids wm) wm tables rows inv0 v tr fm of
       (wmF ** (tablesF ** (rowsF ** (eq, invF, trF, fmF)))) =>
         (wmF ** (tablesF ** (rowsF **
           ( eq
           , invF
           , replace {p = \x => iret_12_2__ended (core x) (deps x) = []} eq
               (iret_12_2__phase_n_fixed (S (length rows)) p wm tables rows (iret_12__lte_succ_self (length rows)))
           , trF
           , MkFireMeasure (fmProgress fmF) (\row, e, lt => fmBelowLive fmF row (rowsSub invF row e) lt) (\row, e => fmKind fmF row (rowsSub invF row e)) ))))

-- ---------------------------------------------------------------------
-- One action, one firing, one run
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
||| One action with truth maintenance keeps the firing invariant and the
||| measure data: the core action by the core's progress lemma, the record
||| by the emitted kind, the cascade by `lcyc_3_1_1__cascade_measure`.
export
lcyc_3_1_1__action_measure : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                             ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                             (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                             (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                             (a : Lgra_10_1__action) -> Elem a (actions rule) ->
                             (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) ->
                             (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                             Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows ->
                             (wm' ** (tables' ** (rows' **
                               ( rarc_5_6_7__do_action_tms p r tok a (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                               , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                               , Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm' tables' rows' ))))
lcyc_3_1_1__action_measure p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm
  with (rarc_5_6_7__do_action p (tfacts tok) a (MkState wm tables)) proof da
  lcyc_3_1_1__action_measure p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm | (MkState wm1 tables1) =
    let (inv1, shape) = rarc_5_6_7__action_core p dom (lcyc_3_1_1__range_widen p (tmsLits ct) dom litsIn (tmsRange ct)) r rule nr (tfacts tok) bk bd a ea
                          wm tables (runCore (fireRun finv)) (runUniq (fireRun finv)) wm1 tables1 da
    in let (prog1, _) = rarc_5_6_7__action_step p (lcyc_3_1_1__tms_to_core p ct) dom litsIn r rule nr (tfacts tok) bk bd a ea
                          (MkState wm0 tables0) (MkState wm tables) (runCore (fireRun finv)) (fmProgress fm)
    in let uniq1 : Iret_4_4__unique wm1
           uniq1 = case shape of
             Left (we, _) => replace {p = \w => Iret_4_4__unique w} (sym we) (runUniq (fireRun finv))
             Right (sh, _) => shUniq sh
           keeps1 : Iret_4_4__keeps wm wm1
           keeps1 = case shape of
             Left (we, _) => replace {p = \w => Iret_4_4__keeps wm w} (sym we) (\f, e, _ => e)
             Right (sh, _) => shKeeps sh
           adds1 : (g : Lfac_1_7_1__fact) -> Elem g wm1 -> Either (Elem g wm) (rarc_5_6_4__is_live (fid g) wm = False, rarc_5_6_5__elem (fid g) (iret_11_3__ids tok) = False)
           adds1 = case shape of
             Left (we, _) => \g, eg => Left (replace {p = \w => Elem g w} we eg)
             Right (sh, _) => shAdds sh
           te1 : Either (tables1 = tables) (tables1 = rarc_5_6_5__propagate p wm1 tables)
           te1 = case shape of
             Left (_, te) => Left te
             Right (_, te) => Right te
           prog1' : Lcyc_1_1__progress p (lcyc_3_1_1__tms_to_core p ct) dom (strat (tmsStrata ct) r) (MkState wm0 tables0) (MkState wm1 tables1)
           prog1' = replace {p = \s => Lcyc_1_1__progress p (lcyc_3_1_1__tms_to_core p ct) dom (strat (tmsStrata ct) r) (MkState wm0 tables0) s} da prog1
           elemR : (row : Iret_12_4__row) -> Elem row (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) ->
                   Either (Elem row rows) (f : Lfac_1_7_1__fact ** (Elem f wm1, row = MkRow r (iret_11_3__ids tok) (fid f), (k : Nat ** (v : List Lfac_1_7_1__fact -> (Nat, Nat) ** (a = Emit k v, fkind f = k, Not (life p k = Explicit))))))
           elemR row e = iret_10_2__record_elem p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows row e
           belowLive1 : (row : Iret_12_4__row) -> Elem row (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) ->
                        LT (strat (tmsStrata ct) (rrule row)) (strat (tmsStrata ct) r) -> iret_7_8__activation_live tables1 row = True
           belowLive1 row e1 lt = case elemR row e1 of
             Right (f ** (_, eq, _)) => void (succNotLTEpred (replace {p = \x => LT (strat (tmsStrata ct) (rrule x)) (strat (tmsStrata ct) r)} eq lt))
             Left e => case shape of
               Left (_, te) => replace {p = \t => iret_7_8__activation_live t row = True} (sym te) (fmBelowLive fm row e lt)
               Right (sh, te) =>
                 let (k ** (wk, fr)) = shFrame sh
                 in let (q ** (nq, _)) = fmKind fm row e
                 in let notRead : (rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = False)
                        notRead = lcyc_3_1__not_read_below (tmsStrata ct) (rules p) (tmsEdgeMono ct) r rule nr k wk (rrule row) q nq lt
                        nt : (rarc_5_6_5__nth (rrule row) (rarc_5_6_5__propagate p wm1 tables) = rarc_5_6_5__nth (rrule row) tables)
                        nt = rarc_5_6_5__table_frame_pred p dom wm tables (runCore (fireRun finv)) (\k' => k' = k) wm1 fr (rrule row)
                               (\q', nq', k', keq => rewrite lcyc_1_1__just_injective (trans (sym nq') nq) in
                                                     replace {p = \x => rarc_5_6_5__elem x (lcyc_3_2_2__read_kinds q) = False} (sym keq) notRead)
                 in replace {p = \t => iret_7_8__activation_live t row = True} (sym te)
                      (replace {p = \m => rarc_5_6_5__any (\u => (iret_11_3__ids u == rids row) && (fired u && not (blocked u))) (iret_11__from_maybe m) = True}
                               (sym nt) (fmBelowLive fm row e lt))
           kind1 : Iret_12_4__run_kind p wm1 (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)
           kind1 row e1 = case elemR row e1 of
             Left e => let (q ** (nq, kf)) = fmKind fm row e
                       in (q ** (nq, \f, ef, feq => case adds1 f ef of
                             Left efw => kf f efw feq
                             Right (nl, _) => void (lcyc_1_1__bool_not_both _
                                                     (replace {p = \j => rarc_5_6_4__is_live j wm = True} (sym feq) (snd (iret_12__run_row_live p dom wm tables rows (fireRun finv) row e)))
                                                     nl)))
             Right (f' ** (ef', eq, (k ** (v ** (aeq, fk, ne))))) =>
               (rule ** ( replace {p = \x => rarc_5_6_5__nth (rrule x) (rules p) = Just rule} (sym eq) nr
                        , \f, ef, feq =>
                            let feq' : (fid f = fid f')
                                feq' = trans feq (cong rtarget eq)
                                ff' : (f = f')
                                ff' = uniq1 f f' ef ef' feq'
                            in ( replace {p = \x => rarc_5_6_5__elem x (lcyc_3_2_2__emit_kinds rule) = True} (sym (trans (cong fkind ff') fk))
                                   (lcyc_3_2_2__emit_kinds_has rule k v (replace {p = \x => Elem x (actions rule)} aeq ea))
                               , \ex => ne (replace {p = \x => life p x = Explicit} (trans (cong fkind ff') fk) ex) ) ))
    in let (rf1, rl1, tr1) = iret_12_2__cascade_entry p pos dom r (iret_11_3__ids tok) wm tables rows finv wm1 tables1 keeps1 adds1 te1
                               (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows)
                               (\row, e => case elemR row e of
                                  Left e' => Left e'
                                  Right (f ** (_, eq, _)) => Right (fid f ** eq))
    in case lcyc_3_1_1__cascade_measure p pos ct dom r wm0 tables0 wm1 tables1 (iret_10_2__record p r (iret_11_3__ids tok) (tfacts tok) a wm1 rows) inv1 uniq1 rf1 rl1
              (MkRow r (iret_11_3__ids tok) 0) tr1 (MkFireMeasure prog1' belowLive1 kind1) of
         (wmF ** (tablesF ** (rowsF ** (eq, invF, fixedF, trF, fmF)))) =>
           (wmF ** (tablesF ** (rowsF **
             ( eq
             , MkFireInv (MkRunInv (coreInv invF) (uniq invF) (\row, e, act => rowFacts invF row (rowsSub invF row e) act) fixedF) trF
             , fmF ))))

--@derives [LCYC.3.1.1]
||| The whole RHS keeps the firing invariant and the measure data.
export
lcyc_3_1_1__actions_measure : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                              ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                              (r : Nat) -> (rule : Lgra_6_1__rule) -> rarc_5_6_5__nth r (rules p) = Just rule ->
                              (tok : Iret_11__tok) -> lcyc_3_2_2__kinds_of (tfacts tok) = posKinds rule -> All (\f => Elem (lfac_2_5_1__val f) dom) (tfacts tok) ->
                              (as : List Lgra_10_1__action) -> All (\a => Elem a (actions rule)) as ->
                              (wm0 : Rarc_5_6_4__wm) -> (tables0 : List (List Iret_11__tok)) ->
                              (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                              Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm tables rows -> Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm tables rows ->
                              (wm' ** (tables' ** (rows' **
                                ( rarc_5_6_7__do_actions_tms p r tok as (MkTms (MkState wm tables) rows) = MkTms (MkState wm' tables') rows'
                                , Iret_12__fire_inv p dom r (iret_11_3__ids tok) wm' tables' rows'
                                , Lcyc_3_1_1__fire_measure p ct dom r wm0 tables0 wm' tables' rows' ))))
lcyc_3_1_1__actions_measure p pos ct dom litsIn r rule nr tok bk bd [] [] wm0 tables0 wm tables rows finv fm = (wm ** (tables ** (rows ** (Refl, finv, fm))))
lcyc_3_1_1__actions_measure p pos ct dom litsIn r rule nr tok bk bd (a :: as) (ea :: eas) wm0 tables0 wm tables rows finv fm =
  case lcyc_3_1_1__action_measure p pos ct dom litsIn r rule nr tok bk bd a ea wm0 tables0 wm tables rows finv fm of
    (wm1 ** (tables1 ** (rows1 ** (eq, finv1, fm1)))) =>
      case lcyc_3_1_1__actions_measure p pos ct dom litsIn r rule nr tok bk bd as eas wm0 tables0 wm1 tables1 rows1 finv1 fm1 of
        (wm2 ** (tables2 ** (rows2 ** (eq2, finv2, fm2)))) =>
          (wm2 ** (tables2 ** (rows2 ** (trans (rarc_5_6_7__actions_tms_succ p r tok a as (MkTms (MkState wm tables) rows) (MkState wm1 tables1) rows1 eq) eq2, finv2, fm2))))

--@derives [LCYC.1.1]
||| THE STEP. One firing with truth maintenance decreases the measure and
||| keeps the run invariant and the kinds of the rows' targets. The pop
||| takes one from its stratum's pending count, the actions and their
||| cascades touch nothing below the firing stratum and either lower its
||| comp1 or leave both of its components alone.
export
lcyc_1_1__step_tms_decreases : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                                ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                                (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                                Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                                (s' : Iret_12__state) -> iret_11_4__step_tms p (MkTms (MkState wm tables) rows) = Just s' ->
                                ( Lcyc_1_1__lex_lt (lcyc_1_1__measure p (tmsStrata ct) dom (core s')) (lcyc_1_1__measure p (tmsStrata ct) dom (MkState wm tables))
                                , Iret_12__run_inv_s p dom s'
                                , Iret_12_4__run_kind p (core s').wm (deps s') )
lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq with (ldet_5_1__select_next tables) proof sel
  lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | Nothing = absurd eq
  lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | (Just (r, j)) with (rarc_5_6_5__nth r (rules p)) proof nr
    lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | (Just (r, j)) | Nothing = absurd eq
    lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | (Just (r, j)) | (Just rule)
      with (rarc_5_6_5__nth j (iret_11__table_at r tables)) proof ntok
      lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | (Just (r, j)) | (Just rule) | Nothing = absurd eq
      lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk s' eq | (Just (r, j)) | (Just rule) | (Just tok) =
        let (ts ** (t ** (nt, njt, pt))) = ldet_5_1__select_next_pending tables r j sel
        in let njtok : (rarc_5_6_5__nth j ts = Just tok)
               njtok = replace {p = \tbl => rarc_5_6_5__nth j tbl = Just tok} (iret_11__table_at_nth r tables ts nt) ntok
               okTok : Iret_7_4__tok_ok rule dom tok
               okTok = lcyc_1_1__all_lookup (tokOk (runCore rinv) r rule ts nr nt) (lcyc_1_1__nth_elem j ts njtok)
               fm0 : Lcyc_3_1_1__fire_measure p ct dom r wm (idat_6_2_2__mark_fired r j tables) wm (idat_6_2_2__mark_fired r j tables) rows
               fm0 = MkFireMeasure (\j', _ => (Refl, Refl), Right (Refl, Refl))
                       (\row, e, _ => idat_6_2_2__mark_keeps_live r j tables row (fst (iret_12__run_row_live p dom wm tables rows rinv row e)))
                       rk
        in case lcyc_3_1_1__actions_measure p pos ct dom litsIn r rule nr tok (fst okTok) (snd okTok) (actions rule) (lcyc_1_1__all_from_elem (actions rule) (\a, e => e))
                  wm (idat_6_2_2__mark_fired r j tables) wm (idat_6_2_2__mark_fired r j tables) rows
                  (iret_11_4__fire_start p pos dom wm tables rows rinv r j rule nr ts nt tok njtok) fm0 of
             (wm' ** (tables' ** (rows' ** (eq', finv', fm')))) =>
               let stEq : (s' = MkTms (MkState wm' tables') rows')
                   stEq = trans (sym (iret_11_4__just_inj eq)) eq'
                   below : (j' : Nat) -> LT j' (strat (tmsStrata ct) r) ->
                           ( lcyc_1_1__comp1 p (tmsStrata ct) dom j' wm' = lcyc_1_1__comp1 p (tmsStrata ct) dom j' wm
                           , lcyc_1_1__comp2 (tmsStrata ct) j' (rules p) tables' = lcyc_1_1__comp2 (tmsStrata ct) j' (rules p) tables )
                   below j' lt = let (e1, e2) = fst (fmProgress fm') j' lt
                                 in (e1, trans e2 (lcyc_1_1__pop_comp2_other p (tmsStrata ct) (MkState wm tables) r j rule nr j'
                                                    (\x => succNotLTEpred (replace {p = \y => LTE (S j') y} (sym x) lt))))
                   atI : Either (LT (lcyc_1_1__comp1 p (tmsStrata ct) dom (strat (tmsStrata ct) r) wm') (lcyc_1_1__comp1 p (tmsStrata ct) dom (strat (tmsStrata ct) r) wm))
                                ( lcyc_1_1__comp1 p (tmsStrata ct) dom (strat (tmsStrata ct) r) wm' = lcyc_1_1__comp1 p (tmsStrata ct) dom (strat (tmsStrata ct) r) wm
                                , LT (lcyc_1_1__comp2 (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) tables') (lcyc_1_1__comp2 (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) tables) )
                   atI = case snd (fmProgress fm') of
                     Left lt => Left lt
                     Right (e1, e2) => Right (e1, replace {p = \x => LT x (lcyc_1_1__comp2 (tmsStrata ct) (strat (tmsStrata ct) r) (rules p) tables)} (sym e2)
                                                    (lcyc_1_1__pop_comp2_own p (tmsStrata ct) (MkState wm tables) r j rule nr ts nt t njt pt))
               in replace {p = \x => ( Lcyc_1_1__lex_lt (lcyc_1_1__measure p (tmsStrata ct) dom (core x)) (lcyc_1_1__measure p (tmsStrata ct) dom (MkState wm tables))
                                     , Iret_12__run_inv_s p dom x
                                     , Iret_12_4__run_kind p (core x).wm (deps x) )} (sym stEq)
                    ( lcyc_1_1__lex_from p (tmsStrata ct) dom (MkState wm tables) (MkState wm' tables') 0 (count (tmsStrata ct)) (strat (tmsStrata ct) r) LTEZero
                        (tmsInRange ct r rule nr) (\j', _, lt => below j' lt) atI
                    , fireRun finv'
                    , fmKind fm' )

--@derives [LCYC.1.1]
||| A certified positive program quiesces from every invariant-satisfying
||| state, with truth maintenance: well-founded recursion on the measure.
export
lcyc_1_1__quiesces_tms : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) -> (dom : List (Nat, Nat)) ->
                         ((x : (Nat, Nat)) -> Elem x (tmsLits ct) -> Elem x dom) ->
                         (wm : Rarc_5_6_4__wm) -> (tables : List (List Iret_11__tok)) -> (rows : Iret_12_4__table) ->
                         Iret_12__run_inv p dom wm tables rows -> Iret_12_4__run_kind p wm rows ->
                         Accessible Lcyc_1_1__lex_lt (lcyc_1_1__measure p (tmsStrata ct) dom (MkState wm tables)) ->
                         (n : Nat ** iret_11_4__step_n_tms p n (MkTms (MkState wm tables) rows) = Nothing)
lcyc_1_1__quiesces_tms p pos ct dom litsIn wm tables rows rinv rk (Access h) with (iret_11_4__step_tms p (MkTms (MkState wm tables) rows)) proof prf
  lcyc_1_1__quiesces_tms p pos ct dom litsIn wm tables rows rinv rk (Access h) | Nothing = (1 ** rewrite prf in Refl)
  lcyc_1_1__quiesces_tms p pos ct dom litsIn wm tables rows rinv rk (Access h) | (Just (MkTms (MkState wm1 tables1) rows1)) =
    let (dec, rinv1, rk1) = lcyc_1_1__step_tms_decreases p pos ct dom litsIn wm tables rows rinv rk (MkTms (MkState wm1 tables1) rows1) prf
    in let (n ** done) = lcyc_1_1__quiesces_tms p pos ct dom litsIn wm1 tables1 rows1 rinv1 rk1 (h _ dec)
    in (S n ** rewrite prf in done)

--@derives [LCYC.1.1]
--@derives [LCYC.3.1.1]
||| THE THEOREM WITH TRUTH MAINTENANCE. A positive program certified as
||| [LCYC.3.1.1] admits it reaches an empty agenda from every input with
||| unique ids, on the deterministic engine with logical retraction in the
||| loop -- `lcyc_1_1__certified_terminates` re-proved for
||| Rete/FireLoopTms.idr's engine.
export
lcyc_1_1__certified_terminates_tms : (p : Lcyc_3_2_1__program) -> Iret_7_9__positive p -> (ct : Lcyc_3_1_1__certified_tms p) ->
                                     (wm0 : Rarc_5_6_4__wm) -> Iret_4_4__unique wm0 ->
                                     (n : Nat ** iret_11_4__step_n_tms p n (rarc_5_6_5__init_tms p wm0) = Nothing)
lcyc_1_1__certified_terminates_tms p pos ct wm0 uniq =
  lcyc_1_1__quiesces_tms p pos ct (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) (\x, e => lcyc_1_1__elem_append_left e)
    wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p))) []
    (rarc_5_6_5__init_tms_inv p (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) wm0 (lcyc_1_1__init_inv p (lcyc_3_1_1__tms_to_core p ct) wm0) uniq)
    (\row, e => absurd e)
    (lcyc_1_1__lex_acc (lcyc_1_1__measure p (tmsStrata ct) (lcyc_1_1__dom_of (lcyc_3_1_1__tms_to_core p ct) wm0) (MkState wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p))))))

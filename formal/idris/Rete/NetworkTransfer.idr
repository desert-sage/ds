-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE TRANSFER, CLOSED. The network of Rete/Network.idr and the engine of
||| Rete/FireLoop.idr, run on one history from the loaded network and the
||| empty state, agree at every step: one working memory, each rule the
||| lowering of its chain, each table's unblocked tokens the terminal's
||| activations in order and with their flags (RLOW.4.2.1, [IRET.11],
||| [IDAT.6.2.2]). Selection agrees because both pick the first unfired
||| unblocked activation of the lowest rule ([LDET.5.1]); marking agrees
||| because both mark it; the RHS agrees because both run the same actions
||| on the same bound facts against one working memory (RARC.5.6.7);
||| and every change of working memory keeps the agreement
||| (Rete/NetworkTransferAgree.idr). This is the plain pipeline: inputs
||| without Rete/PumpBoundary.idr's TMS phase and without the clock.
||| Rete/NetworkTmsTransfer.idr carries the phase and Rete/NetworkTtl.idr
||| the clock, and it is there that Rete/TmsRun.idr,
||| Lcyc/TmsTermination.idr, Rete/PumpBoundary.idr and Rete/TtlSweep.idr,
||| stated over FireLoop's run, reach the spec's network: what they say
||| of the tables they say of the terminals.
module Rete.NetworkTransfer

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkOrder
import Rete.NetworkOrderKeep
import Rete.NetworkRefraction
import Rete.NetworkCorollaries
import Rete.NetworkAgree
import Rete.NetworkTransferOrder
import Rete.NetworkTransferTable
import Rete.NetworkTransferFlags
import Rete.NetworkTransferAgree
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

-- ---------------------------------------------------------------------
-- Small facts about selection
-- ---------------------------------------------------------------------

--@derives [IRET.11.3.1]
export
iret_11_3_1__pending_true : (t : Iret_11__tok) -> iret_11_3_1__pending_tok t = True -> (blocked t = False, fired t = False)
iret_11_3_1__pending_true t h =
  ( lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_r (not (fired t)) (not (blocked t)) h)
  , lcyc_1_1__not_true_is_false _ (lcyc_1_1__and_true_l (not (fired t)) (not (blocked t)) h) )

--@derives [IRET.11.3.1]
export
iret_11_3_1__pending_of : (t : Iret_11__tok) -> blocked t = False -> fired t = False -> iret_11_3_1__pending_tok t = True
iret_11_3_1__pending_of t nb nf = rewrite nb in rewrite nf in Refl

--@derives [IRET.11.3.1]
export
iret_11_3_1__pending_blocked : (t : Iret_11__tok) -> blocked t = True -> iret_11_3_1__pending_tok t = False
iret_11_3_1__pending_blocked t h with (fired t)
  iret_11_3_1__pending_blocked t h | True = Refl
  iret_11_3_1__pending_blocked t h | False = rewrite h in Refl

--@derives [IRET.11.3.1]
export
iret_11_3_1__pending_fired : (t : Iret_11__tok) -> fired t = True -> iret_11_3_1__pending_tok t = False
iret_11_3_1__pending_fired t h = rewrite h in Refl

--@derives [LDET.5.5]
export
ldet_5_5__first_pending_yes : (t : Iret_11__tok) -> (ts : List Iret_11__tok) -> iret_11_3_1__pending_tok t = True -> ldet_5_5__first_pending (t :: ts) = Just 0
ldet_5_5__first_pending_yes t ts h = rewrite h in Refl

--@derives [LDET.5.5]
export
ldet_5_5__first_pending_no : (t : Iret_11__tok) -> (ts : List Iret_11__tok) -> iret_11_3_1__pending_tok t = False ->
                             ldet_5_5__first_pending (t :: ts) = map S (ldet_5_5__first_pending ts)
ldet_5_5__first_pending_no t ts h = rewrite h in Refl

--@derives [IRET.11.3.1]
export
iret_11_3_1__first_unfired_yes : (a : Iret_8_1__act) -> (rest : List Iret_8_1__act) -> afired a = False -> iret_11_3_1__first_unfired (a :: rest) = Just 0
iret_11_3_1__first_unfired_yes a rest h = rewrite h in Refl

--@derives [IRET.11.3.1]
export
iret_11_3_1__first_unfired_no : (a : Iret_8_1__act) -> (rest : List Iret_8_1__act) -> afired a = True ->
                                iret_11_3_1__first_unfired (a :: rest) = map S (iret_11_3_1__first_unfired rest)
iret_11_3_1__first_unfired_no a rest h = rewrite h in Refl

--@derives [IRET.11.4]
export
iret_11_4__map_S_just : (m : Maybe Nat) -> (j : Nat) -> map S m = Just j -> (j0 ** (m = Just j0, j = S j0))
iret_11_4__map_S_just Nothing j h = absurd h
iret_11_4__map_S_just (Just j0) j h = (j0 ** (Refl, sym (iret_11_4__just_inj h)))

--@derives [IRET.11.3.1]
||| A blocked head leaves the unblocked activations.
export
iret_11_3_1__unblocked_cons_blocked : (t : Iret_11__tok) -> (ts : List Iret_11__tok) -> blocked t = True ->
                                      iret_11_3_1__unblocked_acts (t :: ts) = iret_11_3_1__unblocked_acts ts
iret_11_3_1__unblocked_cons_blocked t ts h = rewrite h in Refl

--@derives [IRET.11.3.1]
||| An unblocked head is the first unblocked activation.
export
iret_11_3_1__unblocked_cons_free : (t : Iret_11__tok) -> (ts : List Iret_11__tok) -> blocked t = False ->
                                   iret_11_3_1__unblocked_acts (t :: ts) = iret_11__to_act t :: iret_11_3_1__unblocked_acts ts
iret_11_3_1__unblocked_cons_free t ts h = rewrite h in Refl

--@derives [IRET.1.7]
export
iret_1_7__nth_some : (i : Nat) -> (xs : List a) -> (ys : List b) -> length ys = length xs -> (x : a) -> rarc_5_6_5__nth i xs = Just x -> (y ** rarc_5_6_5__nth i ys = Just y)
iret_1_7__nth_some i [] ys len x n = absurd n
iret_1_7__nth_some i (x' :: xs) [] len x n = absurd len
iret_1_7__nth_some Z (x' :: xs) (y :: ys) len x n = (y ** Refl)
iret_1_7__nth_some (S i) (x' :: xs) (y :: ys) len x n = iret_1_7__nth_some i xs ys (cong pred len) x n

--@derives [LDET.5.1]
||| Selection, one table at a time: a head table with a pending token
||| is selected at it.
export
ldet_5_1__select_next_yes : (ts : List Iret_11__tok) -> (tss : List (List Iret_11__tok)) -> (j : Nat) ->
                            ldet_5_5__first_pending ts = Just j -> ldet_5_1__select_next (ts :: tss) = Just (0, j)
ldet_5_1__select_next_yes ts tss j h = rewrite h in Refl

--@derives [LDET.5.1]
||| A head table with no pending token and nothing after it selects
||| nothing.
export
ldet_5_1__select_next_none : (ts : List Iret_11__tok) -> (tss : List (List Iret_11__tok)) ->
                             ldet_5_5__first_pending ts = Nothing -> ldet_5_1__select_next tss = Nothing -> ldet_5_1__select_next (ts :: tss) = Nothing
ldet_5_1__select_next_none ts tss h1 h2 = rewrite h1 in rewrite h2 in Refl

--@derives [LDET.5.1]
||| A head table with no pending token is skipped: the selection after
||| it, one ordinal later.
export
ldet_5_1__select_next_skip : (ts : List Iret_11__tok) -> (tss : List (List Iret_11__tok)) -> (r, j : Nat) ->
                             ldet_5_5__first_pending ts = Nothing -> ldet_5_1__select_next tss = Just (r, j) -> ldet_5_1__select_next (ts :: tss) = Just (S r, j)
ldet_5_1__select_next_skip ts tss r j h1 h2 = rewrite h1 in rewrite h2 in Refl

--@derives [IRET.11.1]
||| Selection over the chains, one at a time: a head terminal with an
||| unfired activation is selected at it.
export
iret_11_1__select_yes : (c : Rlow_4_2_1__chain) -> (cs : List Rlow_4_2_1__chain) -> (j : Nat) ->
                        iret_11_3_1__first_unfired (cacts c) = Just j -> iret_11_1__select (c :: cs) = Just (0, j)
iret_11_1__select_yes c cs j h = rewrite h in Refl

--@derives [IRET.11.1]
export
iret_11_1__select_none : (c : Rlow_4_2_1__chain) -> (cs : List Rlow_4_2_1__chain) ->
                         iret_11_3_1__first_unfired (cacts c) = Nothing -> iret_11_1__select cs = Nothing -> iret_11_1__select (c :: cs) = Nothing
iret_11_1__select_none c cs h1 h2 = rewrite h1 in rewrite h2 in Refl

--@derives [IRET.11.1]
export
iret_11_1__select_skip : (c : Rlow_4_2_1__chain) -> (cs : List Rlow_4_2_1__chain) -> (r, j : Nat) ->
                         iret_11_3_1__first_unfired (cacts c) = Nothing -> iret_11_1__select cs = Just (r, j) -> iret_11_1__select (c :: cs) = Just (S r, j)
iret_11_1__select_skip c cs r j h1 h2 = rewrite h1 in rewrite h2 in Refl

-- ---------------------------------------------------------------------
-- Selection agrees, table by table
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [LDET.5.1]
--@derives [IRET.11.3.1]
||| THE FIRST PENDING TOKEN of a table is the first unfired activation
||| among its unblocked tokens: both skip the blocked and the fired.
export
rlow_4_2_1__first_agree : (ts : List Iret_11__tok) ->
                          Either (ldet_5_5__first_pending ts = Nothing, iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts) = Nothing)
                                 (j ** j' ** tok ** ( ldet_5_5__first_pending ts = Just j, rarc_5_6_5__nth j ts = Just tok, blocked tok = False, fired tok = False
                                                    , iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts) = Just j'
                                                    , rarc_5_6_5__nth j' (iret_11_3_1__unblocked_acts ts) = Just (iret_11__to_act tok) ))
rlow_4_2_1__first_agree [] = Left (Refl, Refl)
rlow_4_2_1__first_agree (t :: ts) = case iret_12__bool_split (blocked t) of
  Left bt =>
    let np = ldet_5_5__first_pending_no t ts (iret_11_3_1__pending_blocked t bt)
        nu = iret_11_3_1__unblocked_cons_blocked t ts bt
    in case rlow_4_2_1__first_agree ts of
         Left (fp, fu) => Left (trans np (cong (map S) fp), trans (cong iret_11_3_1__first_unfired nu) fu)
         Right (j ** j' ** tok ** (fp, nt, nb, nf, fu, nt')) =>
           Right (S j ** j' ** tok ** ( trans np (cong (map S) fp), nt, nb, nf
                                       , trans (cong iret_11_3_1__first_unfired nu) fu
                                       , trans (cong (rarc_5_6_5__nth j') nu) nt' ))
  Right bt => case iret_12__bool_split (fired t) of
    Left ft =>
      let np = ldet_5_5__first_pending_no t ts (iret_11_3_1__pending_fired t ft)
          nu = iret_11_3_1__unblocked_cons_free t ts bt
          skip : (iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts (t :: ts)) = map S (iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts)))
          skip = trans (cong iret_11_3_1__first_unfired nu) (iret_11_3_1__first_unfired_no (iret_11__to_act t) _ ft)
      in case rlow_4_2_1__first_agree ts of
           Left (fp, fu) => Left (trans np (cong (map S) fp), trans skip (cong (map S) fu))
           Right (j ** j' ** tok ** (fp, nt, nb, nf, fu, nt')) =>
             Right (S j ** S j' ** tok ** ( trans np (cong (map S) fp), nt, nb, nf
                                           , trans skip (cong (map S) fu)
                                           , trans (cong (rarc_5_6_5__nth (S j')) nu) nt' ))
    Right ft =>
      let nu = iret_11_3_1__unblocked_cons_free t ts bt
      in Right (0 ** 0 ** t ** ( ldet_5_5__first_pending_yes t ts (iret_11_3_1__pending_of t bt ft), Refl, bt, ft
                                , trans (cong iret_11_3_1__first_unfired nu) (iret_11_3_1__first_unfired_yes (iret_11__to_act t) _ ft)
                                , trans (cong (rarc_5_6_5__nth 0) nu) Refl ))

--@derives [RLOW.4.2.1]
--@derives [LDET.5.1]
--@derives [LDET.5.4]
||| SELECTION AGREES: with every table's unblocked tokens its terminal's
||| activations, both engines pick nothing, or the same rule and the same
||| activation.
export
rlow_4_2_1__select_agree : (tss : List (List Iret_11__tok)) -> (cs : List Rlow_4_2_1__chain) -> Rlow_4_2_1__tables_agree tss cs ->
                           Either (ldet_5_1__select_next tss = Nothing, iret_11_1__select cs = Nothing)
                                  (r ** j ** j' ** ts ** c ** tok ** ( ldet_5_1__select_next tss = Just (r, j), iret_11_1__select cs = Just (r, j')
                                                                     , rarc_5_6_5__nth r tss = Just ts, rarc_5_6_5__nth r cs = Just c
                                                                     , rarc_5_6_5__nth j ts = Just tok, blocked tok = False, fired tok = False
                                                                     , rarc_5_6_5__nth j' (cacts c) = Just (iret_11__to_act tok) ))
rlow_4_2_1__select_agree [] [] TANil = Left (Refl, Refl)
rlow_4_2_1__select_agree (ts :: tss) (c :: cs) (TACons eq rest) =
  case rlow_4_2_1__first_agree ts of
    Right (j ** j' ** tok ** (fp, nt, nb, nf, fu, nt')) =>
      Right (0 ** j ** j' ** ts ** c ** tok **
             ( ldet_5_1__select_next_yes ts tss j fp
             , iret_11_1__select_yes c cs j' (replace {p = \z => iret_11_3_1__first_unfired z = Just j'} eq fu)
             , Refl, Refl, nt, nb, nf
             , replace {p = \z => rarc_5_6_5__nth j' z = Just (iret_11__to_act tok)} eq nt' ))
    Left (fp, fu) => case rlow_4_2_1__select_agree tss cs rest of
      Left (sn, sc) => Left ( ldet_5_1__select_next_none ts tss fp sn
                            , iret_11_1__select_none c cs (replace {p = \z => iret_11_3_1__first_unfired z = Nothing} eq fu) sc )
      Right (r ** j ** j' ** ts1 ** c1 ** tok ** (sn, sc, nts, nc, nt, nb, nf, nt')) =>
        Right (S r ** j ** j' ** ts1 ** c1 ** tok **
               ( ldet_5_1__select_next_skip ts tss r j fp sn
               , iret_11_1__select_skip c cs r j' (replace {p = \z => iret_11_3_1__first_unfired z = Nothing} eq fu) sc
               , nts, nc, nt, nb, nf, nt' ))

-- ---------------------------------------------------------------------
-- Marking agrees
-- ---------------------------------------------------------------------

--@derives [IRET.11.3.1]
||| A token that is not pending and not blocked has fired.
export
iret_11_3_1__not_pending_free : (t : Iret_11__tok) -> iret_11_3_1__pending_tok t = False -> blocked t = False -> fired t = True
iret_11_3_1__not_pending_free t np nb = case iret_12__bool_split (fired t) of
  Left ft => ft
  Right ff => absurd (trans (sym (iret_11_3_1__pending_of t nb ff)) np)

--@derives [RLOW.4.2.1]
--@derives [IDAT.6.2.2]
--@derives [IRET.11.3.1]
||| MARKING THE SELECTED TOKEN marks the selected activation.
export
rlow_4_2_1__mark_agree : (ts : List Iret_11__tok) -> (j, j' : Nat) -> ldet_5_5__first_pending ts = Just j ->
                         iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts) = Just j' ->
                         iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at j ts) = idat_6_2_2__mark_acts j' (iret_11_3_1__unblocked_acts ts)
rlow_4_2_1__mark_agree [] j j' fp fu = absurd fp
rlow_4_2_1__mark_agree (t :: ts) j j' fp fu = case iret_12__bool_split (iret_11_3_1__pending_tok t) of
  Left pt =>
    let (nb, nf) = iret_11_3_1__pending_true t pt
    in let j0 : (j = 0)
           j0 = sym (iret_11_4__just_inj (trans (sym (ldet_5_5__first_pending_yes t ts pt)) fp))
           fu' : (iret_11_3_1__first_unfired (iret_11__to_act t :: iret_11_3_1__unblocked_acts ts) = Just j')
           fu' = trans (cong iret_11_3_1__first_unfired (sym (iret_11_3_1__unblocked_cons_free t ts nb))) fu
           j0' : (j' = 0)
           j0' = sym (iret_11_4__just_inj (trans (sym (iret_11_3_1__first_unfired_yes (iret_11__to_act t) _ nf)) fu'))
           base : (iret_11_3_1__unblocked_acts (idat_6_2_2__mark_t t :: ts) = idat_6_2_2__mark_acts 0 (iret_11_3_1__unblocked_acts (t :: ts)))
           base = trans (iret_11_3_1__unblocked_cons_free (idat_6_2_2__mark_t t) ts nb)
                        (sym (cong (idat_6_2_2__mark_acts 0) (iret_11_3_1__unblocked_cons_free t ts nb)))
       in replace {p = \z => iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at z (t :: ts)) = idat_6_2_2__mark_acts j' (iret_11_3_1__unblocked_acts (t :: ts))} (sym j0)
            (replace {p = \z => iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at 0 (t :: ts)) = idat_6_2_2__mark_acts z (iret_11_3_1__unblocked_acts (t :: ts))} (sym j0') base)
  Right pt => case iret_12__bool_split (blocked t) of
    Left bt =>
      let (j0 ** (fp0, jS)) = iret_11_4__map_S_just _ j (trans (sym (ldet_5_5__first_pending_no t ts pt)) fp)
      in let fu' : (iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts) = Just j')
             fu' = trans (cong iret_11_3_1__first_unfired (sym (iret_11_3_1__unblocked_cons_blocked t ts bt))) fu
             base : (iret_11_3_1__unblocked_acts (t :: idat_6_2_2__mark_at j0 ts) = idat_6_2_2__mark_acts j' (iret_11_3_1__unblocked_acts (t :: ts)))
             base = trans (iret_11_3_1__unblocked_cons_blocked t (idat_6_2_2__mark_at j0 ts) bt)
                          (trans (rlow_4_2_1__mark_agree ts j0 j' fp0 fu')
                                 (sym (cong (idat_6_2_2__mark_acts j') (iret_11_3_1__unblocked_cons_blocked t ts bt))))
         in replace {p = \z => iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at z (t :: ts)) = idat_6_2_2__mark_acts j' (iret_11_3_1__unblocked_acts (t :: ts))} (sym jS) base
    Right bt =>
      let ft : (fired t = True)
          ft = iret_11_3_1__not_pending_free t pt bt
      in let (j0 ** (fp0, jS)) = iret_11_4__map_S_just _ j (trans (sym (ldet_5_5__first_pending_no t ts pt)) fp)
      in let fuS : (map S (iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts)) = Just j')
             fuS = trans (sym (iret_11_3_1__first_unfired_no (iret_11__to_act t) _ ft))
                         (trans (cong iret_11_3_1__first_unfired (sym (iret_11_3_1__unblocked_cons_free t ts bt))) fu)
      in let (j0' ** (fu0, jS')) = iret_11_4__map_S_just _ j' fuS
      in let base : (iret_11_3_1__unblocked_acts (t :: idat_6_2_2__mark_at j0 ts) = idat_6_2_2__mark_acts (S j0') (iret_11_3_1__unblocked_acts (t :: ts)))
             base = trans (iret_11_3_1__unblocked_cons_free t (idat_6_2_2__mark_at j0 ts) bt)
                          (trans (cong (iret_11__to_act t ::) (rlow_4_2_1__mark_agree ts j0 j0' fp0 fu0))
                                 (sym (cong (idat_6_2_2__mark_acts (S j0')) (iret_11_3_1__unblocked_cons_free t ts bt))))
         in replace {p = \z => iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at z (t :: ts)) = idat_6_2_2__mark_acts j' (iret_11_3_1__unblocked_acts (t :: ts))} (sym jS)
              (replace {p = \z => iret_11_3_1__unblocked_acts (idat_6_2_2__mark_at (S j0) (t :: ts)) = idat_6_2_2__mark_acts z (iret_11_3_1__unblocked_acts (t :: ts))} (sym jS') base)

--@derives [RLOW.4.2.1]
--@derives [IDAT.6.2.2]
||| Marking the selected token of the selected table marks the selected
||| activation of the selected terminal.
export
rlow_4_2_1__mark_tables_agree : (r, j, j' : Nat) -> (tss : List (List Iret_11__tok)) -> (cs : List Rlow_4_2_1__chain) -> Rlow_4_2_1__tables_agree tss cs ->
                                (ts : List Iret_11__tok) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r tss = Just ts -> rarc_5_6_5__nth r cs = Just c ->
                                ldet_5_5__first_pending ts = Just j -> iret_11_3_1__first_unfired (cacts c) = Just j' ->
                                Rlow_4_2_1__tables_agree (idat_6_2_2__mark_fired r j tss) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') cs)
rlow_4_2_1__mark_tables_agree r j j' [] [] TANil ts c nts nc fp fu = absurd nts
rlow_4_2_1__mark_tables_agree Z j j' (ts0 :: tss) (c0 :: cs) (TACons eq rest) ts c nts nc fp fu =
  let tsEq : (ts0 = ts)
      tsEq = iret_11_4__just_inj nts
      cEq : (c0 = c)
      cEq = iret_11_4__just_inj nc
      fu0 : (iret_11_3_1__first_unfired (iret_11_3_1__unblocked_acts ts0) = Just j')
      fu0 = replace {p = \z => iret_11_3_1__first_unfired z = Just j'} (sym eq)
              (replace {p = \z => iret_11_3_1__first_unfired (cacts z) = Just j'} (sym cEq) fu)
      fp0 : (ldet_5_5__first_pending ts0 = Just j)
      fp0 = replace {p = \z => ldet_5_5__first_pending z = Just j} (sym tsEq) fp
  in TACons (trans (rlow_4_2_1__mark_agree ts0 j j' fp0 fu0) (cong (idat_6_2_2__mark_acts j') eq)) rest
rlow_4_2_1__mark_tables_agree (S r) j j' (ts0 :: tss) (c0 :: cs) (TACons eq rest) ts c nts nc fp fu =
  TACons eq (rlow_4_2_1__mark_tables_agree r j j' tss cs rest ts c nts nc fp fu)

--@derives [RLOW.4.2.1]
||| Marking keeps every rule the lowering of its chain: the nodes and
||| actions do not move.
export
rlow_4_2_1__rules_agree_mark : (alphas : List Iret_6_1__alpha) -> (r, j' : Nat) -> (cs : List Rlow_4_2_1__chain) -> (rs : List Lgra_6_1__rule) ->
                               Rlow_4_2_1__rules_agree alphas cs rs -> Rlow_4_2_1__rules_agree alphas (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') cs) rs
rlow_4_2_1__rules_agree_mark alphas r j' [] [] RANil = RANil
rlow_4_2_1__rules_agree_mark alphas Z j' (c :: cs) (rl :: rs) (RACons sr rest) = RACons sr rest
rlow_4_2_1__rules_agree_mark alphas (S r) j' (c :: cs) (rl :: rs) (RACons sr rest) = RACons sr (rlow_4_2_1__rules_agree_mark alphas r j' cs rs rest)

-- ---------------------------------------------------------------------
-- What a firing does, on each side
-- ---------------------------------------------------------------------

--@derives [IRET.11.4]
||| A firing of the network with nothing selected is no firing.
export
iret_11_4__step_net_quiet : (lc : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) ->
                            iret_11_1__select (nchains (enet eng)) = Nothing -> iret_11_4__step_net lc eng = Nothing
iret_11_4__step_net_quiet lc eng h = rewrite h in Refl

--@derives [IRET.11.4]
||| A firing of the network with an activation selected marks it and
||| runs its chain's actions on its match.
export
iret_11_4__step_net_fires : (lc : Nat -> Lscp_1_3__lifecycle) -> (eng : Iret_19__engine) -> (r, j : Nat) -> (c : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                            iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just c -> rarc_5_6_5__nth j (cacts c) = Just a ->
                            iret_11_4__step_net lc eng = Just (rarc_5_6_7__do_actions_net lc (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng))
iret_11_4__step_net_fires lc eng r j c a s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [IRET.11.4]
||| A firing of FireLoop with nothing selected is no firing.
export
iret_11_4__step_quiet : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (toks : List (List Iret_11__tok)) ->
                        ldet_5_1__select_next toks = Nothing -> iret_11_4__step p (MkState wm toks) = Nothing
iret_11_4__step_quiet p wm toks h = rewrite h in Refl

--@derives [IRET.11.4]
||| A firing of FireLoop with a token selected marks it and runs its
||| rule's actions on its facts.
export
iret_11_4__step_fires : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (toks : List (List Iret_11__tok)) -> (r, j : Nat) -> (rule : Lgra_6_1__rule) -> (tok : Iret_11__tok) ->
                        ldet_5_1__select_next toks = Just (r, j) -> rarc_5_6_5__nth r (rules p) = Just rule -> rarc_5_6_5__nth j (iret_11__table_at r toks) = Just tok ->
                        iret_11_4__step p (MkState wm toks) = Just (rarc_5_6_7__do_actions p (tfacts tok) (actions rule) (MkState wm (idat_6_2_2__mark_fired r j toks)))
iret_11_4__step_fires p wm toks r j rule tok s n1 n2 = rewrite s in rewrite n1 in rewrite n2 in Refl

--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| FIRELOOP'S RUN IS THE ONE FOLD at its step (Rete/RunFold.idr's
||| `iret_11_4__run_by`), by induction on the fuel. The unfoldings below are
||| RunFold's through it and Rete/NetworkRefraction.idr's `iret_11_4__run_net_by`.
export
iret_11_4__run_by_fl : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st : Rarc_5_6_5__state) ->
                       iret_11_4__run p fuel st = iret_11_4__run_by (iret_11_4__step p) fuel st
iret_11_4__run_by_fl p Z st = Refl
iret_11_4__run_by_fl p (S fuel) st with (iret_11_4__step p st)
  iret_11_4__run_by_fl p (S fuel) st | Nothing = Refl
  iret_11_4__run_by_fl p (S fuel) st | (Just st') with (iret_11_4__run_by (iret_11_4__step p) fuel st') proof rr
    iret_11_4__run_by_fl p (S fuel) st | (Just st') | (t, h, n) = rewrite trans (iret_11_4__run_by_fl p fuel st') rr in Refl

--@derives [IRET.11.4]
export
iret_11_4__run_net_quiet : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng : Iret_19__engine) -> iret_11_4__step_net life eng = Nothing ->
                           fst (iret_11_4__run_net life (S fuel) eng) = eng
iret_11_4__run_net_quiet life fuel eng h =
  trans (cong fst (iret_11_4__run_net_by life (S fuel) eng)) (iret_11_4__run_by_fst_nothing (iret_11_4__step_net life) fuel eng h)

--@derives [IRET.11.4]
export
iret_11_4__run_net_fires : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (eng, eng' : Iret_19__engine) -> iret_11_4__step_net life eng = Just eng' ->
                           fst (iret_11_4__run_net life (S fuel) eng) = fst (iret_11_4__run_net life fuel eng')
iret_11_4__run_net_fires life fuel eng eng' h =
  trans (cong fst (iret_11_4__run_net_by life (S fuel) eng))
        (trans (iret_11_4__run_by_fst_just (iret_11_4__step_net life) fuel eng eng' h)
               (cong fst (sym (iret_11_4__run_net_by life fuel eng'))))

--@derives [IRET.11.4]
export
iret_11_4__run_quiet : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st : Rarc_5_6_5__state) -> iret_11_4__step p st = Nothing ->
                       fst (iret_11_4__run p (S fuel) st) = st
iret_11_4__run_quiet p fuel st h =
  trans (cong fst (iret_11_4__run_by_fl p (S fuel) st)) (iret_11_4__run_by_fst_nothing (iret_11_4__step p) fuel st h)

--@derives [IRET.11.4]
export
iret_11_4__run_fires : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (st, st' : Rarc_5_6_5__state) -> iret_11_4__step p st = Just st' ->
                       fst (iret_11_4__run p (S fuel) st) = fst (iret_11_4__run p fuel st')
iret_11_4__run_fires p fuel st st' h =
  trans (cong fst (iret_11_4__run_by_fl p (S fuel) st))
        (trans (iret_11_4__run_by_fst_just (iret_11_4__step p) fuel st st' h)
               (cong fst (sym (iret_11_4__run_by_fl p fuel st'))))

--@derives [RLOW.4.2.1]
||| The rule at an ordinal is the lowering of the chain at it.
export
rlow_4_2_1__rule_at : (alphas : List Iret_6_1__alpha) -> (cs : List Rlow_4_2_1__chain) -> (rs : List Lgra_6_1__rule) -> Rlow_4_2_1__rules_agree alphas cs rs ->
                      (r : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r cs = Just c ->
                      (rule ** (rarc_5_6_5__nth r rs = Just rule, Lgra_6_1__same_rule rule (rlow_4_2_1__rule_of alphas c)))
rlow_4_2_1__rule_at alphas [] [] RANil r c n = absurd n
rlow_4_2_1__rule_at alphas (c0 :: cs) (rl :: rs) (RACons sr rest) Z c n = (rl ** (Refl, replace {p = \z => Lgra_6_1__same_rule rl (rlow_4_2_1__rule_of alphas z)} (iret_11_4__just_inj n) sr))
rlow_4_2_1__rule_at alphas (c0 :: cs) (rl :: rs) (RACons sr rest) (S r) c n = rlow_4_2_1__rule_at alphas cs rs rest r c n

-- ---------------------------------------------------------------------
-- Changes of working memory, on each side
-- ---------------------------------------------------------------------

--@derives [IRET.6.4]
export
iret_6_4__dispatch_assert_length : (wm' : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                   length (nchains (iret_6_4__dispatch_assert wm' f is net)) = length (nchains net)
iret_6_4__dispatch_assert_length wm' f [] net = Refl
iret_6_4__dispatch_assert_length wm' f (k :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_6_4__dispatch_assert_length wm' f (k :: is) (MkNetwork alphas chains) | False = iret_6_4__dispatch_assert_length wm' f is (MkNetwork alphas chains)
  iret_6_4__dispatch_assert_length wm' f (k :: is) (MkNetwork alphas chains) | True =
    trans (iret_6_4__dispatch_assert_length wm' f is (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) (map (iret_7_7__activate_chain wm' (rarc_5_6_5__set_at k (iret_6_5__insert f) alphas) k f) chains)))
          (lengthMap chains)

--@derives [IRET.19.2]
export
iret_19_2__dispatch_retract_length : (wm : Rarc_5_6_4__wm) -> (f : Lfac_1_7_1__fact) -> (is : List Nat) -> (net : Rarc_5_3_1__network) ->
                                     length (nchains (iret_19_2__dispatch_retract wm f is net)) = length (nchains net)
iret_19_2__dispatch_retract_length wm f [] net = Refl
iret_19_2__dispatch_retract_length wm f (k :: is) (MkNetwork alphas chains) with (iret_6_4__admits (iret_6_6__alpha_at alphas k) f)
  iret_19_2__dispatch_retract_length wm f (k :: is) (MkNetwork alphas chains) | False = iret_19_2__dispatch_retract_length wm f is (MkNetwork alphas chains)
  iret_19_2__dispatch_retract_length wm f (k :: is) (MkNetwork alphas chains) | True =
    trans (iret_19_2__dispatch_retract_length wm f is (MkNetwork (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) (map (iret_7_7__retract_chain wm (rarc_5_6_5__set_at k (iret_6_5__remove f) alphas) k f) chains)))
          (lengthMap chains)

--@derives [RLOW.4.2.1]
--@derives [IRET.19.1]
||| INSERTING A FRESH FACT keeps the agreement, against FireLoop's one
||| propagation over the grown working memory.
export
rlow_4_2_1__insert_agree : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                           Rlow_4_2_1__agree p wm net toks -> (new : Lfac_1_7_1__fact) -> Not (Elem new wm) -> rarc_5_6_4__is_live (fid new) wm = False ->
                           Rlow_4_2_1__agree p (wm ++ [new]) (enet (iret_19_1__insert new (MkEngine wm net))) (rarc_5_6_5__propagate p (wm ++ [new]) toks)
rlow_4_2_1__insert_agree p wm net toks ag new nf fresh =
  let (ra, ta, ord, (dw, uq, tw)) = ag
      (sa, sh) = iret_6_4__dispatch_assert_shape (wm ++ [new]) new (iret_1_7__indices (length (nalphas net))) net
  in rlow_4_2_1__change_agree p wm net toks ag (wm ++ [new]) (enet (iret_19_1__insert new (MkEngine wm net)))
       (iret_19_1__insert_ordered new (MkEngine wm net) nf ord)
       (rarc_5_6_5__well_grow p wm dw uq wm dw uq (\g, e => e) (\s, t, _, _, _, _ => Refl) new fresh toks tw)
       sa (iret_6_4__dispatch_assert_length (wm ++ [new]) new (iret_1_7__indices (length (nalphas net))) net) sh
       (\i, c, c', n, n' =>
          let (p1, p2) = iret_19_1__insert_flags new (MkEngine wm net) nf (fst ord) i c c' n n'
          in (\a', e => case p1 a' e of
                          Left x => Left x
                          Right (_, y) => Right y, p2))

--@derives [RLOW.4.2.1]
--@derives [IRET.19.2]
||| RETRACTING A LIVE FACT keeps the agreement, against FireLoop's one
||| propagation over the shrunk working memory.
export
rlow_4_2_1__retract_agree : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                            Rlow_4_2_1__agree p wm net toks -> (f : Lfac_1_7_1__fact) -> Elem f wm ->
                            Rlow_4_2_1__agree p (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net))) (rarc_5_6_5__propagate p (rarc_5_6_4__remove_exact f wm) toks)
rlow_4_2_1__retract_agree p wm net toks ag f ef =
  let (ra, ta, ord, (dw, uq, tw)) = ag
      (sa, sh) = iret_19_2__dispatch_retract_shape wm f (iret_1_7__indices (length (nalphas net))) net
  in rlow_4_2_1__change_agree p wm net toks ag (rarc_5_6_4__remove_exact f wm) (enet (iret_19_2__retract f (MkEngine wm net)))
       (iret_19_2__retract_ordered f (MkEngine wm net) ef ord)
       (rarc_5_6_5__well_shrink p wm dw uq f ef toks tw)
       sa (iret_19_2__dispatch_retract_length wm f (iret_1_7__indices (length (nalphas net))) net) sh
       (\i, c, c', n, n' => iret_19_2__retract_flags f (MkEngine wm net) ef (fst ord) i c c' n n')

--@derives [RLOW.4.2.1]
--@derives [LFAC.2.5.3]
||| REPLACING AN ENTITY -- the retraction of the old fact then the
||| insertion of the fresh one on the network, one propagation over the
||| result on FireLoop -- keeps the agreement.
export
rlow_4_2_1__replace_agree : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                            Rlow_4_2_1__agree p wm net toks -> (old : Lfac_1_7_1__fact) -> Elem old wm ->
                            (new : Lfac_1_7_1__fact) -> Not (Elem new wm) -> rarc_5_6_4__is_live (fid new) wm = False ->
                            Rlow_4_2_1__agree p (rarc_5_6_4__remove_exact old wm ++ [new])
                                              (enet (iret_19_1__insert new (iret_19_2__retract old (MkEngine wm net))))
                                              (rarc_5_6_5__propagate p (rarc_5_6_4__remove_exact old wm ++ [new]) toks)
rlow_4_2_1__replace_agree p wm net toks ag old eo new nf fresh =
  let (ra, ta, ord, (dw, uq, tw)) = ag
  in let net1 : Rarc_5_3_1__network
         net1 = enet (iret_19_2__retract old (MkEngine wm net))
         nf1 : Not (Elem new (rarc_5_6_4__remove_exact old wm))
         nf1 = \e => nf (fst (rarc_5_6_4__remove_exact_elem_inv old wm new e))
         ord1 : Ldet_5_9__ordered (iret_19_2__retract old (MkEngine wm net))
         ord1 = iret_19_2__retract_ordered old (MkEngine wm net) eo ord
  in let (sa1, sh1) = iret_19_2__dispatch_retract_shape wm old (iret_1_7__indices (length (nalphas net))) net
  in let (sa2, sh2) = iret_6_4__dispatch_assert_shape (rarc_5_6_4__remove_exact old wm ++ [new]) new (iret_1_7__indices (length (nalphas net1))) net1
  in let len1 : (length (nchains net1) = length (nchains net))
         len1 = iret_19_2__dispatch_retract_length wm old (iret_1_7__indices (length (nalphas net))) net
         len2 : (length (nchains (enet (iret_19_1__insert new (iret_19_2__retract old (MkEngine wm net))))) = length (nchains net1))
         len2 = iret_6_4__dispatch_assert_length (rarc_5_6_4__remove_exact old wm ++ [new]) new (iret_1_7__indices (length (nalphas net1))) net1
         liveOld : (i : Nat) -> (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth i (nchains net) = Just c -> Ldet_5_5__live_acts wm (cacts c)
         liveOld = \i, c, n => lcyc_1_1__all_lookup (ldet_5_5__view_live_acts (MkEngine wm net) (fst ord)) (lcyc_1_1__nth_elem i (nchains net) n)
  in rlow_4_2_1__change_agree p wm net toks ag (rarc_5_6_4__remove_exact old wm ++ [new]) (enet (iret_19_1__insert new (iret_19_2__retract old (MkEngine wm net))))
       (iret_19_1__insert_ordered new (iret_19_2__retract old (MkEngine wm net)) nf1 ord1)
       (rarc_5_6_5__well_grow p wm dw uq (rarc_5_6_4__remove_exact old wm) (iret_11_3__distinct_filter _ wm dw) (iret_4_4__unique_filter wm uq _)
          (\g, e => fst (rarc_5_6_4__remove_exact_elem_inv old wm g e))
          (\s, t, ls, lt, ls', lt' => ldet_5_9__before_remove wm dw old eo s t ls lt
              (\e => snd (rarc_5_6_4__remove_exact_elem_inv old wm old (lcyc_1_1__all_lookup ls' e)) Refl)
              (\e => snd (rarc_5_6_4__remove_exact_elem_inv old wm old (lcyc_1_1__all_lookup lt' e)) Refl))
          new fresh toks tw)
       (iret_6_1__same_alphas_trans _ _ _ sa1 sa2)
       (trans len2 len1)
       (\i, c, c2, n, n2 =>
          let (c1 ** n1) = iret_1_7__nth_some i (nchains net) (nchains net1) len1 c n
              (s1, a1) = sh1 i c c1 n n1
              (s2, a2) = sh2 i c1 c2 n1 n2
          in (rlow_4_2_1__same_shape_trans _ _ _ s1 s2, trans a2 a1))
       (\i, c, c2, n, n2 =>
          let (c1 ** n1) = iret_1_7__nth_some i (nchains net) (nchains net1) len1 c n
              (p1r, p2r) = iret_19_2__retract_flags old (MkEngine wm net) eo (fst ord) i c c1 n n1
              (p1i, p2i) = iret_19_1__insert_flags new (iret_19_2__retract old (MkEngine wm net)) nf1 (fst ord1) i c1 c2 n1 n2
          in ( \a', e => case p1i a' e of
                 Left e1 => p1r a' e1
                 Right (_, u) => Right u
             , \a, ea, et =>
                 let (a'' ** (ea'', teq)) = lcyc_1_1__elem_map_inv atuple (cacts c2) et
                 in case p1i a'' ea'' of
                      Left e1 => p2i a (p2r a ea (replace {p = \z => Elem z (iret_8_1__tuples (cacts c1))} teq (lcyc_1_1__elem_map_fwd atuple e1))) et
                      Right (hasNew, _) => void (nf (lcyc_1_1__all_lookup (lcyc_1_1__all_lookup (liveOld i c n) ea) (replace {p = \z => Elem new z} teq hasNew))) ))

--@spec [IRET.19.1]
--@spec [RARC.5.6.4]
||| FireLoop's assert under the kind's lifecycle, then one propagation
||| when working memory changed: what `rarc_5_6_7__do_action`'s Emit and
||| `rarc_5_6_4__apply_plain`'s Assert both do, named so that a
||| statement can mention it (a case block restated in a type is never
||| the definition's).
public export
iret_19_1__assert_state : Lcyc_3_2_1__program -> List Nat -> Nat -> Nat -> Nat -> Rarc_5_6_4__wm -> List (List Iret_11__tok) -> Rarc_5_6_5__state
iret_19_1__assert_state p avoid k key pay wm toks = case iret_19_1__assert_fact (life p k) avoid k key pay wm of
  Nothing => MkState wm toks
  Just w  => MkState w (rarc_5_6_5__propagate p w toks)

--@derives [RLOW.4.2.1]
--@derives [IRET.19.1]
||| ASSERT UNDER THE LIFECYCLE keeps the agreement: the network's assert
||| and FireLoop's assert-then-propagate decide alike on the same
||| working memory.
export
rlow_4_2_1__assert_agree : (p : Lcyc_3_2_1__program) -> (avoid : List Nat) -> (k, key, pay : Nat) ->
                           (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> Rlow_4_2_1__agree p wm net toks ->
                           (wm' ** net' ** toks' ** ( iret_19_1__assert (life p) avoid k key pay (MkEngine wm net) = MkEngine wm' net'
                                                    , iret_19_1__assert_state p avoid k key pay wm toks = MkState wm' toks'
                                                    , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag with (life p k)
  rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Explicit =
    ((wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) ** _ ** _ **
     (Refl, Refl, rlow_4_2_1__insert_agree p wm net toks ag _ (lfac_2_5_3__fresh_not_elem avoid wm k key pay) (fst (lfac_2_5_3__fresh_id_free avoid wm))))
  rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Relation with (iret_19_1__find_relation k key pay wm)
    rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Relation | (Just _) = (wm ** net ** toks ** (Refl, Refl, ag))
    rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Relation | Nothing =
      ((wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) ** _ ** _ **
       (Refl, Refl, rlow_4_2_1__insert_agree p wm net toks ag _ (lfac_2_5_3__fresh_not_elem avoid wm k key pay) (fst (lfac_2_5_3__fresh_id_free avoid wm))))
  rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Entity with (iret_19_1__find_entity k key wm) proof fe
    rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Entity | Nothing =
      ((wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) ** _ ** _ **
       (Refl, Refl, rlow_4_2_1__insert_agree p wm net toks ag _ (lfac_2_5_3__fresh_not_elem avoid wm k key pay) (fst (lfac_2_5_3__fresh_id_free avoid wm))))
    rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Entity | (Just old) with (fpay old == pay)
      rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Entity | (Just old) | True = (wm ** net ** toks ** (Refl, Refl, ag))
      rlow_4_2_1__assert_agree p avoid k key pay wm net toks ag | Entity | (Just old) | False =
        ((rarc_5_6_4__remove_exact old wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay]) ** _ ** _ **
         (Refl, Refl, rlow_4_2_1__replace_agree p wm net toks ag old (snd (lcyc_1_1__find_just _ wm fe)) _
                        (lfac_2_5_3__fresh_not_elem avoid wm k key pay) (fst (lfac_2_5_3__fresh_id_free avoid wm))))

--@derives [RARC.5.6.7]
||| The Emit action is the named assert-then-propagate on its bound
||| facts.
export
rarc_5_6_7__do_action_emit : (p : Lcyc_3_2_1__program) -> (bound : List Lfac_1_7_1__fact) -> (k : Nat) -> (value : List Lfac_1_7_1__fact -> (Nat, Nat)) ->
                             (wm : Rarc_5_6_4__wm) -> (toks : List (List Iret_11__tok)) ->
                             rarc_5_6_7__do_action p bound (Emit k value) (MkState wm toks) =
                               iret_19_1__assert_state p (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) wm toks
rarc_5_6_7__do_action_emit p bound k value wm toks with (iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) wm)
  rarc_5_6_7__do_action_emit p bound k value wm toks | Nothing = Refl
  rarc_5_6_7__do_action_emit p bound k value wm toks | (Just w) = Refl

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
||| ONE RHS ACTION keeps the agreement.
export
rlow_4_2_1__do_action_agree : (p : Lcyc_3_2_1__program) -> (bound : List Lfac_1_7_1__fact) -> (a : Lgra_10_1__action) ->
                              (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> Rlow_4_2_1__agree p wm net toks ->
                              (wm' ** net' ** toks' ** ( rarc_5_6_7__do_action_net (life p) bound a (MkEngine wm net) = MkEngine wm' net'
                                                       , rarc_5_6_7__do_action p bound a (MkState wm toks) = MkState wm' toks'
                                                       , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__do_action_agree p bound (Emit k value) wm net toks ag =
  let (wm' ** net' ** toks' ** (en, es, ag')) = rlow_4_2_1__assert_agree p (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) wm net toks ag
  in (wm' ** net' ** toks' ** (en, trans (rarc_5_6_7__do_action_emit p bound k value wm toks) es, ag'))
rlow_4_2_1__do_action_agree p bound (Withdraw i) wm net toks ag with (rarc_5_6_5__nth i bound)
  rlow_4_2_1__do_action_agree p bound (Withdraw i) wm net toks ag | Nothing = (wm ** net ** toks ** (Refl, Refl, ag))
  rlow_4_2_1__do_action_agree p bound (Withdraw i) wm net toks ag | (Just f) with (rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm) proof an
    rlow_4_2_1__do_action_agree p bound (Withdraw i) wm net toks ag | (Just f) | True =
      (rarc_5_6_4__remove_exact f wm ** _ ** _ ** (Refl, Refl, rlow_4_2_1__retract_agree p wm net toks ag f (lscp_2_1_1__any_same_elem f wm an)))
    rlow_4_2_1__do_action_agree p bound (Withdraw i) wm net toks ag | (Just f) | False = (wm ** net ** toks ** (Refl, Refl, ag))

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.7]
||| THE RHS keeps the agreement.
export
rlow_4_2_1__do_actions_agree : (p : Lcyc_3_2_1__program) -> (bound : List Lfac_1_7_1__fact) -> (as : List Lgra_10_1__action) ->
                               (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) -> Rlow_4_2_1__agree p wm net toks ->
                               (wm' ** net' ** toks' ** ( rarc_5_6_7__do_actions_net (life p) bound as (MkEngine wm net) = MkEngine wm' net'
                                                        , rarc_5_6_7__do_actions p bound as (MkState wm toks) = MkState wm' toks'
                                                        , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__do_actions_agree p bound [] wm net toks ag = (wm ** net ** toks ** (Refl, Refl, ag))
rlow_4_2_1__do_actions_agree p bound (a :: as) wm net toks ag =
  let (wm1 ** net1 ** toks1 ** (e1, s1, ag1)) = rlow_4_2_1__do_action_agree p bound a wm net toks ag
      (wm2 ** net2 ** toks2 ** (e2, s2, ag2)) = rlow_4_2_1__do_actions_agree p bound as wm1 net1 toks1 ag1
  in (wm2 ** net2 ** toks2 ** ( trans (cong (rarc_5_6_7__do_actions_net (life p) bound as) e1) e2
                              , trans (cong (rarc_5_6_7__do_actions p bound as) s1) s2
                              , ag2 ))

-- ---------------------------------------------------------------------
-- One firing, a run, an input, a history
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [LDET.5.1]
||| The selection's token is the table's first pending one.
export
rlow_4_2_1__first_of_select : (tss : List (List Iret_11__tok)) -> (r, j : Nat) -> ldet_5_1__select_next tss = Just (r, j) ->
                              (ts : List Iret_11__tok) -> rarc_5_6_5__nth r tss = Just ts -> ldet_5_5__first_pending ts = Just j
rlow_4_2_1__first_of_select [] r j s ts n = absurd s
rlow_4_2_1__first_of_select (t0 :: tss) r j s ts n with (ldet_5_5__first_pending t0) proof fp
  rlow_4_2_1__first_of_select (t0 :: tss) r j s ts n | (Just j0) =
    let rj : ((0, j0) = (r, j))
        rj = iret_11_4__just_inj s
    in rewrite sym (iret_11_4__just_inj (replace {p = \z => rarc_5_6_5__nth z (t0 :: tss) = Just ts} (sym (cong fst rj)) n)) in
       rewrite sym (cong snd rj) in fp
  rlow_4_2_1__first_of_select (t0 :: tss) r j s ts n | Nothing with (ldet_5_1__select_next tss) proof s2
    rlow_4_2_1__first_of_select (t0 :: tss) r j s ts n | Nothing | Nothing = absurd s
    rlow_4_2_1__first_of_select (t0 :: tss) r j s ts n | Nothing | (Just (r2, j2)) =
      let rj : ((S r2, j2) = (r, j))
          rj = iret_11_4__just_inj s
          h : (ldet_5_5__first_pending ts = Just j2)
          h = rlow_4_2_1__first_of_select tss r2 j2 s2 ts (replace {p = \z => rarc_5_6_5__nth z (t0 :: tss) = Just ts} (sym (cong fst rj)) n)
      in replace {p = \z => ldet_5_5__first_pending ts = Just z} (cong snd rj) h

--@derives [RLOW.4.2.1]
--@derives [LDET.5.1]
||| The selection's activation is the terminal's first unfired one.
export
rlow_4_2_1__first_of_net : (cs : List Rlow_4_2_1__chain) -> (r, j' : Nat) -> iret_11_1__select cs = Just (r, j') ->
                           (c : Rlow_4_2_1__chain) -> rarc_5_6_5__nth r cs = Just c -> iret_11_3_1__first_unfired (cacts c) = Just j'
rlow_4_2_1__first_of_net [] r j' s c n = absurd s
rlow_4_2_1__first_of_net (c0 :: cs) r j' s c n with (iret_11_3_1__first_unfired (cacts c0)) proof fu
  rlow_4_2_1__first_of_net (c0 :: cs) r j' s c n | (Just j0) =
    let rj : ((0, j0) = (r, j'))
        rj = iret_11_4__just_inj s
    in rewrite sym (iret_11_4__just_inj (replace {p = \z => rarc_5_6_5__nth z (c0 :: cs) = Just c} (sym (cong fst rj)) n)) in
       rewrite sym (cong snd rj) in fu
  rlow_4_2_1__first_of_net (c0 :: cs) r j' s c n | Nothing with (iret_11_1__select cs) proof s2
    rlow_4_2_1__first_of_net (c0 :: cs) r j' s c n | Nothing | Nothing = absurd s
    rlow_4_2_1__first_of_net (c0 :: cs) r j' s c n | Nothing | (Just (r2, j2)) =
      let rj : ((S r2, j2) = (r, j'))
          rj = iret_11_4__just_inj s
          h : (iret_11_3_1__first_unfired (cacts c) = Just j2)
          h = rlow_4_2_1__first_of_net cs r2 j2 s2 c (replace {p = \z => rarc_5_6_5__nth z (c0 :: cs) = Just c} (sym (cong fst rj)) n)
      in replace {p = \z => iret_11_3_1__first_unfired (cacts c) = Just z} (cong snd rj) h

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
||| A FIRING AGREES: with the same activation of the same rule selected
||| on both sides, both mark it, both run the rule's actions on its
||| facts, and the results agree.
export
rlow_4_2_1__step_fire : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                        Rlow_4_2_1__agree p wm net toks ->
                        (r, j, j' : Nat) -> (ts : List Iret_11__tok) -> (c : Rlow_4_2_1__chain) -> (tok : Iret_11__tok) ->
                        ldet_5_1__select_next toks = Just (r, j) -> iret_11_1__select (nchains net) = Just (r, j') ->
                        rarc_5_6_5__nth r toks = Just ts -> rarc_5_6_5__nth r (nchains net) = Just c ->
                        rarc_5_6_5__nth j ts = Just tok -> rarc_5_6_5__nth j' (cacts c) = Just (iret_11__to_act tok) ->
                        (wm' ** net' ** toks' ** ( iret_11_4__step_net (life p) (MkEngine wm net) = Just (MkEngine wm' net')
                                                 , iret_11_4__step p (MkState wm toks) = Just (MkState wm' toks')
                                                 , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__step_fire p wm net toks ag r j j' ts c tok sn sc nts nc nt na =
  let (ra, ta, ord, well) = ag
  in let (rule ** (nr, sr)) = rlow_4_2_1__rule_at (nalphas net) (nchains net) (rules p) ra r c nc
  in let acEq : (actions (rlow_4_2_1__rule_of (nalphas net) c) = actions rule)
         acEq = snd (snd (snd sr))
         net1 : Rarc_5_3_1__network
         net1 = MkNetwork (nalphas net) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j') (nchains net))
         marked : Rlow_4_2_1__agree p wm net1 (idat_6_2_2__mark_fired r j toks)
         marked = ( rlow_4_2_1__rules_agree_mark (nalphas net) r j' (nchains net) (rules p) ra
                  , rlow_4_2_1__mark_tables_agree r j j' toks (nchains net) ta ts c nts nc
                      (rlow_4_2_1__first_of_select toks r j sn ts nts) (rlow_4_2_1__first_of_net (nchains net) r j' sc c nc)
                  , idat_6_2_2__mark_net_ordered r j' (MkEngine wm net) ord
                  , (fst well, fst (snd well), idat_6_2_2__mark_tables_well wm r j (rules p) toks (snd (snd well))) )
  in let (wm2 ** net2 ** toks2 ** (e2, s2, ag2)) =
           rlow_4_2_1__do_actions_agree p (tfacts tok) (cactions c) wm net1 (idat_6_2_2__mark_fired r j toks) marked
  in let stepN : (iret_11_4__step_net (life p) (MkEngine wm net) = Just (MkEngine wm2 net2))
         stepN = trans (iret_11_4__step_net_fires (life p) (MkEngine wm net) r j' c (iret_11__to_act tok) sc nc na) (cong Just e2)
         stepF : (iret_11_4__step p (MkState wm toks) = Just (MkState wm2 toks2))
         stepF = trans (iret_11_4__step_fires p wm toks r j rule tok sn nr
                          (replace {p = \z => rarc_5_6_5__nth j z = Just tok} (sym (iret_11__table_at_nth r toks ts nts)) nt))
                       (cong Just (trans (cong (\acts => rarc_5_6_7__do_actions p (tfacts tok) acts (MkState wm (idat_6_2_2__mark_fired r j toks))) (sym acEq)) s2))
     in (wm2 ** net2 ** toks2 ** (stepN, stepF, ag2))

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
--@derives [LDET.5.1]
||| ONE FIRING AGREES: both engines stop, or both fire the same
||| activation of the same rule and agree afterwards.
export
rlow_4_2_1__step_agree : (p : Lcyc_3_2_1__program) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                         Rlow_4_2_1__agree p wm net toks ->
                         Either (iret_11_4__step_net (life p) (MkEngine wm net) = Nothing, iret_11_4__step p (MkState wm toks) = Nothing)
                                (wm' ** net' ** toks' ** ( iret_11_4__step_net (life p) (MkEngine wm net) = Just (MkEngine wm' net')
                                                         , iret_11_4__step p (MkState wm toks) = Just (MkState wm' toks')
                                                         , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__step_agree p wm net toks ag =
  let (ra, ta, ord, well) = ag
  in case rlow_4_2_1__select_agree toks (nchains net) ta of
       Left (sn, sc) => Left (iret_11_4__step_net_quiet (life p) (MkEngine wm net) sc, iret_11_4__step_quiet p wm toks sn)
       Right (r ** j ** j' ** ts ** c ** tok ** (sn, sc, nts, nc, nt, nb, nf, na)) =>
         Right (rlow_4_2_1__step_fire p wm net toks ag r j j' ts c tok sn sc nts nc nt na)

--@derives [RLOW.4.2.1]
--@derives [IRET.11.4]
--@derives [IRET.11.5]
||| A RUN AGREES, under any fuel.
export
rlow_4_2_1__run_agree : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                        Rlow_4_2_1__agree p wm net toks ->
                        (wm' ** net' ** toks' ** ( fst (iret_11_4__run_net (life p) fuel (MkEngine wm net)) = MkEngine wm' net'
                                                 , fst (iret_11_4__run p fuel (MkState wm toks)) = MkState wm' toks'
                                                 , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__run_agree p Z wm net toks ag = (wm ** net ** toks ** (Refl, Refl, ag))
rlow_4_2_1__run_agree p (S fuel) wm net toks ag = case rlow_4_2_1__step_agree p wm net toks ag of
  Left (qn, qf) => (wm ** net ** toks ** (iret_11_4__run_net_quiet (life p) fuel (MkEngine wm net) qn, iret_11_4__run_quiet p fuel (MkState wm toks) qf, ag))
  Right (wm1 ** net1 ** toks1 ** (sn, sf, ag1)) =>
    let (wm2 ** net2 ** toks2 ** (rn, rf, ag2)) = rlow_4_2_1__run_agree p fuel wm1 net1 toks1 ag1
    in (wm2 ** net2 ** toks2 ** ( trans (iret_11_4__run_net_fires (life p) fuel (MkEngine wm net) (MkEngine wm1 net1) sn) rn
                                , trans (iret_11_4__run_fires p fuel (MkState wm toks) (MkState wm1 toks1) sf) rf
                                , ag2 ))

--@derives [RARC.5.6.4]
||| An asserted input is the named assert-then-propagate with nothing
||| to avoid.
export
rarc_5_6_4__apply_plain_assert : (p : Lcyc_3_2_1__program) -> (k, key, pay : Nat) -> (wm : Rarc_5_6_4__wm) -> (toks : List (List Iret_11__tok)) ->
                                 rarc_5_6_4__apply_plain p (Assert k key pay) (MkState wm toks) = iret_19_1__assert_state p [] k key pay wm toks
rarc_5_6_4__apply_plain_assert p k key pay wm toks with (iret_19_1__assert_fact (life p k) [] k key pay wm)
  rarc_5_6_4__apply_plain_assert p k key pay wm toks | Nothing = Refl
  rarc_5_6_4__apply_plain_assert p k key pay wm toks | (Just w) = Refl

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.4]
||| AN INPUT AGREES.
export
rlow_4_2_1__apply_agree : (p : Lcyc_3_2_1__program) -> (ev : Rarc_5_6_1__event) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                          Rlow_4_2_1__agree p wm net toks ->
                          (wm' ** net' ** toks' ** ( rarc_5_6_4__apply_net (life p) ev (MkEngine wm net) = MkEngine wm' net'
                                                   , rarc_5_6_4__apply_plain p ev (MkState wm toks) = MkState wm' toks'
                                                   , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__apply_agree p (Assert k key pay) wm net toks ag =
  let (wm' ** net' ** toks' ** (en, es, ag')) = rlow_4_2_1__assert_agree p [] k key pay wm net toks ag
  in (wm' ** net' ** toks' ** (en, trans (rarc_5_6_4__apply_plain_assert p k key pay wm toks) es, ag'))
rlow_4_2_1__apply_agree p (Retract i) wm net toks ag with (rarc_5_6_4__lookup_fact i wm) proof lk
  rlow_4_2_1__apply_agree p (Retract i) wm net toks ag | Nothing = (wm ** net ** toks ** (Refl, Refl, ag))
  rlow_4_2_1__apply_agree p (Retract i) wm net toks ag | (Just f) =
    (rarc_5_6_4__remove_exact f wm ** _ ** _ ** (Refl, Refl, rlow_4_2_1__retract_agree p wm net toks ag f (fst (rarc_5_6_4__lookup_elem i wm f lk))))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| AN INPUT PUMPED agrees.
export
rlow_4_2_1__boundary_agree : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (ev : Rarc_5_6_1__event) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                             Rlow_4_2_1__agree p wm net toks ->
                             (wm' ** net' ** toks' ** ( lfst_9_2_1__boundary_net (life p) fuel ev (MkEngine wm net) = MkEngine wm' net'
                                                      , lfst_9_2_1__boundary_plain p fuel ev (MkState wm toks) = MkState wm' toks'
                                                      , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__boundary_agree p fuel ev wm net toks ag =
  let (wm1 ** net1 ** toks1 ** (e1, s1, ag1)) = rlow_4_2_1__apply_agree p ev wm net toks ag
      (wm2 ** net2 ** toks2 ** (e2, s2, ag2)) = rlow_4_2_1__run_agree p fuel wm1 net1 toks1 ag1
  in (wm2 ** net2 ** toks2 ** ( trans (cong (\e => fst (iret_11_4__run_net (life p) fuel e)) e1) e2
                              , trans (cong (\s => fst (iret_11_4__run p fuel s)) s1) s2
                              , ag2 ))

--@derives [RLOW.4.2.1]
--@derives [LFST.9.2.1]
||| EVERY HISTORY keeps the agreement.
export
rlow_4_2_1__replay_agree : (p : Lcyc_3_2_1__program) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) -> (wm : Rarc_5_6_4__wm) -> (net : Rarc_5_3_1__network) -> (toks : List (List Iret_11__tok)) ->
                           Rlow_4_2_1__agree p wm net toks ->
                           (wm' ** net' ** toks' ** ( lfst_9_2_1__replay_net (life p) fuel evs (MkEngine wm net) = MkEngine wm' net'
                                                    , lfst_9_2_1__replay_plain p fuel evs (MkState wm toks) = MkState wm' toks'
                                                    , Rlow_4_2_1__agree p wm' net' toks' ))
rlow_4_2_1__replay_agree p fuel [] wm net toks ag = (wm ** net ** toks ** (Refl, Refl, ag))
rlow_4_2_1__replay_agree p fuel (ev :: evs) wm net toks ag =
  let (wm1 ** net1 ** toks1 ** (e1, s1, ag1)) = rlow_4_2_1__boundary_agree p fuel ev wm net toks ag
      (wm2 ** net2 ** toks2 ** (e2, s2, ag2)) = rlow_4_2_1__replay_agree p fuel evs wm1 net1 toks1 ag1
  in (wm2 ** net2 ** toks2 ** ( trans (cong (lfst_9_2_1__replay_net (life p) fuel evs) e1) e2
                              , trans (cong (lfst_9_2_1__replay_plain p fuel evs) s1) s2
                              , ag2 ))

-- ---------------------------------------------------------------------
-- The start
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
export
rlow_4_2_1__rules_agree_refl : (alphas : List Iret_6_1__alpha) -> (cs : List Rlow_4_2_1__chain) -> Rlow_4_2_1__rules_agree alphas cs (map (rlow_4_2_1__rule_of alphas) cs)
rlow_4_2_1__rules_agree_refl alphas [] = RANil
rlow_4_2_1__rules_agree_refl alphas (c :: cs) = RACons (lgra_6_1__same_rule_refl (rlow_4_2_1__rule_of alphas c)) (rlow_4_2_1__rules_agree_refl alphas cs)

--@derives [RDSC.4a.5]
--@derives [IRET.8.1]
||| A SEEDED TERMINAL holds unfired activations only.
export
rdsc_4a_5__seed_unfired : (alphas : List Iret_6_1__alpha) -> (r : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                          (a : Iret_8_1__act) -> Elem a (cacts (rdsc_4a_5__seed alphas (iret_16_6__terminal r))) -> afired a = False
rdsc_4a_5__seed_unfired alphas (nodes, actions) a e =
  let (e1, _) = iret_7_7__wave_evolves [] alphas (iret_16_5__beta_nodes nodes) [[]] []
  in case e1 a e of
       Left (x, _) => absurd x
       Right (_, nf) => nf

--@derives [RLOW.4.2.1]
--@derives [RDSC.4a.5]
||| AT THE START the tables agree: FireLoop's first propagation from
||| nothing over empty working memory, and the network's seeding, hold
||| the same unblocked matches, all unfired.
export
rlow_4_2_1__init_tables_agree : (life : Nat -> Lscp_1_3__lifecycle) -> (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                                (cs : List Rlow_4_2_1__chain) -> ((c : Rlow_4_2_1__chain) -> Elem c cs -> Elem c (nchains (enet (rdsc_4a_5__load alphas rules)))) ->
                                ((c : Rlow_4_2_1__chain) -> Elem c cs -> (a : Iret_8_1__act) -> Elem a (cacts c) -> afired a = False) ->
                                Rlow_4_2_1__tables_agree (zipWith (\r, ts => rarc_5_6_5__prop_rule r [] ts) (map (rlow_4_2_1__rule_of (iret_16_4__alpha_nodes alphas)) cs) (map (const []) (map (rlow_4_2_1__rule_of (iret_16_4__alpha_nodes alphas)) cs))) cs
rlow_4_2_1__init_tables_agree life alphas rules [] inLoad unfired = TANil
rlow_4_2_1__init_tables_agree life alphas rules (c :: cs) inLoad unfired =
  let v = rdsc_4a_5__load_view alphas rules
      (v', ordActs) = rdsc_4a_5__load_ordered alphas rules
      ec = inLoad c Here
      (sorted', _) = lcyc_1_1__all_lookup ordActs ec
      (_, dt) = snd (rarc_5_6_5__view_recomputed (rdsc_4a_5__load alphas rules) v) c ec
      sameSet = rlow_4_2_1__terminal_agrees (rdsc_4a_5__load alphas rules) v c ec
  in TACons (rlow_4_2_1__prop_agree (rlow_4_2_1__rule_of (iret_16_4__alpha_nodes alphas) c) [] [] (\f, g, ef, eg, eq => absurd ef)
               [] ([], STNil) [] Refl
               (rarc_5_6_5__init_table_well (rlow_4_2_1__rule_of (iret_16_4__alpha_nodes alphas) c))
               (iret_8_1__prop_with_settled _ _ _ [])
               (cacts c) sorted' dt sameSet
               (\a', e => Right (unfired c Here a' e))
               (\a, ea, _ => absurd ea))
            (rlow_4_2_1__init_tables_agree life alphas rules cs (\d, e => inLoad d (There e)) (\d, e => unfired d (There e)))

--@derives [RLOW.4.2.1]
--@derives [RDSC.4a.5]
--@derives [IRET.18.2]
||| THE LOADED NETWORK AND THE EMPTY FIRELOOP STATE AGREE, under the
||| program the loaded network lowers to.
export
rlow_4_2_1__init_agree : (life : Nat -> Lscp_1_3__lifecycle) -> (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                         Rlow_4_2_1__agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) [] (enet (rdsc_4a_5__load alphas rules))
                                           (toks (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []))
rlow_4_2_1__init_agree life alphas rules =
  ( rlow_4_2_1__rules_agree_refl (iret_16_4__alpha_nodes alphas) _
  , rlow_4_2_1__init_tables_agree life alphas rules _ (\c, e => e)
      (\c, ec, a, ea =>
         let (r ** (er, ceq)) = lcyc_1_1__elem_map_inv (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas)) (map iret_16_6__terminal rules) ec
             (spec ** (_, teq)) = lcyc_1_1__elem_map_inv iret_16_6__terminal rules er
         in rdsc_4a_5__seed_unfired (iret_16_4__alpha_nodes alphas) spec a
              (replace {p = \z => Elem a (cacts z)} (sym (trans (cong (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas)) teq) ceq)) ea))
  , rdsc_4a_5__load_ordered alphas rules
  , rarc_5_6_5__init_well (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) )

-- ---------------------------------------------------------------------
-- THE TRANSFER
-- ---------------------------------------------------------------------

--@derives [RLOW.4.2.1]
--@derives [RARC.5.6.5]
--@derives [IRET.11]
--@derives [IDAT.6.2.2]
--@derives [LFST.9.2.1]
||| THE TRANSFER THEOREM. Run on one history from the loaded network and
||| from FireLoop's empty state under the program the network lowers to,
||| the two engines reach one working memory, and each FireLoop table's
||| unblocked tokens are the network terminal's activations, in order and
||| with their flags. Against the plain pipeline, without the TMS phase
||| and the clock; Rete/NetworkTmsTransfer.idr and Rete/NetworkTtl.idr
||| carry those, on this agreement.
export
rlow_4_2_1__transfer : (life : Nat -> Lscp_1_3__lifecycle) -> (fuel : Nat) -> (evs : List Rarc_5_6_1__event) ->
                       (alphas : List (Nat, Lfac_1_7_1__fact -> Bool)) -> (rules : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)) ->
                       (wm' ** net' ** toks' **
                         ( lfst_9_2_1__replay_net life fuel evs (rdsc_4a_5__load alphas rules) = MkEngine wm' net'
                         , lfst_9_2_1__replay_plain (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) fuel evs
                             (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []) = MkState wm' toks'
                         , Rlow_4_2_1__agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) wm' net' toks' ))
rlow_4_2_1__transfer life fuel evs alphas rules =
  rlow_4_2_1__replay_agree (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) fuel evs [] (enet (rdsc_4a_5__load alphas rules))
    (toks (rarc_5_6_5__init_state (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) []))
    (rlow_4_2_1__init_agree life alphas rules)

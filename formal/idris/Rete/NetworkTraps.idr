-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| WHEN A MATCH-TIME TRAP IS RECORDED: the pairs a state change DERIVES
||| ([LERR.1.4.12]) against the pairs the incremental network evaluates, and
||| the two properties the clause's choice rests on, proved over the derived
||| pairs.
|||
||| NORMATIVE COMPANION to Rete/Network.idr and Rete/NetworkAnswer.idr.
|||
||| A pair (rule, node, token, candidate) is LIVE when the token is in the
||| node's left memory and the candidate in its right memory
||| (`rarc_5_3_1__net_live`). An operation DERIVES the pairs live after it
||| and not before (`lerr_1_4_12__derived`), the pairs below a released
||| negated pattern included: a released token's pairs are live after.
||| [LERR.1.4.12] records a TypeError or a
||| ComputationError once per derivation of a pair whose tests yield it,
||| and for no other pair, in the agenda's order.
|||
||| WHAT IS PROVED. By the view (Rete/NetworkDispatch.idr) every memory is
||| the recompute over working memory, so:
|||   (b) THE LIVE PAIRS ARE A FUNCTION OF WORKING MEMORY
|||       (`lerr_1_4_12__live_is_a_function_of_wm`): under the view a
|||       network's live pairs are, as a set, `lerr_1_4_12__net_live_of`, the
|||       recompute from the program and working memory alone. The derived
|||       pairs are the filter of one such set by another, so which pairs an
|||       operation derives is a function of working memory before and
|||       after it -- the clause's own sentence -- whatever the engine's
|||       traversal, index or alpha order ([LDET.5.9]).
|||   (c) A RETRACTION DERIVES NO PAIR CONTAINING ITS FACT
|||       (`lerr_1_4_12__retraction_derives_no_pair_of_its_fact`): a pair
|||       retracting `f` derives is live after, so its facts are in the
|||       working memory after, from which `f` is gone. The pairs a
|||       retraction ends record nothing.
||| Not modelled: the order of one operation's records (the clause's three
||| keys). The pairs here are lists in chain and memory order, compared as
||| sets.
|||
||| THE EVALUATIONS (`iret_19_1__insert_pairs`, `iret_19_2__retract_pairs`),
||| read off the four paths as Rete/Network.idr defines them: a wave pairs
||| every arriving token with every candidate at every node it reaches; a
||| right-activation pairs the new fact with every left token of every node
||| on its alpha, positive or `no`; a right-retraction evaluates nothing it
||| records -- the pairs it re-tests are the pairs it ENDS, and [IRET.7.7]
||| as amended has it evaluate no join test at all -- except through the
||| wave of the tokens a `no` node releases. These `_pairs` functions are a
||| hand-written reading of Rete/Network.idr's paths, not proved equal to
||| them.
|||
||| WHY THE CLAUSE IS OVER DERIVED PAIRS AND NOT OVER EVALUATIONS. Alpha
||| dispatch visits one alpha at a time and right-activates every chain
||| before the next ([IRET.6.4], [IRET.1.7], [IRET.19.2]), and within a
||| chain the deeper node goes first (the reading
||| [IRET.7.7] needs to produce each match once). So one fact that feeds a
||| `no` node and a positive node of the same rule is evaluated at the
||| positive node against tokens the `no` node is about to block, or, on
||| retraction, against the tokens a `no` node has just released while
||| another alpha still holds it. Those pairs are live in no state:
||| TRANSIENT, evaluated and not derived, and the clause records nothing
||| for them. The witnesses, by computation:
|||
|||   * `lerr_1_4_12__transient_pair_records_nothing` -- `A a, no B b where
|||     b.k == a.k, B c where <test>`, one alpha for both `B` patterns
|||     ([IRET.6.6]): asserting `b1` with `b1.k == a1.k` evaluates
|||     `((a1), b1)` at the `c` node, then blocks `(a1)`. The pair is not
|||     live before, not live after, and not derived; a test that traps on
|||     it records nothing. The lockstep scenario `113_transient_trap` and
|||     the vector `logical/LERR.1.4.12_transient_pair_records_nothing` run
|||     it against both runtimes.
|||   * `lerr_1_4_12__retraction_evaluates_but_derives_not_its_fact` -- the
|||     same rule with an alpha test on `c` (a second `B` alpha, after the
|||     first): retracting `b1` releases `(a1)`, whose wave meets `b1` in the
|||     second alpha before dispatch reaches it. The retraction EVALUATES a
|||     pair containing `b1` and DERIVES no such pair: (c) at an instance.
|||   * `lerr_1_4_12__evaluated_pairs_vary_with_alpha_order_derived_do_not`
|||     -- the two alpha orders evaluate different transients and derive the
|||     same nothing. No alpha order makes the evaluated pairs the derived
|||     ones, which is why an engine meets the clause by discarding the
|||     transients it evaluates -- both runtimes hold a match-time trap with
|||     its pair and record it only if the pair is live when the event ends
|||     -- or by ordering its paths, and never by recording per
|||     evaluation.
module Rete.NetworkTraps

import Rete.FireLoop
import Rete.PumpBoundary
import Rete.Network
import Rete.NetworkView
import Rete.NetworkPaths
import Rete.NetworkDispatch
import Rete.NetworkAnswer
import Rete.TmsBridge
import Rete.Eval
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Pairs, live and derived
-- ---------------------------------------------------------------------

--@spec [IRET.7.6]
||| A pair a node's tests answer: the rule's ordinal, the node's position
||| in the chain, the token, the candidate.
public export
Iret_7_6__pair : Type
Iret_7_6__pair = (Nat, Nat, Iret_7_1__token, Lfac_1_7_1__fact)

--@spec [IRET.7.6]
||| Every token against every candidate, at one node.
public export
iret_7_6__cross : Nat -> Nat -> List Iret_7_1__token -> List Lfac_1_7_1__fact -> List Iret_7_6__pair
iret_7_6__cross r k toks mem = rarc_5_6_5__concat_map (\t => map (\g => (r, k, t, g)) mem) toks

--@spec [IRET.7.4]
||| A chain's live pairs, from node `k` on: each node's left memory against
||| its right memory.
public export
iret_7_4__chain_live : List Iret_6_1__alpha -> Nat -> Nat -> List Iret_7_4__beta -> List Iret_7_6__pair
iret_7_4__chain_live alphas r k [] = []
iret_7_4__chain_live alphas r k (b :: rest) =
  iret_7_6__cross r k (blmem b) (iret_6_6__mem_at alphas (balpha b)) ++ iret_7_4__chain_live alphas r (S k) rest

--@spec [RARC.5.3.1]
||| One list per chain, tagged with the rule's ordinal.
public export
rarc_5_3_1__per_chain : (Nat -> Rlow_4_2_1__chain -> List Iret_7_6__pair) -> Nat -> List Rlow_4_2_1__chain -> List Iret_7_6__pair
rarc_5_3_1__per_chain g r [] = []
rarc_5_3_1__per_chain g r (c :: cs) = g r c ++ rarc_5_3_1__per_chain g (S r) cs

--@spec [RARC.5.3.1]
||| THE LIVE PAIRS of a network.
public export
rarc_5_3_1__net_live : Rarc_5_3_1__network -> List Iret_7_6__pair
rarc_5_3_1__net_live net = rarc_5_3_1__per_chain (\r, c => iret_7_4__chain_live (nalphas net) r 0 (cnodes c)) 0 (nchains net)

--@spec [LERR.1.4.12]
||| THE DERIVED PAIRS of a state change: live after, not before -- the
||| clause's "derives", the pairs below a released negated pattern included,
||| since a released token's pairs are live after. What a match-time
||| TypeError or ComputationError is recorded for, once per derivation.
public export
lerr_1_4_12__derived : Rarc_5_3_1__network -> Rarc_5_3_1__network -> List Iret_7_6__pair
lerr_1_4_12__derived before after = filter (\p => not (rarc_5_6_5__elem p (rarc_5_3_1__net_live before))) (rarc_5_3_1__net_live after)

--@spec [LERR.1.4.12]
||| A chain's live pairs RECOMPUTED from working memory: at each node the
||| front it receives against its alpha's view of working memory, the
||| front advanced by the node's own propagation ([IRET.7.7]). Reads the
||| program -- the alphas' tests, the nodes' alphas, tests and flags -- and
||| working memory, and no memory of the network.
public export
lerr_1_4_12__chain_live_of : List Iret_6_1__alpha -> Rarc_5_6_4__wm -> Nat -> Nat -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_7_6__pair
lerr_1_4_12__chain_live_of alphas wm r k [] front = []
lerr_1_4_12__chain_live_of alphas wm r k (b :: rest) front =
  iret_7_6__cross r k front (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm)
    ++ lerr_1_4_12__chain_live_of alphas wm r (S k) rest
         (iret_7_7__next_of (bneg b) (bjoin b) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm) front)

--@spec [LERR.1.4.12]
||| The live pairs of a network recomputed from its working memory.
public export
lerr_1_4_12__net_live_of : Rarc_5_3_1__network -> Rarc_5_6_4__wm -> List Iret_7_6__pair
lerr_1_4_12__net_live_of net wm =
  rarc_5_3_1__per_chain (\q, c => lerr_1_4_12__chain_live_of (nalphas net) wm q 0 (cnodes c) [[]]) 0 (nchains net)

-- ---------------------------------------------------------------------
-- (b) The live pairs are a function of working memory
-- ---------------------------------------------------------------------

--@derives [LERR.1.4.12]
||| Two fronts with the same members pair alike with one memory.
export
lerr_1_4_12__cross_same_set : (r, k : Nat) -> (toks, toks' : List Iret_7_1__token) -> (mem, mem' : List Lfac_1_7_1__fact) ->
                              mem = mem' -> Iret_7_4__same_set toks toks' ->
                              Iret_7_4__same_set (iret_7_6__cross r k toks mem) (iret_7_6__cross r k toks' mem')
lerr_1_4_12__cross_same_set r k toks toks' mem mem' eq ss =
  replace {p = \m => Iret_7_4__same_set (iret_7_6__cross r k toks mem) (iret_7_6__cross r k toks' m)} eq (\p =>
    ( \e => let (t ** (et, ep)) = iret_7_7__elem_concat_inv (\u => map (\g => (r, k, u, g)) mem) toks e
            in iret_12_2__elem_concat_map (\u => map (\g => (r, k, u, g)) mem) toks' (fst (ss t) et) ep
    , \e => let (t ** (et, ep)) = iret_7_7__elem_concat_inv (\u => map (\g => (r, k, u, g)) mem) toks' e
            in iret_12_2__elem_concat_map (\u => map (\g => (r, k, u, g)) mem) toks (snd (ss t) et) ep ))

--@derives [LERR.1.4.12]
||| Appending respects membership on both sides.
export
lerr_1_4_12__append_same_set : {a : Type} -> (xs, xs', ys, ys' : List a) -> Iret_7_4__same_set xs xs' -> Iret_7_4__same_set ys ys' ->
                               Iret_7_4__same_set (xs ++ ys) (xs' ++ ys')
lerr_1_4_12__append_same_set xs xs' ys ys' sx sy = \p =>
  ( \e => case lcyc_1_1__elem_append_inv xs e of
            Left ex => lcyc_1_1__elem_append_left (fst (sx p) ex)
            Right ey => lcyc_1_1__elem_append_right xs' (fst (sy p) ey)
  , \e => case lcyc_1_1__elem_append_inv xs' e of
            Left ex => lcyc_1_1__elem_append_left (snd (sx p) ex)
            Right ey => lcyc_1_1__elem_append_right xs (snd (sy p) ey) )

--@derives [LERR.1.4.12]
||| A CONSISTENT CHAIN'S LIVE PAIRS ARE THE RECOMPUTE'S, node by node: the
||| left memory is the front it receives, as a set, and the right memory is
||| the alpha's view of working memory.
export
lerr_1_4_12__chain_live_recomputed : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) ->
                                     ((i : Nat) -> iret_6_6__mem_at alphas i = iret_6_5__view (iret_6_6__alpha_at alphas i) wm) ->
                                     (r, k : Nat) -> (nodes : List Iret_7_4__beta) -> (front : List Iret_7_1__token) -> (acts : List Iret_8_1__act) ->
                                     Iret_7_7__consistent alphas front nodes acts ->
                                     Iret_7_4__same_set (iret_7_4__chain_live alphas r k nodes) (lerr_1_4_12__chain_live_of alphas wm r k nodes front)
lerr_1_4_12__chain_live_recomputed alphas wm mv r k [] front acts cons = \p => (\e => absurd e, \e => absurd e)
lerr_1_4_12__chain_live_recomputed alphas wm mv r k (b :: rest) front acts (sl, dl, cnt, rec) =
  lerr_1_4_12__append_same_set _ _ _ _
    (lerr_1_4_12__cross_same_set r k (blmem b) front (iret_6_6__mem_at alphas (balpha b)) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm) (mv (balpha b)) sl)
    (lerr_1_4_12__chain_live_recomputed alphas wm mv r (S k) rest _ acts
       (replace {p = \m => Iret_7_7__consistent alphas (iret_7_7__next_of (bneg b) (bjoin b) m front) rest acts} (mv (balpha b)) rec))

--@derives [LERR.1.4.12]
||| Chain by chain, with the rule ordinals.
export
lerr_1_4_12__per_chain_recomputed : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) ->
                                    ((i : Nat) -> iret_6_6__mem_at alphas i = iret_6_5__view (iret_6_6__alpha_at alphas i) wm) ->
                                    (r : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                                    All (\c => Iret_7_7__consistent alphas [[]] (cnodes c) (cacts c)) chains ->
                                    Iret_7_4__same_set (rarc_5_3_1__per_chain (\q, c => iret_7_4__chain_live alphas q 0 (cnodes c)) r chains)
                                                       (rarc_5_3_1__per_chain (\q, c => lerr_1_4_12__chain_live_of alphas wm q 0 (cnodes c) [[]]) r chains)
lerr_1_4_12__per_chain_recomputed alphas wm mv r [] [] = \p => (\e => absurd e, \e => absurd e)
lerr_1_4_12__per_chain_recomputed alphas wm mv r (c :: cs) (kc :: kcs) =
  lerr_1_4_12__append_same_set _ _ _ _
    (lerr_1_4_12__chain_live_recomputed alphas wm mv r 0 (cnodes c) [[]] (cacts c) kc)
    (lerr_1_4_12__per_chain_recomputed alphas wm mv (S r) cs kcs)

--@derives [LERR.1.4.12]
||| (b) THE LIVE PAIRS ARE A FUNCTION OF WORKING MEMORY: under the view, a
||| network's live pairs are, as a set, their recompute from the program and
||| working memory. The derived pairs of an operation are the filter of the
||| recompute after by the recompute before, so which pairs an operation
||| derives -- and which match-time faults it records -- is a function of
||| working memory before and after it, whatever the engine's traversal,
||| index or alpha order ([LDET.5.9]).
export
lerr_1_4_12__live_is_a_function_of_wm : (eng : Iret_19__engine) -> Iret_19__view eng ->
                                        Iret_7_4__same_set (rarc_5_3_1__net_live (enet eng)) (lerr_1_4_12__net_live_of (enet eng) (ewm eng))
lerr_1_4_12__live_is_a_function_of_wm (MkEngine wm (MkNetwork alphas chains)) (dw, dm, mv, cons) =
  lerr_1_4_12__per_chain_recomputed alphas wm mv 0 chains cons

-- ---------------------------------------------------------------------
-- (c) A retraction derives no pair containing its fact
-- ---------------------------------------------------------------------

--@derives [LERR.1.4.12]
||| A node's propagation keeps a front's facts live: a `no` node filters
||| the front, a positive node extends its tokens by candidates of the
||| alpha's view of working memory.
export
lerr_1_4_12__front_in_wm : (wm : Rarc_5_6_4__wm) -> (neg : Bool) -> (j : Iret_7_5__join) -> (a : Iret_6_1__alpha) -> (front : List Iret_7_1__token) ->
                           All (\t => All (\h => Elem h wm) t) front ->
                           All (\t => All (\h => Elem h wm) t) (iret_7_7__next_of neg j (iret_6_5__view a wm) front)
lerr_1_4_12__front_in_wm wm True j a front inwm = lcyc_1_1__all_filter (\t => iret_7_9_1__blockers j (iret_6_5__view a wm) t == 0) front inwm
lerr_1_4_12__front_in_wm wm False j a front inwm =
  lcyc_1_1__all_from_elem (iret_7_7__extend_front j (iret_6_5__view a wm) front) (\y, ey =>
    let (t ** (g ** (et, eg, jg, eq))) = iret_7_7__extend_elem_inv j (iret_6_5__view a wm) front y ey
    in replace {p = \z => All (\h => Elem h wm) z} (sym eq)
         (lcyc_1_1__all_append (lcyc_1_1__all_lookup inwm et) (fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits a) wm eg) :: [])))

--@derives [LERR.1.4.12]
||| A live pair of the recompute is over live facts: the token's and the
||| candidate.
export
lerr_1_4_12__chain_pair_in_wm : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (r, k : Nat) -> (nodes : List Iret_7_4__beta) -> (front : List Iret_7_1__token) ->
                                All (\t => All (\h => Elem h wm) t) front ->
                                (r', k' : Nat) -> (t : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) ->
                                Elem (r', k', t, g) (lerr_1_4_12__chain_live_of alphas wm r k nodes front) ->
                                (All (\h => Elem h wm) t, Elem g wm)
lerr_1_4_12__chain_pair_in_wm alphas wm r k [] front inwm r' k' t g e = absurd e
lerr_1_4_12__chain_pair_in_wm alphas wm r k (b :: rest) front inwm r' k' t g e =
  case lcyc_1_1__elem_append_inv (iret_7_6__cross r k front (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm)) e of
    Left ex =>
      let (t0 ** (et, ep)) = iret_7_7__elem_concat_inv (\u => map (\h => (r, k, u, h)) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm)) front ex
          (g0 ** (eg, eq)) = lcyc_1_1__elem_map_inv (\h => (r, k, t0, h)) (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm) ep
      in ( replace {p = \z => All (\h => Elem h wm) z} (cong (\q => fst (snd (snd q))) eq) (lcyc_1_1__all_lookup inwm et)
         , replace {p = \z => Elem z wm} (cong (\q => snd (snd (snd q))) eq)
             (fst (lcyc_1_1__elem_filter_inv (iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b))) wm eg)) )
    Right ey =>
      lerr_1_4_12__chain_pair_in_wm alphas wm r (S k) rest _
        (lerr_1_4_12__front_in_wm wm (bneg b) (bjoin b) (iret_6_6__alpha_at alphas (balpha b)) front inwm) r' k' t g ey

--@derives [LERR.1.4.12]
||| Over every chain, from the empty token.
export
lerr_1_4_12__net_pair_in_wm : (alphas : List Iret_6_1__alpha) -> (wm : Rarc_5_6_4__wm) -> (r : Nat) -> (chains : List Rlow_4_2_1__chain) ->
                              (r', k' : Nat) -> (t : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) ->
                              Elem (r', k', t, g) (rarc_5_3_1__per_chain (\q, c => lerr_1_4_12__chain_live_of alphas wm q 0 (cnodes c) [[]]) r chains) ->
                              (All (\h => Elem h wm) t, Elem g wm)
lerr_1_4_12__net_pair_in_wm alphas wm r [] r' k' t g e = absurd e
lerr_1_4_12__net_pair_in_wm alphas wm r (c :: cs) r' k' t g e =
  case lcyc_1_1__elem_append_inv (lerr_1_4_12__chain_live_of alphas wm r 0 (cnodes c) [[]]) e of
    Left ex => lerr_1_4_12__chain_pair_in_wm alphas wm r 0 (cnodes c) [[]] ([] :: []) r' k' t g ex
    Right ey => lerr_1_4_12__net_pair_in_wm alphas wm (S r) cs r' k' t g ey

--@derives [LERR.1.4.12]
||| (c) A RETRACTION DERIVES NO PAIR CONTAINING ITS FACT: a pair derived by
||| retracting `f` is live after, so its facts are in the working memory
||| after, from which `f` is gone. The pairs a retraction ends -- every pair
||| `f` was in -- record nothing, whatever the engine evaluates on the way
||| (`lerr_1_4_12__retraction_evaluates_but_derives_not_its_fact`).
export
lerr_1_4_12__retraction_derives_no_pair_of_its_fact : (f : Lfac_1_7_1__fact) -> (eng : Iret_19__engine) -> Elem f (ewm eng) -> Iret_19__view eng ->
                                                      (r, k : Nat) -> (t : Iret_7_1__token) -> (g : Lfac_1_7_1__fact) ->
                                                      Elem (r, k, t, g) (lerr_1_4_12__derived (enet eng) (enet (iret_19_2__retract f eng))) ->
                                                      (Not (g = f), Not (Elem f t))
lerr_1_4_12__retraction_derives_no_pair_of_its_fact f eng ef v r k t g e =
  let (ea, _) = lcyc_1_1__elem_filter_inv (\p => not (rarc_5_6_5__elem p (rarc_5_3_1__net_live (enet eng))))
                                          (rarc_5_3_1__net_live (enet (iret_19_2__retract f eng))) e
      er = fst (lerr_1_4_12__live_is_a_function_of_wm (iret_19_2__retract f eng) (iret_19_2__retract_view f eng ef v) (r, k, t, g)) ea
      (allt, eg) = lerr_1_4_12__net_pair_in_wm (nalphas (enet (iret_19_2__retract f eng))) (rarc_5_6_4__remove_exact f (ewm eng)) 0
                                               (nchains (enet (iret_19_2__retract f eng))) r k t g er
  in ( \gf => snd (rarc_5_6_4__remove_exact_elem_inv f (ewm eng) g eg) gf
     , \eft => snd (rarc_5_6_4__remove_exact_elem_inv f (ewm eng) f (lcyc_1_1__all_lookup allt eft)) Refl )

-- ---------------------------------------------------------------------
-- The pairs the network evaluates, path by path
-- ---------------------------------------------------------------------

--@spec [IRET.7.7]
--@spec [IRET.7.9.1]
||| A WAVE evaluates every arriving token against every candidate of every
||| node it reaches — a `no` node to count its blockers, a positive node to
||| extend.
public export
iret_7_7__wave_pairs : List Iret_6_1__alpha -> Nat -> Nat -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_7_6__pair
iret_7_7__wave_pairs alphas r k [] front = []
iret_7_7__wave_pairs alphas r k (b :: rest) front =
  iret_7_6__cross r k front (iret_6_6__mem_at alphas (balpha b))
    ++ iret_7_7__wave_pairs alphas r (S k) rest (iret_7_7__next b (iret_6_6__mem_at alphas (balpha b)) front)

--@spec [IRET.7.7]
--@spec [IRET.7.9.2]
||| RIGHT-ACTIVATION, deepest node first, as `iret_7_7__right_activate`
||| runs it: a node on the fact's alpha evaluates the fact against every
||| left token; a positive node's extensions then wave down the (already
||| activated) deeper nodes.
public export
iret_7_7__right_activate_pairs : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> Nat -> Nat -> List Iret_7_4__beta -> List Iret_8_1__act -> List Iret_7_6__pair
iret_7_7__right_activate_pairs wm alphas a f r k [] acts = []
iret_7_7__right_activate_pairs wm alphas a f r k (b :: rest) acts =
  let deeper = iret_7_7__right_activate_pairs wm alphas a f r (S k) rest acts
      r1 = iret_7_7__right_activate wm alphas a f rest acts
      hit = filter (\t => bjoin b t f) (blmem b)
  in if balpha b == a
       then if bneg b
              then deeper ++ iret_7_6__cross r k (blmem b) [f]
              else deeper ++ iret_7_6__cross r k (blmem b) [f] ++ iret_7_7__wave_pairs alphas r (S k) (fst r1) (map (\t => t ++ [f]) hit)
       else deeper

--@spec [IRET.7.7]
--@spec [IRET.7.9.3]
||| RIGHT-RETRACTION, deepest node first, as `iret_7_7__right_retract`
||| runs it: the pairs it re-tests are the pairs it ends, and record
||| nothing; the tokens a `no` node releases wave down the deeper nodes.
public export
iret_7_7__right_retract_pairs : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> Nat -> Nat -> List Iret_7_4__beta -> List Iret_8_1__act -> List Iret_7_6__pair
iret_7_7__right_retract_pairs wm alphas a f r k [] acts = []
iret_7_7__right_retract_pairs wm alphas a f r k (b :: rest) acts =
  let deeper = iret_7_7__right_retract_pairs wm alphas a f r (S k) rest acts
      r1 = iret_7_7__right_retract wm alphas a f rest acts
      hit = filter (\t => bjoin b t f) (blmem b)
  in if balpha b == a
       then if bneg b
              then deeper ++ iret_7_7__wave_pairs alphas r (S k) (fst r1) (filter (\t => iret_7_9_4__count t (bcounts b) == 1) hit)
              else deeper
       else deeper

--@spec [IRET.6.4]
--@spec [IRET.1.7]
||| ALPHA DISPATCH ON ASSERT, as `iret_6_4__dispatch_assert` runs it: per
||| admitting alpha, in order, every chain's right-activation.
public export
iret_6_4__dispatch_assert_pairs : Rarc_5_6_4__wm -> Lfac_1_7_1__fact -> List Nat -> Rarc_5_3_1__network -> List Iret_7_6__pair
iret_6_4__dispatch_assert_pairs wm f [] net = []
iret_6_4__dispatch_assert_pairs wm f (i :: is) net =
  if iret_6_4__admits (iret_6_6__alpha_at (nalphas net) i) f
    then let alphas' = rarc_5_6_5__set_at i (iret_6_5__insert f) (nalphas net)
         in rarc_5_3_1__per_chain (\r, c => iret_7_7__right_activate_pairs wm alphas' i f r 0 (cnodes c) (cacts c)) 0 (nchains net)
              ++ iret_6_4__dispatch_assert_pairs wm f is (MkNetwork alphas' (map (iret_7_7__activate_chain wm alphas' i f) (nchains net)))
    else iret_6_4__dispatch_assert_pairs wm f is net

--@spec [IRET.19.2]
--@spec [IRET.1.7]
||| ALPHA DISPATCH ON RETRACT, as `iret_19_2__dispatch_retract` runs it.
public export
iret_19_2__dispatch_retract_pairs : Rarc_5_6_4__wm -> Lfac_1_7_1__fact -> List Nat -> Rarc_5_3_1__network -> List Iret_7_6__pair
iret_19_2__dispatch_retract_pairs wm f [] net = []
iret_19_2__dispatch_retract_pairs wm f (i :: is) net =
  if iret_6_4__admits (iret_6_6__alpha_at (nalphas net) i) f
    then let alphas' = rarc_5_6_5__set_at i (iret_6_5__remove f) (nalphas net)
         in rarc_5_3_1__per_chain (\r, c => iret_7_7__right_retract_pairs wm alphas' i f r 0 (cnodes c) (cacts c)) 0 (nchains net)
              ++ iret_19_2__dispatch_retract_pairs wm f is (MkNetwork alphas' (map (iret_7_7__retract_chain wm alphas' i f) (nchains net)))
    else iret_19_2__dispatch_retract_pairs wm f is net

--@spec [IRET.19.1]
||| The pairs inserting a fresh fact evaluates.
public export
iret_19_1__insert_pairs : Lfac_1_7_1__fact -> Iret_19__engine -> List Iret_7_6__pair
iret_19_1__insert_pairs f eng =
  iret_6_4__dispatch_assert_pairs (ewm eng ++ [f]) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)

--@spec [IRET.19.2]
||| The pairs retracting a live fact evaluates.
public export
iret_19_2__retract_pairs : Lfac_1_7_1__fact -> Iret_19__engine -> List Iret_7_6__pair
iret_19_2__retract_pairs f eng =
  iret_19_2__dispatch_retract_pairs (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng)

-- ---------------------------------------------------------------------
-- The witness program: A a, no B b where b.k == a.k, B c where <traps>
-- ---------------------------------------------------------------------

--@spec [LERR.1.4.12]
||| `A` is kind 0, `B` kind 1; `a1` and `b1` share key 7, `b1`'s payload
||| is 1. A fixture.
public export
lerr_1_4_12__a1 : Lfac_1_7_1__fact
lerr_1_4_12__a1 = MkFact 1 0 7 0

--@spec [LERR.1.4.12]
||| A fixture.
public export
lerr_1_4_12__b1 : Lfac_1_7_1__fact
lerr_1_4_12__b1 = MkFact 2 1 7 1

--@spec [LERR.1.4.12]
||| Two keys compared, decided. A fixture.
public export
lerr_1_4_12__key_eq : Nat -> Nat -> Lnul_4_2__answer
lerr_1_4_12__key_eq x y = if x == y then KTrue else KFalse

--@spec [LERR.1.4.12]
||| A fixture.
public export
lerr_1_4_12__same_key_of : List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Lnul_4_2__answer
lerr_1_4_12__same_key_of [x] g = lerr_1_4_12__key_eq (fkey x) (fkey g)
lerr_1_4_12__same_key_of _   _ = KFalse

--@spec [LERR.1.4.12]
||| `a`'s key against the candidate's: `b.k == a.k`, decided. A fixture.
public export
lerr_1_4_12__same_key : Iret_7_5__test
lerr_1_4_12__same_key = lerr_1_4_12__same_key_of

--@spec [LERR.1.4.12]
||| `c`'s test, a trap on every pair: `c.v / a.w > 1` with `a.w` zero. A
||| fixture.
public export
lerr_1_4_12__traps : Iret_7_5__test
lerr_1_4_12__traps = \_, _ => KTrap

--@spec [LERR.1.4.12]
||| The rule's nodes over alphas `nb` (the `no` pattern's) and `nc` (`c`'s).
||| A fixture.
public export
lerr_1_4_12__rule : Nat -> Nat -> List (Nat, Iret_7_5__test, Bool)
lerr_1_4_12__rule nb nc = [(0, \_, _ => KTrue, False), (nb, lerr_1_4_12__same_key, True), (nc, lerr_1_4_12__traps, False)]

--@spec [LERR.1.4.12]
||| One `B` alpha shared by both patterns ([IRET.6.6]: one alpha node per
||| schema and tests). A fixture.
public export
lerr_1_4_12__shared : Iret_19__engine
lerr_1_4_12__shared = rdsc_4a_5__load4 [(0, \_ => True), (1, \_ => True)] [(lerr_1_4_12__rule 1 1, [])]

--@spec [LERR.1.4.12]
||| A second `B` alpha for `c`, which carries an alpha test (payload 1),
||| after the `no` pattern's. A fixture.
public export
lerr_1_4_12__split : Iret_19__engine
lerr_1_4_12__split = rdsc_4a_5__load4 [(0, \_ => True), (1, \_ => True), (1, \f => fpay f == 1)] [(lerr_1_4_12__rule 1 2, [])]

--@spec [LERR.1.4.12]
||| The same two alphas the other way round: `c`'s first. A fixture.
public export
lerr_1_4_12__split_other : Iret_19__engine
lerr_1_4_12__split_other = rdsc_4a_5__load4 [(0, \_ => True), (1, \f => fpay f == 1), (1, \_ => True)] [(lerr_1_4_12__rule 2 1, [])]

--@derives [LERR.1.4.12]
||| TRANSIENT ON ASSERT RECORDS NOTHING. With `a1` live, asserting `b1`
||| evaluates `((a1), b1)` at the `c` node -- whose test traps on it --
||| although the pair is live neither before nor after: `b1` blocks `(a1)`
||| at the `no` node. It is not a derived pair, so the clause records no
||| trap for it: "a pair the engine evaluates that is not live when the
||| operation completes ... record[s] nothing, whatever [its] tests yield".
||| Computed.
export
lerr_1_4_12__transient_pair_records_nothing :
  ( lerr_1_4_12__traps [lerr_1_4_12__a1] lerr_1_4_12__b1 = KTrap
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (iret_19_1__insert_pairs lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__shared)) = True
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (rarc_5_3_1__net_live (enet (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__shared))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (rarc_5_3_1__net_live (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__shared)))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1)
      (lerr_1_4_12__derived (enet (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__shared))
                            (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__shared)))) = False )
lerr_1_4_12__transient_pair_records_nothing = (Refl, Refl, Refl, Refl, Refl)

--@derives [LERR.1.4.12]
||| A RETRACTION EVALUATES A PAIR CONTAINING ITS OWN FACT, AND DERIVES NO
||| SUCH PAIR. With `a1` and `b1` live and `(a1)` blocked, retracting `b1`
||| releases `(a1)`; its wave reaches the `c` node while `c`'s alpha still
||| holds `b1`, and evaluates `((a1), b1)`. The pair is live neither before
||| (`(a1)` was blocked) nor after (`b1` is gone), and is not derived: the
||| instance of `lerr_1_4_12__retraction_derives_no_pair_of_its_fact`, and
||| a trap the clause does not record. Computed.
export
lerr_1_4_12__retraction_evaluates_but_derives_not_its_fact :
  ( rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (iret_19_2__retract_pairs lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split))) = True
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (rarc_5_3_1__net_live (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split)))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (rarc_5_3_1__net_live (enet (iret_19_2__retract lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split))))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1)
      (lerr_1_4_12__derived (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split)))
                            (enet (iret_19_2__retract lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split))))) = False )
lerr_1_4_12__retraction_evaluates_but_derives_not_its_fact = (Refl, Refl, Refl, Refl)

--@derives [LERR.1.4.12]
||| THE EVALUATED PAIRS VARY WITH THE ALPHA ORDER; THE DERIVED PAIRS DO NOT.
||| With the `no` pattern's alpha first, the assertion of `b1` evaluates
||| no transient and its retraction does (the witness above); with `c`'s
||| alpha first, the assertion does and the retraction does not. Under
||| either order the pair is derived by neither operation. Dispatch order
||| cannot make the evaluated pairs the derived ones, and the clause's
||| record -- over derived pairs -- does not see the order ([LDET.5.9]).
||| Computed.
export
lerr_1_4_12__evaluated_pairs_vary_with_alpha_order_derived_do_not :
  ( rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (iret_19_1__insert_pairs lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split)) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (iret_19_1__insert_pairs lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other)) = True
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (rarc_5_3_1__net_live (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other)))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1) (iret_19_2__retract_pairs lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1)
      (lerr_1_4_12__derived (enet (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other))
                            (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other)))) = False
  , rarc_5_6_5__elem (0, 2, [lerr_1_4_12__a1], lerr_1_4_12__b1)
      (lerr_1_4_12__derived (enet (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other)))
                            (enet (iret_19_2__retract lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__b1 (iret_19_1__insert lerr_1_4_12__a1 lerr_1_4_12__split_other))))) = False )
lerr_1_4_12__evaluated_pairs_vary_with_alpha_order_derived_do_not = (Refl, Refl, Refl, Refl, Refl, Refl)

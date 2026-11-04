-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| `then` ON THE CLOCKED NETWORK: a sequence pattern is a two-node chain
||| whose second join is [LTHE.2.2.2]'s test on the facts' `ts`, event
||| time, and never on the clock; so a tick leaves it, and under the
||| general frame it fires once per valid pair ([LTHE.2.5.1]). The
||| clocked-network programme's part F. And `latest`, the anchor pinned to
||| its most recent match: the NOT sub-node after the sequence's last join
||| ([LTHE.2.5.3], [RLOW.5.6.5.2], [IRET.7.10.2]), the Idris lane's rung R2.
|||
||| NORMATIVE COMPANION to Rete/NetworkFrameRetime.idr, which it stands on.
|||
||| WHY. [LTHE.2.1] makes `then` a binary pattern combinator with a
||| mandatory `within T`; [LTHE.2.2.1] to [LTHE.2.2.3] say what it matches:
||| X, then a Y with `Y.ts > X.ts` and `Y.ts - X.ts < T`, the activation
||| holding both. Both comparisons are on the facts' `ts`, when the events
||| happened, and the monotonic clock takes no part ([LTIM.2.8.2]). On this
||| network that is a chain of two positive nodes, the second's join test a
||| predicate of the front token's fact and the candidate -- a join test
||| like any other, timed by nothing. The model's fact carries no `ts` slot;
||| its payload stands for `ts` here, and the
||| fixture says so. `latest` ([LTHE.2.5.3], [LTHE.2.5.5]) is the same
||| machinery once more: the exclusion is a NOT sub-node placed after the
||| sequence's LAST join ([IRET.7.10.2], [RLOW.5.6.5.2]), where the anchor
||| and every follower are on the token, so "another anchor that would
||| satisfy the sequence with these followers" is a predicate of the token
||| and one candidate -- a join test of this network on a standard NOT
||| node, and no new node kind. Placed straight after the anchor instead,
||| with no follower on the token yet, it would be a test over the anchor's
||| whole memory and no join test at all, which is the reading the vectors
||| of [LTHE.2.5.3] refute and this file no longer states.
|||
||| PROVED.
|||
|||   * THE SEQUENCE'S JOIN (`lthe_2_2_2__within`): strictly after, and
|||     within the bound, on `ts`; a function of two facts and nothing else.
|||   * A SEQUENCE CHAIN IS UNTIMED (`lthe_2_2_2__tick_leaves_chain`,
|||     `lthe_2_2_2__tick_leaves_engine`): with no time-dependent test, a
|||     tick's re-time leaves the chain and the engine as they were --
|||     [LTHE.2.2.2]'s "the monotonic clock takes no part", on the engine
|||     that re-times.
|||   * ONCE PER PAIR (`lthe_2_5_1__pairs_is_an_instance`): the general
|||     frame's theorem (Rete/NetworkFrameRetime.idr's) at a sequence chain
|||     no rule writes into -- no new lemma, the instance.
|||   * EXECUTED ([LTHE.2.5.1]): four X facts at `ts` 0, 2, 3 and 4, a tick
|||     to 7 between them and the Y at `ts` 4, with the bound 3. Two X fall
|||     strictly before Y within the bound (2 and 3); 0 is outside the
|||     window and 4 is not strictly before. Two activations
|||     (`lthe_2_5_1__two_pairs`), two firings `[0, 0]`
|||     (`lthe_2_5_1__trace`), the theorem at the fixture and the count
|||     (`lthe_2_5_1__fires_twice`). The tick to 7 in the middle of the
|||     inputs moves the clock past every `ts` and changes no pair.
|||   * THE `latest` EXCLUSION IS A JOIN TEST (`lthe_2_5_3__excludes`): a
|||     candidate of the anchor's schema strictly between the anchor and the
|||     first follower on `ts` and within the first follower's window blocks
|||     the token -- [RLOW.5.6.5.2]'s ordering and window, a function of the
|||     token and the candidate. The clause's window on the candidate
|||     follows from its ordering and the match the node guards
|||     (`rlow_5_6_5_2__window_implied`). A later step's join is against the
|||     step before it, by rank (`lthe_2_3_1__within_at`, [LTHE.2.3.1]).
|||   * EXECUTED ([LTHE.2.5.3], [LTHE.2.5.5], [LTHE.5.2]): the `ts`-only
|||     shapes of the LTHE.2.5.3 vectors under the bound 30 -- an earlier
|||     anchor excluded by a later one before the follower, a later anchor
|||     excluding nothing, an anchor at the follower's own `ts` excluding
|||     nothing, and on a three-step chain a later anchor excluding nothing,
|||     a newer one excluding, and two second-step facts fanning out into
|||     two firings. One run each; the firing count and, by the emitted
|||     fact's payload, the anchor that fired are read off the trace.
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The exclusion's
||| `where` conjuncts: [LTHE.2.5.3] puts the anchor's `where` and every
||| follower's into the test with the candidate in the anchor's place, and
||| the model's fact carries `ts` alone, so those conjuncts are the Idris model
||| lowering's, conjoined into the same NOT node's test and evaluated by
||| Rete/Eval.idr over the token and the candidate; the vectors whose
||| exclusion turns on a slot other than `ts` are run by the Idris model and not
||| executed here. A candidate whose substituted `where` answers `null`
||| blocks the NOT node ([LNUL.4.7]), and [LTHE.2.5.3] says the
||| same (a newer anchor whose eligibility is
||| unknown excludes), which logical/LTHE.2.5.3_null_candidate_excludes
||| reaches on both runtimes; the model and the clause agree there. A
||| candidate whose substituted `where` traps blocks the node too, and no
||| clause says so: that residue is the trap-blocks-a-`no` ties of Rete/Eval.idr
||| and Rete/NetworkAnswer.idr, not a reading this file settles. A chain of three steps is
||| executed; longer chains are more nodes of the same kind. `window` and
||| `series` are not sequences. The `ts` slot's identity ([LFAC]) is
||| not this file's: `ts` is read as the payload.
module Rete.NetworkThen

-- The imports are Rete/NetworkFrameRetime.idr's whole, for the reason
-- Rete/NetworkSampled.idr's comment gives: a run evaluated in a witness
-- unfolds only through modules the file imports.
import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkView
import Rete.NetworkDispatch
import Rete.NetworkOrderKeep
import Rete.NetworkTransferAgree
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkOnce
import Rete.NetworkFrame
import Rete.NetworkFrameClocked
import Rete.NetworkFrameRetime
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Control.Relation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The sequence's join: on ts, never on the clock
-- ---------------------------------------------------------------------

--@spec [LTHE.2.2.2]
||| A FACT'S `ts`, read as the model's payload: the model's fact has no
||| `ts` slot, and the fixtures put the event time there.
public export
lthe_2_2_2__ts : Lfac_1_7_1__fact -> Nat
lthe_2_2_2__ts f = fpay f

--@spec [LTHE.2.1]
--@spec [LTHE.2.2.2]
||| THE SEQUENCE'S JOIN: Y strictly after X, and within the bound, on the
||| facts' `ts`. The front token holds X; the candidate is Y. A function
||| of the two facts: no clock is read, so it is no `Ltim_2_4_1__timed`.
public export
lthe_2_2_2__within : Nat -> Iret_7_5__join
lthe_2_2_2__within bound (x :: _) f = (lthe_2_2_2__ts x < lthe_2_2_2__ts f) && (minus (lthe_2_2_2__ts f) (lthe_2_2_2__ts x) < bound)
lthe_2_2_2__within bound [] f = False

--@spec [LTHE.2.1]
--@spec [LTHE.2.2.1]
--@spec [LTHE.2.2.3]
||| THE SEQUENCE RULE: X of kind 0 (matched, its slots bound), then Y of
||| kind 1 under the join, the activation holding both; emits kind 2,
||| which neither node reads, so the chain is framed.
public export
lthe_2_1__sequence_rules : Nat -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
lthe_2_1__sequence_rules bound = [ ([(0, iret_7_7__row, False), (1, lthe_2_2_2__within bound, False)], ltim_2_5_1__emit_two) ]

--@spec [LTHE.2.1]
||| THE PROGRAM: the sequence rule alone, every kind explicit.
public export
lthe_2_1__sequence_program : Nat -> Lcyc_3_2_1__program
lthe_2_1__sequence_program bound =
  lcyc_3_2_1__program_of (\k => Explicit) (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three (lthe_2_1__sequence_rules bound)))

--@spec [LTHE.2.2.2]
--@spec [LTIM.2.8.2]
||| THE TIMED TESTS OF A SEQUENCE PROGRAM: none. The sequence's join reads
||| no clock, so the tick re-times nothing.
public export
lthe_2_2_2__untimed : List (Maybe Ltim_2_4_1__timed)
lthe_2_2_2__untimed = [Nothing]

-- ---------------------------------------------------------------------
-- A sequence chain is untimed: a tick leaves it
-- ---------------------------------------------------------------------

--@derives [LTHE.2.2.2]
--@derives [LTIM.2.8.2]
--@derives [IRET.19.5]
||| A TICK LEAVES A CHAIN WITH NO TIMED TEST: the re-time of a chain whose
||| test is `Nothing` is the chain. The clause's "the monotonic clock
||| takes no part", for the chain.
export
lthe_2_2_2__tick_leaves_chain : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (c : Nat) -> (ch : Rlow_4_2_1__chain) ->
                                iret_19_5__tick_chain wm alphas Nothing c ch = ch
lthe_2_2_2__tick_leaves_chain wm alphas c ch = Refl

--@derives [LTHE.2.2.2]
--@derives [LTIM.2.8.2]
--@derives [LDET.5.8]
--@derives [IRET.19.5]
||| A TICK LEAVES AN ENGINE WHOSE ONE CHAIN IS UNTIMED: Rete/NetworkTick.idr's
||| tick with `[Nothing]` is the identity on it. [LDET.5.8]'s "cycling the
||| tick is not a change to the LHS", with nothing for it to change.
export
lthe_2_2_2__tick_leaves_engine : (wm : Rarc_5_6_4__wm) -> (alphas : List Iret_6_1__alpha) -> (c : Nat) -> (ch : Rlow_4_2_1__chain) ->
                                 iret_19_5__tick lthe_2_2_2__untimed c (MkEngine wm (MkNetwork alphas [ch])) = MkEngine wm (MkNetwork alphas [ch])
lthe_2_2_2__tick_leaves_engine wm alphas c ch = Refl

-- ---------------------------------------------------------------------
-- Executed: two pairs in the window, one outside, one not strictly after
-- ---------------------------------------------------------------------

--@spec [LTHE.2.5.1]
--@spec [LTHE.2.2.2]
||| THE INPUTS: four X facts at `ts` 0, 2, 3 and 4 (keys 1 to 4), a tick to
||| 7, then the Y at `ts` 4. Prepared with no run between them.
public export
lthe_2_5_1__inputs : List Rarc_5_6_2__input
lthe_2_5_1__inputs = [Data (Assert 0 1 0), Data (Assert 0 2 2), Data (Assert 0 3 3), Data (Assert 0 4 4), Tick 7, Data (Assert 1 1 4)]

--@spec [LTHE.2.5.1]
||| THE NETWORK AS THE INPUTS LEFT IT, under the bound 3.
public export
lthe_2_5_1__ready : Iret_19_3__clocked_net
lthe_2_5_1__ready =
  rarc_5_6_3__prepared_clocked (lthe_2_1__sequence_program 3) ltim_2_5_1__no_ttl lthe_2_2_2__untimed lthe_2_5_1__inputs
    (rdsc_4a_5__load_clocked ltim_2_5_1__alphas_three (lthe_2_1__sequence_rules 3) 0)

--@spec [LTHE.2.5.1]
||| THE SEQUENCE CHAIN as the inputs left it, read off the network, so that
||| the theorem's hypotheses name its nodes and activations without
||| spelling the left memories by hand.
public export
lthe_2_5_1__chain : Rlow_4_2_1__chain
lthe_2_5_1__chain = fromMaybe (MkChain [] [] []) (rarc_5_6_5__nth 0 (nchains (enet (ncore (nengine lthe_2_5_1__ready)))))

--@derives [LTHE.2.5.1]
--@derives [LTHE.2.2.2]
||| TWO PAIRS: the X at 2 and the X at 3 are strictly before Y's 4 and
||| within 3 of it; the X at 0 is outside the window, the X at 4 not
||| strictly before. Two activations, both unfired, and the tick to 7
||| between the inputs changed neither. Computed.
export
lthe_2_5_1__two_pairs : map (\a => afired a) (cacts lthe_2_5_1__chain) = [False, False]
lthe_2_5_1__two_pairs = Refl

--@derives [LTHE.2.5.1]
--@derives [LTIM.2.5.1]
||| THE SEQUENCE CHAIN IS FRAMED: its one rule emits kind 2, which neither
||| node reads. Computed.
export
lthe_2_5_1__is_framed :
  ltim_2_5_1__framed (nalphas (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three (lthe_2_1__sequence_rules 3))))
                     (nchains (enet (rdsc_4a_5__load ltim_2_5_1__alphas_three (lthe_2_1__sequence_rules 3))))
                     (cnodes lthe_2_5_1__chain) = True
lthe_2_5_1__is_framed = Refl

--@derives [LTHE.2.5.1]
||| The chain read off the network is the chain at ordinal 0. Computed.
export
lthe_2_5_1__chain_at_zero :
  rarc_5_6_5__nth 0 (nchains (enet (ncore (nengine lthe_2_5_1__ready)))) = Just (MkChain (cnodes lthe_2_5_1__chain) (cacts lthe_2_5_1__chain) ltim_2_5_1__emit_two)
lthe_2_5_1__chain_at_zero = Refl

--@derives [LTHE.2.5.1]
--@derives [IRET.11.3]
||| THE TRACE: the sequence rule fires twice, once per pair, `[0, 0]`,
||| quiescent; the four X, the Y and the two kind-2 facts live. Executed,
||| with fuel 3.
export
lthe_2_5_1__trace :
  iret_11_4__trace_of_ttl (iret_11_4__run_ttl_net_traced (lthe_2_1__sequence_program 3) ltim_2_5_1__no_ttl 3 lthe_2_5_1__ready)
    = ([0, 0], Quiescent, [0, 0, 0, 0, 1, 2, 2])
lthe_2_5_1__trace = Refl

--@derives [LTHE.2.5.1]
--@derives [LTHE.2.2.3]
--@derives [IRET.11.3]
--@derives [LTIM.2.5.1]
||| ONCE PER PAIR: Rete/NetworkFrameRetime.idr's theorem at the sequence
||| chain -- the frame by computation, the chain as the inputs left it,
||| the run and the halt by the trace -- counts the rule's firings as its
||| matches when the run began, the valid pairs. Executed.
export
lthe_2_5_1__pairs_is_an_instance :
  ltim_2_5_1__count 0 [0, 0]
    = length (iret_7_7__view (nalphas (enet (ncore (nengine lthe_2_5_1__ready)))) (ewm (ncore (nengine lthe_2_5_1__ready)))
                             (cnodes lthe_2_5_1__chain) [[]])
lthe_2_5_1__pairs_is_an_instance =
  let (cs' ** rt) = iret_11_4__trace_of_ttl_inv (iret_11_4__run_ttl_net_traced (lthe_2_1__sequence_program 3) ltim_2_5_1__no_ttl 3 lthe_2_5_1__ready)
                      [0, 0] Quiescent [0, 0, 0, 0, 1, 2, 2] lthe_2_5_1__trace
  in iret_11_3__framed_fires_once_per_match_clocked (lthe_2_1__sequence_program 3) ltim_2_5_1__no_ttl lthe_2_2_2__untimed 3 0 lthe_2_5_1__inputs
       ltim_2_5_1__alphas_three (lthe_2_1__sequence_rules 3)
       0 (cnodes lthe_2_5_1__chain) (cacts lthe_2_5_1__chain) ltim_2_5_1__emit_two
       lthe_2_5_1__is_framed lthe_2_5_1__chain_at_zero cs' Quiescent [0, 0] rt Refl

--@derives [LTHE.2.5.1]
||| And the number is two: one activation per valid pair, each fired once.
||| Computed.
export
lthe_2_5_1__fires_twice :
  ( ltim_2_5_1__count 0 [0, 0]
  , length (iret_7_7__view (nalphas (enet (ncore (nengine lthe_2_5_1__ready)))) (ewm (ncore (nengine lthe_2_5_1__ready)))
                           (cnodes lthe_2_5_1__chain) [[]]) ) = (2, 2)
lthe_2_5_1__fires_twice = Refl

-- ---------------------------------------------------------------------
-- `latest`: the exclusion as a NOT sub-node's join test after the last join
-- ---------------------------------------------------------------------

--@spec [LTHE.2.5.3]
--@spec [RLOW.5.6.5.2]
--@spec [IRET.7.10.2]
||| THE EXCLUSION: the NOT sub-node's join test, placed after the sequence's
||| last join, where the token holds the anchor first and the first
||| follower second ([IRET.7.10.2]). A candidate `f` of the anchor's schema
||| blocks the token when `d.ts < f.ts`, `f.ts < m.ts` and `m.ts - f.ts`
||| is under the bound: [RLOW.5.6.5.2]'s ordering and window on `ts`,
||| [LTHE.2.5.3]'s `A.ts < A'.ts` and "precede `B` strictly". The `where`s
||| the clause substitutes are the lowering's, conjoined into this test and
||| evaluated by Rete/Eval.idr over the token and the candidate; the
||| model's fact carries `ts` alone. A function of the token and one
||| candidate and of nothing else: a join test of this network
||| ([IRET.7.5]) on a NOT node ([IRET.7.9]), no new node kind.
public export
lthe_2_5_3__excludes : Nat -> Iret_7_5__join
lthe_2_5_3__excludes bound (d :: m :: _) f =
  (lthe_2_2_2__ts d < lthe_2_2_2__ts f) && ((lthe_2_2_2__ts f < lthe_2_2_2__ts m) && (minus (lthe_2_2_2__ts m) (lthe_2_2_2__ts f) < bound))
lthe_2_5_3__excludes bound _ f = False

--@derives [RLOW.5.6.5.2]
||| `minus n k` is at most `n`.
export
rlow_5_6_5_2__minus_le : (n, k : Nat) -> LTE (minus n k) n
rlow_5_6_5_2__minus_le Z k = LTEZero
rlow_5_6_5_2__minus_le (S n) Z = reflexive
rlow_5_6_5_2__minus_le (S n) (S k) = lteSuccRight (rlow_5_6_5_2__minus_le n k)

--@derives [RLOW.5.6.5.2]
||| Subtracting more leaves less: `d <= f` gives `m - f <= m - d`.
export
rlow_5_6_5_2__minus_antitone : (d, f, m : Nat) -> LTE d f -> LTE (minus m f) (minus m d)
rlow_5_6_5_2__minus_antitone d f Z p = LTEZero
rlow_5_6_5_2__minus_antitone Z f (S m) p = rlow_5_6_5_2__minus_le (S m) f
rlow_5_6_5_2__minus_antitone (S d) (S f) (S m) (LTESucc p) = rlow_5_6_5_2__minus_antitone d f m p
rlow_5_6_5_2__minus_antitone (S d) Z (S m) _ impossible

--@derives [RLOW.5.6.5.2]
--@derives [IRET.7.10.2]
||| THE WINDOW ON THE CANDIDATE IS IMPLIED: a candidate after the anchor,
||| `d.ts < f.ts`, is within the first follower's window whenever the
||| anchor is, `m.ts - d.ts < T`. The clause's `m.ts - f.ts < T` follows
||| from its `d.ts < f.ts` and the match the NOT sub-node guards, so a
||| lowering may carry the conjunct or leave it; `lthe_2_5_3__excludes`
||| and the fixture lowering carry it.
export
rlow_5_6_5_2__window_implied : (d, f, m, bound : Nat) -> LT d f -> LT (minus m d) bound -> LT (minus m f) bound
rlow_5_6_5_2__window_implied d f m bound dlt mlt =
  transitive (LTESucc (rlow_5_6_5_2__minus_antitone d f m (lteSuccLeft dlt))) mlt

--@spec [LTHE.2.3.1]
--@spec [LTHE.2.2.2]
||| A LATER STEP'S JOIN, from the fact the step before it bound: strictly
||| after it and within the bound on `ts`, or nothing to join when the
||| token has no such fact.
public export
lthe_2_3_1__within_from : Nat -> Maybe Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool
lthe_2_3_1__within_from bound Nothing f = False
lthe_2_3_1__within_from bound (Just x) f = (lthe_2_2_2__ts x < lthe_2_2_2__ts f) && (minus (lthe_2_2_2__ts f) (lthe_2_2_2__ts x) < bound)

--@spec [LTHE.2.3.1]
--@spec [LTHE.2.2.2]
||| A LATER STEP'S JOIN AT A RANK: against the token's fact at rank `r`,
||| the step immediately before it and never the anchor ([LTHE.2.3.1]);
||| `lthe_2_2_2__within` is this at rank 0.
public export
lthe_2_3_1__within_at : Nat -> Nat -> Iret_7_5__join
lthe_2_3_1__within_at bound r tok f = lthe_2_3_1__within_from bound (rarc_5_6_5__nth r tok) f

--@spec [LTHE.2.5.3]
||| THE ANCHOR'S `ts`, read off the bound facts, so that an emit can carry
||| out which anchor fired.
public export
lthe_2_5_3__anchor_ts : List Lfac_1_7_1__fact -> Nat
lthe_2_5_3__anchor_ts (d :: _) = lthe_2_2_2__ts d
lthe_2_5_3__anchor_ts [] = 0

--@spec [LTHE.2.5.3]
||| THE RHS OF THE `latest` FIXTURES: emit kind `k` with the anchor's `ts`
||| as its payload; `k` is read by no node, so the chain is framed.
public export
lthe_2_5_3__emit_anchor : Nat -> List Lgra_10_1__action
lthe_2_5_3__emit_anchor k = [Emit k (\b => (0, lthe_2_5_3__anchor_ts b))]

--@spec [LTHE.2.5.3]
--@spec [RLOW.5.6.5.2]
--@spec [IRET.7.10.2]
||| THE `latest` SEQUENCE RULE: the anchor of kind 0, the follower of kind
||| 1 under the sequence's join, then the NOT sub-node on the anchor's
||| alpha under the exclusion, after the last join as [IRET.7.10.2] places
||| it; emits kind 2.
public export
lthe_2_5_3__latest_rules : Nat -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
lthe_2_5_3__latest_rules bound =
  [ ([(0, iret_7_7__row, False), (1, lthe_2_2_2__within bound, False), (0, lthe_2_5_3__excludes bound, True)], lthe_2_5_3__emit_anchor 2) ]

--@spec [LTHE.2.5.3]
--@spec [LTHE.2.5.5]
||| THE ALPHAS OF THE CHAIN FIXTURES: four kinds, the emitted kind among
||| them, each admitting every fact.
public export
lthe_2_5_3__alphas_four : List (Nat, Lfac_1_7_1__fact -> Bool)
lthe_2_5_3__alphas_four = [(0, ltim_2_5_1__admits_all), (1, ltim_2_5_1__admits_all), (2, ltim_2_5_1__admits_all), (3, ltim_2_5_1__admits_all)]

--@spec [LTHE.2.5.3]
--@spec [LTHE.2.5.5]
--@spec [LTHE.2.3.1]
||| THE `latest` CHAIN RULE: the anchor (kind 0), a first follower (kind 1)
||| joined to it, a second (kind 2) joined to the first and not to the
||| anchor ([LTHE.2.3.1]), then the NOT sub-node after the last join; emits
||| kind 3.
public export
lthe_2_5_3__chain_rules : Nat -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
lthe_2_5_3__chain_rules bound =
  [ ([(0, iret_7_7__row, False), (1, lthe_2_2_2__within bound, False), (2, lthe_2_3_1__within_at bound 1, False), (0, lthe_2_5_3__excludes bound, True)], lthe_2_5_3__emit_anchor 3) ]

--@spec [LTHE.2.5.3]
||| A live fact's kind and payload: for an emitted fact, the kind it was
||| emitted into and the `ts` of the anchor that fired.
public export
lthe_2_5_3__kind_pay : Lfac_1_7_1__fact -> (Nat, Nat)
lthe_2_5_3__kind_pay f = (fkind f, fpay f)

--@spec [LTHE.2.5.3]
||| WHAT A TRACED RUN SHOWS: its trace, its halt, and each live fact's kind
||| and payload. By pattern matching, one evaluation for all three.
public export
lthe_2_5_3__shown : (Iret_19_3__clocked_net, Iret_11_4__halt, List Nat) -> (List Nat, Iret_11_4__halt, List (Nat, Nat))
lthe_2_5_3__shown (cs, h, tr) = (tr, h, map lthe_2_5_3__kind_pay (ewm (ncore (nengine cs))))

--@spec [LTHE.2.5.3]
||| THE RUN OF A `latest` FIXTURE: the inputs prepared on the loaded
||| network with no run between them, then the traced pump with fuel 3,
||| shown. One term, so that each witness states its inputs and its answer.
public export
lthe_2_5_3__run : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) ->
                  List Rarc_5_6_2__input -> (List Nat, Iret_11_4__halt, List (Nat, Nat))
lthe_2_5_3__run alphas rules inputs =
  lthe_2_5_3__shown
    (iret_11_4__run_ttl_net_traced (lcyc_3_2_1__program_of (\k => Explicit) (enet (rdsc_4a_5__load alphas rules))) ltim_2_5_1__no_ttl 3
      (rarc_5_6_3__prepared_clocked (lcyc_3_2_1__program_of (\k => Explicit) (enet (rdsc_4a_5__load alphas rules))) ltim_2_5_1__no_ttl
         lthe_2_2_2__untimed inputs (rdsc_4a_5__load_clocked alphas rules 0)))

--@derives [LTHE.2.5.3]
--@derives [RLOW.5.6.5.3]
||| AN EARLIER ANCHOR IS EXCLUDED: anchors at `ts` 1 and 2, the follower
||| at 3, bound 30. The anchor at 2 precedes the follower and would
||| complete the sequence with it, so it excludes the anchor at 1: one
||| firing, and the emitted fact names the anchor at 2. Executed
||| (logical/LTHE.2.5.3_earlier_anchor_is_excluded, on `ts` alone).
export
lthe_2_5_3__earlier_anchor_is_excluded :
  lthe_2_5_3__run ltim_2_5_1__alphas_three (lthe_2_5_3__latest_rules 30) [Data (Assert 0 1 1), Data (Assert 0 2 2), Data (Assert 1 1 3)]
    = ([0], Quiescent, [(0, 1), (0, 2), (1, 3), (2, 2)])
lthe_2_5_3__earlier_anchor_is_excluded = Refl

--@derives [LTHE.2.5.3]
--@derives [RLOW.5.6.5.3]
||| A LATER ANCHOR DOES NOT EXCLUDE: the anchor at 1, the follower at 2,
||| then an anchor at 3, asserted after both. It is not before the
||| follower, so it excludes nothing, whenever it arrived: one firing, on
||| the anchor at 1. Executed (logical/LTHE.2.5.3_later_anchor_does_not_exclude).
export
lthe_2_5_3__later_anchor_does_not_exclude :
  lthe_2_5_3__run ltim_2_5_1__alphas_three (lthe_2_5_3__latest_rules 30) [Data (Assert 0 1 1), Data (Assert 1 1 2), Data (Assert 0 2 3)]
    = ([0], Quiescent, [(0, 1), (1, 2), (0, 3), (2, 1)])
lthe_2_5_3__later_anchor_does_not_exclude = Refl

--@derives [LTHE.2.5.3]
--@derives [LTHE.5.2]
||| AN ANCHOR AT THE FOLLOWER'S OWN `ts` DOES NOT EXCLUDE: anchors at 1 and
||| 3, the follower at 3. "Precede strictly" ([LTHE.5.2]): the anchor at 3
||| is not before the follower, so it neither matches it nor excludes the
||| anchor at 1: one firing, on the anchor at 1. Executed
||| (logical/LTHE.2.5.3_anchor_at_follower_ts_does_not_exclude).
export
lthe_2_5_3__anchor_at_follower_ts_does_not_exclude :
  lthe_2_5_3__run ltim_2_5_1__alphas_three (lthe_2_5_3__latest_rules 30) [Data (Assert 0 1 1), Data (Assert 0 2 3), Data (Assert 1 1 3)]
    = ([0], Quiescent, [(0, 1), (0, 3), (1, 3), (2, 1)])
lthe_2_5_3__anchor_at_follower_ts_does_not_exclude = Refl

--@derives [LTHE.2.5.3]
--@derives [IRET.7.10.2]
||| ON A CHAIN, A LATER ANCHOR DOES NOT EXCLUDE: the anchor at 1, the first
||| follower at 2, an anchor at 3, the second follower at 4. The NOT
||| sub-node sits after the last join and orders the candidate against the
||| FIRST follower, which the anchor at 3 does not precede: one firing, on
||| the anchor at 1. Executed (logical/LTHE.2.5.3_chain_later_anchor_does_not_exclude).
export
lthe_2_5_3__chain_later_anchor_does_not_exclude :
  lthe_2_5_3__run lthe_2_5_3__alphas_four (lthe_2_5_3__chain_rules 30) [Data (Assert 0 1 1), Data (Assert 1 1 2), Data (Assert 0 2 3), Data (Assert 2 1 4)]
    = ([0], Quiescent, [(0, 1), (1, 2), (0, 3), (2, 4), (3, 1)])
lthe_2_5_3__chain_later_anchor_does_not_exclude = Refl

--@derives [LTHE.2.5.3]
--@derives [RLOW.5.6.5.2]
||| ON A CHAIN, A NEWER ANCHOR EXCLUDES: anchors at 1 and 2, the followers
||| at 3 and 4. The anchor at 2 precedes the first follower within the
||| window and completes the chain with the same followers, so it excludes
||| the anchor at 1: one firing, and the emitted fact names the anchor at
||| 2. Executed (the `ts` shape of
||| logical/LTHE.2.5.3_chain_newer_anchor_passing_later_where_excludes).
export
lthe_2_5_3__chain_newer_anchor_excludes :
  lthe_2_5_3__run lthe_2_5_3__alphas_four (lthe_2_5_3__chain_rules 30) [Data (Assert 0 1 1), Data (Assert 0 2 2), Data (Assert 1 1 3), Data (Assert 2 1 4)]
    = ([0], Quiescent, [(0, 1), (0, 2), (1, 3), (2, 4), (3, 2)])
lthe_2_5_3__chain_newer_anchor_excludes = Refl

--@derives [LTHE.2.5.5]
--@derives [LTHE.2.5.3]
||| LATER STEPS FAN OUT: the anchor at 1, two first followers at 2 and 3,
||| the second follower at 4, which follows each within the window. The
||| anchor is pinned and nothing excludes it; the second step matches
||| twice and the third once after each: two firings, both on the anchor
||| at 1 -- [LTHE.2.5.5]'s "if two facts match the second step and each
||| is followed by a fact matching the third, the rule fires twice".
||| Executed.
export
lthe_2_5_5__later_steps_fan_out :
  lthe_2_5_3__run lthe_2_5_3__alphas_four (lthe_2_5_3__chain_rules 30) [Data (Assert 0 1 1), Data (Assert 1 1 2), Data (Assert 1 2 3), Data (Assert 2 1 4)]
    = ([0, 0], Quiescent, [(0, 1), (1, 2), (1, 3), (2, 4), (3, 1), (3, 1)])
lthe_2_5_5__later_steps_fan_out = Refl

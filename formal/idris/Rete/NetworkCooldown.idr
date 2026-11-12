-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| COOLDOWN ON THE CLOCKED NETWORK: Rete/RateGate.idr's gate threaded
||| through the firing of the engine Fixture.idr runs ([LCDB.3.2.1],
||| [LCDB.3.2.1.1], [RLOW.4.6.2.1] to [RLOW.4.6.2.3], [IRET.10.4],
||| [RDSC.4a.8.2.3]).
|||
||| NORMATIVE COMPANION to Rete/NetworkTraced.idr, whose traced clocked
||| pump this file gates, and to Rete/RateGate.idr, whose
||| `rlow_4_6_2_2__allows` is the whole of the decision.
|||
||| WHAT IS MODELLED. Beside the clocked network engine of Rete/NetworkTtl.idr
||| a table of TRACKERS, `(rule ordinal, key code) -> last allowed instant`
||| ([IRET.10.4]'s per-engine state keyed `(name, activation_key)`;
||| [RLOW.4.6.2.1]'s `(rule_name, activation_key) -> last_fire_ns`). A lookup
||| that finds no entry is the stamp `Nothing` of Rete/RateGate.idr, so a
||| key that has never fired is an absence and not an instant, and instant
||| zero is a stamp like any other ([RLOW.4.6.2.2]). A rule's COOLDOWN is
||| its window in clock units and its activation key as a function of the
||| fired match (`Lcdb_3_2_1__cool`), given per rule by ordinal as the
||| timed tests are given to Rete/NetworkClocked.idr; a rule with none runs
||| as it did. The GATED FIRING (`lcdb_3_2_1__fire_gated`) selects and marks
||| as `iret_11_4__fire_ttl_net` does -- the activation fires, refraction
||| marks it, [LCDB.3.2.1.1] -- and then, for a rule with a cooldown, asks
||| the gate at the net's clock with the key of the fired match: admitted,
||| the actions run and the key is stamped with the clock; refused, no
||| action runs and nothing moves but the `fired` flag. The gated pump is
||| Rete/RunFold.idr's traced fold over that firing, each firing named with
||| its ordinal, its facts and the gate's verdict; an input (a data event
||| or a tick) prepares the net as Rete/NetworkTtl.idr does and moves no
||| tracker. What this engine holds, the runner prints, with a `gated`
||| line after a refused firing's `fired` line.
|||
||| THE KEY IS THE LOWERING'S. [LCDB.3.3.3]'s composition and [LCDB.3.3.4]'s
||| `by:` paths are expressions over the fired match's facts, lowered by the
||| fixture lowering and evaluated by Rete/Eval.idr; their tuple is CODED
||| (Fixture.idr, THE VALUE CODE), and the code's equality is
||| [RLOW.4.6.2.1]'s identity -- the same length and, per position, the
||| same representation tag and an equal value under it: an Int and a Time
||| one key, `1` and `"1"` two, the two zeros one, a Json by its canonical
||| text, `null` only `null`. This file takes the key as a function of the
||| token and states nothing of the composition ([LCDB.3.3.3]), which is
||| the fixture lowering's; the fixtures below key on a fact's identity
||| key, on a payload slot, or on nothing.
|||
||| PROVED, each over every program, state and tracker table.
|||
|||   * THE GATE ([RLOW.4.6.2.2]): a key with no recorded firing is admitted
|||     and stamped (`rlow_4_6_2_2__first_firing_admitted`); inside the
|||     window it is refused and the trackers do not move
|||     (`lcdb_3_2_1__window_suppresses`); at or past the boundary it is
|||     admitted and restamped (`rlow_4_6_2_2__refires_at_the_boundary`),
|||     the boundary itself included (`rlow_4_6_2_2__boundary_is_inclusive`,
|||     the instant `rgate.cool_refire` pins).
|||   * DISTINCT KEYS, INDEPENDENT STATE ([RLOW.4.6.2.3]): a stamp under one
|||     key leaves every other key's lookup as it was
|||     (`rlow_4_6_2_3__other_key_unmoved`).
|||   * A RULE WITH NO COOLDOWN FIRES AS THE PLAIN ENGINE FIRES
|||     (`lcdb_3_2_1__uncooled_rule_fires_plain`), and THE FRAME
|||     (`lcdb_3_2_1__no_cooldown_is_the_plain_pump`): with no rule cooled,
|||     the gated traced pump's net, halt and trace are
|||     `iret_11_4__run_ttl_net_traced`'s, every firing admitted, and the
|||     trackers are the ones given. Every fixture the Idris model compares today
|||     runs through the gated pump, and its agreements hold by this theorem
|||     rather than by a rerun.
|||   * AN ADMITTED FIRING IS THE FIRING ([LCDB.3.2.1.1]): its net is
|||     `iret_11_4__fire_ttl_net`'s, and the trackers gain the key at the
|||     clock (`lcdb_3_2_1_1__allowed_is_the_firing`). A REFUSED FIRING RUNS
|||     NO ACTION: its net is the net with that activation marked fired and
|||     nothing else -- working memory, the dependency rows, the deadlines
|||     and the clock as they were -- and the trackers do not move
|||     (`lcdb_3_2_1_1__suppressed_runs_no_action`,
|||     `rlow_4_6_2_2__refused_keeps`).
|||   * A SUPPRESSED FIRING IS STILL THE MATCH'S FIRING ([RDSC.4a.8.2.3]):
|||     after it the selected activation carries `fired`
|||     (`rdsc_4a_8_2_3__suppressed_is_still_the_firing`), and the selection
|||     of [IRET.11.4] 1a takes the first activation NOT fired
|||     (`iret_11_3_1__first_unfired`), so the match is not selected again
|||     while it persists; Rete/NetworkRefraction.idr is the general
|||     statement of that flag.
|||   * ONE LOOKUP, AT MOST ONE STAMP, PER FIRING ([RDSC.4a.8.2.3]): the
|||     trackers after any firing are the trackers before, or those with the
|||     fired rule's key stamped at the clock in front
|||     (`rdsc_4a_8_2_3__gate_once`).
|||   * EXECUTED: `formal/k/rgate.k`'s five schedules on this engine --
|||     `cool_first`, `cool_refire`, `cool_suppress` (the zero instant, the
|||     first fire at clock 0 kept by the `Maybe`), `cool_perkey` and
|||     `key_separates` -- each a `Refl` on the verdicts read off the gated
|||     pump's trace, the same sequences `rgate.k`'s `.expected` files carry:
|||     the K-to-Idris interlock by executed vectors, for this gate. And
|||     [LCDB.3.3.4]'s shape (a ttl schema under a `by:` path to a payload
|||     slot) and [LCDB.3.3.3]'s empty key (two facts, one window).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The key composition
||| (the lowering's; above). The value code's injectivity (run, Main.idr).
||| The guard's condition half: [RDSC.4a.8.2.3] evaluates the gate only for
||| an activation whose condition was `true`, and here the guard is the
||| gate alone, which [RDSC.4a.8.2.1] says of an untimed rule; the timed
||| `where` is the Idris lane's rung R4. One clock: the net's clock is the
||| monotonic sample ([LTIM.2.8.2]), the harness moving the two clocks
||| alike ([NLFC.5.4]); the wall clock is beside, Rete/NetworkTwoClocks.idr's.
||| A tracker is never evicted: libds's rate table evicts an entry whose
||| window has lapsed, which changes no verdict, and nothing here models
||| the table's capacity. A call site's cooldown (`<rule>#call<N>`,
||| [RLOW.4.6.6.1]) is outside the fragment: calls are. The `fired` flag's
||| whole story is Rete/NetworkRefraction.idr's, not restated.
module Rete.NetworkCooldown

-- The imports are Rete/NetworkTraced.idr's whole: a run evaluated in a
-- witness unfolds only through modules the file imports.
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
import Rete.NetworkTtl
import Rete.NetworkTraced
import Rete.RunFold
import Rete.RateGate
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The trackers [IRET.10.4], [RLOW.4.6.2.1], [RLOW.4.6.2.2]
-- ---------------------------------------------------------------------

--@spec [IRET.10.4]
--@spec [RLOW.4.6.2.1]
||| THE TRACKERS: per `(rule ordinal, key code)`, the last allowed instant.
||| A stamp is recorded in front, and a lookup reads the newest; absence is
||| the honest "never fired".
public export
Iret_10_4__trackers : Type
Iret_10_4__trackers = List ((Nat, Nat), Nat)

--@spec [RLOW.4.6.2.1]
||| TWO TRACKER KEYS ARE ONE KEY when the rule and the key code are equal.
||| The code is the value code of the activation key's tuple, so its
||| equality is the clause's identity (the header).
public export
rlow_4_6_2_1__same_key : (Nat, Nat) -> (Nat, Nat) -> Bool
rlow_4_6_2_1__same_key (r, k) (r', k') = (r == r') && (k == k')

--@spec [RLOW.4.6.2.2]
--@spec [IRET.10.4]
||| THE RECORDED STAMP of a key: Rete/RateGate.idr's `Maybe Nat`, `Nothing`
||| for a key with no recorded firing.
public export
rlow_4_6_2_2__lookup : Iret_10_4__trackers -> (Nat, Nat) -> Rlow_4_6_2_2__stamp
rlow_4_6_2_2__lookup [] rk = Nothing
rlow_4_6_2_2__lookup ((rk', c) :: rest) rk = if rlow_4_6_2_1__same_key rk rk' then Just c else rlow_4_6_2_2__lookup rest rk

--@spec [RLOW.4.6.2.2]
||| THE VERDICT APPLIED: admitted, the key is stamped with the instant;
||| refused, nothing moves. By pattern matching on the verdict, so a proof
||| can split on it.
public export
rlow_4_6_2_2__decide : Bool -> (Nat, Nat) -> Nat -> Iret_10_4__trackers -> (Bool, Iret_10_4__trackers)
rlow_4_6_2_2__decide True  rk now st = (True, (rk, now) :: st)
rlow_4_6_2_2__decide False rk now st = (False, st)

--@spec [IRET.10.4]
--@spec [RLOW.4.6.2.2]
||| THE RATE-ALLOW BUILTIN: the decision is Rete/RateGate.idr's gate over
||| the key's recorded stamp at the instant, and nothing else; on allow the
||| entry `key -> now` is recorded ("updates `last_fire_ns = now_ns`").
public export
iret_10_4__allow : (window, now : Nat) -> (Nat, Nat) -> Iret_10_4__trackers -> (Bool, Iret_10_4__trackers)
iret_10_4__allow window now rk st =
  rlow_4_6_2_2__decide (rlow_4_6_2_2__allows window now (rlow_4_6_2_2__lookup st rk)) rk now st

-- ---------------------------------------------------------------------
-- A rule's cooldown [LCDB.3.2.1], [LCDB.3.3.3], [LCDB.3.3.4]
-- ---------------------------------------------------------------------

--@spec [LCDB.3.2.1]
--@spec [LCDB.3.3.3]
--@spec [LCDB.3.3.4]
||| A RULE'S COOLDOWN: its window in clock units, and its activation key as
||| a function of the fired match -- the lowering's composition
||| ([LCDB.3.3.3]) or `by:` paths ([LCDB.3.3.4]), coded -- or nothing for
||| a rule with no `cooldown`.
public export
Lcdb_3_2_1__cool : Type
Lcdb_3_2_1__cool = Maybe (Nat, Iret_7_1__token -> Nat)

--@spec [LCDB.3.2.1]
||| The cooldown of the rule at an ordinal; none past the list.
public export
lcdb_3_2_1__cool_at : List Lcdb_3_2_1__cool -> Nat -> Lcdb_3_2_1__cool
lcdb_3_2_1__cool_at [] r = Nothing
lcdb_3_2_1__cool_at (c :: cs) Z = c
lcdb_3_2_1__cool_at (c :: cs) (S r) = lcdb_3_2_1__cool_at cs r

--@spec [LCDB.3.2.1]
||| No rule cooled: the frame theorem's hypothesis.
public export
lcdb_3_2_1__uncooled : List Lcdb_3_2_1__cool -> Bool
lcdb_3_2_1__uncooled [] = True
lcdb_3_2_1__uncooled (Nothing :: cs) = lcdb_3_2_1__uncooled cs
lcdb_3_2_1__uncooled (Just _ :: cs) = False

-- ---------------------------------------------------------------------
-- The gated firing [LCDB.3.2.1.1], [RDSC.4a.8.2.3]
-- ---------------------------------------------------------------------

--@spec [LCDB.3.2.1]
||| The clocked network engine with its trackers beside it: what the gated
||| pump runs on.
public export
Lcdb_3_2_1__gated_state : Type
Lcdb_3_2_1__gated_state = (Iret_19_3__clocked_net, Iret_10_4__trackers)

--@spec [LCDB.3.2.1.1]
||| THE RHS UNDER A VERDICT: admitted, the actions run on the marked net;
||| refused, the marked net stands and no action runs. The trackers are
||| the verdict's.
public export
lcdb_3_2_1_1__run_if : (Bool, Iret_10_4__trackers) -> Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> List Lgra_10_1__action ->
                       Iret_19_3__clocked_net -> (Bool, (Iret_19_3__clocked_net, Iret_10_4__trackers))
lcdb_3_2_1_1__run_if (True, st)  pg ttl r a acts marked = (True, (rarc_5_6_7__do_actions_ttl_net pg ttl r a acts marked, st))
lcdb_3_2_1_1__run_if (False, st) pg ttl r a acts marked = (False, (marked, st))

--@spec [LCDB.3.2.1.1]
--@spec [RDSC.4a.8.2.3]
--@spec [LTIM.2.8.2]
||| THE RHS GATED: a rule with no cooldown runs its actions with the
||| trackers untouched; otherwise the gate decides at the net's clock --
||| the monotonic sample, [LTIM.2.8.2] -- with the key of the fired match,
||| once, after the activation was marked and before the first action
||| ([RDSC.4a.8.2.3]).
public export
lcdb_3_2_1_1__rhs_gated : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Lcdb_3_2_1__cool -> Nat -> Iret_8_1__act -> List Lgra_10_1__action ->
                          Nat -> Iret_10_4__trackers -> Iret_19_3__clocked_net -> (Bool, (Iret_19_3__clocked_net, Iret_10_4__trackers))
lcdb_3_2_1_1__rhs_gated pg ttl Nothing r a acts c st marked = (True, (rarc_5_6_7__do_actions_ttl_net pg ttl r a acts marked, st))
lcdb_3_2_1_1__rhs_gated pg ttl (Just (window, kf)) r a acts c st marked =
  lcdb_3_2_1_1__run_if (iret_10_4__allow window c (r, kf (atuple a)) st) pg ttl r a acts marked

--@spec [LCDB.3.2.1]
||| THE SELECTION of [IRET.11.4] 1a, with the chain and the activation it
||| names: what `iret_11_4__fire_ttl_net` resolves before it fires.
public export
lcdb_3_2_1__selected : Iret_19__engine -> Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act)
lcdb_3_2_1__selected eng = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just ch => case rarc_5_6_5__nth j (cacts ch) of
      Nothing => Nothing
      Just a  => Just (r, j, ch, a)

--@spec [LCDB.3.2.1]
||| A firing named: the ordinal, the fired facts and the verdict, with the
||| state after it. By projections, so that it reduces on a result that is
||| not yet a pair.
public export
lcdb_3_2_1__label : Nat -> Iret_7_1__token -> (Bool, Lcdb_3_2_1__gated_state) -> Maybe ((Nat, Iret_7_1__token, Bool), Lcdb_3_2_1__gated_state)
lcdb_3_2_1__label r fs x = Just ((r, fs, fst x), snd x)

--@spec [LCDB.3.2.1]
||| THE FIRING AT A SELECTION: mark the activation fired, then the gated
||| RHS.
public export
lcdb_3_2_1__fire_at : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_19__engine -> Iret_12_4__table -> Iret_4_3__deadlines -> Nat ->
                      Iret_10_4__trackers -> Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act) -> Maybe ((Nat, Iret_7_1__token, Bool), Lcdb_3_2_1__gated_state)
lcdb_3_2_1__fire_at pg ttl cools eng rows dl c st Nothing = Nothing
lcdb_3_2_1__fire_at pg ttl cools eng rows dl c st (Just (r, j, ch, a)) =
  lcdb_3_2_1__label r (atuple a)
    (lcdb_3_2_1_1__rhs_gated pg ttl (lcdb_3_2_1__cool_at cools r) r a (cactions ch) c st (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c))

--@spec [LCDB.3.2.1]
--@spec [LCDB.3.2.1.1]
--@spec [RDSC.4a.8.2.3]
||| THE GATED FIRING: select and mark as `iret_11_4__fire_ttl_net` does --
||| the activation fires, refraction marks it, the budget is spent -- then
||| the RHS under the gate. Named with its ordinal, its facts and the
||| verdict, as a firing Rete/RunFold.idr's traced fold takes.
public export
lcdb_3_2_1__fire_gated : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Lcdb_3_2_1__gated_state -> Maybe ((Nat, Iret_7_1__token, Bool), Lcdb_3_2_1__gated_state)
lcdb_3_2_1__fire_gated pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c, st) = lcdb_3_2_1__fire_at pg ttl cools eng rows dl c st (lcdb_3_2_1__selected eng)

--@spec [LCDB.3.2.1]
||| THE GATED PUMP, TRACED: the traced fold over the gated firing -- the
||| firings in order, each with its verdict, the state and the halt.
public export
lcdb_3_2_1__run_gated_traced : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Nat -> Lcdb_3_2_1__gated_state ->
                               (Lcdb_3_2_1__gated_state, Iret_11_4__halt, List (Nat, Iret_7_1__token, Bool))
lcdb_3_2_1__run_gated_traced pg ttl cools fuel s = iret_11_4__trace_by (lcdb_3_2_1__fire_gated pg ttl cools) fuel s

--@spec [IRET.10.4]
||| AN INPUT prepares the net as Rete/NetworkTtl.idr does -- the sweep, then
||| the data event or the tick -- and leaves the trackers: per-engine
||| state, which a tick or an input does not read.
public export
iret_10_4__prepare_gated : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Rarc_5_6_2__input -> Lcdb_3_2_1__gated_state -> Lcdb_3_2_1__gated_state
iret_10_4__prepare_gated pg ttl inp (cs, st) = (rarc_5_6_3__prepare_net pg ttl inp cs, st)

--@spec [LCDB.3.2.1]
||| The verdicts of a trace: each firing's ordinal and whether the gate
||| admitted it.
public export
lcdb_3_2_1__verdicts : List (Nat, Iret_7_1__token, Bool) -> List (Nat, Bool)
lcdb_3_2_1__verdicts [] = []
lcdb_3_2_1__verdicts ((r, fs, ok) :: tr) = (r, ok) :: lcdb_3_2_1__verdicts tr

--@spec [LCDB.3.2.1]
||| A FIXTURE'S STEPS on the gated engine, in its cadence: an input
||| prepared, a pump under its fuel; the verdicts of every pump, in order.
public export
lcdb_3_2_1__run_steps_gated : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List Rarc_5_6_2__step -> Lcdb_3_2_1__gated_state ->
                              (Lcdb_3_2_1__gated_state, List (Nat, Bool))
lcdb_3_2_1__run_steps_gated pg ttl cools [] s = (s, [])
lcdb_3_2_1__run_steps_gated pg ttl cools (SInput inp :: ss) s = lcdb_3_2_1__run_steps_gated pg ttl cools ss (iret_10_4__prepare_gated pg ttl inp s)
lcdb_3_2_1__run_steps_gated pg ttl cools (SPumpT fuel :: ss) s = case lcdb_3_2_1__run_gated_traced pg ttl cools fuel s of
  (s', h, tr) => case lcdb_3_2_1__run_steps_gated pg ttl cools ss s' of
    (s'', vs) => (s'', lcdb_3_2_1__verdicts tr ++ vs)

-- ---------------------------------------------------------------------
-- The gate [RLOW.4.6.2.2], [RLOW.4.6.2.3]
-- ---------------------------------------------------------------------

--@derives [RLOW.4.6.2.2]
||| The gate's `true` applied: the key is stamped with the instant.
export
rlow_4_6_2_2__allow_admits : (window, now : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                             rlow_4_6_2_2__allows window now (rlow_4_6_2_2__lookup st rk) = True ->
                             iret_10_4__allow window now rk st = (True, (rk, now) :: st)
rlow_4_6_2_2__allow_admits window now rk st h = rewrite h in Refl

--@derives [RLOW.4.6.2.2]
||| The gate's `false` applied: nothing moves.
export
rlow_4_6_2_2__allow_refuses : (window, now : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                              rlow_4_6_2_2__allows window now (rlow_4_6_2_2__lookup st rk) = False ->
                              iret_10_4__allow window now rk st = (False, st)
rlow_4_6_2_2__allow_refuses window now rk st h = rewrite h in Refl

--@derives [RLOW.4.6.2.2]
||| A refused verdict leaves the trackers, whichever verdict it was.
export
rlow_4_6_2_2__decide_false : (b : Bool) -> (rk : (Nat, Nat)) -> (now : Nat) -> (st, st' : Iret_10_4__trackers) ->
                             rlow_4_6_2_2__decide b rk now st = (False, st') -> st' = st
rlow_4_6_2_2__decide_false True  rk now st st' h = absurd (cong fst h)
rlow_4_6_2_2__decide_false False rk now st st' h = sym (cong snd h)

--@derives [RLOW.4.6.2.2]
||| A verdict stamps the key or leaves the trackers, and nothing else.
export
rlow_4_6_2_2__decide_once : (b : Bool) -> (rk : (Nat, Nat)) -> (now : Nat) -> (st : Iret_10_4__trackers) ->
                            Either (snd (rlow_4_6_2_2__decide b rk now st) = st) (snd (rlow_4_6_2_2__decide b rk now st) = (rk, now) :: st)
rlow_4_6_2_2__decide_once True  rk now st = Right Refl
rlow_4_6_2_2__decide_once False rk now st = Left Refl

--@derives [RLOW.4.6.2.2]
||| A REFUSED GATE MOVES NO TRACKER.
export
rlow_4_6_2_2__refused_keeps : (window, now : Nat) -> (rk : (Nat, Nat)) -> (st, st' : Iret_10_4__trackers) ->
                              iret_10_4__allow window now rk st = (False, st') -> st' = st
rlow_4_6_2_2__refused_keeps window now rk st st' h =
  rlow_4_6_2_2__decide_false (rlow_4_6_2_2__allows window now (rlow_4_6_2_2__lookup st rk)) rk now st st' h

--@derives [RLOW.4.6.2.2]
||| A KEY WITH NO RECORDED FIRING IS ADMITTED, and stamped: "always for a
||| key with no recorded firing, it returns true and records".
export
rlow_4_6_2_2__first_firing_admitted : (window, now : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                                      rlow_4_6_2_2__lookup st rk = Nothing ->
                                      iret_10_4__allow window now rk st = (True, (rk, now) :: st)
rlow_4_6_2_2__first_firing_admitted window now rk st lk =
  rlow_4_6_2_2__allow_admits window now rk st (cong (rlow_4_6_2_2__allows window now) lk)

--@derives [LCDB.3.2.1]
--@derives [RLOW.4.6.2.2]
||| THE WINDOW SUPPRESSES: a key stamped at `c0` and an instant inside the
||| window, `c' < c0 + window`, is refused, and the trackers do not move --
||| "suppress further fires of the same activation key for duration T".
export
lcdb_3_2_1__window_suppresses : (window, c0, c' : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                                rlow_4_6_2_2__lookup st rk = Just c0 -> (c' < c0 + window) = True ->
                                iret_10_4__allow window c' rk st = (False, st)
lcdb_3_2_1__window_suppresses window c0 c' rk st lk lt =
  rlow_4_6_2_2__allow_refuses window c' rk st (trans (cong (rlow_4_6_2_2__allows window c') lk) (cong not lt))

--@derives [RLOW.4.6.2.2]
||| AT OR PAST THE BOUNDARY THE KEY FIRES AGAIN, and is restamped: a key
||| stamped at `c0` and an instant not inside the window.
export
rlow_4_6_2_2__refires_at_the_boundary : (window, c0, c' : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                                        rlow_4_6_2_2__lookup st rk = Just c0 -> (c' < c0 + window) = False ->
                                        iret_10_4__allow window c' rk st = (True, (rk, c') :: st)
rlow_4_6_2_2__refires_at_the_boundary window c0 c' rk st lk lt =
  rlow_4_6_2_2__allow_admits window c' rk st (trans (cong (rlow_4_6_2_2__allows window c') lk) (cong not lt))

--@derives [RLOW.4.6.2.2]
||| No natural is below itself. A Nat fact for the boundary.
export
rlow_4_6_2_2__lt_irrefl : (n : Nat) -> (n < n) = False
rlow_4_6_2_2__lt_irrefl Z = Refl
rlow_4_6_2_2__lt_irrefl (S n) = rlow_4_6_2_2__lt_irrefl n

--@derives [RLOW.4.6.2.2]
||| THE BOUNDARY IS INCLUSIVE: at exactly `c0 + window` the key fires. The
||| clause's `mono_ns - last_fire_ns < window_ns` is false at equality; the
||| instant `rgate.cool_refire` and logical/LCDB.3.2.1_rgate_cool_refire pin.
export
rlow_4_6_2_2__boundary_is_inclusive : (window, c0 : Nat) -> (rk : (Nat, Nat)) -> (st : Iret_10_4__trackers) ->
                                      rlow_4_6_2_2__lookup st rk = Just c0 ->
                                      iret_10_4__allow window (c0 + window) rk st = (True, (rk, c0 + window) :: st)
rlow_4_6_2_2__boundary_is_inclusive window c0 rk st lk =
  rlow_4_6_2_2__refires_at_the_boundary window c0 (c0 + window) rk st lk (rlow_4_6_2_2__lt_irrefl (c0 + window))

--@derives [RLOW.4.6.2.1]
||| A key is the same key as itself.
export
rlow_4_6_2_1__same_key_refl : (rk : (Nat, Nat)) -> rlow_4_6_2_1__same_key rk rk = True
rlow_4_6_2_1__same_key_refl (r, k) = rewrite lcyc_1_1__nat_eq_refl r in rewrite lcyc_1_1__nat_eq_refl k in Refl

--@derives [RLOW.4.6.2.1]
||| TWO KEYS THE TABLE CALLS THE SAME ARE ONE PAIR: the identity is
||| equality of the rule and the code.
export
rlow_4_6_2_1__same_key_is_equality : (a, b : (Nat, Nat)) -> rlow_4_6_2_1__same_key a b = True -> a = b
rlow_4_6_2_1__same_key_is_equality (r, k) (r', k') h =
  rewrite lcyc_1_1__nat_eq_true r r' (lcyc_1_1__and_true_l (r == r') (k == k') h) in
  rewrite lcyc_1_1__nat_eq_true k k' (lcyc_1_1__and_true_r (r == r') (k == k') h) in Refl

--@derives [RLOW.4.6.2.2]
||| A STAMP IS READ BACK: the key just stamped looks up its instant --
||| "records `last_fire_ns = mono_ns`".
export
rlow_4_6_2_2__lookup_stamped : (rk : (Nat, Nat)) -> (now : Nat) -> (st : Iret_10_4__trackers) ->
                               rlow_4_6_2_2__lookup ((rk, now) :: st) rk = Just now
rlow_4_6_2_2__lookup_stamped rk now st = rewrite rlow_4_6_2_1__same_key_refl rk in Refl

--@derives [RLOW.4.6.2.3]
||| DISTINCT KEYS HAVE INDEPENDENT STATE: a stamp under one key leaves every
||| other key's lookup as it was.
export
rlow_4_6_2_3__other_key_unmoved : (rk, rk' : (Nat, Nat)) -> (now : Nat) -> (st : Iret_10_4__trackers) ->
                                  rlow_4_6_2_1__same_key rk' rk = False ->
                                  rlow_4_6_2_2__lookup ((rk, now) :: st) rk' = rlow_4_6_2_2__lookup st rk'
rlow_4_6_2_3__other_key_unmoved rk rk' now st h = rewrite h in Refl

-- ---------------------------------------------------------------------
-- One firing [LCDB.3.2.1.1], [RDSC.4a.8.2.3]
-- ---------------------------------------------------------------------

--@derives [LCDB.3.2.1]
||| With no rule cooled, no ordinal has a cooldown.
export
lcdb_3_2_1__uncooled_at : (cools : List Lcdb_3_2_1__cool) -> (r : Nat) -> lcdb_3_2_1__uncooled cools = True ->
                          lcdb_3_2_1__cool_at cools r = Nothing
lcdb_3_2_1__uncooled_at [] r u = Refl
lcdb_3_2_1__uncooled_at (Nothing :: cs) Z u = Refl
lcdb_3_2_1__uncooled_at (Nothing :: cs) (S r) u = lcdb_3_2_1__uncooled_at cs r u
lcdb_3_2_1__uncooled_at (Just x :: cs) r u = absurd u

--@derives [LCDB.3.2.1]
||| A RULE WITH NO COOLDOWN FIRES AS THE PLAIN ENGINE FIRES: the gated
||| firing's net is `iret_11_4__fire_ttl_net`'s, admitted, and the trackers
||| are unchanged.
export
lcdb_3_2_1__uncooled_rule_fires_plain : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                        (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) -> (st : Iret_10_4__trackers) ->
                                        (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                                        iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                        lcdb_3_2_1__cool_at cools r = Nothing ->
                                        lcdb_3_2_1__fire_gated pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c, st)
                                          = Just ((r, atuple a, True), (rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c), st))
lcdb_3_2_1__uncooled_rule_fires_plain pg ttl cools eng rows dl c st r j ch a sel nc na nco =
  rewrite sel in rewrite nc in rewrite na in rewrite nco in Refl

--@derives [LCDB.3.2.1.1]
--@derives [RDSC.4a.8.2.3]
||| AN ADMITTED FIRING IS THE FIRING: when the gate's verdict on the fired
||| match's key at the clock is `true`, the firing's net is
||| `iret_11_4__fire_ttl_net`'s -- the activation marked, the actions run
||| -- and the trackers gain `(rule, key) -> clock` in front.
export
lcdb_3_2_1_1__allowed_is_the_firing : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                      (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) -> (st : Iret_10_4__trackers) ->
                                      (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) -> (window : Nat) -> (kf : Iret_7_1__token -> Nat) ->
                                      iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                      lcdb_3_2_1__cool_at cools r = Just (window, kf) ->
                                      rlow_4_6_2_2__allows window c (rlow_4_6_2_2__lookup st (r, kf (atuple a))) = True ->
                                      lcdb_3_2_1__fire_gated pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c, st)
                                        = Just ((r, atuple a, True), (rarc_5_6_7__do_actions_ttl_net pg ttl r a (cactions ch) (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c), ((r, kf (atuple a)), c) :: st))
lcdb_3_2_1_1__allowed_is_the_firing pg ttl cools eng rows dl c st r j ch a window kf sel nc na co ok =
  rewrite sel in rewrite nc in rewrite na in rewrite co in rewrite ok in Refl

--@derives [LCDB.3.2.1.1]
--@derives [RDSC.4a.8.2.3]
||| A REFUSED FIRING RUNS NO ACTION: when the gate's verdict is `false`,
||| the firing's net is the net with that activation marked fired and
||| nothing else -- working memory, the dependency rows, the deadlines and
||| the clock as they were -- and the trackers are the ones before.
export
lcdb_3_2_1_1__suppressed_runs_no_action : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                          (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) -> (st : Iret_10_4__trackers) ->
                                          (r, j : Nat) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) -> (window : Nat) -> (kf : Iret_7_1__token -> Nat) ->
                                          iret_11_1__select (nchains (enet eng)) = Just (r, j) -> rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                          lcdb_3_2_1__cool_at cools r = Just (window, kf) ->
                                          rlow_4_6_2_2__allows window c (rlow_4_6_2_2__lookup st (r, kf (atuple a))) = False ->
                                          lcdb_3_2_1__fire_gated pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c, st)
                                            = Just ((r, atuple a, False), (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c, st))
lcdb_3_2_1_1__suppressed_runs_no_action pg ttl cools eng rows dl c st r j ch a window kf sel nc na co no =
  rewrite sel in rewrite nc in rewrite na in rewrite co in rewrite no in Refl

--@derives [LCDB.3.2.1.1]
||| Marking an activation leaves working memory: the refused firing's net
||| holds the facts it held. A transcription of `idat_6_2_2__mark_net`.
export
lcdb_3_2_1_1__suppressed_leaves_memory : (r, j : Nat) -> (eng : Iret_19__engine) -> ewm (idat_6_2_2__mark_net r j eng) = ewm eng
lcdb_3_2_1_1__suppressed_leaves_memory r j eng = Refl

--@derives [RDSC.4a.8.2.3]
--@derives [LCDB.3.2.1.1]
||| A SUPPRESSED FIRING IS STILL THE MATCH'S FIRING: after it, the chain at
||| the ordinal is the chain with activation `j` marked, that activation
||| is the selected match, and it carries `fired` -- so the selection of
||| [IRET.11.4] 1a, the first activation not fired, does not take it again
||| while it persists.
export
rdsc_4a_8_2_3__suppressed_is_still_the_firing : (r, j : Nat) -> (eng : Iret_19__engine) -> (ch : Rlow_4_2_1__chain) -> (a : Iret_8_1__act) ->
                                                rarc_5_6_5__nth r (nchains (enet eng)) = Just ch -> rarc_5_6_5__nth j (cacts ch) = Just a ->
                                                ( rarc_5_6_5__nth r (nchains (enet (idat_6_2_2__mark_net r j eng))) = Just (idat_6_2_2__mark_chain j ch)
                                                , rarc_5_6_5__nth j (cacts (idat_6_2_2__mark_chain j ch)) = Just (idat_6_2_2__mark_act a)
                                                , atuple (idat_6_2_2__mark_act a) = atuple a
                                                , afired (idat_6_2_2__mark_act a) = True )
rdsc_4a_8_2_3__suppressed_is_still_the_firing r j eng ch a nc na =
  ( trans (lcyc_1_1__nth_set_at_eq r (idat_6_2_2__mark_chain j) (nchains (enet eng))) (cong (map (idat_6_2_2__mark_chain j)) nc)
  , trans (lcyc_1_1__nth_set_at_eq j idat_6_2_2__mark_act (cacts ch)) (cong (map idat_6_2_2__mark_act) na)
  , idat_6_2_2__mark_atuple a
  , idat_6_2_2__mark_fired a )

--@derives [LCDB.3.2.1.1]
||| The trackers after the RHS under a verdict are the verdict's.
export
lcdb_3_2_1_1__run_if_trackers : (d : (Bool, Iret_10_4__trackers)) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (r : Nat) -> (a : Iret_8_1__act) ->
                                (acts : List Lgra_10_1__action) -> (marked : Iret_19_3__clocked_net) ->
                                snd (snd (lcdb_3_2_1_1__run_if d pg ttl r a acts marked)) = snd d
lcdb_3_2_1_1__run_if_trackers (True, st)  pg ttl r a acts marked = Refl
lcdb_3_2_1_1__run_if_trackers (False, st) pg ttl r a acts marked = Refl

--@derives [LCDB.3.2.1.1]
--@derives [RDSC.4a.8.2.3]
||| THE RHS GATES ONCE: the trackers after it are the trackers before, or
||| those with the rule's key stamped at the clock in front.
export
lcdb_3_2_1_1__rhs_once : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (co : Lcdb_3_2_1__cool) -> (r : Nat) -> (a : Iret_8_1__act) ->
                         (acts : List Lgra_10_1__action) -> (c : Nat) -> (st : Iret_10_4__trackers) -> (marked : Iret_19_3__clocked_net) ->
                         Either (snd (snd (lcdb_3_2_1_1__rhs_gated pg ttl co r a acts c st marked)) = st)
                                (k : Nat ** snd (snd (lcdb_3_2_1_1__rhs_gated pg ttl co r a acts c st marked)) = ((r, k), c) :: st)
lcdb_3_2_1_1__rhs_once pg ttl Nothing r a acts c st marked = Left Refl
lcdb_3_2_1_1__rhs_once pg ttl (Just (window, kf)) r a acts c st marked =
  case rlow_4_6_2_2__decide_once (rlow_4_6_2_2__allows window c (rlow_4_6_2_2__lookup st (r, kf (atuple a)))) (r, kf (atuple a)) c st of
    Left e  => Left (trans (lcdb_3_2_1_1__run_if_trackers (iret_10_4__allow window c (r, kf (atuple a)) st) pg ttl r a acts marked) e)
    Right e => Right (kf (atuple a) ** trans (lcdb_3_2_1_1__run_if_trackers (iret_10_4__allow window c (r, kf (atuple a)) st) pg ttl r a acts marked) e)

--@derives [LCDB.3.2.1]
||| THE FIRING AT A SELECTION GATES ONCE: from what it names, the trackers
||| after it are the trackers before, or those with the fired rule's key
||| stamped at the clock in front.
export
lcdb_3_2_1__fire_at_once : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                           (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) -> (st : Iret_10_4__trackers) ->
                           (m : Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act)) ->
                           (r : Nat) -> (fs : Iret_7_1__token) -> (ok : Bool) -> (cs' : Iret_19_3__clocked_net) -> (st' : Iret_10_4__trackers) ->
                           lcdb_3_2_1__fire_at pg ttl cools eng rows dl c st m = Just ((r, fs, ok), (cs', st')) ->
                           Either (st' = st) (k : Nat ** st' = ((r, k), c) :: st)
lcdb_3_2_1__fire_at_once pg ttl cools eng rows dl c st Nothing r fs ok cs' st' h = absurd h
lcdb_3_2_1__fire_at_once pg ttl cools eng rows dl c st (Just (r0, j, ch, a)) r fs ok cs' st' h =
  let je = iret_11_4__just_inj h
      rEq : (r0 = r)
      rEq = cong (\z => fst (fst z)) je
      stEq : (snd (snd (lcdb_3_2_1_1__rhs_gated pg ttl (lcdb_3_2_1__cool_at cools r0) r0 a (cactions ch) c st (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r0 j eng) rows) dl c))) = st')
      stEq = cong (\z => snd (snd z)) je
  in case lcdb_3_2_1_1__rhs_once pg ttl (lcdb_3_2_1__cool_at cools r0) r0 a (cactions ch) c st (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r0 j eng) rows) dl c) of
       Left e  => Left (trans (sym stEq) e)
       Right (k ** e) => Right (k ** replace {p = \z => st' = ((z, k), c) :: st} rEq (trans (sym stEq) e))

--@derives [RDSC.4a.8.2.3]
--@derives [IRET.10.4]
||| ONE LOOKUP, AT MOST ONE STAMP, PER FIRING: the trackers after any gated
||| firing are the trackers before, or those with the fired rule's key
||| stamped at the clock in front -- "evaluated exactly once per firing",
||| and "the gate records the firing it admits".
export
rdsc_4a_8_2_3__gate_once : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                           (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c : Nat) -> (st : Iret_10_4__trackers) ->
                           (r : Nat) -> (fs : Iret_7_1__token) -> (ok : Bool) -> (cs' : Iret_19_3__clocked_net) -> (st' : Iret_10_4__trackers) ->
                           lcdb_3_2_1__fire_gated pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c, st) = Just ((r, fs, ok), (cs', st')) ->
                           Either (st' = st) (k : Nat ** st' = ((r, k), c) :: st)
rdsc_4a_8_2_3__gate_once pg ttl cools eng rows dl c st r fs ok cs' st' h =
  lcdb_3_2_1__fire_at_once pg ttl cools eng rows dl c st (lcdb_3_2_1__selected eng) r fs ok cs' st' h

-- ---------------------------------------------------------------------
-- The frame: no rule cooled, the plain pump [LCDB.3.2.1]
-- ---------------------------------------------------------------------

--@spec [LCDB.3.2.1]
||| A plain firing read as a gated one: admitted, the trackers as given.
public export
lcdb_3_2_1__plain : Iret_10_4__trackers -> (Nat, Iret_7_1__token, Iret_19_3__clocked_net) -> ((Nat, Iret_7_1__token, Bool), Lcdb_3_2_1__gated_state)
lcdb_3_2_1__plain st (r, fs, cs') = ((r, fs, True), (cs', st))

--@spec [LCDB.3.2.1]
||| A plain trace read as a gated one: every firing admitted.
public export
lcdb_3_2_1__admitted : List (Nat, Iret_7_1__token) -> List (Nat, Iret_7_1__token, Bool)
lcdb_3_2_1__admitted [] = []
lcdb_3_2_1__admitted ((r, fs) :: tr) = (r, fs, True) :: lcdb_3_2_1__admitted tr

--@derives [LCDB.3.2.1]
||| WITH NO RULE COOLED, THE GATED FIRING IS THE PLAIN FIRING, admitted,
||| the trackers as given: on every state.
export
lcdb_3_2_1__uncooled_firing_is_plain : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) ->
                                       (cs : Iret_19_3__clocked_net) -> (st : Iret_10_4__trackers) -> lcdb_3_2_1__uncooled cools = True ->
                                       lcdb_3_2_1__fire_gated pg ttl cools (cs, st) = map (lcdb_3_2_1__plain st) (iret_11_4__fire_ttl_net pg ttl cs)
lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u with (iret_11_1__select (nchains (enet eng)))
  lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | Nothing = Refl
  lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | (Just (r, j)) with (rarc_5_6_5__nth r (nchains (enet eng)))
    lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | (Just (r, j)) | Nothing = Refl
    lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | (Just (r, j)) | (Just ch) with (rarc_5_6_5__nth j (cacts ch))
      lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | (Just (r, j)) | (Just ch) | Nothing = Refl
      lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools (MkClockedNet (MkTmsNet eng rows) dl c) st u | (Just (r, j)) | (Just ch) | (Just a) =
        rewrite lcdb_3_2_1__uncooled_at cools r u in Refl

--@derives [LCDB.3.2.1]
||| THE FRAME: with no rule cooled, the gated traced pump's net, halt and
||| trace are `iret_11_4__run_ttl_net_traced`'s, every firing admitted, and
||| the trackers are the ones given. Every fixture the Idris model compared
||| before this rung runs through the gated pump, and its agreement holds
||| by this theorem.
export
lcdb_3_2_1__no_cooldown_is_the_plain_pump : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (fuel : Nat) ->
                                            (cs : Iret_19_3__clocked_net) -> (st : Iret_10_4__trackers) -> lcdb_3_2_1__uncooled cools = True ->
                                            (t : Iret_19_3__clocked_net ** (h : Iret_11_4__halt ** (tr : List (Nat, Iret_7_1__token) **
                                              ( iret_11_4__run_ttl_net_traced pg ttl fuel cs = (t, h, tr)
                                              , lcdb_3_2_1__run_gated_traced pg ttl cools fuel (cs, st) = ((t, st), h, lcdb_3_2_1__admitted tr) ))))
lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools Z cs st u = (cs ** (FuelOut ** ([] ** (Refl, Refl))))
lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools (S fuel) cs st u with (iret_11_4__fire_ttl_net pg ttl cs) proof e
  lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools (S fuel) cs st u | Nothing =
    (cs ** (Quiescent ** ([] ** ( Refl
                                , iret_11_4__trace_by_end (lcdb_3_2_1__fire_gated pg ttl cools) fuel (cs, st)
                                    (trans (lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools cs st u) (cong (map (lcdb_3_2_1__plain st)) e)) ))))
  lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools (S fuel) cs st u | (Just (r, fs, cs')) =
    let (t ** (h ** (tr ** (tE, gE)))) = lcdb_3_2_1__no_cooldown_is_the_plain_pump pg ttl cools fuel cs' st u
    in (t ** (h ** (((r, fs) :: tr) ** ( rewrite tE in Refl
                                       , iret_11_4__trace_by_cons (lcdb_3_2_1__fire_gated pg ttl cools) fuel (cs, st) (cs', st) (r, fs, True) (t, st) h (lcdb_3_2_1__admitted tr)
                                           (trans (lcdb_3_2_1__uncooled_firing_is_plain pg ttl cools cs st u) (cong (map (lcdb_3_2_1__plain st)) e)) gE ))))

-- ---------------------------------------------------------------------
-- Executed: rgate.k's schedules on this engine, and two shapes of LCDB.3.3
-- ---------------------------------------------------------------------

--@spec [LCDB.3.2.1]
||| An alpha that admits every fact.
public export
lcdb_3_2_1__admits_all : Lfac_1_7_1__fact -> Bool
lcdb_3_2_1__admits_all _ = True

--@spec [LCDB.3.2.1]
||| A join that admits every candidate: the single-pattern rule's node.
public export
lcdb_3_2_1__any_join : Iret_7_5__join
lcdb_3_2_1__any_join t f = True

--@spec [LCDB.3.2.1]
||| No schema carries a TTL.
public export
lcdb_3_2_1__no_ttl : Iret_4_2__ttl
lcdb_3_2_1__no_ttl _ = 0

--@spec [LCDB.3.2.1]
||| Every kind `logical` with an identity: the rgate fixtures' `Trig`, whose
||| mutable-slot change under one key is a replace, a fresh match of the
||| same activation key.
public export
lcdb_3_2_1__entity_life : Nat -> Lscp_1_3__lifecycle
lcdb_3_2_1__entity_life _ = Entity

--@spec [LCDB.3.2.1]
||| Every kind explicit: a ttl schema's facts, which carry no identity.
public export
lcdb_3_2_1__explicit_life : Nat -> Lscp_1_3__lifecycle
lcdb_3_2_1__explicit_life _ = Explicit

--@spec [LCDB.3.2.1]
||| One alpha, kind 0.
public export
lcdb_3_2_1__alphas_one : List (Nat, Lfac_1_7_1__fact -> Bool)
lcdb_3_2_1__alphas_one = [(0, lcdb_3_2_1__admits_all)]

--@spec [LCDB.3.2.1]
||| One rule over kind 0, action-free: `rgate.k`'s `R`, whose RHS is a
||| `log` the model does not carry.
public export
lcdb_3_2_1__one_rule : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
lcdb_3_2_1__one_rule = [([(0, lcdb_3_2_1__any_join, False)], [])]

--@spec [LCDB.3.2.1]
||| The program of the one rule, under a lifecycle for every kind.
public export
lcdb_3_2_1__program : (Nat -> Lscp_1_3__lifecycle) -> Lcyc_3_2_1__program
lcdb_3_2_1__program life = lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load lcdb_3_2_1__alphas_one lcdb_3_2_1__one_rule))

--@spec [LCDB.3.2.1]
||| The loaded network, no rows, no deadlines, the clock at 0, no tracker.
public export
lcdb_3_2_1__loaded : Lcdb_3_2_1__gated_state
lcdb_3_2_1__loaded = (MkClockedNet (MkTmsNet (rdsc_4a_5__load lcdb_3_2_1__alphas_one lcdb_3_2_1__one_rule) []) [] 0, [])

--@spec [LCDB.3.2.1]
||| The one rule cooled: a window and a key.
public export
lcdb_3_2_1__cooled : Nat -> (Iret_7_1__token -> Nat) -> List Lcdb_3_2_1__cool
lcdb_3_2_1__cooled window kf = [Just (window, kf)]

--@spec [LCDB.3.2.1]
||| THE VERDICTS OF A SCHEDULE on the one-rule program from the loaded
||| network: each firing's ordinal and whether the gate admitted it.
public export
lcdb_3_2_1__verdicts_of : (Nat -> Lscp_1_3__lifecycle) -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List Rarc_5_6_2__step -> List (Nat, Bool)
lcdb_3_2_1__verdicts_of life ttl cools steps = snd (lcdb_3_2_1__run_steps_gated (lcdb_3_2_1__program life) ttl cools steps lcdb_3_2_1__loaded)

--@spec [LCDB.3.3.1]
||| THE KEY OF A SINGLE-PATTERN RULE OVER A LOGICAL SCHEMA: the bound fact's
||| identity key -- the model's `fkey`, the code of the declared `key`
||| slots -- and nothing of its payload.
public export
lcdb_3_3_1__key_of_head : Iret_7_1__token -> Nat
lcdb_3_3_1__key_of_head (f :: _) = fkey f
lcdb_3_3_1__key_of_head [] = 0

--@spec [LCDB.3.3.4]
||| A `by:` path to a payload slot of a ttl fact: the model's `fpay`, the
||| code of the payload slots.
public export
lcdb_3_3_4__pay_of_head : Iret_7_1__token -> Nat
lcdb_3_3_4__pay_of_head (f :: _) = fpay f
lcdb_3_3_4__pay_of_head [] = 0

--@spec [LCDB.3.3.4]
||| A ttl schema's default TTL, thirty units: the 5 min of
||| logical/LCDB.3.3.4_ttl_by_suppresses in units of its 10 s window.
public export
lcdb_3_3_4__ttl_thirty : Iret_4_2__ttl
lcdb_3_3_4__ttl_thirty _ = 30

--@spec [LCDB.3.3.3]
||| THE EMPTY KEY: no bound fact contributes a slot, so the key is the code
||| of the empty tuple, one for every match -- the rule-global cooldown.
public export
lcdb_3_3_3__empty_key : Iret_7_1__token -> Nat
lcdb_3_3_3__empty_key _ = 1

--@derives [LCDB.3.3.1]
||| THE KEY IGNORES THE PAYLOAD: for a single-pattern rule over a logical
||| schema the key of the bound fact is the same for any payload, so a
||| mutable churn resets no window. A transcription of `lcdb_3_3_1__key_of_head`.
export
lcdb_3_3_1__key_ignores_the_payload : (i, i', k, key, p, p' : Nat) ->
                                      lcdb_3_3_1__key_of_head [MkFact i k key p] = lcdb_3_3_1__key_of_head [MkFact i' k key p']
lcdb_3_3_1__key_ignores_the_payload i i' k key p p' = Refl

--@derives [LCDB.3.2.1]
--@derives [RLOW.4.6.2.2]
||| `rgate.cool_first`: the first activation of a cooled rule fires, there
||| being no prior fire to be inside a window of. Executed:
||| `fire:R:int(1)@0|`.
export
lcdb_3_2_1__cool_first :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_1__key_of_head)
    [SInput (Data (Assert 0 1 0)), SPumpT 3]
    = [(0, True)]
lcdb_3_2_1__cool_first = Refl

--@derives [LCDB.3.2.1]
--@derives [RLOW.4.6.2.2]
||| `rgate.cool_refire`: a fire at 0, a tick to 10 and a fresh match of the
||| key (the mutable slot changed, a replace) fires again at the window's
||| boundary, 10 >= 0 + 10. Executed: `fire:R:int(1)@0|fire:R:int(1)@10|`.
export
lcdb_3_2_1__cool_refire :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_1__key_of_head)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 10), SInput (Data (Assert 0 1 1)), SPumpT 3]
    = [(0, True), (0, True)]
lcdb_3_2_1__cool_refire = Refl

--@derives [LCDB.3.2.1]
--@derives [RLOW.4.6.2.2]
||| `rgate.cool_suppress`, the zero instant: a fire at clock 0 and a fresh
||| match of the key at 5, inside the 10 window, is refused -- the stamp
||| `Just 0` kept apart from "never fired". Executed:
||| `fire:R:int(1)@0|cool_suppress:R:int(1)@5|`.
export
lcdb_3_2_1__cool_suppress :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_1__key_of_head)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 1 1)), SPumpT 3]
    = [(0, True), (0, False)]
lcdb_3_2_1__cool_suppress = Refl

--@derives [LCDB.3.3.3]
--@derives [RLOW.4.6.2.3]
||| `rgate.cool_perkey`: two keys in one pump both fire, in [LDET.5.5]'s
||| order; the state is per key. Executed: `fire:R:int(1)@0|fire:R:int(2)@0|`.
export
lcdb_3_3_3__cool_perkey :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_1__key_of_head)
    [SInput (Data (Assert 0 1 0)), SInput (Data (Assert 0 2 0)), SPumpT 3]
    = [(0, True), (0, True)]
lcdb_3_3_3__cool_perkey = Refl

--@derives [LCDB.3.3.3]
--@derives [RLOW.4.6.2.3]
||| `rgate.key_separates`: a second key arriving at 5, inside the first
||| key's window, fires: the window is `(R, 1)`'s and not `(R, 2)`'s.
||| Executed: `fire:R:int(1)@0|fire:R:int(2)@5|`.
export
lcdb_3_3_3__key_separates :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_1__key_of_head)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 2 0)), SPumpT 3]
    = [(0, True), (0, True)]
lcdb_3_3_3__key_separates = Refl

--@derives [LCDB.3.3.3]
||| THE EMPTY KEY IS RULE-GLOBAL: under the empty key two facts in one pump
||| share one window, and the second is refused. Executed.
export
lcdb_3_3_3__empty_key_is_rule_global :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__entity_life lcdb_3_2_1__no_ttl (lcdb_3_2_1__cooled 10 lcdb_3_3_3__empty_key)
    [SInput (Data (Assert 0 1 0)), SInput (Data (Assert 0 2 0)), SPumpT 3]
    = [(0, True), (0, False)]
lcdb_3_3_3__empty_key_is_rule_global = Refl

--@derives [LCDB.3.3.4]
||| The shape of logical/LCDB.3.3.4_ttl_by_suppresses: a ttl schema with no
||| identity, the key a payload slot under `by:`. Three facts, each its own
||| identity, pumped in turn at clock 0: the second carries the first's
||| key and is refused, the third its own key and fires. Executed.
export
lcdb_3_3_4__ttl_by_suppresses :
  lcdb_3_2_1__verdicts_of lcdb_3_2_1__explicit_life lcdb_3_3_4__ttl_thirty (lcdb_3_2_1__cooled 1 lcdb_3_3_4__pay_of_head)
    [SInput (Data (Assert 0 1 1)), SPumpT 3, SInput (Data (Assert 0 2 1)), SPumpT 3, SInput (Data (Assert 0 3 2)), SPumpT 3]
    = [(0, True), (0, False), (0, True)]
lcdb_3_3_4__ttl_by_suppresses = Refl

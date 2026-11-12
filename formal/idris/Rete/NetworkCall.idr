-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE CALL SURFACE ON THE IDRIS MODEL'S ENGINE: a service's response schema and
||| the `CallError` as ANSWER KINDS carrying a `corr` slot, the SWEEP a call
||| performs on its correlation before it is issued ([LCRS.6.2.1],
||| [RLOW.7.3.8], [LCRS.17.1]), the SWEEP an arriving answer performs before
||| it enters working memory ([LCRS.6.2.4], [NCBK.6.4]), the PER-CALL RATE
||| GATE wrapping each call site ([LCRS.8.2], [RLOW.4.6.6.1],
||| [RLOW.4.6.6.6]), and the CALL RECORD the engine emits for an issued
||| call ([NCBK.6.9]).
|||
||| NORMATIVE COMPANION to Rete/NetworkTimed.idr, whose stamped gated firing
||| this file threads the call sites through and whose timed state it carries
||| beside a second tracker table, and to formal/tla/call_response.tla, the
||| bounded model of the same clauses over one service and a numbered
||| correlation; the Idris side is the kinds and the correlation as a String
||| text, one operation at a time over every state.
|||
||| WHAT IS MODELLED. A program's ANSWER KINDS (`Lcrs_4_2_2__answers`): the
||| kinds of its response schemas and the kind of `CallError`. Where a kind
||| keeps its `corr` (`Lcrs_4_3_2__corr_of`): in the key tuple or the
||| payload, and at which index; a kind with none reads no correlation. A
||| fact's CORRELATION is read through Rete/Eval.idr's environment, the value
||| code's decoder, as the String text of that slot (`lcrs_4_3_2__corr_read`);
||| two correlations are one under [LSTR.3.1]'s codepoint equality. THE
||| VICTIMS of a sweep (`lcrs_6_2__victims`) are the live facts of the swept
||| kinds whose correlation is the sweep's; a sweep retracts them one at a
||| time through alpha dispatch and runs the cascade
||| (`lcrs_6_2__sweep_ids_net`), as Rete/NetworkTtl.idr's TTL sweep does.
||| THE CALL'S SWEEP ([LCRS.6.2.1]) covers the site's response schema and
||| `CallError`, or `CallError` alone for a `no response` service
||| ([LCRS.17.1]), derived from the site's service as [RLOW.7.3.8] has the
||| engine take it from the `ServiceDef`; THE ARRIVAL'S SWEEP ([LCRS.6.2.4])
||| covers the arriving kind and `CallError` for a response fact, and every
||| answer kind for a `CallError`, which names no service. A CALL SITE
||| (`Lcrs_6_2_1__site`) is its POSITION among the rule's emits and
||| withdraws, its gate (a window and the activation key of [LCRS.8.2] as a
||| function of the fired match, or none under `nocooldown`), its response
||| kind, its correlation and its arguments as functions of the match; the
||| sites of a rule are given by ordinal as the cooldowns are. THE RHS WITH
||| CALLS (`rlow_7_3_8__do_actions_called`) is Rete/NetworkTimed.idr's
||| stamped fold with the sites at each position run before the action at
||| that position and the sites past the last action after it: at a site the
||| gate decides at the net's clock on the site's own tracker table
||| (`Rlow_4_6_6_1__trackers`, keyed `(rule, site, key)`); admitted, the
||| sweep runs on the site's correlation and the call is RECORDED
||| (`Ncbk_6_9__call_record`); refused, nothing moves. THE GATED FIRING WITH
||| CALLS (`lcrs_6_2_1__fire_called`) is Rete/NetworkTimed.idr's -- select,
||| mark, the rule's own gate -- with that fold, each firing named with its
||| ordinal, its facts, the verdict and the calls it issued. A DATA INPUT
||| ARRIVES (`lcrs_6_2_4__arrive_timed`): the arrival's sweep on the input's
||| correlation, then Rete/NetworkTimed.idr's input, so the retractions
||| precede the answer in working memory ([LCRS.6.2.4]); a retraction sweeps
||| nothing. A tick, the wall step and the pump's re-time are
||| Rete/NetworkTimed.idr's and Rete/NetworkWall.idr's, the call trackers
||| beside.
|||
||| THE READINGS. [LCRS.6.2.4] exempts the empty String from the arrival's
||| sweep: an answer whose `corr` is "" supersedes nothing, and the clause's
||| consequence reads "for each non-empty correlation", as both runtimes have it
||| (libds's dispatcher, Mercury's `ds.exec`) and
||| logical/LCRS.6.2.4_empty_corr_retracts_nothing pins; the model has
||| `lcrs_6_2__victims` of the empty text as nothing, on either side. On the
||| call side the exemption is [LRST.1.2]'s: a call whose `as` evaluates to
||| "" takes a generated correlation ([LCCO.3.4]), unique to the firing, so
||| it supersedes nothing; the generated value is not modelled, the record
||| carries the empty text, and the ties are `partial` for it. The
||| activation key of a call whose rule binds no `logical` fact with a `key`
||| slot is the empty key, and the site has one window across its
||| activations ([LCRS.8.2]: the compiler composes the empty key and keeps one tracker per site); every
||| key is the lowering's composition, as every rule-level key is. The
||| tracker name `<rule>#call<N>` ([RLOW.4.6.6.1]) is a site index here. A
||| site's arguments are evaluated results; one that traps is recorded as
||| such, where the engine abandons the activation at the action ([LNUL.11.1]),
||| so a trapping argument is a divergence and never a silent agreement. A
||| rule asserts no answer: the compiler rejects an `emit` or a `publish` of
||| a response schema or `CallError` ([LCRS.4.3.4]), so every answer enters
||| by the host's assert, where the supersede is ([NCBK.6.4]); the lowering
||| refuses such a program too (`emit:answer-kind`), so no fixture reaches
||| it.
|||
||| PROVED, each over every program, environment, kind table, site table,
||| state and tracker table.
|||
|||   * THE FRAMES. With no call site anywhere, the fold is the stamped RHS
|||     (`rlow_7_3_8__no_site_is_the_stamped_rhs`), the gated RHS projects to
|||     Rete/NetworkTimed.idr's (`lcrs_6_2_1__no_site_outcome`), the firing to
|||     its firing (`lcrs_6_2_1__no_site_fire_projects`), the run and the pump
|||     to its run and pump, state, halt and trace
|||     (`lcrs_6_2_1__no_site_run_projects`,
|||     `lcrs_6_2_1__no_site_is_the_timed_pump`); with no kind carrying a
|||     `corr` an arrival is the input (`lcrs_6_2_4__no_corr_arrival_is_the_input`).
|||     Every fixture the Idris model compared before this rung runs through the
|||     called engine, and its agreement holds by these theorems and
|||     Rete/NetworkTimed.idr's frame rather than by a rerun.
|||   * THE SWEEP ([LCRS.6.2.1], [LCRS.6.2.4]): it only removes
|||     (`lcrs_6_2__sweep_ids_net_sub`); what it was asked to remove is gone
|||     (`lcrs_6_2__swept_not_live`), so after a sweep on a correlation no
|||     live fact of the swept kinds carries it
|||     (`lcrs_6_2_1__issued_call_sweeps`); its retraction removes the
|||     victims and nothing else (`lcrs_6_2_1__retraction_keeps_non_victims`),
|||     what the cascade then removes being [IRET.12.2]'s; a kind outside the
|||     swept kinds is no victim (`lcrs_6_2_1__other_kind_is_no_victim`): the
|||     other service's response survives the call and the response's
|||     arrival; a correlation no live fact carries sweeps nothing
|||     (`lcrs_6_2__no_carrier_sweeps_nothing`), the empty correlation among
|||     them (`lcrs_6_2__empty_corr_sweeps_nothing`,
|||     `lcrs_6_2_1__empty_corr_call_sweeps_nothing`); a `no response`
|||     service's call sweeps `CallError` alone
|||     (`lcrs_17_1__no_response_sweeps_error_alone`, a transcription, said so).
|||   * THE PER-CALL GATE ([LCRS.8.2], [RLOW.4.6.6.1], [RLOW.4.6.6.6]): a site
|||     with no recorded issue is admitted and stamped
|||     (`lcrs_8_2__first_call_admitted`); inside the window it is refused and
|||     the trackers do not move (`lcrs_8_2__window_suppresses_call`); at or
|||     past the boundary it is admitted and restamped
|||     (`lcrs_8_2__refires_at_the_boundary_call`); `nocooldown` is no gate
|||     (`rlow_4_6_6_6__no_gate_admits`, a transcription). At a site, an
|||     admitted gate sweeps, records and stamps (`lcrs_8_2__site_admitted`);
|||     a refused one leaves the net, the stamps and the records as they were
|||     (`lcrs_8_2__site_refused`), so a call its cooldown suppresses is not
|||     issued and retracts nothing (`lcrs_6_2_1__suppressed_retracts_nothing`).
|||   * EXECUTED, `Refl` through the loader, the stamps, the gated pump and
|||     the arrival, the twelve fixtures' shapes: a call issued again past its
|||     window retracts the live reply of its correlation
|||     (logical/LCRS.6.2.1_admitted_call_supersedes); inside the window the
|||     reply stays and no call is recorded
|||     (LCRS.6.2.1_cooldown_suppressed_retracts_nothing), and at the boundary
|||     the call is issued; a `no response` call retracts the `CallError`
|||     alone (LCRS.6.2.1_no_response_sweeps_error_only); the other service's
|||     reply of the same correlation survives the call
|||     (LCRS.6.2.1_other_service_reply_survives); two calls before any
|||     reply, then two replies: the last asserted stays, in either order
|||     (LCRS.6.2.4_refire_pending_last_reply_wins, _out_of_order); an error
|||     after a response, a response after an error, an error spanning two
|||     services, the other service untouched by a response
|||     (LCRS.6.2.4_error_after_response, _response_after_error,
|||     _error_spans_services, _other_service_untouched); three answers with
|||     the empty correlation all live (LCRS.6.2.4_empty_corr_retracts_nothing).
|||
||| WHAT THIS FILE RELIES ON AND DOES NOT ESTABLISH. The stream's record
||| order on an arrival (the answer's `FactAssert` first, the withdrawals
||| after, [RFCS.6.7]) is not modelled: the model has the retractions
||| precede the answer in working memory and says nothing of the stream.
||| That one answer per correlation holds after every history
||| ([LCRS.6.2.4]'s third paragraph) is not proved here: the sweep theorems
||| are per operation, and formal/tla/call_response.tla holds the consequence
||| within its bounds. That a response
||| schema is `ttl` and declares `corr` as a non-nullable String is the
||| validator's ([LCRS.4.3.2]); the kind table and the corr table are the
||| lowering's, read off the program's declarations, and a kind that reads
||| no String at its corr index reads no correlation. The adapter is not
||| modelled: an answer is a host assert, and that exactly one answer follows
||| a call ([LCRS.4.2.2]) is the adapter's contract. The cascade after a
||| sweep is [IRET.12.2]'s; a response fact, being `ttl`, has no
||| justification row, which is why "responses of other services are
||| untouched" holds of the whole sweep and is proved here of its retraction
||| alone. The value of a lowered argument is run, not proved, as every
||| evaluated slot is. Continuations, a computed `as`, a qualified service, a
||| `retain:`, `every` and the adapter's own dedup are outside the fragment.
module Rete.NetworkCall

-- The imports are Rete/NetworkTimed.idr's whole, with Rete/NetworkTimed.idr
-- and Rete/NetworkWall.idr: a run evaluated in a witness unfolds only
-- through modules the file imports.
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
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkEdges
import Rete.NetworkTwoClocks
import Rete.NetworkCooldown
import Rete.NetworkTimed
import Rete.NetworkWall
import Rete.EntryStamp
import Rete.Eval
import Rete.RunFold
import Rete.RateGate
import Rete.Refcount
import Rete.TmsBridge
import Rete.TmsRun
import TwoClocks
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.Maybe
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The answer kinds and the swept kinds [LCRS.4.2.2], [LCRS.6.2.1], [LCRS.6.2.4]
-- ---------------------------------------------------------------------

--@spec [LCRS.4.2.2]
--@spec [LCRS.4.2.1]
--@spec [LCRS.4.3.1]
||| THE ANSWER KINDS of a program: the kinds of its response schemas, one per
||| service declaring `response T` ([LCRS.4.3.1]), and the kind of `CallError`
||| ([LCRS.4.2.1]), which every program with a call carries. An answer is a
||| fact of one of these kinds; the adapter asserts exactly one per call
||| ([LCRS.4.2.2]), which is not modelled: here an answer is a host assert.
public export
record Lcrs_4_2_2__answers where
  constructor MkAnswers
  aresponses : List Nat
  aerror     : Nat

--@spec [LCRS.4.2.2]
||| Whether a kind is an answer kind.
public export
lcrs_4_2_2__is_answer : Lcrs_4_2_2__answers -> Nat -> Bool
lcrs_4_2_2__is_answer ans k = (k == aerror ans) || rarc_5_6_5__elem k (aresponses ans)

--@spec [LCRS.6.2.4]
||| THE KINDS AN ARRIVAL SWEEPS, by the two tests on the arriving kind: a
||| `CallError` sweeps every answer kind -- it names no service, so its
||| correlation spans services; a response fact sweeps its own kind and
||| `CallError`; any other kind sweeps nothing. By pattern matching on the
||| two tests, so a proof can split on them.
public export
lcrs_6_2_4__swept_if : Lcrs_4_2_2__answers -> Nat -> Bool -> Bool -> List Nat
lcrs_6_2_4__swept_if ans k True  _     = aerror ans :: aresponses ans
lcrs_6_2_4__swept_if ans k False True  = [k, aerror ans]
lcrs_6_2_4__swept_if ans k False False = []

--@spec [LCRS.6.2.4]
--@spec [LCRS.4.2.1]
||| The kinds an arriving fact of kind `k` sweeps.
public export
lcrs_6_2_4__swept_by : Lcrs_4_2_2__answers -> Nat -> List Nat
lcrs_6_2_4__swept_by ans k = lcrs_6_2_4__swept_if ans k (k == aerror ans) (rarc_5_6_5__elem k (aresponses ans))

--@spec [LCRS.6.2.1]
--@spec [LCRS.17.1]
--@spec [RLOW.7.3.8]
||| THE KINDS A CALL SWEEPS, from the site's response kind as the engine
||| takes it from the service's `ServiceDef` ([RLOW.7.3.8]): the response
||| schema and `CallError`, or `CallError` alone for a `no response` service
||| ([LCRS.17.1]), which has no response schema.
public export
lcrs_6_2_1__swept_by_call : Lcrs_4_2_2__answers -> Maybe Nat -> List Nat
lcrs_6_2_1__swept_by_call ans Nothing  = [aerror ans]
lcrs_6_2_1__swept_by_call ans (Just t) = [t, aerror ans]

-- ---------------------------------------------------------------------
-- The correlation of a fact [LCRS.4.3.2], [LCRS.4.2.1], [LSTR.3.1]
-- ---------------------------------------------------------------------

--@spec [LCRS.4.3.2]
--@spec [LCRS.4.2.1]
||| WHERE A KIND KEEPS ITS `corr`: in the key tuple (`True`) or the payload
||| (`False`), and at which index; `Nothing` for a kind that declares none.
||| A response schema declares `corr` as a non-nullable String
||| ([LCRS.4.3.2]) and `CallError` has it as its first slot ([LCRS.4.2.1]);
||| the table is the lowering's, read off the declarations.
public export
Lcrs_4_3_2__corr_of : Type
Lcrs_4_3_2__corr_of = Nat -> Maybe (Bool, Nat)

--@spec [LCRS.4.3.2]
||| A String value's text; any other value, or none, reads no correlation.
public export
lcrs_4_3_2__str_of : Maybe Lnul_2_1__value -> Maybe Lstr_1_1__text
lcrs_4_3_2__str_of (Just (VStr t)) = Just t
lcrs_4_3_2__str_of _               = Nothing

--@spec [LCRS.4.3.2]
||| The text at an index of a decoded tuple.
public export
lcrs_4_3_2__text_at : Maybe (List Lnul_2_1__value) -> Nat -> Maybe Lstr_1_1__text
lcrs_4_3_2__text_at (Just vs) i = lcrs_4_3_2__str_of (rarc_5_6_5__nth i vs)
lcrs_4_3_2__text_at Nothing   i = Nothing

--@spec [LCRS.4.3.2]
||| The id the slot's tuple is coded under: the key for a key slot, the
||| payload otherwise.
public export
lcrs_4_3_2__id_of : Bool -> Nat -> Nat -> Nat
lcrs_4_3_2__id_of True  key pay = key
lcrs_4_3_2__id_of False key pay = pay

--@spec [LCRS.4.3.2]
||| The correlation of a value (key, payload) under a slot role, through the
||| environment: the value code's decoder, as Rete/Eval.idr reads a slot.
public export
lcrs_4_3_2__corr_in : Iret_7_6__env -> (Bool, Nat) -> Nat -> Nat -> Maybe Lstr_1_1__text
lcrs_4_3_2__corr_in env (isKey, i) key pay = lcrs_4_3_2__text_at (env (lcrs_4_3_2__id_of isKey key pay)) i

--@spec [LCRS.4.3.2]
||| The correlation of a value of a kind, given where the kind keeps it.
public export
lcrs_4_3_2__corr_at : Iret_7_6__env -> Maybe (Bool, Nat) -> Nat -> Nat -> Maybe Lstr_1_1__text
lcrs_4_3_2__corr_at env Nothing     key pay = Nothing
lcrs_4_3_2__corr_at env (Just role) key pay = lcrs_4_3_2__corr_in env role key pay

--@spec [LCRS.4.3.2]
||| THE CORRELATION OF A LIVE FACT: the text of its kind's `corr` slot, or
||| none. By projections, so that it reduces on a fact given by its parts.
public export
lcrs_4_3_2__corr_read : Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lfac_1_7_1__fact -> Maybe Lstr_1_1__text
lcrs_4_3_2__corr_read env corrOf f = lcrs_4_3_2__corr_at env (corrOf (fkind f)) (fkey f) (fpay f)

-- ---------------------------------------------------------------------
-- The victims and the sweep [LCRS.6.2], [IRET.19.2], [IRET.12.2]
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2]
--@spec [LSTR.3.1]
||| A read correlation IS the sweep's: the same text, codepoint by codepoint
||| ([LSTR.3.1]); a fact that reads none never matches.
public export
lcrs_6_2__corr_is : Maybe Lstr_1_1__text -> Lstr_1_1__text -> Bool
lcrs_6_2__corr_is (Just t) k = lstr_3_1__eq t k
lcrs_6_2__corr_is Nothing  k = False

--@spec [LCRS.6.2]
||| A VICTIM of a sweep over some kinds on a correlation: a fact of one of
||| the kinds whose correlation is the sweep's.
public export
lcrs_6_2__is_victim : Iret_7_6__env -> Lcrs_4_3_2__corr_of -> List Nat -> Lstr_1_1__text -> Lfac_1_7_1__fact -> Bool
lcrs_6_2__is_victim env corrOf kinds k f = rarc_5_6_5__elem (fkind f) kinds && lcrs_6_2__corr_is (lcrs_4_3_2__corr_read env corrOf f) k

--@spec [LCRS.6.2]
--@spec [LCRS.6.2.4]
--@spec [LRST.1.2]
||| THE VICTIMS of a sweep: the ids of the live victims, in working-memory
||| order. The EMPTY CORRELATION HAS NONE: on the call side a call whose
||| `as` evaluates to "" takes a generated correlation and supersedes nothing
||| ([LRST.1.2]); on the arrival side an answer whose `corr` is "" supersedes
||| nothing ([LCRS.6.2.4]: the empty key is no key, and such an answer answers no call).
public export
lcrs_6_2__victims : Iret_7_6__env -> Lcrs_4_3_2__corr_of -> List Nat -> Lstr_1_1__text -> Rarc_5_6_4__wm -> List Nat
lcrs_6_2__victims env corrOf kinds []        wm = []
lcrs_6_2__victims env corrOf kinds (c :: cs) wm = iret_11_3__fact_ids (filter (lcrs_6_2__is_victim env corrOf kinds (c :: cs)) wm)

--@spec [LCRS.6.2]
--@spec [IRET.19.2]
--@spec [IRET.12.2]
||| THE SWEEP ON THE CLOCKED NETWORK: the ids retracted one at a time through
||| alpha dispatch, then the cascade for the rows the retractions ended --
||| Rete/NetworkTtl.idr's TTL sweep on a list of ids; nothing to sweep is the
||| identity. The deadlines and the clock stand, as they do under that sweep:
||| a stamp clears an id's old deadline when the id is minted again.
public export
lcrs_6_2__sweep_ids_net : Lcyc_3_2_1__program -> List Nat -> Iret_19_3__clocked_net -> Iret_19_3__clocked_net
lcrs_6_2__sweep_ids_net pg []        cs = cs
lcrs_6_2__sweep_ids_net pg (i :: is) (MkClockedNet (MkTmsNet eng rows) dl c) =
  MkClockedNet (iret_12_2__phase_net pg (MkTmsNet (iret_12_2__retract_ids_net (i :: is) eng) rows)) dl c

--@spec [LCRS.6.2.1]
||| The working memory of a clocked net: what a sweep reads.
public export
lcrs_6_2_1__wm : Iret_19_3__clocked_net -> Rarc_5_6_4__wm
lcrs_6_2_1__wm cs = ewm (ncore (nengine cs))

-- ---------------------------------------------------------------------
-- A call site, its record and its trackers [LCRS.6.2.1], [LCRS.8.2],
-- [RLOW.4.6.6.1], [NCBK.6.9]
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2.1]
--@spec [LCRS.8.2]
--@spec [RLOW.4.6.6.1]
--@spec [LCRS.3.1]
||| A CALL SITE of a rule: its POSITION, the number of the rule's emits and
||| withdraws lowered before it; its GATE, the window in clock units and
||| [LCRS.8.2]'s activation key as a function of the fired match, coded, or
||| none under `nocooldown` ([RLOW.4.6.6.6]); its RESPONSE KIND, or none for
||| a `no response` service; its CORRELATION ([LCRS.3.1]'s `as`, the
||| lowering's literal) and its ARGUMENTS as functions of the match,
||| evaluated by Rete/Eval.idr as an `emit`'s slots are.
public export
record Lcrs_6_2_1__site where
  constructor MkSite
  sposition : Nat
  sgate     : Maybe (Nat, Iret_7_1__token -> Nat)
  sresponse : Maybe Nat
  scorr     : Iret_7_1__token -> Lstr_1_1__text
  sargs     : Iret_7_1__token -> List Lerr_1_4_1__result

--@spec [LCRS.6.2.1]
||| The sites of the rule at an ordinal, each with its index among the
||| rule's calls; none past the list.
public export
lcrs_6_2_1__sites_at : List (List (Nat, Lcrs_6_2_1__site)) -> Nat -> List (Nat, Lcrs_6_2_1__site)
lcrs_6_2_1__sites_at []        r     = []
lcrs_6_2_1__sites_at (s :: ss) Z     = s
lcrs_6_2_1__sites_at (s :: ss) (S r) = lcrs_6_2_1__sites_at ss r

--@spec [LCRS.6.2.1]
||| No rule has a call site: the frame theorems' hypothesis.
public export
lcrs_6_2_1__unsited : List (List (Nat, Lcrs_6_2_1__site)) -> Bool
lcrs_6_2_1__unsited []               = True
lcrs_6_2_1__unsited ([] :: ss)       = lcrs_6_2_1__unsited ss
lcrs_6_2_1__unsited ((_ :: _) :: ss) = False

--@spec [NCBK.6.9]
||| THE CALL RECORD: what the engine emits for an issued call -- the rule,
||| the site, the correlation and the arguments. The service is the site's;
||| the timetag is the pump's.
public export
record Ncbk_6_9__call_record where
  constructor MkCallRecord
  crule : Nat
  csite : Nat
  ccorr : Lstr_1_1__text
  cargs : List Lerr_1_4_1__result

--@spec [RLOW.4.6.6.1]
--@spec [LCRS.8.2]
||| THE CALL TRACKERS: per `(rule ordinal, site, key code)`, the instant the
||| site last issued the call for that key. Each site has its own window
||| ([LCRS.8.2]), its tracker named `<rule>#call<N>` ([RLOW.4.6.6.1]); a
||| stamp is recorded in front, a lookup reads the newest, absence is
||| "never issued".
public export
Rlow_4_6_6_1__trackers : Type
Rlow_4_6_6_1__trackers = List ((Nat, Nat, Nat), Nat)

--@spec [RLOW.4.6.6.1]
||| Two tracker keys are one key when the rule, the site and the key code
||| are equal.
public export
rlow_4_6_6_1__same_key : (Nat, Nat, Nat) -> (Nat, Nat, Nat) -> Bool
rlow_4_6_6_1__same_key (r, n, k) (r', n', k') = (r == r') && ((n == n') && (k == k'))

--@spec [RLOW.4.6.6.1]
--@spec [RLOW.4.6.2.2]
||| The recorded stamp of a tracker key: Rete/RateGate.idr's `Maybe Nat`.
public export
rlow_4_6_6_1__lookup : Rlow_4_6_6_1__trackers -> (Nat, Nat, Nat) -> Rlow_4_6_2_2__stamp
rlow_4_6_6_1__lookup [] key = Nothing
rlow_4_6_6_1__lookup ((key', c) :: rest) key = if rlow_4_6_6_1__same_key key key' then Just c else rlow_4_6_6_1__lookup rest key

--@spec [RLOW.4.6.6.1]
||| The verdict applied: admitted, the key is stamped; refused, nothing moves.
public export
rlow_4_6_6_1__decide : Bool -> (Nat, Nat, Nat) -> Nat -> Rlow_4_6_6_1__trackers -> (Bool, Rlow_4_6_6_1__trackers)
rlow_4_6_6_1__decide True  key now trk = (True, (key, now) :: trk)
rlow_4_6_6_1__decide False key now trk = (False, trk)

--@spec [LCRS.8.2]
--@spec [RLOW.4.6.6.1]
||| THE PER-CALL RATE-ALLOW: Rete/RateGate.idr's gate over the site's key at
||| the instant, on allow recording `key -> now`; [IRET.10.4]'s builtin on
||| the site's own tracker.
public export
lcrs_8_2__allow : (window, now : Nat) -> (Nat, Nat, Nat) -> Rlow_4_6_6_1__trackers -> (Bool, Rlow_4_6_6_1__trackers)
lcrs_8_2__allow window now key trk =
  rlow_4_6_6_1__decide (rlow_4_6_2_2__allows window now (rlow_4_6_6_1__lookup trk key)) key now trk

--@spec [LCRS.8.2]
--@spec [RLOW.4.6.6.6]
||| THE SITE'S GATE: `nocooldown` admits with the trackers untouched
||| ([RLOW.4.6.6.6]); a window decides at the clock on the key of the fired
||| match under `(rule, site)`.
public export
lcrs_8_2__admit_gate : Maybe (Nat, Iret_7_1__token -> Nat) -> Nat -> Nat -> Nat -> Iret_7_1__token -> Rlow_4_6_6_1__trackers ->
                       (Bool, Rlow_4_6_6_1__trackers)
lcrs_8_2__admit_gate Nothing        r n c tok trk = (True, trk)
lcrs_8_2__admit_gate (Just (w, kf)) r n c tok trk = lcrs_8_2__allow w c (r, n, kf tok) trk

-- ---------------------------------------------------------------------
-- The issue, and the RHS with calls [LCRS.6.2.1], [RLOW.7.3.8], [LCRS.8.2]
-- ---------------------------------------------------------------------

--@spec [RLOW.7.3.8]
||| THE ACCUMULATOR of the RHS with calls: the net and the stamps the
||| actions fold over, the call trackers, and the records of the calls
||| issued so far, in order.
public export
record Rlow_7_3_8__acc where
  constructor MkAcc
  anet    : Iret_19_3__clocked_net
  astamps : Ltim_2_8_6__stamps
  atrk    : Rlow_4_6_6_1__trackers
  arecs   : List Ncbk_6_9__call_record

--@spec [LCRS.6.2.1]
--@spec [RLOW.7.3.8]
||| THE ISSUE: the sweep on the site's correlation over the kinds the site's
||| service answers with, before the request -- [RLOW.7.3.8]'s engine
||| performing [LCRS.6.2.1]'s retraction while evaluating the call.
public export
lcrs_6_2_1__issue : Lcyc_3_2_1__program -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Lcrs_6_2_1__site -> Iret_7_1__token ->
                    Iret_19_3__clocked_net -> Iret_19_3__clocked_net
lcrs_6_2_1__issue pg env corrOf ans site tok cs =
  lcrs_6_2__sweep_ids_net pg (lcrs_6_2__victims env corrOf (lcrs_6_2_1__swept_by_call ans (sresponse site)) (scorr site tok) (lcrs_6_2_1__wm cs)) cs

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
--@spec [RLOW.7.3.8]
||| THE ISSUE UNDER A VERDICT: admitted, the sweep runs and the call is
||| recorded; refused, nothing moves -- not issued, retracting nothing. By
||| pattern matching on the verdict, so a proof can split on it.
public export
lcrs_6_2_1__issue_if : Bool -> Lcyc_3_2_1__program -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Nat -> Nat -> Lcrs_6_2_1__site ->
                       Iret_7_1__token -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
lcrs_6_2_1__issue_if True  pg env corrOf ans r n site tok acc =
  MkAcc (lcrs_6_2_1__issue pg env corrOf ans site tok (anet acc)) (astamps acc) (atrk acc)
        (arecs acc ++ [MkCallRecord r n (scorr site tok) (sargs site tok)])
lcrs_6_2_1__issue_if False pg env corrOf ans r n site tok acc = acc

--@spec [LCRS.8.2]
--@spec [RLOW.7.3.8]
||| A site decided: the trackers take the gate's, then the issue under its
||| verdict.
public export
lcrs_8_2__site_decided : (Bool, Rlow_4_6_6_1__trackers) -> Lcyc_3_2_1__program -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                         Nat -> Nat -> Lcrs_6_2_1__site -> Iret_7_1__token -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
lcrs_8_2__site_decided (ok, trk') pg env corrOf ans r n site tok acc =
  lcrs_6_2_1__issue_if ok pg env corrOf ans r n site tok (MkAcc (anet acc) (astamps acc) trk' (arecs acc))

--@spec [LCRS.8.2]
--@spec [RLOW.4.6.6.1]
--@spec [RLOW.7.3.8]
||| A CALL SITE RUN: the gate at the net's clock on the site's tracker, then
||| the issue under the verdict. The gate covers the sweep as it covers the
||| call ([RLOW.7.3.8]).
public export
lcrs_8_2__call_site : Lcyc_3_2_1__program -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Nat -> (Nat, Lcrs_6_2_1__site) ->
                      Iret_7_1__token -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
lcrs_8_2__call_site pg env corrOf ans r ns tok acc =
  lcrs_8_2__site_decided (lcrs_8_2__admit_gate (sgate (snd ns)) r (fst ns) (nclock (anet acc)) tok (atrk acc))
                         pg env corrOf ans r (fst ns) (snd ns) tok acc

--@spec [RLOW.7.3.8]
||| Whether a site is at a position.
public export
rlow_7_3_8__at_position : Nat -> (Nat, Lcrs_6_2_1__site) -> Bool
rlow_7_3_8__at_position i ns = sposition (snd ns) == i

--@spec [RLOW.7.3.8]
||| The sites at a position, in site order.
public export
rlow_7_3_8__sites_at : Nat -> List (Nat, Lcrs_6_2_1__site) -> List (Nat, Lcrs_6_2_1__site)
rlow_7_3_8__sites_at i sites = filter (rlow_7_3_8__at_position i) sites

--@spec [LCRS.8.2]
--@spec [RLOW.7.3.8]
||| The sites of one position run in order, each on the accumulator the
||| last left: two calls in one rule cool independently, and a suppressed
||| one stops nothing else ([LCRS.8.2]).
public export
rlow_7_3_8__run_sites : Lcyc_3_2_1__program -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Nat -> List (Nat, Lcrs_6_2_1__site) ->
                        Iret_7_1__token -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
rlow_7_3_8__run_sites pg env corrOf ans r []        tok acc = acc
rlow_7_3_8__run_sites pg env corrOf ans r (s :: ss) tok acc =
  rlow_7_3_8__run_sites pg env corrOf ans r ss tok (lcrs_8_2__call_site pg env corrOf ans r s tok acc)

--@spec [RLOW.7.3.8]
||| A stamped net and stamps, with trackers and records, as an accumulator.
||| By projections, so that it reduces on a pair not yet a constructor.
public export
rlow_7_3_8__with_stamped : (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> Rlow_4_6_6_1__trackers -> List Ncbk_6_9__call_record -> Rlow_7_3_8__acc
rlow_7_3_8__with_stamped x trk recs = MkAcc (fst x) (snd x) trk recs

--@spec [RLOW.7.3.8]
--@spec [RARC.5.6.7]
||| One emit or withdraw on the accumulator: Rete/NetworkTimed.idr's stamped
||| action on the net and the stamps; the trackers and the records stand.
public export
rlow_7_3_8__do_action_acc : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Iret_8_1__act -> Lgra_10_1__action -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
rlow_7_3_8__do_action_acc pg ttl r a act acc =
  rlow_7_3_8__with_stamped (rarc_5_6_7__do_action_stamped pg ttl r a act (anet acc, astamps acc)) (atrk acc) (arecs acc)

--@spec [RLOW.7.3.8]
--@spec [RARC.5.6.7]
--@spec [LCRS.8.2]
||| THE RHS WITH CALLS: at each position the sites there, then the action
||| there; the sites past the last action after it. The `i`-th position is
||| the one before the `i`-th emit or withdraw.
public export
rlow_7_3_8__do_actions_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Nat ->
                                List (Nat, Lcrs_6_2_1__site) -> Nat -> Iret_8_1__act -> List Lgra_10_1__action -> Rlow_7_3_8__acc -> Rlow_7_3_8__acc
rlow_7_3_8__do_actions_called pg ttl env corrOf ans r sites i a [] acc =
  rlow_7_3_8__run_sites pg env corrOf ans r (rlow_7_3_8__sites_at i sites) (atuple a) acc
rlow_7_3_8__do_actions_called pg ttl env corrOf ans r sites i a (act :: acts) acc =
  rlow_7_3_8__do_actions_called pg ttl env corrOf ans r sites (S i) a acts
    (rlow_7_3_8__do_action_acc pg ttl r a act (rlow_7_3_8__run_sites pg env corrOf ans r (rlow_7_3_8__sites_at i sites) (atuple a) acc))

-- ---------------------------------------------------------------------
-- The gated firing with calls [LTIM.2.5.4], [LCDB.3.2.1.1], [LCRS.6.2.1]
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2.1]
||| THE OUTCOME of a gated RHS with calls: the rule's verdict, the net and
||| the stamps the actions left, the rule's trackers, the call trackers and
||| the calls issued.
public export
record Lcrs_6_2_1__outcome where
  constructor MkOutcome
  overdict : Bool
  onet     : Iret_19_3__clocked_net
  ostamps  : Ltim_2_8_6__stamps
  otrk     : Iret_10_4__trackers
  ocalltrk : Rlow_4_6_6_1__trackers
  orecs    : List Ncbk_6_9__call_record

--@spec [LCRS.6.2.1]
||| An accumulator as an outcome under a verdict and the rule's trackers.
public export
lcrs_6_2_1__of_acc : Bool -> Iret_10_4__trackers -> Rlow_7_3_8__acc -> Lcrs_6_2_1__outcome
lcrs_6_2_1__of_acc ok trk acc = MkOutcome ok (anet acc) (astamps acc) trk (atrk acc) (arecs acc)

--@spec [LCRS.6.2.1]
--@spec [LTIM.2.5.4]
--@spec [LCDB.3.2.1.1]
--@spec [RLOW.7.3.8]
||| THE RHS WITH CALLS UNDER THE RULE'S VERDICT: admitted, the actions and
||| the sites run on the marked net from position 0 with no call issued yet;
||| refused, the marked net, the stamps and the call trackers stand and no
||| call is issued.
public export
lcrs_6_2_1__run_if_called : (Bool, Iret_10_4__trackers) -> Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                            Nat -> List (Nat, Lcrs_6_2_1__site) -> Iret_8_1__act -> List Lgra_10_1__action ->
                            (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> Rlow_4_6_6_1__trackers -> Lcrs_6_2_1__outcome
lcrs_6_2_1__run_if_called (True, trk)  pg ttl env corrOf ans r sites a acts x ctrk =
  lcrs_6_2_1__of_acc True trk (rlow_7_3_8__do_actions_called pg ttl env corrOf ans r sites 0 a acts (MkAcc (fst x) (snd x) ctrk []))
lcrs_6_2_1__run_if_called (False, trk) pg ttl env corrOf ans r sites a acts x ctrk = MkOutcome False (fst x) (snd x) trk ctrk []

--@spec [LTIM.2.5.4]
--@spec [LCDB.3.2.1.1]
--@spec [RDSC.4a.8.2.3]
--@spec [LCRS.6.2.1]
||| THE RHS WITH CALLS GATED BY THE RULE'S COOLDOWN: Rete/NetworkTimed.idr's
||| gate, then the RHS with calls under its verdict. A rule-level refusal
||| issues no call: no action of the rule runs.
public export
lcrs_6_2_1__rhs_gated_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                               Nat -> List (Nat, Lcrs_6_2_1__site) -> Iret_8_1__act -> List Lgra_10_1__action -> Nat -> Iret_10_4__trackers ->
                               (Iret_19_3__clocked_net, Ltim_2_8_6__stamps) -> Rlow_4_6_6_1__trackers -> Lcrs_6_2_1__outcome
lcrs_6_2_1__rhs_gated_called pg ttl Nothing env corrOf ans r sites a acts c trk x ctrk =
  lcrs_6_2_1__of_acc True trk (rlow_7_3_8__do_actions_called pg ttl env corrOf ans r sites 0 a acts (MkAcc (fst x) (snd x) ctrk []))
lcrs_6_2_1__rhs_gated_called pg ttl (Just (window, kf)) env corrOf ans r sites a acts c trk x ctrk =
  lcrs_6_2_1__run_if_called (iret_10_4__allow window c (r, kf (atuple a)) trk) pg ttl env corrOf ans r sites a acts x ctrk

--@spec [LCRS.6.2.1]
||| The timed state with the call trackers beside it: what the called pump
||| runs on.
public export
Lcrs_6_2_1__called_state : Type
Lcrs_6_2_1__called_state = (Ltim_2_4_1__timed_state, Rlow_4_6_6_1__trackers)

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
||| A firing named: Rete/NetworkTimed.idr's name -- the ordinal, the fired
||| facts, the rule's verdict -- with the calls the firing issued, in order.
public export
Lcrs_6_2_1__firing : Type
Lcrs_6_2_1__firing = ((Nat, Iret_7_1__token, Bool), List Ncbk_6_9__call_record)

--@spec [LCRS.6.2.1]
||| A firing named, with the called state after it: the net and the stamps
||| the RHS left, the wall sample kept, both tracker tables the RHS's.
public export
lcrs_6_2_1__label : Nat -> Iret_7_1__token -> Nat -> Lcrs_6_2_1__outcome -> Maybe (Lcrs_6_2_1__firing, Lcrs_6_2_1__called_state)
lcrs_6_2_1__label r fs w o = Just (((r, fs, overdict o), orecs o), ((MkSampled (onet o) w (ostamps o), otrk o), ocalltrk o))

--@spec [LCRS.6.2.1]
--@spec [LTIM.2.5.4]
||| THE FIRING AT A SELECTION, with calls: mark the activation fired, then
||| the gated RHS with the rule's sites.
public export
lcrs_6_2_1__fire_at : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                      List (List (Nat, Lcrs_6_2_1__site)) -> Iret_19__engine -> Iret_12_4__table -> Iret_4_3__deadlines -> Nat -> Nat ->
                      Ltim_2_8_6__stamps -> Iret_10_4__trackers -> Rlow_4_6_6_1__trackers -> Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act) ->
                      Maybe (Lcrs_6_2_1__firing, Lcrs_6_2_1__called_state)
lcrs_6_2_1__fire_at pg ttl cools env corrOf ans sites eng rows dl c w st trk ctrk Nothing = Nothing
lcrs_6_2_1__fire_at pg ttl cools env corrOf ans sites eng rows dl c w st trk ctrk (Just (r, j, ch, a)) =
  lcrs_6_2_1__label r (atuple a) w
    (lcrs_6_2_1__rhs_gated_called pg ttl (lcdb_3_2_1__cool_at cools r) env corrOf ans r (lcrs_6_2_1__sites_at sites r) a (cactions ch) c trk
       (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c, st) ctrk)

--@spec [LCRS.6.2.1]
--@spec [LTIM.2.5.4]
--@spec [RDSC.4a.8.2.3]
||| THE GATED FIRING WITH CALLS: Rete/NetworkTimed.idr's selection and mark,
||| then the gated RHS with calls; named as a firing Rete/RunFold.idr's
||| traced fold takes.
public export
lcrs_6_2_1__fire_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                          List (List (Nat, Lcrs_6_2_1__site)) -> Lcrs_6_2_1__called_state -> Maybe (Lcrs_6_2_1__firing, Lcrs_6_2_1__called_state)
lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites ((MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk), ctrk) =
  lcrs_6_2_1__fire_at pg ttl cools env corrOf ans sites eng rows dl c w st trk ctrk (lcdb_3_2_1__selected eng)

--@spec [LCRS.6.2.1]
--@spec [IRET.11.4]
||| THE RUN, TRACED: Rete/RunFold.idr's traced fold over the called firing.
public export
lcrs_6_2_1__run_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                         List (List (Nat, Lcrs_6_2_1__site)) -> Nat -> Lcrs_6_2_1__called_state ->
                         (Lcrs_6_2_1__called_state, Iret_11_4__halt, List Lcrs_6_2_1__firing)
lcrs_6_2_1__run_called pg ttl cools env corrOf ans sites fuel s = iret_11_4__trace_by (lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites) fuel s

--@spec [LCRS.6.2.1]
--@spec [IRET.19.5]
--@spec [LTIM.2.4.2]
||| THE PUMP: Rete/NetworkTimed.idr's re-time at entry, then the called run.
public export
lcrs_6_2_1__pump_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                          List (List (Nat, Lcrs_6_2_1__site)) -> List (Maybe Ltim_2_4_1__ttest) -> Nat -> Lcrs_6_2_1__called_state ->
                          (Lcrs_6_2_1__called_state, Iret_11_4__halt, List Lcrs_6_2_1__firing)
lcrs_6_2_1__pump_called pg ttl cools env corrOf ans sites tests fuel ((s, trk), ctrk) =
  lcrs_6_2_1__run_called pg ttl cools env corrOf ans sites fuel ((ltim_2_4_3__retime_at_entry pg tests s, trk), ctrk)

--@spec [LCRS.6.2.1]
--@spec [LTIM.2.8.4]
||| A TICK: Rete/NetworkTimed.idr's; the call trackers stand.
public export
lcrs_6_2_1__tick_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Nat -> Lcrs_6_2_1__called_state -> Lcrs_6_2_1__called_state
lcrs_6_2_1__tick_called pg ttl t (s, ctrk) = (ltim_2_8_4__tick_timed pg ttl t s, ctrk)

--@spec [LCRS.6.2.1]
--@spec [LTIM.2.8.3]
||| THE WALL STEP: Rete/NetworkWall.idr's; the call trackers stand.
public export
lcrs_6_2_1__wall_called : Nat -> Lcrs_6_2_1__called_state -> Lcrs_6_2_1__called_state
lcrs_6_2_1__wall_called w (s, ctrk) = (ltim_2_8_3__wall_set_timed w s, ctrk)

-- ---------------------------------------------------------------------
-- The arrival [LCRS.6.2.4], [NCBK.6.4]
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2.4]
||| The victims of an arriving fact of a kind under its read correlation:
||| none for a fact that reads no correlation.
public export
lcrs_6_2_4__victims_of : Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Nat -> Maybe Lstr_1_1__text -> Rarc_5_6_4__wm -> List Nat
lcrs_6_2_4__victims_of env corrOf ans k Nothing  wm = []
lcrs_6_2_4__victims_of env corrOf ans k (Just t) wm = lcrs_6_2__victims env corrOf (lcrs_6_2_4__swept_by ans k) t wm

--@spec [LCRS.6.2.4]
--@spec [NCBK.6.4]
||| THE VICTIMS OF A DATA EVENT: an assert of kind `k` sweeps the kinds `k`
||| sweeps on the asserted value's correlation; a retraction sweeps nothing.
public export
lcrs_6_2_4__arrival_victims : Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Rarc_5_6_1__event -> Rarc_5_6_4__wm -> List Nat
lcrs_6_2_4__arrival_victims env corrOf ans (Retract i)        wm = []
lcrs_6_2_4__arrival_victims env corrOf ans (Assert k key pay) wm =
  lcrs_6_2_4__victims_of env corrOf ans k (lcrs_4_3_2__corr_at env (corrOf k) key pay) wm

--@spec [LCRS.6.2.4]
--@spec [NCBK.6.4]
--@spec [LTIM.2.8.6]
||| A DATA INPUT ARRIVES: the arrival's sweep on the net as it stands, then
||| Rete/NetworkTimed.idr's input -- the TTL sweep, the event applied and
||| stamped -- so the retractions precede the answer in working memory
||| ([LCRS.6.2.4]) and the answer is stamped at the held sample as any
||| entered fact is. The trackers stand.
public export
lcrs_6_2_4__arrive_timed : Lcyc_3_2_1__program -> Iret_4_2__ttl -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> Rarc_5_6_1__event ->
                           Lcrs_6_2_1__called_state -> Lcrs_6_2_1__called_state
lcrs_6_2_4__arrive_timed pg ttl env corrOf ans ev ((MkSampled net w st, trk), ctrk) =
  (ltim_2_8_6__input_timed pg ttl ev (MkSampled (lcrs_6_2__sweep_ids_net pg (lcrs_6_2_4__arrival_victims env corrOf ans ev (lcrs_6_2_1__wm net)) net) w st, trk), ctrk)

-- ---------------------------------------------------------------------
-- A fixture's steps, and what the runner reads off a pump
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
||| The calls of a trace, in order: the records every firing issued.
public export
lcrs_6_2_1__calls_of_trace : List Lcrs_6_2_1__firing -> List Ncbk_6_9__call_record
lcrs_6_2_1__calls_of_trace []                = []
lcrs_6_2_1__calls_of_trace ((l, recs) :: tr) = recs ++ lcrs_6_2_1__calls_of_trace tr

--@spec [LCRS.6.2.1]
||| The verdicts of a trace: each firing's ordinal and the rule's verdict.
public export
lcrs_6_2_1__verdicts_of_trace : List Lcrs_6_2_1__firing -> List (Nat, Bool)
lcrs_6_2_1__verdicts_of_trace []                        = []
lcrs_6_2_1__verdicts_of_trace (((r, fs, ok), recs) :: tr) = (r, ok) :: lcrs_6_2_1__verdicts_of_trace tr

--@spec [LCRS.6.2.1]
--@spec [RARC.5.6.1]
||| A FIXTURE'S STEPS on the called engine, in its cadence: a tick, a data
||| input through the arrival, a pump under its fuel; per pump, the verdicts
||| and the calls, in order.
public export
lcrs_6_2_1__run_steps_called : Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> Iret_7_6__env -> Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers ->
                               List (List (Nat, Lcrs_6_2_1__site)) -> List (Maybe Ltim_2_4_1__ttest) -> List Rarc_5_6_2__step -> Lcrs_6_2_1__called_state ->
                               (Lcrs_6_2_1__called_state, List (List (Nat, Bool), List Ncbk_6_9__call_record))
lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests [] s = (s, [])
lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests (SInput (Tick t) :: ss) s =
  lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests ss (lcrs_6_2_1__tick_called pg ttl t s)
lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests (SInput (Data ev) :: ss) s =
  lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests ss (lcrs_6_2_4__arrive_timed pg ttl env corrOf ans ev s)
lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests (SPumpT fuel :: ss) s =
  case lcrs_6_2_1__pump_called pg ttl cools env corrOf ans sites tests fuel s of
    (s', h, tr) => case lcrs_6_2_1__run_steps_called pg ttl cools env corrOf ans sites tests ss s' of
      (s'', vs) => (s'', (lcrs_6_2_1__verdicts_of_trace tr, lcrs_6_2_1__calls_of_trace tr) :: vs)

-- ---------------------------------------------------------------------
-- The frames: no call site, no corr [RLOW.7.3.8], [LCRS.6.2.1], [LCRS.6.2.4]
-- ---------------------------------------------------------------------

--@derives [RLOW.7.3.8]
--@derives [RARC.5.6.7]
||| WITH NO SITE THE FOLD IS THE STAMPED RHS: from any position, the actions
||| run as Rete/NetworkTimed.idr runs them, the trackers and the records
||| untouched. By induction on the actions.
export
rlow_7_3_8__no_site_is_the_stamped_rhs : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) ->
                                         (ans : Lcrs_4_2_2__answers) -> (r, i : Nat) -> (a : Iret_8_1__act) -> (acts : List Lgra_10_1__action) ->
                                         (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) -> (ctrk : Rlow_4_6_6_1__trackers) ->
                                         (recs : List Ncbk_6_9__call_record) ->
                                         rlow_7_3_8__do_actions_called pg ttl env corrOf ans r [] i a acts (MkAcc cs st ctrk recs)
                                           = rlow_7_3_8__with_stamped (rarc_5_6_7__do_actions_stamped pg ttl r a acts (cs, st)) ctrk recs
rlow_7_3_8__no_site_is_the_stamped_rhs pg ttl env corrOf ans r i a [] cs st ctrk recs = Refl
rlow_7_3_8__no_site_is_the_stamped_rhs pg ttl env corrOf ans r i a (act :: acts) cs st ctrk recs =
  rlow_7_3_8__no_site_is_the_stamped_rhs pg ttl env corrOf ans r (S i) a acts
    (rarc_5_6_7__do_action_ttl_net pg ttl r a act cs)
    (ltim_2_8_6__record_action pg (nclock cs) a act (ewm (ncore (nengine cs))) st)
    ctrk recs

--@spec [LCRS.6.2.1]
||| Rete/NetworkTimed.idr's gated verdict as an outcome with no call issued:
||| what a siteless rule's outcome is.
public export
lcrs_6_2_1__outcome_of : (Bool, ((Iret_19_3__clocked_net, Ltim_2_8_6__stamps), Iret_10_4__trackers)) -> Rlow_4_6_6_1__trackers -> Lcrs_6_2_1__outcome
lcrs_6_2_1__outcome_of x ctrk = MkOutcome (fst x) (fst (fst (snd x))) (snd (fst (snd x))) (snd (snd x)) ctrk []

--@derives [LCRS.6.2.1]
--@derives [LTIM.2.5.4]
--@derives [LCDB.3.2.1.1]
||| With no site, the RHS under a verdict is Rete/NetworkTimed.idr's.
export
lcrs_6_2_1__no_site_run_if : (d : (Bool, Iret_10_4__trackers)) -> (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (env : Iret_7_6__env) ->
                             (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (r : Nat) -> (a : Iret_8_1__act) -> (acts : List Lgra_10_1__action) ->
                             (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) -> (ctrk : Rlow_4_6_6_1__trackers) ->
                             lcrs_6_2_1__run_if_called d pg ttl env corrOf ans r [] a acts (cs, st) ctrk
                               = lcrs_6_2_1__outcome_of (ltim_2_5_4__run_if d pg ttl r a acts (cs, st)) ctrk
lcrs_6_2_1__no_site_run_if (True, trk)  pg ttl env corrOf ans r a acts cs st ctrk =
  cong (lcrs_6_2_1__of_acc True trk) (rlow_7_3_8__no_site_is_the_stamped_rhs pg ttl env corrOf ans r 0 a acts cs st ctrk [])
lcrs_6_2_1__no_site_run_if (False, trk) pg ttl env corrOf ans r a acts cs st ctrk = Refl

--@derives [LTIM.2.5.4]
--@derives [RDSC.4a.8.2.3]
--@derives [LCRS.6.2.1]
||| WITH NO SITE THE GATED RHS IS Rete/NetworkTimed.idr's: the same gate, the
||| same verdict, net, stamps and trackers, the call trackers untouched and
||| no call issued.
export
lcrs_6_2_1__no_site_outcome : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (co : Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                              (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (r : Nat) -> (a : Iret_8_1__act) -> (acts : List Lgra_10_1__action) ->
                              (c : Nat) -> (trk : Iret_10_4__trackers) -> (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) -> (ctrk : Rlow_4_6_6_1__trackers) ->
                              lcrs_6_2_1__rhs_gated_called pg ttl co env corrOf ans r [] a acts c trk (cs, st) ctrk
                                = lcrs_6_2_1__outcome_of (ltim_2_5_4__rhs_gated pg ttl co r a acts c trk (cs, st)) ctrk
lcrs_6_2_1__no_site_outcome pg ttl Nothing env corrOf ans r a acts c trk cs st ctrk =
  cong (lcrs_6_2_1__of_acc True trk) (rlow_7_3_8__no_site_is_the_stamped_rhs pg ttl env corrOf ans r 0 a acts cs st ctrk [])
lcrs_6_2_1__no_site_outcome pg ttl (Just (window, kf)) env corrOf ans r a acts c trk cs st ctrk =
  lcrs_6_2_1__no_site_run_if (iret_10_4__allow window c (r, kf (atuple a)) trk) pg ttl env corrOf ans r a acts cs st ctrk

--@derives [LCRS.6.2.1]
||| With no rule sited, every ordinal's sites are none.
export
lcrs_6_2_1__sites_at_unsited : (sites : List (List (Nat, Lcrs_6_2_1__site))) -> lcrs_6_2_1__unsited sites = True -> (r : Nat) ->
                               lcrs_6_2_1__sites_at sites r = []
lcrs_6_2_1__sites_at_unsited []               u r     = Refl
lcrs_6_2_1__sites_at_unsited ([] :: ss)       u Z     = Refl
lcrs_6_2_1__sites_at_unsited ([] :: ss)       u (S r) = lcrs_6_2_1__sites_at_unsited ss u r
lcrs_6_2_1__sites_at_unsited ((_ :: _) :: ss) u r     = absurd u

--@spec [LCRS.6.2.1]
||| A called firing with its calls and its call trackers dropped:
||| Rete/NetworkTimed.idr's firing. By projections, so that it reduces on a
||| firing not yet a pair.
public export
lcrs_6_2_1__proj_firing : (Lcrs_6_2_1__firing, Lcrs_6_2_1__called_state) -> ((Nat, Iret_7_1__token, Bool), Ltim_2_4_1__timed_state)
lcrs_6_2_1__proj_firing x = (fst (fst x), fst (snd x))

--@derives [LCRS.6.2.1]
--@derives [LTIM.2.5.4]
||| WITH NO RULE SITED THE FIRING AT A SELECTION PROJECTS to
||| Rete/NetworkTimed.idr's firing at the same selection.
export
lcrs_6_2_1__no_site_fire_at_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                       (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                       lcrs_6_2_1__unsited sites = True ->
                                       (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c, w : Nat) ->
                                       (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) -> (ctrk : Rlow_4_6_6_1__trackers) ->
                                       (m : Maybe (Nat, Nat, Rlow_4_2_1__chain, Iret_8_1__act)) ->
                                       map lcrs_6_2_1__proj_firing (lcrs_6_2_1__fire_at pg ttl cools env corrOf ans sites eng rows dl c w st trk ctrk m)
                                         = ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk m
lcrs_6_2_1__no_site_fire_at_projects pg ttl cools env corrOf ans sites u eng rows dl c w st trk ctrk Nothing = Refl
lcrs_6_2_1__no_site_fire_at_projects pg ttl cools env corrOf ans sites u eng rows dl c w st trk ctrk (Just (r, j, ch, a)) =
  replace {p = \ss => map lcrs_6_2_1__proj_firing
                        (lcrs_6_2_1__label r (atuple a) w
                           (lcrs_6_2_1__rhs_gated_called pg ttl (lcdb_3_2_1__cool_at cools r) env corrOf ans r ss a (cactions ch) c trk
                              (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c, st) ctrk))
                        = ltim_2_5_4__fire_at pg ttl cools eng rows dl c w st trk (Just (r, j, ch, a))}
          (sym (lcrs_6_2_1__sites_at_unsited sites u r))
          (cong (\o => Just ((r, atuple a, overdict o), (MkSampled (onet o) w (ostamps o), otrk o)))
                (lcrs_6_2_1__no_site_outcome pg ttl (lcdb_3_2_1__cool_at cools r) env corrOf ans r a (cactions ch) c trk
                   (MkClockedNet (MkTmsNet (idat_6_2_2__mark_net r j eng) rows) dl c) st ctrk))

--@derives [LCRS.6.2.1]
--@derives [LTIM.2.5.4]
||| WITH NO RULE SITED THE CALLED FIRING PROJECTS TO THE TIMED FIRING on
||| the timed half of the state.
export
lcrs_6_2_1__no_site_fire_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                    (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                    lcrs_6_2_1__unsited sites = True -> (s : Lcrs_6_2_1__called_state) ->
                                    map lcrs_6_2_1__proj_firing (lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites s)
                                      = ltim_2_5_4__fire_timed pg ttl cools (fst s)
lcrs_6_2_1__no_site_fire_projects pg ttl cools env corrOf ans sites u ((MkSampled (MkClockedNet (MkTmsNet eng rows) dl c) w st, trk), ctrk) =
  lcrs_6_2_1__no_site_fire_at_projects pg ttl cools env corrOf ans sites u eng rows dl c w st trk ctrk (lcdb_3_2_1__selected eng)

--@derives [LCRS.6.2.1]
||| A called firing that resolves to nothing: so does the timed firing.
export
lcrs_6_2_1__no_site_fire_nothing : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                   (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                   lcrs_6_2_1__unsited sites = True -> (s : Lcrs_6_2_1__called_state) ->
                                   lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites s = Nothing -> ltim_2_5_4__fire_timed pg ttl cools (fst s) = Nothing
lcrs_6_2_1__no_site_fire_nothing pg ttl cools env corrOf ans sites u s e =
  trans (sym (lcrs_6_2_1__no_site_fire_projects pg ttl cools env corrOf ans sites u s)) (cong (map lcrs_6_2_1__proj_firing) e)

--@derives [LCRS.6.2.1]
||| A called firing that names a firing: the timed firing names its
||| projection, with the state projected.
export
lcrs_6_2_1__no_site_fire_just : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                lcrs_6_2_1__unsited sites = True -> (s : Lcrs_6_2_1__called_state) -> (f : Lcrs_6_2_1__firing) -> (s1 : Lcrs_6_2_1__called_state) ->
                                lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites s = Just (f, s1) ->
                                ltim_2_5_4__fire_timed pg ttl cools (fst s) = Just (fst f, fst s1)
lcrs_6_2_1__no_site_fire_just pg ttl cools env corrOf ans sites u s f s1 e =
  trans (sym (lcrs_6_2_1__no_site_fire_projects pg ttl cools env corrOf ans sites u s)) (cong (map lcrs_6_2_1__proj_firing) e)

--@derives [LCRS.6.2.1]
--@derives [IRET.11.4]
||| WITH NO RULE SITED THE RUN PROJECTS: the called run's state, halt and
||| trace, the state and the trace projected, are Rete/NetworkTimed.idr's
||| run's from the timed half, for any fuel. By induction on the fuel
||| through the firing's projection, as Rete/NetworkTimed.idr's run projects.
export
lcrs_6_2_1__no_site_run_projects : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                   (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                   lcrs_6_2_1__unsited sites = True -> (fuel : Nat) -> (s : Lcrs_6_2_1__called_state) ->
                                   (s' : Lcrs_6_2_1__called_state ** (h : Iret_11_4__halt ** (tr : List Lcrs_6_2_1__firing **
                                     ( lcrs_6_2_1__run_called pg ttl cools env corrOf ans sites fuel s = (s', h, tr)
                                     , ltim_2_4_2__run_timed pg ttl cools fuel (fst s) = (fst s', h, map fst tr) ))))
lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u Z s = (s ** (FuelOut ** ([] ** (Refl, Refl))))
lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u (S fuel) s with (lcrs_6_2_1__fire_called pg ttl cools env corrOf ans sites s) proof e
  lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u (S fuel) s | Nothing =
    (s ** (Quiescent ** ([] ** ( Refl
                               , iret_11_4__trace_by_end (ltim_2_5_4__fire_timed pg ttl cools) fuel (fst s)
                                   (lcrs_6_2_1__no_site_fire_nothing pg ttl cools env corrOf ans sites u s e) ))))
  lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u (S fuel) s | (Just (f, s1)) =
    let (s' ** (h ** (tr ** (rE, tE)))) = lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u fuel s1
    in (s' ** (h ** ((f :: tr) ** ( rewrite rE in Refl
                                  , iret_11_4__trace_by_cons (ltim_2_5_4__fire_timed pg ttl cools) fuel (fst s) (fst s1) (fst f) (fst s') h (map fst tr)
                                      (lcrs_6_2_1__no_site_fire_just pg ttl cools env corrOf ans sites u s f s1 e) tE ))))

--@derives [LCRS.6.2.1]
--@derives [LTIM.2.4.2]
||| THE FRAME: with no rule sited, the called pump's state, halt and trace
||| project to Rete/NetworkTimed.idr's timed pump's from the timed half of
||| the state, the call trackers beside and no call issued. Every fixture
||| the Idris model compared before this rung runs through the called engine,
||| and its agreement holds by this theorem and Rete/NetworkTimed.idr's
||| frame rather than by a rerun.
export
lcrs_6_2_1__no_site_is_the_timed_pump : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (cools : List Lcdb_3_2_1__cool) -> (env : Iret_7_6__env) ->
                                        (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) -> (sites : List (List (Nat, Lcrs_6_2_1__site))) ->
                                        lcrs_6_2_1__unsited sites = True -> (tests : List (Maybe Ltim_2_4_1__ttest)) -> (fuel : Nat) ->
                                        (ts : Ltim_2_8_1__sampled_net) -> (trk : Iret_10_4__trackers) -> (ctrk : Rlow_4_6_6_1__trackers) ->
                                        (s' : Lcrs_6_2_1__called_state ** (h : Iret_11_4__halt ** (tr : List Lcrs_6_2_1__firing **
                                          ( lcrs_6_2_1__pump_called pg ttl cools env corrOf ans sites tests fuel ((ts, trk), ctrk) = (s', h, tr)
                                          , ltim_2_4_2__pump_timed pg ttl cools tests fuel (ts, trk) = (fst s', h, map fst tr) ))))
lcrs_6_2_1__no_site_is_the_timed_pump pg ttl cools env corrOf ans sites u tests fuel ts trk ctrk =
  lcrs_6_2_1__no_site_run_projects pg ttl cools env corrOf ans sites u fuel ((ltim_2_4_3__retime_at_entry pg tests ts, trk), ctrk)

--@derives [LCRS.6.2.4]
--@derives [LTIM.2.8.6]
||| WITH NO KIND CARRYING A `corr` AN ARRIVAL IS THE INPUT: the arrival's
||| sweep finds no correlation to sweep on, and Rete/NetworkTimed.idr's
||| input runs on the net as it stood.
export
lcrs_6_2_4__no_corr_arrival_is_the_input : (pg : Lcyc_3_2_1__program) -> (ttl : Iret_4_2__ttl) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) ->
                                           ((k : Nat) -> corrOf k = Nothing) -> (ans : Lcrs_4_2_2__answers) -> (ev : Rarc_5_6_1__event) ->
                                           (net : Iret_19_3__clocked_net) -> (w : Nat) -> (st : Ltim_2_8_6__stamps) -> (trk : Iret_10_4__trackers) ->
                                           (ctrk : Rlow_4_6_6_1__trackers) ->
                                           lcrs_6_2_4__arrive_timed pg ttl env corrOf ans ev ((MkSampled net w st, trk), ctrk)
                                             = (ltim_2_8_6__input_timed pg ttl ev (MkSampled net w st, trk), ctrk)
lcrs_6_2_4__no_corr_arrival_is_the_input pg ttl env corrOf nocorr ans (Retract i) net w st trk ctrk = Refl
lcrs_6_2_4__no_corr_arrival_is_the_input pg ttl env corrOf nocorr ans (Assert k key pay) net w st trk ctrk =
  cong (\m => (ltim_2_8_6__input_timed pg ttl (Assert k key pay)
                 (MkSampled (lcrs_6_2__sweep_ids_net pg (lcrs_6_2_4__victims_of env corrOf ans k (lcrs_4_3_2__corr_at env m key pay) (lcrs_6_2_1__wm net)) net) w st, trk), ctrk))
       (nocorr k)

-- ---------------------------------------------------------------------
-- The retraction of ids and the cascade only remove [IRET.12.2]
-- ---------------------------------------------------------------------

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

--@derives [IRET.12.2]
||| ONE PHASE, BY CASES: it ends nothing and is the identity, or it ends rows
||| and the engine it leaves is the retraction of the zeroed ids from the
||| engine it started with, the engine named rather than existential.
export
iret_12_2__phase_step_net_split : (pg : Lcyc_3_2_1__program) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) ->
  Either ( iret_12_2__ended_net eng rows = []
         , iret_12_2__phase_step_net pg (MkTmsNet eng rows) = MkTmsNet eng rows )
         (x : Iret_12_4__row ** (xs : Iret_12_4__table **
            ( iret_12_2__ended_net eng rows = x :: xs
            , iret_12_2__phase_step_net pg (MkTmsNet eng rows)
                = MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows) )))
iret_12_2__phase_step_net_split pg eng rows with (iret_12_2__ended_net eng rows)
  iret_12_2__phase_step_net_split pg eng rows | [] = Left (Refl, Refl)
  iret_12_2__phase_step_net_split pg eng rows | (x :: xs) = Right (x ** (xs ** (Refl, Refl)))

--@derives [IRET.12.2]
||| A CASCADE ONLY REMOVES FACTS: a fact in working memory after any number of
||| phases was in it before. An ending phase is a retraction of ids
||| (`iret_12_2__retract_ids_net_sub`); a quiet phase changes nothing.
export
iret_12_2__phase_n_net_wm_sub : (n : Nat) -> (pg : Lcyc_3_2_1__program) -> (s : Iret_12__net_state) -> (g : Lfac_1_7_1__fact) ->
                                Elem g (ewm (ncore (iret_12_2__phase_n_net n pg s))) -> Elem g (ewm (ncore s))
iret_12_2__phase_n_net_wm_sub Z pg s g e = e
iret_12_2__phase_n_net_wm_sub (S m) pg (MkTmsNet eng rows) g e = case iret_12_2__phase_step_net_split pg eng rows of
  Left (_, eq) =>
    iret_12_2__phase_n_net_wm_sub m pg (MkTmsNet eng rows) g
      (replace {p = \t => Elem g (ewm (ncore t))} (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows) eng rows eq) e)
  Right (x ** (xs ** (_, eq))) =>
    iret_12_2__retract_ids_net_sub (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng g
      (iret_12_2__phase_n_net_wm_sub m pg
         (MkTmsNet (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows)) g
         (replace {p = \t => Elem g (ewm (ncore t))}
                  (iret_12_2__phase_n_net_succ m pg (MkTmsNet eng rows)
                     (iret_12_2__retract_ids_net (iret_12_2__zeroed (x :: xs) (iret_12_2__kept_net eng rows)) eng) (iret_12_2__kept_net eng rows) eq)
                  e))

--@derives [IRET.12.2]
--@derives [IRET.4.4]
||| Retracting ids one at a time leaves the batch's working memory under
||| unique ids, for an engine given whole: Rete/NetworkTms.idr's
||| `iret_12_2__retract_ids_net_wm` on the engine's two fields.
export
iret_12_2__retract_ids_net_wm_eng : (ids : List Nat) -> (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) ->
                                    ewm (iret_12_2__retract_ids_net ids eng) = iret_12_2__retract_ids ids (ewm eng)
iret_12_2__retract_ids_net_wm_eng ids (MkEngine wm net) uq = iret_12_2__retract_ids_net_wm ids wm uq net

-- ---------------------------------------------------------------------
-- The sweep [LCRS.6.2.1], [LCRS.6.2.4], [IRET.12.2]
-- ---------------------------------------------------------------------

--@derives [LCRS.6.2]
--@derives [IRET.12.2]
||| A SWEEP ONLY REMOVES: a fact live after it was live before. The
||| retraction of ids only removes (`iret_12_2__retract_ids_net_sub`), and so
||| does the cascade (`iret_12_2__phase_n_net_wm_sub`).
export
lcrs_6_2__sweep_ids_net_sub : (pg : Lcyc_3_2_1__program) -> (ids : List Nat) -> (cs : Iret_19_3__clocked_net) -> (g : Lfac_1_7_1__fact) ->
                              Elem g (lcrs_6_2_1__wm (lcrs_6_2__sweep_ids_net pg ids cs)) -> Elem g (lcrs_6_2_1__wm cs)
lcrs_6_2__sweep_ids_net_sub pg [] cs g e = e
lcrs_6_2__sweep_ids_net_sub pg (i :: is) (MkClockedNet (MkTmsNet eng rows) dl c) g e =
  iret_12_2__retract_ids_net_sub (i :: is) eng g
    (iret_12_2__phase_n_net_wm_sub (S (length rows)) pg (MkTmsNet (iret_12_2__retract_ids_net (i :: is) eng) rows) g e)

--@derives [LCRS.6.2]
--@derives [IRET.19.2]
--@derives [IRET.4.4]
||| WHAT A SWEEP WAS ASKED TO REMOVE IS GONE: under unique ids, a fact live
||| after a sweep of some ids carries none of them. The retraction leaves the
||| batch's working memory (`iret_12_2__retract_ids_net_wm_eng`), the filter of the
||| ids, and the cascade only removes.
export
lcrs_6_2__swept_not_live : (pg : Lcyc_3_2_1__program) -> (ids : List Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) ->
                           (c : Nat) -> Iret_4_4__unique (ewm eng) -> (g : Lfac_1_7_1__fact) ->
                           Elem g (lcrs_6_2_1__wm (lcrs_6_2__sweep_ids_net pg ids (MkClockedNet (MkTmsNet eng rows) dl c))) ->
                           rarc_5_6_5__elem (fid g) ids = False
lcrs_6_2__swept_not_live pg [] eng rows dl c uq g e = Refl
lcrs_6_2__swept_not_live pg (i :: is) eng rows dl c uq g e =
  lcyc_1_1__not_true_is_false (rarc_5_6_5__elem (fid g) (i :: is))
    (snd (lcyc_1_1__elem_filter_inv (\f => not (rarc_5_6_5__elem (fid f) (i :: is))) (ewm eng)
            (replace {p = \wm => Elem g wm} (iret_12_2__retract_ids_net_wm_eng (i :: is) eng uq)
                     (iret_12_2__phase_n_net_wm_sub (S (length rows)) pg (MkTmsNet (iret_12_2__retract_ids_net (i :: is) eng) rows) g e))))

--@derives [LCRS.6.2.1]
--@derives [LCRS.6.2.4]
--@derives [RLOW.7.3.8]
||| EVERY SWEEP SWEEPS: after a sweep on a correlation over some kinds, no
||| live fact of those kinds carries that correlation -- after an issued
||| call, no live answer of its service carries the call's ([LCRS.6.2.1]);
||| after an arrival, none of the kinds it sweeps carries the answer's
||| ([LCRS.6.2.4]). Under unique ids; the correlation non-empty, the empty
||| one sweeping nothing.
export
lcrs_6_2_1__issued_call_sweeps : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (kinds : List Nat) ->
                                 (c : Nat) -> (cs : List Nat) -> (eng : Iret_19__engine) -> (rows : Iret_12_4__table) -> (dl : Iret_4_3__deadlines) -> (c0 : Nat) ->
                                 Iret_4_4__unique (ewm eng) -> (g : Lfac_1_7_1__fact) ->
                                 Elem g (lcrs_6_2_1__wm (lcrs_6_2__sweep_ids_net pg (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng))
                                                                                   (MkClockedNet (MkTmsNet eng rows) dl c0))) ->
                                 lcrs_6_2__is_victim env corrOf kinds (c :: cs) g = False
lcrs_6_2_1__issued_call_sweeps pg env corrOf kinds c cs eng rows dl c0 uq g e =
  iret_12__bool_false_of (lcrs_6_2__is_victim env corrOf kinds (c :: cs) g)
    (\isv => lcyc_1_1__bool_not_both (rarc_5_6_5__elem (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)))
               (lcyc_1_1__elem_l_true (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng))
                  (lcyc_1_1__elem_map_fwd fid
                     (lcyc_1_1__elem_filter_fwd (lcrs_6_2__is_victim env corrOf kinds (c :: cs)) (ewm eng)
                        (lcrs_6_2__sweep_ids_net_sub pg (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)) (MkClockedNet (MkTmsNet eng rows) dl c0) g e)
                        isv)))
               (lcrs_6_2__swept_not_live pg (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)) eng rows dl c0 uq g e))

--@derives [LCRS.6.2.1]
--@derives [LCRS.6.2.4]
--@derives [IRET.4.4]
||| THE RETRACTION REMOVES THE VICTIMS AND NOTHING ELSE: under unique ids, a
||| live fact that is no victim is live after the retraction of the victims'
||| ids. What the cascade then removes is [IRET.12.2]'s: a response fact,
||| being `ttl`, has no justification row, so "responses of other services
||| are untouched" and "the retractions precede the answer" rest on this.
export
lcrs_6_2_1__retraction_keeps_non_victims : (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (kinds : List Nat) -> (k : Lstr_1_1__text) ->
                                           (eng : Iret_19__engine) -> Iret_4_4__unique (ewm eng) -> (g : Lfac_1_7_1__fact) -> Elem g (ewm eng) ->
                                           lcrs_6_2__is_victim env corrOf kinds k g = False ->
                                           Elem g (ewm (iret_12_2__retract_ids_net (lcrs_6_2__victims env corrOf kinds k (ewm eng)) eng))
lcrs_6_2_1__retraction_keeps_non_victims env corrOf kinds [] eng uq g eg nv = eg
lcrs_6_2_1__retraction_keeps_non_victims env corrOf kinds (c :: cs) eng uq g eg nv =
  replace {p = \wm => Elem g wm} (sym (iret_12_2__retract_ids_net_wm_eng (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)) eng uq))
    (lcyc_1_1__elem_filter_fwd (\f => not (rarc_5_6_5__elem (fid f) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)))) (ewm eng) eg
       (iret_12__not_false (rarc_5_6_5__elem (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)))
          (iret_12__bool_false_of (rarc_5_6_5__elem (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng))) notVictimId)))
  where
    notVictimId : rarc_5_6_5__elem (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)) = True -> Void
    notVictimId prf =
      let (h ** (eh, idEq)) = lcyc_1_1__elem_map_inv fid (filter (lcrs_6_2__is_victim env corrOf kinds (c :: cs)) (ewm eng))
                                (lcyc_1_1__elem_l_elem (fid g) (lcrs_6_2__victims env corrOf kinds (c :: cs) (ewm eng)) prf)
          (eh', vh) = lcyc_1_1__elem_filter_inv (lcrs_6_2__is_victim env corrOf kinds (c :: cs)) (ewm eng) eh
      in lcyc_1_1__bool_not_both (lcrs_6_2__is_victim env corrOf kinds (c :: cs) g)
           (replace {p = \x => lcrs_6_2__is_victim env corrOf kinds (c :: cs) x = True} (uq h g eh' eg idEq) vh)
           nv

--@derives [LCRS.6.2.1]
--@derives [LCRS.6.2.4]
||| A KIND OUTSIDE THE SWEPT PAIR IS NO VICTIM: a fact of neither the swept
||| response kind nor `CallError` is left alone by a call's sweep and by a
||| response's arrival, whatever its correlation -- "responses of other
||| services are untouched".
export
lcrs_6_2_1__other_kind_is_no_victim : (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (t, e : Nat) -> (k : Lstr_1_1__text) -> (g : Lfac_1_7_1__fact) ->
                                      (t == fkind g) = False -> (e == fkind g) = False ->
                                      lcrs_6_2__is_victim env corrOf [t, e] k g = False
lcrs_6_2_1__other_kind_is_no_victim env corrOf t e k g nt ne = rewrite nt in rewrite ne in Refl

--@derives [LCRS.6.2]
--@derives [LCRS.6.2.1]
--@derives [LCRS.6.2.4]
--@derives [LRST.1.2]
||| A CORRELATION NO LIVE FACT CARRIES SWEEPS NOTHING: with no victim in
||| working memory the sweep is the identity -- a call whose correlation is
||| new, an answer whose correlation no earlier answer carries.
export
lcrs_6_2__no_carrier_sweeps_nothing : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (kinds : List Nat) ->
                                      (k : Lstr_1_1__text) -> (cs : Iret_19_3__clocked_net) ->
                                      rarc_5_6_5__any (lcrs_6_2__is_victim env corrOf kinds k) (lcrs_6_2_1__wm cs) = False ->
                                      lcrs_6_2__sweep_ids_net pg (lcrs_6_2__victims env corrOf kinds k (lcrs_6_2_1__wm cs)) cs = cs
lcrs_6_2__no_carrier_sweeps_nothing pg env corrOf kinds [] cs h = Refl
lcrs_6_2__no_carrier_sweeps_nothing pg env corrOf kinds (c :: ks) cs h =
  cong (\ids => lcrs_6_2__sweep_ids_net pg ids cs)
       (cong iret_11_3__fact_ids
             (lcyc_1_1__filter_all_false (lcrs_6_2__is_victim env corrOf kinds (c :: ks)) (lcrs_6_2_1__wm cs)
                (lcyc_1_1__any_false_all (lcrs_6_2__is_victim env corrOf kinds (c :: ks)) (lcrs_6_2_1__wm cs) h)))

--@derives [LCRS.6.2]
--@derives [LRST.1.2]
--@derives [LCRS.6.2.4]
||| THE EMPTY CORRELATION SWEEPS NOTHING, on either side: a transcription of
||| `lcrs_6_2__victims`' empty clause, said so. On the call side the
||| clause's own rule ([LRST.1.2]); on the arrival side [LCRS.6.2.4]'s.
export
lcrs_6_2__empty_corr_sweeps_nothing : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (kinds : List Nat) ->
                                      (cs : Iret_19_3__clocked_net) ->
                                      lcrs_6_2__sweep_ids_net pg (lcrs_6_2__victims env corrOf kinds [] (lcrs_6_2_1__wm cs)) cs = cs
lcrs_6_2__empty_corr_sweeps_nothing pg env corrOf kinds cs = Refl

--@derives [LCRS.6.2.1]
--@derives [LRST.1.2]
--@derives [LCCO.3.4]
--@derives [RLOW.7.3.8]
||| A CALL WHOSE `as` EVALUATES TO "" SUPERSEDES NOTHING: its issue is the
||| identity on the net. The generated correlation it takes is unique to the
||| firing and not modelled: the record carries the empty text.
export
lcrs_6_2_1__empty_corr_call_sweeps_nothing : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) ->
                                             (site : Lcrs_6_2_1__site) -> (tok : Iret_7_1__token) -> (cs : Iret_19_3__clocked_net) ->
                                             scorr site tok = [] -> lcrs_6_2_1__issue pg env corrOf ans site tok cs = cs
lcrs_6_2_1__empty_corr_call_sweeps_nothing pg env corrOf ans site tok cs h =
  cong (\k => lcrs_6_2__sweep_ids_net pg (lcrs_6_2__victims env corrOf (lcrs_6_2_1__swept_by_call ans (sresponse site)) k (lcrs_6_2_1__wm cs)) cs) h

--@derives [LCRS.17.1]
--@derives [LCRS.6.2.1]
||| A `no response` SERVICE'S CALL SWEEPS `CallError` ALONE: a transcription
||| of `lcrs_6_2_1__swept_by_call`, said so.
export
lcrs_17_1__no_response_sweeps_error_alone : (ans : Lcrs_4_2_2__answers) -> lcrs_6_2_1__swept_by_call ans Nothing = [aerror ans]
lcrs_17_1__no_response_sweeps_error_alone ans = Refl

--@derives [LCRS.6.2.4]
--@derives [LCRS.4.2.1]
||| A `CallError` ARRIVING SWEEPS EVERY ANSWER KIND: a transcription of the
||| first test of `lcrs_6_2_4__swept_if`, said so.
export
lcrs_6_2_4__error_sweeps_every_answer : (ans : Lcrs_4_2_2__answers) -> lcrs_6_2_4__swept_by ans (aerror ans) = aerror ans :: aresponses ans
lcrs_6_2_4__error_sweeps_every_answer ans = rewrite lcyc_1_1__nat_eq_refl (aerror ans) in Refl

-- ---------------------------------------------------------------------
-- The per-call gate [LCRS.8.2], [RLOW.4.6.6.1], [RLOW.4.6.6.6]
-- ---------------------------------------------------------------------

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| The gate's `true` applied: the site's key is stamped with the instant.
export
lcrs_8_2__allow_admits : (window, now : Nat) -> (key : (Nat, Nat, Nat)) -> (trk : Rlow_4_6_6_1__trackers) ->
                         rlow_4_6_2_2__allows window now (rlow_4_6_6_1__lookup trk key) = True ->
                         lcrs_8_2__allow window now key trk = (True, (key, now) :: trk)
lcrs_8_2__allow_admits window now key trk h = rewrite h in Refl

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| The gate's `false` applied: nothing moves.
export
lcrs_8_2__allow_refuses : (window, now : Nat) -> (key : (Nat, Nat, Nat)) -> (trk : Rlow_4_6_6_1__trackers) ->
                          rlow_4_6_2_2__allows window now (rlow_4_6_6_1__lookup trk key) = False ->
                          lcrs_8_2__allow window now key trk = (False, trk)
lcrs_8_2__allow_refuses window now key trk h = rewrite h in Refl

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| A SITE WITH NO RECORDED ISSUE IS ADMITTED, and stamped: a call site that
||| has never issued the call for the key issues it.
export
lcrs_8_2__first_call_admitted : (window, now : Nat) -> (key : (Nat, Nat, Nat)) -> (trk : Rlow_4_6_6_1__trackers) ->
                                rlow_4_6_6_1__lookup trk key = Nothing ->
                                lcrs_8_2__allow window now key trk = (True, (key, now) :: trk)
lcrs_8_2__first_call_admitted window now key trk lk =
  lcrs_8_2__allow_admits window now key trk (cong (rlow_4_6_2_2__allows window now) lk)

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| THE WINDOW SUPPRESSES THE CALL: a site's key stamped at `c0` and an
||| instant inside the window, `c' < c0 + window`, is refused and the
||| trackers do not move -- "the same call site has issued the call within
||| `<dur>` for the same key".
export
lcrs_8_2__window_suppresses_call : (window, c0, c' : Nat) -> (key : (Nat, Nat, Nat)) -> (trk : Rlow_4_6_6_1__trackers) ->
                                   rlow_4_6_6_1__lookup trk key = Just c0 -> (c' < c0 + window) = True ->
                                   lcrs_8_2__allow window c' key trk = (False, trk)
lcrs_8_2__window_suppresses_call window c0 c' key trk lk lt =
  lcrs_8_2__allow_refuses window c' key trk (trans (cong (rlow_4_6_2_2__allows window c') lk) (cong not lt))

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| AT OR PAST THE BOUNDARY THE SITE ISSUES AGAIN, and is restamped: the
||| boundary itself included, as Rete/NetworkCooldown.idr's gate has it.
export
lcrs_8_2__refires_at_the_boundary_call : (window, c0, c' : Nat) -> (key : (Nat, Nat, Nat)) -> (trk : Rlow_4_6_6_1__trackers) ->
                                         rlow_4_6_6_1__lookup trk key = Just c0 -> (c' < c0 + window) = False ->
                                         lcrs_8_2__allow window c' key trk = (True, (key, c') :: trk)
lcrs_8_2__refires_at_the_boundary_call window c0 c' key trk lk lt =
  lcrs_8_2__allow_admits window c' key trk (trans (cong (rlow_4_6_2_2__allows window c') lk) (cong not lt))

--@derives [RLOW.4.6.6.6]
--@derives [LCRS.8.2]
||| `nocooldown` IS NO GATE: the site is admitted every time its rule fires,
||| the trackers untouched. A transcription, said so.
export
rlow_4_6_6_6__no_gate_admits : (r, n, c : Nat) -> (tok : Iret_7_1__token) -> (trk : Rlow_4_6_6_1__trackers) ->
                               lcrs_8_2__admit_gate Nothing r n c tok trk = (True, trk)
rlow_4_6_6_6__no_gate_admits r n c tok trk = Refl

--@derives [LCRS.8.2]
--@derives [LCRS.6.2.1]
--@derives [NCBK.6.9]
||| AN ADMITTED SITE SWEEPS, RECORDS AND STAMPS: with the gate's verdict
||| `true` and the trackers it leaves, the site's run on an accumulator is
||| the issue on its net, the stamps kept, the trackers the gate's, and the
||| call recorded after the ones before.
export
lcrs_8_2__site_admitted : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) ->
                          (r, n : Nat) -> (site : Lcrs_6_2_1__site) -> (tok : Iret_7_1__token) -> (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) ->
                          (trk, trk' : Rlow_4_6_6_1__trackers) -> (recs : List Ncbk_6_9__call_record) ->
                          lcrs_8_2__admit_gate (sgate site) r n (nclock cs) tok trk = (True, trk') ->
                          lcrs_8_2__call_site pg env corrOf ans r (n, site) tok (MkAcc cs st trk recs)
                            = MkAcc (lcrs_6_2_1__issue pg env corrOf ans site tok cs) st trk' (recs ++ [MkCallRecord r n (scorr site tok) (sargs site tok)])
lcrs_8_2__site_admitted pg env corrOf ans r n site tok cs st trk trk' recs h =
  cong (\d => lcrs_8_2__site_decided d pg env corrOf ans r n site tok (MkAcc cs st trk recs)) h

--@derives [LCRS.8.2]
--@derives [LCRS.6.2.1]
--@derives [RLOW.7.3.8]
||| A REFUSED SITE LEAVES THE NET, THE STAMPS AND THE RECORDS: with the
||| gate's verdict `false`, only the trackers are the gate's -- and the gate
||| moves none on a refusal.
export
lcrs_8_2__site_refused : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) ->
                         (r, n : Nat) -> (site : Lcrs_6_2_1__site) -> (tok : Iret_7_1__token) -> (cs : Iret_19_3__clocked_net) -> (st : Ltim_2_8_6__stamps) ->
                         (trk, trk' : Rlow_4_6_6_1__trackers) -> (recs : List Ncbk_6_9__call_record) ->
                         lcrs_8_2__admit_gate (sgate site) r n (nclock cs) tok trk = (False, trk') ->
                         lcrs_8_2__call_site pg env corrOf ans r (n, site) tok (MkAcc cs st trk recs) = MkAcc cs st trk' recs
lcrs_8_2__site_refused pg env corrOf ans r n site tok cs st trk trk' recs h =
  cong (\d => lcrs_8_2__site_decided d pg env corrOf ans r n site tok (MkAcc cs st trk recs)) h

--@derives [LCRS.6.2.1]
--@derives [LCRS.8.2]
--@derives [RLOW.7.3.8]
||| A CALL ITS COOLDOWN SUPPRESSES IS NOT ISSUED AND RETRACTS NOTHING: a
||| site with a window, its key stamped inside the window at the net's
||| clock, leaves the accumulator exactly as it was -- the net unswept, no
||| record, the trackers unmoved. The gate covers the sweep as it covers the
||| call ([RLOW.7.3.8]).
export
lcrs_6_2_1__suppressed_retracts_nothing : (pg : Lcyc_3_2_1__program) -> (env : Iret_7_6__env) -> (corrOf : Lcrs_4_3_2__corr_of) -> (ans : Lcrs_4_2_2__answers) ->
                                          (r, n : Nat) -> (site : Lcrs_6_2_1__site) -> (tok : Iret_7_1__token) -> (cs : Iret_19_3__clocked_net) ->
                                          (st : Ltim_2_8_6__stamps) -> (trk : Rlow_4_6_6_1__trackers) -> (recs : List Ncbk_6_9__call_record) ->
                                          (window, c0 : Nat) -> (kf : Iret_7_1__token -> Nat) ->
                                          sgate site = Just (window, kf) -> rlow_4_6_6_1__lookup trk (r, n, kf tok) = Just c0 ->
                                          (nclock cs < c0 + window) = True ->
                                          lcrs_8_2__call_site pg env corrOf ans r (n, site) tok (MkAcc cs st trk recs) = MkAcc cs st trk recs
lcrs_6_2_1__suppressed_retracts_nothing pg env corrOf ans r n site tok cs st trk recs window c0 kf sg lk lt =
  lcrs_8_2__site_refused pg env corrOf ans r n site tok cs st trk trk recs
    (trans (cong (\g => lcrs_8_2__admit_gate g r n (nclock cs) tok trk) sg)
           (lcrs_8_2__window_suppresses_call window c0 (nclock cs) (r, n, kf tok) trk lk lt))

-- ---------------------------------------------------------------------
-- Executed: the fixtures' shapes on this engine
-- ---------------------------------------------------------------------

--@spec [LCRS.6.2.1]
||| THE WITNESSES' KINDS: 0 the trigger (`logical`, a key and a mutable
||| slot, so a change under one key is a replace and a fresh match), 1 the
||| first service's response schema, 2 `CallError`, 3 the second service's
||| response schema -- the three `ttl`, so every answer is its own fact.
public export
lcrs_6_2_1__life : Nat -> Lscp_1_3__lifecycle
lcrs_6_2_1__life Z     = Entity
lcrs_6_2_1__life (S _) = Explicit

--@spec [LCRS.6.2.1]
||| The witnesses' correlations: `"c1"` and `"c2"`, as codepoints.
public export
lcrs_6_2_1__c1 : Lstr_1_1__text
lcrs_6_2_1__c1 = [99, 49]

--@spec [LCRS.6.2.1]
public export
lcrs_6_2_1__c2 : Lstr_1_1__text
lcrs_6_2_1__c2 = [99, 50]

--@spec [LCRS.6.2.1]
--@spec [LCRS.4.3.2]
||| THE WITNESSES' ENVIRONMENT: a response payload is `(corr, v)`, a
||| `CallError` payload `(corr, code, message, ts)`; 11 and 12 the replies
||| `"c1"` with v 1 and 2, 13 the error `"c1"`, 21 a reply `"c2"`, 30 and 31
||| the replies with the empty correlation, 33 the error with it; any other
||| id the one-slot tuple of the Int it is (the trigger's key and payload).
public export
lcrs_6_2_1__wenv : Iret_7_6__env
lcrs_6_2_1__wenv i =
  if i == 11 then Just [VStr lcrs_6_2_1__c1, VInt 1]
  else if i == 12 then Just [VStr lcrs_6_2_1__c1, VInt 2]
  else if i == 13 then Just [VStr lcrs_6_2_1__c1, VStr [], VStr [], VInt 0]
  else if i == 21 then Just [VStr lcrs_6_2_1__c2, VInt 1]
  else if i == 30 then Just [VStr [], VInt 1]
  else if i == 31 then Just [VStr [], VInt 2]
  else if i == 33 then Just [VStr [], VStr [], VStr [], VInt 0]
  else Just [VInt (cast i)]

--@spec [LCRS.6.2.1]
--@spec [LCRS.4.3.2]
--@spec [LCRS.4.2.1]
||| Where the witnesses' kinds keep `corr`: the three answer kinds at
||| payload slot 0; the trigger has none.
public export
lcrs_6_2_1__wcorr : Lcrs_4_3_2__corr_of
lcrs_6_2_1__wcorr 1 = Just (False, 0)
lcrs_6_2_1__wcorr 2 = Just (False, 0)
lcrs_6_2_1__wcorr 3 = Just (False, 0)
lcrs_6_2_1__wcorr _ = Nothing

--@spec [LCRS.6.2.1]
--@spec [LCRS.4.2.2]
||| The witnesses' answer kinds: the two response schemas and `CallError`.
public export
lcrs_6_2_1__wanswers : Lcrs_4_2_2__answers
lcrs_6_2_1__wanswers = MkAnswers [1, 3] 2

--@spec [LCRS.6.2.1]
--@spec [LCRS.3.1]
||| The correlation `"c1"` as every witness site's `as`.
public export
lcrs_6_2_1__corr_c1 : Iret_7_1__token -> Lstr_1_1__text
lcrs_6_2_1__corr_c1 _ = lcrs_6_2_1__c1

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
||| The witness sites' one argument, `n: t.k`: the trigger's key slot.
public export
lcrs_6_2_1__args_k : Iret_7_1__token -> List Lerr_1_4_1__result
lcrs_6_2_1__args_k tok = [iret_7_6__slot lcrs_6_2_1__wenv tok 0 True 0]

--@spec [LCRS.6.2.1]
--@spec [LCRS.8.2]
||| THE COOLED SITE: `call svc.read n: t.k cooldown: 10 as "c1"` on the
||| first service, keyed on the trigger's identity key ([LCDB.3.3.1]).
public export
lcrs_6_2_1__site_cooled : Lcrs_6_2_1__site
lcrs_6_2_1__site_cooled = MkSite 0 (Just (10, lcdb_3_3_1__key_of_head)) (Just 1) lcrs_6_2_1__corr_c1 lcrs_6_2_1__args_k

--@spec [LCRS.6.2.1]
--@spec [RLOW.4.6.6.6]
||| THE PLAIN SITE: the same call under `nocooldown`.
public export
lcrs_6_2_1__site_plain : Lcrs_6_2_1__site
lcrs_6_2_1__site_plain = MkSite 0 Nothing (Just 1) lcrs_6_2_1__corr_c1 lcrs_6_2_1__args_k

--@spec [LCRS.6.2.1]
--@spec [LCRS.17.1]
||| THE `no response` SITE: `call svc.ping n: t.k nocooldown as "c1"`.
public export
lcrs_6_2_1__site_ping : Lcrs_6_2_1__site
lcrs_6_2_1__site_ping = MkSite 0 Nothing Nothing lcrs_6_2_1__corr_c1 lcrs_6_2_1__args_k

--@spec [LCRS.6.2.1]
||| ONE RULE OVER THE TRIGGER, action-free: its RHS is the call alone.
public export
lcrs_6_2_1__rule_trig : List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
lcrs_6_2_1__rule_trig = [([(0, lcdb_3_2_1__any_join, False)], [])]

--@spec [LCRS.6.2.1]
||| The one rule's sites: one site.
public export
lcrs_6_2_1__sites_one : Lcrs_6_2_1__site -> List (List (Nat, Lcrs_6_2_1__site))
lcrs_6_2_1__sites_one site = [[(0, site)]]

--@spec [LCRS.6.2.1]
||| THE LOADED CALLED STATE of a program: no rows, no deadlines, the clock
||| at 0, the wall at 0, no stamps, no tracker of either kind.
public export
lcrs_6_2_1__loaded : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Lcrs_6_2_1__called_state
lcrs_6_2_1__loaded alphas rules = ((MkSampled (MkClockedNet (MkTmsNet (rdsc_4a_5__load alphas rules) []) [] 0) 0 [], []), [])

--@spec [LCRS.6.2.1]
||| THE RESULTS OF A SCHEDULE from the loaded network on the witnesses'
||| environment, kinds and answers: per pump, the verdicts and the calls.
public export
lcrs_6_2_1__results_of : (Nat -> Lscp_1_3__lifecycle) -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                         List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List (List (Nat, Lcrs_6_2_1__site)) ->
                         List Rarc_5_6_2__step -> List (List (Nat, Bool), List Ncbk_6_9__call_record)
lcrs_6_2_1__results_of life alphas rules sites steps =
  snd (lcrs_6_2_1__run_steps_called (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) lcdb_3_2_1__no_ttl [Nothing]
         lcrs_6_2_1__wenv lcrs_6_2_1__wcorr lcrs_6_2_1__wanswers sites [Nothing] steps (lcrs_6_2_1__loaded alphas rules))

--@spec [LCRS.6.2.1]
||| THE WORKING MEMORY after a schedule from the loaded network.
public export
lcrs_6_2_1__wm_after : (Nat -> Lscp_1_3__lifecycle) -> List (Nat, Lfac_1_7_1__fact -> Bool) ->
                       List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> List (List (Nat, Lcrs_6_2_1__site)) ->
                       List Rarc_5_6_2__step -> Rarc_5_6_4__wm
lcrs_6_2_1__wm_after life alphas rules sites steps =
  lcrs_6_2_1__wm (ltim_2_4_1__net_of (fst (fst (lcrs_6_2_1__run_steps_called (lcyc_3_2_1__program_of life (enet (rdsc_4a_5__load alphas rules))) lcdb_3_2_1__no_ttl [Nothing]
                                                  lcrs_6_2_1__wenv lcrs_6_2_1__wcorr lcrs_6_2_1__wanswers sites [Nothing] steps (lcrs_6_2_1__loaded alphas rules)))))

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
||| The record of the witness call: rule 0, site 0, `"c1"`, the trigger's
||| key 1.
public export
lcrs_6_2_1__rec_k1 : Ncbk_6_9__call_record
lcrs_6_2_1__rec_k1 = MkCallRecord 0 0 lcrs_6_2_1__c1 [RVal (VInt 1)]

--@derives [LCRS.6.2.1]
--@derives [RLOW.7.3.8]
--@derives [LCRS.8.2]
||| AN ISSUED CALL SUPERSEDES: the trigger fires the cooled call at 0; the
||| reply `"c1"` arrives; eleven units later the trigger changes under its
||| key, the rule fires, the gate admits past the window, and the call
||| retracts the live reply before it is issued --
||| logical/LCRS.6.2.1_admitted_call_supersedes's shape. Executed: three
||| pumps, the first and the third each one admitted firing with one call,
||| and no reply live after.
export
lcrs_6_2_1__admitted_call_supersedes :
  ( lcrs_6_2_1__results_of lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 11), SInput (Data (Assert 0 1 5)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([], []), ([(0, True)], [lcrs_6_2_1__rec_k1])]
  , lcrs_6_2_1__wm_after lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 11), SInput (Data (Assert 0 1 5)), SPumpT 3]
      = [MkFact 2 0 1 5] )
lcrs_6_2_1__admitted_call_supersedes = (Refl, Refl)

--@derives [LCRS.6.2.1]
--@derives [LCRS.8.2]
--@derives [RLOW.7.3.8]
||| A SUPPRESSED CALL RETRACTS NOTHING: the same, five units later -- inside
||| the window the rule fires, the gate refuses the site, no call is
||| recorded and the reply stays live
||| (logical/LCRS.6.2.1_cooldown_suppressed_retracts_nothing's shape).
export
lcrs_6_2_1__cooldown_suppressed_retracts_nothing :
  ( lcrs_6_2_1__results_of lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 1 5)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([], []), ([(0, True)], [])]
  , lcrs_6_2_1__wm_after lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 1 5)), SPumpT 3]
      = [MkFact 1 1 1 11, MkFact 2 0 1 5] )
lcrs_6_2_1__cooldown_suppressed_retracts_nothing = (Refl, Refl)

--@derives [LCRS.8.2]
--@derives [RLOW.4.6.6.1]
||| THE SITE'S BOUNDARY IS INCLUSIVE: suppressed at 5, the site issues at
||| exactly 10, and the call then sweeps the reply.
export
lcrs_8_2__site_refires_at_the_boundary :
  ( lcrs_6_2_1__results_of lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 1 5)), SPumpT 3,
       SInput (Tick 10), SInput (Data (Assert 0 1 6)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([], []), ([(0, True)], []), ([(0, True)], [lcrs_6_2_1__rec_k1])]
  , lcrs_6_2_1__wm_after lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_cooled)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SPumpT 3, SInput (Tick 5), SInput (Data (Assert 0 1 5)), SPumpT 3,
       SInput (Tick 10), SInput (Data (Assert 0 1 6)), SPumpT 3]
      = [MkFact 0 0 1 6] )
lcrs_8_2__site_refires_at_the_boundary = (Refl, Refl)

--@derives [LCRS.17.1]
--@derives [LCRS.6.2.1]
||| A `no response` CALL SWEEPS THE `CallError` ALONE: the trigger fires the
||| ping at 0; a `CallError` `"c1"` arrives; the trigger changes and the
||| rule fires again, and the issue retracts the error
||| (logical/LCRS.6.2.1_no_response_sweeps_error_only's shape).
export
lcrs_17_1__no_response_sweeps_error_only :
  ( lcrs_6_2_1__results_of lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_ping)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 2 1 13)), SPumpT 3, SInput (Data (Assert 0 1 1)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([], []), ([(0, True)], [lcrs_6_2_1__rec_k1])]
  , lcrs_6_2_1__wm_after lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_ping)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 2 1 13)), SPumpT 3, SInput (Data (Assert 0 1 1)), SPumpT 3]
      = [MkFact 2 0 1 1] )
lcrs_17_1__no_response_sweeps_error_only = (Refl, Refl)

--@derives [LCRS.6.2.1]
--@derives [LCRS.6.2.4]
||| THE OTHER SERVICE'S REPLY SURVIVES: a reply of each service arrives with
||| `"c1"` and both are live, the second's arrival sweeping its own kind
||| alone; the trigger changes, the call to the first service is issued, and
||| it retracts its own service's reply and leaves the other's
||| (logical/LCRS.6.2.1_other_service_reply_survives's shape).
export
lcrs_6_2_1__other_service_reply_survives :
  ( lcrs_6_2_1__results_of lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_plain)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SInput (Data (Assert 3 1 11)), SPumpT 3, SInput (Data (Assert 0 1 1)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([], []), ([(0, True)], [lcrs_6_2_1__rec_k1])]
  , lcrs_6_2_1__wm_after lcrs_6_2_1__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_plain)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SInput (Data (Assert 3 1 11)), SPumpT 3, SInput (Data (Assert 0 1 1)), SPumpT 3]
      = [MkFact 2 3 1 11, MkFact 3 0 1 1] )
lcrs_6_2_1__other_service_reply_survives = (Refl, Refl)

--@spec [LCRS.6.2.4]
||| The arrival shapes' lifecycle: every kind explicit -- the `Job` of the
||| refire shapes is explicit, and every answer is.
public export
lcrs_6_2_4__life : Nat -> Lscp_1_3__lifecycle
lcrs_6_2_4__life _ = Explicit

--@spec [LCRS.6.2.1]
--@spec [NCBK.6.9]
||| The record of the second Job's call: its key 2.
public export
lcrs_6_2_1__rec_k2 : Ncbk_6_9__call_record
lcrs_6_2_1__rec_k2 = MkCallRecord 0 0 lcrs_6_2_1__c1 [RVal (VInt 2)]

--@derives [LCRS.6.2.4]
--@derives [LCRS.6.2.1]
||| A CALL FIRING TWICE BEFORE EITHER REQUEST IS ANSWERED FINDS NOTHING TO
||| RETRACT, AND THE LAST REPLY WINS: two Jobs, two calls `"c1"` each
||| recorded with its Job's key; then reply 1 and reply 2 arrive, and the
||| arriving 2 retracts 1 before it enters
||| (logical/LCRS.6.2.4_refire_pending_last_reply_wins's shape).
export
lcrs_6_2_4__refire_pending_last_reply_wins :
  ( lcrs_6_2_1__results_of lcrs_6_2_4__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_plain)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 0 2 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SInput (Data (Assert 1 1 12)), SPumpT 3]
      = [([(0, True)], [lcrs_6_2_1__rec_k1]), ([(0, True)], [lcrs_6_2_1__rec_k2]), ([], [])]
  , lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_plain)
      [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 0 2 0)), SPumpT 3, SInput (Data (Assert 1 1 11)), SInput (Data (Assert 1 1 12)), SPumpT 3]
      = [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 1 12] )
lcrs_6_2_4__refire_pending_last_reply_wins = (Refl, Refl)

--@derives [LCRS.6.2.4]
--@derives [NCBK.6.3]
||| THE REPLIES OUT OF ORDER: reply 2 then reply 1, and the one asserted last
||| stays, whichever request it answered
||| (logical/LCRS.6.2.4_refire_pending_out_of_order's shape).
export
lcrs_6_2_4__refire_pending_out_of_order :
  lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one lcrs_6_2_1__rule_trig (lcrs_6_2_1__sites_one lcrs_6_2_1__site_plain)
    [SInput (Data (Assert 0 1 0)), SPumpT 3, SInput (Data (Assert 0 2 0)), SPumpT 3, SInput (Data (Assert 1 1 12)), SInput (Data (Assert 1 1 11)), SPumpT 3]
    = [MkFact 0 0 1 0, MkFact 1 0 2 0, MkFact 2 1 1 11]
lcrs_6_2_4__refire_pending_out_of_order = Refl

--@derives [LCRS.6.2.4]
--@derives [LCRS.4.2.1]
||| AN ERROR AFTER A RESPONSE: the reply `"c1"` is live when the `CallError`
||| `"c1"` arrives, and the error alone is live after
||| (logical/LCRS.6.2.4_error_after_response's shape).
export
lcrs_6_2_4__error_after_response :
  lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] [] [SInput (Data (Assert 1 1 11)), SInput (Data (Assert 2 1 13)), SPumpT 3]
    = [MkFact 0 2 1 13]
lcrs_6_2_4__error_after_response = Refl

--@derives [LCRS.6.2.4]
||| A RESPONSE AFTER AN ERROR: the `CallError` `"c1"` is live when the reply
||| `"c1"` arrives, and the reply alone is live after
||| (logical/LCRS.6.2.4_response_after_error's shape).
export
lcrs_6_2_4__response_after_error :
  lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] [] [SInput (Data (Assert 2 1 13)), SInput (Data (Assert 1 1 11)), SPumpT 3]
    = [MkFact 0 1 1 11]
lcrs_6_2_4__response_after_error = Refl

--@derives [LCRS.6.2.4]
--@derives [LCRS.4.2.1]
||| AN ERROR SPANS SERVICES: replies of both services are live with `"c1"`
||| when the `CallError` `"c1"` arrives, and both go
||| (logical/LCRS.6.2.4_error_spans_services's shape).
export
lcrs_6_2_4__error_spans_services :
  lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] []
    [SInput (Data (Assert 1 1 11)), SInput (Data (Assert 3 1 11)), SInput (Data (Assert 2 1 13)), SPumpT 3]
    = [MkFact 0 2 1 13]
lcrs_6_2_4__error_spans_services = Refl

--@derives [LCRS.6.2.4]
--@derives [LCRS.6.2.1]
||| THE OTHER SERVICE IS UNTOUCHED BY A RESPONSE: a reply of each service
||| with `"c1"`, both live; a second reply of the first service with `"c1"`
||| retracts the first service's and leaves the other's
||| (logical/LCRS.6.2.4_other_service_untouched's shape, and one reply more).
export
lcrs_6_2_4__other_service_untouched :
  ( lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] [] [SInput (Data (Assert 1 1 11)), SInput (Data (Assert 3 1 11)), SPumpT 3]
      = [MkFact 0 1 1 11, MkFact 1 3 1 11]
  , lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] []
      [SInput (Data (Assert 1 1 11)), SInput (Data (Assert 3 1 11)), SInput (Data (Assert 1 1 12)), SPumpT 3]
      = [MkFact 1 3 1 11, MkFact 0 1 1 12] )
lcrs_6_2_4__other_service_untouched = (Refl, Refl)

--@derives [LCRS.6.2.4]
--@derives [LRST.1.2]
||| THE EMPTY CORRELATION RETRACTS NOTHING ON ARRIVAL: two replies and a
||| `CallError` with `corr` `""`, all three live after
||| (logical/LCRS.6.2.4_empty_corr_retracts_nothing's shape; [LCRS.6.2.4]).
export
lcrs_6_2_4__empty_corr_retracts_nothing :
  lcrs_6_2_1__wm_after lcrs_6_2_4__life lcdb_3_2_1__alphas_one [] []
    [SInput (Data (Assert 1 1 30)), SInput (Data (Assert 1 1 31)), SInput (Data (Assert 2 1 33)), SPumpT 3]
    = [MkFact 0 1 1 30, MkFact 1 1 1 31, MkFact 2 2 1 33]
lcrs_6_2_4__empty_corr_retracts_nothing = Refl

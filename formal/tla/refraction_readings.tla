---------------------------- MODULE refraction_readings ----------------------------
(***************************************************************************)
(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors        *)
(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later              *)
(*                                                                         *)
(* REFRACTION, STATED FIVE WAYS, RUN AS FIVE READINGS (TLA+ / TLC).        *)
(* The corpus says what                                                     *)
(* refraction is in five places and the tick-free models cannot tell them   *)
(* apart, because in that fragment a fired token comes back to the gate     *)
(* only through a working-memory change. This module drives one abstract   *)
(* engine over recorded streams that DO include pump boundaries, clock      *)
(* ticks with a time-dependent condition, a NOT node blocked and released   *)
(* both across and WITHIN a pump, no-op and meaningful reasserts, a         *)
(* retraction of the matched fact and of an unrelated one, an unrelated     *)
(* assert, and a hash collision -- and pins, for every reading and every    *)
(* stream, the observable firing sequence. Where two readings differ, the   *)
(* cell is the distinguishing trace; where they agree on every stream, the  *)
(* table says so.                                                          *)
(*                                                                         *)
(* THE CLAUSE IS THE FLAG READING, column "own" below. [IRET.11.3],        *)
(* [IRET.11.3.2], [IRET.8.2] and [LTIM.2.5.1] state it: an identity's       *)
(* refraction is cleared only when its activation is re-created; neither a  *)
(* pump boundary nor a tick nor an unrelated assert or retract clears it;   *)
(* edge-once follows. A time-dependent condition that goes false ENDS the   *)
(* match and its activation ([LTIM.2.5.1], [IRET.19.5]): no memory of the   *)
(* firing outlives it, and the condition going true again makes a new       *)
(* activation, unfired. That is the match ending, not the tick clearing: a  *)
(* tick that leaves the condition true leaves the flag. [IRET.11.3.2]'s     *)
(* list of what re-creates an activation names the closing, "ended by a     *)
(* time-dependent test that went false"; the model follows all three. The   *)
(* other columns are readings the clause refuses, and one, "pump_oneshot",  *)
(* is libds: it agrees with "own" on every stream but one -- the hash       *)
(* collision, where a set keyed by the hash alone cross-suppresses (the key *)
(* `[IRET.11.3.3]` refuses under every capability setting). Its one-shot    *)
(* ends with the match as the flag does: a gate that shuts and reopens      *)
(* fires again under both (`ldet_5_3__libds_fires_each_opening`).           *)
(*                                                                         *)
(* THE FIVE STATEMENTS AND THE READING EACH BECOMES.                        *)
(*                                                                         *)
(*   "pump"          "a refraction model which resets each pump", read as   *)
(*                   the whole mechanism. A per-terminal set keyed by token *)
(*                   identity, valid for the current pump only.             *)
(*   "pump_oneshot"  libds. The table in rete/terminal.c: entries carry the *)
(*                   engine's cycle generation, which advances on EVERY     *)
(*                   working-memory assert and retract (wm_rete.c, both     *)
(*                   paths; a no-op reassert returns before it) and once    *)
(*                   more per pump (`ds_rete_bump_cycle`), so an entry is   *)
(*                   stale after any change. Plus the REACT1g one-shot for  *)
(*                   a time-dependent rule -- a per-terminal set of matched  *)
(*                   fact ids that persists across pumps and is cleared     *)
(*                   when that fact leaves working memory (`[LTIM.2.5.2]`)  *)
(*                   and when its condition closes (`[LTIM.2.5.1]`: the     *)
(*                   match has ended, and the mark goes with it).           *)
(*   "anywm"         `[IRET.11.3.2]` read literally: the set is cleared     *)
(*                   when ANY fact is asserted or retracted -- also by a     *)
(*                   change to a fact the token never matched. The tick is  *)
(*                   not a working-memory fact (`[LDET.5.8]`) and clears    *)
(*                   nothing.                                               *)
(*   "own"           `[IDAT.6.2.2]`, `[IRET.11]`'s header and `[LDET.5.3]`: *)
(*                   refraction is the `fired` flag of the activation, held *)
(*                   "until the LHS changes" -- the token is re-asserted     *)
(*                   under a new wrapper, retracted, blocked and released,  *)
(*                   or its time-dependent condition goes false and true    *)
(*                   again; each re-creates the activation unfired. Nothing *)
(*                   else clears it; a tick that leaves the condition true  *)
(*                   does not.                                              *)
(*   "runentry"      `[IRET.8.2]`: the set is reset "at ds_rete_run entry    *)
(*                   when the agenda was empty", and an identity is cleared *)
(*                   "on re-activation (same token, after the fact that     *)
(*                   caused it changed)".                                   *)
(*                                                                         *)
(* and, orthogonally, the IDENTITY the set is keyed by: the fact-id tuple  *)
(* with the hash as a pre-filter (`[IRET.11.3]`, `[IRET.11.3.3]`), or the   *)
(* hash alone, the key `[IRET.11.3.3]` refuses: no capability setting may   *)
(* select it, since a setting never changes a result (`[LDET.1.12]`). The   *)
(* "own" reading keeps no set and so has no identity to collide.            *)
(*                                                                         *)
(* THE ENGINE. One rule over a fact A with two keys, a `no B` pattern that   *)
(* blocks every A token while B is present (`[IRET.7.9.2]`) and releases   *)
(* them, under their ORIGINAL creation timetags, when B goes                *)
(* (`[IRET.7.9.3]`, `[LDET.5.9]`), and, in the timed streams, a              *)
(* time-dependent condition that holds exactly on the clocks in the         *)
(* stream's window (`[LTIM.2.4.1]`). A pump is a boundary followed by one   *)
(* or more drains: the boundary advances the pump number (and, for a tick,  *)
(* the clock) and, for a timed rule, re-drives every live unblocked token   *)
(* to the gate as the `__ClockTick__` join does (`[LTIM.2.4.2]`); the       *)
(* synthetic tick is invisible to the identity (`[LDET.5.8]`). A drain      *)
(* runs the agenda in timetag order (`[LDET.5.5]`): an activation at the    *)
(* gate is dropped if its condition is false, dropped if the reading        *)
(* suppresses it, and fired otherwise, marking whatever the reading marks   *)
(* (`[IRET.11.3.1]`). A condition that is false has ended the match         *)
(* (`[LTIM.2.5.1]`): under the flag readings the flag goes with the         *)
(* activation. Two drains with a working-memory change between them and no  *)
(* boundary are one pump in which an RHS emitted and withdrew a fact -- the *)
(* case `[LDET.5.3]`'s "until its LHS changes" is decided on.               *)
(*                                                                         *)
(* WHERE THE CLOSING IS SEEN. A condition is re-evaluated once per pump, on *)
(* the clocks as sampled when the pump began (`[LTIM.2.4.2]`,               *)
(* `[LTIM.2.4.3]`), and an edge is a change between two such samples. Here  *)
(* that evaluation is the gate's, at the drain that follows a boundary, and *)
(* every stream follows each boundary with a drain. A boundary that no      *)
(* drain followed would be a pump that re-evaluates nothing, where the      *)
(* clause's pump re-evaluates as it begins: no stream has one, and a        *)
(* closing in it would go unseen. `edge_once_firing.tla` evaluates where    *)
(* the clause does.                                                         *)
(*                                                                         *)
(* THE TABLE. A cell is the fired sequence as key@pump.                     *)
(*                                                                         *)
(*   stream           pump         pump_oneshot  anywm      own      runentry *)
(*   boundary         1@1          1@1           1@1        1@1      1@1      *)
(*   tick_reeval      1@2 1@3 1@4  1@2           1@2 1@4    1@2      1@2      *)
(*   tick_edge_twice  1@2 1@3      1@2 1@6       1@2        1@2 1@6  1@2 1@6  *)
(*                    1@6 1@7                                                *)
(*   cross_release    1@1 1@2 2@2  same          same       same     same     *)
(*   same_pump_rel    1@1          1@1 1@1       1@1 1@1    1@1 1@1  1@1 1@1  *)
(*   rev_release      2@1 1@1      same          same       same     same     *)
(*   reassert         1@1 1@3      same          same       same     same     *)
(*   unrelated        1@1          1@1           1@1        1@1      1@1      *)
(*   retract          2@1 1@2      same          same       same     same     *)
(*   tick_retract     1@2 2@2      1@2 2@2       1@2 2@2    1@2 2@2  1@2 2@2  *)
(*                    1@3                        1@3                          *)
(*   collision/tuple  1@1 2@1      same          same       same     same     *)
(*   collision/hash   1@1          1@1           1@1        1@1 2@1  1@1      *)
(*                                                                         *)
(* WHAT SEPARATES THE READINGS, pair by pair.                                *)
(*   pump / everything else: `same_pump_rel` -- a token fired, blocked by an *)
(*     RHS emit and released by a later RHS withdraw in the SAME pump is    *)
(*     refused by the per-pump set and fired by the other four. `[LDET.5.3]` *)
(*     says "until its LHS changes", and a NOT condition that changed twice *)
(*     is an LHS change; `[IDAT.6.2.2]` says the same. libds fires it: the  *)
(*     block and the release each advance its generation.                  *)
(*   pump / pump_oneshot: the timed streams -- the per-pump set alone fires  *)
(*     a time-dependent rule on every tick while its condition holds; the   *)
(*     one-shot is what stops libds doing so, once per opening.             *)
(*   anywm / own: `tick_edge_twice` -- the gate opens at clock 2, shuts at  *)
(*     4 and opens again at 6. The clause fires at each opening, 1@2 1@6:   *)
(*     "a reopening is a new edge" (`[LTIM.2.5.1]`), and libds's one-shot   *)
(*     ends with the closing and fires the second opening too. The literal  *)
(*     `[IRET.11.3.2]` set sees no working-memory change and keeps its      *)
(*     entry: it ends on 1@2.                                               *)
(*   anywm / own: `tick_reeval` -- an unrelated working-memory change       *)
(*     between two ticks clears the literal `[IRET.11.3.2]` set, so the     *)
(*     still-true time-dependent rule fires AGAIN on the next tick with no  *)
(*     change to the fact it matched, against `[LTIM.2.5.1]` and            *)
(*     `[LTIM.2.5.2]`. The flag reading does not. `tick_retract` is the     *)
(*     same with a RETRACT for the change -- key 2's fact goes, which key   *)
(*     1's token never matched. `[IRET.11.3.2]` names both: "not an         *)
(*     unrelated assert or retract".                                        *)
(*   every reading, on `retract`: a token retracted while its activation    *)
(*     waits takes the activation with it (`[IRET.8.1]`), so key 1 does     *)
(*     not fire in pump 1; asserted again it is a new wrapper and fires     *)
(*     (`[LTIM.2.5.2]`).                                                    *)
(*   own / runentry: NO stream separates them, and none can in this          *)
(*     fragment: a fired token returns to the gate only by re-activation    *)
(*     (which `[IRET.8.2]` clears, as the flag reading does) or by the tick *)
(*     re-drive, which precedes run entry and so leaves the agenda          *)
(*     non-empty exactly when the reset would matter. The reset-when-empty  *)
(*     sentence is unobservable. A gate that shuts and opens again is a     *)
(*     re-activation with no fact changed, which `[IRET.8.2]`'s parenthesis *)
(*     does not name ([IRET.11.3.2] now does); both readings clear on it.   *)
(*   pump_oneshot / own: `collision/hash`, the hash-alone key, alone.       *)
(*     Everywhere else libds is the flag reading: the per-change generation *)
(*     leaves its set nothing to suppress that the flag would not, and its  *)
(*     one-shot ends where the flag does.                                   *)
(*   tuple / hash: `collision` -- every set-keyed reading cross-suppresses  *)
(*     a distinct token on a hash collision; the flag reading cannot,       *)
(*     because it keys nothing.                                             *)
(*                                                                         *)
(* NORMATIVE COMPANION. Same traceability discipline as the other .tla     *)
(* models, machine-checked by the spec gate's crossref: every operator /    *)
(* VARIABLE is named <lowercased-clause-id>__<Tag>, and the tag line above  *)
(* it repeats the clause so the checker confirms the id exists and matches. *)
(* `edge_once_firing.tla` is the model of once per match, seen from one     *)
(* time-dependent fact over every truth history, with libds's one-shot as   *)
(* an engine it excludes; `refraction_identity.als` is the model of the     *)
(* identity key; this module is the one that runs the readings against      *)
(* each other.                                                              *)
(*                                                                         *)
(* ONE WINDOW, THREE MODELS. `tick_edge_twice`'s                            *)
(* window {2, 3, 6, 7} is pinned to two firings in three models: 1@2 1@6    *)
(* here under "own"; [0, 1, 0, 0, 0, 1, 0] over ticks 1 to 7 on the clocked  *)
(* network, formal/idris/Rete/NetworkClocked.idr's                          *)
(* `ltim_2_5_1__window_2367_clocked`; and open, shut, open, two firings,     *)
(* returned by edge_once_firing.tla's `.probe.refires`, whose clock is       *)
(* abstract. The conformance fixture LTIM.2.5.1_window_reopens.json is the  *)
(* runtimes' instance (`dwell` in [2 s, 4 s) or at least 6 s, pumped at 0,   *)
(* 2, 4, 6 s). This paragraph is what a reader compares.                    *)
(*                                                                         *)
(* TEETH. Every cell is an equality TLC checks once the stream is consumed, *)
(* so a wrong cell fails with the actual sequence in the violating state.   *)
(* Make `iret_7_9_3__release` leave `fired` alone under "own" and the       *)
(* `same_pump_rel` column of "own" collapses onto "pump"; make the tick     *)
(* clear `fired` under "anywm" and its `tick_reeval` cell gains 1@3; stop   *)
(* `iret_11_3_2__gen` advancing on a working-memory change and the          *)
(* `same_pump_rel` column of "pump_oneshot" collapses onto "pump". Make a   *)
(* retract leave `pending` alone and `retract` gains 1@1 in every column.   *)
(* Make a release mint new timetags, in key order, and `rev_release` fires  *)
(* 1@1 before 2@1 in every column, and `released_fires_in_stamp_order`      *)
(* fails on it: the two fire in the order of the minted timetags, not of    *)
(* the timetags their matches first completed with. Make a condition that   *)
(* goes false leave `fired` as it was, and the one-shot with it, and        *)
(* `tick_edge_twice` loses its 1@6 under "own", "runentry" and              *)
(* "pump_oneshot".                                                          *)
(*                                                                         *)
(* EVERY EVENT IS IN A STREAM. scripts/formal/check_tla.py fails             *)
(* a model with a definition nothing reaches; `retract` and `tick_retract` *)
(* are the streams that reach `iret_8_1__ret`.                              *)
(*                                                                         *)
(* ONE STREAM MINTS KEY 2 FIRST, so that                                    *)
(* an engine that drains by key, and one that mints new timetags on a       *)
(* release in key order, are told from this one by a cell and by            *)
(* `released_fires_in_stamp_order`. `rev_release` mints key 2 first,        *)
(* blocks both tokens, releases them and drains: 2@1 then 1@1 under every   *)
(* reading, and 1@1 first under either of those engines.                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences

\* @spec [LDET.5.3]
\* Which engine this run is of. "clause" is the engine the table was worked
\* from, and refraction_readings.cfg runs it. The others are the six engines
\* of the header's TEETH paragraph, each of which gets a cell of the table
\* wrong: the paragraph is six sentences, and each
\* `.teeth.` config beside this module is the run of one, which
\* scripts/formal/check_tla.py requires to end in a violation of `table_holds`.
\*   "release_keeps_fired"    a release leaves the `fired` flag as it was
\*   "tick_clears"            under "anywm" a tick clears every flag
\*   "gen_stuck"              the generation advances at a boundary and at
\*                            no working-memory change
\*   "retract_keeps_pending"  a retract leaves the activation waiting
\*   "release_remints"        a release mints a new timetag for every live
\*                            token, in key order
\*   "closing_keeps_fired"    a time-dependent condition that goes false
\*                            leaves the `fired` flag, and libds's one-shot,
\*                            as they were: the memory of the firing outlives
\*                            the match
CONSTANT ldet_5_3__ENGINE

\* @spec [LDET.5.3]
\* The five readings of the suppression rule.
ldet_5_3__Readings == {"pump", "pump_oneshot", "anywm", "own", "runentry"}

\* @spec [IRET.11.3]
\* What the set is keyed by: the fact-id tuple (hash as pre-filter), or the
\* hash alone, the key [IRET.11.3.3] refuses under every capability setting.
iret_11_3__Identities == {"tuple", "hash"}

\* @spec [IRET.8.1]
\* Two keys of A, hence at most two live tokens, each its own activation.
iret_8_1__Keys == {1, 2}

\* @spec [LFAC.2.5.3]
\* A meaningful change to A under key k: a fresh wrapper (retract + assert
\* underneath), a fresh token with a fresh creation timetag.
lfac_2_5_3__chg(k) == [op |-> "chg", key |-> k]

\* @spec [LFAC.2.5.1]
\* A no-op reassert of A under key k: suppressed in working memory, mints
\* nothing, changes nothing.
lfac_2_5_1__noop(k) == [op |-> "noop", key |-> k]

\* @spec [IRET.8.1]
\* A retracts under key k: its activation leaves the agenda with it.
iret_8_1__ret(k) == [op |-> "ret", key |-> k]

\* @spec [IRET.7.9.2]
\* B is asserted: the NOT node blocks every A token and retracts the
\* downstream tokens, so every pending activation is withdrawn.
iret_7_9_2__block == [op |-> "block", key |-> 0]

\* @spec [IRET.7.9.3]
\* B is retracted: every blocked token is released downstream, re-activated
\* under the timetag it first completed with.
iret_7_9_3__release == [op |-> "release", key |-> 0]

\* @spec [IRET.11.3.2]
\* An unrelated working-memory change: a fact no token of this rule matches
\* is asserted. The reading that clears on any assert or retract clears here;
\* [IRET.11.3.2] says nothing of the kind clears an identity.
iret_11_3_2__chgC == [op |-> "chgC", key |-> 0]

\* @spec [LTIM.2.4.2]
\* A clock tick: the clock advances by one and a new pump begins.
ltim_2_4_2__tick == [op |-> "tick", key |-> 0]

\* @spec [LTIM.2.5.1]
\* A pump boundary with no clock change: the cycle the per-pump set resets on.
\* A pump boundary clears no refraction ([IRET.11.3], [IRET.11.3.2]).
ltim_2_5_1__newpump == [op |-> "newpump", key |-> 0]

\* @spec [IRET.11.3.1]
\* A drain: the agenda runs to exhaustion in timetag order, each activation
\* filtered at selection time by the reading.
iret_11_3_1__drain == [op |-> "drain", key |-> 0]

\* @spec [LDET.5.3]
\* The recorded streams. `timed` gives the rule a time-dependent condition
\* that holds exactly on the clocks in `window`; `collide` gives the two
\* tokens one hash.
ldet_5_3__Scenarios ==
    [ boundary        |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               ltim_2_5_1__newpump, iret_11_3_1__drain,
                               ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      tick_reeval     |-> [timed |-> TRUE, window |-> 2 .. 9, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               iret_11_3_2__chgC,
                               ltim_2_4_2__tick, iret_11_3_1__drain >>],
      tick_edge_twice |-> [timed |-> TRUE, window |-> {2, 3, 6, 7}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain >>],
      cross_release   |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               iret_7_9_2__block, lfac_2_5_3__chg(2), iret_7_9_3__release,
                               ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      same_pump_rel   |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               iret_7_9_2__block, iret_7_9_3__release, iret_11_3_1__drain >>],
      rev_release     |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(2), lfac_2_5_3__chg(1),
                               iret_7_9_2__block, iret_7_9_3__release,
                               ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      reassert        |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               lfac_2_5_1__noop(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      unrelated       |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain,
                               iret_11_3_2__chgC, ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      retract         |-> [timed |-> FALSE, window |-> {}, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), lfac_2_5_3__chg(2), iret_8_1__ret(1),
                               ltim_2_5_1__newpump, iret_11_3_1__drain,
                               lfac_2_5_3__chg(1), ltim_2_5_1__newpump, iret_11_3_1__drain >>],
      tick_retract    |-> [timed |-> TRUE, window |-> 2 .. 9, collide |-> FALSE, stream |->
                            << lfac_2_5_3__chg(1), lfac_2_5_3__chg(2),
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               ltim_2_4_2__tick, iret_11_3_1__drain,
                               iret_8_1__ret(2),
                               ltim_2_4_2__tick, iret_11_3_1__drain >>],
      collision       |-> [timed |-> FALSE, window |-> {}, collide |-> TRUE, stream |->
                            << lfac_2_5_3__chg(1), lfac_2_5_3__chg(2),
                               ltim_2_5_1__newpump, iret_11_3_1__drain >>] ]

\* @spec [LDET.5.3]
\* THE TABLE, as data: what each reading fires on each stream, as <<key,
\* pump>>. Checked, not asserted -- `table_holds` compares it with what the
\* engine produced once the stream is consumed.
ldet_5_3__expected(r, i, s) ==
    CASE s = "boundary" -> << <<1, 1>> >>
      [] s = "tick_reeval" ->
          (CASE r = "pump"         -> << <<1, 2>>, <<1, 3>>, <<1, 4>> >>
             [] r = "pump_oneshot" -> << <<1, 2>> >>
             [] r = "anywm"        -> << <<1, 2>>, <<1, 4>> >>
             [] r = "own"          -> << <<1, 2>> >>
             [] r = "runentry"     -> << <<1, 2>> >>)
      [] s = "tick_edge_twice" ->
          (CASE r = "pump"                                -> << <<1, 2>>, <<1, 3>>, <<1, 6>>, <<1, 7>> >>
             [] r \in {"own", "runentry", "pump_oneshot"} -> << <<1, 2>>, <<1, 6>> >>
             [] r = "anywm"                               -> << <<1, 2>> >>)
      [] s = "cross_release" -> << <<1, 1>>, <<1, 2>>, <<2, 2>> >>
      [] s = "same_pump_rel" ->
          (CASE r = "pump" -> << <<1, 1>> >>
             [] r # "pump" -> << <<1, 1>>, <<1, 1>> >>)
      [] s = "rev_release" -> << <<2, 1>>, <<1, 1>> >>
      [] s = "reassert" -> << <<1, 1>>, <<1, 3>> >>
      [] s = "unrelated" -> << <<1, 1>> >>
      [] s = "retract" -> << <<2, 1>>, <<1, 2>> >>
      [] s = "tick_retract" ->
          (CASE r \in {"pump", "anywm"}    -> << <<1, 2>>, <<2, 2>>, <<1, 3>> >>
             [] r \notin {"pump", "anywm"} -> << <<1, 2>>, <<2, 2>> >>)
      [] s = "collision" ->
          (CASE i = "tuple"            -> << <<1, 1>>, <<2, 1>> >>
             [] i = "hash" /\ r = "own" -> << <<1, 1>>, <<2, 1>> >>
             [] i = "hash" /\ r # "own" -> << <<1, 1>> >>)

\* @spec [IRET.8.1]
\* A token of A under one key: whether it is live, its wrapper id and
\* creation timetag, the timetag its match FIRST completed with (`completed`:
\* the one [LDET.5.9] says it fires under; `stamp` and `completed` part only
\* in an engine that mints a timetag on release), whether its activation
\* waits at the gate, the `fired` flag (the "own" / "anywm" / "runentry"
\* state), the scope it last fired in (the pump for "pump", libds's
\* generation for "pump_oneshot"), the wrapper the one-shot latched, and its
\* hash class.
iret_8_1__fresh(h) ==
    [present |-> FALSE, wrapper |-> 0, stamp |-> 0, completed |-> 0,
     pending |-> FALSE, fired |-> FALSE, genFired |-> 0, oneshot |-> 0, hashc |-> h]

\* @spec [LDET.5.3]
\* The reading under test. Chosen at Init, fixed thereafter.
VARIABLE ldet_5_3__reading

\* @spec [IRET.11.3]
\* The identity the set is keyed by. Chosen at Init; "hash" only on the
\* collision stream, where alone it can matter.
VARIABLE iret_11_3__identity

\* @spec [LDET.5.3]
\* The stream under test. Chosen at Init.
VARIABLE ldet_5_3__scenario

\* @spec [LDET.5.3]
\* The index of the next stream event.
VARIABLE ldet_5_3__pc

\* @spec [LTIM.2.4.2]
\* The engine clock.
VARIABLE ltim_2_4_2__clock

\* @spec [LTIM.2.5.1]
\* The pump number: the cycle generation the per-pump set is valid for.
VARIABLE ltim_2_5_1__pumpNo

\* @spec [IRET.11.3.2]
\* libds's refraction cycle generation: advanced by every working-memory
\* assert and retract -- a meaningful change, a retract, B's assert and
\* retract, an unrelated assert -- and by every pump boundary. A no-op
\* reassert and a drain leave it alone. The scope of the "pump_oneshot" set.
VARIABLE iret_11_3_2__gen

\* @spec [IRET.7.9.2]
\* Whether B is present, blocking every A token at the NOT node.
VARIABLE iret_7_9_2__blocker

\* @spec [LDET.5.5]
\* The next creation timetag: monotone, assigned when a match completes.
VARIABLE ldet_5_5__nextStamp

\* @spec [LFAC.2.5.3]
\* The next fact wrapper id.
VARIABLE lfac_2_5_3__nextWrapper

\* @spec [IRET.8.1]
\* The per-key token state.
VARIABLE iret_8_1__tok

\* @spec [LDET.5.3]
\* The observable: the fired sequence, <<key, pump>> per firing, in order.
VARIABLE ldet_5_3__fired

\* @spec [LDET.5.9]
\* The second history: per firing, in the order of `ldet_5_3__fired`, the
\* timetag the firing token's match FIRST completed with. What
\* `released_fires_in_stamp_order` reads, so that a release which minted a
\* new timetag is seen for what it did, which the live `stamp` cannot show.
VARIABLE ldet_5_9__completedAt

\* @spec [LDET.5.3]
ldet_5_3__vars ==
    << ldet_5_3__reading, iret_11_3__identity, ldet_5_3__scenario, ldet_5_3__pc,
       ltim_2_4_2__clock, ltim_2_5_1__pumpNo, iret_11_3_2__gen, iret_7_9_2__blocker,
       ldet_5_5__nextStamp, lfac_2_5_3__nextWrapper, iret_8_1__tok, ldet_5_3__fired,
       ldet_5_9__completedAt >>

\* @spec [LDET.5.3]
ldet_5_3__TypeOK ==
    /\ ldet_5_3__reading \in ldet_5_3__Readings
    /\ iret_11_3__identity \in iret_11_3__Identities
    /\ ldet_5_3__scenario \in DOMAIN ldet_5_3__Scenarios
    /\ ldet_5_3__pc \in 1 .. 20
    /\ ltim_2_4_2__clock \in 0 .. 12
    /\ ltim_2_5_1__pumpNo \in 0 .. 12
    /\ iret_11_3_2__gen \in 0 .. 20
    /\ iret_7_9_2__blocker \in BOOLEAN
    /\ ldet_5_5__nextStamp \in 1 .. 8
    /\ lfac_2_5_3__nextWrapper \in 1 .. 8
    /\ \A k \in iret_8_1__Keys : iret_8_1__tok[k].completed \in 0 .. 8
    /\ Len(ldet_5_9__completedAt) = Len(ldet_5_3__fired)
    /\ \A n \in 1 .. Len(ldet_5_9__completedAt) : ldet_5_9__completedAt[n] \in 1 .. 8
    /\ ldet_5_3__ENGINE \in { "clause", "release_keeps_fired", "tick_clears",
                              "gen_stuck", "retract_keeps_pending",
                              "release_remints", "closing_keeps_fired" }

\* @spec [LDET.5.3]
\* Every reading, every stream; the identity is free only where it matters.
ldet_5_3__Init ==
    /\ ldet_5_3__reading \in ldet_5_3__Readings
    /\ ldet_5_3__scenario \in DOMAIN ldet_5_3__Scenarios
    /\ iret_11_3__identity \in
         (IF ldet_5_3__Scenarios[ldet_5_3__scenario].collide
            THEN iret_11_3__Identities ELSE {"tuple"})
    /\ ldet_5_3__pc = 1
    /\ ltim_2_4_2__clock = 0
    /\ ltim_2_5_1__pumpNo = 0
    /\ iret_11_3_2__gen = 0
    /\ iret_7_9_2__blocker = FALSE
    /\ ldet_5_5__nextStamp = 1
    /\ lfac_2_5_3__nextWrapper = 1
    /\ iret_8_1__tok =
         [k \in iret_8_1__Keys |->
            iret_8_1__fresh(IF k = 1 \/ ldet_5_3__Scenarios[ldet_5_3__scenario].collide
                              THEN 1 ELSE 2)]
    /\ ldet_5_3__fired = << >>
    /\ ldet_5_9__completedAt = << >>

\* @spec [IRET.11.3.1]
\* Whether the reading suppresses key k's activation at the gate. The
\* set-keyed readings ask whether this identity fired in the current scope --
\* the pump for "pump", libds's generation for "pump_oneshot" -- (and, for
\* libds, whether the one-shot latched this wrapper of a timed rule); the
\* flag readings ask the flag. Under the hash identity a set-keyed reading
\* also suppresses when the OTHER live token shares the hash and is marked
\* in the same scope -- the cross-suppression [IRET.11.3.3] names; the flag
\* reading keeps no set and cannot collide.
iret_11_3_1__suppressed(tok, k, r, i, scope, timed) ==
    LET t == tok[k]
        j == IF k = 1 THEN 2 ELSE 1
        o == tok[j]
        sameHash == i = "hash" /\ o.present /\ o.hashc = t.hashc
        selfPump == t.genFired = scope
                    \/ (r = "pump_oneshot" /\ timed /\ t.oneshot = t.wrapper)
        collPump == sameHash /\ o.genFired = scope
        collFlag == sameHash /\ o.fired
    IN  CASE r \in {"pump", "pump_oneshot"} -> selfPump \/ collPump
          [] r \in {"anywm", "runentry"}    -> t.fired \/ collFlag
          [] r = "own"                      -> t.fired

\* @spec [IRET.11.3.1] [LTIM.2.4.1]
\* One activation at the gate. Not pending: nothing. Condition false: dropped
\* without a firing (the maturity guard is pre-evaluated), and the match has
\* ended, so under the flag readings the `fired` flag goes with the activation,
\* and under libds's the one-shot does ([LTIM.2.5.1]), so a reopening finds it
\* unfired (`ended`). The per-pump set and the literal one keep what they hold,
\* which is what the clause refuses in them. Suppressed: dropped. Otherwise it
\* fires and is marked in every representation at once -- each reading reads
\* only its own.
iret_11_3_1__gate(tok, k, r, i, scope, clock, timed, window) ==
    LET t == tok[k]
        spent == [tok EXCEPT ![k].pending = FALSE]
        ended == IF ldet_5_3__ENGINE = "closing_keeps_fired" THEN spent
                 ELSE IF r \in {"own", "runentry"} THEN [spent EXCEPT ![k].fired = FALSE]
                 ELSE IF r = "pump_oneshot" THEN [spent EXCEPT ![k].oneshot = 0]
                 ELSE spent
    IN  IF ~t.pending THEN [tok |-> tok, fire |-> FALSE]
        ELSE IF timed /\ clock \notin window THEN [tok |-> ended, fire |-> FALSE]
        ELSE IF iret_11_3_1__suppressed(tok, k, r, i, scope, timed)
          THEN [tok |-> spent, fire |-> FALSE]
        ELSE [tok |-> [spent EXCEPT ![k].fired = TRUE, ![k].genFired = scope,
                                    ![k].oneshot = IF timed THEN t.wrapper ELSE @],
              fire |-> TRUE]

\* @spec [LDET.5.3]
\* Consume the next event. A change mints a wrapper and a timetag and puts
\* the token at the gate unless B blocks it; a retract removes the token;
\* block withdraws every activation; release re-activates every live token
\* under its own timetag; the unrelated change touches no token; a boundary
\* advances the pump (and the clock, for a tick) and re-drives a timed rule's
\* live unblocked tokens; a drain runs the two keys in timetag order and
\* records, per firing, the timetag the firing's match first completed with
\* (`ldet_5_9__completedAt`); no event but a change writes `completed`, so a
\* release that mints a timetag moves `stamp` and leaves it. What each event
\* does to the suppression state is the reading:
\*   anywm    -- every working-memory change (chg, ret, block, release, chgC)
\*               clears every flag; a boundary clears nothing.
\*   own      -- a release re-creates the activation unfired; a new wrapper is
\*               a new token; a timed condition found false at the gate has
\*               ended the match, and the flag goes with it; nothing else
\*               clears.
\*   runentry -- as own, plus: a boundary whose agenda is empty after the tick
\*               re-drive clears every flag.
\*   pump     -- the pump number is the scope; the boundary is the reset.
\*   pump_oneshot -- libds's generation is the scope; every working-memory
\*               change and every boundary is a reset. The one-shot is
\*               cleared with its wrapper, and when its condition closes.
ldet_5_3__Step ==
    LET sc  == ldet_5_3__Scenarios[ldet_5_3__scenario]
        ev  == sc.stream[ldet_5_3__pc]
        r   == ldet_5_3__reading
        i   == iret_11_3__identity
        tok == iret_8_1__tok
        clearAll(f) == [k \in iret_8_1__Keys |-> [f[k] EXCEPT !.fired = FALSE]]
        wmClear(f) == IF r = "anywm" THEN clearAll(f) ELSE f
        anyPending(f) == \E k \in iret_8_1__Keys : f[k].pending
        \* the token function after the event, before any drain
        tokE ==
          CASE ev.op = "chg" ->
                 wmClear([tok EXCEPT ![ev.key] =
                            [present |-> TRUE, wrapper |-> lfac_2_5_3__nextWrapper,
                             stamp |-> ldet_5_5__nextStamp, completed |-> ldet_5_5__nextStamp,
                             pending |-> ~iret_7_9_2__blocker,
                             fired |-> FALSE, genFired |-> 0, oneshot |-> 0, hashc |-> @.hashc]])
            [] ev.op = "noop" -> tok
            [] ev.op = "ret" ->
                 wmClear([tok EXCEPT ![ev.key] =
                            [@ EXCEPT !.present = FALSE, !.completed = 0,
                                      !.pending = IF ldet_5_3__ENGINE = "retract_keeps_pending"
                                                    THEN @ ELSE FALSE,
                                      !.fired = FALSE, !.genFired = 0, !.oneshot = 0]])
            [] ev.op = "block" ->
                 wmClear([k \in iret_8_1__Keys |-> [tok[k] EXCEPT !.pending = FALSE]])
            [] ev.op = "release" ->
                 LET minted(k) == ldet_5_5__nextStamp
                                    + (IF k = 2 /\ tok[1].present THEN 1 ELSE 0)
                     rel == [k \in iret_8_1__Keys |->
                               [tok[k] EXCEPT !.pending = @ \/ tok[k].present,
                                              !.fired = IF /\ ldet_5_3__ENGINE # "release_keeps_fired"
                                                           /\ r \in {"own", "runentry"}
                                                           /\ tok[k].present
                                                          THEN FALSE ELSE @,
                                              !.stamp = IF /\ ldet_5_3__ENGINE = "release_remints"
                                                           /\ tok[k].present
                                                          THEN minted(k) ELSE @]]
                 IN wmClear(rel)
            [] ev.op = "chgC" -> wmClear(tok)
            [] ev.op \in {"tick", "newpump"} ->
                 LET driven == [k \in iret_8_1__Keys |->
                                  [tok[k] EXCEPT !.pending =
                                     @ \/ (sc.timed /\ tok[k].present /\ ~iret_7_9_2__blocker)]]
                 IN IF r = "runentry" /\ ~anyPending(driven) THEN clearAll(driven)
                    ELSE IF /\ ldet_5_3__ENGINE = "tick_clears"
                            /\ r = "anywm"
                            /\ ev.op = "tick"
                      THEN clearAll(driven)
                    ELSE driven
            [] ev.op = "drain" -> tok
        pumpE == IF ev.op \in {"tick", "newpump"} THEN ltim_2_5_1__pumpNo + 1 ELSE ltim_2_5_1__pumpNo
        clockE == IF ev.op = "tick" THEN ltim_2_4_2__clock + 1 ELSE ltim_2_4_2__clock
        genE == IF ev.op \in (IF ldet_5_3__ENGINE = "gen_stuck"
                                THEN {"tick", "newpump"}
                                ELSE {"chg", "ret", "block", "release", "chgC", "tick", "newpump"})
                  THEN iret_11_3_2__gen + 1 ELSE iret_11_3_2__gen
        scopeE == IF r = "pump_oneshot" THEN genE ELSE pumpE
        \* a drain gates the two keys in timetag order
        first == IF tokE[1].stamp <= tokE[2].stamp THEN 1 ELSE 2
        second == IF first = 1 THEN 2 ELSE 1
        g1 == iret_11_3_1__gate(tokE, first, r, i, scopeE, clockE, sc.timed, sc.window)
        g2 == iret_11_3_1__gate(g1.tok, second, r, i, scopeE, clockE, sc.timed, sc.window)
        fires == (IF g1.fire THEN << <<first, pumpE>> >> ELSE << >>)
                 \o (IF g2.fire THEN << <<second, pumpE>> >> ELSE << >>)
        \* beside each firing, the timetag its match first completed with
        completedAts == (IF g1.fire THEN << tokE[first].completed >> ELSE << >>)
                        \o (IF g2.fire THEN << tokE[second].completed >> ELSE << >>)
    IN  /\ ldet_5_3__pc <= Len(sc.stream)
        /\ ldet_5_3__pc' = ldet_5_3__pc + 1
        /\ ltim_2_5_1__pumpNo' = pumpE
        /\ iret_11_3_2__gen' = genE
        /\ ltim_2_4_2__clock' = clockE
        /\ iret_7_9_2__blocker' =
             CASE ev.op = "block" -> TRUE
               [] ev.op = "release" -> FALSE
               [] ev.op \notin {"block", "release"} -> iret_7_9_2__blocker
        /\ lfac_2_5_3__nextWrapper' =
             IF ev.op = "chg" THEN lfac_2_5_3__nextWrapper + 1 ELSE lfac_2_5_3__nextWrapper
        /\ ldet_5_5__nextStamp' =
             IF ev.op = "chg" THEN ldet_5_5__nextStamp + 1
             ELSE IF ev.op = "release" /\ ldet_5_3__ENGINE = "release_remints"
               THEN ldet_5_5__nextStamp + (IF tok[1].present THEN 1 ELSE 0)
                                        + (IF tok[2].present THEN 1 ELSE 0)
             ELSE ldet_5_5__nextStamp
        /\ iret_8_1__tok' = IF ev.op = "drain" THEN g2.tok ELSE tokE
        /\ ldet_5_3__fired' = IF ev.op = "drain" THEN ldet_5_3__fired \o fires ELSE ldet_5_3__fired
        /\ ldet_5_9__completedAt' =
             IF ev.op = "drain" THEN ldet_5_9__completedAt \o completedAts ELSE ldet_5_9__completedAt
        /\ UNCHANGED << ldet_5_3__reading, iret_11_3__identity, ldet_5_3__scenario >>

\* @spec [LDET.5.3]
\* The stream is consumed: an explicit terminal stutter, not a deadlock.
ldet_5_3__Done ==
    /\ ldet_5_3__pc > Len(ldet_5_3__Scenarios[ldet_5_3__scenario].stream)
    /\ UNCHANGED ldet_5_3__vars

\* @spec [LDET.5.3]
ldet_5_3__Next == ldet_5_3__Step \/ ldet_5_3__Done

\* @spec [LDET.5.3]
\* Safety only: every run is finite and deterministic.
ldet_5_3__Spec == ldet_5_3__Init /\ [][ldet_5_3__Next]_ldet_5_3__vars

\* @derives [LDET.5.3]
\* THE TABLE HOLDS: once the stream is consumed, the fired sequence is the
\* cell the header states for this reading, identity and stream. NO
\* counterexample.
ldet_5_3__table_holds ==
    ldet_5_3__pc > Len(ldet_5_3__Scenarios[ldet_5_3__scenario].stream)
      => ldet_5_3__fired = ldet_5_3__expected(ldet_5_3__reading, iret_11_3__identity,
                                              ldet_5_3__scenario)

\* @derives [LDET.5.3]
\* LIBDS FIRES EACH OPENING: on the stream whose gate opens, shuts and opens
\* again, the libds reading's cell is the clause's, 1@2 1@6 -- its one-shot
\* ends with the closing as the flag does ([LTIM.2.5.1]), so the second
\* opening fires. One cell of the table, held on its own so that it carries
\* its own verdict: the engine that keeps the one-shot past the
\* closing breaks it (refraction_readings.teeth.oneshot_outlives.cfg). NO
\* counterexample.
ldet_5_3__libds_fires_each_opening ==
    ( /\ ldet_5_3__pc > Len(ldet_5_3__Scenarios[ldet_5_3__scenario].stream)
      /\ ldet_5_3__scenario = "tick_edge_twice"
      /\ ldet_5_3__reading = "pump_oneshot" )
      => ldet_5_3__fired = << <<1, 2>>, <<1, 6>> >>

\* @spec [LDET.5.9]
\* RELEASE KEEPS ITS PLACE: whenever two tokens fire in one drain, the one
\* whose match FIRST COMPLETED earlier fires first -- "it fires in the
\* position its original timetag gives it". NO counterexample.
\*
\* It reads `ldet_5_9__completedAt`, the history of the timetag each firing's
\* match first completed with, and not the live `stamp` the drain orders by.
\* On the clause's engine the two are one, since a release mints nothing; on
\* an engine that mints a timetag on release they part, and the firing order
\* is then the minted order and not this one. `rev_release` is the stream
\* that shows it: key 2 completes first, both are blocked and released, and
\* the "release_remints" engine fires key 1 first
\* (refraction_readings.teeth.remint_order.cfg). The `rev_release` cell of the
\* table pins it too.
\*
\* TAGGED `spec`: the clause's observable, stated once over the history.
ldet_5_9__released_fires_in_stamp_order ==
    \A n \in 1 .. Len(ldet_5_3__fired) :
      \A m \in 1 .. Len(ldet_5_3__fired) :
        ( /\ n < m
          /\ ldet_5_3__fired[n][2] = ldet_5_3__fired[m][2]
          /\ ldet_5_3__fired[n][1] # ldet_5_3__fired[m][1] )
          => ldet_5_9__completedAt[n] < ldet_5_9__completedAt[m]

\* PROBES. `table_holds` is of the form "once the stream is
\* consumed, ...", and holds of a model in which none ever is.
\* `released_fires_in_stamp_order` is of the form "whenever two tokens fire in
\* one drain, ...", and what it is tied for is a token the NOT node RELEASED.
\* Each definition below says one of these never happens; its `.probe.` config
\* runs THIS engine, with the constant of refraction_readings.cfg, and
\* scripts/formal/check_tla.py requires TLC to end in a violation.

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: no stream is ever consumed. The run that
\* breaks it reaches the state in which a cell of the table is compared.
probe__no_stream_is_consumed ==
    ldet_5_3__pc <= Len(ldet_5_3__Scenarios[ldet_5_3__scenario].stream)

\* @probe
\* NOT A PROPERTY OF THE CLAUSE: on the stream in which B blocks and releases
\* across a pump, no two tokens fire in one pump. The run that breaks it is the
\* released token firing beside a match that completed while it was blocked:
\* the case the stamp order is about.
probe__a_released_token_fires_alone ==
    ~( /\ ldet_5_3__scenario = "cross_release"
       /\ \E n, m \in 1 .. Len(ldet_5_3__fired) :
            /\ n < m
            /\ ldet_5_3__fired[n][2] = ldet_5_3__fired[m][2]
            /\ ldet_5_3__fired[n][1] # ldet_5_3__fired[m][1] )

=============================================================================

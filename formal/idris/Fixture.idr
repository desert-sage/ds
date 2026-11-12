-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| THE FIXTURE RUNNER. NOT A MODEL MODULE: like Main.idr it carries no
||| `--@spec` tags and is exempted from the clause-tie scanners by name
||| (the crossref's exempt list). It reads a lowered fixture (written by
||| the fixture lowering, private tooling), builds the loaded network
||| of Rete/Network.idr with the dependency table of Rete/NetworkTms.idr
||| and the deadline table and clock of Rete/NetworkTtl.idr, the rate
||| trackers of Rete/NetworkCooldown.idr and the wall sample and entry
||| stamps of Rete/NetworkTwoClocks.idr beside them, runs the fixture's
||| steps on Rete/NetworkTimed.idr's engine -- a tick through
||| `ltim_2_8_4__tick_timed` (the clock takes the sample, the sweep runs), a
||| data event through `ltim_2_8_6__input_timed` (swept for, applied and
||| stamped at the held sample), a pump through `ltim_2_4_2__pump_timed`
||| (every timed chain re-evaluated at the held sample over the stamps,
||| then the traced gated pump with each firing's RHS under the rate gate
||| and every mint stamped) -- and prints after every step what the model
||| holds. With no rule timed the pump IS Rete/NetworkCooldown.idr's gated
||| pump (`ltim_2_4_1__no_timed_rule_is_the_gated_pump`), and with no rule
||| cooled that IS `iret_11_4__run_ttl_net_traced`
||| (`lcdb_3_2_1__no_cooldown_is_the_plain_pump`), the calls
||| `rarc_5_6_2__run_steps_ttl_net` composes and
||| `iret_11_4__run_ttl_net_traced_core` projects, so what is printed is
||| the proved machine's. A fixture with no TTL schema and no tick runs on
||| the same engine with an empty deadline table and a clock that never
||| moves: the sweep before each input then expires nothing, and the
||| output is the engine with truth maintenance's.
|||
||| INPUT, one record per line, whitespace-separated, `#` lines ignored:
|||   schema  <kind> <explicit|relation|entity> <name>
|||   ttl     <kind> <ns>                    (the schema's default TTL [IRET.4.2];
|||                                           a kind with no record has none)
|||   synthetic <kind>                       (a compiler-owned kind: an `after`
|||                                           clause's timer, [LTAC.3.2]. Its facts
|||                                           are on no stream and under no fact id
|||                                           in the engine ([RFCS.6a.5]), so this
|||                                           runner prints neither them nor their
|||                                           ids in a `fired` line -- [NCBK.2.6]'s
|||                                           factless follow-up firing -- and the
|||                                           `count` leaves them out; the engine
|||                                           holds them and the firings' effects
|||                                           read them. AFTER TIMERS below)
|||   alpha   <index> <kind>                 (in index order, from 0)
|||   rule    <ordinal> <name>               (in ordinal order, from 0)
|||   pattern <ordinal> <alpha-index> <0|1>  (1: a `no` pattern; in rule order)
|||   emit    <ordinal> <kind> <key> <pay>   (in rule order; two value codes)
|||   withdraw <ordinal> <rank>              (`withdraw r`, [LSCP.2.1.1]: the explicit
|||                                           fact bound at that rank among the rule's
|||                                           positive patterns leaves working memory;
|||                                           Rete/FireLoop.idr's `Withdraw`, in action
|||                                           order with the `emit` records)
|||   emitx   <ordinal> <kind> <nkey> <npay> <expr...>
|||           an emit whose slots are computed: nkey key expressions then
|||           npay payload expressions over the bound facts (the `where`
|||           grammar below, `slot` ranking the positive patterns); each tuple
|||           is evaluated over the fired facts and CODED, and a tuple with a
|||           trap or a NaN in it gets id 0, which no tuple's code is (in
|||           rule order with the `emit` records)
|||   log     <ordinal> <index> <nsites> <expr...>
|||           a `log` action's interpolation sites, <index> counting the
|||           rule's logs from 0 in source order: nsites expressions over the
|||           bound facts (the `where` grammar, `slot` ranking the positive
|||           patterns). The literal text between the sites stays with the
|||           harness; the runner renders nothing.
|||   cool    <ordinal> <window> <n> <expr...>
|||           the rule's `cooldown` ([LCDB.3.2.1]): its window in the
|||           input's clock units (an exact number of them, the lowering's
|||           time map taking every window into its unit), then n key
|||           expressions over the bound facts (the `where` grammar) -- the
|||           activation key, [LCDB.3.3.3]'s composition or the `by:` paths
|||           of [LCDB.3.3.4], 0 for the empty key. The tuple is evaluated
|||           over the fired facts and CODED when the rule fires, so the key
|||           compared is [RLOW.4.6.2.1]'s identity (THE VALUE CODE below);
|||           a slot read never traps, so the trap id is unreachable here.
|||           A rule with no record has no cooldown.
|||   answer  <kind> <response|error> <key|pay> <i>
|||           an ANSWER KIND (CALLS below): a service's response schema or
|||           `CallError`, and where it keeps its `corr` -- the slot's role
|||           and its index among the slots of that role ([LCRS.4.3.2],
|||           [LCRS.4.2.1]). At most one `error` record; a kind is one or the
|||           other.
|||   callsite <ordinal> <site> <position> <service> <window|none> <kind|none> <n> <expr...> <m> <expr...> <expr>
|||           a CALL SITE of the rule at <ordinal> (CALLS below): <site> its
|||           index among the rule's calls, <position> the number of the
|||           rule's emits and withdraws before it, <service> the service's
|||           dotted name, its `cooldown` window in clock units or `none`
|||           under `nocooldown`, its response kind or `none` for a `no
|||           response` service, n key expressions (the activation key,
|||           [LCRS.8.2], evaluated and CODED as a `cool` record's is), m
|||           argument expressions (one per kwarg the call supplies or the
|||           service defaults, in declaration order), and last the
|||           correlation, a `lit s:<token>` ([LCRS.3.1]'s `as`): anything
|||           else there is refused (a computed `as` is outside the fragment).
|||   where   <ordinal> <pattern-index> <expr...>
|||           the pattern's test, prefix: `slot <binding> <key|pay> <i>`,
|||           `lit <v>` with v one of i:<int>, f:<bits> (a Float, by the
|||           bits of its binary64), s:<token>, b:0 / b:1 or n (null), two
|||           operands after eq ne lt le gt ge add sub mul div floordiv mod
|||           and or coalesce (`x ?? d`, `d` evaluated only on a null `x`,
|||           [LNUL.8.9]), one after not neg, and one after `is <subject>` or
|||           `isnot <subject>` with the subject one of null true false inf
|||           neginf nan int float bool string bytes json ([LNUL.4.9]'s
|||           twelve; `isnot` is the one operator `is not`), and one after
|||           `cast <int|float|bool|string> <0|1>`: `e :: T` with 0, `e :: T?`
|||           with 1 ([LCST.4.2]; a null operand under 1 is null, [LCST.4.3.4];
|||           `Float :: Int` outside Int is a trap, [LCST.4.5.4]; `String ::
|||           Int?` and `String :: Bool?` the parses of [LCST.4.5.7] and
|||           [LCST.4.5.5], a value or null; `Int :: String` and `Bool ::
|||           String` the renders of [LCST.4.5.6]). `slen <e>` is `len` of a
|||           String, its codepoint count ([LSTR.2.1]); `len <e>` stays an
|||           array's. An all-Int
|||           zero divisor under div, floordiv or mod is a trap
|||           ([LEXP.7.15.1]); a null operand is null first ([LNUL.9.3]).
|||           A path into a `Json` value is `path <n> <seg>... <e>`, n
|||           segments `k:<token>` (a member, by its key's string token) or
|||           `i:<index>` (an array element) and then the root expression,
|||           read by Rete/Eval.idr's `lnul_8_4__path` ([LNUL.8.4]: an
|||           unresolved path is null); `has <n> <seg>... <e>` is the
|||           absence test ([LEXP.6.1]) and `len <e>` an array's length
|||           ([LEXP.6.2]). <pattern-index> counts
|||           the rule's patterns from 0; <binding> ranks the positive
|||           patterns before it, the candidate last.
|||   json    <token> <tree>
|||           a `Json` document the fixture's slots hold, by the token its
|||           canonical text has in the lowering's string table (the one a
|||           value code of tag 3 carries, THE VALUE CODE below): the tree in
|||           prefix form -- `null`, `b:0` / `b:1`, `i:<int>`, `f:<bits>`,
|||           `s:<token>` (a string leaf, by its token), `arr <n> <tree>...`
|||           and `obj <n> (<key-token> <tree>)...`. The runner folds every
|||           float zero to `+0.0` ([LGRA.5.8.8]), refuses an object that
|||           names a key twice ([LGRA.5.8.7]) and a document whose root is
|||           `null` ([LNUL.3.4]: that is the canonical null, which the
|||           lowering spells `n`, never a document).
|||   string  <token> <n> <codepoint>...
|||           the TEXT a String token stands for ([LSTR.1.1]): n codepoints,
|||           each a decimal natural the runner refuses unless [LSTR.1.1]
|||           admits it (`lstr_1_1__admissible`). The lowering writes one for
|||           every token of its table when the fixture reads a String's text
|||           -- an ordering, `len`, a cast to or from String -- and none
|||           otherwise (THE STRING TABLE below). The records precede the
|||           rules, so a `lit s:<token>` and a `json` record's string leaf
|||           resolve as they are read.
|||   step    assert <label> <kind> <key> <pay>   (two value codes)
|||   step    retract <label>
|||   step    tick <clock_ns>                (the clock's new value, never lower)
|||   step    wall <utc_ns>                  (the wall sample's new value, any:
|||                                           [NTST.3.1]'s wall set, or the wall
|||                                           half of an advance, after its tick)
|||   step    pump
|||
||| THE VALUE CODE. A key or a payload is the natural the engine compares;
||| what it stands for is the slot tuple it CODES. The code of a tuple is the
||| decimal numeral `1` followed by one block of twenty-one digits per slot,
||| first slot first -- the empty tuple is 1, and no tuple's code is 0. A
||| block is eight times a payload plus a tag: 0 for null (payload 0); 1 for
||| a Bool (payload 0 or 1); 2 for an Int, its ZigZag as the payload (2n for
||| n >= 0, -2n-1 below); 3 for a String, its token in the lowering's string
||| table as the payload -- or for a `Json` document, the token of its
||| canonical text, in a part of the table no String reaches (the lowering
||| keys it under a character [LSTR.1.1] admits in no String), so a
||| `json` record of this input says which tokens are documents; 4 for a
||| Float, the bits of its IEEE binary64 as the
||| payload, with `-0.0` coded as `+0.0` -- identity on a Float slot is IEEE
||| `==` ([LFAC.2.5.1]), under which the two zeros are one -- and a NaN
||| coded by nothing, since one never enters working memory ([LEXP.4.2]). A
||| 64-bit Int's ZigZag and a binary64's bits are below 2^64, so every block
||| is below the base and the code is injective: one tuple, one natural, and
||| the engine's equality of ids is [LFAC.2.5.1]'s exact equality of slot
||| values -- a document's canonical text being the quotient of its deep
||| structural equality (keys sorted, every float zero `+0.0`, an integer
||| and a float distinct), which the lowering's own test holds it to.
||| `valueDecodeWith` the input's tables is the environment every `where`
||| reads through (Rete/Eval.idr's `Iret_7_6__env`): a tag-3 token with a
||| `json` record decodes to its tree, any other to a String whose text is
||| the token's (THE STRING TABLE). `valueCodeWith` the same tables is what
||| an `emitx` tuple becomes: a document copied whole into an emitted slot
||| is coded by the token of the equal tree (deep equality,
||| `lfac_2_5_1__json_eq`), a String by the token of its text, and one no
||| table holds -- a sub-document a path read, a text a render computed,
||| neither of which the lowering admits into an emit -- gets the trap id.
||| The lowering codes the asserted facts and the literal emits with the
||| same arithmetic. The bits of a Float are read and written by two Chez
||| bytevector procedures (`doubleBits`, `bitsDouble` below): a foreign call
||| of the runner's, glue and not a model element.
|||
||| THE STRING TABLE. A String value of the model is its text
||| (Rete/Eval.idr, `Lstr_1_1__text`); the code carries a token. The
||| `string` records of the input are the table between them, written by
||| the lowering for every token it minted whenever the fixture reads a
||| text -- an ordering on two Strings, `len` of one, a cast to or from
||| String -- so that every token the facts, the literals and the
||| documents' string leaves carry has a text. An input with no `string`
||| record is one whose rules compare Strings for equality alone: there a token
||| stands for the OPAQUE text `[1114112 + token]`, one codepoint above
||| [LSTR.1.1]'s range, which no String can hold, so distinct tokens are
||| distinct texts and equal tokens one text, exactly the comparison the
||| engine made of the token. Such a text is never ordered, counted or
||| parsed: the lowering that writes no records admits no operation that
||| would. `textOfToken` and `tokenOfText` below are the two directions.
|||
||| RUN, NOT PROVED, and said so: the code is Integer arithmetic, and Idris
||| reasons about a primitive `div` or `mod` only on literals, so the round
||| trip `valueDecode (valueCode vs) = Just vs` is not a theorem here, and a
||| structural decoder on a natural of 2^66 is a hang, not a reference. It
||| is a worked
||| example in Main.idr on the values that matter (the Int extremes, a
||| negative, a tuple of every kind, the two non-codes 0 and a stray block),
||| and every run checks it in the only way that counts: the ids this runner
||| decodes were coded by the lowering, and the ids the lowering codes from
||| libds's facts are compared with the ones this runner's emits computed.
|||
||| OUTPUT, one record per line:
|||   step <n> assert <label> | step <n> retract <label> | step <n> tick <clock_ns> | step <n> wall <utc_ns> | step <n> pump
|||   fired <ordinal> <rule-name> <fact-ids...>   (per pump, in firing order; a firing
|||                                                the rate gate refused prints its line
|||                                                too -- it is the match's firing,
|||                                                [RDSC.4a.8.2.3], libds's
|||                                                RULE_FIRE_BEGIN -- followed by:)
|||   gated <ordinal>                              (the gate refused the firing's actions,
|||                                                [LCDB.3.2.1.1]: no effect follows and
|||                                                nothing but the `fired` flag moved)
|||   call <ordinal> <site> <service> <corr> <v...>  (after its firing's `fired` line and
|||                                                before its effects, one per call the
|||                                                firing ISSUED, in action order: the
|||                                                site, its service, the correlation as
|||                                                a `value` token and the arguments'
|||                                                values over the fired facts, as
|||                                                `value` spells them, `trap` for one
|||                                                that trapped -- [NCBK.6.9]'s record.
|||                                                A site its own gate refused prints
|||                                                nothing: it issued no call and swept
|||                                                nothing, [LCRS.8.2]. CALLS below)
|||   effect <ordinal> <index> <v...>              (after its firing's `fired` line, one
|||                                                per `log` of the rule in index order,
|||                                                up to the first whose sites trap:
|||                                                the values the sites took over the
|||                                                fired facts, as `value` spells them.
|||                                                A trap abandons the activation at
|||                                                the action it occurs in, the actions
|||                                                before it standing and those after
|||                                                it not running -- [LNUL.11.1]'s
|||                                                prefix rule, [LERR.1.4] -- so a
|||                                                log whose site traps prints no
|||                                                effect, and neither does any log
|||                                                after it; the firing's `fired` line
|||                                                stands, as libds's RULE_FIRE_BEGIN
|||                                                does. An emit's trap is the id 0
|||                                                above, a divergence by design;
|||                                                where a trapping emit and a log
|||                                                interleave, the prefix across the
|||                                                two is not modelled here.)
|||   halt quiescent | halt fuelout               (per pump)
|||   fact <id> <kind> <key> <pay>                (working memory after the step, in its order,
|||                                                the facts of a synthetic kind left out)
|||   count <n>                                   (of the facts printed)
||| Exit 0 on a complete run; 2 on an input the runner cannot read.
|||
||| IDS. The model mints the smallest natural not live; the reference
||| engine's counter never reuses one ([IRET.4.4]). They agree until the
||| first retraction; compare facts by (kind, key, payload), not by id.
||| A `retract <label>` refers to the fact the labelled assert left live
||| under its identity, which is what the engine's handle refers to.
|||
||| TIME. A tick is [RARC.5.6.2]'s clock input: the clock takes the newer
||| value and the sweep retracts what has expired ([IRET.19.3]) before
||| anything else happens, as Rete/TtlSweep.idr's loop does before every
||| input. The reference engine sweeps at its next pump; the two reach one
||| state at every pump, and the difference shows only in a count read
||| between a tick and the pump after it.
|||
||| TIME-DEPENDENT TESTS. A `where`
||| may carry a clock leaf -- `dwell <binding>`, the monotonic sample less
||| the entry stamp of the fact at that rank ([LEXP.9.5.1]); `mono`, the
||| monotonic sample; `now`, the wall sample ([LTIM.2.8.3], [LTIM.2.1.1]),
||| which the lowering writes in nanoseconds since the epoch, unmapped --
||| and the lowering writes a pattern's `within d` as `lt dwell
||| <rank> lit i:<d>` conjoined before the `where` ([RLOW.5.4]). A rule
||| whose single positive pattern's `where` reads a clock is TIMED
||| ([LTIM.2.6.1]): its test is Rete/NetworkTimed.idr's `ltim_2_4_1__test_of`
||| over the evaluator's environment (`ltim_2_8_2__mono_test_of`, the form
||| that is a monotonic gate by construction, when the `where` reads no
||| `now`; the general form when it does), the node is loaded with the test
||| at the sample (0, 0) and no stamps, and the pump re-times it at the held
||| sample over the stamps as they stand ([IRET.19.5] steps 1 to 3,
||| [LTIM.2.4.3]). A clock leaf on a rule of any other shape -- more than one
||| pattern, a `no` pattern, a sequence -- is one the model does not re-time
||| ([LTIM.2.6.1]); the lowering refuses it, and this runner exits 2 rather
||| than run it untimed. The entry stamps are kept beside the deadline table
||| ([LTIM.2.8.6]): a data input stamps the fact it mints at the held sample,
||| an emit at the net's clock, a suppressed reassertion keeps its stamp, a
||| replace restamps. The wall sample starts at 0, the harness's epoch, and
||| is moved by the `wall` step alone (Rete/NetworkWall.idr's
||| `ltim_2_8_3__wall_set_timed`, [NTST.3.1]): the lowering writes an
||| advance as a tick then a wall step, a `set` as a tick, a `wall_set` as a
||| wall step, and writes no wall step at all when no `where` reads `now`,
||| which Rete/NetworkWall.idr's `ltim_2_8_2__wall_step_moves_no_monotonic_pump`
||| says changes nothing the pumps compute.
|||
||| AFTER TIMERS. An `after` clause
||| arrives lowered as the compiler lowers it ([LTAC.3.1]): a timer kind,
||| `synthetic`, that the parent emits after its own actions ([LTAC.3.3]),
||| and a follow-up rule on it whose single positive pattern's `where` is
||| `dwell 0 >= <dur>` -- the timer carries no `fire_at` slot, its entry
||| stamp being the sample the parent's firing held, so the guard
||| `monotonic_ns() >= t.fire_at` is the `dwell` gate
||| (Rete/NetworkTimer.idr, `ltac_3_4__guard_is_due`) -- with the body's
||| actions, their reads of the parent's match rewritten to the timer's
||| payload slots, then `withdraw 0` ([LTAC.3.4], [LTAC.4.2]). Nothing of
||| the engine changes: the follow-up is a timed rule like any other, and
||| the timer a fact like any other, printed by nothing.
|||
||| CALLS. The steps run on
||| Rete/NetworkCall.idr's CALLED ENGINE: Rete/NetworkTimed.idr's state with
||| the call trackers beside it. The `answer` records are the program's
||| answer kinds and where each keeps its `corr`
||| (`Lcrs_4_2_2__answers`, `Lcrs_4_3_2__corr_of`); the `callsite` records
||| are each rule's sites (`Lcrs_6_2_1__site`), their keys and arguments
||| evaluated over the fired match by Rete/Eval.idr as an `emitx` slot is.
||| A host assert goes through the ARRIVAL (`lcrs_6_2_4__arrive_timed`): the
||| sweep [LCRS.6.2.4] names on the asserted value's correlation -- a
||| response fact's own kind and `CallError`, a `CallError`'s every answer
||| kind -- then the timed input; a retraction sweeps nothing. A pump runs
||| `lcrs_6_2_1__pump_called`: each firing's RHS runs its sites at their
||| positions among its emits and withdraws, each site's gate deciding at
||| the net's clock on its own tracker ([LCRS.8.2], [RLOW.4.6.6.1]) and, when
||| it admits, sweeping the site's correlation over the kinds its service
||| answers with ([LCRS.6.2.1]: the response schema and `CallError`, or
||| `CallError` alone for a `no response` service) and recording the call.
||| With no site and no `corr` anywhere the called engine IS the timed
||| engine (`lcrs_6_2_1__no_site_is_the_timed_pump`,
||| `lcrs_6_2_4__no_corr_arrival_is_the_input`), so an input with no `answer`
||| and no `callsite` record prints what it printed before this rung. The
||| adapter is not modelled: an answer is a host assert, and this runner
||| takes no response from anywhere.
module Fixture

import Rete.FireLoop
import Rete.FireLoopTms
import Rete.PumpBoundary
import Rete.TtlSweep
import Rete.Network
import Rete.NetworkTms
import Rete.NetworkTmsTransfer
import Rete.NetworkTtl
import Rete.NetworkTraced
import Rete.NetworkTick
import Rete.NetworkClocked
import Rete.NetworkTwoClocks
import Rete.NetworkCooldown
import Rete.NetworkTimed
import Rete.NetworkWall
import Rete.NetworkCall
import Rete.EntryStamp
import Rete.Eval
import TwoClocks
import Data.List
import Data.String
import System
import System.File

%default total

-- ---------------------------------------------------------------------
-- The lowered fixture
-- ---------------------------------------------------------------------

data OStep = OAssert String Nat Nat Nat | ORetract String | OTick Nat | OWall Nat | OPump

||| An emit: two literal codes, or key and payload expressions over the bound
||| facts, coded when the rule fires.
data OEmit = OLiteral Nat Nat | OCopy (List Iret_7_5__expr) (List Iret_7_5__expr) | OWithdraw Nat

||| A CALL SITE as the lowering writes it (the header's CALLS): its rule's
||| ordinal, its index among the rule's calls, its position among the rule's
||| emits and withdraws, the service's dotted name, its window in clock units
||| (none under `nocooldown`), its response kind (none for a `no response`
||| service), its key expressions, its argument expressions and its
||| correlation, the literal `as`.
record OSite where
  constructor MkOSite
  oRule     : Nat
  oSite     : Nat
  oPosition : Nat
  oService  : String
  oWindow   : Maybe Nat
  oResponse : Maybe Nat
  oKeys     : List Iret_7_5__expr
  oArgs     : List Iret_7_5__expr
  oCorr     : Lstr_1_1__text

record Lowered where
  constructor MkLowered
  lifes     : List (Nat, Lscp_1_3__lifecycle)
  ttls      : List (Nat, Nat)                 -- (kind, default TTL in ns), kinds with one
  ruleNames : List (Nat, String)
  alphaKinds : List Nat                       -- kind of the alpha at each index, in index order
  patterns  : List (Nat, Nat, Bool)           -- (ordinal, alpha index, negative), in rule order
  emits     : List (Nat, Nat, OEmit)          -- (ordinal, kind, what), in rule order
  logs      : List (Nat, Nat, List Iret_7_5__expr)  -- (ordinal, index, sites), in rule order
  cools     : List (Nat, Nat, List Iret_7_5__expr)  -- (ordinal, window, key expressions), the `cool` records
  steps     : List OStep
  wheres    : List (Nat, Nat, Iret_7_5__expr) -- (ordinal, pattern index, test)
  jsons     : List (Nat, Lgra_5_8_1__json)    -- (token, document), the `json` records
  texts     : List (Nat, Lstr_1_1__text)      -- (token, text), the `string` records
  synthetics : List Nat                       -- the kinds of the `synthetic` records (AFTER TIMERS)
  answers   : List (Nat, Bool, Bool, Nat)     -- (kind, is CallError, corr in the key, corr index), the `answer` records (CALLS)
  callsites : List OSite                      -- the `callsite` records, in file order (CALLS)

emptyLowered : Lowered
emptyLowered = MkLowered [] [] [] [] [] [] [] [] [] [] [] [] [] [] []

-- ---------------------------------------------------------------------
-- The string table (the header's THE STRING TABLE)
-- ---------------------------------------------------------------------

||| The first codepoint no String can hold: one above [LSTR.1.1]'s range.
||| An input with no `string` records has its tokens stand for the texts
||| `[opaqueBase + token]`.
opaqueBase : Nat
opaqueBase = 1114112

||| The text a token stands for: the `string` record's, or the opaque one.
export
textOfToken : List (Nat, Lstr_1_1__text) -> Nat -> Lstr_1_1__text
textOfToken [] tok = [opaqueBase + tok]
textOfToken ((t, txt) :: rest) tok = if tok == t then txt else textOfToken rest tok

||| The token a text stands for, among the `string` records, or the token an
||| opaque text spells; nothing for a text no record holds -- a render the
||| evaluator computed, which the lowering never admits into an emit.
export
tokenOfText : List (Nat, Lstr_1_1__text) -> Lstr_1_1__text -> Maybe Nat
tokenOfText [] [c] = if c >= opaqueBase then Just (minus c opaqueBase) else Nothing
tokenOfText [] _   = Nothing
tokenOfText ((t, txt) :: rest) s = if txt == s then Just t else tokenOfText rest s

||| The two tables the value code reads: the documents of the `json`
||| records and the texts of the `string` records.
public export
record OTables where
  constructor MkTables
  tbJsons : List (Nat, Lgra_5_8_1__json)
  tbTexts : List (Nat, Lstr_1_1__text)

export
noTables : OTables
noTables = MkTables [] []

parseNat : String -> Maybe Nat
parseNat s = case parseInteger {a = Integer} s of
  Just n  => if n >= 0 then Just (cast n) else Nothing
  Nothing => Nothing

parseRole : String -> Maybe Bool
parseRole "key" = Just True
parseRole "pay" = Just False
parseRole _     = Nothing

parseBool : String -> Maybe Bool
parseBool "0" = Just False
parseBool "1" = Just True
parseBool _   = Nothing

||| An `answer` record's kind: a response schema's, or `CallError`'s.
parseAnswerKind : String -> Maybe Bool
parseAnswerKind "response" = Just False
parseAnswerKind "error"    = Just True
parseAnswerKind _          = Nothing

||| A natural, or `none`.
parseOptNat : String -> Maybe (Maybe Nat)
parseOptNat "none" = Just Nothing
parseOptNat s      = map Just (parseNat s)

||| The target of a cast, as the lowering spells [LCST.4.1.6]'s
||| four scalars.
parseTarget : String -> Maybe Lcst_4_1_6__target
parseTarget "int"    = Just TInt
parseTarget "float"  = Just TFloat
parseTarget "bool"   = Just TBool
parseTarget "string" = Just TString
parseTarget _        = Nothing

-- ---------------------------------------------------------------------
-- A Float's bits (glue: two R6RS bytevector procedures of Chez's)
-- ---------------------------------------------------------------------

%foreign "scheme,chez:(lambda (x) (let ([bv (make-bytevector 8)]) (bytevector-ieee-double-native-set! bv 0 x) (bytevector-u64-native-ref bv 0)))"
prim__doubleBits : Double -> Integer

%foreign "scheme,chez:(lambda (n) (let ([bv (make-bytevector 8)]) (bytevector-u64-native-set! bv 0 n) (bytevector-ieee-double-native-ref bv 0)))"
prim__bitsDouble : Integer -> Double

||| The bits of a binary64, as the natural they spell: sign, exponent,
||| fraction, most significant first.
export
doubleBits : Double -> Integer
doubleBits = prim__doubleBits

||| The binary64 a natural below 2^64 spells; a natural at or above it
||| spells none.
export
bitsDouble : Integer -> Maybe Double
bitsDouble n = if n < 0 || n >= 18446744073709551616 then Nothing else Just (prim__bitsDouble n)

||| One value of a `value` or `lit` token; a String token's text is the
||| table's.
parseValue : List (Nat, Lstr_1_1__text) -> String -> Maybe Lnul_2_1__value
parseValue txts "n"   = Just VNull
parseValue txts "b:0" = Just (VBool False)
parseValue txts "b:1" = Just (VBool True)
parseValue txts s =
  if isPrefixOf "i:" s then map VInt (parseInteger {a = Integer} (substr 2 (length s) s))
  else if isPrefixOf "f:" s then (parseInteger {a = Integer} (substr 2 (length s) s) >>= bitsDouble) >>= (Just . VFloat)
  else if isPrefixOf "s:" s then map (VStr . textOfToken txts) (parseNat (substr 2 (length s) s))
  else Nothing

||| A leaf of a `json` record: the scalar a value token spells, a JSON null
||| for `null`.
leafOf : List (Nat, Lstr_1_1__text) -> String -> Maybe Lgra_5_8_1__json
leafOf txts "null" = Just JNull
leafOf txts s = case parseValue txts s of
  Just (VBool b)  => Just (JBool b)
  Just (VInt n)   => Just (JInt n)
  Just (VFloat x) => Just (JFloat x)
  Just (VStr t)   => Just (JStr t)
  _               => Nothing

||| A document in prefix form, and the tokens after it. The fuel is the
||| token count, as for `parseExpr`: every node consumes at least one token.
parseJson : List (Nat, Lstr_1_1__text) -> Nat -> List String -> Maybe (Lgra_5_8_1__json, List String)
parseJsons : List (Nat, Lstr_1_1__text) -> Nat -> Nat -> List String -> Maybe (List Lgra_5_8_1__json, List String)
parseMembers : List (Nat, Lstr_1_1__text) -> Nat -> Nat -> List String -> Maybe (List (Nat, Lgra_5_8_1__json), List String)

parseJson txts Z _ = Nothing
parseJson txts (S f) ("arr" :: n :: rest) = case parseNat n of
  Just count => case parseJsons txts f count rest of
    Just (xs, r1) => Just (JArr xs, r1)
    Nothing => Nothing
  Nothing => Nothing
parseJson txts (S f) ("obj" :: n :: rest) = case parseNat n of
  Just count => case parseMembers txts f count rest of
    Just (ms, r1) => Just (JObj ms, r1)
    Nothing => Nothing
  Nothing => Nothing
parseJson txts (S f) (leaf :: rest) = map (\j => (j, rest)) (leafOf txts leaf)
parseJson txts (S f) [] = Nothing

parseJsons txts fuel Z toks = Just ([], toks)
parseJsons txts fuel (S n) toks = case parseJson txts fuel toks of
  Just (j, rest) => case parseJsons txts fuel n rest of
    Just (js, r2) => Just (j :: js, r2)
    Nothing => Nothing
  Nothing => Nothing

parseMembers txts fuel Z toks = Just ([], toks)
parseMembers txts fuel (S n) (k :: toks) = case parseNat k of
  Just key => case parseJson txts fuel toks of
    Just (j, rest) => case parseMembers txts fuel n rest of
      Just (ms, r2) => Just ((key, j) :: ms, r2)
      Nothing => Nothing
    Nothing => Nothing
  Nothing => Nothing
parseMembers txts fuel (S n) [] = Nothing

||| The codepoints of a `string` record, each admissible ([LSTR.1.1]).
parseCodepoints : Nat -> List String -> Maybe (Lstr_1_1__text, List String)
parseCodepoints Z toks = Just ([], toks)
parseCodepoints (S n) (c :: toks) = case parseNat c of
  Just cp => if lstr_1_1__admissible cp
               then (case parseCodepoints n toks of
                       Just (cps, rest) => Just (cp :: cps, rest)
                       Nothing => Nothing)
               else Nothing
  Nothing => Nothing
parseCodepoints (S n) [] = Nothing

||| A path segment: `k:<token>` a member, `i:<index>` an element.
parseSeg : String -> Maybe Lgra_5_8_5__seg
parseSeg s =
  if isPrefixOf "k:" s then map SKey (parseNat (substr 2 (length s) s))
  else if isPrefixOf "i:" s then map SIndex (parseNat (substr 2 (length s) s))
  else Nothing

parseSegs : Nat -> List String -> Maybe (List Lgra_5_8_5__seg, List String)
parseSegs Z toks = Just ([], toks)
parseSegs (S n) (s :: toks) = case (parseSeg s, parseSegs n toks) of
  (Just seg, Just (segs, rest)) => Just (seg :: segs, rest)
  _ => Nothing
parseSegs (S n) [] = Nothing

binOp : String -> Maybe (Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr)
binOp "eq"  = Just (ECmp OpEq)
binOp "ne"  = Just (ECmp OpNe)
binOp "lt"  = Just (ECmp OpLt)
binOp "le"  = Just (ECmp OpLe)
binOp "gt"  = Just (ECmp OpGt)
binOp "ge"  = Just (ECmp OpGe)
binOp "add" = Just (EArith OpAdd)
binOp "sub" = Just (EArith OpSub)
binOp "mul" = Just (EArith OpMul)
binOp "div" = Just (EArith OpDiv)
binOp "floordiv" = Just (EArith OpFloorDiv)
binOp "mod" = Just (EArith OpMod)
binOp "and" = Just EAnd
binOp "or"  = Just EOr
binOp "coalesce" = Just ECoalesce
binOp _     = Nothing

unOp : String -> Maybe (Iret_7_5__expr -> Iret_7_5__expr)
unOp "not" = Just ENot
unOp "neg" = Just ENeg
unOp _     = Nothing

||| The subject of `is`, as the lowering spells [LNUL.4.9]'s
||| twelve.
parseSubject : String -> Maybe Lnul_4_9__subject
parseSubject "null"   = Just IsNull
parseSubject "true"   = Just IsTrue
parseSubject "false"  = Just IsFalse
parseSubject "inf"    = Just IsInf
parseSubject "neginf" = Just IsNegInf
parseSubject "nan"    = Just IsNaN
parseSubject "int"    = Just IsInt
parseSubject "float"  = Just IsFloat
parseSubject "bool"   = Just IsBool
parseSubject "string" = Just IsString
parseSubject "bytes"  = Just IsBytes
parseSubject "json"   = Just IsJson
parseSubject _        = Nothing

||| `is` un-negated, `isnot` the one operator `is not`.
parseIs : String -> Maybe Bool
parseIs "is"    = Just False
parseIs "isnot" = Just True
parseIs _       = Nothing

||| One prefix expression and the tokens after it. The fuel is the token
||| count: every node consumes at least one token, so the depth is bounded
||| by it, and the token list is not structurally smaller to the totality
||| checker across the two recursive calls of a binary node. An `is` or
||| `isnot` is followed by its subject token and then its operand; a `cast`
||| by its target and its fallibility flag, then its operand. A `lit
||| s:<token>` is the String whose text the table gives the token.
parseExpr : List (Nat, Lstr_1_1__text) -> Nat -> List String -> Maybe (Iret_7_5__expr, List String)
parseExpr txts Z _ = Nothing
parseExpr txts (S f) [] = Nothing
parseExpr txts (S f) ("slot" :: b :: r :: i :: rest) =
  case (parseNat b, parseRole r, parseNat i) of
    (Just bn, Just isKey, Just iN) => Just (ESlot bn isKey iN, rest)
    _ => Nothing
parseExpr txts (S f) ("lit" :: v :: rest) = map (\x => (ELit x, rest)) (parseValue txts v)
parseExpr txts (S f) ("cast" :: t :: n :: rest) =
  case (parseTarget t, parseBool n) of
    (Just tg, Just fallible) => case parseExpr txts f rest of
      Just (e, r1) => Just (ECast fallible tg e, r1)
      Nothing => Nothing
    _ => Nothing
parseExpr txts (S f) ("path" :: n :: rest) =
  case parseNat n of
    Just count => case parseSegs count rest of
      Just (segs, r1) => case parseExpr txts f r1 of
        Just (e, r2) => Just (EPath segs e, r2)
        Nothing => Nothing
      Nothing => Nothing
    Nothing => Nothing
parseExpr txts (S f) ("has" :: n :: rest) =
  case parseNat n of
    Just count => case parseSegs count rest of
      Just (segs, r1) => case parseExpr txts f r1 of
        Just (e, r2) => Just (EHas segs e, r2)
        Nothing => Nothing
      Nothing => Nothing
    Nothing => Nothing
parseExpr txts (S f) ("len" :: rest) =
  case parseExpr txts f rest of
    Just (e, r1) => Just (ELen e, r1)
    Nothing => Nothing
parseExpr txts (S f) ("slen" :: rest) =
  case parseExpr txts f rest of
    Just (e, r1) => Just (ELenStr e, r1)
    Nothing => Nothing
parseExpr txts (S f) ("dwell" :: b :: rest) = map (\bn => (EClock (ReadDwell bn), rest)) (parseNat b)
parseExpr txts (S f) ("mono" :: rest) = Just (EClock ReadMono, rest)
parseExpr txts (S f) ("now" :: rest) = Just (EClock ReadNow, rest)
parseExpr txts (S f) (op :: rest) =
  case parseIs op of
    Just neg => case rest of
      (s :: rest') => case parseSubject s of
        Just subj => case parseExpr txts f rest' of
          Just (e, r1) => Just (EIs neg subj e, r1)
          Nothing => Nothing
        Nothing => Nothing
      [] => Nothing
    Nothing => case binOp op of
      Just mk => case parseExpr txts f rest of
        Just (l, r1) => case parseExpr txts f r1 of
          Just (r, r2) => Just (mk l r, r2)
          Nothing => Nothing
        Nothing => Nothing
      Nothing => case unOp op of
        Just mk => case parseExpr txts f rest of
          Just (e, r1) => Just (mk e, r1)
          Nothing => Nothing
        Nothing => Nothing

||| `n` prefix expressions in a row, each with the whole fuel.
parseExprs : List (Nat, Lstr_1_1__text) -> Nat -> Nat -> List String -> Maybe (List Iret_7_5__expr, List String)
parseExprs txts fuel Z toks = Just ([], toks)
parseExprs txts fuel (S n) toks = case parseExpr txts fuel toks of
  Just (e, rest) => case parseExprs txts fuel n rest of
    Just (es, r2) => Just (e :: es, r2)
    Nothing => Nothing
  Nothing => Nothing

parseLife : String -> Maybe Lscp_1_3__lifecycle
parseLife "explicit" = Just Explicit
parseLife "relation" = Just Relation
parseLife "entity"   = Just Entity
parseLife _          = Nothing

||| One record's fields. Records are appended in file order, which is the
||| order the lowering promises for alphas, rules, patterns, emits, logs
||| and steps.
parseFields : Lowered -> List String -> Either String Lowered
parseFields low ("schema" :: k :: lc :: _ :: []) =
  case (parseNat k, parseLife lc) of
    (Just kn, Just l) => Right ({ lifes $= (++ [(kn, l)]) } low)
    _ => Left "schema: bad kind or lifecycle"
parseFields low ("ttl" :: k :: ns :: []) =
  case (parseNat k, parseNat ns) of
    (Just kn, Just n) => Right ({ ttls $= (++ [(kn, n)]) } low)
    _ => Left "ttl: bad kind or duration"
parseFields low ("alpha" :: _ :: k :: []) =
  case parseNat k of
    Just kn => Right ({ alphaKinds $= (++ [kn]) } low)
    Nothing => Left "alpha: bad kind"
parseFields low ("synthetic" :: k :: []) =
  case parseNat k of
    Just kn => Right ({ synthetics $= (++ [kn]) } low)
    Nothing => Left "synthetic: bad kind"
parseFields low ("rule" :: o :: name :: []) =
  case parseNat o of
    Just on => Right ({ ruleNames $= (++ [(on, name)]) } low)
    Nothing => Left "rule: bad ordinal"
parseFields low ("pattern" :: o :: a :: n :: []) =
  case (parseNat o, parseNat a, parseBool n) of
    (Just on, Just an, Just neg) => Right ({ patterns $= (++ [(on, an, neg)]) } low)
    _ => Left "pattern: bad fields"
parseFields low ("emit" :: o :: k :: key :: pay :: []) =
  case (parseNat o, parseNat k, parseNat key, parseNat pay) of
    (Just on, Just kn, Just keyn, Just payn) => Right ({ emits $= (++ [(on, kn, OLiteral keyn payn)]) } low)
    _ => Left "emit: bad fields"
parseFields low ("withdraw" :: o :: b :: []) =
  case (parseNat o, parseNat b) of
    (Just on, Just bn) => Right ({ emits $= (++ [(on, 0, OWithdraw bn)]) } low)
    _ => Left "withdraw: bad fields"
parseFields low ("step" :: "assert" :: label :: k :: key :: pay :: []) =
  case (parseNat k, parseNat key, parseNat pay) of
    (Just kn, Just keyn, Just payn) => Right ({ steps $= (++ [OAssert label kn keyn payn]) } low)
    _ => Left "step assert: bad fields"
parseFields low ("emitx" :: o :: k :: nk :: np :: toks) =
  case (parseNat o, parseNat k, parseNat nk, parseNat np) of
    (Just on, Just kn, Just nkey, Just npay) =>
      case parseExprs (texts low) (length toks) nkey toks of
        Just (keys, rest) => case parseExprs (texts low) (length toks) npay rest of
          Just (pays, []) => Right ({ emits $= (++ [(on, kn, OCopy keys pays)]) } low)
          Just (_, extra) => Left ("emitx: tokens left over: " ++ unwords extra)
          Nothing => Left "emitx: bad payload expression"
        Nothing => Left "emitx: bad key expression"
    _ => Left "emitx: bad fields"
parseFields low ("log" :: o :: i :: n :: toks) =
  case (parseNat o, parseNat i, parseNat n) of
    (Just on, Just iN, Just nsites) =>
      case parseExprs (texts low) (length toks) nsites toks of
        Just (sites, []) => Right ({ logs $= (++ [(on, iN, sites)]) } low)
        Just (_, extra) => Left ("log: tokens left over: " ++ unwords extra)
        Nothing => Left "log: bad site expression"
    _ => Left "log: bad fields"
parseFields low ("cool" :: o :: w :: n :: toks) =
  case (parseNat o, parseNat w, parseNat n) of
    (Just on, Just wn, Just nkeys) =>
      case parseExprs (texts low) (length toks) nkeys toks of
        Just (keys, []) => Right ({ cools $= (++ [(on, wn, keys)]) } low)
        Just (_, extra) => Left ("cool: tokens left over: " ++ unwords extra)
        Nothing => Left "cool: bad key expression"
    _ => Left "cool: bad fields"
parseFields low ("string" :: t :: n :: toks) =
  case (parseNat t, parseNat n) of
    (Just tok, Just count) => case parseCodepoints count toks of
      Just (cps, []) => Right ({ texts $= (++ [(tok, cps)]) } low)
      Just (_, extra) => Left ("string " ++ t ++ ": tokens left over: " ++ unwords extra)
      Nothing => Left ("string " ++ t ++ ": a codepoint no String holds [LSTR.1.1], or too few")
    _ => Left "string: bad token or count"
parseFields low ("where" :: o :: p :: toks) =
  case (parseNat o, parseNat p, parseExpr (texts low) (length toks) toks) of
    (Just on, Just pn, Just (e, [])) => Right ({ wheres $= (++ [(on, pn, e)]) } low)
    (Just _, Just _, Just (_, extra)) => Left ("where: tokens left over: " ++ unwords extra)
    _ => Left "where: bad fields or expression"
parseFields low ("step" :: "retract" :: label :: []) = Right ({ steps $= (++ [ORetract label]) } low)
parseFields low ("step" :: "tick" :: t :: []) =
  case parseNat t of
    Just tn => Right ({ steps $= (++ [OTick tn]) } low)
    Nothing => Left "step tick: bad clock"
parseFields low ("step" :: "wall" :: w :: []) =
  case parseNat w of
    Just wn => Right ({ steps $= (++ [OWall wn]) } low)
    Nothing => Left "step wall: bad instant"
parseFields low ("step" :: "pump" :: []) = Right ({ steps $= (++ [OPump]) } low)
parseFields low ("json" :: t :: toks) =
  case (parseNat t, parseJson (texts low) (length toks) toks) of
    (Just tok, Just (JNull, [])) => Left ("json " ++ t ++ ": a root null is the canonical null, not a document [LNUL.3.4]")
    (Just tok, Just (j, [])) =>
      if lgra_5_8_7__keys_unique j
        then Right ({ jsons $= (++ [(tok, lgra_5_8_8__unsigned_zeros j)]) } low)
        else Left ("json " ++ t ++ ": an object names a key twice [LGRA.5.8.7]")
    (Just _, Just (_, extra)) => Left ("json: tokens left over: " ++ unwords extra)
    _ => Left "json: bad token or tree"
parseFields low ("answer" :: k :: what :: r :: i :: []) =
  case (parseNat k, parseAnswerKind what, parseRole r, parseNat i) of
    (Just kn, Just isErr, Just isKey, Just iN) => Right ({ answers $= (++ [(kn, isErr, isKey, iN)]) } low)
    _ => Left "answer: bad fields"
parseFields low ("callsite" :: o :: n :: p :: svc :: w :: resp :: nk :: toks) =
  -- Two triples, not one six-tuple: a tuple nests a pair per component and
  -- the checker's ambiguity depth stops at three ("Maximum ambiguity depth
  -- exceeded").
  case (parseNat o, parseNat n, parseNat p) of
    (Just on, Just sn, Just pn) => case (parseOptNat w, parseOptNat resp, parseNat nk) of
      (Just wn, Just rn, Just nkeys) =>
        case parseExprs (texts low) (length toks) nkeys toks of
          Just (keys, na :: rest) => case parseNat na of
            Just nargs => case parseExprs (texts low) (length rest) nargs rest of
              Just (args, ctoks) => case parseExpr (texts low) (length ctoks) ctoks of
                Just (ELit (VStr corr), []) => Right ({ callsites $= (++ [MkOSite on sn pn svc wn rn keys args corr]) } low)
                Just (_, []) => Left "callsite: the correlation is not a String literal (a computed `as` is outside the fragment)"
                Just (_, extra) => Left ("callsite: tokens left over: " ++ unwords extra)
                Nothing => Left "callsite: bad correlation"
              Nothing => Left "callsite: bad argument expression"
            Nothing => Left "callsite: bad argument count"
          Just (_, []) => Left "callsite: no argument count"
          Nothing => Left "callsite: bad key expression"
      _ => Left "callsite: bad fields"
    _ => Left "callsite: bad fields"
parseFields low ws = Left ("unrecognised record: " ++ unwords ws)

||| One record: blank lines and `#` comments are skipped.
parseRecord : Lowered -> List String -> Either String Lowered
parseRecord low [] = Right low
parseRecord low (w :: ws) = if isPrefixOf "#" w then Right low else parseFields low (w :: ws)

parseAll : Lowered -> List String -> Either String Lowered
parseAll low [] = Right low
parseAll low (l :: ls) = case parseRecord low (words l) of
  Left err => Left err
  Right low' => parseAll low' ls

-- ---------------------------------------------------------------------
-- The loaded network
-- ---------------------------------------------------------------------

lookupNat : Nat -> List (Nat, a) -> Maybe a
lookupNat k [] = Nothing
lookupNat k ((k', v) :: rest) = if k == k' then Just v else lookupNat k rest

lifeOf : List (Nat, Lscp_1_3__lifecycle) -> Nat -> Lscp_1_3__lifecycle
lifeOf ls k = case lookupNat k ls of
  Just l  => l
  Nothing => Explicit

||| The schema descriptor's default TTL by kind, zero for a kind without
||| one: Rete/TtlSweep.idr's `Iret_4_2__ttl`.
ttlOf : List (Nat, Nat) -> Iret_4_2__ttl
ttlOf ts k = case lookupNat k ts of
  Just n  => n
  Nothing => 0

||| Every alpha admits every fact of its kind. A `where` is carried as the
||| pattern's join test instead: pattern 0 is a beta over the nil token, so
||| one mechanism serves every pattern, and a single-pattern test reads the
||| candidate alone.
alphasOf : Lowered -> List (Nat, Lfac_1_7_1__fact -> Bool)
alphasOf low = map (\k => (k, \_ => True)) (alphaKinds low)

indexedFrom : Nat -> List a -> List (Nat, a)
indexedFrom n [] = []
indexedFrom n (x :: xs) = (n, x) :: indexedFrom (S n) xs

lookupWhere : Nat -> Nat -> List (Nat, Nat, Iret_7_5__expr) -> Maybe Iret_7_5__expr
lookupWhere o i [] = Nothing
lookupWhere o i ((o1, i1, e) :: rest) = if o == o1 && i == i1 then Just e else lookupWhere o i rest

-- ---------------------------------------------------------------------
-- The value code (the header's THE VALUE CODE)
-- ---------------------------------------------------------------------

||| One block of twenty-one decimal digits per slot.
export
codeBase : Integer
codeBase = 1000000000000000000000

||| ZigZag, as protobuf states it: p >= 0 is 2p, n < 0 is 2|n| - 1.
zigzag : Integer -> Integer
zigzag n = if n >= 0 then 2 * n else negate (2 * n) - 1

unzigzag : Integer -> Integer
unzigzag z = if z `mod` 2 == 0 then z `div` 2 else negate ((z `div` 2) + 1)

||| The document a token stands for, among the input's `json` records.
jsonOf : List (Nat, Lgra_5_8_1__json) -> Nat -> Maybe Lgra_5_8_1__json
jsonOf [] t = Nothing
jsonOf ((t', j) :: rest) t = if t == t' then Just j else jsonOf rest t

||| The token of the document equal to `j`, by deep structural equality,
||| among the input's `json` records; none for a tree no record holds.
tokenOf : List (Nat, Lgra_5_8_1__json) -> Lgra_5_8_1__json -> Maybe Nat
tokenOf [] j = Nothing
tokenOf ((t, j') :: rest) j = if lfac_2_5_1__json_eq j j' then Just t else tokenOf rest j

||| A value as a block: eight times its payload plus its tag. A Float's
||| payload is its bits, `-0.0` as `+0.0`; a NaN has no block. A document's
||| payload is the token of the equal document among the input's `json`
||| records, a String's the token of its text among the `string` records
||| (or the token its opaque text spells); one held by no table has no
||| block.
export
valueBlockWith : OTables -> Lnul_2_1__value -> Maybe Integer
valueBlockWith tb VNull      = Just 0
valueBlockWith tb (VBool b)  = Just ((if b then 8 else 0) + 1)
valueBlockWith tb (VInt n)   = Just (8 * zigzag n + 2)
valueBlockWith tb (VStr t)   = map (\tok => 8 * cast tok + 3) (tokenOfText (tbTexts tb) t)
valueBlockWith tb (VJson j)  = map (\t => 8 * cast t + 3) (tokenOf (tbJsons tb) j)
valueBlockWith tb (VFloat x) =
  if x /= x then Nothing
  else Just (8 * doubleBits (if x == 0.0 then 0.0 else x) + 4)

export
valueBlock : Lnul_2_1__value -> Maybe Integer
valueBlock = valueBlockWith noTables

||| A block back to its value; nothing for a block no value makes -- a
||| tag above 4, a payload no value of the tag has, a NaN's bits. A tag-3
||| payload with a `json` record is that document; any other a String, its
||| text the `string` record's or the opaque one.
export
blockValueWith : OTables -> Integer -> Maybe Lnul_2_1__value
blockValueWith tb d =
  let tag = d `mod` 8
      pay = d `div` 8
  in if d < 0 then Nothing
     else if tag == 0 then (if pay == 0 then Just VNull else Nothing)
     else if tag == 1 then (if pay == 0 then Just (VBool False)
                            else if pay == 1 then Just (VBool True) else Nothing)
     else if tag == 2 then Just (VInt (unzigzag pay))
     else if tag == 3 then (case jsonOf (tbJsons tb) (cast pay) of
                              Just j  => Just (VJson j)
                              Nothing => Just (VStr (textOfToken (tbTexts tb) (cast pay))))
     else if tag == 4 then (case bitsDouble pay of
                              Just x  => if x /= x then Nothing else Just (VFloat x)
                              Nothing => Nothing)
     else Nothing

export
blockValue : Integer -> Maybe Lnul_2_1__value
blockValue = blockValueWith noTables

||| The code of a tuple: the numeral `1`, then one block per value, first
||| value first. `[]` is 1; no tuple's code is 0, and a tuple with a NaN
||| in it, which no value code spells, is given 0 -- the trap id, so the
||| fact surfaces as a divergence rather than entering working memory. A
||| document no `json` record holds, and a text no `string` record holds,
||| are given 0 likewise.
export
valueCodeWith : OTables -> List Lnul_2_1__value -> Nat
valueCodeWith tb vs = case foldl step (Just 1) vs of
                        Just n  => cast n
                        Nothing => 0
  where
    step : Maybe Integer -> Lnul_2_1__value -> Maybe Integer
    step Nothing    _ = Nothing
    step (Just acc) v = map (\b => acc * codeBase + b) (valueBlockWith tb v)

export
valueCode : List Lnul_2_1__value -> Nat
valueCode = valueCodeWith noTables

||| Blocks are peeled off the low end, last value first, until the sentinel
||| `1` alone is left. The fuel bounds the arity; a natural below the base
||| that is not the sentinel, or a block no value makes, is no code.
decodeBlocks : OTables -> Nat -> Integer -> List Lnul_2_1__value -> Maybe (List Lnul_2_1__value)
decodeBlocks tb fuel n acc =
  if n == 1 then Just acc
  else if n < codeBase then Nothing
  else case fuel of
    Z   => Nothing
    S f => case blockValueWith tb (n `mod` codeBase) of
      Nothing => Nothing
      Just v  => decodeBlocks tb f (n `div` codeBase) (v :: acc)

||| The arity the decoder admits; the lowering refuses a wider tuple
||| (`code:arity`), and no schema has slots in these numbers.
codeArity : Nat
codeArity = 256

||| The environment every `where` reads through: the tuple an id codes,
||| the input's documents decoded to their trees and its tokens to their
||| texts.
export
valueDecodeWith : OTables -> Iret_7_6__env
valueDecodeWith tb i = decodeBlocks tb codeArity (cast i) []

export
valueDecode : Iret_7_6__env
valueDecode = valueDecodeWith noTables

||| The input's two tables.
tablesOf : Lowered -> OTables
tablesOf low = MkTables (jsons low) (texts low)

||| The id of an emitted tuple with a trap or a NaN in it. No tuple's code,
||| so the fact surfaces as one nobody else can produce, a divergence rather
||| than a silent drop ([LERR.1]'s abandoned activation and [LEXP.4.2]'s
||| rejection are not modelled).
trapId : Nat
trapId = 0

||| Value equality, written out: the evaluator's value type carries no `Eq`.
||| On Floats it is IEEE's (`-0.0` is `0.0`; a NaN is nothing, itself
||| included).
export
sameValue : Lnul_2_1__value -> Lnul_2_1__value -> Bool
sameValue (VInt a)   (VInt b)   = a == b
sameValue (VFloat a) (VFloat b) = a == b
sameValue (VStr a)   (VStr b)   = a == b
sameValue (VBool a)  (VBool b)  = a == b
sameValue (VJson a)  (VJson b)  = lfac_2_5_1__json_eq a b
sameValue VNull      VNull      = True
sameValue _          _          = False

export
sameValues : List Lnul_2_1__value -> List Lnul_2_1__value -> Bool
sameValues [] [] = True
sameValues (x :: xs) (y :: ys) = sameValue x y && sameValues xs ys
sameValues _ _ = False

-- ---------------------------------------------------------------------
-- The loaded network (continued)
-- ---------------------------------------------------------------------

||| A timed test from a `where` that reads a clock (the header's
||| TIME-DEPENDENT TESTS): the monotonic form when it reads no `now`,
||| which Rete/NetworkTimed.idr proves a monotonic gate by construction and
||| pointwise the general test; the general form otherwise.
timedTestOf : OTables -> Iret_7_5__expr -> Ltim_2_4_1__ttest
timedTestOf tb e = if ltim_2_8_2__reads_wall e then ltim_2_4_1__test_of (valueDecodeWith tb) e
                                                 else ltim_2_8_2__mono_test_of (valueDecodeWith tb) e

||| A pattern's join relation. Without a `where` every candidate joins (and,
||| on a `no` node, blocks). With one, Rete/Eval.idr decides: a positive node
||| admits on `true` ([LNUL.4.3]); a `no` node is blocked unless `false`
||| ([LNUL.4.7]). A positive node whose `where` reads a clock is loaded with
||| its timed test at the sample (0, 0) and no stamps; the pump re-times it.
joinFor : Lowered -> Nat -> Nat -> Bool -> Iret_7_5__join
joinFor low o i neg = case lookupWhere o i (wheres low) of
  Nothing => \_, _ => True
  Just e  => if neg then iret_7_6__blocks_join (valueDecodeWith (tablesOf low)) e
             else if ltim_2_4_1__reads_clock e then timedTestOf (tablesOf low) e [] (0, 0)
             else iret_7_6__admits_join (valueDecodeWith (tablesOf low)) e

||| A rule's timed test, by its ordinal: the test of its one positive
||| pattern's `where` when that `where` reads a clock and the rule has no
||| other pattern ([LTIM.2.6.1]); none otherwise. A clock leaf on a rule
||| of any other shape is reported by `timedShapeDefect`.
timedOf : Lowered -> List (Maybe Ltim_2_4_1__ttest)
timedOf low = map (\(o, _) => ruleTest o) (ruleNames low)
  where
    ruleTest : Nat -> Maybe Ltim_2_4_1__ttest
    ruleTest o = case filter (\(o', _, _) => o' == o) (patterns low) of
      [(_, _, False)] => case lookupWhere o 0 (wheres low) of
        Just e => if ltim_2_4_1__reads_clock e then Just (timedTestOf (tablesOf low) e) else Nothing
        Nothing => Nothing
      _ => Nothing

||| The first `where` that reads a clock on a rule the model does not
||| re-time: more than one pattern, a `no` pattern, or a test off the first
||| pattern. The lowering refuses such a fixture by reason; this runner
||| refuses to run it untimed.
timedShapeDefect : Lowered -> Maybe (Nat, Nat)
timedShapeDefect low = go (wheres low)
  where
    single : Nat -> Bool
    single o = case filter (\(o', _, _) => o' == o) (patterns low) of
      [(_, _, False)] => True
      _ => False
    go : List (Nat, Nat, Iret_7_5__expr) -> Maybe (Nat, Nat)
    go [] = Nothing
    go ((o, i, e) :: rest) = if ltim_2_4_1__reads_clock e && not (single o && i == 0) then Just (o, i) else go rest

patternsOf : Lowered -> Nat -> List (Nat, Iret_7_5__join, Bool)
patternsOf low o =
  map (\(i, (_, a, neg)) => (a, joinFor low o i neg, neg))
      (indexedFrom 0 (filter (\(o', _, _) => o' == o) (patterns low)))

||| The values an emit's expressions give over the bound facts; a trap makes
||| the whole tuple unknown.
evalAll : Iret_7_6__env -> List Lfac_1_7_1__fact -> List Iret_7_5__expr -> Maybe (List Lnul_2_1__value)
evalAll env fs [] = Just []
evalAll env fs (e :: es) = case (iret_7_6__eval env fs e, evalAll env fs es) of
  (RVal v, Just vs) => Just (v :: vs)
  _ => Nothing

emitOf : OTables -> Nat -> OEmit -> Lgra_10_1__action
emitOf tb k (OLiteral key pay) = Emit k (\_ => (key, pay))
emitOf tb k (OCopy keys pays) = Emit k (\fs =>
  ( maybe trapId (valueCodeWith tb) (evalAll (valueDecodeWith tb) fs keys)
  , maybe trapId (valueCodeWith tb) (evalAll (valueDecodeWith tb) fs pays) ))
emitOf tb k (OWithdraw b) = Withdraw b

actionsOf : Lowered -> Nat -> List Lgra_10_1__action
actionsOf low o = map (\(_, k, e) => emitOf (tablesOf low) k e) (filter (\(o', _, _) => o' == o) (emits low))

rulesOf : Lowered -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action)
rulesOf low = map (\(o, _) => (patternsOf low o, actionsOf low o)) (ruleNames low)

||| A rule's `log` sites, in index order.
logsOf : Lowered -> Nat -> List (Nat, List Iret_7_5__expr)
logsOf low o = map (\(_, i, es) => (i, es)) (filter (\(o', _, _) => o' == o) (logs low))

lookupCool : Nat -> List (Nat, Nat, List Iret_7_5__expr) -> Maybe (Nat, List Iret_7_5__expr)
lookupCool o [] = Nothing
lookupCool o ((o', w, es) :: rest) = if o == o' then Just (w, es) else lookupCool o rest

||| A rule's cooldown: its window, and its activation key as a function of
||| the fired match -- the key expressions evaluated over the fired facts
||| by Rete/Eval.idr, exactly as an `emitx` slot is, and the tuple CODED,
||| so that two keys are one key iff their codes are equal: [RLOW.4.6.2.1]'s
||| identity. A slot read never traps, so `trapId` is unreachable here;
||| it is the branch the shared evaluator leaves.
coolOf : OTables -> Maybe (Nat, List Iret_7_5__expr) -> Lcdb_3_2_1__cool
coolOf tb Nothing = Nothing
coolOf tb (Just (w, keys)) = Just (w, \fs => maybe trapId (valueCodeWith tb) (evalAll (valueDecodeWith tb) fs keys))

||| The cooldowns by ordinal, in rule order, as Rete/NetworkCooldown.idr
||| takes them.
coolsOf : Lowered -> List Lcdb_3_2_1__cool
coolsOf low = map (\(o, _) => coolOf (tablesOf low) (lookupCool o (cools low))) (ruleNames low)

-- ---------------------------------------------------------------------
-- The call surface (the header's CALLS)
-- ---------------------------------------------------------------------

||| The response kinds among the `answer` records.
responseKinds : List (Nat, Bool, Bool, Nat) -> List Nat
responseKinds [] = []
responseKinds ((k, False, _, _) :: rest) = k :: responseKinds rest
responseKinds ((k, True, _, _) :: rest) = responseKinds rest

||| The error kinds among the `answer` records: one, or none.
errorKinds : List (Nat, Bool, Bool, Nat) -> List Nat
errorKinds [] = []
errorKinds ((k, True, _, _) :: rest) = k :: errorKinds rest
errorKinds ((k, False, _, _) :: rest) = errorKinds rest

||| THE ANSWER KINDS: the response schemas' and CallError's
||| (Rete/NetworkCall.idr's `Lcrs_4_2_2__answers`). With no `error` record
||| the error kind is one no schema has, so no fact is one.
answersOf : Lowered -> Lcrs_4_2_2__answers
answersOf low = MkAnswers (responseKinds (answers low)) (errorOf (errorKinds (answers low)))
  where
    errorOf : List Nat -> Nat
    errorOf (k :: _) = k
    errorOf [] = length (lifes low)

||| WHERE A KIND KEEPS ITS `corr` (Rete/NetworkCall.idr's
||| `Lcrs_4_3_2__corr_of`): the `answer` record's role and index; none for a
||| kind with no record, which reads no correlation.
corrOfLow : Lowered -> Lcrs_4_3_2__corr_of
corrOfLow low k = go (answers low)
  where
    go : List (Nat, Bool, Bool, Nat) -> Maybe (Bool, Nat)
    go [] = Nothing
    go ((k', _, isKey, i) :: rest) = if k == k' then Just (isKey, i) else go rest

||| Whether a site's response kind, if any, is among the response kinds.
responseDeclared : List Nat -> Maybe Nat -> Bool
responseDeclared resps Nothing  = True
responseDeclared resps (Just k) = elem k resps

||| What the call records cannot mean: two `error` records, a kind both a
||| response and the error, a site whose response kind no `answer` record
||| declares, or calls or responses with no error kind to sweep beside them.
||| The lowering writes none of these; this runner refuses to run one.
callDefect : Lowered -> Maybe String
callDefect low =
  let errs = errorKinds (answers low)
      resps = responseKinds (answers low)
  in case errs of
       (e1 :: e2 :: _) => Just "two `answer error` records"
       _ => if any (\k => elem k errs) resps then Just "a kind both a response and the error"
            else case filter (\s => not (responseDeclared resps (oResponse s))) (callsites low) of
              (s :: _) => Just ("callsite " ++ show (oRule s) ++ " " ++ show (oSite s) ++ " names a response kind no answer record declares")
              [] => if isNil errs && not (isNil (callsites low) && isNil resps)
                      then Just "no `answer error` record beside the calls"
                      else Nothing

||| A call site of the model (Rete/NetworkCall.idr's `Lcrs_6_2_1__site`) from
||| its record: the gate's key and the arguments evaluated over the fired
||| match by Rete/Eval.idr, the key CODED as a cooldown's is, the correlation
||| the literal's text.
siteOf : OTables -> OSite -> (Nat, Lcrs_6_2_1__site)
siteOf tb s =
  (oSite s, MkSite (oPosition s) (gateOf (oWindow s)) (oResponse s) (\_ => oCorr s)
                   (\fs => map (iret_7_6__eval (valueDecodeWith tb) fs) (oArgs s)))
  where
    gateOf : Maybe Nat -> Maybe (Nat, Iret_7_1__token -> Nat)
    gateOf Nothing  = Nothing
    gateOf (Just w) = Just (w, \fs => maybe trapId (valueCodeWith tb) (evalAll (valueDecodeWith tb) fs (oKeys s)))

||| THE SITES BY ORDINAL, in rule order, each rule's in site order, as
||| Rete/NetworkCall.idr's `lcrs_6_2_1__sites_at` reads them.
sitesOf : Lowered -> List (List (Nat, Lcrs_6_2_1__site))
sitesOf low = map (\(o, _) => map (siteOf (tablesOf low)) (filter (\s => oRule s == o) (callsites low))) (ruleNames low)

||| The service a site calls, for the `call` line.
serviceOf : Lowered -> Nat -> Nat -> String
serviceOf low o n = case filter (\s => oRule s == o && oSite s == n) (callsites low) of
  (s :: _) => oService s
  []       => "?"

-- ---------------------------------------------------------------------
-- Running the steps
-- ---------------------------------------------------------------------

fixtureFuel : Nat
fixtureFuel = 100000

showFact : Lfac_1_7_1__fact -> String
showFact f = "fact " ++ show (fid f) ++ " " ++ show (fkind f) ++ " " ++ show (fkey f) ++ " " ++ show (fpay f)

||| The working memory of the clocked network engine.
wmOf : Iret_19_3__clocked_net -> Rarc_5_6_4__wm
wmOf cs = ewm (ncore (nengine cs))

||| Whether a fact is of a synthetic kind: printed by nothing (the header's
||| AFTER TIMERS).
isSynthetic : Lowered -> Lfac_1_7_1__fact -> Bool
isSynthetic low f = elem (fkind f) (synthetics low)

||| The working memory as the engine lists it: the facts of a synthetic kind
||| left out, as libds lists none ([RFCS.6a.5]).
listedWm : Lowered -> Iret_19_3__clocked_net -> Rarc_5_6_4__wm
listedWm low cs = filter (not . isSynthetic low) (wmOf cs)

printState : Lowered -> Iret_19_3__clocked_net -> IO ()
printState low cs = do
  traverse_ (putStrLn . showFact) (listedWm low cs)
  putStrLn ("count " ++ show (length (listedWm low cs)))

ruleName : Lowered -> Nat -> String
ruleName low o = case lookupNat o (ruleNames low) of
  Just n  => n
  Nothing => "?"

||| A value as the `value` records spell it: a Float by its bits, raw --
||| the sign of a zero is kept here, where nothing is compared; a String by
||| the token of its text, or, for a text no table holds (a render the
||| evaluator computed, which the lowering never admits into a log site),
||| by its codepoints after `t:`, which no reader renders.
showValueTok : List (Nat, Lstr_1_1__text) -> Lnul_2_1__value -> String
showValueTok txts (VInt n)      = "i:" ++ show n
showValueTok txts (VFloat x)    = "f:" ++ show (doubleBits x)
showValueTok txts (VStr t)      = case tokenOfText txts t of
  Just tok => "s:" ++ show tok
  Nothing  => "t:" ++ concat (intersperse "," (map show t))
showValueTok txts (VBool True)  = "b:1"
showValueTok txts (VBool False) = "b:0"
showValueTok txts (VJson _)     = "j"
showValueTok txts VNull         = "n"

showResultTok : List (Nat, Lstr_1_1__text) -> Lerr_1_4_1__result -> String
showResultTok txts (RVal v) = showValueTok txts v
showResultTok txts RTrap    = "trap"

||| A firing's line: its ordinal, its rule's name and the ids of the facts
||| it matched, a synthetic kind's left out -- the follow-up of an `after`
||| clause matches its timer alone and is factless on the stream
||| ([NCBK.2.6]); its effects are still evaluated over the whole token.
showFiring : Lowered -> (Nat, List Lfac_1_7_1__fact) -> String
showFiring low (o, fs) =
  "fired " ++ show o ++ " " ++ ruleName low o ++ concatMap (\f => " " ++ show (fid f)) (filter (not . isSynthetic low) fs)

isTrap : Lerr_1_4_1__result -> Bool
isTrap RTrap    = True
isTrap (RVal _) = False

||| One `log` of the fired rule, its sites already evaluated over the fired
||| facts by Rete/Eval.idr, exactly as an `emitx` slot is.
showEffect : Lowered -> Nat -> Nat -> List Lerr_1_4_1__result -> String
showEffect low o i rs =
  "effect " ++ show o ++ " " ++ show i ++ concatMap (\r => " " ++ showResultTok (texts low) r) rs

||| The fired rule's logs that RUN: in index order, up to the first whose
||| sites trap. A trap in an action abandons the activation at that action,
||| the actions before it stand and the actions after it do not run
||| ([LNUL.11.1]'s prefix rule; [LERR.1.4], [LEXP.7.12.1]), so the trapping
||| log and every log after it print nothing. The firing itself stands:
||| libds records RULE_FIRE_BEGIN and then the fault, and `fired` is printed
||| above (`LEXP.6.2.len_of_a_whole_json_object_slot_is_a_type_error`).
effectsOf : Lowered -> Nat -> List Lfac_1_7_1__fact -> List String
effectsOf low o fs = go (logsOf low o)
  where
    go : List (Nat, List Iret_7_5__expr) -> List String
    go [] = []
    go ((i, es) :: rest) =
      let rs = map (iret_7_6__eval (valueDecodeWith (tablesOf low)) fs) es
      in if any isTrap rs then [] else showEffect low o i rs :: go rest

||| A CALL LINE: the issued call's rule, site, service, correlation (as a
||| `value` token) and arguments, as the record carries them ([NCBK.6.9];
||| the header's CALLS).
showCall : Lowered -> Ncbk_6_9__call_record -> String
showCall low rec =
  "call " ++ show (crule rec) ++ " " ++ show (csite rec) ++ " " ++ serviceOf low (crule rec) (csite rec)
    ++ " " ++ showValueTok (texts low) (VStr (ccorr rec)) ++ concatMap (\r => " " ++ showResultTok (texts low) r) (cargs rec)

||| A firing: its `fired` line, then, when the rule's gate admitted it, one
||| `call` line per call it issued (a site its own gate refused issued none)
||| and its effects; or `gated` and nothing else when the gate refused the
||| actions ([LCDB.3.2.1.1]).
printFiring : Lowered -> Lcrs_6_2_1__firing -> IO ()
printFiring low ((o, fs, True), recs) = do
  putStrLn (showFiring low (o, fs))
  traverse_ (putStrLn . showCall low) recs
  traverse_ putStrLn (effectsOf low o fs)
printFiring low ((o, fs, False), recs) = do
  putStrLn (showFiring low (o, fs))
  putStrLn ("gated " ++ show o)

showHalt : Iret_11_4__halt -> String
showHalt Quiescent = "halt quiescent"
showHalt FuelOut   = "halt fuelout"

||| The fact a labelled assert left live under its identity: the one
||| appended for an explicit kind, the one at the key for an entity, the
||| identical one for a relation.
labelFact : Lscp_1_3__lifecycle -> Nat -> Nat -> Nat -> Rarc_5_6_4__wm -> Maybe Nat
labelFact Explicit k key pay wm = map fid (last' wm)
labelFact Entity   k key pay wm = map fid (iret_19_1__find_entity k key wm)
labelFact Relation k key pay wm = map fid (iret_19_1__find_relation k key pay wm)

||| The clocked net of a timed state.
netOf : Ltim_2_4_1__timed_state -> Iret_19_3__clocked_net
netOf = ltim_2_4_1__net_of

||| The steps, on Rete/NetworkCall.idr's called engine -- Rete/NetworkTimed.idr's
||| state (the clocked network with the rate trackers, the wall sample and the
||| entry stamps beside it) with the call trackers beside: a tick through
||| `lcrs_6_2_1__tick_called`, a wall step through `lcrs_6_2_1__wall_called`,
||| a data event through `lcrs_6_2_4__arrive_timed` (the arrival's sweep,
||| then the timed input), a pump through `lcrs_6_2_1__pump_called` (the
||| re-time at the held sample, then the traced gated pump with each firing's
||| call sites). With no site and no `corr` these are the timed engine's
||| (the header's CALLS).
execute : Lowered -> Lcyc_3_2_1__program -> Iret_4_2__ttl -> List Lcdb_3_2_1__cool -> List (Maybe Ltim_2_4_1__ttest) ->
          Lcrs_4_3_2__corr_of -> Lcrs_4_2_2__answers -> List (List (Nat, Lcrs_6_2_1__site)) ->
          Nat -> List (String, Nat) -> Lcrs_6_2_1__called_state -> List OStep -> IO ()
execute low pg ttl cools tests corrOf ans sites n labels s [] = pure ()
execute low pg ttl cools tests corrOf ans sites n labels s (OAssert label k key pay :: rest) = do
  putStrLn ("step " ++ show n ++ " assert " ++ label)
  let s' = lcrs_6_2_4__arrive_timed pg ttl (valueDecodeWith (tablesOf low)) corrOf ans (Assert k key pay) s
  let labels' = case labelFact (lifeOf (lifes low) k) k key pay (wmOf (netOf (fst s'))) of
                  Just i  => (label, i) :: labels
                  Nothing => labels
  printState low (netOf (fst s'))
  execute low pg ttl cools tests corrOf ans sites (S n) labels' s' rest
execute low pg ttl cools tests corrOf ans sites n labels s (ORetract label :: rest) = do
  putStrLn ("step " ++ show n ++ " retract " ++ label)
  case lookup label labels of
    Nothing => do putStrLn ("fixture: no fact under label " ++ label)
                  exitWith (ExitFailure 2)
    Just i => do
      let s' = lcrs_6_2_4__arrive_timed pg ttl (valueDecodeWith (tablesOf low)) corrOf ans (Retract i) s
      printState low (netOf (fst s'))
      execute low pg ttl cools tests corrOf ans sites (S n) labels s' rest
execute low pg ttl cools tests corrOf ans sites n labels s (OTick t :: rest) = do
  putStrLn ("step " ++ show n ++ " tick " ++ show t)
  let s' = lcrs_6_2_1__tick_called pg ttl t s
  printState low (netOf (fst s'))
  execute low pg ttl cools tests corrOf ans sites (S n) labels s' rest
execute low pg ttl cools tests corrOf ans sites n labels s (OWall w :: rest) = do
  putStrLn ("step " ++ show n ++ " wall " ++ show w)
  let s' = lcrs_6_2_1__wall_called w s
  printState low (netOf (fst s'))
  execute low pg ttl cools tests corrOf ans sites (S n) labels s' rest
execute low pg ttl cools tests corrOf ans sites n labels s (OPump :: rest) = do
  putStrLn ("step " ++ show n ++ " pump")
  let (s', h, trace) = lcrs_6_2_1__pump_called pg ttl cools (valueDecodeWith (tablesOf low)) corrOf ans sites tests fixtureFuel s
  traverse_ (printFiring low) trace
  putStrLn (showHalt h)
  printState low (netOf (fst s'))
  execute low pg ttl cools tests corrOf ans sites (S n) labels s' rest

||| `covering`, not total: `readFile` runs on `Data.Fuel.forever`, which the
||| totality checker cannot see terminate. Nothing else here is partial,
||| and nothing here is a model element.
export
covering
fixtureMain : String -> IO ()
fixtureMain path = do
  Right txt <- readFile path
    | Left err => do putStrLn ("fixture: cannot read " ++ path ++ ": " ++ show err)
                     exitWith (ExitFailure 2)
  case parseAll emptyLowered (lines txt) of
    Left err => do putStrLn ("fixture: " ++ err)
                   exitWith (ExitFailure 2)
    Right low => case timedShapeDefect low of
      Just (o, i) => do putStrLn ("fixture: a clock read in the where of rule " ++ show o ++ " pattern " ++ show i
                                  ++ " on a rule the model does not re-time [LTIM.2.6.1]")
                        exitWith (ExitFailure 2)
      Nothing => case callDefect low of
        Just defect => do putStrLn ("fixture: " ++ defect)
                          exitWith (ExitFailure 2)
        Nothing => do
          let eng = rdsc_4a_5__load (alphasOf low) (rulesOf low)
          let pg = lcyc_3_2_1__program_of (lifeOf (lifes low)) (enet eng)
          putStrLn ("fixture rules " ++ show (length (ruleNames low)) ++ " steps " ++ show (length (steps low)))
          execute low pg (ttlOf (ttls low)) (coolsOf low) (timedOf low) (corrOfLow low) (answersOf low) (sitesOf low) 0 []
                  ((MkSampled (MkClockedNet (MkTmsNet eng []) [] 0) 0 [], []), []) (steps low)

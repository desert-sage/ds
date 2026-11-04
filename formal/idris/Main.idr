-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Worked examples for the formal modules — RUN, not proven.
|||
||| NOT A MODEL MODULE. This file carries no `--@spec` tags and is exempted by
||| name from the clause-tie scanners: Idris fixes the entry point's name as
||| `main`, no clause owns it, and inventing one would be the kind of tie that
||| looks like traceability and is not.
|||
||| WHY THESE ARE HERE AND NOT IN `Wire.idr`. The first version of that module
||| asserted the protobuf guide's own examples as compile-time equalities and
||| none of them typechecked: `div` and `mod` on `Nat` go through `Integral` and
||| do not reduce during elaboration, so the goal came back stuck rather than
||| false. Rewriting the arithmetic into something that reduces -- repeated
||| subtraction, or bit-by-bit tag decoding -- would make them provable and make
||| the DECODER worse, because a field number runs to 536,870,911.
|||
||| So the division is by what is being claimed. A theorem holds for ALL inputs
||| and belongs in the model; a worked example holds for one input and belongs
||| here. Dressing the second as the first only makes it harder to discharge.
|||
||| Every case below is quoted from a specification, with its source named.
module Main

import Protobuf.Wire
import Protobuf.Framing
import Protobuf.Message
import Rete.Expr
import Rete.FireClock
import TwoClocks
import Rete.RateGate
import Rete.ActivationKey
import Lcdb.RuleGlobal
import Rete.FireLoop
import Rete.FireLoopTms
import Rete.RecomputeFire
import Lcyc.Witnesses
import Lcyc.TmsWitnesses
import Rete.Eval
import Fixture
import Data.List
import Data.Maybe
import System

%default total

||| One example: what it claims, and whether the claim held.
record Case where
  constructor MkCase
  label : String
  held  : Bool

||| A varint decode that yielded a particular value, whatever it left behind.
yielded : Rfcs_19_1__decoded Integer -> Integer -> Bool
yielded (Yield got _) want = got == want
yielded _             _    = False

||| A varint decode that yielded a value AND consumed exactly the input.
yieldedAll : Rfcs_19_1__decoded Integer -> Integer -> Bool
yieldedAll (Yield got []) want = got == want
yieldedAll _              _    = False

||| Wire-type equality, written out rather than derived: six constructors, and
||| an `Eq` implementation would be more code than this.
sameWire : Rfcs_19_1__wire_type -> Rfcs_19_1__wire_type -> Bool
sameWire VARINT VARINT = True
sameWire I64    I64    = True
sameWire LEN    LEN    = True
sameWire SGROUP SGROUP = True
sameWire EGROUP EGROUP = True
sameWire I32    I32    = True
sameWire _      _      = False

||| A tag decode that yielded a particular field number and wire type.
taggedAs : Rfcs_19_1__decoded Rfcs_19_1__tag -> Integer -> Rfcs_19_1__wire_type -> Bool
taggedAs (Yield t _) fld wt = fieldNumber t == fld && sameWire (wireType t) wt
taggedAs _           _   _  = False

||| A decode that refused, for any reason.
refused : Rfcs_19_1__decoded a -> Bool
refused (Refuse _) = True
refused _          = False

||| Answer equality, written out: four constructors.
sameAnswer : Lnul_4_2__answer -> Lnul_4_2__answer -> Bool
sameAnswer KTrue  KTrue  = True
sameAnswer KFalse KFalse = True
sameAnswer KNull  KNull  = True
sameAnswer KTrap  KTrap  = True
sameAnswer _      _      = False

||| An expression that evaluated to a particular Int.
evalsToInt : Iret_7_6__env -> List Lfac_1_7_1__fact -> Iret_7_5__expr -> Integer -> Bool
evalsToInt env fs e n = case iret_7_6__eval env fs e of
  RVal (VInt m) => m == n
  _             => False

||| A test that answered a particular one of the four.
answers : Iret_7_6__env -> List Lfac_1_7_1__fact -> Iret_7_5__expr -> Lnul_4_2__answer -> Bool
answers env fs e a = sameAnswer (iret_7_6__answer env fs e) a

||| An expression that evaluated to a Float equal, by IEEE `==`, to `x`.
floatEq : Iret_7_5__expr -> Double -> Bool
floatEq e x = answers valueDecode [] (ECmp OpEq e (ELit (VFloat x))) KTrue

||| An expression whose value answers `is <subject>`.
isA : Iret_7_5__expr -> Lnul_4_9__subject -> Bool
isA e s = answers valueDecode [] (EIs False s e) KTrue

||| A zero, told apart by its reciprocal: `+0.0` divides 1.0 to `+Inf`,
||| `-0.0` to `-Inf` ([LDET.3.6.2]).
isPosZero : Iret_7_5__expr -> Bool
isPosZero e = floatEq e 0.0 && isA (EArith OpDiv (ELit (VFloat 1.0)) e) IsInf

isNegZero : Iret_7_5__expr -> Bool
isNegZero e = floatEq e 0.0 && isA (EArith OpDiv (ELit (VFloat 1.0)) e) IsNegInf

||| A trap the fragment cannot write but the evaluator must order: the model
||| cannot order two Bools (the residue in Rete/Eval.idr's header; the
||| compiler refuses the form).
trapExpr : Iret_7_5__expr
trapExpr = ECmp OpLt (ELit (VBool True)) (ELit (VBool False))

||| libds's word: eight little-endian bytes of a 64-bit count (`rk_feed_u64`,
||| rete/adapters.c). Division on `Nat` does not reduce during elaboration,
||| so Rete/ActivationKey.idr takes the codec at its contract and this file
||| runs the real one. The arithmetic is Integer's, as Protobuf/Wire.idr's and
||| Rete/Eval.idr's is: `Nat` has no `Integral` in Idris 2's prelude.
wordLE : Nat -> List Nat
wordLE n = go 8 (the Integer (cast n))
  where
    go : Nat -> Integer -> List Nat
    go Z     _ = []
    go (S k) m = the Nat (cast (m `mod` 256)) :: go k (m `div` 256)

||| The word read back: eight bytes, least significant first.
unwordLE : List Nat -> Maybe (Nat, List Nat)
unwordLE bs = go 8 0 1 bs
  where
    go : Nat -> Nat -> Nat -> List Nat -> Maybe (Nat, List Nat)
    go Z     acc _     rest        = Just (acc, rest)
    go (S k) acc scale (b :: rest) = go k (acc + b * scale) (scale * 256) rest
    go (S k) _   _     []          = Nothing

||| The real codec, as Rete/ActivationKey.idr's theorems take one.
realWord : Rlow_4_6_2_1__word
realWord = MkWord wordLE unwordLE

||| A decoded key that is the one wanted, under the clause's identity.
decodesToKey : Maybe Rlow_4_6_2_1__key -> Rlow_4_6_2_1__key -> Bool
decodesToKey (Just k) want = rlow_4_6_2_1__same_b k want
decodesToKey Nothing  _    = False

||| One component of every representation, small enough to run: `Nat` is
||| Peano at run time (IDRIS_MODEL_GUIDE), so no 64-bit pattern appears here.
everyRepresentation : Rlow_4_6_2_1__key
everyRepresentation = [PNull, PInt 7, PFloat 2, PBool False, PStr [0x61], PBytes [0, 255],
                       PJson [0x7b, 0x7d], PFact 3, PRatio 1 2]

||| The codepoints of a string, for the examples that spell a text in
||| source: the runner's `unpack`, a worked example's convenience and not a
||| model element.
cps : String -> Lstr_1_1__text
cps s = map (\c => cast (the Integer (cast (ord c)))) (unpack s)

||| A String value standing for a token of an input with no `string`
||| records: the opaque text Fixture.idr's THE STRING TABLE gives it.
tok : Nat -> Lnul_2_1__value
tok n = VStr (textOfToken [] n)

ptext : Nat -> Lstr_1_1__text
ptext n = textOfToken [] n

||| A double rendered by [LCST.4.5.6]'s `Float :: String` as a given text.
rendersAs : Double -> String -> Bool
rendersAs x s = case lcst_4_5_6__render_float x of
  RVal (VStr t) => t == cps s
  _             => False

||| Two doubles equal by IEEE `==` and, when zero, of one sign.
sameDouble : Double -> Double -> Bool
sameDouble y x = y == x && (y /= 0.0 || (1.0 / y < 0.0) == (1.0 / x < 0.0))

||| A text parsed by [LCST.4.5.8]'s `String :: Float?` to a given double.
parsesTo : String -> Double -> Bool
parsesTo s x = case lcst_4_5_8__parse_float (cps s) of
  Just y  => sameDouble y x
  Nothing => False

||| A text the parse refuses: `null`.
parsesNull : String -> Bool
parsesNull s = isNothing (lcst_4_5_8__parse_float (cps s))

||| A double whose canonical text parses back to it, the sign of a zero
||| included.
roundTrips : Double -> Bool
roundTrips x = case lcst_4_5_6__render_float x of
  RVal (VStr t) => case lcst_4_5_8__parse_float t of
                     Just y  => sameDouble y x
                     Nothing => False
  _             => False

||| The IEEE quotients the Float cases pin: `1.5 / 0.0`, `-1.5 / 0.0` and
||| `0.0 / 0.0`. An infinity is the value that equals its own double and
||| has a sign; a NaN the one unequal to itself (dsexpr.k's `div_zero_*`).
infQ : Iret_7_5__expr
infQ = EArith OpDiv (ELit (VFloat 1.5)) (ELit (VFloat 0.0))

negInfQ : Iret_7_5__expr
negInfQ = EArith OpDiv (ENeg (ELit (VFloat 1.5))) (ELit (VFloat 0.0))

nanQ : Iret_7_5__expr
nanQ = EArith OpDiv (ELit (VFloat 0.0)) (ELit (VFloat 0.0))

||| `-0.0` by arithmetic rather than by a literal: `0.0 * -1.0`.
negZero : Double
negZero = 0.0 * (-1.0)

||| Facts for the evaluator's examples, their slot tuples coded by the value
||| code of Fixture.idr: kind 5 keyed by a String token with no payload, kind 6
||| keyed by a String token and carrying an Int or a null payload. Tokens 11
||| and 12 stand for "a" and "b".
factA5 : Lfac_1_7_1__fact
factA5 = MkFact 0 5 (valueCode [tok 11]) (valueCode [])

factA6 : Lfac_1_7_1__fact
factA6 = MkFact 1 6 (valueCode [tok 11]) (valueCode [VInt 42])

factB6 : Lfac_1_7_1__fact
factB6 = MkFact 1 6 (valueCode [tok 12]) (valueCode [VNull])

||| A decode that gave exactly this tuple.
decodesTo : Nat -> List Lnul_2_1__value -> Bool
decodesTo i vs = case valueDecode i of
  Just got => sameValues got vs
  Nothing  => False

||| The Int extremes, [LEXP.7.13.1]'s range.
int64Max : Integer
int64Max = 9223372036854775807

int64Min : Integer
int64Min = -9223372036854775808

||| The JSON leaf examples' documents: the probe json.json's
||| document with its keys and string leaf as tokens -- nulled 20, n 21,
||| s 22, x 23, b 24, f 25, o 26, k 27, arr 28, z 29 -- as written, with
||| `-0.0` under z (`docRaw`), and folded as the fixture runner folds every
||| document it reads ([LGRA.5.8.8], `docJ`); and `{k: 1}` alone (`docK`).
||| A `json` table names the folded document by token 30 and `docK` by 32,
||| as the Idris model's input would; the raw one by 31 in a table of its own, so
||| a leaf read of it shows the sign the fold removes.
docRaw : Lgra_5_8_1__json
docRaw = JObj [ (20, JNull), (21, JInt 3), (22, JStr (ptext 23)), (24, JBool True)
              , (25, JFloat 2.5), (26, JObj [(27, JInt 1)])
              , (28, JArr [JInt 1, JInt 2]), (29, JFloat negZero) ]

docJ : Lgra_5_8_1__json
docJ = lgra_5_8_8__unsigned_zeros docRaw

docK : Lgra_5_8_1__json
docK = JObj [(27, JInt 1)]

jsonsJ : List (Nat, Lgra_5_8_1__json)
jsonsJ = [(30, docJ), (32, docK)]

tablesJ : OTables
tablesJ = MkTables jsonsJ []

tablesR : OTables
tablesR = MkTables [(31, docRaw)] []

envJ : Iret_7_6__env
envJ = valueDecodeWith tablesJ

envR : Iret_7_6__env
envR = valueDecodeWith tablesR

||| Facts of kinds 7 and 8 keyed by a String token, each carrying one
||| document as its payload.
factJ : Lfac_1_7_1__fact
factJ = MkFact 2 7 (valueCode [tok 11]) (valueCodeWith tablesJ [VJson docJ])

factK : Lfac_1_7_1__fact
factK = MkFact 3 8 (valueCode [tok 12]) (valueCodeWith tablesJ [VJson docK])

factR : Lfac_1_7_1__fact
factR = MkFact 4 7 (valueCode [tok 11]) (valueCodeWith tablesR [VJson docRaw])

||| The real-strings examples' table: the probe strings.json's
||| texts under the tokens the lowering mints for them (0 to 19), and four
||| more (40 to 43) for the cases the probe does not reach, so a String slot
||| is read through a `string` table as the Idris model reads one. Facts of kind
||| 9 keyed by `a` and carrying one String payload each.
textsS : List (Nat, Lstr_1_1__text)
textsS = [ (0, cps "M"), (1, cps "abc"), (2, cps "42"), (3, cps "true"), (4, cps "é")
         , (5, cps "a"), (6, cps "Z"), (8, cps "ab"), (10, cps "0x1F"), (12, cps "3_1")
         , (17, cps "31_"), (19, cps "-0x1F"), (40, cps "😀"), (41, cps "～")
         , (42, cps "9223372036854775808"), (43, cps "-9223372036854775808") ]

tablesS : OTables
tablesS = MkTables [] textsS

envS : Iret_7_6__env
envS = valueDecodeWith tablesS

||| A kind-9 fact keyed `a` whose one payload slot is the String of token `t`.
factS : Nat -> Lfac_1_7_1__fact
factS t = MkFact 5 9 (valueCodeWith tablesS [VStr (cps "a")]) (valueCodeWith tablesS [VStr (textOfToken textsS t)])

||| The payload slot of the first binding.
slot0 : Iret_7_5__expr
slot0 = ESlot 0 False 0

||| The document's slot (the first binding's payload) and a path of member
||| keys into it.
docSlot : Iret_7_5__expr
docSlot = ESlot 0 False 0

leafAt : List Nat -> Iret_7_5__expr
leafAt ks = EPath (map SKey ks) docSlot

||| A decode under the `json` table that gave exactly this document.
decodesToDoc : Nat -> Lgra_5_8_1__json -> Bool
decodesToDoc i d = case valueDecodeWith tablesJ i of
  Just [VJson got] => lfac_2_5_1__json_eq got d
  _                => False

||| The trace: the seed, `gap__grow` closing a `logical` Reach over two
||| edges, then a rule that WITHDRAWS the seed and emits a Probe in the same
||| RHS, and an alarm on a Probe with any Reach. The withdrawal ends the
||| closure's only grounded support mid-pump; Probe and Alarm are explicit.
probeRule : Lgra_6_1__rule
probeRule = MkRule [lcyc_3_2_2__k_seed] (const True) [] [Withdraw 0, Emit 8 (\_ => (0, 0))]

alarmRule : Lgra_6_1__rule
alarmRule = MkRule [8, lcyc_3_2_2__k_reach] (const True) [] [Emit 9 (\_ => (0, 0))]

alarmProg : Lcyc_3_2_1__program
alarmProg = MkProgram (gap__reach_life Relation) [iret_12_1__seed_rule, gap__grow, probeRule, alarmRule]

||| The same seed and withdrawal with no recursion: support stays acyclic.
flatProg : Lcyc_3_2_1__program
flatProg = MkProgram (gap__reach_life Relation) [iret_12_1__seed_rule, lscp_2_1_1__spend_rule]

countKind : Nat -> Iret_12__state -> Nat
countKind k s = length (filter (\f => fkind f == k) (wm (core s)))

quiet : (Iret_12__state, Iret_11_4__halt, Nat) -> Bool
quiet (_, Quiescent, _) = True
quiet _ = False

tmsRun : Lcyc_3_2_1__program -> (Iret_12__state, Iret_11_4__halt, Nat)
tmsRun p = iret_11_4__run_tms p 50 (rarc_5_6_5__init_tms p iret_12_1__reach_input)

rdRun : Lcyc_3_2_1__program -> (Iret_12__state, Iret_11_4__halt, Nat)
rdRun p = gap__run_rd p 50 (rarc_5_6_5__init_tms p iret_12_1__reach_input)

cases : List Case
cases =
  [ -- https://protobuf.dev/programming-guides/encoding/ — the guide's own
    -- worked example: "the number 150 would be encoded as 96 01", and 300 as
    -- `AC 02`, least-significant 7-bit group first.
    MkCase "varint: 0xAC 0x02 is 300"
           (yieldedAll (rfcs_19_1__varint [172, 2]) 300)
  , MkCase "varint: 0x96 0x01 is 150"
           (yieldedAll (rfcs_19_1__varint [150, 1]) 150)
  , MkCase "varint: a single byte below 0x80 is itself"
           (yieldedAll (rfcs_19_1__varint [5]) 5)
  , MkCase "varint: 0x00 is zero, not absent"
           (yieldedAll (rfcs_19_1__varint [0]) 0)
  , MkCase "varint: trailing bytes are left for the caller"
           (yielded (rfcs_19_1__varint [5, 99, 99]) 5)

    -- The four silences. Google's encoding page states no rule for any of
    -- these; Wire.idr decides them explicitly and these pin the decisions.
  , MkCase "varint: empty input is truncated"
           (refused (rfcs_19_1__varint []))
  , MkCase "varint: a continuation bit with nothing after it is truncated"
           (refused (rfcs_19_1__varint [128]))
  , MkCase "varint: eleven continuation bytes is overlong"
           (refused (rfcs_19_1__varint
                      [255,255,255,255,255,255,255,255,255,255,1]))
  , MkCase "varint: a tenth byte above bit 63 overflows"
           (refused (rfcs_19_1__varint
                      [255,255,255,255,255,255,255,255,255,4]))

    -- Tags. "(field_number << 3) | wire_type", and proto3's range "between 1
    -- and 536,870,911".
  , MkCase "tag: 0x0A is field 1, LEN — the DS outer frame [RFCS.19.1]"
           (taggedAs (rfcs_19_1__tag [10]) 1 LEN)
  , MkCase "tag: 0x08 is field 1, VARINT"
           (taggedAs (rfcs_19_1__tag [8]) 1 VARINT)
  , MkCase "tag: 0x0D is field 1, I32"
           (taggedAs (rfcs_19_1__tag [13]) 1 I32)
  , MkCase "tag: 0x09 is field 1, I64"
           (taggedAs (rfcs_19_1__tag [9]) 1 I64)
  , MkCase "tag: field 0 is refused"
           (refused (rfcs_19_1__tag [0]))
  , MkCase "tag: wire type 6 is unassigned and refused"
           (refused (rfcs_19_1__tag [14]))
  , MkCase "tag: wire type 7 is unassigned and refused"
           (refused (rfcs_19_1__tag [15]))
    -- 19,000 is the first RESERVED field number. Accepted on the wire on
    -- purpose: proto3 reserves 19,000-19,999 for the implementation and says
    -- "the protocol buffer compiler will complain if you use one" — a rule
    -- about what a `.proto` may DECLARE, not about what may travel.
    --
    -- (19000 << 3) | 0 = 152000, which is [0xC0, 0xA3, 0x09]. THE FIRST
    -- VERSION OF THIS CASE HAD [128, 189, 9] AND FAILED — bytes I computed by
    -- hand rather than took from a source, and they decode to field 19408.
    -- The decoder was right and the test was wrong, which is the failure mode
    -- worth noticing: every vector above that is quoted from the guide (300 as
    -- `AC 02`, 150 as `96 01`) is independently checked, and every one I
    -- derived myself is a second claim needing its own scrutiny.
  , MkCase "tag: a reserved field number (19000) is ACCEPTED on the wire"
           (taggedAs (rfcs_19_1__tag [192, 163, 9]) 19000 VARINT)

    -- ZigZag. "Positive integers p are encoded as 2 * p (the even numbers),
    -- while negative integers n are encoded as 2 * |n| - 1 (the odd numbers)."
  , MkCase "zigzag: 0 is 0"       (rfcs_19_1__unzigzag 0 == 0)
  , MkCase "zigzag: 1 is -1"      (rfcs_19_1__unzigzag 1 == -1)
  , MkCase "zigzag: 2 is 1"       (rfcs_19_1__unzigzag 2 == 1)
  , MkCase "zigzag: 3 is -2"      (rfcs_19_1__unzigzag 3 == -2)
  , MkCase "zigzag: 4294967294 is 2147483647"
           (rfcs_19_1__unzigzag 4294967294 == 2147483647)
  , MkCase "zigzag: 4294967295 is -2147483648"
           (rfcs_19_1__unzigzag 4294967295 == -2147483648)

    -- LEN payloads: "a varint immediately after the tag, which is followed by
    -- the payload as usual."
  , MkCase "len: a two-byte payload is taken exactly"
           (case rfcs_19_1__len_payload [2, 65, 66, 67] of
              Yield got rest => got == [65, 66] && rest == [67]
              Refuse _       => False)
  , MkCase "len: a zero-length payload is empty, not absent"
           (case rfcs_19_1__len_payload [0, 65] of
              Yield got rest => got == [] && rest == [65]
              Refuse _       => False)
  , MkCase "len: a payload longer than the input is truncated"
           (refused (rfcs_19_1__len_payload [9, 65]))

    -- `take` from an empty input. This WAS a theorem in Wire.idr, quantified
    -- over `(n : Nat)` and discharged by `Refl`; it stopped being provable when
    -- the count became an `Integer`, because stating it needs a positivity
    -- hypothesis and discharging that needs reasoning about primitive Integer
    -- comparison. It moved here rather than acquiring a `believe_me` — a
    -- declared hole, in a module whose whole claim is that it has none.
  , MkCase "take: a positive count from nothing is truncated"
           (refused (rfcs_19_1__take 1 []))
  , MkCase "take: zero from nothing yields nothing"
           (case rfcs_19_1__take 0 [] of
              Yield got rest => got == [] && rest == []
              Refuse _       => False)

    -- THE FRAMING [RFCS.19.1]. `frame = outer_tag , varint_len , atom` and
    -- `atom = oneof_tag , varint_len , body`. One frame carrying atom field 32
    -- (oneof_tag = 32 << 3 | 2 = 258 = [0x82, 0x02]) with a two-byte body:
    --
    --   0A            outer tag, field 1 wire type 2
    --   05            frame length: five bytes of atom follow
    --   82 02         oneof_tag: field 32, wire type LEN
    --   02            body length
    --   41 42         body
  , MkCase "frame: one atom, identity and body recovered"
           (case rfcs_19_1__frame [10, 5, 130, 2, 2, 65, 66] of
              Yield f rest => identity f == 32 && body f == [65, 66] && rest == []
              Refuse _     => False)
  , MkCase "frame: a wrong outer tag is refused"
           (case rfcs_19_1__frame [11, 5, 130, 2, 2, 65, 66] of
              Refuse _ => True
              Yield _ _ => False)
  , MkCase "frame: an inner tag that is not LEN is refused"
           -- oneof_tag 0x80 0x02 is field 32 wire type VARINT, not LEN.
           (case rfcs_19_1__frame [10, 5, 128, 2, 2, 65, 66] of
              Refuse _ => True
              Yield _ _ => False)

    -- The walk, and the truncation policies [RFCS.19.2].
  , MkCase "walk: an empty container is complete, not truncated"
           (case rfcs_19_1__walk TruncationIsError [] of
              Complete [] => True
              _           => False)
  , MkCase "walk: two frames are read in order"
           (case rfcs_19_1__walk TruncationIsError
                   [10, 5, 130, 2, 2, 65, 66, 10, 5, 138, 2, 2, 67, 68] of
              Complete fs => map identity fs == [32, 33]
              _           => False)
  , MkCase "walk: a partial trailing frame is EOF for a Stream"
           (case rfcs_19_1__walk EndOfStream [10, 5, 130, 2, 2, 65, 66, 10, 5] of
              EndedEarly fs n => map identity fs == [32] && n == 2
              _               => False)
  , MkCase "walk: a tail that is only the outer tag is EOF for a Stream"
           (case rfcs_19_1__walk EndOfStream [10, 5, 130, 2, 2, 65, 66, 10] of
              EndedEarly fs n => map identity fs == [32] && n == 1
              _               => False)
    -- [RFCS.19.2]'s EOF is a SHORT tail and nothing else. These two are
    -- corrupt, not short, and a Stream refuses them exactly as a Dsc does.
  , MkCase "walk: a wrong byte after a good frame is MALFORMED for a Stream"
           (case rfcs_19_1__walk EndOfStream [10, 5, 130, 2, 2, 65, 66, 11, 0] of
              Malformed fs _ => map identity fs == [32]
              _              => False)
    -- The outer frame is complete (length 3, three bytes follow); the atom
    -- inside it claims a five-byte body. Its truncation is inside a frame
    -- that has fully arrived, so it is a lie, not an unfinished append.
  , MkCase "walk: an atom overrunning its COMPLETE frame is MALFORMED for a Stream"
           (case rfcs_19_1__walk EndOfStream [10, 3, 130, 2, 5] of
              Malformed [] _ => True
              _              => False)
  , MkCase "walk: the same tail is an ERROR for a Dsc"
           (case rfcs_19_1__walk TruncationIsError
                   [10, 5, 130, 2, 2, 65, 66, 10, 5] of
              Malformed fs _ => map identity fs == [32]
              _              => False)
  , MkCase "walk: the container type is the FIRST atom's field number"
           (case rfcs_19_1__walk TruncationIsError [10, 5, 130, 2, 2, 65, 66] of
              Complete fs => rfcs_19_4__container_type fs == Just 32
              _           => False)
  , MkCase "walk: an empty container has NO type"
           (rfcs_19_4__container_type [] == Nothing)

    -- MESSAGE FIELDS. A body carrying field 1 = 7 (varint) and field 4 = "AB"
    -- (LEN): 08 07 22 02 41 42.
  , MkCase "fields: a varint and a LEN field are read in order"
           (case rfcs_19_1__fields [8, 7, 34, 2, 65, 66] of
              Yield fs _ => map number fs == [1, 4]
              Refuse _   => False)
  , MkCase "fields: an unknown field is skippable by wire type"
           -- field 47, I32: 47<<3|5 = 381 = [0xFD, 0x02], then four bytes.
           (case rfcs_19_1__fields [253, 2, 1, 2, 3, 4, 8, 7] of
              Yield fs _ => map number fs == [47, 1]
              Refuse _   => False)
  , MkCase "fields: a group wire type is refused, not skipped"
           -- 1<<3|3 = 11 = SGROUP.
           (case rfcs_19_1__fields [11] of
              Refuse _ => True
              Yield _ _ => False)
  , MkCase "fields: last one wins for a repeated field number"
           (case rfcs_19_1__fields [8, 7, 8, 9] of
              Yield fs _ => case rfcs_19_1__last_field 1 fs of
                              Just f  => value f == VarintV 9
                              Nothing => False
              Refuse _   => False)

    -- Expr.kind [LNUL.2.1]. The oneof exception is what makes the `false` case
    -- reachable at all: proto3 serializes a oneof member even at its default,
    -- so `lit_bool = false` is on the wire as field 4 payload 0.
    --
    -- Field 16 needs a TWO-BYTE tag -- 16 << 3 | 0 = 128, which is past the
    -- one-byte varint ceiling -- so `lit_null` reads [128, 1] then its payload.
    -- Written out because the previous hand-computed vector in this file was
    -- wrong and the decoder was right.
  , MkCase "expr: a boolean literal FALSE is present, not absent"
           (case rfcs_19_1__fields [32, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Just (SBool False)
              Refuse _   => False)
  , MkCase "expr: null is the CASE, payload 1"
           (case rfcs_19_1__fields [128, 1, 1] of
              Yield fs _ => lnul_2_1__kind_of fs == Just SNull
              Refuse _   => False)
    -- THE ONE THAT SEPARATES THE TWO READINGS. Same field, payload 0. A
    -- decoder keyed on the payload answers `SBool False` here and nothing
    -- downstream could tell, because `false` is an ordinary value.
  , MkCase "expr: null is the CASE, payload 0 -- NOT false"
           (case rfcs_19_1__fields [128, 1, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Just SNull
              Refuse _   => False)
  , MkCase "expr: now is the CASE too, payload 0"
           (case rfcs_19_1__fields [88, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Just SNow
              Refuse _   => False)
    -- Last-wins ACROSS field numbers, which is the rule `rfcs_19_1__last_field`
    -- cannot state: lit_bool=true, then lit_null.
  , MkCase "expr: the LAST oneof member wins across field numbers"
           (case rfcs_19_1__fields [32, 1, 128, 1, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Just SNull
              Refuse _   => False)
  , MkCase "expr: an unmodelled member keeps its field number"
           -- binop = 6, wire type 2 (LEN): 6 << 3 | 2 = 50, empty body.
           (case rfcs_19_1__fields [50, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Just (SUninterpreted 6)
              Refuse _   => False)
  , MkCase "expr: a field outside the oneof is not a member of it"
           -- json_tainted = 19 sits in Expr beside the oneof: 19 << 3 | 0 = 152,
           -- a two-byte tag, then payload 1.
           (case rfcs_19_1__fields [152, 1, 1] of
              Yield fs _ => lnul_2_1__kind_of fs == Nothing
              Refuse _   => False)
  , MkCase "expr: a reserved number is not a member"
           -- 9 was str_cat: 9 << 3 | 0 = 72, payload 0.
           (case rfcs_19_1__fields [72, 0] of
              Yield fs _ => lnul_2_1__kind_of fs == Nothing
              Refuse _   => False)
  , MkCase "expr: the last member declared, interp = 20, keeps its number"
           -- 20 << 3 | 0 = 160: a varint where the schema says LEN, so it is
           -- uninterpreted, and it is still the member it names.
           (case rfcs_19_1__fields [160, 1, 1] of
              Yield fs _ => lnul_2_1__kind_of fs == Just (SUninterpreted 20)
              Refuse _   => False)

    -- EVERY ENCOUNTER IN A PUMP RETURNS ONE VALUE [IRET.25.4.1]. The general
    -- property is proven in Rete/FireClock.idr, quantified over the sample,
    -- the firings and the call count. What lives here is the refused reading
    -- beside it on one moving source, which is a test: a per-fire cache that
    -- reads the source at each firing's first encounter.
  , MkCase "fire: three encounters in two firings see the held sample, no call"
           (iret_25_4_1__pump_reads (0, 7) [2, 1] 0 == ([[7, 7], [7]], 0))
  , MkCase "fire: the refused per-fire cache reads the source once per firing"
           (iret_25_4_1__per_fire_pump ltim_2_8_1__ticking [1, 1] 0 == ([[0], [1]], 2))

    -- THE RATE GATE'S REFUSED SENTINEL, WHICH IS FireClock's SHAPE WITH A
    -- REACHABLE COLLISION [RLOW.4.6.2.2]. The general facts are proved in
    -- Rete/RateGate.idr, quantified over the window, the instant and every
    -- non-zero stamp. What lives here is a SCHEDULE — a claim about particular
    -- instants, which is a test rather than a theorem. The clause's spelling
    -- is the honest stamp, and `logical/LCDB.3.2.1_rgate_cool_suppress` pins
    -- the flag libds has where a sentinel would lose the first stamp.
    -- The window is 30 and the activations are at 0, 10, 30, 40.
  , MkCase "rate: from a non-zero start the two spellings agree"
           (rlow_4_6_2_2__run 30 Nothing [1, 11, 31, 41]
              == rlow_4_6_2_2__run_sentinel 30 0 [1, 11, 31, 41])

    -- The same schedule with the first activation at zero. The honest form
    -- stamps `Just 0` and suppresses at 10; the sentinel stores `0`, reads it
    -- as "never fired", and allows.
  , MkCase "rate: the honest stamp suppresses inside the window from zero"
           (rlow_4_6_2_2__run 30 Nothing [0, 10, 30, 40]
              == [True, False, True, False])
  , MkCase "rate: the zero sentinel loses the first stamp and displaces the rest"
           (rlow_4_6_2_2__run_sentinel 30 0 [0, 10, 30, 40]
              == [True, True, False, True])
  , MkCase "rate: so a run that begins at zero diverges"
           (rlow_4_6_2_2__run 30 Nothing [0, 10, 30, 40]
              /= rlow_4_6_2_2__run_sentinel 30 0 [0, 10, 30, 40])

    -- RULE-WIDE SUPPRESSION, WHICH [LCDB.7.2] SAYS DOES NOT EXIST. The general
    -- facts are proved in Lcdb/RuleGlobal.idr, quantified over every value
    -- every activation could bind. These are the clause's own worked example
    -- with numbers in it, which is what a reader checks the theorem against.
    --
    -- `AmbientTemp{ts mutable, celsius mutable}` is [LCDB.3.3.3]'s schema, not
    -- one chosen to make the point.
  , MkCase "rule-global: the all-mutable schema's key is empty"
           (lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp 1000 21) == [])
  , MkCase "rule-global: two unrelated readings share it"
           (lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp 1000 21)
              == lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp 9999 4))
  , MkCase "rule-global: a `key` slot separates what `mutable` cannot"
           (lcdb_3_3_3__key [[(SlotKey, 1)]] /= lcdb_3_3_3__key [[(SlotKey, 2)]])
  , MkCase "rule-global: and a churning `mutable` beside it does not reset"
           (lcdb_3_3_3__key [[(SlotKey, 1), (SlotMutable, 21)]]
              == lcdb_3_3_3__key [[(SlotKey, 1), (SlotMutable, 22)]])

    -- THE ACTIVATION KEY'S IDENTITY [RLOW.4.6.2.1], AND libds's FRAME OVER IT
    -- [IRET.25.5.3]. The general facts are proved in Rete/ActivationKey.idr
    -- over a word codec taken at its contract; here the codec is the real one
    -- -- eight little-endian bytes, `rk_feed_u64` -- whose arithmetic runs
    -- rather than reduces, and the keys are the clause's own examples.
    -- `0x31` is ASCII '1': the retired encoder rendered the integer 1, the
    -- string "1" and the boolean true to that one byte, and `formal/k/rkey.k`
    -- runs the same cases on the identity (`rkey.int_vs_str`,
    -- `rkey.int_vs_bool`, `rkey.str_vs_bool`).
  , MkCase "key: the real codec has the contract the theorems assume, on a word and a tail"
           (unwordLE (wordLE 300 ++ [7, 8]) == Just (300, [7, 8]))
  , MkCase "key: `1`, \"1\" and `true` are three keys, so three byte strings"
           (rlow_4_6_2_1__encode realWord [PInt 1] /= rlow_4_6_2_1__encode realWord [PStr [0x31]]
              && rlow_4_6_2_1__encode realWord [PInt 1] /= rlow_4_6_2_1__encode realWord [PBool True]
              && rlow_4_6_2_1__encode realWord [PStr [0x31]] /= rlow_4_6_2_1__encode realWord [PBool True])
  , MkCase "key: a Time and an Int holding one count are one key, so one byte string"
           (rlow_4_6_2_1__encode realWord [rlow_4_6_2_1__of_time 5] == rlow_4_6_2_1__encode realWord [PInt 5])
  , MkCase "key: a String holding the retired separator byte is one component, not two"
           (rlow_4_6_2_1__encode realWord [PStr [0x61, 1, 0x62]]
              /= rlow_4_6_2_1__encode realWord [PStr [0x61], PStr [0x62]])
  , MkCase "key: a 600-byte String is kept whole and reads back"
           (decodesToKey (rlow_4_6_2_1__decode realWord (rlow_4_6_2_1__encode realWord [PStr (replicate 600 0x61)]))
                         [PStr (replicate 600 0x61)])
  , MkCase "key: a key with a component of every representation reads back as itself"
           (decodesToKey (rlow_4_6_2_1__decode realWord (rlow_4_6_2_1__encode realWord everyRepresentation))
                         everyRepresentation)
    -- THE WHERE EVALUATOR [IRET.7.6] (Rete/Eval.idr). Quantified facts are
    -- proved there; these are the arithmetic, which is Integer and so does
    -- not reduce during elaboration, and the slot reads through the value
    -- code: every fact's key and payload ids are codes, and `valueDecode` is
    -- the environment the Idris model reads them with.
  , MkCase "eval: 3 + 4 is 7"
           (evalsToInt valueDecode [] (EArith OpAdd (ELit (VInt 3)) (ELit (VInt 4))) 7)
  , MkCase "eval: INT64_MAX + 1 wraps to INT64_MIN [LEXP.7.13.1]"
           (evalsToInt valueDecode [] (EArith OpAdd (ELit (VInt int64Max)) (ELit (VInt 1))) int64Min)
  , MkCase "eval: negating INT64_MIN wraps to itself"
           (evalsToInt valueDecode [] (ENeg (ELit (VInt int64Min))) int64Min)
  , MkCase "eval: -3 * 4 is -12"
           (evalsToInt valueDecode [] (EArith OpMul (ENeg (ELit (VInt 3))) (ELit (VInt 4))) (-12))
    -- DIVISION ON Int. The clauses' own examples, run: the floor pair
    -- is Integer arithmetic over the primitive `div`, so each is a worked
    -- example here and the for-all facts (a zero divisor traps, a null
    -- operand is null first) are theorems in Rete/Eval.idr.
  , MkCase "eval: 7 // 2 is 3 and -7 // 2 is -4, not -3 [LEXP.7.5]"
           (evalsToInt valueDecode [] (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt 2))) 3
              && evalsToInt valueDecode [] (EArith OpFloorDiv (ELit (VInt (-7))) (ELit (VInt 2))) (-4))
  , MkCase "eval: 7 // -2 is -4 and -7 // -2 is 3"
           (evalsToInt valueDecode [] (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt (-2)))) (-4)
              && evalsToInt valueDecode [] (EArith OpFloorDiv (ELit (VInt (-7))) (ELit (VInt (-2)))) 3)
  , MkCase "eval: -7 % 3 is 2 and 7 % -2 is -1: the remainder takes the divisor's sign [LEXP.7.6]"
           (evalsToInt valueDecode [] (EArith OpMod (ELit (VInt (-7))) (ELit (VInt 3))) 2
              && evalsToInt valueDecode [] (EArith OpMod (ELit (VInt 7)) (ELit (VInt (-2)))) (-1)
              && evalsToInt valueDecode [] (EArith OpMod (ELit (VInt (-7))) (ELit (VInt 2))) 1
              && evalsToInt valueDecode [] (EArith OpMod (ELit (VInt 6)) (ELit (VInt 3))) 0)
  , MkCase "eval: INT64_MIN // -1 wraps to INT64_MIN and INT64_MIN % -1 is 0 [LEXP.7.13.1]"
           (evalsToInt valueDecode [] (EArith OpFloorDiv (ELit (VInt int64Min)) (ELit (VInt (-1)))) int64Min
              && evalsToInt valueDecode [] (EArith OpMod (ELit (VInt int64Min)) (ELit (VInt (-1)))) 0)
  , MkCase "eval: 7 // 0 and 7 % 0 trap [LEXP.7.15.1]"
           (answers valueDecode [] (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt 0))) KTrap
              && answers valueDecode [] (EArith OpMod (ELit (VInt 7)) (ELit (VInt 0))) KTrap)
  , MkCase "eval: null // 0 is null, the division never performed [LNUL.9.3]"
           (answers valueDecode [] (EArith OpFloorDiv (ELit VNull) (ELit (VInt 0))) KNull
              && answers valueDecode [] (EArith OpMod (ELit (VInt 0)) (ELit VNull)) KNull)
  , MkCase "eval: null + (7 // 0) is the trap, not null [LNUL.4.10]"
           (answers valueDecode [] (EArith OpAdd (ELit VNull)
                                      (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt 0)))) KTrap)
  , MkCase "eval: y != 0 and x // y > 1 is false on a zero y, the guard deciding [LEXP.7.15.2]"
           (answers valueDecode []
                    (EAnd (ECmp OpNe (ELit (VInt 0)) (ELit (VInt 0)))
                          (ECmp OpGt (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt 0))) (ELit (VInt 1)))) KFalse
              && answers valueDecode []
                    (EAnd (ECmp OpGt (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VInt 0))) (ELit (VInt 1)))
                          (ECmp OpNe (ELit (VInt 0)) (ELit (VInt 0)))) KFalse)
    -- `/` AND Float. Double arithmetic reduces only on literals,
    -- so these are worked examples; dsexpr.k's vectors are the cross-check
    -- (div_int_int_value, promote, div_zero_*, cmp_le_float_int).
  , MkCase "eval: 7 / 2 is the Float 3.5, and 7 / 2.0 too [LEXP.7.4]"
           (answers valueDecode []
                    (ECmp OpEq (EArith OpDiv (ELit (VInt 7)) (ELit (VInt 2))) (ELit (VFloat 3.5))) KTrue
              && answers valueDecode []
                    (ECmp OpEq (EArith OpDiv (ELit (VInt 7)) (ELit (VFloat 2.0))) (ELit (VFloat 3.5))) KTrue)
  , MkCase "eval: 7 / 0 traps, the all-Int zero divisor [LEXP.7.15.1]"
           (answers valueDecode [] (EArith OpDiv (ELit (VInt 7)) (ELit (VInt 0))) KTrap)
  , MkCase "eval: 1.5 / 0.0 is +Inf and -1.5 / 0.0 is -Inf, no trap [LDET.3.6.2]"
           (answers valueDecode [] (EAnd (ECmp OpLt (ELit (VFloat 0.0)) infQ)
                                         (ECmp OpEq infQ (EArith OpMul infQ (ELit (VFloat 2.0))))) KTrue
              && answers valueDecode [] (EAnd (ECmp OpLt negInfQ (ELit (VFloat 0.0)))
                                              (ECmp OpEq negInfQ (EArith OpMul negInfQ (ELit (VFloat 2.0))))) KTrue)
  , MkCase "eval: 0.0 / 0.0 is NaN: unequal to itself, and 7 / 0.0 is +Inf, with an Int dividend promoted"
           (answers valueDecode [] (ECmp OpNe nanQ nanQ) KTrue
              && answers valueDecode [] (ECmp OpEq nanQ nanQ) KFalse
              && answers valueDecode [] (ECmp OpLt nanQ (ELit (VFloat 1.0))) KFalse
              && answers valueDecode []
                   (ECmp OpGt (EArith OpDiv (ELit (VInt 7)) (ELit (VFloat 0.0))) (ELit (VFloat 1.0e300))) KTrue)
  , MkCase "eval: 2 < 1 + 2.0, 1 == 1.0 and 3 <= 3.5: an Int beside a Float promotes [LEXP.7.3]"
           (answers valueDecode []
                    (ECmp OpLt (ELit (VInt 2)) (EArith OpAdd (ELit (VInt 1)) (ELit (VFloat 2.0)))) KTrue
              && answers valueDecode [] (ECmp OpEq (ELit (VInt 1)) (ELit (VFloat 1.0))) KTrue
              && answers valueDecode [] (ECmp OpLe (ELit (VInt 3)) (ELit (VFloat 3.5))) KTrue
              && answers valueDecode [] (ECmp OpGt (ELit (VFloat 3.5)) (ELit (VInt 3))) KTrue)
  , MkCase "eval: 2^53 + 1 promotes to the nearest double, 2^53 [LEXP.7.3b]"
           (answers valueDecode []
                    (ECmp OpEq (EArith OpAdd (ELit (VInt 9007199254740993)) (ELit (VFloat 0.0)))
                               (ELit (VFloat 9007199254740992.0))) KTrue)
  , MkCase "eval: -(0.0) is -0.0, equal to 0.0 and the divisor of -Inf [LDET.3.6.2]"
           (answers valueDecode [] (ECmp OpEq (ENeg (ELit (VFloat 0.0))) (ELit (VFloat 0.0))) KTrue
              && answers valueDecode []
                   (ECmp OpLt (EArith OpDiv (ELit (VFloat 1.0)) (ENeg (ELit (VFloat 0.0)))) (ELit (VFloat 0.0))) KTrue)
  , MkCase "eval: null / 0.0 is null, and null % 2.0 too"
           (answers valueDecode [] (EArith OpDiv (ELit VNull) (ELit (VFloat 0.0))) KNull
              && answers valueDecode [] (EArith OpMod (ELit VNull) (ELit (VFloat 2.0))) KNull)
    -- `//` AND `%` WITH A Float OPERAND. The
    -- for-all fact -- a Float for every pair of operands, never a trap -- is
    -- a theorem in Rete/Eval.idr; the values are Double arithmetic and so
    -- run: the clauses' own examples, the fixtures' vectors (CPython 3.12's
    -- answers, whose algorithm the clauses transcribe:
    -- LEXP.7.6.float_composition, LEXP.7.6.float_special_operands,
    -- LEXP.7.15.1.float_floordiv_mod_zero_divisor) and dsexpr.k's.
  , MkCase "eval: -7.5 // 2 is -4.0; 5.5 % 2 is 1.5 and -7.5 % 2 is 0.5: the clauses' examples [LEXP.7.5] [LEXP.7.6]"
           (floatEq (EArith OpFloorDiv (ELit (VFloat (-7.5))) (ELit (VInt 2))) (-4.0)
              && floatEq (EArith OpMod (ELit (VFloat 5.5)) (ELit (VInt 2))) 1.5
              && floatEq (EArith OpMod (ELit (VFloat (-7.5))) (ELit (VInt 2))) 0.5
              && floatEq (EArith OpFloorDiv (ELit (VFloat (-7.5))) (ELit (VFloat 2.0))) (-4.0)
              && floatEq (EArith OpMod (ELit (VFloat 5.5)) (ELit (VFloat 2.0))) 1.5)
  , MkCase "eval: 7 // 2.5 and 7 % 2.5 are 2.0; 0.3 // 0.1 is 2.0 and 0.3 % 0.1 is 0.09999999999999998 (LEXP.7.6.float_composition)"
           (floatEq (EArith OpFloorDiv (ELit (VInt 7)) (ELit (VFloat 2.5))) 2.0
              && floatEq (EArith OpMod (ELit (VInt 7)) (ELit (VFloat 2.5))) 2.0
              && floatEq (EArith OpFloorDiv (ELit (VFloat 0.3)) (ELit (VFloat 0.1))) 2.0
              && floatEq (EArith OpMod (ELit (VFloat 0.3)) (ELit (VFloat 0.1))) 0.09999999999999998)
    -- The fixture's seeded pairs, |a / b| above 2^53, where a composition
    -- through a rounded quotient answers 0.0 for `%`.
  , MkCase "eval: the two large pairs of LEXP.7.6.float_composition, % and //"
           (floatEq (EArith OpMod (ELit (VFloat 4.627487705881677e18)) (ELit (VFloat (-8.270687598131394)))) (-0.9934620030826427)
              && floatEq (EArith OpFloorDiv (ELit (VFloat 4.627487705881677e18)) (ELit (VFloat (-8.270687598131394)))) (-5.595045939018626e17)
              && floatEq (EArith OpMod (ELit (VFloat (-1.013116706381308e18))) (ELit (VFloat (-1.4307167942600465)))) (-0.9473249047597321)
              && floatEq (EArith OpFloorDiv (ELit (VFloat (-1.013116706381308e18))) (ELit (VFloat (-1.4307167942600465)))) 7.0811827361353e17)
  , MkCase "eval: -0.0 % 2.0 is +0.0 and 0.0 % -2.0 is -0.0: a zero remainder takes the divisor's sign (LEXP.7.6.float_special_operands)"
           (isPosZero (EArith OpMod (ENeg (ELit (VFloat 0.0))) (ELit (VFloat 2.0)))
              && isNegZero (EArith OpMod (ELit (VFloat 0.0)) (ENeg (ELit (VFloat 2.0)))))
  , MkCase "eval: -1.0 % inf is +Inf and 1.0 % -inf is -Inf; -1.0 // inf is -1.0; inf % 2.0 is NaN: the infinite operands"
           (isA (EArith OpMod (ENeg (ELit (VFloat 1.0))) infQ) IsInf
              && isA (EArith OpMod (ELit (VFloat 1.0)) negInfQ) IsNegInf
              && floatEq (EArith OpFloorDiv (ENeg (ELit (VFloat 1.0))) infQ) (-1.0)
              && isA (EArith OpMod infQ (ELit (VFloat 2.0))) IsNaN
              && isA (EArith OpFloorDiv infQ (ELit (VFloat 2.0))) IsNaN)
  , MkCase "eval: 5.0 // 0.0 is +Inf, -5.0 // 0.0 -Inf, 0.0 // 0.0 NaN; 5.0 % 0.0 and 7 % 0.0 NaN; 7.5 // 0 +Inf: a Float zero divisor never traps [LEXP.7.15.1]"
           (isA (EArith OpFloorDiv (ELit (VFloat 5.0)) (ELit (VFloat 0.0))) IsInf
              && isA (EArith OpFloorDiv (ENeg (ELit (VFloat 5.0))) (ELit (VFloat 0.0))) IsNegInf
              && isA (EArith OpFloorDiv (ELit (VFloat 0.0)) (ELit (VFloat 0.0))) IsNaN
              && isA (EArith OpMod (ELit (VFloat 5.0)) (ELit (VFloat 0.0))) IsNaN
              && isA (EArith OpMod (ELit (VInt 7)) (ELit (VFloat 0.0))) IsNaN
              && isA (EArith OpFloorDiv (ELit (VFloat 7.5)) (ELit (VInt 0))) IsInf)
  , MkCase "eval: -0.0 // 4.0 is -0.0 and 0.5 // 4.0 is +0.0: a zero quotient takes the sign of a / b [LEXP.7.5]"
           (isNegZero (EArith OpFloorDiv (ENeg (ELit (VFloat 0.0))) (ELit (VFloat 4.0)))
              && isPosZero (EArith OpFloorDiv (ELit (VFloat 0.5)) (ELit (VFloat 4.0))))
  , MkCase "eval: a NaN operand gives NaN under both, and 7.5 // 2 is 3.0, 7.5 % 2 is 1.5"
           (isA (EArith OpMod nanQ (ELit (VFloat 2.0))) IsNaN
              && isA (EArith OpFloorDiv (ELit (VFloat 2.0)) nanQ) IsNaN
              && floatEq (EArith OpFloorDiv (ELit (VFloat 7.5)) (ELit (VInt 2))) 3.0
              && floatEq (EArith OpMod (ELit (VFloat 7.5)) (ELit (VInt 2))) 1.5)
    -- `Product p where p.name == c.product`: an equality anchor between two
    -- bindings' key slots, read through the code.
  , MkCase "eval: an equality anchor between two bindings holds on one token"
           (answers valueDecode [factA5, factA6]
                    (ECmp OpEq (ESlot 0 True 0) (ESlot 1 True 0)) KTrue)
  , MkCase "eval: and fails on another"
           (answers valueDecode [factA5, factB6]
                    (ECmp OpEq (ESlot 0 True 0) (ESlot 1 True 0)) KFalse)
  , MkCase "eval: a payload slot against an Int literal"
           (answers valueDecode [factA6] (ECmp OpGt (ESlot 0 False 0) (ELit (VInt 40))) KTrue)
    -- [LNUL.4.5]'s absent reading: factB6's payload is null.
  , MkCase "eval: a null reading is not hot [LNUL.4.3]"
           (answers valueDecode [factB6] (ECmp OpGt (ESlot 0 False 0) (ELit (VInt 40))) KNull)
  , MkCase "eval: and not cool either"
           (answers valueDecode [factB6]
                    (ENot (ECmp OpGt (ESlot 0 False 0) (ELit (VInt 40)))) KNull)
  , MkCase "eval: is null on it is true [LNUL.4.4]"
           (answers valueDecode [factB6] (EIs False IsNull (ESlot 0 False 0)) KTrue)
  , MkCase "eval: a slot of an id no tuple codes (0, the trap id) reads as a trap"
           (answers valueDecode [MkFact 1 6 0 0] (EIs False IsNull (ESlot 0 False 0)) KTrap)
  , MkCase "eval: a slot past the tuple's arity reads as a trap"
           (answers valueDecode [factA6] (EIs False IsNull (ESlot 0 False 1)) KTrap)
    -- THE TAG TEST [LNUL.4.9]. The for-all facts --
    -- total for every subject, a null only `null`, a tag name the tag alone,
    -- a constant the value too -- are theorems in Rete/Eval.idr; what lives
    -- here are the IEEE specials, which Double arithmetic reduces only at
    -- run time: the infinities and the NaN of `infQ`, `negInfQ`, `nanQ`.
  , MkCase "eval: +Inf is inf and is Float, not -inf and not NaN; -Inf is -inf [LNUL.4.9]"
           (answers valueDecode [] (EIs False IsInf infQ) KTrue
              && answers valueDecode [] (EIs False IsFloat infQ) KTrue
              && answers valueDecode [] (EIs False IsNegInf infQ) KFalse
              && answers valueDecode [] (EIs False IsNaN infQ) KFalse
              && answers valueDecode [] (EIs False IsNegInf negInfQ) KTrue
              && answers valueDecode [] (EIs False IsInf negInfQ) KFalse)
  , MkCase "eval: a NaN is NaN and is Float -- a tag name tests the tag alone -- and is not inf"
           (answers valueDecode [] (EIs False IsNaN nanQ) KTrue
              && answers valueDecode [] (EIs False IsFloat nanQ) KTrue
              && answers valueDecode [] (EIs False IsInf nanQ) KFalse
              && answers valueDecode [] (EIs False IsNegInf nanQ) KFalse)
  , MkCase "eval: inf - inf is NaN, the computed NaN of LNUL.4.9g"
           (answers valueDecode [] (EIs False IsNaN (EArith OpSub infQ infQ)) KTrue)
  , MkCase "eval: a finite Float, the two zeros and 1e308 are none of inf, -inf, NaN"
           (answers valueDecode [] (EIs False IsInf (ELit (VFloat 1.5))) KFalse
              && answers valueDecode [] (EIs False IsNegInf (ELit (VFloat (-1.5)))) KFalse
              && answers valueDecode [] (EIs False IsInf (ELit (VFloat 0.0))) KFalse
              && answers valueDecode [] (EIs False IsNegInf (ENeg (ELit (VFloat 0.0)))) KFalse
              && answers valueDecode [] (EIs False IsInf (ELit (VFloat 1.0e308))) KFalse
              && answers valueDecode [] (EIs False IsNaN (ELit (VFloat 1.5))) KFalse
              && answers valueDecode [] (EIs False IsFloat (ELit (VFloat 1.5))) KTrue)
  , MkCase "eval: a null is not Int -- the negated form fires on absence (LNUL.4.9a) -- and is not Float"
           (answers valueDecode [] (EIs True IsInt (ELit VNull)) KTrue
              && answers valueDecode [] (EIs False IsInt (ELit VNull)) KFalse
              && answers valueDecode [factB6] (EIs False IsFloat (ESlot 0 False 0)) KFalse
              && answers valueDecode [factB6] (EIs True IsNull (ESlot 0 False 0)) KFalse)
  , MkCase "eval: an Int is Int and not Float; a token is String; a trapping operand traps under `is`"
           (answers valueDecode [factA6] (EIs False IsInt (ESlot 0 False 0)) KTrue
              && answers valueDecode [factA6] (EIs False IsFloat (ESlot 0 False 0)) KFalse
              && answers valueDecode [factA6] (EIs False IsString (ESlot 0 True 0)) KTrue
              && answers valueDecode [] (EIs False IsFloat trapExpr) KTrap
              && answers valueDecode [] (EIs True IsFloat trapExpr) KTrap)
    -- COALESCE [LNUL.5.3] / [LNUL.8.9]. The for-all facts -- the
    -- default never looked at when x is present, a null taking it, a trap
    -- in x standing -- are theorems in Rete/Eval.idr; these are dsexpr.k's
    -- vectors (coalesce_lazy, coalesce_val, coalesce_null,
    -- coalesce_null_trap, coalesce_trap) and the LNUL.4.10 fixtures' shapes,
    -- run through the evaluator with a real trapping default.
  , MkCase "eval: 5.5 ?? (1 // 0) is 5.5 -- the trapping default is never looked at [LNUL.8.9]"
           (answers valueDecode []
                    (ECmp OpEq (ECoalesce (ELit (VFloat 5.5)) (EArith OpFloorDiv (ELit (VInt 1)) (ELit (VInt 0))))
                               (ELit (VFloat 5.5))) KTrue
              && evalsToInt valueDecode [] (ECoalesce (ELit (VInt 3)) (ELit (VInt 7))) 3)
  , MkCase "eval: null ?? 7 is 7, and (null // 0) ?? 7 is 7, the division never performed [LNUL.4.10]"
           (evalsToInt valueDecode [] (ECoalesce (ELit VNull) (ELit (VInt 7))) 7
              && evalsToInt valueDecode []
                   (ECoalesce (EArith OpFloorDiv (ELit VNull) (ELit (VInt 0))) (ELit (VInt 7))) 7
              && evalsToInt valueDecode [factB6] (ECoalesce (ESlot 0 False 0) (ELit (VInt 7))) 7)
  , MkCase "eval: null ?? (1 // 0) is the trap, and so is (null + 1 // 0) ?? 7: no fallback from a fault"
           (answers valueDecode []
                    (ECoalesce (ELit VNull) (EArith OpFloorDiv (ELit (VInt 1)) (ELit (VInt 0)))) KTrap
              && answers valueDecode []
                   (ECoalesce (EArith OpAdd (ELit VNull) (EArith OpFloorDiv (ELit (VInt 1)) (ELit (VInt 0))))
                              (ELit (VInt 7))) KTrap
              && answers valueDecode [] (ECmp OpEq (ECoalesce trapExpr (ELit (VInt 7))) (ELit (VInt 7))) KTrap)
  , MkCase "eval: (null ?? 0.0) > 85.0 is false and (null ?? 100.0) > 85.0 true, LNUL.8.9a and b"
           (answers valueDecode [] (ECmp OpGt (ECoalesce (ELit VNull) (ELit (VFloat 0.0))) (ELit (VFloat 85.0))) KFalse
              && answers valueDecode [] (ECmp OpGt (ECoalesce (ELit VNull) (ELit (VFloat 100.0))) (ELit (VFloat 85.0))) KTrue)
    -- THE CONVERSION CAST [LCST.4.5.2] / [LCST.4.5.4]. The for-all facts -- a null source null, the identity a no-op,
    -- Int :: Float total, Float :: Int the truncation inside Int and the
    -- trap outside it and never null, the trap feeding no default, a trap
    -- standing -- are theorems in Rete/Eval.idr; what lives here is
    -- dscast.k's vectors, which Double arithmetic reduces only at run time:
    -- the truncation in both signs (trunc, trunc_high, trunc_negative), the
    -- four doubles at the bounds and 1e30 (range_*), the specials (trap),
    -- null_cast, identity and widen_narrow.
  , MkCase "cast: 2.25 :: Int and 2.75 :: Int are 2, -2.75 :: Int is -2, and the halves are 0: toward zero [LCST.4.5.2]"
           (evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat 2.25))) 2
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat 2.75))) 2
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat (-2.75)))) (-2)
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat 0.5))) 0
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat (-0.5)))) 0)
  , MkCase "cast: 2^63 - 1024, the double below 2^63, is 9223372036854774784, and -2^63 is INT64_MIN"
           (evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat 9223372036854774784.0))) 9223372036854774784
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VFloat (-9223372036854775808.0)))) int64Min)
  , MkCase "cast: 2^63, -2^63 - 2048 and 1e30 trap: finite and outside Int [LERR.1.4.10]"
           (answers valueDecode [] (ECast False TInt (ELit (VFloat 9223372036854775808.0))) KTrap
              && answers valueDecode [] (ECast False TInt (ELit (VFloat (-9223372036854777856.0)))) KTrap
              && answers valueDecode [] (ECast False TInt (ELit (VFloat 1.0e30))) KTrap)
  , MkCase "cast: +Inf, -Inf and a NaN trap, under either form [LCST.4.5.4]"
           (answers valueDecode [] (ECast False TInt infQ) KTrap
              && answers valueDecode [] (ECast False TInt negInfQ) KTrap
              && answers valueDecode [] (ECast False TInt nanQ) KTrap
              && answers valueDecode [] (ECast True TInt nanQ) KTrap)
  , MkCase "cast: (2^63 :: Int ?? 7) == 7 traps, no fallback from the trap; (null :: Int? ?? 7) == 7 is true and null :: Int? is null"
           (answers valueDecode []
                    (ECmp OpEq (ECoalesce (ECast False TInt (ELit (VFloat 9223372036854775808.0))) (ELit (VInt 7)))
                               (ELit (VInt 7))) KTrap
              && answers valueDecode []
                   (ECmp OpEq (ECoalesce (ECast True TInt (ELit VNull)) (ELit (VInt 7))) (ELit (VInt 7))) KTrue
              && answers valueDecode [] (EIs False IsNull (ECast True TInt (ELit VNull))) KTrue
              && answers valueDecode [factB6] (EIs False IsNull (ECast True TInt (ESlot 0 False 0))) KTrue)
  , MkCase "cast: 2 :: Float is 2.0 and 2^53 + 1 :: Float is 2^53, the nearest double [LEXP.7.3b]; 3 :: Int is 3"
           (answers valueDecode [] (ECmp OpEq (ECast False TFloat (ELit (VInt 2))) (ELit (VFloat 2.0))) KTrue
              && answers valueDecode []
                   (ECmp OpEq (ECast False TFloat (ELit (VInt 9007199254740993))) (ELit (VFloat 9007199254740992.0))) KTrue
              && evalsToInt valueDecode [] (ECast False TInt (ELit (VInt 3))) 3)
  , MkCase "cast: numeric to Bool and a bare null :: Int are the residue's traps, not DS"
           (answers valueDecode [] (ECast False TBool (ELit (VInt 1))) KTrap
              && answers valueDecode [] (ECast False TInt (ELit VNull)) KTrap)
    -- REAL STRINGS [LSTR.1.1], [LSTR.2.1], [LSTR.3.1], [LSTR.3.2],
    -- [LCST.4.5.5], [LCST.4.5.6], [LCST.4.5.7].
    -- The for-all facts -- the order irreflexive, asymmetric, transitive and
    -- total, a prefix first, equality codepoint by codepoint, a fallible
    -- parse a value or null and never a trap, the Bool render the parse's
    -- inverse -- are theorems in Rete/Eval.idr, and the fixtures' small
    -- spellings are executed there. What lives here: the astral codepoint,
    -- whose comparison is 65,374 steps at the type level; the Int render and
    -- parse, Integer arithmetic; the out-of-range magnitude; and the String
    -- slot read through a `string` table, as the Idris model reads one.
  , MkCase "strings: an astral codepoint orders above every BMP one: U+1F600 > U+FF5E, and U+0061 does not (LSTR.3.2_astral_above_bmp)"
           (lstr_3_2__lt (cps "～") (cps "😀") && not (lstr_3_2__lt (cps "～") (cps "a"))
              && answers envS [factS 40] (ECmp OpGt slot0 (ELit (VStr (cps "～")))) KTrue
              && answers envS [factS 5] (ECmp OpGt slot0 (ELit (VStr (cps "～")))) KFalse)
  , MkCase "strings: the six comparisons on two Strings through the evaluator: Z > M, Z >= Z, a != Z, ab < abc, abc <= abc, M < Z [LSTR.3.2]"
           (answers envS [factS 6] (ECmp OpGt slot0 (ELit (VStr (cps "M")))) KTrue
              && answers envS [factS 6] (ECmp OpGe slot0 (ELit (VStr (cps "Z")))) KTrue
              && answers envS [factS 5] (ECmp OpNe slot0 (ELit (VStr (cps "Z")))) KTrue
              && answers envS [factS 8] (ECmp OpLt slot0 (ELit (VStr (cps "abc")))) KTrue
              && answers envS [factS 1] (ECmp OpLe slot0 (ELit (VStr (cps "abc")))) KTrue
              && answers envS [factS 0] (ECmp OpLt slot0 (ELit (VStr (cps "Z")))) KTrue
              && answers envS [factS 1] (ECmp OpLt slot0 (ELit (VStr (cps "abc")))) KFalse)
  , MkCase "strings: equality is codepoint by codepoint and a null operand is null [LSTR.3.1]"
           (answers envS [factS 4] (ECmp OpEq slot0 (ELit (VStr (cps "é")))) KTrue
              && answers envS [factS 4] (ECmp OpEq slot0 (ELit (VStr (cps "e")))) KFalse
              && answers envS [factS 4] (ECmp OpLt slot0 (ELit VNull)) KNull)
  , MkCase "strings: len counts codepoints -- café 4, the waving hand with a skin tone 2, ab 2 -- and len of null traps [LSTR.2.1] [IRET.9.6]"
           (lstr_2_1__len (cps "café") == 4 && lstr_2_1__len (cps "👋🏽") == 2
              && evalsToInt envS [factS 8] (ELenStr slot0) 2
              && answers envS [factB6] (ELenStr slot0) KTrap
              && answers envS [factB6] (EAnd (EIs True IsNull slot0) (ECmp OpGt (ELenStr slot0) (ELit (VInt 3)))) KFalse)
  , MkCase "strings: Int :: String is the exact decimal, both signs and the extremes, and parses back [LCST.4.5.6] [LCST.4.5.7]"
           (lcst_4_5_6__render_int 42 == cps "42" && lcst_4_5_6__render_int 0 == cps "0"
              && lcst_4_5_6__render_int (-7) == cps "-7"
              && lcst_4_5_6__render_int int64Max == cps "9223372036854775807"
              && lcst_4_5_6__render_int int64Min == cps "-9223372036854775808"
              && lcst_4_5_7__parse_int (lcst_4_5_6__render_int int64Max) == Just int64Max
              && lcst_4_5_7__parse_int (lcst_4_5_6__render_int int64Min) == Just int64Min
              && lcst_4_5_7__parse_int (lcst_4_5_6__render_int (-7)) == Just (-7))
  , MkCase "strings: 2^63 and -2^63 - 1 are outside Int and parse to null; -2^63 is inside [LCST.4.5.7]"
           (isNothing (lcst_4_5_7__parse_int (cps "9223372036854775808"))
              && isNothing (lcst_4_5_7__parse_int (cps "-9223372036854775809"))
              && isNothing (lcst_4_5_7__parse_int (cps "99999999999999999999999"))
              && lcst_4_5_7__parse_int (cps "-9223372036854775808") == Just int64Min
              && answers envS [factS 42] (EIs False IsNull (ECast True TInt slot0)) KTrue
              && evalsToInt envS [factS 43] (ECast True TInt slot0) int64Min)
  , MkCase "strings: a String slot parsed through the evaluator: 0x1F and 3_1 are 31, -0x1F is -31, 31_ is null and ?? 0 rescues it [LCST.4.5.7] [LNUL.8.4]"
           (evalsToInt envS [factS 10] (ECast True TInt slot0) 31
              && evalsToInt envS [factS 12] (ECast True TInt slot0) 31
              && evalsToInt envS [factS 19] (ECast True TInt slot0) (-31)
              && answers envS [factS 17] (EIs False IsNull (ECast True TInt slot0)) KTrue
              && evalsToInt envS [factS 17] (ECoalesce (ECast True TInt slot0) (ELit (VInt 0))) 0
              && evalsToInt envS [factS 6] (ECoalesce (ECast True TInt slot0) (ELit (VInt 0))) 0)
  , MkCase "strings: true :: Bool? is true, Z :: Bool? is null, and the renders of 42 and true compare equal to their literals [LCST.4.5.5] [LCST.4.5.6]"
           (answers envS [factS 3] (ECast True TBool slot0) KTrue
              && answers envS [factS 6] (EIs False IsNull (ECast True TBool slot0)) KTrue
              && answers envS [] (ECmp OpEq (ECast False TString (ELit (VInt 42))) (ELit (VStr (cps "42")))) KTrue
              && answers envS [] (ECmp OpEq (ECast False TString (ELit (VBool True))) (ELit (VStr (cps "true")))) KTrue
              && answers envS [] (ECmp OpEq (ECast False TString (ELit (VBool False))) (ELit (VStr (cps "true")))) KFalse)
  , MkCase "strings: a rendered text in a tuple codes by the token of its text, and one no table holds is 0, the trap id; without the table the token decodes to its opaque text"
           (valueCodeWith tablesS [VStr (cps "42")] == 1000000000000000000019
              && valueCodeWith tablesS [VStr (lcst_4_5_6__render_int 42)] == 1000000000000000000019
              && valueCodeWith tablesS [VStr (cps "43")] == 0
              && decodesTo 1000000000000000000019 [tok 2]
              && (case valueDecodeWith tablesS 1000000000000000000019 of
                    Just [VStr t] => t == cps "42"
                    _             => False))
  , MkCase "strings: a String token of an input with no table is an opaque text that codes back to its token, and no String holds it"
           (valueCode [tok 7] == 1000000000000000000059 && decodesTo 1000000000000000000059 [tok 7]
              && not (lstr_1_1__text_admissible (ptext 7)) && lstr_1_1__text_admissible (cps "café"))
    -- FLOAT TEXT [LCST.4.5.8], [LCST.4.5.6], [LDET.3.2.7], [LDET.3.2.8],
    -- [LLEX.11.2] (run, not proved). The
    -- for-all facts -- a parse a value or null for every text, the search's
    -- digits admitted by the parse's own test -- and the grammar and the
    -- shaping on literals are in Rete/Eval.idr; what lives here is the
    -- arithmetic, which Double and Integer division reduce only at run
    -- time: the fixtures' spellings and values, the halfway cases, the
    -- extremes and the powers of two, and every one round-tripped.
  , MkCase "float text: the thirteen spellings of LCST.4.5.8_float_formats_parse: ten are 1500.0, -1.5e3 is -1500.0, inf and -inf the infinities"
           (parsesTo "1500" 1500.0 && parsesTo "1_500" 1500.0 && parsesTo "1500.0" 1500.0
              && parsesTo "1.5e3" 1500.0 && parsesTo "1.5E3" 1500.0 && parsesTo "1.5e+03" 1500.0
              && parsesTo "15e2" 1500.0 && parsesTo "0x5DC" 1500.0 && parsesTo "+1.5e3" 1500.0
              && parsesTo "1_500.0" 1500.0 && parsesTo "-1.5e3" (negate 1500.0)
              && parsesTo "inf" ldet_3_6_2__infinity && parsesTo "-inf" (negate ldet_3_6_2__infinity))
  , MkCase "float text: the fifteen spellings of LCST.4.5.8_float_non_literals_are_null are null; so are an integer spelling outside Int and a finite spelling past the largest double"
           (parsesNull "nan" && parsesNull "NaN" && parsesNull "infinity" && parsesNull "INF"
              && parsesNull " 1.5" && parsesNull "1.5 " && parsesNull "1500_s" && parsesNull "1500s"
              && parsesNull "1." && parsesNull ".5" && parsesNull "1.5e" && parsesNull "0x1p3"
              && parsesNull "1e400" && parsesNull "1_.5" && parsesNull ""
              && parsesNull "99999999999999999999" && parsesNull "1.7976931348623159e308")
  , MkCase "float text: ties round to even: 2^53 + 1 to 2^53 and 2^53 + 3 to 2^53 + 4; half the least subnormal to 0.0 and a hair more to 5e-324; 1e-400 a zero with its sign; 1.7976931348623158e308 down to the largest double"
           (parsesTo "9007199254740993" 9007199254740992.0
              && parsesTo "9007199254740995" 9007199254740996.0
              && parsesTo "2.4703282292062327e-324" 0.0
              && parsesTo "2.4703282292062328e-324" 5.0e-324
              && parsesTo "4.9e-324" 5.0e-324
              && parsesTo "1e-400" 0.0 && parsesTo "-1e-400" negZero
              && parsesTo "1.7976931348623157e308" 1.7976931348623157e308
              && parsesTo "1.7976931348623158e308" 1.7976931348623157e308)
  , MkCase "float text: -0, -0.0 and -0x0 keep their sign; 0.1 + 0.2 parses from its seventeen digits; 1e1_0 is 1e10, the grammar's reading"
           (parsesTo "-0" negZero && parsesTo "-0.0" negZero && parsesTo "-0x0" negZero && parsesTo "0" 0.0
              && parsesTo "0.30000000000000004" (0.1 + 0.2)
              && parsesTo "1e1_0" 1.0e10)
  , MkCase "float text: the renders of LDET.3.2.7, its negzero twin and LCST.4.5.6_nan_renders_nan: 42.0, 3.141592653589793, 0.30000000000000004, inf, -inf, -0.0, 0.0, nan; and 3.14159"
           (rendersAs 42.0 "42.0" && rendersAs 3.141592653589793 "3.141592653589793"
              && rendersAs (0.1 + 0.2) "0.30000000000000004"
              && rendersAs ldet_3_6_2__infinity "inf" && rendersAs (negate ldet_3_6_2__infinity) "-inf"
              && rendersAs negZero "-0.0" && rendersAs 0.0 "0.0"
              && rendersAs (0.0 / 0.0) "nan" && rendersAs 3.14159 "3.14159")
  , MkCase "float text: the shape's edges: 0.0001 and 1000000000000000.0 fixed, 1e-05 and 1e+16 scientific, 9999999999999998.0 the last fixed above; 1.5e+16, 123456789.0, 100.0, 0.1, -2.5e-07, 1e-07, 0.000123, 123456.789, 4.35, 2.675"
           (rendersAs 0.0001 "0.0001" && rendersAs 1.0e15 "1000000000000000.0"
              && rendersAs 0.00001 "1e-05" && rendersAs 1.0e16 "1e+16"
              && rendersAs 9999999999999998.0 "9999999999999998.0"
              && rendersAs 1.5e16 "1.5e+16" && rendersAs 123456789.0 "123456789.0"
              && rendersAs 100.0 "100.0" && rendersAs 0.1 "0.1" && rendersAs (negate 2.5e-7) "-2.5e-07"
              && rendersAs 1.0e-7 "1e-07" && rendersAs 0.000123 "0.000123"
              && rendersAs 123456.789 "123456.789" && rendersAs 4.35 "4.35" && rendersAs 2.675 "2.675")
  , MkCase "float text: the extremes and the powers of two: 5e-324, the least normal, the greatest subnormal, the largest double, 2^53, 2^63, 2^64, 2^100, 2^-100, 2^-30; 1e23, 8.41e21, a third and two thirds"
           (rendersAs 5.0e-324 "5e-324"
              && rendersAs 2.2250738585072014e-308 "2.2250738585072014e-308"
              && rendersAs 2.225073858507201e-308 "2.225073858507201e-308"
              && rendersAs 1.7976931348623157e308 "1.7976931348623157e+308"
              && rendersAs 9007199254740992.0 "9007199254740992.0"
              && rendersAs 9223372036854775808.0 "9.223372036854776e+18"
              && rendersAs 18446744073709551616.0 "1.8446744073709552e+19"
              && rendersAs 1.2676506002282294e30 "1.2676506002282294e+30"
              && rendersAs 7.888609052210118e-31 "7.888609052210118e-31"
              && rendersAs 9.313225746154785e-10 "9.313225746154785e-10"
              && rendersAs 1.0e23 "1e+23" && rendersAs 8.41e21 "8.41e+21"
              && rendersAs (1.0 / 3.0) "0.3333333333333333" && rendersAs (2.0 / 3.0) "0.6666666666666666")
  , MkCase "float text: every value above round-trips through its text, the zeros with their sign"
           (all roundTrips [42.0, 3.141592653589793, 0.1 + 0.2, negZero, 0.0, 3.14159, 0.0001, 1.0e15, 0.00001, 1.0e16,
                            9999999999999998.0, 1.5e16, 123456789.0, 100.0, 0.1, negate 2.5e-7, 1.0e-7, 0.000123,
                            123456.789, 4.35, 2.675, 5.0e-324, 2.2250738585072014e-308, 2.225073858507201e-308,
                            1.7976931348623157e308, 9007199254740992.0, 9223372036854775808.0,
                            18446744073709551616.0, 1.2676506002282294e30, 7.888609052210118e-31,
                            9.313225746154785e-10, 1.0e23, 8.41e21, 1.0 / 3.0, 2.0 / 3.0, 1500.0, negate 1500.0]
              && roundTrips ldet_3_6_2__infinity && roundTrips (negate ldet_3_6_2__infinity))
  , MkCase "float text: through the evaluator: 1.5 :: String is \"1.5\"; \"1_500.0\" :: Float? ?? 0.0 is 1500.0; \"nan\" :: Float? is null; null :: String? is null; 0.1 :: String :: Float? is 0.1 again [LCST.4.5.2]"
           (answers valueDecode [] (ECmp OpEq (ECast False TString (ELit (VFloat 1.5))) (ELit (VStr (cps "1.5")))) KTrue
              && answers valueDecode []
                   (ECmp OpEq (ECoalesce (ECast True TFloat (ELit (VStr (cps "1_500.0")))) (ELit (VFloat 0.0)))
                              (ELit (VFloat 1500.0))) KTrue
              && answers valueDecode [] (EIs False IsNull (ECast True TFloat (ELit (VStr (cps "nan"))))) KTrue
              && answers valueDecode [] (EIs False IsNull (ECast True TString (ELit VNull))) KTrue
              && answers valueDecode []
                   (ECmp OpEq (ECoalesce (ECast True TFloat (ECast False TString (ELit (VFloat 0.1)))) (ELit (VFloat 0.0)))
                              (ELit (VFloat 0.1))) KTrue)
    -- JSON LEAVES [LNUL.8.4], [LEXP.6.1], [LEXP.6.2], [LEXP.7.12.1],
    -- [LFAC.2.5.1], [LGRA.5.8.8]. The
    -- for-all facts -- a path read never faults, an unresolved path and a
    -- present null both read as null and has() tells them apart, a
    -- container under an operator traps, len counts an array alone, the
    -- fold leaves no -0.0 -- are theorems in Rete/Eval.idr; what lives here
    -- is the probe json.json's document read through the value code and a
    -- `json` table (Fixture.idr, `valueDecodeWith`), the zeros, which Double
    -- arithmetic reduces only at run time, and the coding of a copied
    -- document.
  , MkCase "json: an unresolved path reads as null -- is null on it is true, == on it is null [LNUL.8.4]"
           (answers envJ [factJ] (EIs False IsNull (leafAt [99])) KTrue
              && answers envJ [factJ] (ECmp OpEq (leafAt [99]) (ELit (VInt 1))) KNull)
  , MkCase "json: has() separates the two missings: true of the present null, which still reads as null, false of the absent [LEXP.6.1]"
           (answers envJ [factJ] (EHas [SKey 20] docSlot) KTrue
              && answers envJ [factJ] (EIs False IsNull (leafAt [20])) KTrue
              && answers envJ [factJ] (EHas [SKey 99] docSlot) KFalse)
  , MkCase "json: leaves keep the kind they were written with: an Int, a String, a Bool, a Float; the slot and a sub-document are Json [LEXP.7.12.1]"
           (evalsToInt envJ [factJ] (leafAt [21]) 3
              && answers envJ [factJ] (ECmp OpEq (leafAt [22]) (ELit (tok 23))) KTrue
              && answers envJ [factJ] (EIs False IsString (leafAt [22])) KTrue
              && answers envJ [factJ] (EIs False IsTrue (leafAt [24])) KTrue
              && answers envJ [factJ] (ECmp OpGt (leafAt [25]) (ELit (VFloat 1.0))) KTrue
              && answers envJ [factJ] (EIs False IsFloat (leafAt [25])) KTrue
              && answers envJ [factJ] (EIs False IsJson docSlot) KTrue
              && answers envJ [factJ] (EIs False IsJson (leafAt [26])) KTrue)
  , MkCase "json: a nested member, a bracket index, len of the array; an index past the end is absent [LGRA.5.8.1], [LEXP.6.2]"
           (evalsToInt envJ [factJ] (leafAt [26, 27]) 1
              && evalsToInt envJ [factJ] (EPath [SKey 28, SIndex 1] docSlot) 2
              && evalsToInt envJ [factJ] (ELen (leafAt [28])) 2
              && answers envJ [factJ] (EIs False IsNull (EPath [SKey 28, SIndex 2] docSlot)) KTrue)
  , MkCase "json: len of an object or a scalar leaf traps [LEXP.6.2]; a String leaf ordered, a container in arithmetic and a sub-document == 1 trap [LEXP.7.12.1]; a false conjunct absorbs the trap"
           (answers envJ [factJ] (ECmp OpEq (ELen (leafAt [26])) (ELit (VInt 1))) KTrap
              && answers envJ [factJ] (ECmp OpEq (ELen (leafAt [21])) (ELit (VInt 1))) KTrap
              && answers envJ [factJ] (ECmp OpGt (leafAt [22]) (ELit (VInt 5))) KTrap
              && answers envJ [factJ] (EArith OpAdd (leafAt [26]) (ELit (VInt 1))) KTrap
              && answers envJ [factJ] (ECmp OpEq (leafAt [26]) (ELit (VInt 1))) KTrap
              && answers envJ [factJ] (EAnd (ECmp OpGt (leafAt [22]) (ELit (VInt 5))) (ELit (VBool False))) KFalse)
  , MkCase "json: ?? rescues the present null and the absent path alike, and keeps a present value [LNUL.8.4], [LNUL.5.3]"
           (evalsToInt envJ [factJ] (ECoalesce (leafAt [20]) (ELit (VInt 7))) 7
              && evalsToInt envJ [factJ] (ECoalesce (leafAt [99]) (ELit (VInt 7))) 7
              && evalsToInt envJ [factJ] (ECoalesce (leafAt [21]) (ELit (VInt 7))) 3)
  , MkCase "json: a segment into a leaf, and a key into an array, leave the path unresolved -- the model's reading of [LNUL.8.4]"
           (answers envJ [factJ] (EIs False IsNull (leafAt [21, 23])) KTrue
              && answers envJ [factJ] (EHas [SKey 28, SKey 27] docSlot) KFalse)
  , MkCase "json: the float zero has no sign once folded: the raw -0.0 divides 1.0 to -Inf, the folded leaf to +Inf [LGRA.5.8.8]"
           (answers envR [factR] (EIs False IsNegInf (EArith OpDiv (ELit (VFloat 1.0)) (leafAt [29]))) KTrue
              && answers envJ [factJ] (EIs False IsInf (EArith OpDiv (ELit (VFloat 1.0)) (leafAt [29]))) KTrue)
  , MkCase "json: deep equality: the raw and the folded document are one value, 0.0 is -0.0 inside an array, 0 is not 0.0 [LFAC.2.5.1]"
           (lfac_2_5_1__json_eq docJ docRaw
              && lfac_2_5_1__json_eq (JFloat 0.0) (JFloat negZero)
              && lfac_2_5_1__json_eq (JArr [JFloat negZero]) (JArr [JFloat 0.0])
              && not (lfac_2_5_1__json_eq (JInt 0) (JFloat 0.0)))
  , MkCase "json: == and != on two documents through the evaluator; a sub-document equals a whole one with its content; a null operand is null [LEXP.7.19]"
           (answers envJ [factJ, factK] (ECmp OpEq (ESlot 0 False 0) (ESlot 1 False 0)) KFalse
              && answers envJ [factJ, factK] (ECmp OpNe (ESlot 0 False 0) (ESlot 1 False 0)) KTrue
              && answers envJ [factJ, factK] (ECmp OpEq (leafAt [26]) (ESlot 1 False 0)) KTrue
              && answers envJ [factJ] (ECmp OpEq docSlot (ELit VNull)) KNull)
    -- ABSORBING [LNUL.4.2]: a false conjunct decides wherever it stands.
  , MkCase "eval: false and trap is false"
           (answers valueDecode [] (EAnd (ELit (VBool False)) trapExpr) KFalse)
  , MkCase "eval: trap and false is false -- the trap is absorbed"
           (answers valueDecode [] (EAnd trapExpr (ELit (VBool False))) KFalse)
  , MkCase "eval: trap and true traps"
           (answers valueDecode [] (EAnd trapExpr (ELit (VBool True))) KTrap)
  , MkCase "eval: trap or true and true or trap are true; trap or false traps"
           (answers valueDecode [] (EOr trapExpr (ELit (VBool True))) KTrue
              && answers valueDecode [] (EOr (ELit (VBool True)) trapExpr) KTrue
              && answers valueDecode [] (EOr trapExpr (ELit (VBool False))) KTrap)
  , MkCase "eval: null and false is false; true and null is null [LNUL.4.2]"
           (answers valueDecode [] (EAnd (ELit VNull) (ELit (VBool False))) KFalse
              && answers valueDecode [] (EAnd (ELit (VBool True)) (ELit VNull)) KNull)
    -- THE VALUE CODE (Fixture.idr, THE VALUE CODE). The round trip is Integer
    -- arithmetic and so a worked example, not a theorem, on the inputs that
    -- matter: the empty tuple, the Int extremes, a negative, every kind in
    -- one tuple, and the two naturals that are no code. The numerals are
    -- written out so a reader can check them against the header's rule and
    -- against the fixture lowering's `encode`, which must agree digit for
    -- digit.
  , MkCase "code: the empty tuple is 1, and 0 is no code"
           (valueCode [] == 1 && decodesTo 1 [] && isNothing (valueDecode 0))
  , MkCase "code: Int 1 is the numeral 1 then the block 18 (ZigZag 2, tag 2)"
           (valueCode [VInt 1] == 1000000000000000000018)
  , MkCase "code: null, false, true and token 0 are the blocks 0, 1, 9 and 3"
           (valueCode [VNull] == 1000000000000000000000
              && valueCode [VBool False] == 1000000000000000000001
              && valueCode [VBool True] == 1000000000000000000009
              && valueCode [tok 0] == 1000000000000000000003)
  , MkCase "code: INT64_MAX and INT64_MIN each fill one block below the base"
           (valueCode [VInt int64Max] == 1147573952589676412914
              && valueCode [VInt int64Min] == 1147573952589676412922)
    -- A Float is coded by its bits (tag 4): 1.0 is 0x3FF0000000000000, so its
    -- block is 8 * 4607182418800017408 + 4. The bits are read by Chez's
    -- bytevector procedures (Fixture.idr), so each is a claim about one value.
  , MkCase "code: 1.0 is its bits 4607182418800017408, the block 36857459350400139268"
           (doubleBits 1.0 == 4607182418800017408
              && valueCode [VFloat 1.0] == 1036857459350400139268)
  , MkCase "code: the bits of 0.5, 2.0, 100.0 and +Inf, and back again"
           (doubleBits 0.5 == 4602678819172646912
              && doubleBits 2.0 == 4611686018427387904
              && doubleBits 100.0 == 4636737291354636288
              && doubleBits (1.0 / 0.0) == 9218868437227405312
              && bitsDouble 4607182418800017408 == Just 1.0
              && isNothing (bitsDouble 18446744073709551616)
              && decodesTo (valueCode [VFloat 3.5, VInt 2, VFloat (-1.5)]) [VFloat 3.5, VInt 2, VFloat (-1.5)])
  , MkCase "code: -0.0 and +0.0 are one code, the identity's IEEE == [LFAC.2.5.1]"
           (doubleBits negZero == 9223372036854775808
              && valueCode [VFloat negZero] == valueCode [VFloat 0.0]
              && valueCode [VFloat 0.0] == 1000000000000000000004)
  , MkCase "code: a NaN has no code: its tuple gets 0, and its bits decode to nothing [LEXP.4.2]"
           (valueCode [VFloat (0.0 / 0.0)] == 0
              && isNothing (valueDecode (1000000000000000000000 + 8 * 9221120237041090560 + 4)))
  , MkCase "code: a tuple of every kind, first slot first, decodes to itself"
           (decodesTo (valueCode [VInt (-7), tok 3, VBool True, VNull, VInt int64Min])
                      [VInt (-7), tok 3, VBool True, VNull, VInt int64Min])
  , MkCase "code: the two extremes and their neighbours decode to themselves"
           (decodesTo (valueCode [VInt int64Max]) [VInt int64Max]
              && decodesTo (valueCode [VInt int64Min]) [VInt int64Min]
              && decodesTo (valueCode [VInt (-1), VInt 0]) [VInt (-1), VInt 0])
  , MkCase "code: a block with no sentinel before it is no code"
           (isNothing (valueDecode 7) && isJust (valueDecode 1000000000000000000018)
              && isNothing (valueDecode 2000000000000000000018)
              && isNothing (valueDecode 1000000000000000000005))
  , MkCase "code: distinct values have distinct codes across kinds"
           (valueCode [VInt 0] /= valueCode [VNull]
              && valueCode [VInt 0] /= valueCode [VBool False]
              && valueCode [tok 0] /= valueCode [VInt 0]
              && valueCode [VFloat 0.0] /= valueCode [VInt 0]
              && valueCode [VFloat 1.0] /= valueCode [VInt 1]
              && valueCode [VInt 1, VInt 2] /= valueCode [VInt 2, VInt 1]
              && valueCode [VInt 1] /= valueCode [VInt 1, VNull])
    -- A document: coded by the token the `json` table gives the
    -- deep-equal document (30: the block 8 * 30 + 3 = 243), so the raw
    -- document, equal but for a zero's sign, codes the same; one no table
    -- holds gets 0, the trap id. The token decodes to the document with the
    -- table and to a String without it.
  , MkCase "code: a document is the block 243 under its table, the deep-equal raw document too, and one no table holds is 0"
           (valueCodeWith tablesJ [VJson docJ] == 1000000000000000000243
              && valueCodeWith tablesJ [VJson docRaw] == 1000000000000000000243
              && valueCodeWith tablesJ [VJson (JArr [])] == 0)
  , MkCase "code: the token decodes to the document with the table, and to the String token 30 without it"
           (decodesToDoc 1000000000000000000243 docJ
              && decodesTo 1000000000000000000243 [tok 30])
  , MkCase "key: two one-byte Strings are not the two-byte String, nor the Int, nor the empty key"
           (not (rlow_4_6_2_1__same_b [PStr [0x31], PStr [0x32]] [PStr [0x31, 0x32]])
              && not (rlow_4_6_2_1__same_b [PStr [0x31], PStr [0x32]] [PInt 12])
              && not (rlow_4_6_2_1__same_b [PStr [0x31], PStr [0x32]] []))
    -- A `withdraw` mid-pump. The refcount keeps the Reach closure
    -- live on its own justifications, and the alarm fires on it.
  , MkCase "recompute: the refcount engine alarms twice on an unfounded closure"
           (quiet (tmsRun alarmProg)
              && countKind 9 (fst (tmsRun alarmProg)) == 2
              && countKind lcyc_3_2_2__k_reach (fst (tmsRun alarmProg)) == 2)
  , MkCase "recompute: with the step after every action, no Reach and no alarm"
           (quiet (rdRun alarmProg)
              && countKind 9 (fst (rdRun alarmProg)) == 0
              && countKind lcyc_3_2_2__k_reach (fst (rdRun alarmProg)) == 0
              && countKind 8 (fst (rdRun alarmProg)) == 1)
  , MkCase "recompute: on acyclic support the two engines end in the same state"
           (quiet (tmsRun flatProg) && fst (tmsRun flatProg) == fst (rdRun flatProg)
              && snd (snd (tmsRun flatProg)) == snd (snd (rdRun flatProg)))
  ]

report : Case -> IO ()
report c =
  putStrLn ((if held c then "   ok   " else "   FAIL ") ++ label c)

examplesMain : IO ()
examplesMain =
  do putStrLn ("== idris worked examples: " ++ show (length cases) ++ " case(s) ==")
     traverse_ report cases
     let bad = length (filter (not . held) cases)
     if bad == 0
       then putStrLn ("\nall " ++ show (length cases) ++ " examples hold")
       else do putStrLn ("\n" ++ show bad ++ " example(s) FAILED")
               exitFailure

||| With no arguments, the worked examples (the lane's run). With
||| `--fixture <lowered-fixture>`, the Idris model of Fixture.idr --
||| `covering` only because that reads a file (see Fixture.idr).
covering
main : IO ()
main =
  do args <- getArgs
     case args of
       (_ :: "--fixture" :: path :: _) => fixtureMain path
       _ => examplesMain

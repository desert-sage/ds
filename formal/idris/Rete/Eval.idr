-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The `where` expression, evaluated: values, null propagation, Kleene
||| connectives, the total null test, and the four answers a join test gives
||| a (token, candidate) pair ([IRET.7.5], [IRET.7.6]).
|||
||| NORMATIVE COMPANION, on the two mechanisms every module of the lane
||| carries: each element is named `<clause-id>__<tag>` after the paragraph it
||| formalizes and the `--@spec` / `--@derives` marker above it names the
||| clause, so the crossref can confirm the id exists and matches.
|||
||| THE FRAGMENT. What the rules in production write — build-unit's
||| `scheduler.ds`, microctl's knowledge model: equality anchors between two
||| bindings' slots, `and` of those, a slot against a String / Int literal, a
||| bare Bool slot, the same under `no`. So: Int / Float / String / Bool /
||| `null` values; the six comparisons; `+ - * / // %` and unary minus on
||| Int and Float; `and`, `or`, `not`; `is` and `is not` over [LNUL.4.9]'s
||| twelve subjects; `??`; the conversion cast `::` and `::?` between Int
||| and Float, the identities, the parses from String to Int, Float and Bool
||| and the renders of Int, Float and Bool to String ([LCST.4.5.2]); a
||| `Json` document, its paths, `has` and `len`, and `==` on two documents;
||| a String's text, its equality, its order and its `len`.
|||
||| FLOAT TEXT (run, not proved). `String :: Float?` is [LCST.4.5.8]'s parse: the whole text
||| an optional sign then an `INT_LIT` ([LLEX.11.1], in the 64-bit range,
||| [LLEX.11.1.5]), a `FLOAT_LIT` ([LLEX.11.2]: both sides of the point,
||| [LLEX.11.2.1]; the exponent required on the bare form, [LLEX.11.2.2]; a
||| `_` only between two digits, [LLEX.11.1]) or `inf`, to the
||| nearest double, ties to even ([LDET.3.2.8]), `-0.0` keeping its sign,
||| and `null` for every other text -- a value past the largest double
||| among them (`lcst_4_5_8__parse_float`). `Float :: String` is
||| [LCST.4.5.6]'s render in [LDET.3.2.7]'s canonical form: `nan`, `inf`,
||| `-inf`, the signed zeros, and for a finite nonzero value the fewest
||| digits that parse back to it, the nearer of two, the even one at a tie
||| ([LDET.3.2.8]), in fixed notation for `1e-4 <= |x| < 1e16` with the
||| `.0` kept and in scientific notation with a signed two-digit exponent
||| otherwise (`lcst_4_5_6__render_float`). Both are the clauses' own words
||| in exact Integer arithmetic -- the value as a fraction, the quotient at
||| the exponent where it has 53 bits, the remainder against a half; the
||| digits found by testing, length by length, the two decimals bracketing
||| the value with the parse itself -- and read no library and no host
||| conversion: not Chez's, not Dragonbox's, not fast_float's, which is what
||| makes the Idris model a third route to the function libds computes. What is
||| proved is the shape: a parse a value or `null` for every text
||| (`lcst_4_5_8__parse_is_a_value_or_null`), the render's digits admitted
||| by the parse's own test and by nothing else, for every value
||| (`ldet_3_2_7__found_round_trips`), the shaping rows and the grammar on
||| literal digits and spellings. What is run is the arithmetic: the
||| fixtures' spellings and values, the halfway cases, the extremes and the
||| powers of two in Main.idr, and every fixture the idris-libds lane
||| compares. The parse's proof is scheduled for after v1.
|||
||| DIVISION AND Float. `//` rounds toward negative infinity
||| and a nonzero `%` takes the divisor's sign ([LEXP.7.5], [LEXP.7.6]); on
||| Int both wrap ([LEXP.7.13.1]: `INT64_MIN // -1` is `INT64_MIN`); `/`
||| always yields a Float, on two Ints too ([LEXP.7.4]); with every operand
||| Int a zero divisor under any of the three is a runtime error
||| ([LEXP.7.15.1], [LERR.1.4.3]), a trap here; a `null` operand is `null`
||| before the divisor is looked at ([LNUL.9.3], [LNUL.4.10]). A Float is an
||| IEEE 754 binary64 (Idris's `Double`, a Chez flonum): an Int beside one
||| promotes ([LEXP.7.3], the nearest double), `+ - * /` and the six
||| comparisons are IEEE's, rounding to nearest even ([LDET.3.6.1]), and an
||| infinity or a NaN is a result and never a trap ([LDET.3.6.2]): `x / 0.0`
||| is `±Inf`, `0.0 / 0.0` NaN, `NaN != NaN`. formal/k/dsexpr.k is the
||| executable reading this module is kept in step with.
|||
||| `//` AND `%` WITH A Float OPERAND are the compositions [LEXP.7.5] and
||| [LEXP.7.6] pin, and no other: step 1 is the EXACT remainder of the
||| quotient truncated toward zero, `a - b * trunc(a / b)` with no rounding
||| anywhere in it, carrying `a`'s sign -- computed here as a loop that
||| subtracts the largest `|b| * 2^k` not above what is left, each
||| subtraction exact by Sterbenz's lemma (`lexp_7_6__exact_remainder`),
||| never through a rounded quotient. `%` is then steps 2 and 3
||| (`lexp_7_6__float_mod`: a nonzero remainder of the wrong sign moved by
||| `b`, rounded once; a zero one given `b`'s sign) and `//` steps 1 to 4
||| (`lexp_7_5__float_floordiv`: `(a - r) / b` rounded once each, less one
||| when step 2 adjusted, a zero given the sign of `a / b`, else the floor
||| corrected upward when the quotient sits more than a half above it). A
||| zero divisor is [LEXP.7.15.1]'s IEEE row, taken before the composition:
||| `//` by zero is the quotient `a / b` (`±Inf`, NaN for a zero dividend)
||| and `%` by zero is NaN; nothing traps (`lexp_7_15_1__float_divmod_never_traps`,
||| for every pair of operands). The values are Double arithmetic and are
||| RUN, not proved: the clauses' examples, the fixtures' vectors (CPython
||| 3.12's answers, whose algorithm the clauses transcribe) and the IEEE
||| specials in Main.idr, and the same cases as dsexpr.k vectors.
|||
||| THE TAG TEST. `x is <subject>` reads the
||| value's tag against one of [LNUL.4.9]'s twelve subjects -- a closed set,
||| [LGRA.9.3.3]'s surface -- and answers `true` or `false` for a value of
||| any kind, never `null`: a constant (`null`, `true`, `false`, `inf`,
||| `-inf`, `NaN`) tests the tag AND the value, a tag name (`Int`, `Float`,
||| `Bool`, `String`, `Bytes`, `Json`) the tag alone, and every other case is
||| `false`, a `null` value under any subject but `null` included. `is not`
||| is one operator (`lnul_4_9__is` with its flag), and `is null` is the
||| `null` subject, which [LNUL.4.4] names the total null test. An infinity
||| is pinned as the value that equals its own double and has a sign, a NaN
||| as the one unequal to itself -- the tests formal/k/dsexpr.k pins the
||| specials by. `Bytes` names a tag no value of the fragment carries, so
||| it answers `false` to every value here, the clause's "`false` in every
||| other case", and the lowering admits no such slot into a `where`;
||| `Json` is the tag of a document, since the leaf rung below.
|||
||| COALESCE (the same rung). `x ?? d` is `x` when it has a value that is
||| not `null`, else `d` ([LNUL.5.3]) -- and `d` is looked at only then
||| ([LNUL.8.9]: lazy, in every mode, and part of the meaning, since `d` may
||| fault where `x` is present). `lnul_5_3__coalesce` takes `d` unevaluated,
||| as formal/k/dsexpr.k keeps it an `Exp`, so "not looked at" is a theorem
||| over every default rather than a property of an evaluation order. A
||| trap in `x` stands: there is no value and nothing to fall back from.
||| [LNUL.5.3]'s last paragraph says so (a fault is not `null`; `x` faulting
||| is the expression's answer and `d` is not evaluated), as dsexpr.k's
||| `trap ?? _ => trap` and the fixture
||| LNUL.4.10.null_beside_a_trap_is_not_a_null already read it; the tie is
||| `proven`.
|||
||| THE CONVERSION CAST. `e :: T`
||| is total and `e :: T?` fallible ([LCST.4.2]); in the fragment the only
||| conversions are the identities ([LCST.4.5.1]), `Int :: Float`, the
||| widening to the nearest double ([LCST.4.5.2], `lexp_7_3__promote`), and
||| `Float :: Int`: a value whose truncation toward zero is an Int --
||| -2^63 <= x < 2^63, both bounds exact doubles -- gives that Int, and any
||| other, non-finite or finite and outside Int, is a hard runtime trap and
||| never `null` ([LCST.4.5.2], [LCST.4.5.4], [LERR.1.4.10]'s
||| NOT_REPRESENTABLE). The truncation is written over the primitive cast
||| with formal/k/dscast.k's one-step correction, so it is toward zero
||| whichever way the primitive rounds; dscast.k's vectors run in Main.idr,
||| and dscast.k is the executable reading this module is kept in step
||| with. A `null` under `::T?` is `null` and reaches no conversion
||| ([LCST.4.3.4], [LCST.4.2.3]); a trap in the operand stands
||| ([LNUL.4.10]); the trap never feeds `??` or the Kleene stack, a theorem
||| over every default (`lcst_4_5_4__trap_never_feeds_the_stack`). The
||| fragment has no fallible conversion -- the parses from String are
||| outside it -- so the `?` decides the `null` path alone.
|||
||| JSON LEAVES. A `Json`
||| slot holds a document ([LGRA.5.8.1]): a tree of leaves, arrays and
||| objects, `Lgra_5_8_1__json`, every key of an object named once
||| ([LGRA.5.8.7]) and every float zero in it `+0.0` ([LGRA.5.8.8],
||| `lgra_5_8_8__unsigned_zeros`). A path into it is a list of segments,
||| dotted member names and bracket indices ([LGRA.5.8.5]), and resolves
||| segment by segment or not at all (`lnul_8_4__resolve`). What a read
||| yields is [LNUL.8.4]'s: an unresolved path is `null`, ABSENCE, which is
||| not a fault ([LERR.1.3.1]); a path present with a JSON null is `null` AS
||| A VALUE, the one `null` ([LNUL.3.4]); a scalar leaf is its value, of the
||| kind it was written with; a container is the sub-document, a `Json`
||| value. `has(path)` is the one absence test and tells the two missings
||| apart ([LEXP.6.1], `lnul_8_4__has_separates_the_missings`); `len` counts
||| an array's elements and is a TypeError of anything else ([LEXP.6.2],
||| `lexp_6_2__len_is_an_arrays_alone`). A wrong-kinded leaf under an
||| operator -- a string ordered against an Int, a container in arithmetic
||| -- is a TypeError that abandons the activation ([LEXP.7.12.1]), a trap
||| here, absorbed by a deciding operand as any trap is
||| (`lexp_7_12_1__container_under_an_operator_traps`). Two documents under
||| `==` and `!=` compare by [LFAC.2.5.1]'s deep structural equality
||| ([LEXP.7.19], `lfac_2_5_1__json_eq`): member order carries no meaning,
||| an integer and a float are different kinds, the zeros are one -- the
||| first two executed here, the zeros in Main.idr, the rest by the
||| definition. The fixture runner reads a document from the lowering's
||| `json` record, decodes a `Json` slot's token to its tree, and codes a
||| whole document copied into an emitted slot by its token again
||| (Fixture.idr, THE VALUE CODE). The K lane carries no `Json`, so there is
||| nothing of this rung to keep in step there.
|||
||| STRINGS. A String value is its
||| TEXT, a sequence of Unicode codepoints ([LSTR.1.1], `Lstr_1_1__text`;
||| which codepoints a String may hold is `lstr_1_1__admissible`, and the
||| fixture runner refuses a text that breaks it where it enters). Equality
||| is codepoint by codepoint, no normalisation ([LSTR.3.1], `lstr_3_1__eq`:
||| the NFC and NFD spellings of one grapheme are two texts); the order is
||| lexicographic by codepoint value ([LSTR.3.2], `lstr_3_2__lt`), the
||| empty text below every nonempty one so that a proper prefix sorts
||| first, and the six comparisons on two Strings are the equality and the
||| order (`iret_7_5__str_order`), proved irreflexive, asymmetric,
||| transitive and total on distinct texts. `len(<String>)` is the codepoint
||| count ([LSTR.2.1], `lstr_2_1__len`), not bytes, graphemes or UTF-16
||| units, none of which a text of codepoints has; of `null` -- a `String?`
||| slot holding none -- it is a TypeError that abandons the activation
||| ([IRET.9.6]'s first arm, a builtin's receiver being a concrete-value
||| position), a trap here. The compiler types `len` by its argument, so a
||| `Json` value's `len` is `lexp_6_1__len`'s and a String's this one. The
||| casts that need the text are in the fragment now: `String :: Int?` is
||| [LCST.4.5.7]'s parse of an optional sign and an `INT_LIT` ([LLEX.11.1]:
||| decimal, `0x`, `0b`, `0o`, both digit cases for hex, a `_` separator only
||| where [LLEX.12.1] puts one, before a digit), the signed value when it
||| lies in the 64-bit range and `null` for every other text;
||| `String :: Bool?` exactly `true` / `false` ([LCST.4.5.5]); `Int :: String`
||| the exact decimal and `Bool :: String` `true` / `false` ([LCST.4.5.6]),
||| which the compiler lowers (`FN_INT_TO_STRING`,
||| `FN_BOOL_TO_STRING`) and the vectors `logical/LCST.4.5.6_*` drive; they are the
||| clause's rows, kept in step with formal/k/dscast.k and run in Main.idr.
||| A failed parse is `null`, ABSENCE, never a fault ([LNUL.8.4],
||| [LERR.1.3.1]'s third case: the value is absent, the operation is not
||| wrong), a theorem over every text (`lcst_4_5_7__parse_is_a_value_or_null`).
||| A fallible pair under the bare `::T` is [LCST.4.3.1]'s compile error,
||| which no runtime sees, a trap HERE. formal/k/dscast.k carries the same
||| parse and renders as `krun` vectors, and the fixture runner resolves
||| the lowering's string tokens to their texts through the `string`
||| records of its input (Fixture.idr, THE STRING TABLE).
|||
||| THE CONNECTIVES ABSORB A TRAP. `[LNUL.4.2]`: a `false` conjunct decides an `and` wherever it stands;
||| the `and` traps only if no conjunct is `false`, and is `null` only if none
||| is `false` and none traps; `or` is the dual. `[IRET.9.5]` lets operands be
||| evaluated in any order, `[IRET.7.6]` combines join tests the same way, and
||| `[IRET.7.5.1]` makes any equality a legal `nolinscan` anchor. So the
||| connectives commute, traps included (`lnul_4_2__and_commutes`,
||| `lnul_4_2__or_commutes`), and a trap is absorbed by a deciding operand on either
||| side (`lnul_4_2__trap_absorbed`). A left-to-right reading differs on exactly one
||| input, `trap and false`.
|||
||| NAMED RESIDUE, what no clause here states and the module decides:
|||
|||   * A `no` node BLOCKS on a trap. `[LNUL.4.7]` blocks on `true` and
|||     `null`; on a trap this module reads "blocked unless false".
|||   * An ordering (`<` `<=` `>` `>=`) on two Bools is a trap HERE. That is
|||     not DS: the compiler refuses the form, and so does the lowering,
|||     rather than let it reach this function.
|||   * A slot the environment does not decode reads as a trap. That is a
|||     lowering defect, not DS behaviour, and it surfaces in the Idris model as
|||     a missing firing rather than disappearing.
|||   * ONE TRAP KIND. [LERR.1.4.3]'s zero divisor is a ComputationError and
|||     an ill-typed operand a TypeError; the evaluator has one `RTrap` and
|||     does not tell them apart. Which of two faults an expression yields is
|||     [LNUL.4.2]'s order by kind, and Rete/WhereV5.idr is where kinds live.
|||   * A NaN is a value of the evaluator and no value of working memory
|||     ([LEXP.4.2]): the fixture runner codes no tuple that holds one (Fixture.idr,
|||     THE VALUE CODE), and the lowering refuses a NaN slot.
|||   * NUMERIC <-> Bool IS A TRAP HERE and not DS: the compiler rejects
|||     the pair ([LCST.4.5.2]) and no runtime sees it. A unit or `Json`
|||     target is refused by the lowering (`where:cast-target`).
|||   * THE SEARCH FOR THE SHORTEST DIGITS STOPS AT SEVENTEEN, which identify
|||     every double; a search that finds none by then is the parse's defect
|||     and answers with a trap at the cast, never with a text.
|||   * A TEXT NO STRING CAN HOLD -- a codepoint outside [LSTR.1.1]'s range --
|||     is compared and counted like any other here: the model's functions
|||     are total on every list of naturals, and admissibility is the
|||     runner's to refuse where a text enters (Fixture.idr).
|||   * A BARE `null :: T` is a trap HERE. In DS it is a compile error
|||     ([LCST.4.2.3], [LCST.4.3.1]) that no runtime sees; the model has to
|||     answer something for the form, and answers as for a value it cannot
|||     convert.
|||   * A SEGMENT INTO A VALUE THAT IS NOT ITS CONTAINER -- a key into an
|||     array or a leaf, an index into an object or a leaf -- leaves the
|||     path UNRESOLVED, absence and `null`, not a TypeError: the reading
|||     this module takes of [LNUL.8.4]'s "resolves", which no clause
|||     spells out (`lnul_8_4__a_segment_into_a_leaf_is_absent`). The engine
|||     comparison is where a different answer from libds would show.
|||   * `has(<path>)` OF A `null` ROOT (a `Json?` slot holding none) is
|||     `false` HERE: nothing resolves in no document. [LNUL.8.4] states the
|||     test over a document; a null root is [LNUL.4.1]'s territory and the
|||     clauses do not meet. No fixture reaches it.
|||   * A PATH READ ON A VALUE OF ANY OTHER KIND is a trap HERE and not DS:
|||     the compiler refuses a path past a slot that is not `Json`
|||     ([LGRA.5.8.5]), and the lowering admits none.
|||   * TWO CONTAINERS UNDER `==` compare deeply HERE ([LFAC.2.5.1]'s
|||     equality, as [LEXP.7.19] applies it to whole documents); a
|||     sub-document's comparison is one [LEXP.7.12.1] leaves to its kind,
|||     and libds answers it by the containers' serialised text. The two
|||     agree where the text is canonical; no fixture compares two
|||     containers.
module Rete.Eval

import Rete.FireLoop
import Data.List
import Data.Maybe

%default total

-- ---------------------------------------------------------------------
-- Values, results and answers
-- ---------------------------------------------------------------------

--@spec [LSTR.1.1]
||| The text of a String value: a sequence of Unicode codepoints
||| ([LSTR.1.1]), each a natural. Which codepoints a String may hold is
||| `lstr_1_1__admissible`; the fixture runner refuses a text that breaks it
||| where it enters, so every text the model is run on is admissible, and
||| the invariant is not carried as an index here.
public export
Lstr_1_1__text : Type
Lstr_1_1__text = List Nat

--@spec [LSTR.1.1]
||| Whether a codepoint may stand in a String: `U+0001` to `U+10FFFF`, less
||| the surrogates `U+D800` to `U+DFFF`; never `U+0000`.
public export
lstr_1_1__admissible : Nat -> Bool
lstr_1_1__admissible c = c >= 1 && c <= 1114111 && not (c >= 55296 && c <= 57343)

--@spec [LSTR.1.1]
||| Whether every codepoint of a text is admissible.
public export
lstr_1_1__text_admissible : Lstr_1_1__text -> Bool
lstr_1_1__text_admissible []        = True
lstr_1_1__text_admissible (c :: cs) = lstr_1_1__admissible c && lstr_1_1__text_admissible cs

--@spec [LGRA.5.8.1]
--@spec [LGRA.5.8.7]
||| A `Json` value, the document a `Json` slot holds ([LGRA.5.8.1]): a
||| leaf -- the JSON null, a Bool, an integer, a float, a string (its text,
||| as a String value is) -- an array of values, or an
||| object of members, each a key token and a value. An integer and a float
||| are two leaf kinds, as they are written ([LEXP.7.12.1]). [LGRA.5.8.7]
||| names each key of an object once: `lgra_5_8_7__keys_unique` decides it,
||| and the fixture runner refuses a document that breaks it, so the
||| invariant holds of every document the model is run on and is not
||| carried as an index here.
public export
data Lgra_5_8_1__json : Type where
  JNull  : Lgra_5_8_1__json
  JBool  : Bool -> Lgra_5_8_1__json
  JInt   : Integer -> Lgra_5_8_1__json
  JFloat : Double -> Lgra_5_8_1__json
  JStr   : Lstr_1_1__text -> Lgra_5_8_1__json
  JArr   : List Lgra_5_8_1__json -> Lgra_5_8_1__json
  JObj   : List (Nat, Lgra_5_8_1__json) -> Lgra_5_8_1__json

--@spec [LGRA.5.8.7]
||| Whether a list of keys names each once.
public export
lgra_5_8_7__keys_once : List Nat -> Bool
lgra_5_8_7__keys_once []        = True
lgra_5_8_7__keys_once (k :: ks) = not (elem k ks) && lgra_5_8_7__keys_once ks

-- The three walks over a document below recurse through its arrays and
-- objects by a list function each, declared ahead of their clauses so the
-- recursion is mutual without a `mutual` block, which would indent the
-- elements off column 0 and out of the crossref's sight.

--@spec [LGRA.5.8.7]
||| Whether every object in a document names each of its keys once.
public export
lgra_5_8_7__keys_unique : Lgra_5_8_1__json -> Bool

--@spec [LGRA.5.8.7]
||| ... in each element of an array.
public export
lgra_5_8_7__keys_unique_list : List Lgra_5_8_1__json -> Bool

--@spec [LGRA.5.8.7]
||| ... in each value of an object's members.
public export
lgra_5_8_7__keys_unique_members : List (Nat, Lgra_5_8_1__json) -> Bool

lgra_5_8_7__keys_unique (JArr xs) = lgra_5_8_7__keys_unique_list xs
lgra_5_8_7__keys_unique (JObj ms) = lgra_5_8_7__keys_once (map fst ms) && lgra_5_8_7__keys_unique_members ms
lgra_5_8_7__keys_unique _         = True

lgra_5_8_7__keys_unique_list []        = True
lgra_5_8_7__keys_unique_list (x :: xs) = lgra_5_8_7__keys_unique x && lgra_5_8_7__keys_unique_list xs

lgra_5_8_7__keys_unique_members []             = True
lgra_5_8_7__keys_unique_members ((_, v) :: ms) = lgra_5_8_7__keys_unique v && lgra_5_8_7__keys_unique_members ms

--@spec [LGRA.5.8.8]
||| The fold on one float, the decision taken first: `+0.0` when the float
||| is a zero (IEEE `==` makes `-0.0 == 0.0`, so the sign is what the fold
||| drops), the float itself otherwise. Named, rather than an `if` inside
||| the walk, so a theorem can rewrite the decision.
public export
lgra_5_8_8__fold_float : Bool -> Double -> Double
lgra_5_8_8__fold_float True  _ = 0.0
lgra_5_8_8__fold_float False x = x

--@spec [LGRA.5.8.8]
||| Every float zero a `Json` value holds is `+0.0`: the fold a runtime
||| applies wherever a `Json` value comes into being. The zero stays a
||| float; an integer `0` is untouched, and so is every nonzero value.
public export
lgra_5_8_8__unsigned_zeros : Lgra_5_8_1__json -> Lgra_5_8_1__json

--@spec [LGRA.5.8.8]
||| The fold over an array's elements.
public export
lgra_5_8_8__unsigned_zeros_list : List Lgra_5_8_1__json -> List Lgra_5_8_1__json

--@spec [LGRA.5.8.8]
||| The fold over an object's members.
public export
lgra_5_8_8__unsigned_zeros_members : List (Nat, Lgra_5_8_1__json) -> List (Nat, Lgra_5_8_1__json)

lgra_5_8_8__unsigned_zeros (JFloat x) = JFloat (lgra_5_8_8__fold_float (x == 0.0) x)
lgra_5_8_8__unsigned_zeros (JArr xs)  = JArr (lgra_5_8_8__unsigned_zeros_list xs)
lgra_5_8_8__unsigned_zeros (JObj ms)  = JObj (lgra_5_8_8__unsigned_zeros_members ms)
lgra_5_8_8__unsigned_zeros j          = j

lgra_5_8_8__unsigned_zeros_list []        = []
lgra_5_8_8__unsigned_zeros_list (x :: xs) = lgra_5_8_8__unsigned_zeros x :: lgra_5_8_8__unsigned_zeros_list xs

lgra_5_8_8__unsigned_zeros_members []             = []
lgra_5_8_8__unsigned_zeros_members ((k, v) :: ms) = (k, lgra_5_8_8__unsigned_zeros v) :: lgra_5_8_8__unsigned_zeros_members ms

--@spec [LFAC.2.5.1]
--@spec [LEXP.7.19]
||| Deep structural equality of two `Json` values, [LFAC.2.5.1]'s: the
||| same kind and -- two objects, the same set of keys with equal values
||| under each, member order carrying no meaning (every member of either
||| has a member of the other with its key and an equal value); two
||| arrays, the same length with equal elements position by position; two
||| strings the same text ([LSTR.3.1]), two Bools the same value, two nulls
||| equal; two integers the same value, and two floats IEEE `==`, so `0.0`
||| equals `-0.0`. An integer and a float are different kinds and never
||| equal. What `==` and `!=` answer on two `Json` operands ([LEXP.7.19]).
public export
lfac_2_5_1__json_eq : Lgra_5_8_1__json -> Lgra_5_8_1__json -> Bool

--@spec [LFAC.2.5.1]
||| Two arrays' elements, position by position, over equal lengths.
public export
lfac_2_5_1__json_eq_list : List Lgra_5_8_1__json -> List Lgra_5_8_1__json -> Bool

--@spec [LFAC.2.5.1]
||| Every member of the first object has, in the second, a member with its
||| key and an equal value.
public export
lfac_2_5_1__members_in : List (Nat, Lgra_5_8_1__json) -> List (Nat, Lgra_5_8_1__json) -> Bool

--@spec [LFAC.2.5.1]
||| The first object's member under `k` with the value `v` has a match in
||| the second: the same key and an equal value.
public export
lfac_2_5_1__member_in : Nat -> Lgra_5_8_1__json -> List (Nat, Lgra_5_8_1__json) -> Bool

--@spec [LFAC.2.5.1]
||| Every member of the second object has, in the first, a member with its
||| key and an equal value -- the first object's values on the left of every
||| equality, as in `lfac_2_5_1__members_in`.
public export
lfac_2_5_1__members_covered : List (Nat, Lgra_5_8_1__json) -> List (Nat, Lgra_5_8_1__json) -> Bool

--@spec [LFAC.2.5.1]
||| Some member of the first object has the key `k'` and a value equal to
||| `v'`.
public export
lfac_2_5_1__member_covers : List (Nat, Lgra_5_8_1__json) -> Nat -> Lgra_5_8_1__json -> Bool

lfac_2_5_1__json_eq JNull      JNull      = True
lfac_2_5_1__json_eq (JBool a)  (JBool b)  = a == b
lfac_2_5_1__json_eq (JInt a)   (JInt b)   = a == b
lfac_2_5_1__json_eq (JFloat a) (JFloat b) = a == b
lfac_2_5_1__json_eq (JStr a)   (JStr b)   = a == b
lfac_2_5_1__json_eq (JArr xs)  (JArr ys)  = lfac_2_5_1__json_eq_list xs ys
lfac_2_5_1__json_eq (JObj xs)  (JObj ys)  = lfac_2_5_1__members_in xs ys && lfac_2_5_1__members_covered xs ys
lfac_2_5_1__json_eq _          _          = False

lfac_2_5_1__json_eq_list []        []        = True
lfac_2_5_1__json_eq_list (x :: xs) (y :: ys) = lfac_2_5_1__json_eq x y && lfac_2_5_1__json_eq_list xs ys
lfac_2_5_1__json_eq_list _         _         = False

lfac_2_5_1__members_in []             ys = True
lfac_2_5_1__members_in ((k, v) :: xs) ys = lfac_2_5_1__member_in k v ys && lfac_2_5_1__members_in xs ys

lfac_2_5_1__member_in k v []               = False
lfac_2_5_1__member_in k v ((k', v') :: ys) = (k == k' && lfac_2_5_1__json_eq v v') || lfac_2_5_1__member_in k v ys

lfac_2_5_1__members_covered xs []               = True
lfac_2_5_1__members_covered xs ((k', v') :: ys) = lfac_2_5_1__member_covers xs k' v' && lfac_2_5_1__members_covered xs ys

lfac_2_5_1__member_covers []             k' v' = False
lfac_2_5_1__member_covers ((k, v) :: xs) k' v' = (k == k' && lfac_2_5_1__json_eq v v') || lfac_2_5_1__member_covers xs k' v'

--@spec [LNUL.2.1]
||| A value in the fragment: an Int, an IEEE binary64 Float, a String (its
||| text), a Bool, a `Json` document, or the one `null`.
public export
data Lnul_2_1__value : Type where
  VInt   : Integer -> Lnul_2_1__value
  VFloat : Double -> Lnul_2_1__value
  VStr   : Lstr_1_1__text -> Lnul_2_1__value
  VBool  : Bool -> Lnul_2_1__value
  VJson  : Lgra_5_8_1__json -> Lnul_2_1__value
  VNull  : Lnul_2_1__value

--@spec [LERR.1.4.1]
||| What evaluating an expression yields: a value, or a trap — no honest
||| answer, `null` included.
public export
data Lerr_1_4_1__result : Type where
  RVal  : Lnul_2_1__value -> Lerr_1_4_1__result
  RTrap : Lerr_1_4_1__result

--@spec [LNUL.4.2]
||| The four answers a join test gives a pair: the three Kleene truth values
||| and a trap.
public export
data Lnul_4_2__answer : Type where
  KTrue  : Lnul_4_2__answer
  KFalse : Lnul_4_2__answer
  KNull  : Lnul_4_2__answer
  KTrap  : Lnul_4_2__answer

--@spec [LNUL.4.2]
||| The answer a result gives as a predicate. A value that is not a Bool
||| has no truth value: an ill-typed `where`, which the compiler refuses and
||| `[IRET.9.6]` makes a fault, so it answers as a trap.
public export
lnul_4_2__answer_of : Lerr_1_4_1__result -> Lnul_4_2__answer
lnul_4_2__answer_of (RVal (VBool True))  = KTrue
lnul_4_2__answer_of (RVal (VBool False)) = KFalse
lnul_4_2__answer_of (RVal VNull)         = KNull
lnul_4_2__answer_of (RVal _)             = KTrap
lnul_4_2__answer_of RTrap                = KTrap

--@spec [LNUL.4.2]
||| An answer as a result again, so a connective's output can be an operand.
public export
lnul_4_2__result_of : Lnul_4_2__answer -> Lerr_1_4_1__result
lnul_4_2__result_of KTrue  = RVal (VBool True)
lnul_4_2__result_of KFalse = RVal (VBool False)
lnul_4_2__result_of KNull  = RVal VNull
lnul_4_2__result_of KTrap  = RTrap

-- ---------------------------------------------------------------------
-- The connectives: Kleene's, a trap absorbed by a deciding operand
-- ---------------------------------------------------------------------

--@spec [LNUL.4.2]
--@spec [IRET.9.5]
||| `and`. A `false` on either side decides; otherwise a trap on either side
||| is raised; otherwise `null` on either side gives `null`; otherwise `true`.
public export
lnul_4_2__and : Lnul_4_2__answer -> Lnul_4_2__answer -> Lnul_4_2__answer
lnul_4_2__and KFalse _      = KFalse
lnul_4_2__and _      KFalse = KFalse
lnul_4_2__and KTrap  _      = KTrap
lnul_4_2__and _      KTrap  = KTrap
lnul_4_2__and KNull  _      = KNull
lnul_4_2__and _      KNull  = KNull
lnul_4_2__and KTrue  KTrue  = KTrue

--@spec [LNUL.4.2]
--@spec [IRET.9.5]
||| `or`, dually: a `true` on either side decides.
public export
lnul_4_2__or : Lnul_4_2__answer -> Lnul_4_2__answer -> Lnul_4_2__answer
lnul_4_2__or KTrue  _      = KTrue
lnul_4_2__or _      KTrue  = KTrue
lnul_4_2__or KTrap  _      = KTrap
lnul_4_2__or _      KTrap  = KTrap
lnul_4_2__or KNull  _      = KNull
lnul_4_2__or _      KNull  = KNull
lnul_4_2__or KFalse KFalse = KFalse

--@spec [LNUL.4.2]
||| `not` swaps true and false and fixes `null`; a trap stays a trap.
public export
lnul_4_2__not : Lnul_4_2__answer -> Lnul_4_2__answer
lnul_4_2__not KTrue  = KFalse
lnul_4_2__not KFalse = KTrue
lnul_4_2__not KNull  = KNull
lnul_4_2__not KTrap  = KTrap

--@derives [LNUL.4.2]
||| The clause's own table, row by row, and its three `not` cells.
public export
lnul_4_2__table :
  ( lnul_4_2__and KTrue KNull = KNull, lnul_4_2__or KTrue KNull = KTrue
  , lnul_4_2__and KFalse KNull = KFalse, lnul_4_2__or KFalse KNull = KNull
  , lnul_4_2__and KNull KNull = KNull, lnul_4_2__or KNull KNull = KNull
  , lnul_4_2__not KTrue = KFalse, lnul_4_2__not KFalse = KTrue
  , lnul_4_2__not KNull = KNull )
lnul_4_2__table = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LNUL.4.2]
--@derives [IRET.9.5]
||| `and` COMMUTES, traps included: `a and b` and `b and a` agree on every
||| input, so the operands may be evaluated in any order. This is the reason any equality is a legal `nolinscan`
||| anchor ([IRET.7.5.1]).
public export
lnul_4_2__and_commutes : (a, b : Lnul_4_2__answer) -> lnul_4_2__and a b = lnul_4_2__and b a
lnul_4_2__and_commutes KTrue  KTrue  = Refl
lnul_4_2__and_commutes KTrue  KFalse = Refl
lnul_4_2__and_commutes KTrue  KNull  = Refl
lnul_4_2__and_commutes KTrue  KTrap  = Refl
lnul_4_2__and_commutes KFalse KTrue  = Refl
lnul_4_2__and_commutes KFalse KFalse = Refl
lnul_4_2__and_commutes KFalse KNull  = Refl
lnul_4_2__and_commutes KFalse KTrap  = Refl
lnul_4_2__and_commutes KNull  KTrue  = Refl
lnul_4_2__and_commutes KNull  KFalse = Refl
lnul_4_2__and_commutes KNull  KNull  = Refl
lnul_4_2__and_commutes KNull  KTrap  = Refl
lnul_4_2__and_commutes KTrap  KTrue  = Refl
lnul_4_2__and_commutes KTrap  KFalse = Refl
lnul_4_2__and_commutes KTrap  KNull  = Refl
lnul_4_2__and_commutes KTrap  KTrap  = Refl

--@derives [LNUL.4.2]
--@derives [IRET.9.5]
||| And so does `or`.
public export
lnul_4_2__or_commutes : (a, b : Lnul_4_2__answer) -> lnul_4_2__or a b = lnul_4_2__or b a
lnul_4_2__or_commutes KTrue  KTrue  = Refl
lnul_4_2__or_commutes KTrue  KFalse = Refl
lnul_4_2__or_commutes KTrue  KNull  = Refl
lnul_4_2__or_commutes KTrue  KTrap  = Refl
lnul_4_2__or_commutes KFalse KTrue  = Refl
lnul_4_2__or_commutes KFalse KFalse = Refl
lnul_4_2__or_commutes KFalse KNull  = Refl
lnul_4_2__or_commutes KFalse KTrap  = Refl
lnul_4_2__or_commutes KNull  KTrue  = Refl
lnul_4_2__or_commutes KNull  KFalse = Refl
lnul_4_2__or_commutes KNull  KNull  = Refl
lnul_4_2__or_commutes KNull  KTrap  = Refl
lnul_4_2__or_commutes KTrap  KTrue  = Refl
lnul_4_2__or_commutes KTrap  KFalse = Refl
lnul_4_2__or_commutes KTrap  KNull  = Refl
lnul_4_2__or_commutes KTrap  KTrap  = Refl

--@derives [LNUL.4.2]
--@derives [IRET.9.5]
||| A TRAP IS ABSORBED BY A DECIDING OPERAND, on either side, and raised
||| otherwise, as cells of the table -- `trap and false` and `false and trap` are `false`, `trap and
||| true` traps; `trap or true` and `true or trap` are `true`, `trap or
||| false` traps.
public export
lnul_4_2__trap_absorbed :
  ( lnul_4_2__and KTrap KFalse = KFalse, lnul_4_2__and KFalse KTrap = KFalse, lnul_4_2__and KTrap KTrue = KTrap
  , lnul_4_2__or KTrap KTrue = KTrue, lnul_4_2__or KTrue KTrap = KTrue, lnul_4_2__or KTrap KFalse = KTrap )
lnul_4_2__trap_absorbed = (Refl, Refl, Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- What a node does with an answer
-- ---------------------------------------------------------------------

--@spec [LNUL.4.3]
||| A positive node admits a pair iff its tests answer `true`.
public export
lnul_4_3__admits : Lnul_4_2__answer -> Bool
lnul_4_3__admits KTrue = True
lnul_4_3__admits _     = False

--@spec [LNUL.4.7]
||| A `no` node is blocked by a candidate unless its tests answer `false`:
||| `true` and `null` block per the clause; a trap blocks per the residue
||| in the header.
public export
lnul_4_7__blocks : Lnul_4_2__answer -> Bool
lnul_4_7__blocks KFalse = False
lnul_4_7__blocks _      = True

--@derives [LNUL.4.3]
||| Only `true` is admitted.
public export
lnul_4_3__admits_only_true :
  (a : Lnul_4_2__answer) -> lnul_4_3__admits a = True -> a = KTrue
lnul_4_3__admits_only_true KTrue  _ = Refl
lnul_4_3__admits_only_true KFalse p = absurd p
lnul_4_3__admits_only_true KNull  p = absurd p
lnul_4_3__admits_only_true KTrap  p = absurd p

--@derives [LNUL.4.7]
||| Only `false` lets a `no` pattern pass.
public export
lnul_4_7__only_false_passes :
  (a : Lnul_4_2__answer) -> lnul_4_7__blocks a = False -> a = KFalse
lnul_4_7__only_false_passes KFalse _ = Refl
lnul_4_7__only_false_passes KTrue  p = absurd p
lnul_4_7__only_false_passes KNull  p = absurd p
lnul_4_7__only_false_passes KTrap  p = absurd p

--@derives [LNUL.4.7]
--@derives [LNUL.4.3]
||| ONE RULE AT TWO SITES, as `[LNUL.4.7]` says: an answer that is neither
||| `true` nor `false` is not admitted positively AND blocks under `no`.
||| "`null` behaves like `false` positively, like `true` under negation" —
||| for every undecided answer, not only `null`.
public export
lnul_4_7__undecided_neither_admits_nor_passes :
  (a : Lnul_4_2__answer) -> Not (a = KTrue) -> Not (a = KFalse) ->
  (lnul_4_3__admits a = False, lnul_4_7__blocks a = True)
lnul_4_7__undecided_neither_admits_nor_passes KTrue  nt _  = absurd (nt Refl)
lnul_4_7__undecided_neither_admits_nor_passes KFalse _  nf = absurd (nf Refl)
lnul_4_7__undecided_neither_admits_nor_passes KNull  _  _  = (Refl, Refl)
lnul_4_7__undecided_neither_admits_nor_passes KTrap  _  _  = (Refl, Refl)

-- ---------------------------------------------------------------------
-- Value-level operators
-- ---------------------------------------------------------------------

--@spec [LEXP.7.13.1]
||| 64-bit two's-complement wrap: overflow wraps silently.
public export
lexp_7_13_1__wrap : Integer -> Integer
lexp_7_13_1__wrap n =
  let m  = n `mod` 18446744073709551616
      m1 = if m < 0 then m + 18446744073709551616 else m
  in if m1 >= 9223372036854775808 then m1 - 18446744073709551616 else m1

--@spec [LEXP.7.2]
||| The arithmetic operators of the fragment: `+ - * / // %`.
public export
data Lexp_7_2__arith : Type where
  OpAdd      : Lexp_7_2__arith
  OpSub      : Lexp_7_2__arith
  OpMul      : Lexp_7_2__arith
  OpDiv      : Lexp_7_2__arith
  OpFloorDiv : Lexp_7_2__arith
  OpMod      : Lexp_7_2__arith

--@spec [LEXP.7.3]
||| An Int promoted to a Float: the nearest binary64, ties to even
||| ([LDET.3.6.1]); exact below 2^53 and rounded above it ([LEXP.7.3b]).
public export
lexp_7_3__promote : Integer -> Double
lexp_7_3__promote = cast

-- The IEEE specials, pinned by the tests dsexpr.k pins them by. Defined here,
-- above the arithmetic, because the exact remainder reads them.

--@spec [LNUL.4.9]
||| A NaN: the one value unequal to itself ([LDET.3.6.2]).
public export
lnul_4_9__nan : Double -> Bool
lnul_4_9__nan x = x /= x

--@spec [LNUL.4.9]
||| The positive infinity: the value that equals its own double and lies
||| above zero. No finite nonzero double equals its double, the sign test
||| excludes the two zeros, and a NaN fails every comparison.
public export
lnul_4_9__inf : Double -> Bool
lnul_4_9__inf x = x > 0.0 && x * 2.0 == x

--@spec [LNUL.4.9]
||| The negative infinity, likewise below zero.
public export
lnul_4_9__neg_inf : Double -> Bool
lnul_4_9__neg_inf x = x < 0.0 && x * 2.0 == x

--@spec [LEXP.7.15.1]
||| A Float zero divisor, either zero. With a Float operand the operation is
||| IEEE 754's and nothing traps: `//` by zero is the quotient `a / b` (`±Inf`
||| for a nonzero dividend, NaN for a zero one) and `%` by zero is NaN.
||| `lexp_7_5__float_floordiv` and `lexp_7_6__float_mod` take this row before
||| the composition.
public export
lexp_7_15_1__float_zero_divisor : Double -> Bool
lexp_7_15_1__float_zero_divisor b = b == 0.0

--@spec [LEXP.7.6]
||| The magnitude of a Float: `-0.0` to `+0.0` by the addition (the sum of
||| the two zeros is `+0.0` under round-to-nearest), every other value to
||| itself or its negation.
public export
lexp_7_6__abs : Double -> Double
lexp_7_6__abs x = if x < 0.0 then negate x else x + 0.0

--@spec [LEXP.7.6]
||| One subtraction of the exact remainder's loop, on magnitudes: the
||| largest `d * 2^k` not above `r`, found by doubling, is taken from `r`.
||| Since `d <= r < 2d` the difference is representable (Sterbenz's lemma:
||| the difference of two doubles within a factor of two of each other is
||| exact), and `r - d < d`, so what is left has an exponent below `r`'s.
||| The doubling never overflows past the test: a `2d` above the largest
||| finite double is an infinity, which is not at or below `r`. The fuel
||| bounds the doublings; fewer than 2,100 separate the smallest subnormal
||| from the largest finite value, so 4096 is never spent, and on the fuel
||| running out the subtraction is of what was reached, still at or below `r`.
public export
lexp_7_6__strip : Nat -> Double -> Double -> Double
lexp_7_6__strip Z     r d = r - d
lexp_7_6__strip (S k) r d = if d * 2.0 <= r then lexp_7_6__strip k r (d * 2.0) else r - d

--@spec [LEXP.7.6]
||| The loop: while `r` is at or above `b`, subtract -- both non-negative,
||| `b` nonzero and finite. Each round leaves a value whose exponent is below
||| the exponent of the round before, so the exponent span bounds the rounds
||| as it bounds the doublings, and the fuel is that bound.
public export
lexp_7_6__reduce : Nat -> Double -> Double -> Double
lexp_7_6__reduce Z     r b = r
lexp_7_6__reduce (S n) r b = if r >= b then lexp_7_6__reduce n (lexp_7_6__strip 4096 r b) b else r

--@spec [LEXP.7.6]
||| `r` with `a`'s sign: negated when `a` is below zero or is `-0.0`, which
||| the reciprocal tells from `+0.0`.
public export
lexp_7_6__sign_as : Double -> Double -> Double
lexp_7_6__sign_as r a = if a < 0.0 || (a == 0.0 && 1.0 / a < 0.0) then negate r else r

--@spec [LEXP.7.6]
||| Step 1: `a - b * trunc(a / b)`, computed EXACTLY -- the remainder of the
||| quotient truncated toward zero, which always has a representable value
||| and carries `a`'s sign -- as the magnitudes' loop with `a`'s sign put
||| back, never through a rounded quotient. NaN when `a` is infinite or
||| either operand is NaN, and `a` when `b` is infinite and `a` finite: the
||| clause's own rows. A zero `b` is never consulted, the zero divisor being
||| [LEXP.7.15.1]'s row and taken first; on one the loop would not reach
||| the base case, and the fuel ends it.
public export
lexp_7_6__exact_remainder : Double -> Double -> Double
lexp_7_6__exact_remainder a b =
  if lnul_4_9__nan a || lnul_4_9__nan b then a + b
  else if lnul_4_9__inf a || lnul_4_9__neg_inf a then 0.0 / 0.0
  else if lnul_4_9__inf b || lnul_4_9__neg_inf b then a
  else lexp_7_6__sign_as (lexp_7_6__reduce 4096 (lexp_7_6__abs a) (lexp_7_6__abs b)) a

--@spec [LEXP.7.6]
||| Steps 2 and 3 over the exact remainder `r` of `a` by the nonzero `b`: a
||| nonzero `r` whose sign differs from `b`'s moves by `b`, rounded once; a
||| zero `r` is a zero with `b`'s sign; otherwise the result is `r`. A NaN
||| `r` stays NaN: it is unequal to zero and below nothing, so at most `b`
||| is added to it.
public export
lexp_7_6__mod_of : Double -> Double -> Double
lexp_7_6__mod_of b r =
  if r /= 0.0 && ((r < 0.0) /= (b < 0.0)) then r + b
  else if r == 0.0 then (if b < 0.0 then negate 0.0 else 0.0)
  else r

--@spec [LEXP.7.6]
--@spec [LEXP.7.15.1]
||| `%` with a Float operand: [LEXP.7.15.1]'s row on a zero divisor (NaN),
||| else [LEXP.7.6]'s composition over the exact remainder.
public export
lexp_7_6__float_mod : Double -> Double -> Double
lexp_7_6__float_mod a b =
  if lexp_7_15_1__float_zero_divisor b then 0.0 / 0.0
  else lexp_7_6__mod_of b (lexp_7_6__exact_remainder a b)

--@spec [LEXP.7.5]
||| A zero with the sign of `x`: `-0.0` when `x` is below zero or is `-0.0`
||| (the reciprocal tells the two zeros apart), `+0.0` otherwise.
public export
lexp_7_5__zero_with_sign_of : Double -> Double
lexp_7_5__zero_with_sign_of x = if x < 0.0 || (x == 0.0 && 1.0 / x < 0.0) then negate 0.0 else 0.0

--@spec [LEXP.7.5]
||| Steps 1 to 4 over the exact remainder `r` of `a` by the nonzero `b`:
||| `q = (a - r) / b`, the subtraction and the division each rounded once;
||| `q - 1`, rounded once, when [LEXP.7.6]'s step 2 adjusted `r`; a zero
||| `q` is a zero with the sign of `a / b`; otherwise `f = floor q`, and the
||| result is `f + 1` when `q - f` exceeds a half, else `f`. A NaN `q` is
||| unequal to zero, its floor is NaN and the test fails, so it gives NaN.
public export
lexp_7_5__floordiv_of : Double -> Double -> Double -> Double
lexp_7_5__floordiv_of a b r =
  let adjusted = r /= 0.0 && ((r < 0.0) /= (b < 0.0))
      q0 = (a - r) / b
      q  = if adjusted then q0 - 1.0 else q0
  in if q == 0.0 then lexp_7_5__zero_with_sign_of (a / b)
     else let f = floor q in (if q - f > 0.5 then f + 1.0 else f)

--@spec [LEXP.7.5]
--@spec [LEXP.7.15.1]
||| `//` with a Float operand: [LEXP.7.15.1]'s row on a zero divisor (the
||| IEEE quotient `a / b`, `±Inf` or NaN), else [LEXP.7.5]'s composition
||| over the exact remainder.
public export
lexp_7_5__float_floordiv : Double -> Double -> Double
lexp_7_5__float_floordiv a b =
  if lexp_7_15_1__float_zero_divisor b then a / b
  else lexp_7_5__floordiv_of a b (lexp_7_6__exact_remainder a b)

--@spec [LEXP.7.3]
--@spec [LDET.3.6.2]
--@spec [LEXP.7.15.1]
--@spec [LEXP.7.5]
--@spec [LEXP.7.6]
||| Float op Float, IEEE 754: `+ - * /` rounded to nearest even, and an
||| infinity or a NaN returned, never a trap -- `x / 0.0` is `±Inf` for a
||| nonzero `x` and NaN for `0.0 / 0.0`; `//` and `%` the compositions of
||| [LEXP.7.5] and [LEXP.7.6] over the exact remainder, a zero divisor
||| taking [LEXP.7.15.1]'s IEEE row inside each.
public export
lexp_7_3__float_op : Lexp_7_2__arith -> Double -> Double -> Lerr_1_4_1__result
lexp_7_3__float_op OpAdd      a b = RVal (VFloat (a + b))
lexp_7_3__float_op OpSub      a b = RVal (VFloat (a - b))
lexp_7_3__float_op OpMul      a b = RVal (VFloat (a * b))
lexp_7_3__float_op OpDiv      a b = RVal (VFloat (a / b))
lexp_7_3__float_op OpFloorDiv a b = RVal (VFloat (lexp_7_5__float_floordiv a b))
lexp_7_3__float_op OpMod      a b = RVal (VFloat (lexp_7_6__float_mod a b))

--@spec [LEXP.7.5]
--@spec [LEXP.7.6]
||| Floor division and modulo of two Ints with a NONZERO divisor, as one
||| pair: the quotient rounds toward negative infinity ([LEXP.7.5]: `7 // 2`
||| is 3, `-7 // 2` is -4) and a nonzero remainder takes the divisor's sign
||| ([LEXP.7.6]: `-7 % 3` is 2), so that `a = q * b + r` with `r` between 0
||| and `b`. Written over the primitive `div` with the remainder recomputed
||| as `a - q * b` and the pair adjusted once when that remainder has the
||| wrong sign, so it is the floor pair whether the primitive truncates
||| (Chez's `quotient`, which Idris 2's `div` is) or floors; Main.idr runs
||| the clauses' own examples through it. Never consulted on a zero divisor:
||| that is [LEXP.7.15.1]'s trap, raised first by `lexp_7_2__int_op`.
public export
lexp_7_5__divmod : Integer -> Integer -> (Integer, Integer)
lexp_7_5__divmod a b =
  let q = a `div` b
      r = a - q * b
  in if r /= 0 && ((r < 0) /= (b < 0)) then (q - 1, r + b) else (q, r)

--@spec [LEXP.7.15.1]
||| The operators that read a divisor, and an Int zero one: `/`, `//` and
||| `%`. With every operand Int the operation is a runtime error
||| ([LERR.1.4.3]), `/` included though its result is a Float; with a Float
||| operand it is IEEE 754's (`lexp_7_3__float_op`, the zero row of
||| `lexp_7_15_1__float_zero_divisor`), and this is never consulted.
public export
lexp_7_15_1__zero_divisor : Lexp_7_2__arith -> Integer -> Bool
lexp_7_15_1__zero_divisor OpDiv      b = b == 0
lexp_7_15_1__zero_divisor OpFloorDiv b = b == 0
lexp_7_15_1__zero_divisor OpMod      b = b == 0
lexp_7_15_1__zero_divisor _          _ = False

--@spec [LEXP.7.4]
||| The Float quotient of two Ints: their promotions divided, IEEE's
||| ([LEXP.7.4]: `/` always produces a Float).
public export
lexp_7_4__quotient : Integer -> Integer -> Lnul_2_1__value
lexp_7_4__quotient a b = VFloat (lexp_7_3__promote a / lexp_7_3__promote b)

--@spec [LEXP.7.4]
--@spec [LEXP.7.15.1]
||| `/` on two Ints with the divisor test decided: a trap on a zero divisor
||| ([LEXP.7.15.1]), else the Float quotient. A named split rather than an
||| `if`, so a theorem can reason about the test left undecided.
public export
lexp_7_4__guarded : Bool -> Integer -> Integer -> Lerr_1_4_1__result
lexp_7_4__guarded True  _ _ = RTrap
lexp_7_4__guarded False a b = RVal (lexp_7_4__quotient a b)

--@spec [LEXP.7.2]
--@spec [LEXP.7.4]
--@spec [LEXP.7.13.1]
--@spec [LEXP.7.15.1]
||| Int op Int is Int, wrapped, except `/`, which promotes both operands and
||| yields a Float ([LEXP.7.4]); and a zero divisor under `/`, `//` or `%`
||| is a runtime error, a trap, before any division. `INT64_MIN // -1` is
||| 2^63, which the wrap makes `INT64_MIN`; `INT64_MIN % -1` is 0.
public export
lexp_7_2__int_op : Lexp_7_2__arith -> Integer -> Integer -> Lerr_1_4_1__result
lexp_7_2__int_op OpAdd      a b = RVal (VInt (lexp_7_13_1__wrap (a + b)))
lexp_7_2__int_op OpSub      a b = RVal (VInt (lexp_7_13_1__wrap (a - b)))
lexp_7_2__int_op OpMul      a b = RVal (VInt (lexp_7_13_1__wrap (a * b)))
lexp_7_2__int_op OpDiv      a b = lexp_7_4__guarded (lexp_7_15_1__zero_divisor OpDiv b) a b
lexp_7_2__int_op OpFloorDiv a b =
  if lexp_7_15_1__zero_divisor OpFloorDiv b then RTrap
  else RVal (VInt (lexp_7_13_1__wrap (fst (lexp_7_5__divmod a b))))
lexp_7_2__int_op OpMod      a b =
  if lexp_7_15_1__zero_divisor OpMod b then RTrap
  else RVal (VInt (lexp_7_13_1__wrap (snd (lexp_7_5__divmod a b))))

--@spec [LNUL.4.1]
||| The right operand, once the left one has had no answer to give: `null`
||| propagates, anything else is ill-typed.
public export
lnul_4_1__null_or_trap : Lnul_2_1__value -> Lerr_1_4_1__result
lnul_4_1__null_or_trap VNull = RVal VNull
lnul_4_1__null_or_trap _     = RTrap

--@spec [LEXP.7.2]
--@spec [LNUL.4.1]
||| The right operand of an arithmetic operator whose left is the Int `a`.
||| The value is the first argument so the case tree splits on it before
||| the operator, and a `null` reduces for any operator -- before the
||| divisor is looked at ([LNUL.9.3]).
public export
lexp_7_2__int_right : Lnul_2_1__value -> Lexp_7_2__arith -> Integer -> Lerr_1_4_1__result
lexp_7_2__int_right VNull      _  _ = RVal VNull
lexp_7_2__int_right (VInt b)   op a = lexp_7_2__int_op op a b
lexp_7_2__int_right (VFloat b) op a = lexp_7_3__float_op op (lexp_7_3__promote a) b
lexp_7_2__int_right _          _  _ = RTrap

--@spec [LEXP.7.3]
--@spec [LNUL.4.1]
||| The right operand of an arithmetic operator whose left is the Float
||| `a`: a Float computes, an Int promotes first, `null` propagates,
||| anything else is ill-typed.
public export
lexp_7_3__float_right : Lnul_2_1__value -> Lexp_7_2__arith -> Double -> Lerr_1_4_1__result
lexp_7_3__float_right VNull      _  _ = RVal VNull
lexp_7_3__float_right (VFloat b) op a = lexp_7_3__float_op op a b
lexp_7_3__float_right (VInt b)   op a = lexp_7_3__float_op op a (lexp_7_3__promote b)
lexp_7_3__float_right _          _  _ = RTrap

--@spec [LNUL.4.1]
--@spec [LEXP.7.2]
--@spec [LEXP.7.3]
||| Arithmetic: a `null` operand yields `null`; Int with Int computes in
||| Int; a Float on either side promotes the other and computes in Float;
||| anything else is ill-typed.
public export
lnul_4_1__arith : Lexp_7_2__arith -> Lnul_2_1__value -> Lnul_2_1__value -> Lerr_1_4_1__result
lnul_4_1__arith op VNull      _ = RVal VNull
lnul_4_1__arith op (VInt a)   b = lexp_7_2__int_right b op a
lnul_4_1__arith op (VFloat a) b = lexp_7_3__float_right b op a
lnul_4_1__arith op (VStr _)   b = lnul_4_1__null_or_trap b
lnul_4_1__arith op (VBool _)  b = lnul_4_1__null_or_trap b
lnul_4_1__arith op (VJson _)  b = lnul_4_1__null_or_trap b

--@spec [LEXP.7.2]
--@spec [LNUL.4.1]
||| Unary minus: on an Int wrapped, on a Float IEEE's (so `-0.0`).
public export
lexp_7_2__negate : Lnul_2_1__value -> Lerr_1_4_1__result
lexp_7_2__negate VNull      = RVal VNull
lexp_7_2__negate (VInt a)   = RVal (VInt (lexp_7_13_1__wrap (negate a)))
lexp_7_2__negate (VFloat a) = RVal (VFloat (negate a))
lexp_7_2__negate _          = RTrap

-- ---------------------------------------------------------------------
-- Strings: the text, its equality, its order, its length, the parses and
-- the renders
-- ---------------------------------------------------------------------

--@spec [LSTR.3.2]
||| Two codepoints compared by scalar value, structurally, so the order's
||| laws are proved by induction: [LSTR.3.2]'s "by codepoint value", one
||| codepoint at a time.
public export
lstr_3_2__cp_cmp : Nat -> Nat -> Ordering
lstr_3_2__cp_cmp Z     Z     = EQ
lstr_3_2__cp_cmp Z     (S _) = LT
lstr_3_2__cp_cmp (S _) Z     = GT
lstr_3_2__cp_cmp (S a) (S b) = lstr_3_2__cp_cmp a b

--@spec [LSTR.3.2]
||| One step of the lexicographic order, the decision on the heads taken
||| first: a smaller head decides `true`, a greater `false`, equal heads
||| leave it to the tails. Named, so a proof can split on the decision.
public export
lstr_3_2__lt_at : Ordering -> Bool -> Bool
lstr_3_2__lt_at LT _    = True
lstr_3_2__lt_at GT _    = False
lstr_3_2__lt_at EQ rest = rest

--@spec [LSTR.3.2]
||| `a < b` on texts: lexicographic by codepoint value ([LSTR.3.2]), the
||| empty text below every nonempty one, so a proper prefix sorts first.
||| Not locale-aware: `a` (U+0061) is above `Z` (U+005A).
public export
lstr_3_2__lt : Lstr_1_1__text -> Lstr_1_1__text -> Bool
lstr_3_2__lt []        []        = False
lstr_3_2__lt []        (_ :: _)  = True
lstr_3_2__lt (_ :: _)  []        = False
lstr_3_2__lt (x :: xs) (y :: ys) = lstr_3_2__lt_at (lstr_3_2__cp_cmp x y) (lstr_3_2__lt xs ys)

--@spec [LSTR.3.1]
||| One step of the equality: equal heads leave it to the tails, any other
||| pair decides `false`.
public export
lstr_3_1__eq_at : Ordering -> Bool -> Bool
lstr_3_1__eq_at EQ rest = rest
lstr_3_1__eq_at _  _    = False

--@spec [LSTR.3.1]
||| Equality of two texts, codepoint by codepoint: the same length and the
||| same codepoint at every position ([LSTR.3.1]). No normalisation: the
||| NFC and NFD forms of one grapheme cluster are two texts.
public export
lstr_3_1__eq : Lstr_1_1__text -> Lstr_1_1__text -> Bool
lstr_3_1__eq []        []        = True
lstr_3_1__eq []        (_ :: _)  = False
lstr_3_1__eq (_ :: _)  []        = False
lstr_3_1__eq (x :: xs) (y :: ys) = lstr_3_1__eq_at (lstr_3_2__cp_cmp x y) (lstr_3_1__eq xs ys)

--@spec [LSTR.2.1]
||| `len(s)`: the number of codepoints in the text, as an Int -- not the
||| byte count, not the grapheme-cluster count, not the UTF-16 code-unit
||| count, none of which a text of codepoints has.
public export
lstr_2_1__len : Lstr_1_1__text -> Integer
lstr_2_1__len t = cast (length t)

--@spec [LSTR.2.1]
--@spec [IRET.9.6]
||| `len(<String>)` over its evaluated operand: of a String the codepoint
||| count, an Int; of `null` -- a `String?` slot holding none -- a TypeError
||| that abandons the activation ([IRET.9.6]'s first arm: a builtin's
||| receiver is a concrete-value position), a trap here; of a fault the
||| fault. Of a value of any other kind a trap HERE and not DS: the
||| compiler types `len` by its argument, and a `Json` value's `len` is
||| `lexp_6_1__len`'s.
public export
lstr_2_1__len_of : Lerr_1_4_1__result -> Lerr_1_4_1__result
lstr_2_1__len_of RTrap           = RTrap
lstr_2_1__len_of (RVal (VStr t)) = RVal (VInt (lstr_2_1__len t))
lstr_2_1__len_of (RVal _)        = RTrap

--@spec [LCST.4.5.7]
--@spec [LLEX.11.1]
||| The value of one digit of a base, if the codepoint is one: `0` to `9`,
||| then `a` to `f` and `A` to `F` for the bases that reach them
||| ([LLEX.11.1]'s `HEX_DIGIT` admits both cases).
public export
lcst_4_5_7__digit : Nat -> Nat -> Maybe Integer
lcst_4_5_7__digit base c =
  let d = if c >= 48 && c <= 57 then minus c 48
          else if c >= 97 && c <= 102 then minus c 87
          else if c >= 65 && c <= 70 then minus c 55
          else 99
  in if d < base then Just (cast d) else Nothing

--@spec [LCST.4.5.7]
--@spec [LLEX.11.1]
--@spec [LLEX.12.1]
||| The digits after the first, the value so far accumulated: each a digit
||| of the base, or a `_` that sits before a digit -- [LLEX.11.1]'s
||| `('_'? DIGIT)*` in every base, which is [LLEX.12.1]'s rule, "`_` before
||| a digit is a group separator", so none may end the run and none may
||| precede another `_`; a text with one there is no `INT_LIT`
||| (LCST.4.5.7's fixture).
public export
lcst_4_5_7__digits_run : Nat -> Integer -> Lstr_1_1__text -> Maybe Integer
lcst_4_5_7__digits_run base acc []        = Just acc
lcst_4_5_7__digits_run base acc (c :: cs) =
  if c == 95
    then (case cs of
            []        => Nothing
            (d :: ds) => case lcst_4_5_7__digit base d of
                           Just v  => lcst_4_5_7__digits_run base (acc * cast base + v) ds
                           Nothing => Nothing)
    else case lcst_4_5_7__digit base c of
           Just v  => lcst_4_5_7__digits_run base (acc * cast base + v) cs
           Nothing => Nothing

--@spec [LLEX.11.1]
||| A digit run of a base: a first digit, then `lcst_4_5_7__digits_run`.
||| The empty text, and a text opening with anything but a digit of the
||| base -- a `_`, a space, a sign -- is no run.
public export
llex_11_1__digits : Nat -> Lstr_1_1__text -> Maybe Integer
llex_11_1__digits base []        = Nothing
llex_11_1__digits base (c :: cs) = case lcst_4_5_7__digit base c of
  Just v  => lcst_4_5_7__digits_run base v cs
  Nothing => Nothing

--@spec [LLEX.11.1]
||| What follows a leading `0`: `x` then hex digits, `b` then binary, `o`
||| then octal, nothing (the literal `0` itself), or more decimal digits.
||| A prefix with no digit after it, an uppercase `0X` and a digit outside
||| the base are no literal.
public export
llex_11_1__prefixed : Lstr_1_1__text -> Maybe Integer
llex_11_1__prefixed []        = Just 0
llex_11_1__prefixed (c1 :: cs) =
  if c1 == 120 then llex_11_1__digits 16 cs
  else if c1 == 98 then llex_11_1__digits 2 cs
  else if c1 == 111 then llex_11_1__digits 8 cs
  else llex_11_1__digits 10 (48 :: c1 :: cs)

--@spec [LLEX.11.1]
||| An `INT_LIT`'s magnitude: a leading `0` may open a prefixed literal
||| (`llex_11_1__prefixed`); anything else is decimal. The first codepoint
||| is read alone, so a text opening with a non-digit reduces to the decimal
||| case whatever its tail.
public export
llex_11_1__int_lit : Lstr_1_1__text -> Maybe Integer
llex_11_1__int_lit []        = Nothing
llex_11_1__int_lit (c0 :: cs) = if c0 == 48 then llex_11_1__prefixed cs else llex_11_1__digits 10 (c0 :: cs)

--@spec [LCST.4.5.7]
||| The 64-bit range: a value inside it stands, one outside it is nothing
||| -- `null`, not a saturated value and not a fault.
public export
lcst_4_5_7__in_range : Maybe Integer -> Maybe Integer
lcst_4_5_7__in_range Nothing  = Nothing
lcst_4_5_7__in_range (Just v) =
  if v >= -9223372036854775808 && v <= 9223372036854775807 then Just v else Nothing

--@spec [LCST.4.5.7]
||| `String :: Int?`: the whole text an optional sign (`+` or `-`) then an
||| `INT_LIT` ([LLEX.11.1]), the signed value when it lies in the 64-bit
||| range, and nothing for every other text -- one outside the range, one
||| with surrounding whitespace, a decimal point or an exponent, a unit
||| suffix, or a separator where a source literal admits none.
public export
lcst_4_5_7__parse_int : Lstr_1_1__text -> Maybe Integer
lcst_4_5_7__parse_int []        = Nothing
lcst_4_5_7__parse_int (c :: cs) =
  if c == 43 then lcst_4_5_7__in_range (llex_11_1__int_lit cs)
  else if c == 45 then lcst_4_5_7__in_range (map negate (llex_11_1__int_lit cs))
  else lcst_4_5_7__in_range (llex_11_1__int_lit (c :: cs))

--@spec [LCST.4.5.5]
||| `String :: Bool?`: exactly the texts `true` and `false`, case-sensitive,
||| to the Bool; nothing for any other text.
public export
lcst_4_5_5__parse_bool : Lstr_1_1__text -> Maybe Bool
lcst_4_5_5__parse_bool t =
  if t == [116, 114, 117, 101] then Just True
  else if t == [102, 97, 108, 115, 101] then Just False
  else Nothing

--@spec [LCST.4.5.6]
||| The decimal digits of a non-negative Integer, most significant first,
||| placed before the digits already in `acc`. Twenty digits of fuel: a
||| 64-bit value has at most nineteen, and every Int of the model is one
||| ([LEXP.7.13.1]).
public export
lcst_4_5_6__decimal : Nat -> Integer -> Lstr_1_1__text -> Lstr_1_1__text
lcst_4_5_6__decimal Z     n acc = acc
lcst_4_5_6__decimal (S k) n acc =
  let d = the Nat (cast (n `mod` 10)) + 48
  in if n < 10 then d :: acc else lcst_4_5_6__decimal k (n `div` 10) (d :: acc)

--@spec [LCST.4.5.6]
||| `Int :: String`: the exact decimal, a `-` before a negative value.
public export
lcst_4_5_6__render_int : Integer -> Lstr_1_1__text
lcst_4_5_6__render_int n =
  if n < 0 then 45 :: lcst_4_5_6__decimal 20 (negate n) [] else lcst_4_5_6__decimal 20 n []

--@spec [LCST.4.5.6]
--@spec [LCST.4.5.5]
||| `Bool :: String`: `true` / `false`, the inverse of [LCST.4.5.5]'s parse.
public export
lcst_4_5_6__render_bool : Bool -> Lstr_1_1__text
lcst_4_5_6__render_bool True  = [116, 114, 117, 101]
lcst_4_5_6__render_bool False = [102, 97, 108, 115, 101]

--@spec [LNUL.8.4]
--@spec [LERR.1.3.1]
||| What a fallible parse yields: the value it found, or `null` for a text
||| it does not accept -- absence, [LNUL.8.4]'s failed fallible conversion
||| and [LERR.1.3.1]'s third case, never a fault. Named, so a theorem can
||| split on the parse.
public export
lnul_8_4__parsed : Maybe Lnul_2_1__value -> Lerr_1_4_1__result
lnul_8_4__parsed (Just v) = RVal v
lnul_8_4__parsed Nothing  = RVal VNull

-- ---------------------------------------------------------------------
-- Float text: the parse of [LCST.4.5.8] and the render of [LDET.3.2.7]
-- ---------------------------------------------------------------------
--
-- RUN, NOT PROVED: the parse's rounding and the
-- render's search are exact Integer arithmetic, which Idris reduces on
-- literals and reasons about nowhere else, so what they COMPUTE is run --
-- the fixtures' spellings and a battery of hard values in Main.idr, and
-- every fixture the idris-libds lane compares -- and what is proved is the
-- SHAPE: a parse a value or `null` for every text, the render's digits
-- admitted by the parse's own test (`ldet_3_2_7__found_round_trips`), the
-- shaping rows and the grammar on literals. The parse's correctness proof
-- is scheduled for after v1. Neither direction reads a library or the host:
-- no Chez conversion, no Dragonbox, no fast_float.

--@spec [LDET.3.2.8]
||| `b ^ k` on Integers, by recursion on the exponent.
public export
ldet_3_2_8__pow : Integer -> Nat -> Integer
ldet_3_2_8__pow b Z     = 1
ldet_3_2_8__pow b (S k) = b * ldet_3_2_8__pow b k

--@spec [LDET.3.2.8]
||| The bit length of a non-negative Integer, the least `k` with `n < 2^k`.
||| The fuel bounds the halvings; a caller passes more than the length.
public export
ldet_3_2_8__bit_length : Nat -> Integer -> Nat
ldet_3_2_8__bit_length Z     n = Z
ldet_3_2_8__bit_length (S k) n = if n <= 0 then Z else S (ldet_3_2_8__bit_length k (n `div` 2))

--@spec [LDET.3.2.8]
||| The decimal digit count of a non-negative Integer, 0 for 0; the fuel
||| bounds the divisions as above.
public export
ldet_3_2_8__digit_count : Nat -> Integer -> Nat
ldet_3_2_8__digit_count Z     n = Z
ldet_3_2_8__digit_count (S k) n = if n <= 0 then Z else S (ldet_3_2_8__digit_count k (n `div` 10))

--@spec [LDET.3.2.8]
||| The numerator of `n / m` scaled by `2^-e`, for a binary exponent of
||| either sign: `n` itself when `e` is not negative, else `n * 2^-e`.
||| With `ldet_3_2_8__scaled_den`, the scaled value as an exact fraction.
public export
ldet_3_2_8__scaled_num : Integer -> Integer -> Integer -> Integer
ldet_3_2_8__scaled_num n m e = if e >= 0 then n else n * ldet_3_2_8__pow 2 (cast (negate e))

--@spec [LDET.3.2.8]
||| The divisor of `n / m` scaled by `2^-e`: `m * 2^e` when `e` is not
||| negative, else `m` itself.
public export
ldet_3_2_8__scaled_den : Integer -> Integer -> Integer -> Integer
ldet_3_2_8__scaled_den n m e = if e >= 0 then m * ldet_3_2_8__pow 2 (cast e) else m

--@spec [LDET.3.2.8]
||| Round to nearest, ties to even, of a quotient `q + r / d` with
||| `0 <= r < d`: `q`, or `q + 1` when the remainder is above a half, or
||| at exactly a half when `q` is odd.
public export
ldet_3_2_8__round_half_even : Integer -> Integer -> Integer -> Integer
ldet_3_2_8__round_half_even q r d =
  if 2 * r < d then q
  else if 2 * r > d then q + 1
  else if q `mod` 2 == 0 then q else q + 1

--@spec [LDET.3.2.8]
||| The binary exponent at which `n / m` scaled by `2^-e` has 53 bits --
||| its quotient in `[2^52, 2^53)` -- from an estimate corrected a step at
||| a time. The fuel bounds the steps; an estimate by bit lengths is off
||| by at most two.
public export
ldet_3_2_8__exponent_of : Nat -> Integer -> Integer -> Integer -> Integer
ldet_3_2_8__exponent_of Z     n m e = e
ldet_3_2_8__exponent_of (S k) n m e =
  let q = ldet_3_2_8__scaled_num n m e `div` ldet_3_2_8__scaled_den n m e
  in if q >= 9007199254740992 then ldet_3_2_8__exponent_of k n m (e + 1)
     else if q < 4503599627370496 then ldet_3_2_8__exponent_of k n m (e - 1)
     else e

--@spec [LDET.3.2.8]
||| THE PARSE'S ROUNDING: the double nearest to `d * 10^x`, ties to even,
||| for a positive `d`, as its significand and binary exponent `(q, e)` --
||| `q * 2^e` the value, `q` below 2^53 and `e` at least -1074, a subnormal
||| carrying `q` below 2^52 at -1074; nothing when the value rounds past
||| the largest double, which [LCST.4.5.8] makes `null`. The value as an
||| exact fraction; the exponent at which its quotient has 53 bits, or the
||| least a double has; the remainder against a half; a rounding that
||| carries into a 54th bit moving the exponent up. The fuel bounds the
||| bit lengths, and `ldet_3_2_8__of_decimal` passes enough.
public export
ldet_3_2_8__nearest : Nat -> Integer -> Integer -> Maybe (Integer, Integer)
ldet_3_2_8__nearest fuel d x =
  let n   = if x >= 0 then d * ldet_3_2_8__pow 10 (cast x) else d
      m   = if x >= 0 then 1 else ldet_3_2_8__pow 10 (cast (negate x))
      est = the Integer (cast (ldet_3_2_8__bit_length fuel n))
              - the Integer (cast (ldet_3_2_8__bit_length fuel m)) - 53
      e0  = ldet_3_2_8__exponent_of 4 n m est
      e1  = if e0 < -1074 then -1074 else e0
      num = ldet_3_2_8__scaled_num n m e1
      den = ldet_3_2_8__scaled_den n m e1
      q1  = ldet_3_2_8__round_half_even (num `div` den) (num `mod` den) den
      q2  = if q1 >= 9007199254740992 then 4503599627370496 else q1
      e2  = if q1 >= 9007199254740992 then e1 + 1 else e1
  in if e2 > 971 then Nothing else Just (q2, e2)

--@spec [LDET.3.2.8]
||| A double from a significand and a binary exponent, by doubling or
||| halving the significand as a double once per unit of the exponent:
||| every intermediate value is representable -- the final one is, and
||| each before it has no more bits at a larger exponent -- so no step
||| rounds. The fuel bounds the steps; 2200 covers every exponent a double
||| has.
public export
ldet_3_2_8__scale : Nat -> Double -> Integer -> Double
ldet_3_2_8__scale Z     y e = y
ldet_3_2_8__scale (S k) y e =
  if e > 0 then ldet_3_2_8__scale k (y * 2.0) (e - 1)
  else if e < 0 then ldet_3_2_8__scale k (y / 2.0) (e + 1)
  else y

--@spec [LDET.3.2.8]
||| The double `(-1)^neg * q * 2^e`, `q` below 2^53 read as a double
||| exactly by the primitive cast.
public export
ldet_3_2_8__compose : Bool -> Integer -> Integer -> Double
ldet_3_2_8__compose neg q e =
  let y = ldet_3_2_8__scale 2200 (cast q) e
  in if neg then negate y else y

--@spec [LDET.3.2.8]
||| The magnitude of a finite nonzero double brought into `[2^52, 2^53)` by
||| exact halvings and doublings, with the binary exponent it was moved by:
||| `(y, e)` with `y * 2^e` the magnitude. The fuel as for the scaling.
public export
ldet_3_2_8__normalise : Nat -> Double -> Integer -> (Double, Integer)
ldet_3_2_8__normalise Z     y e = (y, e)
ldet_3_2_8__normalise (S k) y e =
  if y >= 9007199254740992.0 then ldet_3_2_8__normalise k (y / 2.0) (e + 1)
  else if y < 4503599627370496.0 then ldet_3_2_8__normalise k (y * 2.0) (e - 1)
  else (y, e)

--@spec [LDET.3.2.8]
||| A finite nonzero double as its sign, significand and binary exponent:
||| `(neg, m, e)` with `m * 2^e` its magnitude and `m` in `[2^52, 2^53)`,
||| the significand read off the normalised magnitude by the primitive
||| cast, exact on an integral double.
public export
ldet_3_2_8__decompose : Double -> (Bool, Integer, Integer)
ldet_3_2_8__decompose x =
  let neg = x < 0.0
      ye  = ldet_3_2_8__normalise 2200 (if neg then negate x else x) 0
  in (neg, cast (fst ye), snd ye)

--@spec [LDET.3.6.2]
||| The positive infinity, as [LDET.3.6.2]'s division makes it.
public export
ldet_3_6_2__infinity : Double
ldet_3_6_2__infinity = 1.0 / 0.0

--@spec [LLEX.11.2]
--@spec [LLEX.11.1]
||| The digits after the first of a `DEC_LIT`, with the value and the
||| count so far: a digit continues the run; a `_` continues it when a
||| digit follows ([LLEX.11.1]'s `DIGIT ('_'? DIGIT)*`: never last, never
||| beside a point or an exponent marker, which a digit is not) and ends the
||| literal otherwise; any other codepoint ends the run and is handed back.
public export
llex_11_2__dec_more : Integer -> Nat -> Lstr_1_1__text -> Maybe (Integer, Nat, Lstr_1_1__text)
llex_11_2__dec_more acc n [] = Just (acc, n, [])
llex_11_2__dec_more acc n (c :: cs) =
  case lcst_4_5_7__digit 10 c of
    Just v  => llex_11_2__dec_more (acc * 10 + v) (S n) cs
    Nothing =>
      if c == 95
        then (case cs of
                []        => Nothing
                (d :: ds) => case lcst_4_5_7__digit 10 d of
                               Just v  => llex_11_2__dec_more (acc * 10 + v) (S n) ds
                               Nothing => Nothing)
        else Just (acc, n, c :: cs)

--@spec [LLEX.11.2]
--@spec [LLEX.11.1]
||| A `DEC_LIT` at the head of a text -- a digit, then
||| `llex_11_2__dec_more` -- as its value, its digit count and the text
||| after it; nothing when no digit opens it.
public export
llex_11_2__dec_run : Lstr_1_1__text -> Maybe (Integer, Nat, Lstr_1_1__text)
llex_11_2__dec_run []        = Nothing
llex_11_2__dec_run (c :: cs) = case lcst_4_5_7__digit 10 c of
  Just v  => llex_11_2__dec_more v 1 cs
  Nothing => Nothing

--@spec [LCST.4.5.8]
||| Whether a text opens with a `-`: the sign of a signed spelling.
public export
lcst_4_5_8__negative : Lstr_1_1__text -> Bool
lcst_4_5_8__negative (45 :: _) = True
lcst_4_5_8__negative _         = False

--@spec [LCST.4.5.8]
||| The text after an optional sign, `+` or `-`.
public export
lcst_4_5_8__unsigned : Lstr_1_1__text -> Lstr_1_1__text
lcst_4_5_8__unsigned (43 :: cs) = cs
lcst_4_5_8__unsigned (45 :: cs) = cs
lcst_4_5_8__unsigned t          = t

--@spec [LLEX.11.2]
||| An `EXPONENT` after its marker: an optional sign, then a `DEC_LIT`
||| that ends the text. The signed value.
public export
llex_11_2__exponent : Lstr_1_1__text -> Maybe Integer
llex_11_2__exponent t =
  case llex_11_2__dec_run (lcst_4_5_8__unsigned t) of
    Just (v, _, []) => Just (if lcst_4_5_8__negative t then negate v else v)
    _               => Nothing

--@spec [LLEX.11.2]
--@spec [LLEX.11.2.1]
--@spec [LLEX.11.2.2]
||| A `FLOAT_LIT`, the whole text: `DEC_LIT '.' DEC_LIT EXPONENT?` or
||| `DEC_LIT EXPONENT` -- both sides of the point required
||| ([LLEX.11.2.1]), the exponent required on the bare form
||| ([LLEX.11.2.2]: a bare `DEC_LIT` is an `INT_LIT` and not this). Its
||| value as a decimal, the digits as one Integer and the power of ten
||| they sit at: `(d, x)` with `d * 10^x` the value.
public export
llex_11_2__float_lit : Lstr_1_1__text -> Maybe (Integer, Integer)
llex_11_2__float_lit t = case llex_11_2__dec_run t of
  Nothing => Nothing
  Just (ip, _, rest) => case rest of
    (46 :: r1) => (case llex_11_2__dec_run r1 of
      Nothing => Nothing
      Just (fp, nf, r2) =>
        let d = ip * ldet_3_2_8__pow 10 nf + fp
        in case r2 of
             []        => Just (d, negate (the Integer (cast nf)))
             (c :: r3) => if c == 101 || c == 69
                            then (case llex_11_2__exponent r3 of
                                    Just ex => Just (d, ex - the Integer (cast nf))
                                    Nothing => Nothing)
                            else Nothing)
    (c :: r1) => if c == 101 || c == 69
                   then (case llex_11_2__exponent r1 of
                           Just ex => Just (ip, ex)
                           Nothing => Nothing)
                   else Nothing
    [] => Nothing

--@spec [LCST.4.5.8]
--@spec [LDET.3.2.8]
||| A signed decimal `d * 10^x` to the nearest double, ties to even
||| ([LDET.3.2.8]); a zero keeps the sign it was spelt with. The magnitude
||| is settled by the digit count before any arithmetic: with `k` digits
||| the value is at least `10^(k-1+x)` and below `10^(k+x)`, so one past
||| `10^310` exceeds every double and is nothing -- an infinity,
||| [LCST.4.5.8]'s `null` -- and one below `10^-324` is under half the
||| least subnormal and rounds to the signed zero; the rest is
||| `ldet_3_2_8__nearest`'s. `digits` bounds the digit count; a text's
||| length serves.
public export
ldet_3_2_8__of_decimal : Nat -> Bool -> Integer -> Integer -> Maybe Double
ldet_3_2_8__of_decimal digits neg d x =
  let zero = if neg then negate 0.0 else 0.0
      k    = the Integer (cast (ldet_3_2_8__digit_count (S digits) d))
  in if d == 0 then Just zero
     else if k + x > 310 then Nothing
     else if k + x < -324 then Just zero
     else case ldet_3_2_8__nearest (4 * (cast k + 400)) d x of
            Just qe => Just (ldet_3_2_8__compose neg (fst qe) (snd qe))
            Nothing => Nothing

--@spec [LCST.4.5.8]
--@spec [LLEX.11.1.5]
||| `String :: Float?`: the whole text an optional sign then an `INT_LIT`
||| ([LLEX.11.1]; its signed value in the 64-bit range, an integer spelling
||| outside it being one no source literal admits, [LLEX.11.1.5]), a
||| `FLOAT_LIT` ([LLEX.11.2]) or `inf`, to the nearest double, ties to even;
||| a zero keeping the sign it was spelt with; `inf` with its sign the
||| infinity; nothing -- `null` -- for every other text: a finite spelling
||| that rounds past the largest double, whitespace, a unit suffix, a NaN
||| spelling, any spelling a source literal would not admit.
public export
lcst_4_5_8__parse_float : Lstr_1_1__text -> Maybe Double
lcst_4_5_8__parse_float t =
  let neg    = lcst_4_5_8__negative t
      body   = lcst_4_5_8__unsigned t
      signed = map (\v => if neg then negate v else v) (llex_11_1__int_lit body)
  in if body == [105, 110, 102]
       then Just (if neg then negate ldet_3_6_2__infinity else ldet_3_6_2__infinity)
       else case lcst_4_5_7__in_range signed of
              Just v  => ldet_3_2_8__of_decimal (length t) neg (if v < 0 then negate v else v) 0
              Nothing => case llex_11_2__float_lit body of
                           Just dx => ldet_3_2_8__of_decimal (length t) neg (fst dx) (snd dx)
                           Nothing => Nothing

--@spec [LDET.3.2.7]
||| The power of ten of the last of `len` significant digits of a value
||| whose leading digit sits at `10^x`.
public export
ldet_3_2_7__last_power : Integer -> Nat -> Integer
ldet_3_2_7__last_power x len = x - the Integer (cast len) + 1

--@spec [LDET.3.2.7]
||| The numerator of `n / md` scaled by `10^-p`: `n` itself when `p` is
||| not negative, else `n * 10^-p`. With `ldet_3_2_7__scaled10_den`, the
||| scaled value as an exact fraction.
public export
ldet_3_2_7__scaled10_num : Integer -> Integer -> Integer -> Integer
ldet_3_2_7__scaled10_num n md p = if p >= 0 then n else n * ldet_3_2_8__pow 10 (cast (negate p))

--@spec [LDET.3.2.7]
||| The divisor of `n / md` scaled by `10^-p`: `md * 10^p` when `p` is not
||| negative, else `md` itself.
public export
ldet_3_2_7__scaled10_den : Integer -> Integer -> Integer -> Integer
ldet_3_2_7__scaled10_den n md p = if p >= 0 then md * ldet_3_2_8__pow 10 (cast p) else md

--@spec [LDET.3.2.7]
||| Whether `n / md` is at least `10^x`, exact for either sign of `x`.
public export
ldet_3_2_7__ge_pow10 : Integer -> Integer -> Integer -> Bool
ldet_3_2_7__ge_pow10 n md x =
  if x >= 0 then n >= md * ldet_3_2_8__pow 10 (cast x)
            else n * ldet_3_2_8__pow 10 (cast (negate x)) >= md

--@spec [LDET.3.2.7]
||| The decimal exponent of a positive `n / md`, the `x` with
||| `10^x <= n/md < 10^(x+1)`, from an estimate corrected a step at a
||| time; the fuel bounds the steps.
public export
ldet_3_2_7__decimal_exponent : Nat -> Integer -> Integer -> Integer -> Integer
ldet_3_2_7__decimal_exponent Z     n md x = x
ldet_3_2_7__decimal_exponent (S k) n md x =
  if not (ldet_3_2_7__ge_pow10 n md x) then ldet_3_2_7__decimal_exponent k n md (x - 1)
  else if ldet_3_2_7__ge_pow10 n md (x + 1) then ldet_3_2_7__decimal_exponent k n md (x + 1)
  else x

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| Whether the decimal `q * 10^p` parses back to the double `m * 2^e`:
||| its nearest double, recomposed, is that one. The clause's "parses back
||| to the identical double", read through the parse's own rounding.
public export
ldet_3_2_7__round_trips : Nat -> Integer -> Integer -> Integer -> Integer -> Bool
ldet_3_2_7__round_trips fuel m e q p =
  case ldet_3_2_8__nearest fuel q p of
    Just qe => ldet_3_2_8__compose False (fst qe) (snd qe) == ldet_3_2_8__compose False m e
    Nothing => False

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| The choice at one length, from the lower bracket `lo` at power `p`,
||| whether each of `lo` and `lo + 1` parses back, whether each is the
||| nearer, and whether `lo` is even: the one that parses back; of two,
||| the nearer; at an exact tie, the one whose last digit is even
||| ([LDET.3.2.8]'s rule); of none, nothing. A case table and no `if`, so
||| that what it admits is read off its clauses.
public export
ldet_3_2_7__choose : Integer -> Integer -> Bool -> Bool -> Bool -> Bool -> Bool -> Maybe (Integer, Integer)
ldet_3_2_7__choose lo p True  True  True  _     _     = Just (lo, p)
ldet_3_2_7__choose lo p True  True  False True  _     = Just (lo + 1, p)
ldet_3_2_7__choose lo p True  True  False False True  = Just (lo, p)
ldet_3_2_7__choose lo p True  True  False False False = Just (lo + 1, p)
ldet_3_2_7__choose lo p True  False _     _     _     = Just (lo, p)
ldet_3_2_7__choose lo p False True  _     _     _     = Just (lo + 1, p)
ldet_3_2_7__choose lo p False False _     _     _     = Nothing

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| THE CHOICE AT ONE LENGTH, OVER THE TEST: the value scaled to the
||| length's grid is `lo + r / den`, so `lo` and `lo + 1` at power `p` are
||| the two decimals of that length bracketing it; each is tested by `rt`,
||| the upper only when the value is not `lo` exactly, and the nearer (the
||| one whose distance, `r` or `den - r`, is the less) and the parity of
||| `lo` go to `ldet_3_2_7__choose`. Abstract in the test on purpose: a
||| theorem about what the choice admits is then stated over variables and
||| never unfolds the parse (`ldet_3_2_7__candidates_by_admit`; as first
||| written through `ldet_3_2_7__candidates`'s own `let`s, the theorem did
||| not elaborate in thirteen minutes). dscast.k's `pick`.
public export
ldet_3_2_7__candidates_by : (Integer -> Integer -> Bool) -> Integer -> Integer -> Integer -> Integer -> Maybe (Integer, Integer)
ldet_3_2_7__candidates_by rt lo p r den =
  ldet_3_2_7__choose lo p (rt lo p) (r /= 0 && rt (lo + 1) p) (r < den - r) (den - r < r) (lo `mod` 2 == 0)

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| THE CANDIDATES AT ONE LENGTH: the value `n / md` with leading digit at
||| `10^x` scaled to `len` digits is `lo + r / den`; `lo` and `lo + 1` are
||| the `len`-digit decimals bracketing it, and a `len`-digit decimal that
||| parses back is one of them (the decimals that parse back form an
||| interval around the value, and these are its nearest neighbours on
||| the `len`-digit grid on either side). The choice over them is
||| `ldet_3_2_7__candidates_by`, the test the parse's own
||| (`ldet_3_2_7__round_trips`).
public export
ldet_3_2_7__candidates : Nat -> Nat -> Integer -> Integer -> Integer -> Integer -> Integer -> Maybe (Integer, Integer)
ldet_3_2_7__candidates fuel len m e n md x =
  let p   = ldet_3_2_7__last_power x len
      num = ldet_3_2_7__scaled10_num n md p
      den = ldet_3_2_7__scaled10_den n md p
  in ldet_3_2_7__candidates_by (ldet_3_2_7__round_trips fuel m e) (num `div` den) p (num `mod` den) den

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| ONE STEP OF THE SEARCH: the candidates at this length when there are
||| any, else the rest of the search, which arrives as a thunk so that a
||| length that answers ends it (dscast.k's `found`). A step of its own, so
||| that what a step that answers rests on is a lemma over variables
||| (`ldet_3_2_7__step_just`) and the round-trip theorem needs no `with`
||| on a scrutinee the checker would unfold.
public export
ldet_3_2_7__shortest_step : Maybe (Integer, Integer) -> (() -> Maybe (Integer, Integer)) -> Maybe (Integer, Integer)
ldet_3_2_7__shortest_step (Just c) _ = Just c
ldet_3_2_7__shortest_step Nothing  k = k ()

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| The search from `len` digits upward, `left` lengths at most: the
||| candidates at this length, else the next.
public export
ldet_3_2_7__shortest_from : Nat -> Nat -> Nat -> Integer -> Integer -> Integer -> Integer -> Integer -> Maybe (Integer, Integer)
ldet_3_2_7__shortest_from fuel len Z        m e n md x = Nothing
ldet_3_2_7__shortest_from fuel len (S left) m e n md x =
  ldet_3_2_7__shortest_step (ldet_3_2_7__candidates fuel len m e n md x)
    (\_ => ldet_3_2_7__shortest_from fuel (S len) left m e n md x)

--@spec [LDET.3.2.7]
--@spec [LDET.3.2.8]
||| THE SHORTEST DIGITS of a finite nonzero magnitude `m * 2^e`, by the
||| clause's words: among the decimals that parse back to it, the fewest
||| significant digits; among those of that length, the nearest; at an
||| exact tie, the even last digit. Searched from one digit to seventeen,
||| which identify every double. `(q, p)`: the digits as an Integer and the
||| power of ten of the last. The fuel bounds the bit lengths; 4000 covers
||| the value and every scaling of it.
public export
ldet_3_2_7__shortest : Integer -> Integer -> Maybe (Integer, Integer)
ldet_3_2_7__shortest m e =
  let n  = if e >= 0 then m * ldet_3_2_8__pow 2 (cast e) else m
      md = if e >= 0 then 1 else ldet_3_2_8__pow 2 (cast (negate e))
      b  = the Integer (cast (ldet_3_2_8__bit_length 4000 n))
             - the Integer (cast (ldet_3_2_8__bit_length 4000 md))
      x0 = if b >= 0 then (b * 30103) `div` 100000 - 1
                     else negate ((negate b * 30103) `div` 100000) - 2
      x  = ldet_3_2_7__decimal_exponent 12 n md x0
  in ldet_3_2_7__shortest_from 4000 1 17 m e n md x

--@spec [LDET.3.2.7]
||| The digits with their trailing zeros removed, the power of ten moved
||| up by as many: `(q, p)` and `(q / 10, p + 1)` are one decimal. The fuel
||| bounds the removals; a search result has at most seventeen digits.
public export
ldet_3_2_7__strip : Nat -> Integer -> Integer -> (Integer, Integer)
ldet_3_2_7__strip Z     q p = (q, p)
ldet_3_2_7__strip (S k) q p =
  if q > 0 && q `mod` 10 == 0 then ldet_3_2_7__strip k (q `div` 10) (p + 1) else (q, p)

--@spec [LDET.3.2.7]
||| Whether a value whose leading digit sits at `10^x` takes the fixed
||| form: `1e-4 <= |v| < 1e16`, so `x` from -4 to 15.
public export
ldet_3_2_7__fixed_form : Integer -> Bool
ldet_3_2_7__fixed_form x = x >= -4 && x <= 15

--@spec [LDET.3.2.7]
||| An exponent's magnitude in at least two digits: a one-digit value
||| padded with a leading `0`.
public export
ldet_3_2_7__two_digits : Integer -> Lstr_1_1__text
ldet_3_2_7__two_digits v =
  let ds = lcst_4_5_6__decimal 20 v []
  in if length ds < 2 then 48 :: ds else ds

--@spec [LDET.3.2.7]
||| What follows the leading digit of a scientific mantissa: nothing when
||| it is the only digit, else a point and the rest.
public export
ldet_3_2_7__after_point : Lstr_1_1__text -> Lstr_1_1__text
ldet_3_2_7__after_point []   = []
ldet_3_2_7__after_point rest = 46 :: rest

--@spec [LDET.3.2.7]
||| THE SHAPE of [LDET.3.2.7]: the digits `q` (no trailing zero) at power
||| of ten `p`, with `x = p + |digits| - 1` the exponent of the leading
||| digit. Fixed notation when `x` is -4 to 15: the integer part, a point,
||| the fraction -- `.0` kept on a whole value, a leading `0` before a
||| sub-one one. Scientific notation otherwise: the leading digit, a point
||| and the rest when there are more, `e`, the exponent's sign and at least
||| two digits of it -- the mantissa of a one-digit value carrying no `.0`,
||| the reading float_fmt.c takes of a shape the clause leaves to the
||| round-trip rule (the header's residue). A `-` first when negative.
public export
ldet_3_2_7__shape : Bool -> Integer -> Integer -> Lstr_1_1__text
ldet_3_2_7__shape neg q p =
  let ds = lcst_4_5_6__decimal 20 q []
      n  = length ds
      x  = p + the Integer (cast n) - 1
      body = if ldet_3_2_7__fixed_form x
               then (if p >= 0
                       then ds ++ replicate (cast p) 48 ++ [46, 48]
                       else let f = the Nat (cast (negate p))
                            in if n > f
                                 then take (minus n f) ds ++ [46] ++ drop (minus n f) ds
                                 else [48, 46] ++ replicate (minus f n) 48 ++ ds)
               else (case ds of
                       []          => [48, 46, 48]
                       (d :: rest) => [d] ++ ldet_3_2_7__after_point rest
                                      ++ [101] ++ (if x < 0 then [45] else [43])
                                      ++ ldet_3_2_7__two_digits (if x < 0 then negate x else x))
  in if neg then 45 :: body else body

--@spec [LCST.4.5.6]
--@spec [LDET.3.2.7]
--@spec [LDET.3.6.2]
||| `Float :: String`: `nan` for a NaN whatever its sign ([LCST.4.5.6]),
||| `inf` / `-inf` for the infinities, `0.0` / `-0.0` for the zeros, each
||| with its sign, and for a finite nonzero value the shortest digits in
||| the clause's shape. Total but for a search that finds no digits, which
||| is the parse's defect surfacing as a trap.
public export
lcst_4_5_6__render_float : Double -> Lerr_1_4_1__result
lcst_4_5_6__render_float x =
  if lnul_4_9__nan x then RVal (VStr [110, 97, 110])
  else if lnul_4_9__inf x then RVal (VStr [105, 110, 102])
  else if lnul_4_9__neg_inf x then RVal (VStr [45, 105, 110, 102])
  else if x == 0.0 then RVal (VStr (if 1.0 / x < 0.0 then [45, 48, 46, 48] else [48, 46, 48]))
  else case ldet_3_2_8__decompose x of
         (neg, m, e) => case ldet_3_2_7__shortest m e of
           Just qp => case ldet_3_2_7__strip 20 (fst qp) (snd qp) of
                        (q, p) => RVal (VStr (ldet_3_2_7__shape neg q p))
           Nothing => RTrap

--@spec [IRET.7.5]
||| The six comparisons a join test may carry.
public export
data Iret_7_5__cmp : Type where
  OpEq : Iret_7_5__cmp
  OpNe : Iret_7_5__cmp
  OpLt : Iret_7_5__cmp
  OpLe : Iret_7_5__cmp
  OpGt : Iret_7_5__cmp
  OpGe : Iret_7_5__cmp

--@spec [IRET.7.5]
||| An Int comparison.
public export
iret_7_5__int_order : Iret_7_5__cmp -> Integer -> Integer -> Bool
iret_7_5__int_order OpEq a b = a == b
iret_7_5__int_order OpNe a b = a /= b
iret_7_5__int_order OpLt a b = a < b
iret_7_5__int_order OpLe a b = a <= b
iret_7_5__int_order OpGt a b = a > b
iret_7_5__int_order OpGe a b = a >= b

--@spec [IRET.7.5]
--@spec [LDET.3.6.2]
||| A Float comparison, IEEE 754's: every ordering and the equality are
||| false on a NaN and `!=` true, `-0.0 == 0.0`, and an infinity orders
||| beyond every finite value.
public export
iret_7_5__float_order : Iret_7_5__cmp -> Double -> Double -> Bool
iret_7_5__float_order OpEq a b = a == b
iret_7_5__float_order OpNe a b = a /= b
iret_7_5__float_order OpLt a b = a < b
iret_7_5__float_order OpLe a b = a <= b
iret_7_5__float_order OpGt a b = a > b
iret_7_5__float_order OpGe a b = a >= b

--@spec [IRET.7.5]
--@spec [LSTR.3.1]
--@spec [LSTR.3.2]
||| A String comparison: `==` and `!=` the equality codepoint by codepoint
||| ([LSTR.3.1]), `<` and `>` the lexicographic order by codepoint value
||| ([LSTR.3.2]), `<=` and `>=` the order or the equality.
public export
iret_7_5__str_order : Iret_7_5__cmp -> Lstr_1_1__text -> Lstr_1_1__text -> Bool
iret_7_5__str_order OpEq a b = lstr_3_1__eq a b
iret_7_5__str_order OpNe a b = not (lstr_3_1__eq a b)
iret_7_5__str_order OpLt a b = lstr_3_2__lt a b
iret_7_5__str_order OpLe a b = lstr_3_2__lt a b || lstr_3_1__eq a b
iret_7_5__str_order OpGt a b = lstr_3_2__lt b a
iret_7_5__str_order OpGe a b = lstr_3_2__lt b a || lstr_3_1__eq a b

--@spec [IRET.7.5]
||| Equality and inequality on a type the model cannot order -- two Bools,
||| or two `Json` values; an ordering is a trap here (the residue in the
||| header).
public export
iret_7_5__eq_only : Iret_7_5__cmp -> Bool -> Lerr_1_4_1__result
iret_7_5__eq_only OpEq same = RVal (VBool same)
iret_7_5__eq_only OpNe same = RVal (VBool (not same))
iret_7_5__eq_only _    _    = RTrap

--@spec [IRET.7.5]
--@spec [LNUL.4.1]
--@spec [LEXP.7.3]
||| The right operand of a comparison whose left is the Int `a`: an Int
||| compares in Int, a Float promotes `a` and compares in Float.
public export
iret_7_5__cmp_int : Lnul_2_1__value -> Iret_7_5__cmp -> Integer -> Lerr_1_4_1__result
iret_7_5__cmp_int VNull      _  _ = RVal VNull
iret_7_5__cmp_int (VInt b)   op a = RVal (VBool (iret_7_5__int_order op a b))
iret_7_5__cmp_int (VFloat b) op a = RVal (VBool (iret_7_5__float_order op (lexp_7_3__promote a) b))
iret_7_5__cmp_int _          _  _ = RTrap

--@spec [IRET.7.5]
--@spec [LNUL.4.1]
--@spec [LEXP.7.3]
||| The right operand of a comparison whose left is the Float `a`: a Float
||| compares, an Int promotes first.
public export
iret_7_5__cmp_float : Lnul_2_1__value -> Iret_7_5__cmp -> Double -> Lerr_1_4_1__result
iret_7_5__cmp_float VNull      _  _ = RVal VNull
iret_7_5__cmp_float (VFloat b) op a = RVal (VBool (iret_7_5__float_order op a b))
iret_7_5__cmp_float (VInt b)   op a = RVal (VBool (iret_7_5__float_order op a (lexp_7_3__promote b)))
iret_7_5__cmp_float _          _  _ = RTrap

--@spec [IRET.7.5]
--@spec [LNUL.4.1]
--@spec [LSTR.3.1]
--@spec [LSTR.3.2]
||| The right operand of a comparison whose left is the String `a`: a
||| String compares by [LSTR.3.1]'s equality and [LSTR.3.2]'s order,
||| `null` propagates, anything else is ill-typed.
public export
iret_7_5__cmp_str : Lnul_2_1__value -> Iret_7_5__cmp -> Lstr_1_1__text -> Lerr_1_4_1__result
iret_7_5__cmp_str VNull    _  _ = RVal VNull
iret_7_5__cmp_str (VStr b) op a = RVal (VBool (iret_7_5__str_order op a b))
iret_7_5__cmp_str _        _  _ = RTrap

--@spec [IRET.7.5]
--@spec [LNUL.4.1]
||| The right operand of a comparison whose left is the Bool `a`.
public export
iret_7_5__cmp_bool : Lnul_2_1__value -> Iret_7_5__cmp -> Bool -> Lerr_1_4_1__result
iret_7_5__cmp_bool VNull     _  _ = RVal VNull
iret_7_5__cmp_bool (VBool b) op a = iret_7_5__eq_only op (a == b)
iret_7_5__cmp_bool _         _  _ = RTrap

-- ---------------------------------------------------------------------
-- Json leaves: paths, `has`, `len`, and equality of documents
-- ---------------------------------------------------------------------

--@spec [LGRA.5.8.5]
--@spec [LGRA.5.8.1]
||| One segment of a path into a `Json` value: a dotted member name (its
||| key token) or a bracket index -- [LGRA.5.8.1]'s dot and bracket
||| operators, which [LGRA.5.8.5] admits past a `Json` slot and nowhere
||| else.
public export
data Lgra_5_8_5__seg : Type where
  SKey   : Nat -> Lgra_5_8_5__seg
  SIndex : Nat -> Lgra_5_8_5__seg

--@spec [LNUL.8.4]
||| The member of an object under a key, if it has one.
public export
lnul_8_4__member : Nat -> List (Nat, Lgra_5_8_1__json) -> Maybe Lgra_5_8_1__json
lnul_8_4__member k []               = Nothing
lnul_8_4__member k ((k', v) :: ms) = if k == k' then Just v else lnul_8_4__member k ms

--@spec [LNUL.8.4]
--@spec [LGRA.5.8.5]
||| Whether a path resolves, and to what: segment by segment, a key into
||| the object's member under it and an index into the array's element at
||| it; a key with no member, an index past the end, and either segment into
||| a value that is not the container it addresses leave the path
||| UNRESOLVED -- [LNUL.8.4]'s absence, `has(path) == false`. The empty
||| path resolves to the value itself.
public export
lnul_8_4__resolve : List Lgra_5_8_5__seg -> Lgra_5_8_1__json -> Maybe Lgra_5_8_1__json
lnul_8_4__resolve []                j         = Just j
lnul_8_4__resolve (SKey k :: ss)    (JObj ms) = case lnul_8_4__member k ms of
  Nothing => Nothing
  Just v  => lnul_8_4__resolve ss v
lnul_8_4__resolve (SIndex i :: ss)  (JArr xs) = case rarc_5_6_5__nth i xs of
  Nothing => Nothing
  Just v  => lnul_8_4__resolve ss v
lnul_8_4__resolve (_ :: _)          _         = Nothing

--@spec [LNUL.8.4]
--@spec [LEXP.7.12.1]
--@spec [LNUL.3.4]
||| What a path read yields. An unresolved path reads as `null` (absence,
||| [LNUL.8.4]); a path present with a JSON null reads as `null` AS A
||| VALUE (the same `null`: there is one, [LNUL.3.4]); a scalar leaf is its
||| value, of the kind it was written with ([LEXP.7.12.1]); an array or an
||| object is the sub-document itself, a `Json` value -- which no arithmetic
||| or ordering takes (a TypeError, [LEXP.7.12.1]), `len` reads
||| ([LEXP.6.1]) and `==` compares deeply ([LEXP.7.19]).
public export
lnul_8_4__read : Maybe Lgra_5_8_1__json -> Lnul_2_1__value
lnul_8_4__read Nothing           = VNull
lnul_8_4__read (Just JNull)      = VNull
lnul_8_4__read (Just (JBool b))  = VBool b
lnul_8_4__read (Just (JInt n))   = VInt n
lnul_8_4__read (Just (JFloat x)) = VFloat x
lnul_8_4__read (Just (JStr s))   = VStr s
lnul_8_4__read (Just (JArr xs))  = VJson (JArr xs)
lnul_8_4__read (Just (JObj ms))  = VJson (JObj ms)

--@spec [LNUL.8.4]
--@spec [LNUL.4.1]
||| A path read over its evaluated root: of a `Json` value, the read above;
||| of `null` (a `Json?` slot holding none), `null` ([LNUL.4.1]); of a
||| fault, the fault ([LNUL.4.10]); of a value of any other kind a trap
||| HERE and not DS -- the compiler refuses a path past such a slot
||| ([LGRA.5.8.5]), so no runtime sees the form.
public export
lnul_8_4__path : List Lgra_5_8_5__seg -> Lerr_1_4_1__result -> Lerr_1_4_1__result
lnul_8_4__path segs RTrap            = RTrap
lnul_8_4__path segs (RVal (VJson j)) = RVal (lnul_8_4__read (lnul_8_4__resolve segs j))
lnul_8_4__path segs (RVal VNull)     = RVal VNull
lnul_8_4__path segs (RVal _)         = RTrap

--@spec [LEXP.6.1]
--@spec [LNUL.8.4]
||| `has(<path>)`: whether the path resolves, a Bool for every document --
||| the one absence test, `true` of a path present with a JSON null and
||| `false` of one that does not resolve. Of a fault, the fault. Of a root
||| that is not a document -- `null` (a `Json?` slot holding none) or a value
||| of any other kind -- a trap HERE, as both runtimes raise a type mismatch
||| there: no well-formed program reaches it, since `has` demands a value of
||| a particular kind and an unnarrowed `Json?` receiver is [LNUL.5.1]'s
||| compile error (`DS_VALIDATE_NULLABLE_UNNARROWED`;
||| compiler/LNUL.5.1_has_on_unnarrowed_json_refused), and [LNUL.4.1]'s
||| propagation is the operators', not a builtin's.
public export
lexp_6_1__has : List Lgra_5_8_5__seg -> Lerr_1_4_1__result -> Lerr_1_4_1__result
lexp_6_1__has segs RTrap            = RTrap
lexp_6_1__has segs (RVal (VJson j)) = RVal (VBool (isJust (lnul_8_4__resolve segs j)))
lexp_6_1__has segs (RVal _)         = RTrap

--@spec [LEXP.6.1]
--@spec [LEXP.6.2]
||| `len(<Json>)`: the length of an array, an Int; of anything else -- an
||| object, a scalar leaf, and `null`, which an unresolved path reads as
||| and is not an array either -- a TypeError that abandons the activation
||| ([LEXP.6.2], [LEXP.7.12.1]), a trap. A fault in the operand stands.
public export
lexp_6_1__len : Lerr_1_4_1__result -> Lerr_1_4_1__result
lexp_6_1__len RTrap                    = RTrap
lexp_6_1__len (RVal (VJson (JArr xs))) = RVal (VInt (cast (length xs)))
lexp_6_1__len (RVal _)                 = RTrap

--@spec [IRET.7.5]
--@spec [LEXP.7.19]
--@spec [LNUL.4.1]
||| The right operand of a comparison whose left is the `Json` value `a`:
||| another `Json` value compares by deep structural equality, `==` and
||| `!=` only ([LEXP.7.19]: the compiler refuses an ordering); `null`
||| propagates; anything else is ill-typed, a TypeError ([LEXP.7.12.1]).
public export
iret_7_5__cmp_json : Lnul_2_1__value -> Iret_7_5__cmp -> Lgra_5_8_1__json -> Lerr_1_4_1__result
iret_7_5__cmp_json VNull     _  _ = RVal VNull
iret_7_5__cmp_json (VJson b) op a = iret_7_5__eq_only op (lfac_2_5_1__json_eq a b)
iret_7_5__cmp_json _         _  _ = RTrap

--@spec [LNUL.4.1]
--@spec [IRET.7.5]
||| A comparison: a `null` operand yields `null`; like with like compares,
||| an Int beside a Float promotes, two `Json` values compare deeply;
||| anything else is ill-typed.
public export
lnul_4_1__cmp : Iret_7_5__cmp -> Lnul_2_1__value -> Lnul_2_1__value -> Lerr_1_4_1__result
lnul_4_1__cmp op VNull      _ = RVal VNull
lnul_4_1__cmp op (VInt a)   b = iret_7_5__cmp_int b op a
lnul_4_1__cmp op (VFloat a) b = iret_7_5__cmp_float b op a
lnul_4_1__cmp op (VStr a)   b = iret_7_5__cmp_str b op a
lnul_4_1__cmp op (VBool a)  b = iret_7_5__cmp_bool b op a
lnul_4_1__cmp op (VJson a)  b = iret_7_5__cmp_json b op a

--@derives [LNUL.4.1]
||| A `null` left operand makes any arithmetic `null`, for every operator
||| and every right operand.
public export
lnul_4_1__arith_null_left :
  (op : Lexp_7_2__arith) -> (v : Lnul_2_1__value) ->
  lnul_4_1__arith op VNull v = RVal VNull
lnul_4_1__arith_null_left _ _ = Refl

--@derives [LNUL.4.1]
||| And a `null` right operand, for every operator and every left operand.
public export
lnul_4_1__arith_null_right :
  (op : Lexp_7_2__arith) -> (v : Lnul_2_1__value) ->
  lnul_4_1__arith op v VNull = RVal VNull
lnul_4_1__arith_null_right _ (VInt _)   = Refl
lnul_4_1__arith_null_right _ (VFloat _) = Refl
lnul_4_1__arith_null_right _ (VStr _)   = Refl
lnul_4_1__arith_null_right _ (VBool _)  = Refl
lnul_4_1__arith_null_right _ (VJson _)  = Refl
lnul_4_1__arith_null_right _ VNull      = Refl

--@derives [LNUL.4.1]
||| A `null` left operand makes any comparison `null` — `==` included:
||| there is no exception.
public export
lnul_4_1__cmp_null_left :
  (op : Iret_7_5__cmp) -> (v : Lnul_2_1__value) ->
  lnul_4_1__cmp op VNull v = RVal VNull
lnul_4_1__cmp_null_left _ _ = Refl

--@derives [LNUL.4.1]
||| And a `null` right operand.
public export
lnul_4_1__cmp_null_right :
  (op : Iret_7_5__cmp) -> (v : Lnul_2_1__value) ->
  lnul_4_1__cmp op v VNull = RVal VNull
lnul_4_1__cmp_null_right _ (VInt _)   = Refl
lnul_4_1__cmp_null_right _ (VFloat _) = Refl
lnul_4_1__cmp_null_right _ (VStr _)   = Refl
lnul_4_1__cmp_null_right _ (VBool _)  = Refl
lnul_4_1__cmp_null_right _ (VJson _)  = Refl
lnul_4_1__cmp_null_right _ VNull      = Refl

--@derives [LEXP.7.15.1]
--@derives [LERR.1.4.3]
||| A zero divisor under `/`, `//` or `%` is a trap for every Int dividend:
||| the clause's runtime error, with no value to go on with -- `/` included,
||| though its result would be a Float.
public export
lexp_7_15_1__int_zero_divisor_traps :
  (a : Integer) ->
  ( lnul_4_1__arith OpDiv (VInt a) (VInt 0) = RTrap
  , lnul_4_1__arith OpFloorDiv (VInt a) (VInt 0) = RTrap
  , lnul_4_1__arith OpMod (VInt a) (VInt 0) = RTrap )
lexp_7_15_1__int_zero_divisor_traps _ = (Refl, Refl, Refl)

--@derives [LEXP.7.4]
--@derives [LEXP.7.3]
||| `/` on two Ints with a nonzero divisor is the Float quotient of their
||| promotions, for every such pair: the operator always produces a Float.
||| Proved by splitting the divisor test rather than by `rewrite`: a
||| rewrite's motive is the normalised goal, in which `/` is the primitive
||| `prim__div_Double`, which Idris marks non-covering.
public export
lexp_7_4__div_of_ints :
  (a, b : Integer) -> (b == 0) = False ->
  lnul_4_1__arith OpDiv (VInt a) (VInt b) = RVal (lexp_7_4__quotient a b)
lexp_7_4__div_of_ints a b nz = split (b == 0) nz
  where
    split : (c : Bool) -> c = False ->
            lexp_7_4__guarded c a b = RVal (lexp_7_4__quotient a b)
    split False Refl = Refl
    split True  p    = absurd p

--@derives [LEXP.7.15.1]
--@derives [LEXP.7.5]
--@derives [LEXP.7.6]
--@derives [LDET.3.6.2]
||| With a Float operand, `//` and `%` yield a Float for every pair of
||| operands -- a zero, an infinite or a NaN divisor or dividend included --
||| and never a trap: the all-Int zero divisor is the one runtime error of
||| the three operators, and an Int beside a Float promotes and takes the
||| Float's rows. Four shapes: Float beside Float, and an Int on either side.
||| The witnesses are the compositions themselves; what they are worth on an
||| input is Double arithmetic, run in Main.idr.
public export
lexp_7_15_1__float_divmod_never_traps :
  (a, b : Double) -> (n : Integer) ->
  ( (q : Double ** lnul_4_1__arith OpFloorDiv (VFloat a) (VFloat b) = RVal (VFloat q))
  , (r : Double ** lnul_4_1__arith OpMod (VFloat a) (VFloat b) = RVal (VFloat r))
  , (q : Double ** lnul_4_1__arith OpFloorDiv (VInt n) (VFloat b) = RVal (VFloat q))
  , (r : Double ** lnul_4_1__arith OpMod (VInt n) (VFloat b) = RVal (VFloat r))
  , (q : Double ** lnul_4_1__arith OpFloorDiv (VFloat a) (VInt n) = RVal (VFloat q))
  , (r : Double ** lnul_4_1__arith OpMod (VFloat a) (VInt n) = RVal (VFloat r)) )
lexp_7_15_1__float_divmod_never_traps a b n =
  ( (lexp_7_5__float_floordiv a b ** Refl)
  , (lexp_7_6__float_mod a b ** Refl)
  , (lexp_7_5__float_floordiv (lexp_7_3__promote n) b ** Refl)
  , (lexp_7_6__float_mod (lexp_7_3__promote n) b ** Refl)
  , (lexp_7_5__float_floordiv a (lexp_7_3__promote n) ** Refl)
  , (lexp_7_6__float_mod a (lexp_7_3__promote n) ** Refl) )

--@derives [LNUL.9.3]
--@derives [LNUL.4.10]
||| A `null` operand short-circuits the operation: `null // 0` and
||| `0 // null` are `null`, never the zero-divisor trap, and so for every
||| operator and every other operand -- the division is never performed
||| ([LNUL.9.3]; [LNUL.4.10]'s last paragraph; formal/k/dsexpr.k's
||| `div_null_zero`).
public export
lnul_9_3__null_before_the_divisor :
  (op : Lexp_7_2__arith) -> (b : Integer) ->
  ( lnul_4_1__arith op VNull (VInt b) = RVal VNull
  , lnul_4_1__arith op (VInt b) VNull = RVal VNull )
lnul_9_3__null_before_the_divisor _ _ = (Refl, Refl)

-- ---------------------------------------------------------------------
-- The total tag test
-- ---------------------------------------------------------------------

--@spec [LNUL.4.9]
--@spec [LGRA.9.3.3]
||| The twelve subjects of `is`, a closed set: six distinguished constants
||| and six tag names. [LGRA.9.3.3] is the surface, [LNUL.4.9] the meaning.
public export
data Lnul_4_9__subject : Type where
  IsNull   : Lnul_4_9__subject
  IsTrue   : Lnul_4_9__subject
  IsFalse  : Lnul_4_9__subject
  IsInf    : Lnul_4_9__subject
  IsNegInf : Lnul_4_9__subject
  IsNaN    : Lnul_4_9__subject
  IsInt    : Lnul_4_9__subject
  IsFloat  : Lnul_4_9__subject
  IsBool   : Lnul_4_9__subject
  IsString : Lnul_4_9__subject
  IsBytes  : Lnul_4_9__subject
  IsJson   : Lnul_4_9__subject

--@spec [LNUL.4.9]
||| The clause's table (the three special tests, `lnul_4_9__nan`,
||| `lnul_4_9__inf` and `lnul_4_9__neg_inf`, sit above the arithmetic, which
||| reads them too). A constant tests tag AND value; a tag name tests the
||| tag alone; `false` in every other case, a `null` value under any subject
||| but `null` included. `Bytes` is a tag no value of the fragment carries;
||| `Json` is the tag of a document.
public export
lnul_4_9__tag_and_value : Lnul_4_9__subject -> Lnul_2_1__value -> Bool
lnul_4_9__tag_and_value IsNull   VNull      = True
lnul_4_9__tag_and_value IsTrue   (VBool b)  = b
lnul_4_9__tag_and_value IsFalse  (VBool b)  = not b
lnul_4_9__tag_and_value IsInf    (VFloat x) = lnul_4_9__inf x
lnul_4_9__tag_and_value IsNegInf (VFloat x) = lnul_4_9__neg_inf x
lnul_4_9__tag_and_value IsNaN    (VFloat x) = lnul_4_9__nan x
lnul_4_9__tag_and_value IsInt    (VInt _)   = True
lnul_4_9__tag_and_value IsFloat  (VFloat _) = True
lnul_4_9__tag_and_value IsBool   (VBool _)  = True
lnul_4_9__tag_and_value IsString (VStr _)   = True
lnul_4_9__tag_and_value IsJson   (VJson _)  = True
lnul_4_9__tag_and_value _        _          = False

--@spec [LNUL.4.9]
--@spec [LNUL.4.4]
||| `x is <subject>`, and with the flag `x is not <subject>` -- one operator,
||| not `not` applied to `is`: `true` or `false` for a value of any kind,
||| never `null`. With the `null` subject it is [LNUL.4.4]'s total null test,
||| `is null` / `is not null`. An operand that faults has no value for a tag
||| to be read off, and the fault stands ([LNUL.4.10]).
public export
lnul_4_9__is : (negated : Bool) -> Lnul_4_9__subject -> Lerr_1_4_1__result -> Lerr_1_4_1__result
lnul_4_9__is _     _ RTrap    = RTrap
lnul_4_9__is False s (RVal v) = RVal (VBool (lnul_4_9__tag_and_value s v))
lnul_4_9__is True  s (RVal v) = RVal (VBool (not (lnul_4_9__tag_and_value s v)))

-- ---------------------------------------------------------------------
-- Coalesce
-- ---------------------------------------------------------------------

--@spec [LNUL.5.3]
--@spec [LNUL.8.9]
||| `x ?? d`: `x` when it has a value that is not `null`, else `d`, which is
||| passed unevaluated and evaluated only then. A trap in `x` is the answer
||| (the header's reading); a trap in `d` is the answer only when `x` is
||| `null`.
public export
lnul_5_3__coalesce : Lerr_1_4_1__result -> (() -> Lerr_1_4_1__result) -> Lerr_1_4_1__result
lnul_5_3__coalesce RTrap        _ = RTrap
lnul_5_3__coalesce (RVal VNull) d = d ()
lnul_5_3__coalesce (RVal v)     _ = RVal v

-- ---------------------------------------------------------------------
-- The conversion cast
-- ---------------------------------------------------------------------

--@spec [LCST.4.1.6]
||| The target of a cast in the fragment: the four scalar builtins. The
||| clause also admits `Json` and a unit; neither is a value of the
||| fragment, and the lowering refuses the form (the header's residue). A
||| schema target is the compiler's rejection and reaches no runtime.
public export
data Lcst_4_1_6__target : Type where
  TInt    : Lcst_4_1_6__target
  TFloat  : Lcst_4_1_6__target
  TBool   : Lcst_4_1_6__target
  TString : Lcst_4_1_6__target

--@spec [LCST.4.5.2]
--@spec [LERR.1.4.10]
||| A Float whose truncation toward zero is an Int: -2^63 <= x < 2^63. The
||| two bounds are built from the Int, as formal/k/dscast.k builds them,
||| and are exact doubles; the double below 2^63 is 2^63 - 1024 and the one
||| below -2^63 is -2^63 - 2048, so the test admits no value that truncates
||| past INT64_MAX and loses none that truncates to INT64_MIN. A NaN fails
||| both comparisons and an infinity one of them, so [LERR.1.4.10]'s
||| "non-finite, or finite and outside `Int`" is this one test's `False`.
public export
lcst_4_5_2__in_int : Double -> Bool
lcst_4_5_2__in_int x =
  x >= lexp_7_3__promote (-9223372036854775808) && x < lexp_7_3__promote 9223372036854775808

--@spec [LCST.4.5.2]
||| Truncation toward zero of a Float inside Int, over the primitive cast
||| with formal/k/dscast.k's one-step correction: where the primitive
||| rounded away from zero -- promoting its result back lands beyond `x` --
||| the result moves one toward zero. Right whichever way the primitive
||| rounds (Chez's `floor`, a truncation, or a rounding to nearest), and the
||| correction never fires above 2^52, where every double is integral.
||| That it truncates is run on dscast.k's vectors in Main.idr, not proved
||| against the primitive. Never consulted outside Int: that is the trap,
||| `lcst_4_5_2__guarded`'s.
public export
lcst_4_5_2__trunc : Double -> Integer
lcst_4_5_2__trunc x =
  let q    = the Integer (cast x)
      back = lexp_7_3__promote q
  in if x >= 0.0 && back > x then q - 1
     else if x < 0.0 && back < x then q + 1
     else q

--@spec [LCST.4.5.2]
--@spec [LCST.4.5.4]
||| `Float :: Int` with the range test decided: inside Int the truncation,
||| outside it the trap -- [LCST.4.5.4]'s carve-out, a trap and never
||| `null`. A named split rather than an `if`, so a theorem can reason
||| about the test left undecided, as `lexp_7_4__guarded` is.
public export
lcst_4_5_2__guarded : Bool -> Double -> Lerr_1_4_1__result
lcst_4_5_2__guarded True  x = RVal (VInt (lcst_4_5_2__trunc x))
lcst_4_5_2__guarded False _ = RTrap

--@spec [LCST.4.5.2]
--@spec [LCST.4.5.1]
--@spec [LCST.4.5.4]
--@spec [LERR.1.4.10]
||| A defined conversion of a value, by target: the identity for a value
||| already of the target's type ([LCST.4.5.1]); `Int -> Float`, the
||| widening to the nearest double ([LCST.4.5.2], `lexp_7_3__promote`);
||| `Float -> Int`, the truncation toward zero inside Int and the trap
||| outside it ([LCST.4.5.2], [LCST.4.5.4], [LERR.1.4.10]); the fallible
||| parses `String -> Int` ([LCST.4.5.7]), `String -> Float` ([LCST.4.5.8])
||| and `String -> Bool` ([LCST.4.5.5]), a value or `null`; the renders
||| `Int -> String`, `Float -> String` and `Bool -> String` ([LCST.4.5.6],
||| the Float in [LDET.3.2.7]'s form). The rest is a trap HERE and not DS
||| (the header's residue): numeric <-> Bool the compiler rejects
||| ([LCST.4.5.2]) and no runtime sees. A `null` reaches no conversion
||| ([LCST.4.3.4]) and `lcst_4_2__cast` never passes one; the function is
||| total over values all the same.
public export
lcst_4_5_2__convert : Lcst_4_1_6__target -> Lnul_2_1__value -> Lerr_1_4_1__result
lcst_4_5_2__convert TInt    (VInt n)   = RVal (VInt n)
lcst_4_5_2__convert TFloat  (VFloat x) = RVal (VFloat x)
lcst_4_5_2__convert TBool   (VBool b)  = RVal (VBool b)
lcst_4_5_2__convert TString (VStr s)   = RVal (VStr s)
lcst_4_5_2__convert TFloat  (VInt n)   = RVal (VFloat (lexp_7_3__promote n))
lcst_4_5_2__convert TInt    (VFloat x) = lcst_4_5_2__guarded (lcst_4_5_2__in_int x) x
lcst_4_5_2__convert TInt    (VStr t)   = lnul_8_4__parsed (map VInt (lcst_4_5_7__parse_int t))
lcst_4_5_2__convert TFloat  (VStr t)   = lnul_8_4__parsed (map VFloat (lcst_4_5_8__parse_float t))
lcst_4_5_2__convert TBool   (VStr t)   = lnul_8_4__parsed (map VBool (lcst_4_5_5__parse_bool t))
lcst_4_5_2__convert TString (VInt n)   = RVal (VStr (lcst_4_5_6__render_int n))
lcst_4_5_2__convert TString (VFloat x) = lcst_4_5_6__render_float x
lcst_4_5_2__convert TString (VBool b)  = RVal (VStr (lcst_4_5_6__render_bool b))
lcst_4_5_2__convert _       _          = RTrap

--@spec [LCST.4.3.1]
--@spec [LCST.4.5.2]
||| Whether a (target, source value) pair is a FALLIBLE conversion, which
||| [LCST.4.3.1] admits under `::T?` alone: the parses from a String to
||| Int, Float or Bool. Every other pair of the fragment is total.
public export
lcst_4_3_1__fallible : Lcst_4_1_6__target -> Lnul_2_1__value -> Bool
lcst_4_3_1__fallible TInt   (VStr _) = True
lcst_4_3_1__fallible TFloat (VStr _) = True
lcst_4_3_1__fallible TBool  (VStr _) = True
lcst_4_3_1__fallible _      _        = False

--@spec [LCST.4.3.1]
||| The bare `::T` with the fallibility decided: a fallible pair under it
||| is the compiler's error ("must be `::T?`"), which no runtime sees, a
||| trap HERE; a total pair converts. A named split rather than an `if`, so
||| a theorem can reason about the decision left undecided.
public export
lcst_4_3_1__total_form : Bool -> Lcst_4_1_6__target -> Lnul_2_1__value -> Lerr_1_4_1__result
lcst_4_3_1__total_form True  _ _ = RTrap
lcst_4_3_1__total_form False t v = lcst_4_5_2__convert t v

--@spec [LCST.4.2]
--@spec [LCST.4.2.1]
--@spec [LCST.4.2.3]
--@spec [LCST.4.3.4]
||| `e :: T` (fallible `False`) and `e :: T?` (fallible `True`) over the
||| operand's result, as one operator. A trap in the operand stands
||| ([LNUL.4.10]: a fault has no value to convert). A `null` under `::T?`
||| is `null` with no conversion attempted ([LCST.4.3.4], [LCST.4.2.3]);
||| under a bare `::T` a `null` operand is the clause's compile error
||| ([LCST.4.2.3], [LCST.4.3.1]), which no runtime sees, a trap HERE (the
||| header's residue). A value converts by `lcst_4_5_2__convert`: under
||| `::T?` a total pair yields its value and a fallible one -- a parse from
||| a String -- its value or `null` ([LCST.4.2.2]); under the bare `::T` a
||| total pair yields a value or [LCST.4.5.4]'s trap and never `null`
||| ([LCST.4.2.1]), and a fallible pair is [LCST.4.3.1]'s compile error,
||| a trap HERE (`lcst_4_3_1__total_form`).
public export
lcst_4_2__cast : (fallible : Bool) -> Lcst_4_1_6__target -> Lerr_1_4_1__result -> Lerr_1_4_1__result
lcst_4_2__cast _     _ RTrap        = RTrap
lcst_4_2__cast True  _ (RVal VNull) = RVal VNull
lcst_4_2__cast False _ (RVal VNull) = RTrap
lcst_4_2__cast True  t (RVal v)     = lcst_4_5_2__convert t v
lcst_4_2__cast False t (RVal v)     = lcst_4_3_1__total_form (lcst_4_3_1__fallible t v) t v

--@derives [LCST.4.3.4]
--@derives [LCST.4.2.3]
||| A `null` source converts to `null` under `::T?`, for every target: the
||| conversion is not attempted and nothing is raised -- the clause's
||| "`null::T?` -> `null`".
public export
lcst_4_3_4__null_source_converts_to_null :
  (t : Lcst_4_1_6__target) -> lcst_4_2__cast True t (RVal VNull) = RVal VNull
lcst_4_3_4__null_source_converts_to_null _ = Refl

--@derives [LCST.4.5.1]
||| The identity is a no-op for every value of each of the fragment's four
||| types, under either form.
public export
lcst_4_5_1__identity_is_a_no_op :
  (f : Bool) -> (n : Integer) -> (x : Double) -> (s : Lstr_1_1__text) -> (b : Bool) ->
  ( lcst_4_2__cast f TInt (RVal (VInt n)) = RVal (VInt n)
  , lcst_4_2__cast f TFloat (RVal (VFloat x)) = RVal (VFloat x)
  , lcst_4_2__cast f TString (RVal (VStr s)) = RVal (VStr s)
  , lcst_4_2__cast f TBool (RVal (VBool b)) = RVal (VBool b) )
lcst_4_5_1__identity_is_a_no_op False _ _ _ _ = (Refl, Refl, Refl, Refl)
lcst_4_5_1__identity_is_a_no_op True  _ _ _ _ = (Refl, Refl, Refl, Refl)

--@derives [LCST.4.5.2]
--@derives [LCST.4.2.1]
||| `Int :: Float` is total for every Int, under either form: the widening
||| to the nearest double, a value and never `null` or a trap.
public export
lcst_4_5_2__int_to_float_is_total :
  (f : Bool) -> (n : Integer) ->
  lcst_4_2__cast f TFloat (RVal (VInt n)) = RVal (VFloat (lexp_7_3__promote n))
lcst_4_5_2__int_to_float_is_total False _ = Refl
lcst_4_5_2__int_to_float_is_total True  _ = Refl

--@spec [LCST.4.5.4]
||| Whether a result is the value `null`: what a total conversion must not
||| produce at runtime.
public export
lcst_4_5_4__yields_null : Lerr_1_4_1__result -> Bool
lcst_4_5_4__yields_null (RVal VNull) = True
lcst_4_5_4__yields_null _            = False

--@derives [LCST.4.5.4]
--@derives [LCST.4.5.2]
--@derives [LCST.4.2.1]
--@derives [LERR.1.4.10]
||| `Float :: Int` is total for every Float in the clause's sense: inside
||| Int it is the truncation toward zero, outside it the trap, and in no
||| case `null` -- the trap is not a fallible result. Under either form.
||| Proved by splitting the range test, as `lexp_7_4__div_of_ints` splits
||| the divisor's.
public export
lcst_4_5_4__float_to_int_is_total :
  (f : Bool) -> (x : Double) ->
  ( lcst_4_5_2__in_int x = True -> lcst_4_2__cast f TInt (RVal (VFloat x)) = RVal (VInt (lcst_4_5_2__trunc x))
  , lcst_4_5_2__in_int x = False -> lcst_4_2__cast f TInt (RVal (VFloat x)) = RTrap
  , lcst_4_5_4__yields_null (lcst_4_2__cast f TInt (RVal (VFloat x))) = False )
lcst_4_5_4__float_to_int_is_total f x = both f
  where
    split : (c : Bool) ->
            ( c = True -> lcst_4_5_2__guarded c x = RVal (VInt (lcst_4_5_2__trunc x))
            , c = False -> lcst_4_5_2__guarded c x = RTrap
            , lcst_4_5_4__yields_null (lcst_4_5_2__guarded c x) = False )
    split True  = (\_ => Refl, \p => absurd p, Refl)
    split False = (\p => absurd p, \_ => Refl, Refl)
    both : (g : Bool) ->
           ( lcst_4_5_2__in_int x = True -> lcst_4_2__cast g TInt (RVal (VFloat x)) = RVal (VInt (lcst_4_5_2__trunc x))
           , lcst_4_5_2__in_int x = False -> lcst_4_2__cast g TInt (RVal (VFloat x)) = RTrap
           , lcst_4_5_4__yields_null (lcst_4_2__cast g TInt (RVal (VFloat x))) = False )
    both False = split (lcst_4_5_2__in_int x)
    both True  = split (lcst_4_5_2__in_int x)

--@derives [LCST.4.5.4]
||| The trap never feeds the `T?` / `??` / Kleene stack: for every Float
||| outside Int and EVERY default, `(x :: Int ?? d)` is the trap and not
||| `d`, the test admits no activation and blocks a `no` pattern -- the
||| fixture LCST.4.5.4.non_finite_float_to_int_is_not_a_null's claim, for
||| every such value.
public export
lcst_4_5_4__trap_never_feeds_the_stack :
  (x : Double) -> lcst_4_5_2__in_int x = False -> (d : () -> Lerr_1_4_1__result) ->
  ( lnul_5_3__coalesce (lcst_4_2__cast False TInt (RVal (VFloat x))) d = RTrap
  , lnul_4_3__admits (lnul_4_2__answer_of (lcst_4_2__cast False TInt (RVal (VFloat x)))) = False
  , lnul_4_7__blocks (lnul_4_2__answer_of (lcst_4_2__cast False TInt (RVal (VFloat x)))) = True )
lcst_4_5_4__trap_never_feeds_the_stack x out d = split (lcst_4_5_2__in_int x) out
  where
    split : (c : Bool) -> c = False ->
            ( lnul_5_3__coalesce (lcst_4_5_2__guarded c x) d = RTrap
            , lnul_4_3__admits (lnul_4_2__answer_of (lcst_4_5_2__guarded c x)) = False
            , lnul_4_7__blocks (lnul_4_2__answer_of (lcst_4_5_2__guarded c x)) = True )
    split False Refl = (Refl, Refl, Refl)
    split True  p    = absurd p

--@derives [LNUL.4.10]
||| A cast of an operand that faults is the fault, for either form and every
||| target: a fault has no value to convert -- [LNUL.4.10]'s rule for every
||| operator but `and`, `or` and `??`.
public export
lnul_4_10__cast_of_a_trap_is_the_trap :
  (f : Bool) -> (t : Lcst_4_1_6__target) -> lcst_4_2__cast f t RTrap = RTrap
lnul_4_10__cast_of_a_trap_is_the_trap False _ = Refl
lnul_4_10__cast_of_a_trap_is_the_trap True  _ = Refl

-- ---------------------------------------------------------------------
-- Json leaves: what the clauses claim, quantified
-- ---------------------------------------------------------------------

--@derives [LERR.1.3.1]
--@derives [LNUL.8.4]
||| A PATH READ NEVER FAULTS: for every path and every document the read is
||| a value. Absence is not a fault -- "the value is absent; the operation
||| is not wrong" -- and neither is anything else a path finds.
public export
lerr_1_3_1__absence_never_traps :
  (segs : List Lgra_5_8_5__seg) -> (j : Lgra_5_8_1__json) ->
  (v : Lnul_2_1__value ** lnul_8_4__path segs (RVal (VJson j)) = RVal v)
lerr_1_3_1__absence_never_traps segs j = (lnul_8_4__read (lnul_8_4__resolve segs j) ** Refl)

--@derives [LNUL.8.4]
||| An unresolved path reads as `null`, for every path and document that
||| does not resolve.
public export
lnul_8_4__absent_reads_null :
  (segs : List Lgra_5_8_5__seg) -> (j : Lgra_5_8_1__json) ->
  lnul_8_4__resolve segs j = Nothing -> lnul_8_4__path segs (RVal (VJson j)) = RVal VNull
lnul_8_4__absent_reads_null segs j prf = cong (\m => RVal (lnul_8_4__read m)) prf

--@derives [LNUL.8.4]
--@derives [LNUL.3.4]
||| A path present with a JSON null reads as `null` too, the same value, for
||| every path and document that resolves to one: there is one `null`.
public export
lnul_8_4__present_null_reads_null :
  (segs : List Lgra_5_8_5__seg) -> (j : Lgra_5_8_1__json) ->
  lnul_8_4__resolve segs j = Just JNull -> lnul_8_4__path segs (RVal (VJson j)) = RVal VNull
lnul_8_4__present_null_reads_null segs j prf = cong (\m => RVal (lnul_8_4__read m)) prf

--@derives [LNUL.8.4]
--@derives [LEXP.6.1]
||| THE TWO MISSINGS ARE DISTINCT, AND `has` IS WHAT SEPARATES THEM. For
||| every path and document: `has` answers a Bool, whether the path
||| resolves; when it answers `false` the read is `null` (absence); when the
||| path resolves to a JSON null it answers `true` and the read is `null`
||| as well (a present value). The read alone cannot tell the two apart,
||| and `has` can.
public export
lnul_8_4__has_separates_the_missings :
  (segs : List Lgra_5_8_5__seg) -> (j : Lgra_5_8_1__json) ->
  ( lexp_6_1__has segs (RVal (VJson j)) = RVal (VBool (isJust (lnul_8_4__resolve segs j)))
  , isJust (lnul_8_4__resolve segs j) = False -> lnul_8_4__path segs (RVal (VJson j)) = RVal VNull
  , lnul_8_4__resolve segs j = Just JNull ->
      ( lexp_6_1__has segs (RVal (VJson j)) = RVal (VBool True)
      , lnul_8_4__path segs (RVal (VJson j)) = RVal VNull ) )
lnul_8_4__has_separates_the_missings segs j =
  (Refl, absent (lnul_8_4__resolve segs j), present)
  where
    absent : (m : Maybe Lgra_5_8_1__json) -> isJust m = False -> RVal (lnul_8_4__read m) = RVal VNull
    absent Nothing  _ = Refl
    absent (Just _) p = absurd p
    present : lnul_8_4__resolve segs j = Just JNull ->
              ( lexp_6_1__has segs (RVal (VJson j)) = RVal (VBool True)
              , lnul_8_4__path segs (RVal (VJson j)) = RVal VNull )
    present prf = (cong (\m => RVal (VBool (isJust m))) prf, cong (\m => RVal (lnul_8_4__read m)) prf)

--@derives [LNUL.8.4]
||| THE READING THIS MODULE TAKES of "resolves" (the header's residue): a
||| segment into a value that is not the container it addresses leaves the
||| path unresolved -- a key into a scalar leaf or an array, an index into
||| a leaf or an object -- for every key, index, remaining path and value.
public export
lnul_8_4__a_segment_into_a_leaf_is_absent :
  (k, i : Nat) -> (ss : List Lgra_5_8_5__seg) -> (n : Integer) -> (t : Lstr_1_1__text) ->
  (xs : List Lgra_5_8_1__json) -> (ms : List (Nat, Lgra_5_8_1__json)) ->
  ( lnul_8_4__resolve (SKey k :: ss) (JInt n) = Nothing
  , lnul_8_4__resolve (SKey k :: ss) (JArr xs) = Nothing
  , lnul_8_4__resolve (SIndex i :: ss) (JStr t) = Nothing
  , lnul_8_4__resolve (SIndex i :: ss) (JObj ms) = Nothing )
lnul_8_4__a_segment_into_a_leaf_is_absent _ _ _ _ _ _ _ = (Refl, Refl, Refl, Refl)

--@derives [LEXP.7.12.1]
||| A CONTAINER UNDER AN OPERATOR IS A TYPEERROR: an array or an object a
||| path reads, in arithmetic with an Int on either side, or ordered
||| against one, is a trap and never a value -- "no operation yields a
||| sentinel that takes part in further computation as though it were
||| data". For every arithmetic operator, every object, every array and
||| every Int.
public export
lexp_7_12_1__container_under_an_operator_traps :
  (op : Lexp_7_2__arith) -> (ms : List (Nat, Lgra_5_8_1__json)) -> (xs : List Lgra_5_8_1__json) -> (n : Integer) ->
  ( lnul_4_1__arith op (VJson (JObj ms)) (VInt n) = RTrap
  , lnul_4_1__arith op (VInt n) (VJson (JArr xs)) = RTrap
  , lnul_4_1__cmp OpLt (VJson (JObj ms)) (VInt n) = RTrap
  , lnul_4_1__cmp OpGt (VInt n) (VJson (JArr xs)) = RTrap )
lexp_7_12_1__container_under_an_operator_traps _ _ _ _ = (Refl, Refl, Refl, Refl)

--@derives [LEXP.6.2]
--@derives [LEXP.6.1]
||| `len` COUNTS AN ARRAY'S ELEMENTS AND NOTHING ELSE: an Int for every
||| array; a trap for every object, every scalar leaf, and `null` -- what
||| an unresolved path reads as, "not an array either".
public export
lexp_6_2__len_is_an_arrays_alone :
  (xs : List Lgra_5_8_1__json) -> (ms : List (Nat, Lgra_5_8_1__json)) -> (n : Integer) -> (s : Lstr_1_1__text) ->
  ( lexp_6_1__len (RVal (VJson (JArr xs))) = RVal (VInt (cast (length xs)))
  , lexp_6_1__len (RVal (VJson (JObj ms))) = RTrap
  , lexp_6_1__len (RVal (VInt n)) = RTrap
  , lexp_6_1__len (RVal (VStr s)) = RTrap
  , lexp_6_1__len (RVal VNull) = RTrap )
lexp_6_2__len_is_an_arrays_alone _ _ _ _ = (Refl, Refl, Refl, Refl, Refl)

--@derives [LGRA.5.8.8]
||| THE FOLD LEAVES NO `-0.0`: a float zero of either sign becomes `+0.0`
||| and every nonzero float is itself, for every float; an integer `0`
||| stays an integer.
public export
lgra_5_8_8__fold_leaves_no_negative_zero :
  (x : Double) ->
  ( x == 0.0 = True -> lgra_5_8_8__unsigned_zeros (JFloat x) = JFloat 0.0
  , x == 0.0 = False -> lgra_5_8_8__unsigned_zeros (JFloat x) = JFloat x
  , lgra_5_8_8__unsigned_zeros (JInt 0) = JInt 0 )
lgra_5_8_8__fold_leaves_no_negative_zero x = (zero, nonzero, Refl)
  where
    zero : x == 0.0 = True -> lgra_5_8_8__unsigned_zeros (JFloat x) = JFloat 0.0
    zero prf = cong (\c => JFloat (lgra_5_8_8__fold_float c x)) prf
    nonzero : x == 0.0 = False -> lgra_5_8_8__unsigned_zeros (JFloat x) = JFloat x
    nonzero prf = cong (\c => JFloat (lgra_5_8_8__fold_float c x)) prf

--@derives [LFAC.2.5.1]
||| MEMBER ORDER CARRIES NO MEANING: two objects with the same members in
||| different orders are equal, executed.
public export
lfac_2_5_1__member_order_carries_no_meaning :
  lfac_2_5_1__json_eq (JObj [(1, JInt 1), (2, JBool True)]) (JObj [(2, JBool True), (1, JInt 1)]) = True
lfac_2_5_1__member_order_carries_no_meaning = Refl

--@derives [LFAC.2.5.1]
||| AN INTEGER AND A FLOAT ARE DIFFERENT KINDS: `1` is not `1.0` and `0` is
||| not `0.0`, at the root and under a key, executed.
public export
lfac_2_5_1__an_integer_is_not_a_float :
  ( lfac_2_5_1__json_eq (JInt 1) (JFloat 1.0) = False
  , lfac_2_5_1__json_eq (JObj [(1, JInt 0)]) (JObj [(1, JFloat 0.0)]) = False )
lfac_2_5_1__an_integer_is_not_a_float = (Refl, Refl)

--@derives [LFAC.2.5.1]
||| A MEMBER MORE DIFFERS, in either direction, and so does an array of
||| another length: "the same set of keys", "the same length", executed.
public export
lfac_2_5_1__a_member_more_differs :
  ( lfac_2_5_1__json_eq (JObj [(1, JInt 1)]) (JObj [(1, JInt 1), (2, JInt 2)]) = False
  , lfac_2_5_1__json_eq (JObj [(1, JInt 1), (2, JInt 2)]) (JObj [(1, JInt 1)]) = False
  , lfac_2_5_1__json_eq (JArr [JInt 1]) (JArr [JInt 1, JInt 1]) = False
  , lfac_2_5_1__json_eq (JArr [JInt 1, JInt 2]) (JArr [JInt 2, JInt 1]) = False )
lfac_2_5_1__a_member_more_differs = (Refl, Refl, Refl, Refl)

-- ---------------------------------------------------------------------
-- Strings: what the clauses claim, quantified over every text
-- ---------------------------------------------------------------------

--@derives [LSTR.3.2]
||| A codepoint compared with itself is `EQ`.
public export
lstr_3_2__cp_cmp_refl : (a : Nat) -> lstr_3_2__cp_cmp a a = EQ
lstr_3_2__cp_cmp_refl Z     = Refl
lstr_3_2__cp_cmp_refl (S a) = lstr_3_2__cp_cmp_refl a

--@derives [LSTR.3.1]
||| `EQ` is equality: two codepoints the comparison calls equal are one.
public export
lstr_3_1__cp_cmp_eq : (a, b : Nat) -> lstr_3_2__cp_cmp a b = EQ -> a = b
lstr_3_1__cp_cmp_eq Z     Z     _    = Refl
lstr_3_1__cp_cmp_eq Z     (S _) Refl impossible
lstr_3_1__cp_cmp_eq (S _) Z     Refl impossible
lstr_3_1__cp_cmp_eq (S a) (S b) p    = cong S (lstr_3_1__cp_cmp_eq a b p)

--@derives [LSTR.3.2]
||| `EQ` is symmetric.
public export
lstr_3_2__cp_cmp_sym_eq : (a, b : Nat) -> lstr_3_2__cp_cmp a b = EQ -> lstr_3_2__cp_cmp b a = EQ
lstr_3_2__cp_cmp_sym_eq Z     Z     _    = Refl
lstr_3_2__cp_cmp_sym_eq Z     (S _) Refl impossible
lstr_3_2__cp_cmp_sym_eq (S _) Z     Refl impossible
lstr_3_2__cp_cmp_sym_eq (S a) (S b) p    = lstr_3_2__cp_cmp_sym_eq a b p

--@derives [LSTR.3.2]
||| The comparison flips with its arguments: `LT` one way is `GT` the other.
public export
lstr_3_2__cp_cmp_flip : (a, b : Nat) -> lstr_3_2__cp_cmp a b = LT -> lstr_3_2__cp_cmp b a = GT
lstr_3_2__cp_cmp_flip Z     Z     Refl impossible
lstr_3_2__cp_cmp_flip Z     (S _) _    = Refl
lstr_3_2__cp_cmp_flip (S _) Z     Refl impossible
lstr_3_2__cp_cmp_flip (S a) (S b) p    = lstr_3_2__cp_cmp_flip a b p

--@derives [LSTR.3.2]
||| And `GT` one way is `LT` the other.
public export
lstr_3_2__cp_cmp_flip_gt : (a, b : Nat) -> lstr_3_2__cp_cmp a b = GT -> lstr_3_2__cp_cmp b a = LT
lstr_3_2__cp_cmp_flip_gt Z     Z     Refl impossible
lstr_3_2__cp_cmp_flip_gt Z     (S _) Refl impossible
lstr_3_2__cp_cmp_flip_gt (S _) Z     _    = Refl
lstr_3_2__cp_cmp_flip_gt (S a) (S b) p    = lstr_3_2__cp_cmp_flip_gt a b p

--@derives [LSTR.3.2]
||| `LT` is transitive on codepoints.
public export
lstr_3_2__cp_cmp_trans : (a, b, c : Nat) -> lstr_3_2__cp_cmp a b = LT -> lstr_3_2__cp_cmp b c = LT ->
                         lstr_3_2__cp_cmp a c = LT
lstr_3_2__cp_cmp_trans Z     Z     _     Refl _    impossible
lstr_3_2__cp_cmp_trans Z     (S _) Z     _    Refl impossible
lstr_3_2__cp_cmp_trans Z     (S _) (S _) _    _    = Refl
lstr_3_2__cp_cmp_trans (S _) Z     _     Refl _    impossible
lstr_3_2__cp_cmp_trans (S _) (S _) Z     _    Refl impossible
lstr_3_2__cp_cmp_trans (S a) (S b) (S c) p    q    = lstr_3_2__cp_cmp_trans a b c p q

--@derives [LSTR.3.1]
||| EQUALITY IS CODEPOINT BY CODEPOINT: two texts the test calls equal are
||| one text, for every pair.
public export
lstr_3_1__eq_sound : (a, b : Lstr_1_1__text) -> lstr_3_1__eq a b = True -> a = b
lstr_3_1__eq_sound []        []        _    = Refl
lstr_3_1__eq_sound []        (_ :: _)  Refl impossible
lstr_3_1__eq_sound (_ :: _)  []        Refl impossible
lstr_3_1__eq_sound (x :: xs) (y :: ys) p with (lstr_3_2__cp_cmp x y) proof pxy
  lstr_3_1__eq_sound (x :: xs) (y :: ys) p | EQ =
    rewrite lstr_3_1__cp_cmp_eq x y pxy in cong (y ::) (lstr_3_1__eq_sound xs ys p)
  lstr_3_1__eq_sound (x :: xs) (y :: ys) p | LT = absurd p
  lstr_3_1__eq_sound (x :: xs) (y :: ys) p | GT = absurd p

--@derives [LSTR.3.1]
||| And every text equals itself.
public export
lstr_3_1__eq_refl : (a : Lstr_1_1__text) -> lstr_3_1__eq a a = True
lstr_3_1__eq_refl []        = Refl
lstr_3_1__eq_refl (x :: xs) = rewrite lstr_3_2__cp_cmp_refl x in lstr_3_1__eq_refl xs

--@derives [LSTR.3.1]
||| NO NORMALISATION: the clause's example, executed -- `café` composed
||| (U+00E9) and decomposed (U+0065 U+0301) are not equal.
public export
lstr_3_1__nfc_is_not_nfd : lstr_3_1__eq [99, 97, 102, 233] [99, 97, 102, 101, 769] = False
lstr_3_1__nfc_is_not_nfd = Refl

--@derives [LSTR.3.2]
||| THE ORDER IS IRREFLEXIVE: no text is below itself.
public export
lstr_3_2__lt_irrefl : (a : Lstr_1_1__text) -> lstr_3_2__lt a a = False
lstr_3_2__lt_irrefl []        = Refl
lstr_3_2__lt_irrefl (x :: xs) = rewrite lstr_3_2__cp_cmp_refl x in lstr_3_2__lt_irrefl xs

--@derives [LSTR.3.2]
||| THE ORDER IS ASYMMETRIC: a text below another is not above it.
public export
lstr_3_2__lt_asym : (a, b : Lstr_1_1__text) -> lstr_3_2__lt a b = True -> lstr_3_2__lt b a = False
lstr_3_2__lt_asym []        []        Refl impossible
lstr_3_2__lt_asym []        (_ :: _)  _    = Refl
lstr_3_2__lt_asym (_ :: _)  []        Refl impossible
lstr_3_2__lt_asym (x :: xs) (y :: ys) p with (lstr_3_2__cp_cmp x y) proof pxy
  lstr_3_2__lt_asym (x :: xs) (y :: ys) p | LT = rewrite lstr_3_2__cp_cmp_flip x y pxy in Refl
  lstr_3_2__lt_asym (x :: xs) (y :: ys) p | GT = absurd p
  lstr_3_2__lt_asym (x :: xs) (y :: ys) p | EQ =
    rewrite lstr_3_2__cp_cmp_sym_eq x y pxy in lstr_3_2__lt_asym xs ys p

--@derives [LSTR.3.2]
||| THE ORDER IS TRANSITIVE.
public export
lstr_3_2__lt_trans : (a, b, c : Lstr_1_1__text) -> lstr_3_2__lt a b = True -> lstr_3_2__lt b c = True ->
                     lstr_3_2__lt a c = True
lstr_3_2__lt_trans []        _         (_ :: _)  _    _    = Refl
lstr_3_2__lt_trans []        []        []        Refl _    impossible
lstr_3_2__lt_trans []        (_ :: _)  []        _    Refl impossible
lstr_3_2__lt_trans (_ :: _)  []        _         Refl _    impossible
lstr_3_2__lt_trans (_ :: _)  (_ :: _)  []        _    Refl impossible
lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q with (lstr_3_2__cp_cmp x y) proof pxy
  lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | LT with (lstr_3_2__cp_cmp y z) proof pyz
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | LT | LT =
      rewrite lstr_3_2__cp_cmp_trans x y z pxy pyz in Refl
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | LT | EQ =
      rewrite sym (lstr_3_1__cp_cmp_eq y z pyz) in rewrite pxy in Refl
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | LT | GT = absurd q
  lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | EQ with (lstr_3_2__cp_cmp y z) proof pyz
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | EQ | LT =
      rewrite lstr_3_1__cp_cmp_eq x y pxy in rewrite pyz in Refl
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | EQ | EQ =
      rewrite lstr_3_1__cp_cmp_eq x y pxy in rewrite pyz in lstr_3_2__lt_trans xs ys zs p q
    lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | EQ | GT = absurd q
  lstr_3_2__lt_trans (x :: xs) (y :: ys) (z :: zs) p q | GT = absurd p

--@derives [LSTR.3.2]
--@derives [LSTR.3.1]
||| THE ORDER IS TOTAL ON DISTINCT TEXTS: two texts that are not equal are
||| ordered one way or the other.
public export
lstr_3_2__lt_total : (a, b : Lstr_1_1__text) -> lstr_3_1__eq a b = False ->
                     Either (lstr_3_2__lt a b = True) (lstr_3_2__lt b a = True)
lstr_3_2__lt_total []        []        Refl impossible
lstr_3_2__lt_total []        (_ :: _)  _    = Left Refl
lstr_3_2__lt_total (_ :: _)  []        _    = Right Refl
lstr_3_2__lt_total (x :: xs) (y :: ys) ne with (lstr_3_2__cp_cmp x y) proof pxy
  lstr_3_2__lt_total (x :: xs) (y :: ys) ne | LT = Left Refl
  lstr_3_2__lt_total (x :: xs) (y :: ys) ne | GT = Right (rewrite lstr_3_2__cp_cmp_flip_gt x y pxy in Refl)
  lstr_3_2__lt_total (x :: xs) (y :: ys) ne | EQ = case lstr_3_2__lt_total xs ys ne of
    Left p  => Left p
    Right p => Right (rewrite lstr_3_2__cp_cmp_sym_eq x y pxy in p)

--@derives [LSTR.3.2]
||| A PROPER PREFIX SORTS FIRST: `ab` is below `abc`, for every text, every
||| codepoint and every continuation.
public export
lstr_3_2__prefix_sorts_first : (xs : Lstr_1_1__text) -> (y : Nat) -> (ys : Lstr_1_1__text) ->
                               lstr_3_2__lt xs (xs ++ y :: ys) = True
lstr_3_2__prefix_sorts_first []        y ys = Refl
lstr_3_2__prefix_sorts_first (x :: xs) y ys =
  rewrite lstr_3_2__cp_cmp_refl x in lstr_3_2__prefix_sorts_first xs y ys

--@derives [LSTR.3.2]
||| THE FIXTURES' CLAIMS, executed on their texts: `a` is above `Z`
||| (codepoint order, not alphabetical: LSTR.3.2_codepoint_not_alphabetical)
||| and `Y` is not; `é` is above `z` (a non-ASCII codepoint by its value,
||| LSTR.3.2_non_ascii_above_ascii); `ab` is below `abc` while `abc` and
||| `abd` are not (LSTR.3.2_prefix_sorts_first); `Z` is above `M` and `A` is
||| not (LSTR.3.2_ordering_fires). The astral case, a codepoint above the
||| BMP, is run in Main.idr.
public export
lstr_3_2__fixture_claims :
  ( lstr_3_2__lt [90] [97] = True, lstr_3_2__lt [90] [89] = False
  , lstr_3_2__lt [122] [233] = True
  , lstr_3_2__lt [97, 98] [97, 98, 99] = True, lstr_3_2__lt [97, 98, 99] [97, 98, 99] = False
  , lstr_3_2__lt [97, 98, 100] [97, 98, 99] = False
  , lstr_3_2__lt [77] [90] = True, lstr_3_2__lt [77] [65] = False )
lstr_3_2__fixture_claims = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LSTR.2.1]
||| `len` COUNTS CODEPOINTS: the clause's examples, executed -- `café` (four
||| codepoints, five UTF-8 bytes) is 4 and the waving hand with a skin tone
||| (two codepoints, one grapheme cluster, four UTF-16 code units) is 2.
public export
lstr_2_1__len_counts_codepoints :
  ( lstr_2_1__len [99, 97, 102, 233] = 4, lstr_2_1__len [128075, 127997] = 2 )
lstr_2_1__len_counts_codepoints = (Refl, Refl)

--@derives [LSTR.2.1]
--@derives [IRET.9.6]
||| `len` OF A String IS AN Int FOR EVERY TEXT, and of `null` a trap: the
||| receiver is a concrete-value position, and a `null` reaching it is
||| [IRET.9.6]'s first arm.
public export
lstr_2_1__len_is_total_on_texts :
  (t : Lstr_1_1__text) ->
  ( lstr_2_1__len_of (RVal (VStr t)) = RVal (VInt (lstr_2_1__len t))
  , lstr_2_1__len_of (RVal VNull) = RTrap )
lstr_2_1__len_is_total_on_texts _ = (Refl, Refl)

--@derives [LCST.4.5.7]
--@derives [LNUL.8.4]
--@derives [LERR.1.3.1]
||| A FALLIBLE PARSE NEVER FAULTS: for every text, `s :: Int?` is an Int or
||| `null`, the clause's two answers, and never a trap -- a text the parse
||| does not accept is absence, [LERR.1.3.1]'s third case, which the Kleene
||| stack and `??` handle.
public export
lcst_4_5_7__parse_is_a_value_or_null :
  (t : Lstr_1_1__text) ->
  Either (n : Integer ** lcst_4_2__cast True TInt (RVal (VStr t)) = RVal (VInt n))
         (lcst_4_2__cast True TInt (RVal (VStr t)) = RVal VNull)
lcst_4_5_7__parse_is_a_value_or_null t with (lcst_4_5_7__parse_int t)
  lcst_4_5_7__parse_is_a_value_or_null t | Just n  = Left (n ** Refl)
  lcst_4_5_7__parse_is_a_value_or_null t | Nothing = Right Refl

--@derives [LCST.4.5.5]
--@derives [LNUL.8.4]
--@derives [LERR.1.3.1]
||| And `s :: Bool?` is a Bool or `null` for every text, never a trap.
public export
lcst_4_5_5__parse_is_a_value_or_null :
  (t : Lstr_1_1__text) ->
  Either (b : Bool ** lcst_4_2__cast True TBool (RVal (VStr t)) = RVal (VBool b))
         (lcst_4_2__cast True TBool (RVal (VStr t)) = RVal VNull)
lcst_4_5_5__parse_is_a_value_or_null t with (lcst_4_5_5__parse_bool t)
  lcst_4_5_5__parse_is_a_value_or_null t | Just b  = Left (b ** Refl)
  lcst_4_5_5__parse_is_a_value_or_null t | Nothing = Right Refl

--@derives [LCST.4.5.6]
--@derives [LCST.4.5.5]
||| THE Bool RENDER IS THE PARSE'S INVERSE: `true` and `false` round-trip.
public export
lcst_4_5_6__bool_round_trip : (b : Bool) -> lcst_4_5_5__parse_bool (lcst_4_5_6__render_bool b) = Just b
lcst_4_5_6__bool_round_trip True  = Refl
lcst_4_5_6__bool_round_trip False = Refl

--@derives [LCST.4.5.7]
||| A LEADING SPACE IS NULL for every tail, and so is the empty text: a
||| space is neither a sign nor a digit, and nothing follows an empty
||| text.
public export
lcst_4_5_7__leading_space_and_empty_are_null :
  (t : Lstr_1_1__text) -> ( lcst_4_5_7__parse_int (32 :: t) = Nothing, lcst_4_5_7__parse_int [] = Nothing )
lcst_4_5_7__leading_space_and_empty_are_null _ = (Refl, Refl)

--@derives [LCST.4.5.7]
--@derives [LLEX.11.1]
||| THE ACCEPTED SPELLINGS, executed: LCST.4.5.7_int_formats_parse's eight
||| texts, each to 31 or -31 -- `31`, `3_1`, `0x1F`, `0x1f`, `0b1_1111`,
||| `0o37`, `+31`, `-0x1F`.
public export
lcst_4_5_7__accepted_spellings :
  ( lcst_4_5_7__parse_int [51, 49] = Just 31
  , lcst_4_5_7__parse_int [51, 95, 49] = Just 31
  , lcst_4_5_7__parse_int [48, 120, 49, 70] = Just 31
  , lcst_4_5_7__parse_int [48, 120, 49, 102] = Just 31
  , lcst_4_5_7__parse_int [48, 98, 49, 95, 49, 49, 49, 49] = Just 31
  , lcst_4_5_7__parse_int [48, 111, 51, 55] = Just 31
  , lcst_4_5_7__parse_int [43, 51, 49] = Just 31
  , lcst_4_5_7__parse_int [45, 48, 120, 49, 70] = Just (-31) )
lcst_4_5_7__accepted_spellings = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LCST.4.5.7]
--@derives [LLEX.11.1]
--@derives [LLEX.12.1]
||| THE REFUSED SPELLINGS, executed: LCST.4.5.7_int_non_literals_are_null's
||| texts that the arithmetic reduces at elaboration -- `31.0`, `3e1`,
||| `31 `, `31_s`, `31s`, `0x_1F`, `_31`, `31_` (the trailing separator,
||| [LLEX.12.1]'s rule), `0X1F`, `0x1G`; the out-of-range magnitude is run
||| in Main.idr.
public export
lcst_4_5_7__refused_spellings :
  ( lcst_4_5_7__parse_int [51, 49, 46, 48] = Nothing
  , lcst_4_5_7__parse_int [51, 101, 49] = Nothing
  , lcst_4_5_7__parse_int [51, 49, 32] = Nothing
  , lcst_4_5_7__parse_int [51, 49, 95, 115] = Nothing
  , lcst_4_5_7__parse_int [51, 49, 115] = Nothing
  , lcst_4_5_7__parse_int [48, 120, 95, 49, 70] = Nothing
  , lcst_4_5_7__parse_int [95, 51, 49] = Nothing
  , lcst_4_5_7__parse_int [51, 49, 95] = Nothing
  , lcst_4_5_7__parse_int [48, 88, 49, 70] = Nothing
  , lcst_4_5_7__parse_int [48, 120, 49, 71] = Nothing )
lcst_4_5_7__refused_spellings = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LCST.4.3.1]
||| A FALLIBLE PAIR UNDER THE BARE `::T` IS REFUSED, for every text: the
||| compiler's "must be `::T?`", a trap here and never a value or `null`.
||| Under `::T?` the same pair is a value or `null`
||| (`lcst_4_5_7__parse_is_a_value_or_null`).
public export
lcst_4_3_1__total_form_refused :
  (t : Lstr_1_1__text) ->
  ( lcst_4_2__cast False TInt (RVal (VStr t)) = RTrap
  , lcst_4_2__cast False TBool (RVal (VStr t)) = RTrap
  , lcst_4_2__cast False TFloat (RVal (VStr t)) = RTrap )
lcst_4_3_1__total_form_refused _ = (Refl, Refl, Refl)

--@derives [LCST.4.5.8]
--@derives [LNUL.8.4]
--@derives [LERR.1.3.1]
||| And `s :: Float?` is a Float or `null` for every text, never a trap.
public export
lcst_4_5_8__parse_is_a_value_or_null :
  (t : Lstr_1_1__text) ->
  Either (x : Double ** lcst_4_2__cast True TFloat (RVal (VStr t)) = RVal (VFloat x))
         (lcst_4_2__cast True TFloat (RVal (VStr t)) = RVal VNull)
lcst_4_5_8__parse_is_a_value_or_null t with (lcst_4_5_8__parse_float t)
  lcst_4_5_8__parse_is_a_value_or_null t | Just x  = Left (x ** Refl)
  lcst_4_5_8__parse_is_a_value_or_null t | Nothing = Right Refl

--@derives [LLEX.11.2]
--@derives [LCST.4.5.8]
||| THE ACCEPTED FLOAT SPELLINGS of LCST.4.5.8_float_formats_parse, read to
||| their decimals: `1500.0`, `1.5e3`, `1.5E3`, `1.5e+03`, `15e2`,
||| `1_500.0`, each `1500` as `d * 10^x`; and `1e1_0`, the separator in an
||| exponent [LLEX.11.2]'s grammar admits (the header's residue). The
||| integer spellings `1500`, `1_500` and `0x5DC` are `INT_LIT`s and take
||| `llex_11_1__int_lit`'s path.
public export
llex_11_2__accepted_spellings :
  ( llex_11_2__float_lit [49, 53, 48, 48, 46, 48] = Just (15000, -1)
  , llex_11_2__float_lit [49, 46, 53, 101, 51] = Just (15, 2)
  , llex_11_2__float_lit [49, 46, 53, 69, 51] = Just (15, 2)
  , llex_11_2__float_lit [49, 46, 53, 101, 43, 48, 51] = Just (15, 2)
  , llex_11_2__float_lit [49, 53, 101, 50] = Just (15, 2)
  , llex_11_2__float_lit [49, 95, 53, 48, 48, 46, 48] = Just (15000, -1)
  , llex_11_2__float_lit [49, 101, 49, 95, 48] = Just (1, 10) )
llex_11_2__accepted_spellings = (Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LLEX.11.2]
--@derives [LLEX.11.2.1]
--@derives [LLEX.11.2.2]
--@derives [LLEX.11.1]
||| THE REFUSED FLOAT SPELLINGS, executed: `1.` and `.5` (one side of the
||| point, [LLEX.11.2.1]), `1500` (an `INT_LIT`, not a `FLOAT_LIT`,
||| [LLEX.11.2.2]), `1.5e` (an exponent with no digits), `1_.5` and `1._5`
||| (a separator beside the point, [LLEX.11.1]), `1.5e_1` (one beside
||| the marker), `0x1p3` (a hex float, [LLEX.11.2.3]), ` 1.5` (a space).
public export
llex_11_2__refused_spellings :
  ( llex_11_2__float_lit [49, 46] = Nothing
  , llex_11_2__float_lit [46, 53] = Nothing
  , llex_11_2__float_lit [49, 53, 48, 48] = Nothing
  , llex_11_2__float_lit [49, 46, 53, 101] = Nothing
  , llex_11_2__float_lit [49, 95, 46, 53] = Nothing
  , llex_11_2__float_lit [49, 46, 95, 53] = Nothing
  , llex_11_2__float_lit [49, 46, 53, 101, 95, 49] = Nothing
  , llex_11_2__float_lit [48, 120, 49, 112, 51] = Nothing
  , llex_11_2__float_lit [32, 49, 46, 53] = Nothing )
llex_11_2__refused_spellings = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LCST.4.5.8]
--@derives [LLEX.11.1.5]
||| THE NULL SPELLINGS of LCST.4.5.8_float_non_literals_are_null, executed
||| as far as the arithmetic reduces -- every one is decided before a
||| double is built: `nan`, `NaN`, `infinity`, `INF`, ` 1.5`, `1.5 `,
||| `1500_s`, `1500s`, `1.`, `.5`, `1.5e`, `0x1p3`, `1e400` (past the
||| largest double, by its digit count), `1_.5`, the empty text; and an
||| integer spelling outside the 64-bit range, `99999999999999999999`
||| ([LLEX.11.1.5]).
public export
lcst_4_5_8__null_spellings :
  ( lcst_4_5_8__parse_float [110, 97, 110] = Nothing
  , lcst_4_5_8__parse_float [78, 97, 78] = Nothing
  , lcst_4_5_8__parse_float [105, 110, 102, 105, 110, 105, 116, 121] = Nothing
  , lcst_4_5_8__parse_float [73, 78, 70] = Nothing
  , lcst_4_5_8__parse_float [32, 49, 46, 53] = Nothing
  , lcst_4_5_8__parse_float [49, 46, 53, 32] = Nothing
  , lcst_4_5_8__parse_float [49, 53, 48, 48, 95, 115] = Nothing
  , lcst_4_5_8__parse_float [49, 53, 48, 48, 115] = Nothing
  , lcst_4_5_8__parse_float [49, 46] = Nothing
  , lcst_4_5_8__parse_float [46, 53] = Nothing
  , lcst_4_5_8__parse_float [49, 46, 53, 101] = Nothing
  , lcst_4_5_8__parse_float [48, 120, 49, 112, 51] = Nothing
  , lcst_4_5_8__parse_float [49, 101, 52, 48, 48] = Nothing
  , lcst_4_5_8__parse_float [49, 95, 46, 53] = Nothing
  , lcst_4_5_8__parse_float [] = Nothing
  , lcst_4_5_8__parse_float [57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57] = Nothing )
lcst_4_5_8__null_spellings = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LDET.3.2.7]
||| THE SHAPE'S ROWS, executed on literal digits: `42.0` (a whole value
||| keeps its `.0`), `0.30000000000000004` and `3.141592653589793` (the
||| fixtures' seventeen and sixteen digits), `0.0001` (the last fixed
||| exponent below one), `1e-05` (the first scientific), `9999999999999998.0`
||| (the last fixed above), `1e+16` and `1.5e+16` (the first scientific),
||| `-2.5e-07`, `5e-324` and `1.7976931348623157e+308` (the extremes),
||| `123456789.0`.
public export
ldet_3_2_7__shape_rows :
  ( ldet_3_2_7__shape False 42 0 = [52, 50, 46, 48]
  , ldet_3_2_7__shape False 30000000000000004 (-17) = [48, 46, 51, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 52]
  , ldet_3_2_7__shape False 3141592653589793 (-15) = [51, 46, 49, 52, 49, 53, 57, 50, 54, 53, 51, 53, 56, 57, 55, 57, 51]
  , ldet_3_2_7__shape False 1 (-4) = [48, 46, 48, 48, 48, 49]
  , ldet_3_2_7__shape False 1 (-5) = [49, 101, 45, 48, 53]
  , ldet_3_2_7__shape False 9999999999999998 0 = [57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56, 46, 48]
  , ldet_3_2_7__shape False 1 16 = [49, 101, 43, 49, 54]
  , ldet_3_2_7__shape False 15 15 = [49, 46, 53, 101, 43, 49, 54]
  , ldet_3_2_7__shape True 25 (-8) = [45, 50, 46, 53, 101, 45, 48, 55]
  , ldet_3_2_7__shape False 5 (-324) = [53, 101, 45, 51, 50, 52]
  , ldet_3_2_7__shape False 17976931348623157 292 = [49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 43, 51, 48, 56]
  , ldet_3_2_7__shape False 123456789 0 = [49, 50, 51, 52, 53, 54, 55, 56, 57, 46, 48] )
ldet_3_2_7__shape_rows = (Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LDET.3.2.7]
||| `Just` is injective. Stated here because base 0.8.0 has no
||| `Injective Just` and this module imports no module that states it (the
||| accepted duplicate of `lcyc_1_1__just_injective`).
public export
ldet_3_2_7__just_inj : {a : Type} -> {x, y : a} -> Just x = Just y -> x = y
ldet_3_2_7__just_inj Refl = Refl

--@derives [LDET.3.2.7]
||| The right half of a true conjunction is true.
public export
ldet_3_2_7__and_right : (a, b : Bool) -> (a && b) = True -> b = True
ldet_3_2_7__and_right True  b prf = prf
ldet_3_2_7__and_right False b prf = absurd prf

--@derives [LDET.3.2.7]
--@derives [LDET.3.2.8]
||| WHAT THE CHOICE ADMITS: a chosen candidate is `lo`, with `lo` parsing
||| back, or `lo + 1`, with `lo + 1` parsing back, at the power it was
||| offered at -- whatever the nearness and parity flags say. Read off
||| `ldet_3_2_7__choose`'s seven clauses.
public export
ldet_3_2_7__chosen_was_admitted :
  (lo, p, q, p' : Integer) -> (loOk, hiOk, a, b, c : Bool) ->
  ldet_3_2_7__choose lo p loOk hiOk a b c = Just (q, p') ->
  (p' = p, Either (q = lo, loOk = True) (q = lo + 1, hiOk = True))
ldet_3_2_7__chosen_was_admitted lo p q p' True True True _ _ prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Left (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' True True False True _ prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Right (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' True True False False True prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Left (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' True True False False False prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Right (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' True False _ _ _ prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Left (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' False True _ _ _ prf =
  let eq = ldet_3_2_7__just_inj prf in (sym (cong snd eq), Right (sym (cong fst eq), Refl))
ldet_3_2_7__chosen_was_admitted lo p q p' False False _ _ _ prf = absurd prf

--@derives [LDET.3.2.7]
--@derives [LDET.3.2.8]
||| WHAT THE CHOICE OVER A TEST ADMITS: a candidate it returns passed the
||| test, whatever the test is -- `lo` with `rt lo p` true, or `lo + 1`
||| with `rt (lo + 1) p` true, read off `ldet_3_2_7__chosen_was_admitted`.
||| Stated over the abstract test so that nothing here unfolds the parse.
public export
ldet_3_2_7__candidates_by_admit :
  (rt : Integer -> Integer -> Bool) -> (lo, p, r, den, q, p' : Integer) ->
  ldet_3_2_7__candidates_by rt lo p r den = Just (q, p') ->
  rt q p' = True
ldet_3_2_7__candidates_by_admit rt lo p r den q p' prf =
  case ldet_3_2_7__chosen_was_admitted lo p q p' (rt lo p) (r /= 0 && rt (lo + 1) p)
         (r < den - r) (den - r < r) (lo `mod` 2 == 0) prf of
    (pEq, Left (qEq, okEq))  => rewrite pEq in rewrite qEq in okEq
    (pEq, Right (qEq, okEq)) => rewrite pEq in rewrite qEq in
                                  ldet_3_2_7__and_right (r /= 0) (rt (lo + 1) p) okEq

--@derives [LDET.3.2.7]
--@derives [LDET.3.2.8]
||| A candidate the search returns at one length parses back: the choice
||| admitted it only with its own test true -- `ldet_3_2_7__candidates_by_admit`
||| at the parse's test, the candidates being that choice by definition.
public export
ldet_3_2_7__candidate_round_trips :
  (fuel, len : Nat) -> (m, e, n, md, x, q, p' : Integer) ->
  ldet_3_2_7__candidates fuel len m e n md x = Just (q, p') ->
  ldet_3_2_7__round_trips fuel m e q p' = True
ldet_3_2_7__candidate_round_trips fuel len m e n md x q p' prf =
  ldet_3_2_7__candidates_by_admit (ldet_3_2_7__round_trips fuel m e) _ _ _ _ q p' prf

--@derives [LDET.3.2.7]
||| WHAT A STEP THAT ANSWERS RESTS ON: the candidates at its length were the
||| answer, or there were none and the rest of the search was. Over
||| variables; the step's two clauses, read back.
public export
ldet_3_2_7__step_just :
  (c : Maybe (Integer, Integer)) -> (k : () -> Maybe (Integer, Integer)) -> (v : (Integer, Integer)) ->
  ldet_3_2_7__shortest_step c k = Just v ->
  Either (c = Just v) (c = Nothing, k () = Just v)
ldet_3_2_7__step_just (Just c') k v prf = Left prf
ldet_3_2_7__step_just Nothing   k v prf = Right (Refl, prf)

--@derives [LDET.3.2.7]
--@derives [LDET.3.2.8]
||| THE ROUND TRIP, BY CONSTRUCTION: whatever the search returns, at any
||| length and from any starting length, parses back to the value it was
||| searched for -- the digits were admitted by the parse's own test and
||| by nothing else. A theorem of the search's shape, over every value;
||| what it rests on, the test, is run. By induction on the lengths left,
||| each step taken apart by `ldet_3_2_7__step_just`.
public export
ldet_3_2_7__found_round_trips :
  (fuel, len, left : Nat) -> (m, e, n, md, x, q, p' : Integer) ->
  ldet_3_2_7__shortest_from fuel len left m e n md x = Just (q, p') ->
  ldet_3_2_7__round_trips fuel m e q p' = True
ldet_3_2_7__found_round_trips fuel len Z m e n md x q p' prf = absurd prf
ldet_3_2_7__found_round_trips fuel len (S left) m e n md x q p' prf =
  case ldet_3_2_7__step_just (ldet_3_2_7__candidates fuel len m e n md x)
         (\_ => ldet_3_2_7__shortest_from fuel (S len) left m e n md x) (q, p') prf of
    Left cEq       => ldet_3_2_7__candidate_round_trips fuel len m e n md x q p' cEq
    Right (_, dEq) => ldet_3_2_7__found_round_trips fuel (S len) left m e n md x q p' dEq

-- ---------------------------------------------------------------------
-- Expressions over a token and a candidate
-- ---------------------------------------------------------------------

--@spec [LTIM.2.4.1]
--@spec [LEXP.9.5.1]
||| A CLOCK READ in a `where`: `now()`, the wall clock; `monotonic_ns()`,
||| the monotonic clock; `t.dwell`, the monotonic clock less the entry stamp
||| of the `b`-th fact of the extended token ([LEXP.9.5.1]). The leaf that
||| makes a condition time-dependent ([LTIM.2.4.1]'s first kind; a series
||| read and a zone read are outside the fragment). The leaf carries no
||| value: Rete/NetworkTimed.idr substitutes each by its literal under the
||| pump's sample and the stamp table before this evaluator runs, so the
||| evaluator here reads no clock ([LTIM.2.8.4]).
public export
data Ltim_2_4_1__read : Type where
  ReadNow   : Ltim_2_4_1__read
  ReadMono  : Ltim_2_4_1__read
  ReadDwell : (binding : Nat) -> Ltim_2_4_1__read

--@spec [IRET.7.5]
||| A join test's expression. `ESlot b k s` reads slot `s` of the key tuple
||| (`k`) or payload tuple of the `b`-th fact of the extended token, the
||| candidate last. `EClock` is a clock read ([LTIM.2.4.1]), substituted
||| away before evaluation (Rete/NetworkTimed.idr); left in place it is a
||| trap, as a slot the environment cannot read is: this evaluator has no
||| clock to read, and a leaf that reaches it is a lowering defect.
public export
data Iret_7_5__expr : Type where
  ELit       : Lnul_2_1__value -> Iret_7_5__expr
  ESlot      : (binding : Nat) -> (isKey : Bool) -> (slot : Nat) -> Iret_7_5__expr
  EClock     : Ltim_2_4_1__read -> Iret_7_5__expr
  ECmp       : Iret_7_5__cmp -> Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr
  EArith     : Lexp_7_2__arith -> Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr
  ENeg       : Iret_7_5__expr -> Iret_7_5__expr
  EAnd       : Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr
  EOr        : Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr
  ENot       : Iret_7_5__expr -> Iret_7_5__expr
  EIs        : (negated : Bool) -> Lnul_4_9__subject -> Iret_7_5__expr -> Iret_7_5__expr
  ECoalesce  : Iret_7_5__expr -> Iret_7_5__expr -> Iret_7_5__expr
  ECast      : (fallible : Bool) -> Lcst_4_1_6__target -> Iret_7_5__expr -> Iret_7_5__expr
  EPath      : List Lgra_5_8_5__seg -> Iret_7_5__expr -> Iret_7_5__expr
  EHas       : List Lgra_5_8_5__seg -> Iret_7_5__expr -> Iret_7_5__expr
  ELen       : Iret_7_5__expr -> Iret_7_5__expr
  ELenStr    : Iret_7_5__expr -> Iret_7_5__expr

--@spec [IRET.7.6]
||| What an id stands for: the slot tuple a fact's `fkey` or `fpay` encodes,
||| or nothing. The model is quantified over this function. The fixture runner
||| supplies the decoder of the lowering's value code (Fixture.idr), under
||| which one tuple has one id and one id names one tuple, so the engine's
||| comparison of ids -- [LFAC.2.5.1]'s exact equality -- is a comparison of
||| the slot values.
public export
Iret_7_6__env : Type
Iret_7_6__env = Nat -> Maybe (List Lnul_2_1__value)

--@spec [IRET.7.6]
||| Read a slot of a fact of the extended token. A missing fact, an id the
||| environment does not decode, or a missing slot is a lowering defect and
||| reads as a trap (the header's residue).
public export
iret_7_6__slot : Iret_7_6__env -> List Lfac_1_7_1__fact -> Nat -> Bool -> Nat -> Lerr_1_4_1__result
iret_7_6__slot env fs b isKey s =
  case rarc_5_6_5__nth b fs of
    Nothing => RTrap
    Just f  =>
      case env (if isKey then fkey f else fpay f) of
        Nothing => RTrap
        Just vs =>
          case rarc_5_6_5__nth s vs of
            Nothing => RTrap
            Just v  => RVal v

--@spec [IRET.7.6]
||| A binary operator over two evaluated operands, left first: a trap in
||| the left is raised before the right is looked at.
public export
iret_7_6__strict2 : (Lnul_2_1__value -> Lnul_2_1__value -> Lerr_1_4_1__result) ->
                    Lerr_1_4_1__result -> Lerr_1_4_1__result -> Lerr_1_4_1__result
iret_7_6__strict2 f RTrap    _        = RTrap
iret_7_6__strict2 f (RVal _) RTrap    = RTrap
iret_7_6__strict2 f (RVal a) (RVal b) = f a b

--@spec [IRET.7.6]
||| A unary operator over an evaluated operand.
public export
iret_7_6__strict1 : (Lnul_2_1__value -> Lerr_1_4_1__result) -> Lerr_1_4_1__result -> Lerr_1_4_1__result
iret_7_6__strict1 f RTrap    = RTrap
iret_7_6__strict1 f (RVal a) = f a

--@spec [IRET.7.6]
||| Evaluate an expression against the extended token.
public export
iret_7_6__eval : Iret_7_6__env -> List Lfac_1_7_1__fact -> Iret_7_5__expr -> Lerr_1_4_1__result
iret_7_6__eval env fs (ELit v)        = RVal v
iret_7_6__eval env fs (ESlot b k s)   = iret_7_6__slot env fs b k s
iret_7_6__eval env fs (EClock _)      = RTrap
iret_7_6__eval env fs (ECmp op l r)   =
  iret_7_6__strict2 (lnul_4_1__cmp op) (iret_7_6__eval env fs l) (iret_7_6__eval env fs r)
iret_7_6__eval env fs (EArith op l r) =
  iret_7_6__strict2 (lnul_4_1__arith op) (iret_7_6__eval env fs l) (iret_7_6__eval env fs r)
iret_7_6__eval env fs (ENeg e)        =
  iret_7_6__strict1 lexp_7_2__negate (iret_7_6__eval env fs e)
iret_7_6__eval env fs (EAnd l r)      =
  lnul_4_2__result_of (lnul_4_2__and (lnul_4_2__answer_of (iret_7_6__eval env fs l))
                                     (lnul_4_2__answer_of (iret_7_6__eval env fs r)))
iret_7_6__eval env fs (EOr l r)       =
  lnul_4_2__result_of (lnul_4_2__or (lnul_4_2__answer_of (iret_7_6__eval env fs l))
                                    (lnul_4_2__answer_of (iret_7_6__eval env fs r)))
iret_7_6__eval env fs (ENot e)        =
  lnul_4_2__result_of (lnul_4_2__not (lnul_4_2__answer_of (iret_7_6__eval env fs e)))
iret_7_6__eval env fs (EIs neg s e)   = lnul_4_9__is neg s (iret_7_6__eval env fs e)
iret_7_6__eval env fs (ECoalesce x d) =
  lnul_5_3__coalesce (iret_7_6__eval env fs x) (\_ => iret_7_6__eval env fs d)
iret_7_6__eval env fs (ECast f t e)   = lcst_4_2__cast f t (iret_7_6__eval env fs e)
iret_7_6__eval env fs (EPath segs e)  = lnul_8_4__path segs (iret_7_6__eval env fs e)
iret_7_6__eval env fs (EHas segs e)   = lexp_6_1__has segs (iret_7_6__eval env fs e)
iret_7_6__eval env fs (ELen e)        = lexp_6_1__len (iret_7_6__eval env fs e)
iret_7_6__eval env fs (ELenStr e)     = lstr_2_1__len_of (iret_7_6__eval env fs e)

--@spec [IRET.7.6]
||| The answer a test gives the extended token.
public export
iret_7_6__answer : Iret_7_6__env -> List Lfac_1_7_1__fact -> Iret_7_5__expr -> Lnul_4_2__answer
iret_7_6__answer env fs e = lnul_4_2__answer_of (iret_7_6__eval env fs e)

--@spec [IRET.7.6]
--@spec [LNUL.4.3]
||| A positive node's join relation: the token plus the candidate, last,
||| admitted iff the test answers `true`.
public export
iret_7_6__admits_join : Iret_7_6__env -> Iret_7_5__expr ->
                        List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool
iret_7_6__admits_join env e tok f = lnul_4_3__admits (iret_7_6__answer env (tok ++ [f]) e)

--@spec [IRET.7.6]
--@spec [LNUL.4.7]
||| A `no` node's join relation: the candidate blocks the token unless the
||| test answers `false`.
public export
iret_7_6__blocks_join : Iret_7_6__env -> Iret_7_5__expr ->
                        List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool
iret_7_6__blocks_join env e tok f = lnul_4_7__blocks (iret_7_6__answer env (tok ++ [f]) e)

-- ---------------------------------------------------------------------
-- The clause's worked example, quantified
-- ---------------------------------------------------------------------

--@derives [LNUL.4.3]
--@derives [LNUL.4.1]
||| `[LNUL.4.5]`'s hot / cool pair over every operator and every other
||| operand: a comparison with a `null` operand fires neither positively
||| nor under `not`. "A missing value never causes a rule to fire."
public export
lnul_4_3__null_comparison_never_fires :
  (env : Iret_7_6__env) -> (fs : List Lfac_1_7_1__fact) ->
  (op : Iret_7_5__cmp) -> (v : Lnul_2_1__value) ->
  ( lnul_4_3__admits (iret_7_6__answer env fs (ECmp op (ELit VNull) (ELit v))) = False
  , lnul_4_3__admits (iret_7_6__answer env fs (ENot (ECmp op (ELit VNull) (ELit v)))) = False )
lnul_4_3__null_comparison_never_fires _ _ _ _ = (Refl, Refl)

--@derives [LNUL.4.7]
--@derives [LNUL.4.1]
||| And under `no`: a candidate whose comparison is `null` blocks.
public export
lnul_4_7__null_comparison_blocks :
  (env : Iret_7_6__env) -> (fs : List Lfac_1_7_1__fact) ->
  (op : Iret_7_5__cmp) -> (v : Lnul_2_1__value) ->
  lnul_4_7__blocks (iret_7_6__answer env fs (ECmp op (ELit VNull) (ELit v))) = True
lnul_4_7__null_comparison_blocks _ _ _ _ = Refl

--@derives [LNUL.4.10]
||| A `null` operand does not absorb a fault: a trap on either side of a
||| binary operator is the expression's answer whatever the other operand
||| is, `null` included -- [LNUL.4.1]'s propagation applies only when no
||| operand faults. (Which of two faults, by kind, is [LNUL.4.2]'s order and
||| Rete/WhereV5.idr's; the evaluator has one trap.)
public export
lnul_4_10__null_beside_a_trap_is_the_trap :
  (f : Lnul_2_1__value -> Lnul_2_1__value -> Lerr_1_4_1__result) -> (v : Lnul_2_1__value) ->
  ( iret_7_6__strict2 f RTrap (RVal v) = RTrap
  , iret_7_6__strict2 f (RVal v) RTrap = RTrap )
lnul_4_10__null_beside_a_trap_is_the_trap _ _ = (Refl, Refl)

--@derives [LNUL.4.4]
--@derives [LNUL.4.9]
||| The null test is total: on any value it answers `true` or `false`,
||| never `null`.
public export
lnul_4_4__is_null_is_total :
  (env : Iret_7_6__env) -> (fs : List Lfac_1_7_1__fact) -> (v : Lnul_2_1__value) ->
  Either (iret_7_6__answer env fs (EIs False IsNull (ELit v)) = KTrue)
         (iret_7_6__answer env fs (EIs False IsNull (ELit v)) = KFalse)
lnul_4_4__is_null_is_total _ _ VNull      = Left Refl
lnul_4_4__is_null_is_total _ _ (VInt _)   = Right Refl
lnul_4_4__is_null_is_total _ _ (VFloat _) = Right Refl
lnul_4_4__is_null_is_total _ _ (VStr _)   = Right Refl
lnul_4_4__is_null_is_total _ _ (VBool _)  = Right Refl
lnul_4_4__is_null_is_total _ _ (VJson _)  = Right Refl

--@derives [LNUL.4.9]
||| The tag test is total for every subject: on a value of any kind, `is`
||| and `is not` answer a Bool -- never `null`, never a trap -- the value's
||| tag read against the subject.
public export
lnul_4_9__is_total :
  (negated : Bool) -> (s : Lnul_4_9__subject) -> (v : Lnul_2_1__value) ->
  (b : Bool ** lnul_4_9__is negated s (RVal v) = RVal (VBool b))
lnul_4_9__is_total False s v = (lnul_4_9__tag_and_value s v ** Refl)
lnul_4_9__is_total True  s v = (not (lnul_4_9__tag_and_value s v) ** Refl)

--@derives [LNUL.4.10]
--@derives [LNUL.4.9]
||| An operand that faults is the answer, for every subject and either
||| polarity: a fault has no value whose tag could be read -- [LNUL.4.10]'s
||| rule for every operator but `and`, `or` and `??`.
public export
lnul_4_10__tag_test_of_a_trap_is_the_trap :
  (negated : Bool) -> (s : Lnul_4_9__subject) -> lnul_4_9__is negated s RTrap = RTrap
lnul_4_10__tag_test_of_a_trap_is_the_trap _ _ = Refl

--@derives [LNUL.4.9]
||| `false` in every other case, the `null` value included: a `null` answers
||| `true` to the `null` subject and `false` to each of the other eleven.
public export
lnul_4_9__null_answers_only_null :
  (s : Lnul_4_9__subject) -> Not (s = IsNull) -> lnul_4_9__tag_and_value s VNull = False
lnul_4_9__null_answers_only_null IsNull   nn = absurd (nn Refl)
lnul_4_9__null_answers_only_null IsTrue   _  = Refl
lnul_4_9__null_answers_only_null IsFalse  _  = Refl
lnul_4_9__null_answers_only_null IsInf    _  = Refl
lnul_4_9__null_answers_only_null IsNegInf _  = Refl
lnul_4_9__null_answers_only_null IsNaN    _  = Refl
lnul_4_9__null_answers_only_null IsInt    _  = Refl
lnul_4_9__null_answers_only_null IsFloat  _  = Refl
lnul_4_9__null_answers_only_null IsBool   _  = Refl
lnul_4_9__null_answers_only_null IsString _  = Refl
lnul_4_9__null_answers_only_null IsBytes  _  = Refl
lnul_4_9__null_answers_only_null IsJson   _  = Refl

--@derives [LNUL.4.9]
||| A tag name tests the tag alone, whatever the value: `is Float` is `true`
||| of every Float, the infinities and a NaN alike; `is Int` of every Int,
||| `is String` of every token, `is Bool` of `false` as of `true`, `is Json`
||| of every document.
public export
lnul_4_9__tag_name_tests_the_tag_alone :
  (x : Double) -> (n : Integer) -> (t : Lstr_1_1__text) -> (b : Bool) -> (j : Lgra_5_8_1__json) ->
  ( lnul_4_9__tag_and_value IsFloat (VFloat x) = True
  , lnul_4_9__tag_and_value IsInt (VInt n) = True
  , lnul_4_9__tag_and_value IsString (VStr t) = True
  , lnul_4_9__tag_and_value IsBool (VBool b) = True
  , lnul_4_9__tag_and_value IsJson (VJson j) = True )
lnul_4_9__tag_name_tests_the_tag_alone _ _ _ _ _ = (Refl, Refl, Refl, Refl, Refl)

--@derives [LNUL.4.9]
||| A constant tests tag AND value: `is true` is `false` of a Bool `false`
||| and `is false` `true` of it; and a constant of one tag is `false` of
||| every value of another, whatever that value -- `is true` of an Int,
||| `is inf` of a Bool, `is NaN` of an Int.
public export
lnul_4_9__constant_tests_the_value :
  (n : Integer) -> (b : Bool) ->
  ( lnul_4_9__tag_and_value IsTrue (VBool False) = False
  , lnul_4_9__tag_and_value IsTrue (VBool True) = True
  , lnul_4_9__tag_and_value IsFalse (VBool False) = True
  , lnul_4_9__tag_and_value IsFalse (VBool True) = False
  , lnul_4_9__tag_and_value IsTrue (VInt n) = False
  , lnul_4_9__tag_and_value IsInf (VBool b) = False
  , lnul_4_9__tag_and_value IsNaN (VInt n) = False )
lnul_4_9__constant_tests_the_value _ _ = (Refl, Refl, Refl, Refl, Refl, Refl, Refl)

--@derives [LNUL.8.9]
--@derives [LNUL.5.3]
||| The default is not looked at when `x` is present: for every value that
||| is not `null` and EVERY default, a trapping one included, `x ?? d` is
||| `x`. [LNUL.8.9]'s `x ?? y / z` with `x` present and `z` zero.
public export
lnul_8_9__default_not_looked_at :
  (v : Lnul_2_1__value) -> Not (v = VNull) -> (d : () -> Lerr_1_4_1__result) ->
  lnul_5_3__coalesce (RVal v) d = RVal v
lnul_8_9__default_not_looked_at VNull      nn _ = absurd (nn Refl)
lnul_8_9__default_not_looked_at (VInt _)   _  _ = Refl
lnul_8_9__default_not_looked_at (VFloat _) _  _ = Refl
lnul_8_9__default_not_looked_at (VStr _)   _  _ = Refl
lnul_8_9__default_not_looked_at (VBool _)  _  _ = Refl
lnul_8_9__default_not_looked_at (VJson _)  _  _ = Refl

--@derives [LNUL.5.3]
--@derives [LNUL.8.9]
||| A `null` takes the default, whatever it yields: its value, or its trap
||| -- `null ?? (1 // 0)` is the trap, dsexpr.k's `coalesce_null_trap`.
public export
lnul_5_3__null_takes_the_default :
  (d : () -> Lerr_1_4_1__result) -> lnul_5_3__coalesce (RVal VNull) d = d ()
lnul_5_3__null_takes_the_default _ = Refl

--@derives [LNUL.5.3]
||| A trap in `x` is the answer, for every default: no value, and nothing
||| to fall back from. `(null + 1 // 0) ?? 7` is the trap and not 7, the
||| fixture LNUL.4.10.null_beside_a_trap_is_not_a_null's reading, which no
||| clause states (the header).
public export
lnul_5_3__trap_has_no_fallback :
  (d : () -> Lerr_1_4_1__result) -> lnul_5_3__coalesce RTrap d = RTrap
lnul_5_3__trap_has_no_fallback _ = Refl

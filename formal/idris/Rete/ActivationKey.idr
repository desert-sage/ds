-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The activation key's identity (RLOW.4.6.2.1), and the two storages that
||| preserve it: the Mercury runtime's typed key, which is the identity
||| itself, and libds's byte frame, which is proved injective over it
||| ([IRET.25.5.3]).
|||
||| THE CLAUSE. "The activation key is the sequence of values [LCDB.3.3.3]
||| composes, and two keys are the same key only if they have the same
||| length and, position by position, values of the same representation
||| that are equal. `1`, `"1"` and `true` are three keys, not one. The
||| representation is the value's tag, not its declared type ([LNUL.4.9]),
||| so a `Time` and an `Int` holding the same count are one key. Equality
||| within a representation is the language's `==` for a scalar -- `0.0`
||| and `-0.0` are one key -- deep structural equality for `Json`
||| ([LFAC.2.5.1]), and `null` equals only `null`. The comparison is exact
||| and whole: nothing is rounded, truncated or compared by prefix, and a
||| key has no length limit of its own. How a runtime stores a key is its
||| own, provided the storage preserves this identity."
|||
||| THE RUNTIMES. libds keys typed and whole (`rk_walk`,
||| runtime/src/libds/rete/adapters.c) and so does the Mercury runtime
||| (`ds.rate.activation_key`, a `list(key_part)` compared as a term). The
||| clause fixes the key's IDENTITY and no encoding, so the model is of the
||| identity.
|||
||| WHAT IS MODELLED. A component is a value under its representation's
||| tag, in the canonical form that representation compares by: a Float by
||| the bits of its double with the two zeros one pattern
||| (`rlow_4_6_2_1__of_float`), a Time by its count as an Int
||| (`rlow_4_6_2_1__of_time`), a Json document by its canonical text, a
||| String or Bytes by its bytes, `null` by itself. Equality within a
||| representation is then structural equality of the part, which is how
||| both runtimes realise the clause's "equal": libds compares a Json by its
||| canonical serialization, the Mercury runtime as a term whose members are
||| sorted. The clause's identity is the relation `Rlow_4_6_2_1__same` --
||| the same length, position by position the same part -- and it is
||| structural equality of the key (`rlow_4_6_2_1__same_is_equality`), which
||| is what a Mercury `map` keyed on `rate_key` compares: that storage
||| preserves the identity by construction, and nothing is left to prove of
||| it.
|||
||| libds's storage is the byte string `rk_walk` feeds: the component count,
||| then per component a tag byte and either a fixed-width word or a word
||| giving the length and then the bytes. `rlow_4_6_2_1__encode` is that
||| frame over a word codec taken at its contract -- `bytes` and `unbytes`
||| with `unbytes (bytes n ++ rest) = Just (n, rest)`, which eight
||| little-endian bytes have for every value a uint64 holds -- and
||| `rlow_4_6_2_1__decode` inverts it (`rlow_4_6_2_1__decode_encode`), so
||| the frame is injective over the identity
||| (`rlow_4_6_2_1__encode_injective`): two keys that are not the same key
||| are two byte strings, whatever bytes their components hold and however
||| long they are. That is [IRET.25.5.3]'s "no separator a component can
||| contain, no truncation of a component or of the whole" as a theorem
||| rather than a rule, and the property the retired encoder lacked.
|||
||| NOT MODELLED. The word codec's bytes (a parameter, its round trip a
||| hypothesis of every theorem that reads a word); the values' canonical
||| forms, taken as given; a NaN, which reaches no slot ([LEXP.4.2]); a
||| value no representation carries -- libds's `RK_UNBOUND`, the Mercury
||| runtime's `kp_unexpanded` for a broken artefact -- since the clause
||| composes a key from values; and the composition of the key from the
||| bound facts, which is Lcdb/RuleGlobal.idr's ([LCDB.3.3.3]). The
||| decidable test `rlow_4_6_2_1__same_b` is run (Main.idr) and not proved
||| equal to the relation. Standalone, importing nothing of the lane, so it
||| carries two list lemmas of its own (`rlow_4_6_2_1__take_app`,
||| `rlow_4_6_2_1__drop_app`) and `Just`'s injectivity, as
||| Rete/Refcount.idr carries its Nat lemmas.
module Rete.ActivationKey

import Data.List
import Decidable.Equality

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The key and its identity
-- ---------------------------------------------------------------------

--@spec [RLOW.4.6.2.1]
||| ONE COMPONENT: a value under its representation's tag ([LNUL.4.9]), in
||| the canonical form that representation compares by. A `Nat` stands for
||| a 64-bit count -- an Int, a Float's bits, a fact id, a Ratio's terms --
||| and a `List Nat` for bytes: a String's, a Bytes value's, a Json
||| document's canonical text.
public export
data Rlow_4_6_2_1__part : Type where
  PNull  : Rlow_4_6_2_1__part
  PInt   : Nat -> Rlow_4_6_2_1__part
  PFloat : Nat -> Rlow_4_6_2_1__part
  PBool  : Bool -> Rlow_4_6_2_1__part
  PStr   : List Nat -> Rlow_4_6_2_1__part
  PBytes : List Nat -> Rlow_4_6_2_1__part
  PJson  : List Nat -> Rlow_4_6_2_1__part
  PFact  : Nat -> Rlow_4_6_2_1__part
  PRatio : Nat -> Nat -> Rlow_4_6_2_1__part

--@spec [RLOW.4.6.2.1]
||| THE KEY: the components in [LCDB.3.3.3]'s order.
public export
Rlow_4_6_2_1__key : Type
Rlow_4_6_2_1__key = List Rlow_4_6_2_1__part

--@spec [RLOW.4.6.2.1]
||| A Time keys as its count: "a `Time` and an `Int` holding the same count
||| are one key". The representation is the tag and a Time's tag is `Int`
||| ([LNUL.4.9]), so there is no constructor for a Time; this function is
||| the whole of the rule, and a Date or a Duration takes the same one.
public export
rlow_4_6_2_1__of_time : Nat -> Rlow_4_6_2_1__part
rlow_4_6_2_1__of_time n = PInt n

--@spec [RLOW.4.6.2.1]
||| A Float keys by the bits of its double, the negative zero's pattern read
||| as the positive zero's: "`0.0` and `-0.0` are one key", the one pair a
||| slot can hold that IEEE `==` identifies and bit equality does not.
||| `negZero` is the bit pattern of `-0.0`, a parameter so that the rule is
||| stated without a 64-bit literal. Both runtimes make this normalisation
||| as they key (`if (f == 0.0) f = 0.0`, rete/adapters.c; `key_part_of`,
||| ds.rate.m).
public export
rlow_4_6_2_1__of_float : (negZero : Nat) -> (bits : Nat) -> Rlow_4_6_2_1__part
rlow_4_6_2_1__of_float negZero bits with (decEq bits negZero)
  rlow_4_6_2_1__of_float negZero bits | Yes _ = PFloat 0
  rlow_4_6_2_1__of_float negZero bits | No _  = PFloat bits

--@spec [RLOW.4.6.2.1]
||| THE IDENTITY, as the clause words it: the same length, and position by
||| position a component of the same representation with an equal value --
||| here, the same canonical part.
public export
data Rlow_4_6_2_1__same : Rlow_4_6_2_1__key -> Rlow_4_6_2_1__key -> Type where
  SameNil  : Rlow_4_6_2_1__same [] []
  SameCons : (p : Rlow_4_6_2_1__part) -> (ps, qs : Rlow_4_6_2_1__key) ->
             Rlow_4_6_2_1__same ps qs -> Rlow_4_6_2_1__same (p :: ps) (p :: qs)

--@derives [RLOW.4.6.2.1]
||| THE IDENTITY IS EQUALITY OF THE KEY: two keys the clause calls the same
||| are one list of canonical parts, which is what a `map` keyed on the
||| Mercury runtime's `rate_key` compares (ds.rate.m).
public export
rlow_4_6_2_1__same_is_equality : (k1, k2 : Rlow_4_6_2_1__key) -> Rlow_4_6_2_1__same k1 k2 -> k1 = k2
rlow_4_6_2_1__same_is_equality _ _ SameNil = Refl
rlow_4_6_2_1__same_is_equality _ _ (SameCons p ps qs s) = cong (p ::) (rlow_4_6_2_1__same_is_equality ps qs s)

--@derives [RLOW.4.6.2.1]
||| And a key is the same key as itself, so the relation is exactly
||| equality.
public export
rlow_4_6_2_1__equal_is_same : (k : Rlow_4_6_2_1__key) -> Rlow_4_6_2_1__same k k
rlow_4_6_2_1__equal_is_same [] = SameNil
rlow_4_6_2_1__equal_is_same (p :: ps) = SameCons p ps ps (rlow_4_6_2_1__equal_is_same ps)

--@spec [RLOW.4.6.2.1]
||| ONE COMPONENT COMPARED: the same representation and an equal value under
||| it; two representations are two components whatever the values. The
||| test a runtime makes on lookup.
public export
rlow_4_6_2_1__same_part_b : Rlow_4_6_2_1__part -> Rlow_4_6_2_1__part -> Bool
rlow_4_6_2_1__same_part_b PNull        PNull        = True
rlow_4_6_2_1__same_part_b (PInt a)     (PInt b)     = a == b
rlow_4_6_2_1__same_part_b (PFloat a)   (PFloat b)   = a == b
rlow_4_6_2_1__same_part_b (PBool a)    (PBool b)    = a == b
rlow_4_6_2_1__same_part_b (PStr a)     (PStr b)     = a == b
rlow_4_6_2_1__same_part_b (PBytes a)   (PBytes b)   = a == b
rlow_4_6_2_1__same_part_b (PJson a)    (PJson b)    = a == b
rlow_4_6_2_1__same_part_b (PFact a)    (PFact b)    = a == b
rlow_4_6_2_1__same_part_b (PRatio a b) (PRatio c d) = a == c && b == d
rlow_4_6_2_1__same_part_b _            _            = False

--@spec [RLOW.4.6.2.1]
||| THE KEY COMPARED, exact and whole: the same length, then component by
||| component. The executable form of `Rlow_4_6_2_1__same`, run in Main.idr
||| and not proved equal to the relation.
public export
rlow_4_6_2_1__same_b : Rlow_4_6_2_1__key -> Rlow_4_6_2_1__key -> Bool
rlow_4_6_2_1__same_b []        []        = True
rlow_4_6_2_1__same_b (p :: ps) (q :: qs) = rlow_4_6_2_1__same_part_b p q && rlow_4_6_2_1__same_b ps qs
rlow_4_6_2_1__same_b _         _         = False

-- ---------------------------------------------------------------------
-- The clause's three examples
-- ---------------------------------------------------------------------

--@derives [RLOW.4.6.2.1]
||| THREE KEYS, NOT ONE: the integer 1 and the string "1" (its one byte,
||| 0x31) are components of two representations, so not the same key. By
||| the constructors; the retired encoder rendered both to the byte 0x31.
public export
rlow_4_6_2_1__int_is_not_the_string : Not (the Rlow_4_6_2_1__key [PInt 1] = [PStr [0x31]])
rlow_4_6_2_1__int_is_not_the_string Refl impossible

--@derives [RLOW.4.6.2.1]
||| The integer 1 and the boolean true, likewise.
public export
rlow_4_6_2_1__int_is_not_the_bool : Not (the Rlow_4_6_2_1__key [PInt 1] = [PBool True])
rlow_4_6_2_1__int_is_not_the_bool Refl impossible

--@derives [RLOW.4.6.2.1]
||| The string "1" and the boolean true, likewise: the third pair.
public export
rlow_4_6_2_1__string_is_not_the_bool : Not (the Rlow_4_6_2_1__key [PStr [0x31]] = [PBool True])
rlow_4_6_2_1__string_is_not_the_bool Refl impossible

--@derives [RLOW.4.6.2.1]
||| A TIME AND AN INT HOLDING THE SAME COUNT ARE ONE KEY, for every count:
||| a transcription of `rlow_4_6_2_1__of_time`, `Refl`, kept so the clause's
||| sentence has an element.
public export
rlow_4_6_2_1__time_keys_as_int : (n : Nat) -> rlow_4_6_2_1__of_time n = PInt n
rlow_4_6_2_1__time_keys_as_int n = Refl

--@derives [RLOW.4.6.2.1]
||| The negative zero's pattern keys as the zero, for every pattern that
||| stands for it.
public export
rlow_4_6_2_1__negative_zero_is_zero : (negZero : Nat) -> rlow_4_6_2_1__of_float negZero negZero = PFloat 0
rlow_4_6_2_1__negative_zero_is_zero negZero with (decEq negZero negZero)
  rlow_4_6_2_1__negative_zero_is_zero negZero | Yes _     = Refl
  rlow_4_6_2_1__negative_zero_is_zero negZero | No contra = absurd (contra Refl)

--@derives [RLOW.4.6.2.1]
||| And the zero keys as itself, whatever pattern stands for the negative
||| one: the normalisation touches nothing else.
public export
rlow_4_6_2_1__zero_is_zero : (negZero : Nat) -> rlow_4_6_2_1__of_float negZero 0 = PFloat 0
rlow_4_6_2_1__zero_is_zero negZero with (decEq 0 negZero)
  rlow_4_6_2_1__zero_is_zero negZero | Yes _ = Refl
  rlow_4_6_2_1__zero_is_zero negZero | No _  = Refl

--@derives [RLOW.4.6.2.1]
||| `0.0` AND `-0.0` ARE ONE KEY, for every pattern of the negative zero.
public export
rlow_4_6_2_1__zeros_one_key : (negZero : Nat) -> rlow_4_6_2_1__of_float negZero negZero = rlow_4_6_2_1__of_float negZero 0
rlow_4_6_2_1__zeros_one_key negZero =
  trans (rlow_4_6_2_1__negative_zero_is_zero negZero) (sym (rlow_4_6_2_1__zero_is_zero negZero))

-- ---------------------------------------------------------------------
-- libds's storage: the byte frame `rk_walk` feeds
-- ---------------------------------------------------------------------

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A WORD CODEC: how libds writes a 64-bit count into a key
||| (`rk_feed_u64`, eight little-endian bytes) and how a reader takes it
||| back. A parameter, taken at the contract below rather than modelled
||| byte by byte: the proofs use nothing else of it.
public export
record Rlow_4_6_2_1__word where
  constructor MkWord
  bytes   : Nat -> List Nat
  unbytes : List Nat -> Maybe (Nat, List Nat)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| THE CODEC'S CONTRACT: a word written in front of anything reads back as
||| that word and leaves the rest. Eight little-endian bytes have it for
||| every value a uint64 holds, which every count fed to a key is.
public export
Rlow_4_6_2_1__word_ok : Rlow_4_6_2_1__word -> Type
Rlow_4_6_2_1__word_ok w = (n : Nat) -> (rest : List Nat) -> unbytes w (bytes w n ++ rest) = Just (n, rest)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| ONE COMPONENT'S BYTES in front of what follows -- `rk_walk`'s arm for
||| its kind: a tag byte for the representation, then a word for a scalar,
||| or a word giving the length and then the bytes for a String, Bytes or
||| Json; a `null` is its tag alone; a Ratio two words. Written with the
||| rest appended so that a reader meets exactly what the writer wrote.
public export
rlow_4_6_2_1__field_to : Rlow_4_6_2_1__word -> Rlow_4_6_2_1__part -> List Nat -> List Nat
rlow_4_6_2_1__field_to w PNull        rest = 0 :: rest
rlow_4_6_2_1__field_to w (PInt n)     rest = 1 :: (bytes w n ++ rest)
rlow_4_6_2_1__field_to w (PFloat b)   rest = 2 :: (bytes w b ++ rest)
rlow_4_6_2_1__field_to w (PBool x)    rest = 3 :: (bytes w (if x then 1 else 0) ++ rest)
rlow_4_6_2_1__field_to w (PStr s)     rest = 4 :: (bytes w (length s) ++ (s ++ rest))
rlow_4_6_2_1__field_to w (PBytes s)   rest = 5 :: (bytes w (length s) ++ (s ++ rest))
rlow_4_6_2_1__field_to w (PJson s)    rest = 6 :: (bytes w (length s) ++ (s ++ rest))
rlow_4_6_2_1__field_to w (PFact i)    rest = 7 :: (bytes w i ++ rest)
rlow_4_6_2_1__field_to w (PRatio n d) rest = 8 :: (bytes w n ++ (bytes w d ++ rest))

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| THE COMPONENTS' BYTES, in the key's order, in front of what follows.
public export
rlow_4_6_2_1__fields_to : Rlow_4_6_2_1__word -> Rlow_4_6_2_1__key -> List Nat -> List Nat
rlow_4_6_2_1__fields_to w []        rest = rest
rlow_4_6_2_1__fields_to w (p :: ps) rest = rlow_4_6_2_1__field_to w p (rlow_4_6_2_1__fields_to w ps rest)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| THE KEY AS libds STORES IT: the component count, then the components.
||| `rk_walk` feeds these bytes to a sink that hashes, writes or compares
||| them; the bytes are the same whichever sink.
public export
rlow_4_6_2_1__encode : Rlow_4_6_2_1__word -> Rlow_4_6_2_1__key -> List Nat
rlow_4_6_2_1__encode w k = bytes w (length k) ++ rlow_4_6_2_1__fields_to w k []

-- ---------------------------------------------------------------------
-- A reader that inverts the writer
-- ---------------------------------------------------------------------

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A Bool's word read back: libds writes 1 or 0.
public export
rlow_4_6_2_1__bool_of : Nat -> Rlow_4_6_2_1__part
rlow_4_6_2_1__bool_of n = PBool (n == 1)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A scalar component read back: one word, under the constructor its tag
||| named.
public export
rlow_4_6_2_1__word_then : (Nat -> Rlow_4_6_2_1__part) -> Rlow_4_6_2_1__word -> List Nat -> Maybe (Rlow_4_6_2_1__part, List Nat)
rlow_4_6_2_1__word_then f w rest = case unbytes w rest of
  Nothing     => Nothing
  Just (n, r) => Just (f n, r)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A length-prefixed component read back: the word says how many bytes
||| are the component's, and the rest follows them.
public export
rlow_4_6_2_1__bytes_then : (List Nat -> Rlow_4_6_2_1__part) -> Rlow_4_6_2_1__word -> List Nat -> Maybe (Rlow_4_6_2_1__part, List Nat)
rlow_4_6_2_1__bytes_then f w rest = case unbytes w rest of
  Nothing     => Nothing
  Just (n, r) => Just (f (take n r), drop n r)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A Ratio's second word read back, after its first.
public export
rlow_4_6_2_1__ratio_of : Rlow_4_6_2_1__word -> Nat -> List Nat -> Maybe (Rlow_4_6_2_1__part, List Nat)
rlow_4_6_2_1__ratio_of w n rest = case unbytes w rest of
  Nothing     => Nothing
  Just (d, r) => Just (PRatio n d, r)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| ONE COMPONENT READ BACK: the tag decides the shape, the word the value or
||| the length. libds has no such reader -- it compares keys in place, by
||| feeding `rk_walk` to a comparing sink -- and it is written here because
||| a reader that inverts the writer is what makes the writer injective.
public export
rlow_4_6_2_1__field_of : Rlow_4_6_2_1__word -> List Nat -> Maybe (Rlow_4_6_2_1__part, List Nat)
rlow_4_6_2_1__field_of w (0 :: rest) = Just (PNull, rest)
rlow_4_6_2_1__field_of w (1 :: rest) = rlow_4_6_2_1__word_then PInt w rest
rlow_4_6_2_1__field_of w (2 :: rest) = rlow_4_6_2_1__word_then PFloat w rest
rlow_4_6_2_1__field_of w (3 :: rest) = rlow_4_6_2_1__word_then rlow_4_6_2_1__bool_of w rest
rlow_4_6_2_1__field_of w (4 :: rest) = rlow_4_6_2_1__bytes_then PStr w rest
rlow_4_6_2_1__field_of w (5 :: rest) = rlow_4_6_2_1__bytes_then PBytes w rest
rlow_4_6_2_1__field_of w (6 :: rest) = rlow_4_6_2_1__bytes_then PJson w rest
rlow_4_6_2_1__field_of w (7 :: rest) = rlow_4_6_2_1__word_then PFact w rest
rlow_4_6_2_1__field_of w (8 :: rest) = case unbytes w rest of
  Nothing     => Nothing
  Just (n, r) => rlow_4_6_2_1__ratio_of w n r
rlow_4_6_2_1__field_of w _ = Nothing

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| A component read in front of the components read after it.
public export
rlow_4_6_2_1__cons_of : Rlow_4_6_2_1__part -> Maybe (Rlow_4_6_2_1__key, List Nat) -> Maybe (Rlow_4_6_2_1__key, List Nat)
rlow_4_6_2_1__cons_of p Nothing        = Nothing
rlow_4_6_2_1__cons_of p (Just (ps, r)) = Just (p :: ps, r)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| So many components read back, in order.
public export
rlow_4_6_2_1__fields_of : Rlow_4_6_2_1__word -> Nat -> List Nat -> Maybe (Rlow_4_6_2_1__key, List Nat)
rlow_4_6_2_1__fields_of w Z     rest = Just ([], rest)
rlow_4_6_2_1__fields_of w (S n) rest = case rlow_4_6_2_1__field_of w rest of
  Nothing     => Nothing
  Just (p, r) => rlow_4_6_2_1__cons_of p (rlow_4_6_2_1__fields_of w n r)

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| The components read back are the key when nothing is left over.
public export
rlow_4_6_2_1__whole_of : Maybe (Rlow_4_6_2_1__key, List Nat) -> Maybe Rlow_4_6_2_1__key
rlow_4_6_2_1__whole_of (Just (ps, [])) = Just ps
rlow_4_6_2_1__whole_of _               = Nothing

--@spec [IRET.25.5.3]
--@spec [RLOW.4.6.2.1]
||| THE KEY READ BACK: the count, then that many components, and nothing
||| left over.
public export
rlow_4_6_2_1__decode : Rlow_4_6_2_1__word -> List Nat -> Maybe Rlow_4_6_2_1__key
rlow_4_6_2_1__decode w bs = case unbytes w bs of
  Nothing     => Nothing
  Just (n, r) => rlow_4_6_2_1__whole_of (rlow_4_6_2_1__fields_of w n r)

-- ---------------------------------------------------------------------
-- The frame is injective over the identity
-- ---------------------------------------------------------------------

--@derives [RLOW.4.6.2.1]
||| `Just` is injective. The base has no `Injective Just` (IDRIS_MODEL_GUIDE),
||| and this module imports nothing of the lane.
public export
rlow_4_6_2_1__just_inj : {0 t : Type} -> (a, b : t) -> Just a = Just b -> a = b
rlow_4_6_2_1__just_inj _ _ Refl = Refl

--@derives [RLOW.4.6.2.1]
||| A list's own length takes it whole from in front of anything.
public export
rlow_4_6_2_1__take_app : (s, rest : List Nat) -> take (length s) (s ++ rest) = s
rlow_4_6_2_1__take_app []        rest = Refl
rlow_4_6_2_1__take_app (x :: xs) rest = cong (x ::) (rlow_4_6_2_1__take_app xs rest)

--@derives [RLOW.4.6.2.1]
||| And dropping its own length leaves exactly what followed it.
public export
rlow_4_6_2_1__drop_app : (s, rest : List Nat) -> drop (length s) (s ++ rest) = rest
rlow_4_6_2_1__drop_app []        rest = Refl
rlow_4_6_2_1__drop_app (x :: xs) rest = rlow_4_6_2_1__drop_app xs rest

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| A SCALAR WRITTEN READS BACK and leaves what followed it, for every word
||| and every tail.
public export
rlow_4_6_2_1__word_rt : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                        (f : Nat -> Rlow_4_6_2_1__part) -> (n : Nat) -> (rest : List Nat) ->
                        rlow_4_6_2_1__word_then f w (bytes w n ++ rest) = Just (f n, rest)
rlow_4_6_2_1__word_rt w ok f n rest with (unbytes w (bytes w n ++ rest)) proof prf
  rlow_4_6_2_1__word_rt w ok f n rest | Nothing     = absurd (trans (sym prf) (ok n rest))
  rlow_4_6_2_1__word_rt w ok f n rest | Just (m, r) =
    case rlow_4_6_2_1__just_inj (m, r) (n, rest) (trans (sym prf) (ok n rest)) of
      Refl => Refl

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| A LENGTH-PREFIXED COMPONENT WRITTEN READS BACK WHOLE and leaves what
||| followed it, for every byte string and every tail: no separator a
||| component can contain, no truncation.
public export
rlow_4_6_2_1__bytes_rt : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                         (f : List Nat -> Rlow_4_6_2_1__part) -> (s, rest : List Nat) ->
                         rlow_4_6_2_1__bytes_then f w (bytes w (length s) ++ (s ++ rest)) = Just (f s, rest)
rlow_4_6_2_1__bytes_rt w ok f s rest with (unbytes w (bytes w (length s) ++ (s ++ rest))) proof prf
  rlow_4_6_2_1__bytes_rt w ok f s rest | Nothing     = absurd (trans (sym prf) (ok (length s) (s ++ rest)))
  rlow_4_6_2_1__bytes_rt w ok f s rest | Just (m, r) =
    case rlow_4_6_2_1__just_inj (m, r) (length s, s ++ rest) (trans (sym prf) (ok (length s) (s ++ rest))) of
      Refl => cong2 (\a, b => Just (f a, b)) (rlow_4_6_2_1__take_app s rest) (rlow_4_6_2_1__drop_app s rest)

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| A Ratio's second word reads back after its first.
public export
rlow_4_6_2_1__ratio_rt : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                         (n, d : Nat) -> (rest : List Nat) ->
                         rlow_4_6_2_1__ratio_of w n (bytes w d ++ rest) = Just (PRatio n d, rest)
rlow_4_6_2_1__ratio_rt w ok n d rest with (unbytes w (bytes w d ++ rest)) proof prf
  rlow_4_6_2_1__ratio_rt w ok n d rest | Nothing     = absurd (trans (sym prf) (ok d rest))
  rlow_4_6_2_1__ratio_rt w ok n d rest | Just (e, r) =
    case rlow_4_6_2_1__just_inj (e, r) (d, rest) (trans (sym prf) (ok d rest)) of
      Refl => Refl

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| A COMPONENT WRITTEN READS BACK and leaves exactly what followed it, for
||| every component and every tail.
public export
rlow_4_6_2_1__field_rt : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                         (p : Rlow_4_6_2_1__part) -> (rest : List Nat) ->
                         rlow_4_6_2_1__field_of w (rlow_4_6_2_1__field_to w p rest) = Just (p, rest)
rlow_4_6_2_1__field_rt w ok PNull         rest = Refl
rlow_4_6_2_1__field_rt w ok (PInt n)      rest = rlow_4_6_2_1__word_rt w ok PInt n rest
rlow_4_6_2_1__field_rt w ok (PFloat b)    rest = rlow_4_6_2_1__word_rt w ok PFloat b rest
rlow_4_6_2_1__field_rt w ok (PBool True)  rest = rlow_4_6_2_1__word_rt w ok rlow_4_6_2_1__bool_of 1 rest
rlow_4_6_2_1__field_rt w ok (PBool False) rest = rlow_4_6_2_1__word_rt w ok rlow_4_6_2_1__bool_of 0 rest
rlow_4_6_2_1__field_rt w ok (PStr s)      rest = rlow_4_6_2_1__bytes_rt w ok PStr s rest
rlow_4_6_2_1__field_rt w ok (PBytes s)    rest = rlow_4_6_2_1__bytes_rt w ok PBytes s rest
rlow_4_6_2_1__field_rt w ok (PJson s)     rest = rlow_4_6_2_1__bytes_rt w ok PJson s rest
rlow_4_6_2_1__field_rt w ok (PFact i)     rest = rlow_4_6_2_1__word_rt w ok PFact i rest
rlow_4_6_2_1__field_rt w ok (PRatio n d)  rest with (unbytes w (bytes w n ++ (bytes w d ++ rest))) proof prf
  rlow_4_6_2_1__field_rt w ok (PRatio n d) rest | Nothing     = absurd (trans (sym prf) (ok n (bytes w d ++ rest)))
  rlow_4_6_2_1__field_rt w ok (PRatio n d) rest | Just (m, r) =
    case rlow_4_6_2_1__just_inj (m, r) (n, bytes w d ++ rest) (trans (sym prf) (ok n (bytes w d ++ rest))) of
      Refl => rlow_4_6_2_1__ratio_rt w ok n d rest

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| THE COMPONENTS WRITTEN READ BACK, as many as were written, and leave
||| exactly what followed them.
public export
rlow_4_6_2_1__fields_rt : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                          (ps : Rlow_4_6_2_1__key) -> (rest : List Nat) ->
                          rlow_4_6_2_1__fields_of w (length ps) (rlow_4_6_2_1__fields_to w ps rest) = Just (ps, rest)
rlow_4_6_2_1__fields_rt w ok [] rest = Refl
rlow_4_6_2_1__fields_rt w ok (p :: ps) rest with (rlow_4_6_2_1__field_of w (rlow_4_6_2_1__field_to w p (rlow_4_6_2_1__fields_to w ps rest))) proof prf
  rlow_4_6_2_1__fields_rt w ok (p :: ps) rest | Nothing =
    absurd (trans (sym prf) (rlow_4_6_2_1__field_rt w ok p (rlow_4_6_2_1__fields_to w ps rest)))
  rlow_4_6_2_1__fields_rt w ok (p :: ps) rest | Just (q, r) =
    case rlow_4_6_2_1__just_inj (q, r) (p, rlow_4_6_2_1__fields_to w ps rest) (trans (sym prf) (rlow_4_6_2_1__field_rt w ok p (rlow_4_6_2_1__fields_to w ps rest))) of
      Refl => cong (rlow_4_6_2_1__cons_of p) (rlow_4_6_2_1__fields_rt w ok ps rest)

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| THE KEY WRITTEN READS BACK: `rlow_4_6_2_1__decode` inverts
||| `rlow_4_6_2_1__encode` on every key, under every codec with the
||| contract.
public export
rlow_4_6_2_1__decode_encode : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                              (k : Rlow_4_6_2_1__key) ->
                              rlow_4_6_2_1__decode w (rlow_4_6_2_1__encode w k) = Just k
rlow_4_6_2_1__decode_encode w ok k with (unbytes w (bytes w (length k) ++ rlow_4_6_2_1__fields_to w k [])) proof prf
  rlow_4_6_2_1__decode_encode w ok k | Nothing =
    absurd (trans (sym prf) (ok (length k) (rlow_4_6_2_1__fields_to w k [])))
  rlow_4_6_2_1__decode_encode w ok k | Just (n, r) =
    case rlow_4_6_2_1__just_inj (n, r) (length k, rlow_4_6_2_1__fields_to w k []) (trans (sym prf) (ok (length k) (rlow_4_6_2_1__fields_to w k []))) of
      Refl => cong rlow_4_6_2_1__whole_of (rlow_4_6_2_1__fields_rt w ok k [])

--@derives [IRET.25.5.3]
--@derives [RLOW.4.6.2.1]
||| THE FRAME IS INJECTIVE OVER THE IDENTITY: two keys libds stores as one
||| byte string are one key, under every codec with the contract. So the
||| storage preserves the identity the clause fixes -- "no separator a
||| component can contain, no truncation of a component or of the whole,
||| no key-length limit" ([IRET.25.5.3]) -- whatever bytes the components
||| hold: the component count, the tag bytes and the length words make the
||| frame prefix-free, which the retired encoder's separator could not.
public export
rlow_4_6_2_1__encode_injective : (w : Rlow_4_6_2_1__word) -> Rlow_4_6_2_1__word_ok w ->
                                 (k1, k2 : Rlow_4_6_2_1__key) ->
                                 rlow_4_6_2_1__encode w k1 = rlow_4_6_2_1__encode w k2 -> k1 = k2
rlow_4_6_2_1__encode_injective w ok k1 k2 eq =
  rlow_4_6_2_1__just_inj k1 k2
    (trans (sym (rlow_4_6_2_1__decode_encode w ok k1))
           (trans (cong (rlow_4_6_2_1__decode w) eq) (rlow_4_6_2_1__decode_encode w ok k2)))

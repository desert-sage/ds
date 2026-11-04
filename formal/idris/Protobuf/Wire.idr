-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The Protocol Buffers wire format, as a total decoder ([RFCS.19.1]).
|||
||| WHY THIS EXISTS. [RFCS.19.1] says "the framing is two levels and both are
||| protobuf". Everything the DS corpus specifies about `.dsc` and about fact
||| streams rests on that sentence, and the corpus does not restate the wire
||| format — correctly, since it is Google's and not DS's. So a reference
||| implementation of DS needs a protobuf decoder before it can read a single
||| atom, and this is it.
|||
||| WRITTEN FROM THE SPECIFICATION, not from memory of it. Sources:
|||
|||   https://protobuf.dev/programming-guides/encoding/   (wire format)
|||   https://protobuf.dev/programming-guides/proto3/      (field numbers)
|||
||| Every constant below is quoted in the comment that introduces it. This
||| project has filed enough findings about implementations written from a
||| remembered format to know better than to add one.
|||
||| WHAT TOTALITY BUYS HERE, and it is not a formality. `.dsc` bytes are
||| UNTRUSTED INPUT. Under `%default total` this decoder is proven to terminate
||| on every byte string — malformed, truncated, adversarial, or a gigabyte of
||| 0xFF. Neither libds's decoder nor the Mercury one has that property proven,
||| and "the parser cannot hang" is exactly the kind of claim a runtime handling
||| untrusted artefacts should be able to make.
|||
||| FOUR PLACES GOOGLE'S SPEC IS SILENT, decided explicitly here rather than by
||| accident. The encoding page states no rule for any of them, and an
||| implementation that picks silently is how two decoders come to disagree on
||| exactly the inputs an attacker controls:
|||
|||   1. OVERLONG VARINT. 1-10 bytes is stated; what an 11th byte means is not.
|||      Refused — see `rfcs_19_1__varint`.
|||   2. TRUNCATED INPUT. Refused. Note DS's own corpus DOES rule on this one
|||      level up, at the framing: [RFCS.19.2] makes a partial trailing atom EOF
|||      for a `Stream` read incrementally and an error for a whole buffer, and
|||      [RDSC.9.7] keeps it a loader error for a `Dsc`. Those clauses are about
|||      frames; this is about the bytes inside one.
|||   3. FIELD NUMBER OUT OF RANGE. proto3 states the range and says the
|||      COMPILER complains; it says nothing about a decoder. Refused here.
|||   4. RESERVED FIELD NUMBERS 19,000-19,999. ACCEPTED, deliberately — the
|||      restriction is on what a `.proto` may declare, not on what may appear
|||      on the wire, and a decoder that refused them would reject bytes a
|||      conforming producer is permitted to emit.
|||
||| `Integer` IS THE NUMERIC TYPE, not `Bits64` and NOT `Nat`.
|||
||| Not `Bits64`, because a reference decoder should make its range checks
||| explicit rather than inherit them from a machine word: `Integer` is
||| arbitrary-precision, so the 2^64 bound is tested where the specification
||| states it and nowhere else, and an overflow cannot happen silently in the
||| arithmetic.
|||
||| NOT `Nat`, AND THAT WAS A REAL MISTAKE, corrected here because only running
||| the code could have found it. The first version used `Nat` for exactly the
||| argument above and typechecked perfectly — `Nat` is unbounded too. Then the
||| worked examples were built and executed for the first time and the process
||| was SIGKILLed after thirty-three minutes: `Nat` is Peano, so a literal like
||| `4294967294` in a ZigZag example, or `536870911` as the field-number
||| ceiling, is that many nested `S` constructors at runtime.
|||
||| Both types are arbitrary-precision and only one of them can be evaluated.
||| `idris2 --check` cannot tell them apart, which is the entire argument for
||| the build-and-run phase in `scripts/formal/check_idris.py` — and it earned its place
||| twice on the first run: once on visibility, once here.
module Protobuf.Wire

import Data.List
import Data.Nat

%default total

--@spec [RFCS.19.1]
||| The six wire types. Quoted from the encoding guide's table:
|||
|||   0  VARINT  int32, int64, uint32, uint64, sint32, sint64, bool, enum
|||   1  I64     fixed64, sfixed64, double
|||   2  LEN     string, bytes, embedded messages, packed repeated fields
|||   3  SGROUP  group start (deprecated)
|||   4  EGROUP  group end (deprecated)
|||   5  I32     fixed32, sfixed32, float
|||
||| Codes 6 and 7 are unassigned. They are representable in the three tag bits
||| and are therefore reachable from any byte string, which is why decoding a
||| tag can fail rather than being total into this type.
public export
data Rfcs_19_1__wire_type : Type where
  VARINT : Rfcs_19_1__wire_type
  I64    : Rfcs_19_1__wire_type
  LEN    : Rfcs_19_1__wire_type
  SGROUP : Rfcs_19_1__wire_type
  EGROUP : Rfcs_19_1__wire_type
  I32    : Rfcs_19_1__wire_type

--@spec [RFCS.19.1]
||| Why a decode stopped. A decoder over untrusted bytes needs to say which
||| thing was wrong, not merely that something was: three of these five are
||| cases Google's specification does not rule on, and naming them separately is
||| what makes the choice auditable.
public export
data Rfcs_19_1__refusal : Type where
  Truncated        : Rfcs_19_1__refusal
  OverlongVarint   : Rfcs_19_1__refusal
  VarintOverflow   : Rfcs_19_1__refusal
  BadWireType      : Integer -> Rfcs_19_1__refusal
  FieldOutOfRange  : Integer -> Rfcs_19_1__refusal

--@spec [RFCS.19.1]
||| A decode either yields a value and the bytes after it, or refuses.
|||
||| CARRYING THE REMAINDER is what makes the decoder composable AND is what
||| makes termination provable: every step returns a suffix of its input, so a
||| caller recursing on the remainder is recursing on something structurally
||| smaller.
public export
data Rfcs_19_1__decoded : Type -> Type where
  Yield  : a -> List Bits8 -> Rfcs_19_1__decoded a
  Refuse : Rfcs_19_1__refusal -> Rfcs_19_1__decoded a

--@spec [RFCS.19.1]
||| Base-128 varint. "Each byte in the varint has a continuation bit that
||| indicates if the byte that follows it is part of the varint. This is the
||| most significant bit (MSB) of the byte" — and "the resulting integer is
||| built by appending together the 7-bit payloads of its constituent bytes",
||| least-significant group first.
|||
||| TEN BYTES IS THE CEILING. The guide states varints encode unsigned 64-bit
||| integers in 1-10 bytes, and that a negative `intN` uses "all ten bytes". An
||| eleventh byte is therefore not a longer number, it is a malformed one:
||| refused as `OverlongVarint` rather than silently truncated to 64 bits, which
||| is what an implementation using a machine word would do by accident.
|||
||| THE TENTH BYTE IS ALSO RANGE-CHECKED. Nine bytes carry 63 bits, so the tenth
||| may contribute only bit 63 — a tenth byte with any higher payload bit set
||| encodes a value above 2^64-1. `VarintOverflow` is a different refusal from
||| `OverlongVarint` because they are different producer defects.
public export
rfcs_19_1__varint_go : List Bits8 -> Integer -> Integer -> Nat ->
                       Rfcs_19_1__decoded Integer
rfcs_19_1__varint_go [] _ _ _ = Refuse Truncated
rfcs_19_1__varint_go (b :: rest) acc scale taken =
  let payload : Integer
      payload = cast (prim__and_Bits8 b 127)
      acc'    = acc + payload * scale
  in if prim__and_Bits8 b 128 == 0
       -- The tenth byte carries only bit 63, so its payload may be 0 or 1;
       -- anything larger encodes a value above 2^64-1.
       then (if taken >= 9 && payload > 1
               then Refuse VarintOverflow
               else Yield acc' rest)
       -- A continuation bit on the tenth byte announces an eleventh.
       else if taken >= 9
              then Refuse OverlongVarint
              else rfcs_19_1__varint_go rest acc' (scale * 128) (S taken)

--@spec [RFCS.19.1]
||| Base-128 varint — the entry point. See `rfcs_19_1__varint_go` above for the
||| loop and for why it is top-level rather than a `where` clause.
public export
rfcs_19_1__varint : List Bits8 -> Rfcs_19_1__decoded Integer
rfcs_19_1__varint bs = rfcs_19_1__varint_go bs 0 1 0

--@spec [RFCS.19.1]
||| The wire type in a tag's low three bits. Codes 6 and 7 are unassigned, so
||| this is a refusal and not a total function — every three-bit pattern is
||| reachable from arbitrary bytes, and mapping an unassigned code onto a real
||| wire type would let malformed input be parsed as something.
public export
rfcs_19_1__wire_type_of : Integer -> Rfcs_19_1__decoded Rfcs_19_1__wire_type
rfcs_19_1__wire_type_of 0 = Yield VARINT []
rfcs_19_1__wire_type_of 1 = Yield I64    []
rfcs_19_1__wire_type_of 2 = Yield LEN    []
rfcs_19_1__wire_type_of 3 = Yield SGROUP []
rfcs_19_1__wire_type_of 4 = Yield EGROUP []
rfcs_19_1__wire_type_of 5 = Yield I32    []
rfcs_19_1__wire_type_of n = Refuse (BadWireType n)

--@spec [RFCS.19.1]
||| A wire type's numeric code — the inverse of `rfcs_19_1__wire_type_of`.
|||
||| Needed so a caller that REQUIRES a particular wire type can say which one it
||| got when refusing. Total in this direction, unlike the decode: every wire
||| type has a code, but not every code is a wire type.
public export
rfcs_19_1__wire_code : Rfcs_19_1__wire_type -> Integer
rfcs_19_1__wire_code VARINT = 0
rfcs_19_1__wire_code I64    = 1
rfcs_19_1__wire_code LEN    = 2
rfcs_19_1__wire_code SGROUP = 3
rfcs_19_1__wire_code EGROUP = 4
rfcs_19_1__wire_code I32    = 5

--@spec [RFCS.19.1]
||| The largest legal field number. proto3: "You must give each field in your
||| message definition a number between `1` and `536,870,911`" — which is
||| 2^29 - 1, the range that fits once the three wire-type bits are taken.
public export
rfcs_19_1__max_field_number : Integer
rfcs_19_1__max_field_number = 536870911

--@spec [RFCS.19.1]
||| A decoded tag: the field number and the wire type it announces.
public export
record Rfcs_19_1__tag where
  constructor MkTag
  fieldNumber : Integer
  wireType    : Rfcs_19_1__wire_type

--@spec [RFCS.19.1]
||| Decode one tag. "The 'tag' of a record is encoded as a varint formed from
||| the field number and the wire type via the formula
||| `(field_number << 3) | wire_type`", so decoding divides by eight and takes
||| the remainder.
|||
||| DIVISION RATHER THAN SHIFTS, and not for elegance: `div 8` and `mod 8` on
||| `Nat` are the same operation as `>> 3` and `& 7` on a machine word without
||| the width assumption, so the field number cannot be silently truncated by
||| the type it is computed in.
|||
||| FIELD NUMBER 0 IS REFUSED along with anything above the maximum. proto3
||| gives the range as starting at 1 and says nothing about a decoder meeting a
||| 0 — one of the four silences this module decides rather than inherits.
||| Reserved numbers 19,000-19,999 are NOT refused: that restriction binds what
||| a `.proto` may declare, not what may travel on the wire.
public export
rfcs_19_1__tag : List Bits8 -> Rfcs_19_1__decoded Rfcs_19_1__tag
rfcs_19_1__tag bs =
  case rfcs_19_1__varint bs of
    Refuse r => Refuse r
    Yield v rest =>
      let fld = v `div` 8
          wt  = v `mod` 8
      in if fld == 0 || fld > rfcs_19_1__max_field_number
           then Refuse (FieldOutOfRange fld)
           else case rfcs_19_1__wire_type_of wt of
                  Refuse r  => Refuse r
                  Yield w _ => Yield (MkTag fld w) rest

--@spec [RFCS.19.1]
||| Take exactly `n` bytes, or refuse as truncated. The building block for
||| LEN payloads and for the two fixed-width wire types.
public export
rfcs_19_1__take : Integer -> List Bits8 -> Rfcs_19_1__decoded (List Bits8)
rfcs_19_1__take n bs =
  if n <= 0
    then Yield [] bs
    else case bs of
           []          => Refuse Truncated
           (b :: rest) =>
             case rfcs_19_1__take (n - 1) rest of
               Refuse r       => Refuse r
               Yield got more => Yield (b :: got) more

--@spec [RFCS.19.1]
||| A LEN payload: "The `LEN` wire type has a dynamic length, specified by a
||| varint immediately after the tag, which is followed by the payload as
||| usual." Used identically by string, bytes, submessages and packed repeated
||| fields — the guide is explicit that submessages "are encoded identically to
||| strings".
public export
rfcs_19_1__len_payload : List Bits8 -> Rfcs_19_1__decoded (List Bits8)
rfcs_19_1__len_payload bs =
  case rfcs_19_1__varint bs of
    Refuse r     => Refuse r
    Yield n rest => rfcs_19_1__take n rest

--@spec [RFCS.19.1]
||| ZigZag, decoded. The guide gives the ENCODING as `(n << 1) ^ (n >> 31)` for
||| sint32 and `(n << 1) ^ (n >> 63)` for sint64, and states the mapping
||| plainly: "Positive integers `p` are encoded as `2 * p` (the even numbers),
||| while negative integers `n` are encoded as `2 * |n| - 1` (the odd numbers)."
|||
||| Decoding inverts that statement directly rather than inverting the shift
||| formula, because the shift formula is width-dependent and the statement is
||| not — the two agree, and only one of them is true for every width.
public export
rfcs_19_1__unzigzag : Integer -> Integer
rfcs_19_1__unzigzag n =
  if n `mod` 2 == 0
    then cast (n `div` 2)
    else negate (cast ((n `div` 2) + 1))

--@derives [RFCS.19.1]
||| The empty input is TRUNCATED, not zero.
|||
||| Distinguishing those two is the whole difference between a decoder and a
||| guess. proto3 omits a zero-valued scalar entirely, so "no bytes" and "a byte
||| encoding 0" are different facts about the message — and conflating them is
||| the single most-filed defect class in this project's ledger.
public export
rfcs_19_1__empty_is_truncated :
  rfcs_19_1__varint [] = Refuse Truncated
rfcs_19_1__empty_is_truncated = Refl

--@derives [RFCS.19.1]
||| Taking nothing consumes nothing and refuses nothing, whatever follows.
|||
||| Quantified over the input rather than shown on an example, which is the
||| distinction this module now draws throughout: a theorem holds for all
||| inputs, a worked example holds for one and belongs in the test executable.
public export
rfcs_19_1__take_zero_is_identity :
  (bs : List Bits8) -> rfcs_19_1__take 0 bs = Yield [] bs
rfcs_19_1__take_zero_is_identity bs = Refl

-- `take` from an empty input with a positive count refuses. That WAS a theorem
-- here, quantified over `(n : Nat)` and discharged by `Refl` — and it stopped
-- being provable when the count became an `Integer`, because stating it needs a
-- positivity hypothesis (`So (n > 0)`) and discharging it needs reasoning about
-- primitive Integer comparison that Idris will not do for free.
--
-- It moved to the executable rather than acquiring machinery, because what it
-- asserts is a fact about a class of inputs and the honest place for that is a
-- test. Dressing it as a theorem would have cost a `believe_me` — a declared
-- hole, in a module whose entire claim is that it has none.

-- WORKED EXAMPLES LIVE IN `Main.idr`, NOT HERE, and finding that out was worth
-- the detour.
--
-- The first version of this module asserted the guide's own examples as
-- compile-time equalities -- `varint [172, 2] = Yield 300 []` by `Refl`, 0x0A
-- decoding to field 1 / LEN, ZigZag's 0,1,2,3 mapping to 0,-1,1,-2. None of
-- them typechecks: `div` and `mod` on `Nat` go through `Integral` and do not
-- reduce during elaboration, so the goal comes back as
-- `if ((acc' [10] 10 [] 0 1 0 `div` 8) == 0) || Delay ...` -- stuck, not false.
--
-- The tempting fix is to rewrite the arithmetic into something that reduces --
-- repeated subtraction, or decoding the tag bit-by-bit from the first byte.
-- Both would make the examples provable and both make the DECODER worse: a
-- field number runs to 536,870,911, and a `div` by repeated subtraction on a
-- `Nat` that large is not a reference implementation, it is a hang.
--
-- So the split is deliberate: compile-time proofs state properties holding for
-- ALL inputs, and the guide's worked examples are RUN by the executable. This
-- is a plain comment rather than a tagged element, because a `Unit` definition
-- existing only to carry prose is a tie that looks like content and is not.

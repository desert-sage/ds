-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Reading a protobuf message body: fields, skipping, and last-one-wins.
|||
||| `Wire.idr` decodes the primitives and `Framing.idr` walks DS's two-level
||| container. This is the level between: given the BODY bytes of one atom, what
||| fields does it carry?
|||
||| WRITTEN FROM THE SPECIFICATION. Sources as in `Wire.idr`, plus the oneof
||| rules from https://protobuf.dev/programming-guides/proto3/, which are quoted
||| where they are used.
|||
||| THE ONEOF EXCEPTION, and it is the reason this module exists rather than
||| being folded into an atom decoder. proto3 normally omits a default-valued
||| field, so absent and zero are the same bytes — the single most-filed defect
||| class in this project. Inside a `oneof` that rule is REVERSED:
|||
|||   "If you set a oneof field to the default value (such as setting an int32
|||    oneof field to 0), the 'case' of that oneof field will be set, and the
|||    value will be serialized on the wire."
|||
||| So an `ExprLiteral` carrying the boolean `false` really is on the wire as
||| field 5 with payload 0, and is NOT indistinguishable from absent. A decoder
||| that applied proto3's usual rule here would read every `false` literal in
||| every artefact as a missing value. Verified against the specification rather
||| than recalled, because recalling it the other way is entirely plausible.
|||
||| LAST ONE WINS, also quoted: "If the parser encounters multiple members of
||| the same oneof on the wire, only the last member seen is used in the parsed
||| message." The same rule holds for repeated appearances of a non-repeated
||| scalar: "the parser accepts the last value it sees." So this module returns
||| fields IN ORDER and `rfcs_19_1__last_field` takes the last — separated so
||| that a caller wanting the repeated-field reading (concatenation) still has
||| the full list.
module Protobuf.Message

import Protobuf.Wire
import Data.List

%default total

--@spec [RFCS.19.1]
||| One field's raw value, kept in the shape its wire type gives it.
|||
||| NOT INTERPRETED HERE. A VARINT payload might be an int64, a bool, an enum or
||| a ZigZag sint — the wire cannot tell, only the `.proto` can. Decoding stops
||| at the point where the schema would have to be consulted, which is what
||| makes this module reusable for every atom body rather than for one.
public export
data Rfcs_19_1__field_value : Type where
  VarintV : Integer -> Rfcs_19_1__field_value
  I64V    : List Bits8 -> Rfcs_19_1__field_value
  LenV    : List Bits8 -> Rfcs_19_1__field_value
  I32V    : List Bits8 -> Rfcs_19_1__field_value

-- Structural equality, written out rather than derived. Not a tagged element:
-- an interface implementation formalizes no clause, and giving it a `--@spec`
-- would be the kind of tie that inflates a coverage number without covering
-- anything. Two values are equal when the wire gave them the same shape AND the
-- same bytes -- a VarintV and an I64V holding the same number are NOT equal,
-- because the wire type is part of what was read.
public export
Eq Rfcs_19_1__field_value where
  (VarintV a) == (VarintV b) = a == b
  (I64V a)    == (I64V b)    = a == b
  (LenV a)    == (LenV b)    = a == b
  (I32V a)    == (I32V b)    = a == b
  _           == _           = False

--@spec [RFCS.19.1]
||| A field: its number, and its value as the wire gave it.
public export
record Rfcs_19_1__field where
  constructor MkField
  number : Integer
  value  : Rfcs_19_1__field_value

--@spec [RFCS.19.1]
||| Read one field — tag, then a value whose shape the wire type decides.
|||
||| THIS IS WHAT MAKES UNKNOWN FIELDS SKIPPABLE, which the guide gives as the
||| reason wire types exist at all: "This allows old parsers to skip over new
||| fields they don't understand." A reader that does not know field 47 can
||| still step over it, because the wire type says how long it is without
||| knowing what it means.
|||
||| GROUPS ARE REFUSED, explicitly rather than by omission. SGROUP and EGROUP
||| are wire types 3 and 4, deprecated, and proto3 cannot declare a group at
||| all — so no conforming producer of a DS artefact can emit one. Accepting
||| them would mean carrying nesting-and-matching logic ("Group field numbers
||| need to match up") that nothing in this corpus can exercise, which is
||| untested code in a decoder for untrusted input. Refusing names the decision.
public export
rfcs_19_1__field : List Bits8 -> Rfcs_19_1__decoded Rfcs_19_1__field
rfcs_19_1__field bs =
  case rfcs_19_1__tag bs of
    Refuse r => Refuse r
    Yield t rest =>
      case wireType t of
        VARINT => case rfcs_19_1__varint rest of
                    Refuse r => Refuse r
                    Yield v after => Yield (MkField (fieldNumber t) (VarintV v)) after
        I64    => case rfcs_19_1__take 8 rest of
                    Refuse r => Refuse r
                    Yield p after => Yield (MkField (fieldNumber t) (I64V p)) after
        I32    => case rfcs_19_1__take 4 rest of
                    Refuse r => Refuse r
                    Yield p after => Yield (MkField (fieldNumber t) (I32V p)) after
        LEN    => case rfcs_19_1__len_payload rest of
                    Refuse r => Refuse r
                    Yield p after => Yield (MkField (fieldNumber t) (LenV p)) after
        SGROUP => Refuse (BadWireType 3)
        EGROUP => Refuse (BadWireType 4)

--@spec [RFCS.19.1]
||| Every field in a message body, IN ORDER.
|||
||| Order is preserved because two of protobuf's rules depend on it: a repeated
||| non-oneof field concatenates its appearances, and a non-repeated one keeps
||| the LAST. Returning a map would silently decide both.
|||
||| Fuel is the byte count, and as in the frame walk it is an exact bound rather
||| than a guess: a field costs at least one byte for its tag.
public export
rfcs_19_1__fields_go : Nat -> List Bits8 -> List Rfcs_19_1__field ->
                       Rfcs_19_1__decoded (List Rfcs_19_1__field)
rfcs_19_1__fields_go _ [] acc = Yield (reverse acc) []
rfcs_19_1__fields_go Z _ acc = Refuse Truncated
rfcs_19_1__fields_go (S fuel) bs acc =
  case rfcs_19_1__field bs of
    Refuse r => Refuse r
    Yield f after => rfcs_19_1__fields_go fuel after (f :: acc)

--@spec [RFCS.19.1]
||| Every field in a message body.
public export
rfcs_19_1__fields : List Bits8 -> Rfcs_19_1__decoded (List Rfcs_19_1__field)
rfcs_19_1__fields bs = rfcs_19_1__fields_go (length bs) bs []

--@spec [RFCS.19.1]
||| The LAST field with a given number, which is the value a parser must use.
|||
||| "For numeric types and strings, if the same field appears multiple times,
||| the parser accepts the `last` value it sees", and for a oneof, "only the
||| last member seen is used in the parsed message".
|||
||| Written as a fold rather than `find` over a reversed list so the traversal
||| order is the wire order and the rule is visible in the code: each later
||| match replaces the earlier one.
public export
rfcs_19_1__last_field : Integer -> List Rfcs_19_1__field ->
                        Maybe Rfcs_19_1__field
rfcs_19_1__last_field _ [] = Nothing
rfcs_19_1__last_field n (f :: fs) =
  case rfcs_19_1__last_field n fs of
    Just later => Just later
    Nothing    => if number f == n then Just f else Nothing

--@spec [RFCS.19.1]
||| The LAST member of a `oneof` present in a body, given a recogniser that says
||| whether a field is a member and what it means.
|||
||| SEPARATE FROM `rfcs_19_1__last_field`, and the difference is the whole point.
||| That one is last-wins WITHIN one field number; this is last-wins ACROSS the
||| several numbers a `oneof` spans — "if the parser encounters multiple members
||| of the same oneof on the wire, only the last member seen is used in the
||| parsed message". Field 5 followed by field 2 must yield field 2's, and a
||| per-number lookup cannot say that: it would have to encode a priority
||| between numbers, which the wire order already decides.
|||
||| PARAMETERISED BY THE RECOGNISER rather than written per message, because the
||| rule is protobuf's and not any one schema's. A version specialised to a
||| single message would have to be re-proved for the next one, and the previous
||| such lemma died with the message it was written against.
public export
rfcs_19_1__last_oneof : (Rfcs_19_1__field -> Maybe a) -> List Rfcs_19_1__field ->
                        Maybe a -> Maybe a
rfcs_19_1__last_oneof _      []        acc = acc
rfcs_19_1__last_oneof member (f :: fs) acc =
  rfcs_19_1__last_oneof member fs (case member f of
                                     Just x  => Just x
                                     Nothing => acc)

--@derives [RFCS.19.1]
||| An empty body sets no member of any `oneof`, for every recogniser.
|||
||| Quantified over the recogniser, so it is the BODY that is empty rather than
||| any particular schema finding nothing in it.
public export
rfcs_19_1__no_body_sets_no_member :
  (member : Rfcs_19_1__field -> Maybe a) ->
  rfcs_19_1__last_oneof member [] Nothing = Nothing
rfcs_19_1__no_body_sets_no_member _ = Refl

--@derives [RFCS.19.1]
||| An empty body has no fields — not a truncated one.
public export
rfcs_19_1__empty_body_has_no_fields :
  rfcs_19_1__fields [] = Yield [] []
rfcs_19_1__empty_body_has_no_fields = Refl

--@derives [RFCS.19.1]
||| Looking up a field in nothing finds nothing, for every field number.
public export
rfcs_19_1__lookup_in_empty :
  (n : Integer) -> rfcs_19_1__last_field n [] = Nothing
rfcs_19_1__lookup_in_empty n = Refl

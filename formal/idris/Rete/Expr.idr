-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The Rete expression `oneof`, and the three members that carry a `bool`
||| ([LNUL.2.1]).
|||
||| WHAT THIS REPLACES, and why it is a rewrite rather than a re-point.
||| `Dsc/Expr.idr` modelled the `E*` atom encoding: `expr_id` keys, topological
||| emission order, a single-forward-pass resolver. `[RPIR.*]` is retired and
||| `proto/pir_expr.proto` is gone. Those properties did not lose their clause —
||| their SUBJECT stopped existing. `proto/rete_expr.proto` nests
||| sub-expressions by containment:
|||
|||   message Expr { oneof kind { ... CoalesceExpr coalesce = 17; } }
|||   message CoalesceExpr { Expr left = 1; Expr right = 2; }
|||
||| There is no identifier to be unique, nothing emitted separately to be
||| ordered, and no way to reference a node that has no name. A proof about any
||| of it would now be a proof about nothing.
|||
||| WHAT SURVIVED THE MOVE is one property, and it arrived with a bigger
||| subject than it had. `ELIT`'s `null_val` was a `bool` whose value meant
||| nothing — the oneof CASE was the signal. In `Expr` that is true of TWO
||| members:
|||
|||   bool now      = 11;  // (now) clock read; value ignored
|||   bool lit_null = 16;  // the oneof CASE signals null; the bool is ignored
|||
||| and a third member carries a `bool` that DOES mean what it holds:
|||
|||   bool lit_bool = 4;
|||
||| So three members of one `oneof` are `bool` on the wire and only one of them
||| is to be read. A decoder that trusts the payload rather than the case
||| answers `false` for `null` — and `false` is a perfectly good value, so
||| nothing downstream can tell it went wrong. That is what makes this worth a
||| proof rather than a comment.
|||
||| [LNUL.2.1] is the clause because it is the one the artefact itself cites at
||| the field, and because its content is exactly at stake: "there is exactly
||| ONE `null` … so it hashes, encodes, orders, and compares identically on
||| every conforming engine." A payload-reading decoder makes `null` encode as
||| two different things depending on a byte no producer promises anything
||| about.
module Rete.Expr

import Protobuf.Wire
import Protobuf.Message

%default total

--@spec [LNUL.2.1]
||| What a member of `Expr.kind` was found to mean.
|||
||| FOUR CONSTRUCTORS, THREE OF WHICH ARE THE SUBJECT. `SBool`, `SNow` and
||| `SNull` are the three `bool`-carrying members; `SUninterpreted` is
||| everything else, and it KEEPS THE FIELD NUMBER rather than collapsing to a
||| single "other".
|||
||| That last choice is the one worth defending. A member this module does not
||| interpret and a member arriving with a wire type the schema does not give it
||| both land here — but naming the number means neither is silently dropped,
||| and a caller can tell `binop` (6) from a `lit_null` (16) that came in
||| length-delimited. Collapsing them would make a malformed artefact and an
||| unmodelled one indistinguishable, which is the blur this module exists to
||| refuse in the first place.
public export
data Lnul_2_1__signal : Type where
  ||| `lit_bool = 4` — the PAYLOAD is the value.
  SBool          : Bool -> Lnul_2_1__signal
  ||| `now = 11` — the CASE is the value; the payload is ignored.
  SNow           : Lnul_2_1__signal
  ||| `lit_null = 16` — the CASE is the value; the payload is ignored.
  SNull          : Lnul_2_1__signal
  ||| Another member of `kind`, or one of the three above under a wire type the
  ||| schema does not give it. Named by field number, not collapsed.
  SUninterpreted : Integer -> Lnul_2_1__signal

-- Structural equality, for the same reason `Protobuf/Message.idr` gives for
-- its own: an interface implementation formalizes no clause, so it carries no
-- tag. `SNow` and `SNull` are distinct here even though the wire hands both of
-- them the same bytes, which is the entire content of the module.
public export
Eq Lnul_2_1__signal where
  (SBool a)          == (SBool b)          = a == b
  SNow               == SNow               = True
  SNull              == SNull              = True
  (SUninterpreted a) == (SUninterpreted b) = a == b
  _                  == _                  = False

--@spec [LNUL.2.1]
||| The field numbers `Expr.kind` declares: 1 to 8, 11 to 18, 20 and 21, as
||| `rete_expr.proto` stands today (21 is `entry_stamp`, [LTIM.2.8.6]'s
||| stamp of the fact bound at a pattern index, a `uint32`). 9 and 10 are
||| reserved, 19 is `json_tainted`, a field of `Expr` outside the `oneof`,
||| and 22 on is nothing yet.
|||
||| A fact about a schema version rather than a law, written out as the set
||| rather than as a bound: a bound claimed the reserved numbers and would have
||| claimed 19, and a member added at 22 shows up as unknown either way rather
||| than as a member this module silently claims to have interpreted. Literal
||| patterns, not comparisons, so that a proof below reduces through it.
public export
lnul_2_1__declared : Integer -> Bool
lnul_2_1__declared 1  = True
lnul_2_1__declared 2  = True
lnul_2_1__declared 3  = True
lnul_2_1__declared 4  = True
lnul_2_1__declared 5  = True
lnul_2_1__declared 6  = True
lnul_2_1__declared 7  = True
lnul_2_1__declared 8  = True
lnul_2_1__declared 11 = True
lnul_2_1__declared 12 = True
lnul_2_1__declared 13 = True
lnul_2_1__declared 14 = True
lnul_2_1__declared 15 = True
lnul_2_1__declared 16 = True
lnul_2_1__declared 17 = True
lnul_2_1__declared 18 = True
lnul_2_1__declared 20 = True
lnul_2_1__declared 21 = True
lnul_2_1__declared _  = False

--@spec [LNUL.2.1]
||| Whether one field is a member of `Expr.kind`, and what it means.
|||
||| `Nothing` means NOT A MEMBER — a field number the `oneof` does not declare,
||| which a parser skips as unknown. It does not mean "malformed" and it does
||| not mean "unset": an unset `oneof` is an empty list of members, which is a
||| property of the BODY and is decided by `lnul_2_1__kind_of` below.
public export
lnul_2_1__member : Rfcs_19_1__field -> Maybe Lnul_2_1__signal
lnul_2_1__member f =
  case (number f, value f) of
    (4,  VarintV v) => Just (SBool (v /= 0))
    (11, VarintV _) => Just SNow
    (16, VarintV _) => Just SNull
    (n,  _)         => if lnul_2_1__declared n
                         then Just (SUninterpreted n)
                         else Nothing

--@spec [LNUL.2.1]
||| The member of `Expr.kind` a body sets, or `Nothing` if it sets none.
|||
||| Last-one-wins across the `oneof`, delegated to `rfcs_19_1__last_oneof`
||| because that rule is protobuf's rather than this schema's. The previous
||| version of this module wrote its own fold and it died with the message it
||| was written against; this one cannot.
public export
lnul_2_1__kind_of : List Rfcs_19_1__field -> Maybe Lnul_2_1__signal
lnul_2_1__kind_of fs = rfcs_19_1__last_oneof lnul_2_1__member fs Nothing

--@derives [LNUL.2.1]
||| `lit_null` is the CASE, for EVERY payload.
|||
||| Quantified over the byte, which is what makes it a theorem rather than a
||| test: there is no value of `v` for which this decoder reads the payload. The
||| proto says the bool "is ignored"; this is that sentence with nothing left to
||| trust.
public export
lnul_2_1__null_is_the_case_not_the_payload :
  (v : Integer) -> lnul_2_1__kind_of [MkField 16 (VarintV v)] = Just SNull
lnul_2_1__null_is_the_case_not_the_payload v = Refl

--@derives [LNUL.2.1]
||| `now` is the CASE, for EVERY payload — the same shape, one field over.
|||
||| Stated separately rather than folded into the null lemma because the two
||| members are the same hazard for different reasons, and a single lemma over
||| "the ignored-payload members" would have to name that set, which is exactly
||| the thing a reader gets wrong.
public export
lnul_2_1__now_is_the_case_not_the_payload :
  (v : Integer) -> lnul_2_1__kind_of [MkField 11 (VarintV v)] = Just SNow
lnul_2_1__now_is_the_case_not_the_payload v = Refl

--@derives [LNUL.2.1]
||| `lit_bool` IS its payload — the contrast that gives the other two their
||| content.
|||
||| Without this one the module says "two bool fields are ignored" and a reader
||| may generalise to "bool payloads are ignored", which is false and is the
||| mirror-image mistake. Three members carry a `bool`; exactly one means it.
public export
lnul_2_1__bool_is_the_payload :
  (v : Integer) -> lnul_2_1__kind_of [MkField 4 (VarintV v)] = Just (SBool (v /= 0))
lnul_2_1__bool_is_the_payload v = Refl

--@derives [LNUL.2.1]
||| `null` is NOT `false`, on the wire that spells them the same.
|||
||| `lit_null` with payload 0 and `lit_bool` with payload 0 are the same three
||| bytes but for the field number, and a decoder keyed on the payload cannot
||| tell them apart. This is the refutation of that decoder, stated so the
||| hazard is in the corpus rather than in a comment — and `false` is a
||| perfectly ordinary value, so nothing downstream would ever raise it.
public export
lnul_2_1__null_is_not_false :
  Not (lnul_2_1__kind_of [MkField 16 (VarintV 0)] = Just (SBool False))
lnul_2_1__null_is_not_false Refl impossible

--@derives [LNUL.2.1]
||| A body setting no member is not an expression.
|||
||| The tempting default is `null`, and it would be the worst available: it
||| turns a producer defect into the one value [LNUL] gives Kleene semantics to,
||| so a malformed `Expr` would evaluate, propagate, and read as deliberate.
||| `Nothing` keeps it a decode failure.
public export
lnul_2_1__unset_kind_is_not_an_expression :
  lnul_2_1__kind_of [] = Nothing
lnul_2_1__unset_kind_is_not_an_expression = Refl

--@derives [LNUL.2.1]
||| A reserved number is not a member, whatever it carries: 9 was `str_cat`,
||| and a bound from 1 to 17 claimed it.
public export
lnul_2_1__reserved_number_is_not_a_member :
  (v : Integer) -> lnul_2_1__kind_of [MkField 9 (VarintV v)] = Nothing
lnul_2_1__reserved_number_is_not_a_member v = Refl

--@derives [LNUL.2.1]
||| A field of `Expr` outside the `oneof` is not a member of it, whatever it
||| carries: 19 is `json_tainted`, a property of the node, not a kind of node.
public export
lnul_2_1__field_outside_the_oneof_is_not_a_member :
  (v : Integer) -> lnul_2_1__kind_of [MkField 19 (VarintV v)] = Nothing
lnul_2_1__field_outside_the_oneof_is_not_a_member v = Refl

--@derives [LNUL.2.1]
||| A member declared past the old bound keeps its number: 20 is `interp`, here
||| under a wire type the schema does not give it, and it is not dropped.
public export
lnul_2_1__late_member_keeps_its_number :
  (v : Integer) -> lnul_2_1__kind_of [MkField 20 (VarintV v)] = Just (SUninterpreted 20)
lnul_2_1__late_member_keeps_its_number v = Refl

--@derives [LNUL.2.1]
||| A number the schema does not declare yet is unknown: 22 is the next one,
||| now that 21 is `entry_stamp`.
public export
lnul_2_1__undeclared_number_is_not_a_member :
  (v : Integer) -> lnul_2_1__kind_of [MkField 22 (VarintV v)] = Nothing
lnul_2_1__undeclared_number_is_not_a_member v = Refl

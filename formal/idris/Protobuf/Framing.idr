-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The DS two-level framing, as a total frame walk ([RFCS.19.1], [RFCS.19.2]).
|||
||| `Protobuf/Wire.idr` implements the protobuf mechanics. This is the level
||| above: the grammar [RFCS.19.1] states outright, which is DS's and not
||| Google's.
|||
|||     container   = { frame } ;      (* Dsc or Stream; type from the first atom *)
|||     frame       = outer_tag , varint_len , atom ;
|||     outer_tag   = %x0A ;           (* field 1, wire type 2 *)
|||     atom        = oneof_tag , varint_len , body ;
|||     oneof_tag   = ?varint of (field_number << 3 | 2)? ;
|||
||| So a container is a repetition of frames; each frame is the field-1 tag of
||| the container message, a length, and an `Atom`; and the atom is itself a
||| tag, a length and a body — where THAT tag's field number is the atom's
||| identity ([RFCS.16.1]).
|||
||| WHAT THE CLAUSE SAYS ITS GRAMMAR CANNOT CARRY, quoted, because each is a
||| decision this module then has to make explicitly:
|||
|||   "A partial trailing `frame` is EOF ([RFCS.19.2]); the productions cannot
|||    say that. And the container's *type* is not in the grammar at all: it is
|||    the first atom's field number ([RFCS.19.4])."
|||
||| TRUNCATION IS WHERE DS RULES AND GOOGLE DOES NOT, and the two levels get
||| different answers — which is why this is a parameter rather than a constant.
||| [RFCS.19.2]:
|||
|||   * in a `Stream` read INCREMENTALLY, a partial trailing atom "is **EOF, not
|||     an error**… it ends the container at the last **complete** atom";
|||   * a reader "whose **caller supplied the full extent** — a whole buffer —
|||     **may** instead treat a partial trailing atom as an error";
|||   * and "**This does not extend to `Dsc`** — a truncated `.dsc` remains a
|||     loader error under [RDSC.9.7]".
|||
||| A decoder with one truncation rule cannot be right about both containers, so
||| `rfcs_19_2__tail_policy` is an argument and the caller states which it is.
||| That is the clause's structure, not a generalisation invented here.
module Protobuf.Framing

import Protobuf.Wire
import Data.List

%default total

--@spec [RFCS.19.1]
||| One decoded frame: the atom's identity and its body.
|||
||| `identity` is the INNER tag's field number. [RFCS.16.1] makes that the
||| atom's identity — not a magic string, not a position — so it is the only
||| thing this level needs to hand upward.
public export
record Rfcs_19_1__frame where
  constructor MkFrame
  identity : Integer
  body     : List Bits8

--@spec [RFCS.19.2]
||| What a partial trailing frame means, which depends on the container.
|||
||| `EndOfStream` is a `Stream` read incrementally: the container ends at the
||| last complete atom. `TruncationIsError` is a `Dsc`, or a `Stream` whose
||| caller supplied the whole extent. The clause gives both and does not let a
||| decoder pick one for all cases.
public export
data Rfcs_19_2__tail_policy : Type where
  EndOfStream       : Rfcs_19_2__tail_policy
  TruncationIsError : Rfcs_19_2__tail_policy

--@spec [RFCS.19.1]
||| How a container walk ended.
|||
||| `Complete` consumed every byte. `EndedEarly` stopped at the last complete
||| frame under `EndOfStream` and reports how many bytes it left — an
||| incremental reader needs that number to resume, and a caller that asked for
||| the whole extent needs it to know the slice was wrong.
public export
data Rfcs_19_1__walk : Type where
  Complete   : List Rfcs_19_1__frame -> Rfcs_19_1__walk
  EndedEarly : List Rfcs_19_1__frame -> Nat -> Rfcs_19_1__walk
  Malformed  : List Rfcs_19_1__frame -> Rfcs_19_1__refusal -> Rfcs_19_1__walk

--@spec [RFCS.19.1]
||| The outer frame tag: `%x0A`, field 1 with wire type LEN.
|||
||| Stated as a value rather than inlined because [RFCS.19.1]'s residue note
||| turns on it: the band and tag-width rules of [RFCS.16.2] / [RFCS.16.4] are
||| about `oneof_tag`, the INNER tag — "not `outer_tag`, which is one byte for
||| every atom regardless of band".
public export
rfcs_19_1__outer_tag : Bits8
rfcs_19_1__outer_tag = 10

--@spec [RFCS.19.1]
||| Decode ONE frame: outer tag, length, then the atom inside it.
|||
||| The atom is decoded from the frame's own payload rather than from the
||| remaining input, which is what makes the two levels two levels: a frame's
||| length bounds its atom, so a lying inner length cannot reach past the frame
||| into the next one.
public export
rfcs_19_1__frame : List Bits8 -> Rfcs_19_1__decoded Rfcs_19_1__frame
rfcs_19_1__frame [] = Refuse Truncated
rfcs_19_1__frame (t :: rest) =
  if t /= rfcs_19_1__outer_tag
    then Refuse (FieldOutOfRange (cast t))
    else case rfcs_19_1__len_payload rest of
           Refuse r => Refuse r
           Yield atom after =>
             case rfcs_19_1__tag atom of
               Refuse r => Refuse r
               Yield inner afterTag =>
                 -- THE INNER TAG'S WIRE TYPE IS FIXED AT LEN, and the grammar
                 -- says so literally: `oneof_tag = ?varint of
                 -- (field_number << 3 | 2)?`. The `| 2` is not a placeholder
                 -- for "whatever the field's type implies" -- an `Atom` is a
                 -- oneof of message types, so every atom is length-delimited.
                 --
                 -- Missed on the first pass, which accepted any wire type here
                 -- and then read a length that was not one. A VARINT-tagged
                 -- "atom" would have decoded its next byte as a body length
                 -- and produced a frame out of nothing.
                 case wireType inner of
                   LEN =>
                     case rfcs_19_1__len_payload afterTag of
                       Refuse r => Refuse r
                       Yield bodyBytes _ =>
                         Yield (MkFrame (fieldNumber inner) bodyBytes) after
                   other => Refuse (BadWireType (rfcs_19_1__wire_code other))

--@spec [RFCS.19.1]
||| Walk a container: `container = { frame }`.
|||
||| TOTAL BY STRUCTURAL RECURSION ON THE INPUT. Every `rfcs_19_1__frame` returns
||| the bytes after the frame it read, and a frame is at least one byte, so the
||| remainder shrinks — but Idris cannot see that through `Rfcs_19_1__decoded`,
||| so the walk carries `fuel` and the caller supplies the input length. Fuel is
||| not a safety net here: one frame costs at least one byte, so the byte count
||| is an exact upper bound on the number of frames, and running out means the
||| decoder is wrong rather than the input being large.
public export
rfcs_19_1__walk_go : Nat -> Rfcs_19_2__tail_policy -> List Bits8 ->
                     List Rfcs_19_1__frame -> Rfcs_19_1__walk
rfcs_19_1__walk_go _ _ [] acc = Complete (reverse acc)
rfcs_19_1__walk_go Z _ left acc = Malformed (reverse acc) Truncated
rfcs_19_1__walk_go (S fuel) policy bs acc =
  case rfcs_19_1__frame bs of
    Yield f after => rfcs_19_1__walk_go fuel policy after (f :: acc)
    Refuse r =>
      case policy of
        -- [RFCS.19.2]: a partial trailing frame ends the container at the last
        -- COMPLETE atom. The frames already read are kept, which is the whole
        -- point -- an incremental reader has consumed them.
        --
        -- ONLY A SHORT TAIL. The clause's EOF is "short length or truncated
        -- body": the input ran out before the frame did. Every other refusal
        -- -- a wrong outer tag, an inner tag that is not LEN, an atom whose
        -- own length overruns a frame that HAS fully arrived -- is corruption,
        -- and a Stream refuses it exactly as a Dsc does. This read
        -- `EndedEarly` for every refusal, which is the conflation
        -- `rfcs_19_2__bad_outer_tag_is_not_eof` exists to rule out.
        EndOfStream       => if shortTail bs
                               then EndedEarly (reverse acc) (length bs)
                               else Malformed (reverse acc) r
        TruncationIsError => Malformed (reverse acc) r
  where
    -- The outer frame itself is incomplete: its tag is right and either its
    -- length varint or the bytes it announces run past the input.
    shortTail : List Bits8 -> Bool
    shortTail [] = False
    shortTail (t :: rest) =
      t == rfcs_19_1__outer_tag
        && (case rfcs_19_1__len_payload rest of
              Refuse Truncated => True
              _                => False)

--@spec [RFCS.19.1]
||| Walk a container from its bytes, under a stated truncation policy.
public export
rfcs_19_1__walk : Rfcs_19_2__tail_policy -> List Bits8 -> Rfcs_19_1__walk
rfcs_19_1__walk policy bs = rfcs_19_1__walk_go (length bs) policy bs []

--@spec [RFCS.19.4]
||| The container's TYPE: the first atom's field number.
|||
||| [RFCS.19.1] says this outright — "the container's *type* is not in the
||| grammar at all: it is the first atom's field number ([RFCS.19.4])". An empty
||| container therefore has no type, which is why this is a `Maybe` and not a
||| default: defaulting it would invent a `Dsc` out of zero bytes.
public export
rfcs_19_4__container_type : List Rfcs_19_1__frame -> Maybe Integer
rfcs_19_4__container_type []       = Nothing
rfcs_19_4__container_type (f :: _) = Just (identity f)

--@derives [RFCS.19.1]
||| An empty container is Complete with no frames — not truncated.
|||
||| The two are genuinely different: zero frames is a container that ended, and
||| a partial frame is one that did not. Conflating them is the same
||| absent-versus-empty error the wire layer refuses to make about `0x00`.
public export
rfcs_19_1__empty_container_is_complete :
  (p : Rfcs_19_2__tail_policy) -> rfcs_19_1__walk p [] = Complete []
rfcs_19_1__empty_container_is_complete p = Refl

--@derives [RFCS.19.2]
||| A frame whose outer tag is not `0x0A` is refused under EITHER policy —
||| truncation policy governs a SHORT tail, not a wrong byte.
|||
||| Worth separating because the two are easy to conflate in an implementation:
||| a reader that treated any frame-level refusal as end-of-stream would accept
||| a corrupt container as a short one, and [RFCS.19.2]'s EOF rule is about
||| running out of bytes, not about finding the wrong ones.
|||
||| QUANTIFIED OVER THE POLICY, and it has to be. Stated for
||| `TruncationIsError` alone it held by construction — that policy refuses
||| every refusal — and said nothing about the one policy the clause makes
||| tolerant. Under `EndOfStream` this model returned `EndedEarly` for this
||| input until the walk was made to ask whether the tail was short; the
||| general statement is what would have failed.
public export
rfcs_19_2__bad_outer_tag_is_not_eof :
  (p : Rfcs_19_2__tail_policy) ->
  rfcs_19_1__walk p [11, 0] = Malformed [] (FieldOutOfRange 11)
rfcs_19_2__bad_outer_tag_is_not_eof EndOfStream       = Refl
rfcs_19_2__bad_outer_tag_is_not_eof TruncationIsError = Refl

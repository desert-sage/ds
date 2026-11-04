-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Replay determinism, and why loop determinism alone does not give it
||| ([RARC.5.6.10]).
|||
||| THE CLAUSE: "If the consumption
||| loop is deterministic ([RARC.5.6.9]) **and the ambient inputs agree**,
||| replay is byte-for-byte identical. Ambient inputs are every input to the
||| record that the loop does not compute, the clock origin and the identity
||| assigned to an event among them. ... Loop determinism alone does not give
||| byte-identical replay. Two runs can agree on every value the loop
||| computed and still record different events if their clock origins
||| differ. So the engine must take no ambient input from outside the run
||| where the run can supply it: a mock clock starts at a fixed origin rather
||| than a wall-clock reading ([NLFC.5.4]), and an event's identity is derived
||| from the run ([RARC.5.8.8]) rather than drawn at random."
|||
||| WHAT IS PROVED. `rarc_5_6_10__loop_determinism_is_not_enough` is the
||| clause's warning paragraph as stated: for every value the loop computed,
||| two records whose origins differ are different. The sufficiency half --
||| loop determinism and ambient agreement give one record -- has no theorem
||| here, on purpose. It is carried by the definition `rarc_5_6_10__record`:
||| a record is built from the loop's output and the ambient values and from
||| nothing else, which is the clause's conjunction made structural. As a lemma
||| its type would be `record p amb = record p amb`, which cannot fail: a one-line
||| model has no sufficiency claim with content to make.
module Replay

%default total

--@spec [RARC.5.6.10]
||| One recorded event, split by WHO DECIDED each field.
|||
||| `payload` is what the consumption loop computed -- the part [RARC.5.6.9]'s
||| serial, monotonic discipline governs. `stamp` and `ident` are ambient: they
||| enter the record from outside the loop, and no amount of loop determinism
||| constrains them.
|||
||| The split is the entire model. Everything below follows from the fact that a
||| recorded event has fields with two different provenances, which is a fact
||| about the format rather than about any implementation.
record Rarc_5_6_10__event where
  constructor MkEvent
  payload : Nat
  stamp   : Nat
  ident   : Nat

--@spec [RARC.5.6.10]
||| The values a run takes from outside the consumption loop, the two the
||| clause names: the clock origin, which a mock clock fixes at 0
||| ([NLFC.5.4]), and the
||| event identity, which the run derives ([RARC.5.8.8]). "Defined by that property, not by a list": these
||| two stand for every input the loop does not compute.
record Rarc_5_6_10__ambient where
  constructor MkAmbient
  origin : Nat
  uuid   : Nat

--@spec [RARC.5.6.10]
||| Recording one event: the loop's output, plus the ambient values. This
||| definition IS the sufficiency half of the clause -- the record has no third
||| input -- and the header says why it is not also stated as a lemma.
rarc_5_6_10__record : (loopOutput : Nat) -> Rarc_5_6_10__ambient ->
                      Rarc_5_6_10__event
rarc_5_6_10__record p amb = MkEvent p (origin amb) (uuid amb)

--@derives [RARC.5.6.10]
||| LOOP DETERMINISM ALONE DOES NOT GIVE BYTE-IDENTICAL REPLAY: two runs that
||| agree on EVERY value the consumption loop computed still produce different
||| records when their clock origins differ -- the clause's warning paragraph.
|||
||| `p` is universally quantified, so this holds however deterministic the loop
||| is: the witness never touches `payload`. The two ambients differ only in
||| `origin`, and that alone is enough. Against the clause's first paragraph it is the necessity
||| of the ambient conjunct, which is why the clause carries one.
rarc_5_6_10__loop_determinism_is_not_enough :
  (p : Nat) ->
  Not (rarc_5_6_10__record p (MkAmbient 0 0) =
       rarc_5_6_10__record p (MkAmbient 1 0))
rarc_5_6_10__loop_determinism_is_not_enough p Refl impossible

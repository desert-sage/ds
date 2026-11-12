-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| What a verb does with a `null` argument, and the one consumer that cannot
||| be written once a stored `null` and a cache miss are one value
||| ([LNUL.11.1]).
|||
||| THE CLAUSE has one absent value, `null`, "not a separate sentinel", and a
||| table over it: `log` renders it as the empty string; `emit` and `publish`
||| put it in a slot declared `T?` and raise a `TypeError` for any other slot;
||| `call` is not made; `cache` stores it as itself. `Lnul_11_1__absent` is
||| that one value and `lnul_11_1__on_null` is the table, total over every
||| verb. A fault is no argument: it never reaches a verb ([LERR.1.4]), so no
||| outcome here stands for one.
|||
||| THE THREE OUTCOMES this module keeps apart before the clause's one `null`:
|||
|||   Value      the argument evaluated to a value.
|||   Declared   a `null` that is data: the author wrote it, or stored it.
|||   Missing    not present at all: `cached(key)` where the key was never
|||              written ([LSTO.4.3.1]). A statement about the store.
|||
||| `lnul_11_1__collapse` sends `Declared` and `Missing` to the one `null`.
||| The clause says so of the read in as many words: once `cache` has stored
||| a `null`, "a `cached(key)` miss and a stored `null` are indistinguishable
||| at the read" ([LSTO.4.3.1a]), and it calls the consequence deliberate.
||| `lnul_11_1__stored_null_reads_as_a_miss` is that sentence.
|||
||| WHAT THIS MODULE PROVES THAT A COUNTEREXAMPLE COULD NOT. Not "this
||| implementation loses the distinction" but that NO consumer can recover
||| it: `lnul_11_1__collapse_loses_the_miss` is quantified over every total
||| function from the collapsed type, and refutes all of them at once. That
||| is the shape an ITP is for, and it is why this is here rather than in
||| Alloy: a bounded search can exhibit a lossy encoding, but "no decoder
||| exists" is a statement about a function space. The clause's advice is its
||| consequence: an author who needs the two apart stores a sentinel of their
||| own choosing.
|||
||| THE CONSEQUENCE IN A RUNTIME. `ds.cache.cache_get` is `semidet` in the
||| Mercury runtime, `runtime/mercury`, so that a miss is not a value: the
||| store keeps the two apart, and `cached()` joins them at the language
||| boundary, where the clause puts the collapse.
module AbsentTrichotomy

%default total

--@spec [LNUL.11.1]
||| What reaches a consumer, with the two absences kept apart. `collapse`
||| below is the bridge to the clause's one `null`.
public export
data Lnul_11_1__outcome : Type where
  Value    : Nat -> Lnul_11_1__outcome
  Declared : Lnul_11_1__outcome
  Missing  : Lnul_11_1__outcome

--@spec [LNUL.11.1]
||| A verb's argument as the clause has it: a value, or the one `null`.
public export
data Lnul_11_1__absent : Type where
  Evaluated : Nat -> Lnul_11_1__absent
  Absent    : Lnul_11_1__absent

--@spec [LNUL.11.1]
||| "One absent value, not a separate sentinel", as a function. It is not
||| injective: `Declared` and `Missing` share an image, so nothing downstream
||| can recover which arrived.
public export
lnul_11_1__collapse : Lnul_11_1__outcome -> Lnul_11_1__absent
lnul_11_1__collapse (Value n) = Evaluated n
lnul_11_1__collapse Declared  = Absent
lnul_11_1__collapse Missing   = Absent

-- ---------------------------------------------------------------------
-- The clause's table
-- ---------------------------------------------------------------------

--@spec [LNUL.11.1]
||| The declared type of the slot an `emit` or a `publish` writes: `T?`, or
||| any other.
public export
data Lnul_11_1__slot : Type where
  Nullable    : Lnul_11_1__slot
  NonNullable : Lnul_11_1__slot

--@spec [LNUL.11.1]
||| The table's four rows. `emit` and `publish` share one, and it reads the
||| slot's declared type.
public export
data Lnul_11_1__verb : Type where
  Log      : Lnul_11_1__verb
  EmitInto : Lnul_11_1__slot -> Lnul_11_1__verb
  Call     : Lnul_11_1__verb
  Cache    : Lnul_11_1__verb

--@spec [LNUL.11.1]
||| What a verb does with its argument: it proceeds on a value, and on `null`
||| it does what its row says.
public export
data Lnul_11_1__effect : Type where
  Proceeds        : Nat -> Lnul_11_1__effect
  RendersEmpty    : Lnul_11_1__effect
  SlotTakesNull   : Lnul_11_1__effect
  RaisesTypeError : Lnul_11_1__effect
  CallNotMade     : Lnul_11_1__effect
  StoresNull      : Lnul_11_1__effect

--@spec [LNUL.11.1]
||| THE TABLE, as a total function of the verb and its argument. Every row
||| has an answer for `null`, and the answer reads nothing but the row: the
||| table is over the one absent value, whichever absence it was.
public export
lnul_11_1__on_null : Lnul_11_1__verb -> Lnul_11_1__absent -> Lnul_11_1__effect
lnul_11_1__on_null Log                    (Evaluated n) = Proceeds n
lnul_11_1__on_null Log                    Absent        = RendersEmpty
lnul_11_1__on_null (EmitInto Nullable)    (Evaluated n) = Proceeds n
lnul_11_1__on_null (EmitInto Nullable)    Absent        = SlotTakesNull
lnul_11_1__on_null (EmitInto NonNullable) (Evaluated n) = Proceeds n
lnul_11_1__on_null (EmitInto NonNullable) Absent        = RaisesTypeError
lnul_11_1__on_null Call                   (Evaluated n) = Proceeds n
lnul_11_1__on_null Call                   Absent        = CallNotMade
lnul_11_1__on_null Cache                  (Evaluated n) = Proceeds n
lnul_11_1__on_null Cache                  Absent        = StoresNull

--@derives [LNUL.11.1]
||| A `null` ARGUMENT IS AN ERROR IN ONE ROW ONLY: an `emit` or a `publish`
||| into a slot not declared `T?`. Every other row has an outcome that is not
||| a fault -- the empty string, the `null` in the slot, the call not made,
||| the `null` stored.
public export
lnul_11_1__null_raises_only_into_a_non_nullable_slot :
  (v : Lnul_11_1__verb) ->
  lnul_11_1__on_null v Absent = RaisesTypeError ->
  v = EmitInto NonNullable
lnul_11_1__null_raises_only_into_a_non_nullable_slot Log                    Refl impossible
lnul_11_1__null_raises_only_into_a_non_nullable_slot (EmitInto Nullable)    Refl impossible
lnul_11_1__null_raises_only_into_a_non_nullable_slot (EmitInto NonNullable) Refl = Refl
lnul_11_1__null_raises_only_into_a_non_nullable_slot Call                   Refl impossible
lnul_11_1__null_raises_only_into_a_non_nullable_slot Cache                  Refl impossible

-- ---------------------------------------------------------------------
-- The store consumer, and what the collapse costs it
-- ---------------------------------------------------------------------

--@spec [LNUL.11.1]
||| The STORE consumer: was the key never written?
|||
||| `Missing` alone. A `null` the author stored is a value that is there, so
||| a prune that treated it as absence would evict a live entry.
public export
lnul_11_1__is_a_miss : Lnul_11_1__outcome -> Bool
lnul_11_1__is_a_miss (Value _) = False
lnul_11_1__is_a_miss Declared  = False
lnul_11_1__is_a_miss Missing   = True

--@derives [LNUL.11.1]
||| "A `cached(key)` miss and a stored `null` are indistinguishable at the
||| read": the two collapse to one value. The clause's sentence, read back.
public export
lnul_11_1__stored_null_reads_as_a_miss : lnul_11_1__collapse Declared = lnul_11_1__collapse Missing
lnul_11_1__stored_null_reads_as_a_miss = Refl

--@derives [LNUL.11.1]
||| AND NO STORE CONSUMER CAN BE WRITTEN AFTER IT -- for ANY total function
||| from the collapsed type, not merely for the obvious ones.
|||
||| Quantified over `f`, so this is not "the implementations tried so far
||| lose the miss" but "the miss is unrecoverable". `Declared` and `Missing`
||| both collapse to `Absent` while needing opposite answers, so any `f`
||| agreeing with `is_a_miss` on both would prove `False = True`.
|||
||| THE CONSEQUENCE IN THE RUNTIME. `ds.cache.cache_get` is `semidet` rather
||| than returning a value for exactly this reason: `cached()` collapses a
||| miss into `null` at the language boundary, as [LNUL.11.1] rules, while a
||| prune must still tell a miss from a stored `null`. A store that answered
||| `null` would leave the prune nothing to read.
public export
lnul_11_1__collapse_loses_the_miss :
  (f : Lnul_11_1__absent -> Bool) ->
  Not ((x : Lnul_11_1__outcome) ->
         f (lnul_11_1__collapse x) = lnul_11_1__is_a_miss x)
lnul_11_1__collapse_loses_the_miss f agrees =
  case trans (sym (agrees Declared)) (agrees Missing) of
    Refl impossible

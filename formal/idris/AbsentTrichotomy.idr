-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Three absences collapsed into one, and the consumer that cannot be written
||| afterwards ([LNUL.11.1]).
|||
||| The clause's own claim is "An argument that cannot be evaluated is `null` —
||| ONE absent value, not a separate sentinel". This module is the finding
||| against that reading, so it models three, and `Lnul_11_1__absent` below is
||| the clause's single-`Absent` reading they collapse to.
|||
||| THE THREE, and every one of them is a state some part of DS distinguishes:
|||
|||   Declared   the author wrote `null`. An absence that is data.
|||   Declined   the artefact is valid and THIS RUNTIME would
|||              not evaluate the expression. A statement about the runtime.
|||   Missing    not present at all — `cached(key)` where the key was never
|||              written ([LSTO.4.3.1]). A statement about the store.
|||
|||
||| ⚠ THE CLAUSE IS NOT WRONG, AND SAYING SO WOULD BE THE EASY MISTAKE. Its
||| table is about ACTION VERBS, and for those three the collapse is harmless:
||| a slot takes the zero of its declared type whichever absence arrived, so
||| `collapse_keeps_the_slot_policy` below holds by construction. The clause is
||| right about the consumer it was written for.
|||
||| The defect is a consumer it was not written for. `ds.cache.cache_get` is
||| `semidet` in the Mercury runtime, `runtime/mercury`, precisely so a miss is not a value, and its
||| own comment says why: "Returning `null` here would conflate a stored `null`
||| with a miss. `cached()` makes exactly that conflation at the language
||| boundary, where libds makes it; the store keeps the two apart."
|||
||| WHAT THIS MODULE PROVES THAT A COUNTEREXAMPLE COULD NOT. Not "this
||| implementation loses the distinction" but that NO implementation can recover
||| it: `collapse_loses_the_miss` is quantified over every total function from
||| the collapsed type, and refutes all of them at once. That is the shape an
||| ITP is for, and it is why this is here rather than in Alloy — a bounded
||| search can exhibit a lossy encoding, but "no decoder exists" is a statement
||| about a function space.
|||
||| Same argument as `Rete/RateGate.idr` one level up: there a sentinel collided
||| with a valid instant, here an absence collides with two other absences. The
||| pattern is a non-injective encoding whose inverse some consumer needs.
module AbsentTrichotomy

%default total

--@spec [LNUL.11.1]
||| A value reaching a consumer, with the absences kept apart. `collapse` below
||| is the bridge to the clause's single-`Absent` type, and it is the thing
||| under test.
public export
data Lnul_11_1__outcome : Type where
  Value    : Nat -> Lnul_11_1__outcome
  Declared : Lnul_11_1__outcome
  Declined : Lnul_11_1__outcome
  Missing  : Lnul_11_1__outcome

--@spec [LNUL.11.1]
||| The clause's absent value: evaluated, or absent.
|||
||| Restated here rather than imported so this module's theorems are about its
||| own two types and reduce without reaching across a module boundary.
public export
data Lnul_11_1__absent : Type where
  Evaluated : Nat -> Lnul_11_1__absent
  Absent    : Lnul_11_1__absent

--@spec [LNUL.11.1]
||| "One absent value, not a separate sentinel", as a function.
|||
||| THIS IS THE DEFECT, WRITTEN DOWN. It is not injective — `Declared`,
||| `Declined` and `Missing` share an image — so nothing downstream can recover
||| which arrived.
public export
lnul_11_1__collapse : Lnul_11_1__outcome -> Lnul_11_1__absent
lnul_11_1__collapse (Value n) = Evaluated n
lnul_11_1__collapse Declared  = Absent
lnul_11_1__collapse Declined  = Absent
lnul_11_1__collapse Missing   = Absent

--@spec [LNUL.11.1]
||| The SLOT consumer: does this argument make the slot take the zero of its
||| declared type? The clause's `ZeroAndProceed`, as a predicate.
public export
lnul_11_1__zeroes_the_slot : Lnul_11_1__outcome -> Bool
lnul_11_1__zeroes_the_slot (Value _) = False
lnul_11_1__zeroes_the_slot Declared  = True
lnul_11_1__zeroes_the_slot Declined  = True
lnul_11_1__zeroes_the_slot Missing   = True

--@spec [LNUL.11.1]
||| The STORE consumer: was the key never written?
|||
||| `Missing` alone. A `null` the author stored is a value that is there, and a
||| a refusal is a statement about the runtime rather than about the store — so
||| a prune that treated either as absence would evict a live entry.
public export
lnul_11_1__is_a_miss : Lnul_11_1__outcome -> Bool
lnul_11_1__is_a_miss (Value _) = False
lnul_11_1__is_a_miss Declared  = False
lnul_11_1__is_a_miss Declined  = False
lnul_11_1__is_a_miss Missing   = True

--@spec [LNUL.11.1]
||| The slot consumer, rewritten to read the collapsed value.
public export
lnul_11_1__zeroes_the_slot_after : Lnul_11_1__absent -> Bool
lnul_11_1__zeroes_the_slot_after (Evaluated _) = False
lnul_11_1__zeroes_the_slot_after Absent        = True

--@derives [LNUL.11.1]
||| THE COLLAPSE IS HARMLESS FOR THE CONSUMER THE CLAUSE WAS WRITTEN FOR.
|||
||| Every outcome gets the same slot answer before and after, so `[LNUL.11.1]`'s
||| table survives its own simplification intact. Stated first and proved for
||| every outcome, because a module that only showed the loss would misrepresent
||| a clause that is right about its subject.
public export
lnul_11_1__collapse_keeps_the_slot_policy :
  (x : Lnul_11_1__outcome) ->
  lnul_11_1__zeroes_the_slot_after (lnul_11_1__collapse x)
    = lnul_11_1__zeroes_the_slot x
lnul_11_1__collapse_keeps_the_slot_policy (Value _) = Refl
lnul_11_1__collapse_keeps_the_slot_policy Declared  = Refl
lnul_11_1__collapse_keeps_the_slot_policy Declined  = Refl
lnul_11_1__collapse_keeps_the_slot_policy Missing   = Refl

--@derives [LNUL.11.1]
||| AND NO STORE CONSUMER CAN BE WRITTEN AFTER IT — for ANY total function from
||| the collapsed type, not merely for the obvious ones.
|||
||| Quantified over `f`, so this is not "the implementations tried so far lose
||| the miss" but "the miss is unrecoverable". `Declared` and `Missing` both
||| collapse to `Absent` while needing opposite answers, so any `f` agreeing
||| with `is_a_miss` on both would prove `False = True`.
|||
||| THE CONSEQUENCE IN THE RUNTIME. `ds.cache.cache_get` is `semidet` rather
||| than returning a value for exactly this reason: `cached()` collapses a miss
||| into `null` at the language boundary, as `[LNUL.11.1]` rules, while a prune
||| must still tell a miss from a stored `null`. A store that answered `null`
||| would leave the prune nothing to read.
public export
lnul_11_1__collapse_loses_the_miss :
  (f : Lnul_11_1__absent -> Bool) ->
  Not ((x : Lnul_11_1__outcome) ->
         f (lnul_11_1__collapse x) = lnul_11_1__is_a_miss x)
lnul_11_1__collapse_loses_the_miss f agrees =
  case trans (sym (agrees Declared)) (agrees Missing) of
    Refl impossible

--@derives [LNUL.11.1]
||| The same loss between the other two, so the finding is about the whole
||| trichotomy rather than about `Missing` being special.
|||
||| `Declared` is data the author wrote; `Declined` is this runtime saying it
||| would not evaluate. A consumer distinguishing them — a diagnostic, a
||| conformance report, a metric — cannot be written after the collapse either.
public export
lnul_11_1__declined_is_not_declared : Lnul_11_1__outcome -> Bool
lnul_11_1__declined_is_not_declared (Value _) = False
lnul_11_1__declined_is_not_declared Declared  = False
lnul_11_1__declined_is_not_declared Declined  = True
lnul_11_1__declined_is_not_declared Missing   = False

--@derives [LNUL.11.1]
public export
lnul_11_1__collapse_loses_the_decline :
  (f : Lnul_11_1__absent -> Bool) ->
  Not ((x : Lnul_11_1__outcome) ->
         f (lnul_11_1__collapse x) = lnul_11_1__declined_is_not_declared x)
lnul_11_1__collapse_loses_the_decline f agrees =
  case trans (sym (agrees Declined)) (agrees Declared) of
    Refl impossible

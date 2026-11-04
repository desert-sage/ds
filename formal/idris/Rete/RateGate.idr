-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The rate gate's per-key stamp (RLOW.4.6.2.2): the clause's spelling, and
||| the refused one beside it.
|||
||| THE CLAUSE. "At gate evaluation, for a key with a recorded `last_fire_ns`,
||| if `mono_ns - last_fire_ns < window_ns` the gate returns false (suppress);
||| otherwise, and always for a key with no recorded firing, it returns true
||| and records `last_fire_ns = mono_ns`. Every instant, zero included, is a
||| valid `last_fire_ns`." The theorems below are why that last sentence is there.
|||
||| WHAT IS MODELLED. `rlow_4_6_2_2__allows` is the clause's gate over the
||| stamp as an option (`Maybe Nat`): no recorded firing admits; otherwise the
||| window decides. The clause writes the test as `mono_ns - last_fire_ns <
||| window_ns` and the model as `now < last + window`; the two agree whenever
||| the stamp is at or before the instant, which it always is -- a stamp is an
||| earlier sample of the monotonic clock, which never runs back
||| ([LTIM.2.8.2]). `rlow_4_6_2_2__run` is the gate over a schedule of
||| instants, the stamp threaded so that each allowed instant becomes the
||| next stamp.
|||
||| THE REFUSED SPELLING. "No prior fire" as `last_fire_ns == 0` in a calloc'd
||| `ds_rate_entry_t`:
|||
|||     if (cooldown_ns > 0
|||         && entry->last_fire_ns != 0
|||         && now_ns < entry->last_fire_ns + cooldown_ns) { suppress }
|||
||| `0` is not outside the clock's range the way `-1` is. It is the first
||| instant of any mock clock, and `ds_clock_set(clock, 0)` reaches it in one
||| call. Under it, a run from a clock set to zero fires at t=10 where it should
||| be quiet, is quiet at t=30 where it should fire, and fires again at t=40 --
||| the windows displaced, not merely leakier. The `_sentinel` functions below transcribe that spelling,
||| `rlow_4_6_2_2__encode` is the collapse of the option onto it, and the
||| three faithfulness results say exactly where the two agree and the one
||| instant where they do not. Their ties are `partial`: they model a reading
||| the clause now rules out in so many words, and they are kept because
||| they are the reason it does.
|||
||| WHAT SHIPS. `rete/adapters.c` carries a flag beside the instant,
||| `has_fired`, in the padding after `key_hash` -- a flag rather than a
||| sentinel value, its comment says, because entries come from `DS_CALLOC`
||| and zero-init has to MEAN "never fired" -- and the same file's
||| `rate_entry_evictable` reads the same flag. The Mercury runtime keeps `maybe(uint64)`
||| (`ds.rate.m`). Both are the option spelling, which is the clause's; the
||| conformance twin `logical/LCDB.3.2.1_rgate_cool_suppress` pins it against
||| both runtimes at the one instant that broke the sentinel, and
||| `formal/k/rgate.k`'s `cool_suppress` is the same schedule on the K gate.
||| Rete/NetworkCooldown.idr threads `rlow_4_6_2_2__allows` through the
||| clocked network's firing: this
||| module's gate is the one an engine runs, and that module executes
||| `rgate.k`'s schedules on it.
|||
||| WHY THIS MODULE, AND WHY IT IS NOT Rete/FireClock.idr AGAIN. FireClock
||| models the same shape -- a cache whose empty state was once spelled as a
||| sentinel of the clock's own type -- and the clause it serves has since
||| forbidden that spelling outright; whether a clock can return `-1` was an
||| implementation question FireClock declined to answer. This is the
||| instance where the answer was yes. The general rule the pair establishes,
||| stated here because neither module can state it alone: a sentinel
||| encoding is faithful exactly when the sentinel lies outside the range of
||| the values it shares a field with. FireClock's `-1` satisfies that against
||| a live `now_ns` and fails against a harness clock; this module's `0` fails
||| against both. The theorems prove the concrete instance rather than the
||| parameterised claim -- equality on a variable does not reduce, as
||| Rete/FireClock.idr records -- and `Nat` is used throughout so `Z` versus
||| `S k` is a STRUCTURAL case split and the proofs go through by `Refl`.
|||
||| ⚠ TWO CONSUMERS OF THE SAME ENCODING, and the second was worse. The gate
||| reads it to decide; the rate table's eviction (`rate_entry_evictable` in
||| `rete/adapters.c`, reached from `rate_find`) reads it to decide EVICTION,
||| so under the sentinel an entry that fired at instant zero reports itself
||| unfired and can be freed mid-window. Both consumers read the flag. The rate
||| table is the one live consumer of the property.
module Rete.RateGate

%default total

--@spec [RLOW.4.6.2.2]
||| The cooldown stamp: the instant of the last allowed fire, or nothing yet.
|||
||| `Maybe Nat`, so absence is not a number and cannot be confused with an
||| instant -- "every instant, zero included, is a valid `last_fire_ns`".
||| `Nat` rather than `Integer` because the proofs need `Z` and `S k` to be a
||| structural case split; instants are non-negative anyway, which is what
||| makes the restriction free rather than an idealisation.
public export
Rlow_4_6_2_2__stamp : Type
Rlow_4_6_2_2__stamp = Maybe Nat

--@spec [RLOW.4.6.2.2]
||| THE GATE, as the clause has it: a key with no recorded firing admits;
||| otherwise the window decides, `now < last + window` suppressing. The
||| clause's `mono_ns - last_fire_ns < window_ns` is this test whenever the
||| stamp is at or before the instant, which a stamp always is: it is an
||| earlier sample of the monotonic clock ([LTIM.2.8.2]).
public export
rlow_4_6_2_2__allows : (window, now : Nat) -> Rlow_4_6_2_2__stamp -> Bool
rlow_4_6_2_2__allows _      _   Nothing     = True
rlow_4_6_2_2__allows window now (Just last) = not (now < last + window)

--@spec [RLOW.4.6.2.2]
||| THE REFUSED SPELLING: the same gate over one `Nat`, where `Z` means
||| "never fired" (`entry->last_fire_ns != 0`), which is what the clause's "every instant, zero included, is a valid
||| `last_fire_ns`" rules out.
|||
||| Transcribed as a case split on `Z` / `S k` rather than as `last == 0`,
||| which is the same function and reduces.
public export
rlow_4_6_2_2__allows_sentinel : (window, now, last : Nat) -> Bool
rlow_4_6_2_2__allows_sentinel _      _   Z     = True
rlow_4_6_2_2__allows_sentinel window now (S k) = not (now < S k + window)

--@spec [RLOW.4.6.2.2]
||| How the refused field stored the honest stamp: absence became zero.
|||
||| This function is the defect, and writing it down is the point. It is not
||| injective -- `Nothing` and `Just Z` have the same image -- so no reader of
||| the field can recover which one was stored.
public export
rlow_4_6_2_2__encode : Rlow_4_6_2_2__stamp -> Nat
rlow_4_6_2_2__encode Nothing  = Z
rlow_4_6_2_2__encode (Just n) = n

--@derives [RLOW.4.6.2.2]
||| FAITHFUL ON ABSENCE. A key that has never fired decides the same either way.
public export
rlow_4_6_2_2__faithful_on_absence :
  (window, now : Nat) ->
  rlow_4_6_2_2__allows window now Nothing
    = rlow_4_6_2_2__allows_sentinel window now (rlow_4_6_2_2__encode Nothing)
rlow_4_6_2_2__faithful_on_absence _ _ = Refl

--@derives [RLOW.4.6.2.2]
||| FAITHFUL ON EVERY STAMP THE SENTINEL DOES NOT COLLIDE WITH -- quantified over
||| the window, the instant and every non-zero stamp.
|||
||| The half that says the encoding is nearly right, and the reason the defect
||| survived: every fire at a non-zero instant behaves identically, so any test
||| whose clock has moved at all passes.
public export
rlow_4_6_2_2__faithful_above_zero :
  (window, now, k : Nat) ->
  rlow_4_6_2_2__allows window now (Just (S k))
    = rlow_4_6_2_2__allows_sentinel window now (rlow_4_6_2_2__encode (Just (S k)))
rlow_4_6_2_2__faithful_above_zero _ _ _ = Refl

--@derives [RLOW.4.6.2.2]
||| AND NOT FAITHFUL ON A FIRE AT INSTANT ZERO, which is the whole finding, and
||| the clause's sentence.
|||
||| A rule that fires at `t = 0` stores `Just Z`, the field holds `Z`, and the
||| next evaluation reads `Z` as "never fired" -- so the cooldown allows where it
||| must suppress. Stated as a refutation rather than as an inequality of
||| booleans so that what fails is the CLAIM OF FAITHFULNESS, at the one input
||| that breaks it.
|||
||| `window = 1`, `now = 0`: the honest gate suppresses (0 is inside a window of
||| 1 opened at 0) and the sentinel gate allows. Any positive window and any
||| instant inside it does the same; one witness is what a refutation needs.
public export
rlow_4_6_2_2__zero_stamp_is_lost :
  Not (rlow_4_6_2_2__allows 1 0 (Just 0)
        = rlow_4_6_2_2__allows_sentinel 1 0 (rlow_4_6_2_2__encode (Just 0)))
rlow_4_6_2_2__zero_stamp_is_lost Refl impossible

--@spec [RLOW.4.6.2.2]
||| The verdicts a schedule of activation instants produces, under the
||| clause's spelling, for a rule with a cooldown.
|||
||| Threaded rather than folded so the STAMP is visible: each allowed instant
||| becomes the next stamp -- "records `last_fire_ns = mono_ns`" -- which is
||| the step the refused encoding loses at zero.
public export
rlow_4_6_2_2__run : (window : Nat) -> Rlow_4_6_2_2__stamp -> List Nat -> List Bool
rlow_4_6_2_2__run _      _    []          = []
rlow_4_6_2_2__run window last (now :: ts) =
  let ok = rlow_4_6_2_2__allows window now last in
  ok :: rlow_4_6_2_2__run window (if ok then Just now else last) ts

--@spec [RLOW.4.6.2.2]
||| The same schedule under the refused field.
public export
rlow_4_6_2_2__run_sentinel : (window, last : Nat) -> List Nat -> List Bool
rlow_4_6_2_2__run_sentinel _      _    []          = []
rlow_4_6_2_2__run_sentinel window last (now :: ts) =
  let ok = rlow_4_6_2_2__allows_sentinel window now last in
  ok :: rlow_4_6_2_2__run_sentinel window (if ok then now else last) ts

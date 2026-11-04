-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The activation key's composition, and the rule-wide suppression window a
||| keyless schema reaches ([LCDB.3.3.3], [LCDB.7.2]).
|||
||| `[LCDB.3.3.3]` — "a `logical` fact contributes its declared `key` slots. A
||| schema whose key is ∅ (every slot `mutable`) contributes nothing, so a
||| single-pattern rule on such a schema is rule-global (the
||| `AmbientTemp{ts mutable, celsius mutable}` case)" … "when no bound fact
||| contributes a slot, the key is empty and the cooldown is rule-global."
|||
||| `[LCDB.7.2]` — "Suppression is keyed on `(rule, activation_key)`, and there
||| is no `global` modifier. The grammar offers no rule-wide variant to write.
||| ⚠ Rule-wide suppression is nevertheless REACHABLE, with no modifier and no
||| author opt-in. A schema with no `key` slot … gives every activation the
||| empty activation key, so `(rule, [])` is one window for the whole rule."
|||
||| WHAT THIS MODULE ESTABLISHES is the second clause's ⚠ paragraph, from the
||| first clause's composition rule: `every_activation_shares_one_key` shows
||| that every activation of a single-pattern rule over an all-`mutable`
||| schema has the empty key, so one suppression window covers the rule. The
||| grammar half — no `global` modifier — is true and untouched here. Its one
||| conformance fixture (`specs/conformance/compiler/LCDB.7.2.json`,
||| `compile_ok`) pins that half and cannot see this one, which is why the
||| theorem is worth having.
|||
||| `[LCDB.7.2]` states the reachable window, and this module proves it from
||| `[LCDB.3.3.3]`. What remains open is the question the clause poses itself:
||| whether the reachable window is WANTED, or a trap for an author who never
||| chose a key.
|||
||| WHERE THE THEOREM'S FORCE LIVES, stated so the `Refl` below is not
||| mistaken for it. `every_activation_shares_one_key` reduces to `[] = []`:
||| the key of an all-`mutable` schema is empty by `[LCDB.3.3.3]`'s own
||| composition, and the lemma checks that composition on the clause's worked
||| example. The step from "one key for every activation" to "rule-wide
||| suppression exists" is a READING — suppression is keyed on
||| `(rule, activation_key)` — and it is the reading, not the equation, that
||| `[LCDB.7.2]` now states. The equation is what makes the reading checkable
||| by anyone with the two clauses in front of them.
|||
||| `Nat` for bound values, for `Rete/RateGate.idr`'s reason: the proofs need a
||| structural case split, and a type whose equality is primitive does not
||| reduce for a variable.
module Lcdb.RuleGlobal

%default total

--@spec [LCDB.3.3.3]
||| A logical schema's slot, by the identity role that decides whether it
||| contributes to the activation key.
|||
||| Two constructors and not three: `[LCDB.3.3.3]` splits `logical` facts on
||| `key` versus everything else, and `mutable` is what "everything else" is
||| called. A `ttl` / event fact takes the other branch of the clause entirely
||| — it "carries no identity markers ([LFAC.1.7.6]) and contributes the slots
||| it binds" — which is a different function, not a third role.
public export
data Lcdb_3_3_3__slot = SlotKey | SlotMutable

--@spec [LCDB.3.3.3]
||| One bound fact of an activation: each slot's role paired with the value
||| bound in this activation.
|||
||| Zipped rather than two lists, so a role and its value cannot drift apart —
||| the failure this whole clause is about is a key that says less than the
||| author thinks, and a model that could mis-pair them would be able to
||| reproduce it for the wrong reason.
public export
Lcdb_3_3_3__fact : Type
Lcdb_3_3_3__fact = List (Lcdb_3_3_3__slot, Nat)

--@spec [LCDB.3.3.3]
||| What one `logical` fact contributes: its declared `key` slots, in
||| declaration order.
public export
lcdb_3_3_3__contributes : Lcdb_3_3_3__fact -> List Nat
lcdb_3_3_3__contributes []                     = []
lcdb_3_3_3__contributes ((SlotKey, v)  :: rest) = v :: lcdb_3_3_3__contributes rest
lcdb_3_3_3__contributes ((SlotMutable, _) :: rest) = lcdb_3_3_3__contributes rest

--@spec [LCDB.3.3.3]
||| The activation key: "the ordered concatenation, per bound pattern in source
||| order, of each fact's contributing slots".
public export
lcdb_3_3_3__key : List Lcdb_3_3_3__fact -> List Nat
lcdb_3_3_3__key []        = []
lcdb_3_3_3__key (f :: fs) = lcdb_3_3_3__contributes f ++ lcdb_3_3_3__key fs

--@spec [LCDB.3.3.3]
||| The clause's own worked example: `AmbientTemp{ts mutable, celsius mutable}`,
||| bound in a single-pattern rule.
|||
||| A function of the two values, so a theorem about it is a theorem about every
||| activation of that rule rather than about one reading.
public export
lcdb_3_3_3__ambient_temp : (ts, celsius : Nat) -> List Lcdb_3_3_3__fact
lcdb_3_3_3__ambient_temp ts celsius =
  [[(SlotMutable, ts), (SlotMutable, celsius)]]

--@derives [LCDB.3.3.3]
||| A schema whose key is ∅ contributes nothing — for any number of slots and
||| any values in them.
|||
||| Quantified over the value list rather than shown on the two-slot example,
||| because "every slot `mutable`" is a property of schemas of any width and an
||| example would leave the general case unproved.
public export
lcdb_3_3_3__all_mutable_contributes_nothing :
  (vs : List Nat) ->
  lcdb_3_3_3__contributes (map (\v => (SlotMutable, v)) vs) = []
lcdb_3_3_3__all_mutable_contributes_nothing []        = Refl
lcdb_3_3_3__all_mutable_contributes_nothing (_ :: vs) =
  lcdb_3_3_3__all_mutable_contributes_nothing vs

--@derives [LCDB.3.3.3]
||| So the clause's own example has the empty key, whatever it binds.
public export
lcdb_3_3_3__ambient_temp_key_is_empty :
  (ts, celsius : Nat) -> lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp ts celsius) = []
lcdb_3_3_3__ambient_temp_key_is_empty _ _ = Refl

--@derives [LCDB.3.3.3]
--@derives [LCDB.7.2]
||| THE REACHABLE RULE-WIDE WINDOW `[LCDB.7.2]` now states. Any two activations
||| of that rule share one activation key — quantified over both readings of
||| both, so no pair of activations anywhere is distinguishable.
|||
||| Suppression is keyed on `(rule, activation_key)`. One key for every
||| activation IS one window for the whole rule, which is what "rule-wide"
||| names. Nothing about the author's intent enters: they cannot express a
||| per-instance window on this schema, because there is no instance to be per.
|||
||| The author does not opt in. `[LCDB.7.2]` offers a logical-fact sentinel as
||| the way to express this behaviour deliberately; `[LCDB.3.3.3]` hands it to
||| anyone whose schema happens to have no `key` slot, which is the default for
||| a schema written without identity in mind. Whether that is wanted is the
||| owner question the clause leaves open.
public export
lcdb_3_3_3__every_activation_shares_one_key :
  (ts, celsius, ts', celsius' : Nat) ->
  lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp ts celsius)
    = lcdb_3_3_3__key (lcdb_3_3_3__ambient_temp ts' celsius')
lcdb_3_3_3__every_activation_shares_one_key _ _ _ _ = Refl

--@derives [LCDB.3.3.3]
||| THE FALSIFIABILITY CONTROL, and the theorem above is worthless without it.
|||
||| A schema WITH a `key` slot separates activations that differ in it. If this
||| did not hold, the model would be collapsing every activation to one key for
||| a reason of its own and `every_activation_shares_one_key` would say nothing
||| about `[LCDB.3.3.3]`.
|||
||| Stated from an arbitrary inequality rather than on two literals, so it is
||| the general property — distinct key values give distinct keys — rather than
||| one pair that happens to differ.
public export
lcdb_3_3_3__a_keyed_schema_separates :
  (a, b : Nat) -> Not (a = b) ->
  Not (lcdb_3_3_3__key [[(SlotKey, a)]] = lcdb_3_3_3__key [[(SlotKey, b)]])
lcdb_3_3_3__a_keyed_schema_separates _ _ contra Refl = contra Refl

--@derives [LCDB.3.3.3]
||| And a `mutable` slot beside a `key` one does not weaken it: the key is the
||| key slots and nothing else, so a churning `mutable` value cannot reset a
||| window.
|||
||| `[LCDB.3.3.1]`'s fix, as a consequence of `[LCDB.3.3.3]`'s composition
||| rather than as a separate rule — and this matters because
||| `RLOW.4.6.2.3`'s "the tuple of all LHS binding values" would put the
||| churning value in the key and destroy exactly this property.
public export
lcdb_3_3_3__mutable_does_not_enter_the_key :
  (id, reading, reading' : Nat) ->
  lcdb_3_3_3__key [[(SlotKey, id), (SlotMutable, reading)]]
    = lcdb_3_3_3__key [[(SlotKey, id), (SlotMutable, reading')]]
lcdb_3_3_3__mutable_does_not_enter_the_key _ _ _ = Refl

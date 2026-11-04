/-
  SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
  SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later

  DS null semantics — the Kleene 3-valued predicate logic, in Lean 4.

  A RESTATEMENT of formal/alloy/kleene_logic.als, and the first Lean in this
  repository: Lean is enabled here, not adopted. Same tables, same laws, same
  names (<clause>__<tag>, as the Alloy model and the conformance suite name
  them). What changes is the claim. Alloy checks each law over every
  assignment within `for 3`; here each is a theorem, proved by exhausting the
  three values. The domain is finite, so the two agree — but this is the
  version that says so without a scope.

  It also states, as theorems, what issue #1321 measured about the Alloy
  model's TEETH comment: which one-cell flip of the tables breaks which law.
  Those rows were found by running Alloy on mutants; here they are proved.

  Core Lean only: no Mathlib, no Lake. `lean formal/lean/Kleene.lean` checks it.
-/

namespace Ds.Kleene

/-- @spec [LNUL.4.2] The 3-valued truth domain: true, false, and the one
canonical null ([LNUL.2.1]) read as "unknown". -/
inductive Tri where
  | tt
  | ff
  | null
  deriving DecidableEq, Repr

open Tri

/-- @spec [LNUL.4.1] A value operation with a null operand yields null. (`tt`
stands for any non-null result, as in the Alloy model.) -/
def valueOp : Tri → Tri → Tri
  | null, _ => null
  | _, null => null
  | _, _ => tt

/-- @spec [LNUL.4.2] Kleene AND: false dominates; else null is contagious. -/
def and3 : Tri → Tri → Tri
  | ff, _ => ff
  | _, ff => ff
  | null, _ => null
  | _, null => null
  | tt, tt => tt

/-- @spec [LNUL.4.2] Kleene OR: true dominates; else null is contagious. -/
def or3 : Tri → Tri → Tri
  | tt, _ => tt
  | _, tt => tt
  | null, _ => null
  | _, null => null
  | ff, ff => ff

/-- @spec [LNUL.4.2] Kleene NOT: swaps true and false, fixes null. -/
def not3 : Tri → Tri
  | tt => ff
  | ff => tt
  | null => null

/-- @spec [LNUL.4.3] A `where` fires iff it evaluates to true. -/
def fires (a : Tri) : Bool := a == tt

/-- @spec [LNUL.4.4] A null-test is total: true or false, never null. -/
def isNull : Tri → Tri
  | null => tt
  | _ => ff

/-- @spec [LNUL.5.3] Coalesce `x ?? d`. -/
def coalesce : Tri → Tri → Tri
  | null, d => d
  | x, _ => x

/-! ## The laws — kleene_logic.als's assertions, as theorems -/

/-- @probe Kleene refines propagation: a null operand does not always yield
null (`false and null = false`, `true or null = true`). -/
theorem probe__kleene_refines_propagation :
    and3 ff null = ff ∧ or3 tt null = tt := ⟨rfl, rfl⟩

/-- @spec [LNUL.4.1] -/
theorem lnul_4_1__value_propagates_null (a b : Tri) (h : a = null ∨ b = null) :
    valueOp a b = null := by
  cases a <;> cases b <;> simp_all [valueOp]

/-- @derives [LNUL.4.2] De Morgan over all three values. -/
theorem lnul_4_2__de_morgan (a b : Tri) :
    not3 (and3 a b) = or3 (not3 a) (not3 b) := by
  cases a <;> cases b <;> rfl

/-- @derives [LNUL.4.2] Involutive negation. -/
theorem lnul_4_2__double_negation (a : Tri) : not3 (not3 a) = a := by
  cases a <;> rfl

/-- @derives [LNUL.4.2] Commutativity of Kleene and/or. -/
theorem lnul_4_2__and_or_commutative (a b : Tri) :
    and3 a b = and3 b a ∧ or3 a b = or3 b a := by
  cases a <;> cases b <;> exact ⟨rfl, rfl⟩

/-- @derives [LNUL.4.3] The safety collapse: null fires neither positively nor
under negation. -/
theorem lnul_4_3__null_never_fires :
    fires null = false ∧ fires (not3 null) = false := ⟨rfl, rfl⟩

/-- @derives [LNUL.4.4] -/
theorem lnul_4_4__null_test_total (a : Tri) : isNull a ≠ null := by
  cases a <;> decide

/-- @derives [LNUL.5.3] A non-null default makes coalesce non-null. -/
theorem lnul_5_3__coalesce_non_null (x d : Tri) (h : d ≠ null) :
    coalesce x d ≠ null := by
  cases x <;> simp [coalesce] <;> exact h

/-! ## Teeth — issue #1321, proved

Each law is only evidence if a wrong table would break it. These are the
three one-cell flips #1321 ran as Alloy mutants, with the laws each breaks
and the laws each leaves standing — the second half being what the Alloy
model's comment had wrong. -/

/-- `not null = false`: the flip kleene_logic.als's TEETH comment names. -/
def not3NullFalse : Tri → Tri
  | tt => ff
  | ff => tt
  | null => ff

/-- `not null = true`: null read as false, then negated. -/
def not3NullTrue : Tri → Tri
  | tt => ff
  | ff => tt
  | null => tt

/-- `false and null = null`: pure propagation, false dominant only otherwise. -/
def and3Propagating : Tri → Tri → Tri
  | null, _ => null
  | _, null => null
  | ff, _ => ff
  | _, ff => ff
  | tt, tt => tt

/-- `not null = false` does NOT break De Morgan… -/
theorem teeth__not_null_false_keeps_de_morgan (a b : Tri) :
    not3NullFalse (and3 a b) = or3 (not3NullFalse a) (not3NullFalse b) := by
  cases a <;> cases b <;> rfl

/-- …nor the safety collapse… -/
theorem teeth__not_null_false_keeps_null_never_fires :
    fires null = false ∧ fires (not3NullFalse null) = false := ⟨rfl, rfl⟩

/-- …only involution, at null — Alloy's witness `a = Null`. -/
theorem teeth__not_null_false_breaks_double_negation :
    not3NullFalse (not3NullFalse null) ≠ null := by decide

/-- `not null = true` fires the negated rule on an unknown value: the
null-as-false reading, and what `lnul_4_3__null_never_fires` exists to catch. -/
theorem teeth__not_null_true_breaks_null_never_fires :
    fires (not3NullTrue null) = true := rfl

/-- `false and null = null` breaks De Morgan, at `a = null, b = false` —
Alloy's witness. -/
theorem teeth__propagating_and_breaks_de_morgan :
    not3 (and3Propagating null ff) ≠ or3 (not3 null) (not3 ff) := by decide

end Ds.Kleene

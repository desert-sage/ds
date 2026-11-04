-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| A deterministic, executable model of the DS fire loop, built to answer
||| termination questions.
|||
||| NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked
||| by the crossref and the [STYL.5.5.4] gates: every element is
||| named `<clause-id>__<tag>` after the paragraph it formalizes (a type-level
||| name carries one capital, `Iret_11__tok`; a value-level name stays
||| lowercase, `iret_11_4__step`), and the `--@spec` / `--@derives` marker on
||| the line above names the clause so the checker can confirm the id exists
||| and matches the name. An element whose home clause does not exist yet is
||| marked `--@gap` and named `gap__<tag>` instead; none is in this file. The
||| lane's gaps — the `withdraw` action's admission rule and the `+recursive`
||| witnesses —
||| are in Lcyc/Witnesses.idr, Lcyc/WitnessProofs.idr and Lcyc/Termination.idr.
|||
||| The list helpers tagged [RARC.5.6.5] (`rarc_5_6_5__any`, `_elem`, `_find`,
||| `_nth`, `_set_at`, `_concat_map`) and `lcyc_1_1__sum_by` are plumbing
||| named under the clause they serve, not formalizations of it; their
||| `checks` entries carry `role: definition` for that reason.
|||
||| WHAT IS MODELLED, and the clause each choice is read from:
|||
|||   * ORDER. One activation fires at a time; the next to fire is the
|||     lowest terminal ordinal (= rule source order) with a pending
|||     activation, and among that rule's activations the earliest-created
|||     [LDET.5.1] [LDET.5.4] [LDET.5.5]. Salience is gone from the
|||     language and is not modelled.
|||   * POP ON FIRE. A fired activation leaves the agenda [IRET.11.4 1a]. It
|||     comes back only if Rete re-propagates its token: a NOT release, or a
|||     constituent re-asserted under a new fact id. The refraction set of
|||     [IRET.11.3] is cleared on every real WM change [IRET.11.3.2], so
|||     between two WM changes nothing can re-propagate and the set is
|||     unobservable here; `fired` on a token is the whole of it
|||     [IDAT.6.2.2].
|||   * NOT RELEASE KEEPS ITS PLACE. A token blocked by a `no` pattern keeps
|||     its creation timetag and fires, once released, in its original
|||     position [LDET.5.9]. Modelled as: a rule's tokens are a list in
|||     creation order; blocking never moves an entry; release only clears
|||     `fired`.
|||   * TOKEN IDENTITY = tuple of participating fact ids [IRET.11.3]. A
|||     `no` pattern contributes no fact to the tuple [IRET.7.9.5]; a rule
|||     whose LHS is only `no` patterns has exactly one token, the empty
|||     tuple, from the start.
|||   * IMMEDIATE PROPAGATION. Every emit / withdraw reaches Rete before the
|||     next action of the same RHS.
|||     The running RHS keeps its bindings even if it withdraws them.
|||   * LIFECYCLES [LFAC.2.6.1] [LFAC.1.7.2] [LSCP.2.1.1], as the runtime
|||     implements them (schema_reg.c: `id_dedup` is true only for
|||     role-marked schemas):
|||       Explicit — every emit is a NEW fact, whatever its slot values.
|||                  This is the only lifecycle `withdraw` may target.
|||       Relation — `logical`, key = all slots: an emit whose value is
|||                  already live is a no-op.
|||       Entity   — `logical` with a payload: same key + same payload is a
|||                  no-op; same key + new payload RETRACTS the old fact and
|||                  asserts a new one [LFAC.2.5.3].
|||     Truth maintenance (justifier-end retraction of `logical` facts) is
|||     NOT in this model; Rete.Refcount.idr covers it separately, and the
|||     certificate module states where that omission bites.
|||   * FACT IDS are the smallest free natural. DS mints monotonically
|||     [IDAT.4.4]; the two agree on every observable of this model, since
|||     only id EQUALITY is ever consulted, an id is reused only after every
|||     token holding it has been dropped by the propagation that followed
|||     its withdrawal, and reuse is what lets a looping run return to a
|||     LITERALLY equal state so Lcyc.Witnesses.idr can prove
|||     divergence by two `Refl`s.
|||
||| WHAT IS NOT MODELLED: time (`within`, `ttl`, `after`), `call` /
||| `CallResponse`, cache, `latest`, `then`, `scope activation`,
||| cross-tier `publish`, cooldown, and the TMS. Each is placed
||| in the characterization document as either an additional "removal" or
||| an additional "fresh production" for the certificate.
|||
||| WHAT THIS FILE RELIES ON BUT DOES NOT ESTABLISH:
|||
|||   * ONE TOKEN TABLE PER RULE. `iret_11_4__step` answers `Nothing`
|||     (quiescent) when a rule or token index is out of range, and
|||     `rarc_5_6_5__propagate` zips rules with tables, so both are faithful
|||     only when `length (toks st) = length (rules p)`. `rarc_5_6_5__init_state`
|||     establishes it and every action preserves it; the invariant is stated
|||     and carried as `tokLen` of `Lcyc_1_1__inv` in Lcyc/Certificate.idr. A
|||     state written out by hand, as the witness proofs do, must satisfy it.
|||   * FACT-ID REUSE IS UNOBSERVABLE. The FACT IDS argument above is a
|||     fidelity argument about this model against DS, made in prose; no
|||     proof in this lane states it. `iret_8_1__kept_of` matches tokens to
|||     tuples by fact ids alone, so the claim that a token never outlives
|||     the withdrawal of a fact it holds is what makes that sound.
|||
||| This file is the model and carries no proofs. The lemmas about runs
||| (`iret_11_4__step_n_plus`, `_prefix`, `lcyc_1_1__periodic_diverges`) are
||| in Lcyc/WitnessProofs.idr, next to the witnesses that use them.
module Rete.FireLoop

import Data.List
import Data.Maybe
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Facts and working memory
-- ---------------------------------------------------------------------

--@spec [LFAC.1.7.1]
||| A live fact. Slot values are abstracted to a (key, payload) pair of
||| naturals: enough to distinguish the three lifecycles and to write
||| joins (`fkey a == fkey b`) and value-generating emits (`fpay + 1`).
public export
record Lfac_1_7_1__fact where
  constructor MkFact
  fid   : Nat
  fkind : Nat
  fkey  : Nat
  fpay  : Nat

--@spec [LFAC.2.5.4]
||| Field-wise equality, parenthesised explicitly so a proof can peel the
||| conjuncts without knowing `&&`'s fixity.
public export
lfac_2_5_4__same_fact : Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool
lfac_2_5_4__same_fact a b = (fid a == fid b) && ((fkind a == fkind b) && ((fkey a == fkey b) && (fpay a == fpay b)))

public export
Eq Lfac_1_7_1__fact where
  a == b = lfac_2_5_4__same_fact a b

--@spec [RARC.5.6.5]
||| `concatMap`, `any`, `elem` and `find` restricted to lists, by
||| structural recursion, so that proofs can unfold them without going
||| through `Foldable`.
public export
rarc_5_6_5__concat_map : (a -> List b) -> List a -> List b
rarc_5_6_5__concat_map f [] = []
rarc_5_6_5__concat_map f (x :: xs) = f x ++ rarc_5_6_5__concat_map f xs

--@spec [RARC.5.6.5]
public export
rarc_5_6_5__any : (a -> Bool) -> List a -> Bool
rarc_5_6_5__any p [] = False
rarc_5_6_5__any p (x :: xs) = if p x then True else rarc_5_6_5__any p xs

--@spec [RARC.5.6.5]
public export
rarc_5_6_5__elem : Eq a => a -> List a -> Bool
rarc_5_6_5__elem x [] = False
rarc_5_6_5__elem x (y :: ys) = if y == x then True else rarc_5_6_5__elem x ys

--@spec [RARC.5.6.5]
public export
rarc_5_6_5__find : (a -> Bool) -> List a -> Maybe a
rarc_5_6_5__find p [] = Nothing
rarc_5_6_5__find p (x :: xs) = if p x then Just x else rarc_5_6_5__find p xs

--@spec [RARC.5.6.5]
public export
rarc_5_6_5__nth : Nat -> List a -> Maybe a
rarc_5_6_5__nth _ [] = Nothing
rarc_5_6_5__nth Z (x :: _) = Just x
rarc_5_6_5__nth (S n) (_ :: xs) = rarc_5_6_5__nth n xs

--@spec [LCYC.1.1]
public export
lcyc_1_1__sum_by : (a -> Nat) -> List a -> Nat
lcyc_1_1__sum_by f [] = 0
lcyc_1_1__sum_by f (x :: xs) = f x + lcyc_1_1__sum_by f xs

--@spec [LFAC.2.5.1]
public export
lfac_2_5_1__val : Lfac_1_7_1__fact -> (Nat, Nat)
lfac_2_5_1__val f = (fkey f, fpay f)

--@spec [LFAC.2.5.1]
public export
lfac_2_5_1__same_val : (Nat, Nat) -> (Nat, Nat) -> Bool
lfac_2_5_1__same_val (a, b) (c, d) = (a == c) && (b == d)

public export
Show Lfac_1_7_1__fact where
  show f = "#" ++ show (fid f) ++ ":" ++ show (fkind f) ++ "(" ++ show (fkey f) ++ "," ++ show (fpay f) ++ ")"

--@spec [RARC.5.6.4]
public export
Rarc_5_6_4__wm : Type
Rarc_5_6_4__wm = List Lfac_1_7_1__fact

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__facts_of_kind : Nat -> Rarc_5_6_4__wm -> List Lfac_1_7_1__fact
rarc_5_6_4__facts_of_kind k = filter (\f => fkind f == k)

--@spec [RARC.5.6.4]
||| A change confined to kind `k`: every other kind's facts are unchanged.
||| What every emit and withdraw satisfies, and what the termination
||| measure's per-stratum locality (Lcyc/) rests on.
public export
Rarc_5_6_4__frame : Nat -> Rarc_5_6_4__wm -> Rarc_5_6_4__wm -> Type
Rarc_5_6_4__frame k wm wm' = (k' : Nat) -> Not (k' = k) -> rarc_5_6_4__facts_of_kind k' wm' = rarc_5_6_4__facts_of_kind k' wm

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__count_kind : Nat -> Rarc_5_6_4__wm -> Nat
rarc_5_6_4__count_kind k wm = length (rarc_5_6_4__facts_of_kind k wm)

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__lookup_fact : Nat -> Rarc_5_6_4__wm -> Maybe Lfac_1_7_1__fact
rarc_5_6_4__lookup_fact i [] = Nothing
rarc_5_6_4__lookup_fact i (f :: fs) = if fid f == i then Just f else rarc_5_6_4__lookup_fact i fs

--@spec [RARC.5.6.4]
public export
rarc_5_6_4__is_live : Nat -> Rarc_5_6_4__wm -> Bool
rarc_5_6_4__is_live i wm = case rarc_5_6_4__lookup_fact i wm of
  Just _  => True
  Nothing => False

--@spec [LFAC.2.5.3]
||| Smallest natural neither used as a live fact id nor in `avoid`.
||| Bounded search: among the first `length wm + length avoid + 1`
||| naturals at least one qualifies.
public export
lfac_2_5_3__fresh_from : Nat -> Nat -> List Nat -> Rarc_5_6_4__wm -> Nat
lfac_2_5_3__fresh_from Z     cand avoid wm = cand
lfac_2_5_3__fresh_from (S n) cand avoid wm =
  if rarc_5_6_4__is_live cand wm || rarc_5_6_5__elem cand avoid then lfac_2_5_3__fresh_from n (S cand) avoid wm else cand

--@spec [LFAC.2.5.3]
||| `avoid` carries the ids bound by the RHS currently running: a binding
||| withdrawn earlier in the same RHS must not have its id handed to a
||| fact emitted later in it, or a second `withdraw` of that binding would
||| remove the wrong fact. DS never reuses an id [IDAT.4.4]; this is the
||| one place reuse could be observed, so it is excluded here.
public export
lfac_2_5_3__fresh_id : List Nat -> Rarc_5_6_4__wm -> Nat
lfac_2_5_3__fresh_id avoid wm = lfac_2_5_3__fresh_from (S (length wm + length avoid)) 0 avoid wm

-- ---------------------------------------------------------------------
-- Lifecycles and assertion
-- ---------------------------------------------------------------------

--@spec [LSCP.1.3]
--@spec [LFAC.1.7.2]
public export
data Lscp_1_3__lifecycle = Explicit | Relation | Entity

public export
Eq Lscp_1_3__lifecycle where
  Explicit == Explicit = True
  Relation == Relation = True
  Entity   == Entity   = True
  _        == _        = False

--@spec [IRET.19.1]
||| A live fact of kind `k` with the same value (Relation) or the same
||| key (Entity).
public export
iret_19_1__find_relation : Nat -> Nat -> Nat -> Rarc_5_6_4__wm -> Maybe Lfac_1_7_1__fact
iret_19_1__find_relation k key pay wm = rarc_5_6_5__find (\f => (fkind f == k) && ((fkey f == key) && (fpay f == pay))) wm

--@spec [IRET.19.1]
public export
iret_19_1__find_entity : Nat -> Nat -> Rarc_5_6_4__wm -> Maybe Lfac_1_7_1__fact
iret_19_1__find_entity k key wm = rarc_5_6_5__find (\f => (fkind f == k) && (fkey f == key)) wm

--@spec [RARC.5.6.4]
||| Remove exactly this fact (id, kind and value all equal). In every
||| reachable state the id alone would identify it — `lfac_2_5_3__fresh_id` never hands
||| a live id out, and a token holding a withdrawn fact is dropped by the
||| propagation that follows the withdrawal — but removing by the whole
||| fact keeps that a consequence rather than an invariant the proofs must
||| carry.
public export
rarc_5_6_4__remove_exact : Lfac_1_7_1__fact -> Rarc_5_6_4__wm -> Rarc_5_6_4__wm
rarc_5_6_4__remove_exact f = filter (\g => not (lfac_2_5_4__same_fact g f))

--@spec [IRET.19.1]
--@spec [LFAC.2.5.1]
--@spec [LFAC.2.5.3]
--@spec [LFAC.2.6.4]
||| Assert a fact of kind `k` with value (key, pay) under its lifecycle.
||| `Nothing` means the assertion was a no-op (nothing to propagate).
public export
iret_19_1__assert_fact : Lscp_1_3__lifecycle -> List Nat -> Nat -> Nat -> Nat -> Rarc_5_6_4__wm -> Maybe Rarc_5_6_4__wm
iret_19_1__assert_fact Explicit avoid k key pay wm = Just (wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay])
iret_19_1__assert_fact Relation avoid k key pay wm = case iret_19_1__find_relation k key pay wm of
  Just _  => Nothing
  Nothing => Just (wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay])
iret_19_1__assert_fact Entity avoid k key pay wm = case iret_19_1__find_entity k key wm of
  Nothing => Just (wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay])
  Just old => if fpay old == pay
                 then Nothing
                 -- The replacement's id is chosen while the old fact is
                 -- still live, so it differs from the old id: DS mints a
                 -- fresh wrapper [LFAC.2.5.3], and a token holding the new
                 -- fact must not collide with the token that held the old.
                 else Just (rarc_5_6_4__remove_exact old wm ++ [MkFact (lfac_2_5_3__fresh_id avoid wm) k key pay])

--@spec [LSCP.2.1.1]
||| Withdraw a bound fact. `Nothing` when it is already gone (a no-op).
public export
lscp_2_1_1__withdraw_fact : Lfac_1_7_1__fact -> Rarc_5_6_4__wm -> Maybe Rarc_5_6_4__wm
lscp_2_1_1__withdraw_fact f wm = if rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) wm then Just (rarc_5_6_4__remove_exact f wm) else Nothing

-- ---------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------

--@spec [LGRA.10.1]
--@spec [LSCP.2.1.1]
||| An RHS action. `Withdraw i` withdraws the i-th positive binding.
public export
data Lgra_10_1__action : Type where
  Emit     : (kind : Nat) -> (value : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Lgra_10_1__action
  Withdraw : (binding : Nat) -> Lgra_10_1__action

--@spec [LGRA.6.1]
--@spec [LGRA.8.1]
||| A rule: positive patterns by kind, a guard over the bound facts (where
||| clauses and join conditions), `no` patterns as (kind, blocker) pairs —
||| the pattern is violated by any live fact of that kind the blocker
||| accepts given the bindings — and the RHS.
public export
record Lgra_6_1__rule where
  constructor MkRule
  posKinds : List Nat
  guard    : List Lfac_1_7_1__fact -> Bool
  negs     : List (Nat, List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool)
  actions  : List Lgra_10_1__action

--@spec [LCYC.3.2.1]
public export
record Lcyc_3_2_1__program where
  constructor MkProgram
  life  : Nat -> Lscp_1_3__lifecycle
  rules : List Lgra_6_1__rule

-- ---- Named projections. Proof statements must not mention a lowercase
-- function unapplied (Idris would bind it as an implicit), so the pieces
-- the lemmas talk about are given names that are always applied. ------

--@spec [IRET.11.3]
public export
iret_11_3__fact_ids : List Lfac_1_7_1__fact -> List Nat
iret_11_3__fact_ids fs = map fid fs

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__kinds_of : List Lfac_1_7_1__fact -> List Nat
lcyc_3_2_2__kinds_of fs = map fkind fs

--@spec [IRET.7.9]
public export
iret_7_9__neg_kinds : Lgra_6_1__rule -> List Nat
iret_7_9__neg_kinds r = map fst (negs r)

--@spec [IRET.7.9]
public export
iret_7_9__blockers : Lgra_6_1__rule -> List (List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool)
iret_7_9__blockers r = map snd (negs r)

-- ---- Static analysis: the kinds a rule reads and writes ----------------

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__read_kinds : Lgra_6_1__rule -> List Nat
lcyc_3_2_2__read_kinds r = posKinds r ++ iret_7_9__neg_kinds r

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__emit_kind_of : Lgra_10_1__action -> Maybe Nat
lcyc_3_2_2__emit_kind_of (Emit k _) = Just k
lcyc_3_2_2__emit_kind_of (Withdraw _) = Nothing

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__emit_kinds : Lgra_6_1__rule -> List Nat
lcyc_3_2_2__emit_kinds r = mapMaybe lcyc_3_2_2__emit_kind_of (actions r)

--@spec [LCYC.3.2.2]
||| The kind of the binding an action withdraws, if it withdraws one.
public export
lcyc_3_2_2__withdraw_kind_of : Lgra_6_1__rule -> Lgra_10_1__action -> Maybe Nat
lcyc_3_2_2__withdraw_kind_of r (Withdraw i) = rarc_5_6_5__nth i (posKinds r)
lcyc_3_2_2__withdraw_kind_of r (Emit _ _) = Nothing

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__withdraw_kinds : Lgra_6_1__rule -> List Nat
lcyc_3_2_2__withdraw_kinds r = mapMaybe (lcyc_3_2_2__withdraw_kind_of r) (actions r)

--@spec [LCYC.3.2.2]
public export
lcyc_3_2_2__write_kinds : Lgra_6_1__rule -> List Nat
lcyc_3_2_2__write_kinds r = lcyc_3_2_2__emit_kinds r ++ lcyc_3_2_2__withdraw_kinds r

-- ---------------------------------------------------------------------
-- Tokens and the agenda
-- ---------------------------------------------------------------------

--@spec [IRET.11]
--@spec [IDAT.6.2.2]
||| One token of one rule: the facts it binds (in pattern order), whether
||| it has fired since it was last (re)propagated, and whether a `no`
||| pattern currently blocks it. Facts are immutable, so a token can carry
||| them outright; its identity [IRET.11.3] is `map fid tfacts`.
public export
record Iret_11__tok where
  constructor MkTok
  tfacts  : List Lfac_1_7_1__fact
  fired   : Bool
  blocked : Bool

--@spec [IRET.11.3]
public export
iret_11_3__ids : Iret_11__tok -> List Nat
iret_11_3__ids t = iret_11_3__fact_ids (tfacts t)

--@spec [IRET.11.3]
public export
iret_11_3__tok_ids : List Iret_11__tok -> List (List Nat)
iret_11_3__tok_ids ts = map iret_11_3__ids ts

--@spec [IRET.11.3]
public export
iret_11_3__now_ids : List (List Lfac_1_7_1__fact) -> List (List Nat)
iret_11_3__now_ids now = map iret_11_3__fact_ids now

public export
Eq Iret_11__tok where
  a == b = tfacts a == tfacts b && fired a == fired b && blocked a == blocked b

public export
Show Iret_11__tok where
  show t = "<" ++ show (iret_11_3__ids t) ++ (if fired t then " fired" else "") ++ (if blocked t then " blocked" else "") ++ ">"

--@spec [RARC.5.6.5]
public export
record Rarc_5_6_5__state where
  constructor MkState
  wm   : Rarc_5_6_4__wm
  toks : List (List Iret_11__tok)

public export
Eq Rarc_5_6_5__state where
  a == b = wm a == wm b && toks a == toks b

public export
Show Rarc_5_6_5__state where
  show s = "WM " ++ show (wm s) ++ " TOKS " ++ show (toks s)

--@spec [IRET.7.4]
||| Prefix every tuple in `rest` with every fact in `fs`, facts outermost.
public export
iret_7_4__extend : List Lfac_1_7_1__fact -> List (List Lfac_1_7_1__fact) -> List (List Lfac_1_7_1__fact)
iret_7_4__extend fs rest = rarc_5_6_5__concat_map (\f => map (f ::) rest) fs

--@spec [IRET.7.4]
||| All tuples of live facts matching a kind list, in pattern order, each
||| position enumerated in working-memory order. This enumeration order is
||| the creation-timetag order for matches completed by one assertion.
public export
iret_7_4__tuples : List Nat -> Rarc_5_6_4__wm -> List (List Lfac_1_7_1__fact)
iret_7_4__tuples [] wm = [[]]
iret_7_4__tuples (k :: ks) wm = iret_7_4__extend (rarc_5_6_4__facts_of_kind k wm) (iret_7_4__tuples ks wm)

--@spec [IRET.7.4]
public export
iret_7_4__match_tuples : Lgra_6_1__rule -> Rarc_5_6_4__wm -> List (List Lfac_1_7_1__fact)
iret_7_4__match_tuples r wm = filter (guard r) (iret_7_4__tuples (posKinds r) wm)

--@spec [IRET.7.9]
||| The live facts of each `no` pattern's kind, in pattern order — the
||| only part of working memory the blocking test reads.
public export
iret_7_9__neg_facts : Lgra_6_1__rule -> Rarc_5_6_4__wm -> List (List Lfac_1_7_1__fact)
iret_7_9__neg_facts r wm = map (\nb => rarc_5_6_4__facts_of_kind (fst nb) wm) (negs r)

--@spec [IRET.7.9]
public export
iret_7_9__is_blocked_with : List (List Lfac_1_7_1__fact -> Lfac_1_7_1__fact -> Bool) -> List (List Lfac_1_7_1__fact) -> List Lfac_1_7_1__fact -> Bool
iret_7_9__is_blocked_with bs fss fs = rarc_5_6_5__any (\bfl => rarc_5_6_5__any ((fst bfl) fs) (snd bfl)) (zip bs fss)

--@spec [IRET.7.9]
public export
iret_7_9__is_blocked : Lgra_6_1__rule -> Rarc_5_6_4__wm -> List Lfac_1_7_1__fact -> Bool
iret_7_9__is_blocked r wm = iret_7_9__is_blocked_with (iret_7_9__blockers r) (iret_7_9__neg_facts r wm)

--@spec [IRET.8.1]
||| The old tokens whose tuple still matches: they keep their entry, and
||| so their creation order and `fired`.
public export
iret_8_1__kept_of : List (List Lfac_1_7_1__fact) -> List Iret_11__tok -> List Iret_11__tok
iret_8_1__kept_of now old = filter (\t => rarc_5_6_5__elem (iret_11_3__ids t) (iret_11_3__now_ids now)) old

--@spec [IRET.8.1]
||| Match tuples not seen before, as new unfired tokens, appended in
||| enumeration order.
public export
iret_8_1__fresh_tok : List Lfac_1_7_1__fact -> Iret_11__tok
iret_8_1__fresh_tok fs = MkTok fs False False

--@spec [IRET.8.1]
public export
iret_8_1__added_of : List (List Lfac_1_7_1__fact) -> List Iret_11__tok -> List Iret_11__tok
iret_8_1__added_of now old = map iret_8_1__fresh_tok (filter (\fs => not (rarc_5_6_5__elem (iret_11_3__fact_ids fs) (iret_11_3__tok_ids old))) now)

--@spec [LDET.5.9]
--@spec [IDAT.6.2.2]
--@spec [IRET.22.3]
||| Recompute blocking; a blocked -> unblocked transition is a
||| re-propagation, which clears `fired` [IDAT.6.2.2] while keeping the
||| position [LDET.5.9].
public export
ldet_5_9__refresh_with : Bool -> Iret_11__tok -> Iret_11__tok
ldet_5_9__refresh_with blk t = MkTok (tfacts t) (if blocked t && not blk then False else fired t) blk

--@spec [LDET.5.9]
public export
ldet_5_9__refresh_tok : Lgra_6_1__rule -> List (List Lfac_1_7_1__fact) -> Iret_11__tok -> Iret_11__tok
ldet_5_9__refresh_tok r nf t = ldet_5_9__refresh_with (iret_7_9__is_blocked_with (iret_7_9__blockers r) nf (tfacts t)) t

--@spec [RARC.5.6.5]
||| Re-propagate one rule given its current match tuples and the facts
||| its `no` patterns see.
public export
rarc_5_6_5__prop_with : Lgra_6_1__rule -> List (List Lfac_1_7_1__fact) -> List (List Lfac_1_7_1__fact) -> List Iret_11__tok -> List Iret_11__tok
rarc_5_6_5__prop_with r now nf old = map (ldet_5_9__refresh_tok r nf) (iret_8_1__kept_of now old ++ iret_8_1__added_of now old)

--@spec [RARC.5.6.5]
||| Re-propagate one rule after a WM change. Factored through `rarc_5_6_5__prop_with`
||| so that it provably depends on working memory only through the facts
||| of the kinds the rule reads.
public export
rarc_5_6_5__prop_rule : Lgra_6_1__rule -> Rarc_5_6_4__wm -> List Iret_11__tok -> List Iret_11__tok
rarc_5_6_5__prop_rule r wm old = rarc_5_6_5__prop_with r (iret_7_4__match_tuples r wm) (iret_7_9__neg_facts r wm) old

--@spec [RARC.5.6.5]
public export
rarc_5_6_5__propagate : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> List (List Iret_11__tok) -> List (List Iret_11__tok)
rarc_5_6_5__propagate p wm tables = zipWith (\r, ts => rarc_5_6_5__prop_rule r wm ts) (rules p) tables

--@spec [RARC.5.6.5]
||| The initial state: an input working memory, every rule's tokens
||| propagated from empty tables. Rule count and table count agree from
||| here on.
public export
rarc_5_6_5__init_state : Lcyc_3_2_1__program -> Rarc_5_6_4__wm -> Rarc_5_6_5__state
rarc_5_6_5__init_state p wm0 = MkState wm0 (rarc_5_6_5__propagate p wm0 (map (const []) (rules p)))

-- ---------------------------------------------------------------------
-- Selection and firing
-- ---------------------------------------------------------------------

--@spec [IRET.11.3.1]
public export
iret_11_3_1__pending_tok : Iret_11__tok -> Bool
iret_11_3_1__pending_tok t = not (fired t) && not (blocked t)

--@spec [IRET.11.3.1]
public export
iret_11_3_1__pending_count : List Iret_11__tok -> Nat
iret_11_3_1__pending_count ts = length (filter iret_11_3_1__pending_tok ts)

--@spec [LDET.5.5]
||| Index of the first pending token of a rule, in creation order.
public export
ldet_5_5__first_pending : List Iret_11__tok -> Maybe Nat
ldet_5_5__first_pending [] = Nothing
ldet_5_5__first_pending (t :: ts) = if iret_11_3_1__pending_tok t then Just 0 else map S (ldet_5_5__first_pending ts)

--@spec [LDET.5.1]
--@spec [LDET.5.4]
||| The activation that fires next: lowest rule ordinal with a pending
||| token, then that rule's earliest pending token [LDET.5.1].
public export
ldet_5_1__select_next : List (List Iret_11__tok) -> Maybe (Nat, Nat)
ldet_5_1__select_next [] = Nothing
ldet_5_1__select_next (ts :: tss) = case ldet_5_5__first_pending ts of
  Just j  => Just (0, j)
  Nothing => map (\(r, j) => (S r, j)) (ldet_5_1__select_next tss)

--@spec [RARC.5.6.5]
||| Apply `f` to the n-th element, if there is one.
public export
rarc_5_6_5__set_at : Nat -> (a -> a) -> List a -> List a
rarc_5_6_5__set_at _     f []        = []
rarc_5_6_5__set_at Z     f (x :: xs) = f x :: xs
rarc_5_6_5__set_at (S n) f (x :: xs) = x :: rarc_5_6_5__set_at n f xs

--@spec [IDAT.6.2.2]
public export
idat_6_2_2__mark_t : Iret_11__tok -> Iret_11__tok
idat_6_2_2__mark_t t = MkTok (tfacts t) True (blocked t)

--@spec [IDAT.6.2.2]
public export
idat_6_2_2__mark_at : Nat -> List Iret_11__tok -> List Iret_11__tok
idat_6_2_2__mark_at j ts = rarc_5_6_5__set_at j idat_6_2_2__mark_t ts

--@spec [IDAT.6.2.2]
--@spec [IRET.11.3.1]
||| Set `fired` on entry j of the r-th table.
public export
idat_6_2_2__mark_fired : Nat -> Nat -> List (List Iret_11__tok) -> List (List Iret_11__tok)
idat_6_2_2__mark_fired r j = rarc_5_6_5__set_at r (idat_6_2_2__mark_at j)

--@spec [IRET.11]
public export
iret_11__from_maybe : Maybe (List Iret_11__tok) -> List Iret_11__tok
iret_11__from_maybe (Just ts) = ts
iret_11__from_maybe Nothing = []

--@spec [IRET.11]
||| The r-th rule's token table (empty if there is none).
public export
iret_11__table_at : Nat -> List (List Iret_11__tok) -> List Iret_11__tok
iret_11__table_at r tables = iret_11__from_maybe (rarc_5_6_5__nth r tables)

--@spec [RARC.5.6.7]
||| Run one action against the state and propagate immediately if it
||| changed working memory. `bound` is the fired token's facts.
public export
rarc_5_6_7__do_action : Lcyc_3_2_1__program -> List Lfac_1_7_1__fact -> Lgra_10_1__action -> Rarc_5_6_5__state -> Rarc_5_6_5__state
rarc_5_6_7__do_action p bound (Emit k value) st =
  case iret_19_1__assert_fact (life p k) (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) (wm st) of
    Nothing  => st
    Just wm' => MkState wm' (rarc_5_6_5__propagate p wm' (toks st))
rarc_5_6_7__do_action p bound (Withdraw i) st =
  case rarc_5_6_5__nth i bound of
    Nothing => st
    Just f => case lscp_2_1_1__withdraw_fact f (wm st) of
      Nothing  => st
      Just wm' => MkState wm' (rarc_5_6_5__propagate p wm' (toks st))

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions : Lcyc_3_2_1__program -> List Lfac_1_7_1__fact -> List Lgra_10_1__action -> Rarc_5_6_5__state -> Rarc_5_6_5__state
rarc_5_6_7__do_actions p bound [] st = st
rarc_5_6_7__do_actions p bound (a :: as) st = rarc_5_6_7__do_actions p bound as (rarc_5_6_7__do_action p bound a st)

--@spec [IRET.11.4]
||| One firing. `Nothing` when the agenda has no pending activation: the
||| run has reached its fixpoint.
public export
iret_11_4__step : Lcyc_3_2_1__program -> Rarc_5_6_5__state -> Maybe Rarc_5_6_5__state
iret_11_4__step p st = case ldet_5_1__select_next (toks st) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (rules p) of
    Nothing => Nothing
    Just rule => case rarc_5_6_5__nth j (iret_11__table_at r (toks st)) of
      Nothing => Nothing
      Just tok => Just (rarc_5_6_7__do_actions p (tfacts tok) (actions rule)
                                  (MkState (wm st) (idat_6_2_2__mark_fired r j (toks st))))

-- ---------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------

--@spec [IRET.11.4]
||| The state after `n` firings, or `Nothing` if the run quiesced first.
public export
iret_11_4__step_n : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> Maybe Rarc_5_6_5__state
iret_11_4__step_n p Z     st = Just st
iret_11_4__step_n p (S n) st = case iret_11_4__step p st of
  Nothing  => Nothing
  Just st' => iret_11_4__step_n p n st'

--@spec [IRET.11.4]
public export
data Iret_11_4__halt = Quiescent | FuelOut

public export
Uninhabited (FuelOut = Quiescent) where
  uninhabited Refl impossible

public export
Uninhabited (Quiescent = FuelOut) where
  uninhabited Refl impossible

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| Bounded run: fire until quiescent or the fuel is spent, reporting
||| which. Total because `fuel` decreases on the one recursive call. This
||| is [RARC.5.6.6]'s fire phase; ConsumptionLoop.idr names it so and proves
||| the count stays within the fuel and that `Quiescent` is honest.
public export
iret_11_4__run : Lcyc_3_2_1__program -> Nat -> Rarc_5_6_5__state -> (Rarc_5_6_5__state, Iret_11_4__halt, Nat)
iret_11_4__run p Z st = (st, FuelOut, 0)
iret_11_4__run p (S fuel) st = case iret_11_4__step p st of
  Nothing  => (st, Quiescent, 0)
  Just st' => let (s, h, n) = iret_11_4__run p fuel st' in (s, h, S n)

--@spec [LCYC.1.1]
||| Divergence, stated positively: from `st`, every finite number of
||| firings is possible. This is what a proof of non-termination
||| establishes about a witness.
public export
Lcyc_1_1__diverges : Lcyc_3_2_1__program -> Rarc_5_6_5__state -> Type
Lcyc_1_1__diverges p st = (n : Nat) -> IsJust (iret_11_4__step_n p n st)

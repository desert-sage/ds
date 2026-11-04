-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The termination certificate for Rete/FireLoop.idr's deterministic fire
||| loop, and the proof that a certified program quiesces from every input.
|||
||| NORMATIVE COMPANION, on the same two mechanisms as Rete/FireLoop.idr.
||| The stratification and the kind sets it is computed from are [LCYC.3.1]'s
||| rule graph and SCC-DAG; the measure and its well-founded order are
||| [LCYC.1.1]'s. `Lcyc_3_1_1__cert_emit`, `Lcyc_3_1_1__range` and
||| `Lcyc_3_1_1__certified` tie to [LCYC.3.1.1] as `--@derives`, not
||| `--@spec`: [LCYC.3.1.1] refuses the recursion exception
||| `Lcyc_3_1_1__cert_emit`'s `life p k = Relation` disjunct models -- the
||| clause requires no emitted-and-read kind to exist in an admitted SCC at
||| all, full stop.
||| This module's certificate is therefore PROVEN FOR MORE than the
||| clause admits (`verdict: "partial"`, the AbsentTrichotomy.idr
||| shape of the word, per [STYL.5.3.6.2]): every program [LCYC.3.1.1]
||| admits satisfies it vacuously (no kind is ever emitted-and-read, so the
||| implication holds on an empty domain), but the reverse does not hold.
|||
||| THE STRATIFICATION.
||| The compiler already builds the rule graph and its SCC-DAG [LCYC.3.1]; a
||| topological order of that DAG is a STRATIFICATION: every rule gets a
||| stratum, and every edge goes to an equal or later stratum. [LCYC.3.1.1]
||| itself states the narrower condition: no schema is both
||| emitted and matched (positively or under `no`) by rules of one SCC, and
||| no rule of the SCC carries a `call`, `cache` or `cache_delete` action
||| or matches via `latest`/`then` a schema the SCC emits. The
||| condition this module checks is more general, and no clause states it:
|||
|||   a kind that some rule of stratum i emits AND some rule of stratum i
|||   reads must (1) be a `logical` relation (key = all slots, so a repeat
|||   emit is a no-op) and (2) not be withdrawn by any rule of stratum i;
|||
||| together with the range restriction every emit already needs for the
||| monotone argument to mean anything: an emitted value is a literal of
||| the program or a copy of a bound fact's value.
|||
||| WHAT DECIDES TERMINATION is whether a kind is both produced and removed
||| where it is read, and whether production is bounded. `no` patterns are
||| not mentioned at all: a negated beta over a kind that is only ever
||| added flips once and never re-arms, and one over a kind that is only
||| ever consumed re-arms at most once per consumed fact.
|||
||| THE MEASURE. For stratum i, (c1, c2) where c1 = sum over the kinds
||| emitted-and-read in i of the DOM values not yet live for that kind
||| (headroom), plus the live count of every kind withdrawn in i; c2 = the
||| pending activations of i's rules. The vector (c1_0, c2_0, c1_1, c2_1,
||| ...) decreases lexicographically on every firing: the pop takes one
||| from c2 of the firing stratum, a real emit or withdraw takes at least
||| one from its c1, and nothing a rule does reaches an earlier stratum
||| (that would be an edge against the topological order). Lexicographic
||| order on fixed-length vectors of naturals is well-founded, so the run
||| is finite.
|||
||| WHAT IS NOT PROVED HERE. That the compiler's graph is the model's
||| graph (a language-surface claim, argued in the characterization
||| document), and anything about the TMS, time, or `call` — each
||| adds a way to remove or freshly produce a fact and is placed against
||| this certificate in that document.
|||
||| THE CERTIFICATE IS KIND-LEVEL, AND THE COMPILER'S GRAPH IS NOT.
||| `Lcyc_3_1__edge_mono` reads edges off
||| `lcyc_3_2_2__write_kinds` and `lcyc_3_2_2__read_kinds`; a guard is an
||| opaque Bool here, so no edge is ever dropped by reading it. [LCYC.6.1]
||| drops an edge when the emit's literal refutes every positive pattern
||| of the target, and [LCYC.3.1.1] admits over that pruned graph. So a
||| program the compiler admits only by the break -- the kind-flip
||| `compiler/LCYC.6.1_self_edge_kind_flip_ok`, [LCYC.6.1.3]'s staged
||| derivation -- keeps a kind-level edge inside an SCC and has NO
||| certificate here: every theorem over `Lcyc_3_1_1__certified` is silent
||| on it, and its termination rests on the break's own argument, which
||| nothing in the lane proves. The ties that read "certified" say so.
module Lcyc.Certificate

import Rete.FireLoop
import Lcyc.Lemmas
import Lcyc.Propagation
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Control.WellFounded
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- Syntactic kind sets
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
||| Pair every element with its position.
public export
lcyc_1_1__indexed_from : Nat -> List a -> List (Nat, a)
lcyc_1_1__indexed_from n [] = []
lcyc_1_1__indexed_from n (x :: xs) = (n, x) :: lcyc_1_1__indexed_from (S n) xs

-- ---------------------------------------------------------------------
-- Stratification: the SCC-DAG's topological order, as the compiler has it
-- ---------------------------------------------------------------------

--@spec [LCYC.3.1]
public export
record Lcyc_3_1__strata where
  constructor MkStrata
  count : Nat
  strat : Nat -> Nat

--@spec [LCYC.3.1]
public export
lcyc_3_1__rules_in : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List Lgra_6_1__rule
lcyc_3_1__rules_in s i rs = map snd (filter (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs))

--@spec [LCYC.3.1]
public export
lcyc_3_1__read_kinds_of : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List Nat
lcyc_3_1__read_kinds_of s i rs = rarc_5_6_5__concat_map lcyc_3_2_2__read_kinds (lcyc_3_1__rules_in s i rs)

--@spec [LCYC.3.1]
public export
lcyc_3_1__emit_kinds_of : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List Nat
lcyc_3_1__emit_kinds_of s i rs = rarc_5_6_5__concat_map lcyc_3_2_2__emit_kinds (lcyc_3_1__rules_in s i rs)

--@spec [LCYC.3.1]
public export
lcyc_3_1__withdraw_kinds_of : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List Nat
lcyc_3_1__withdraw_kinds_of s i rs = rarc_5_6_5__concat_map lcyc_3_2_2__withdraw_kinds (lcyc_3_1__rules_in s i rs)

--@spec [LCYC.3.1]
||| Every edge respects the order: a rule writing a kind another reads
||| sits in an equal or earlier stratum. This is what [LCYC.3.1]'s
||| acyclic SCC-DAG supplies.
public export
Lcyc_3_1__edge_mono : Lcyc_3_1__strata -> List Lgra_6_1__rule -> Type
Lcyc_3_1__edge_mono s rs =
  (ri, rj : Nat) -> (r, q : Lgra_6_1__rule) -> rarc_5_6_5__nth ri rs = Just r -> rarc_5_6_5__nth rj rs = Just q ->
  (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__write_kinds r) = True -> rarc_5_6_5__elem k (lcyc_3_2_2__read_kinds q) = True ->
  LTE (strat s ri) (strat s rj)

--@spec [LCYC.3.1]
||| Every rule index has a stratum below `count`.
public export
Lcyc_3_1__in_range : Lcyc_3_1__strata -> List Lgra_6_1__rule -> Type
Lcyc_3_1__in_range s rs = (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri rs = Just r -> LT (strat s ri) (count s)

-- ---------------------------------------------------------------------
-- The certificate
-- ---------------------------------------------------------------------

--@derives [LCYC.3.1.1]
||| A kind emitted and read in the same stratum is a dedup'd relation
||| that no rule of the stratum withdraws.
public export
Lcyc_3_1_1__cert_emit : Lcyc_3_2_1__program -> Lcyc_3_1__strata -> Type
Lcyc_3_1_1__cert_emit p s =
  (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
  (k : Nat) -> rarc_5_6_5__elem k (lcyc_3_2_2__emit_kinds r) = True ->
  rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s (strat s ri) (rules p)) = True ->
  (life p k = Relation, rarc_5_6_5__elem k (lcyc_3_1__withdraw_kinds_of s (strat s ri) (rules p)) = False)

--@derives [LCYC.3.1.1]
||| Range restriction: every emitted value is a program literal or a copy
||| of a bound fact's value.
public export
Lcyc_3_1_1__range : Lcyc_3_2_1__program -> List (Nat, Nat) -> Type
Lcyc_3_1_1__range p lits =
  (ri : Nat) -> (r : Lgra_6_1__rule) -> rarc_5_6_5__nth ri (rules p) = Just r ->
  (k : Nat) -> (v : List Lfac_1_7_1__fact -> (Nat, Nat)) -> Elem (Emit k v) (actions r) ->
  (fs : List Lfac_1_7_1__fact) -> Either (Elem (v fs) lits) (Elem (v fs) (map (\f => lfac_2_5_1__val f) fs))

--@derives [LCYC.3.1.1]
public export
record Lcyc_3_1_1__certified (p : Lcyc_3_2_1__program) where
  constructor MkCertified
  strata   : Lcyc_3_1__strata
  lits     : List (Nat, Nat)
  edgeMono : Lcyc_3_1__edge_mono strata (rules p)
  inRange  : Lcyc_3_1__in_range strata (rules p)
  certEmit : Lcyc_3_1_1__cert_emit p strata
  range    : Lcyc_3_1_1__range p lits

-- ---------------------------------------------------------------------
-- The measure
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
public export
lcyc_1_1__comp1 : Lcyc_3_2_1__program -> Lcyc_3_1__strata -> List (Nat, Nat) -> Nat -> Rarc_5_6_4__wm -> Nat
lcyc_1_1__comp1 p s dom i wm =
  lcyc_1_1__sum_by (\k => lcyc_1_1__headroom k dom wm)
        (filter (\k => rarc_5_6_5__elem k (lcyc_3_1__read_kinds_of s i (rules p))) (lcyc_3_1__emit_kinds_of s i (rules p)))
  + lcyc_1_1__sum_by (\k => rarc_5_6_4__count_kind k wm) (lcyc_3_1__withdraw_kinds_of s i (rules p))

--@spec [LCYC.3.1]
||| The rule indices of stratum i.
public export
lcyc_3_1__indices_in : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List Nat
lcyc_3_1__indices_in s i rs = map fst (filter (\ir => strat s (fst ir) == i) (lcyc_1_1__indexed_from 0 rs))

--@spec [LCYC.1.1]
public export
lcyc_1_1__comp2 : Lcyc_3_1__strata -> Nat -> List Lgra_6_1__rule -> List (List Iret_11__tok) -> Nat
lcyc_1_1__comp2 s i rs tables = lcyc_1_1__sum_by (\ri => iret_11_3_1__pending_count (iret_11__table_at ri tables)) (lcyc_3_1__indices_in s i rs)

--@spec [LCYC.1.1]
||| (c1_a, c2_a, c1_(a+1), c2_(a+1), ...) for n strata starting at a.
public export
lcyc_1_1__measure_from : Lcyc_3_2_1__program -> Lcyc_3_1__strata -> List (Nat, Nat) -> Nat -> Nat -> Rarc_5_6_5__state -> List Nat
lcyc_1_1__measure_from p s dom a Z st = []
lcyc_1_1__measure_from p s dom a (S n) st =
  lcyc_1_1__comp1 p s dom a (wm st) :: lcyc_1_1__comp2 s a (rules p) (toks st) :: lcyc_1_1__measure_from p s dom (S a) n st

--@spec [LCYC.1.1]
public export
lcyc_1_1__measure : Lcyc_3_2_1__program -> Lcyc_3_1__strata -> List (Nat, Nat) -> Rarc_5_6_5__state -> List Nat
lcyc_1_1__measure p s dom st = lcyc_1_1__measure_from p s dom 0 (count s) st

-- ---------------------------------------------------------------------
-- Lexicographic order on equal-length lists of naturals is well-founded
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
public export
data Lcyc_1_1__lex_lt : List Nat -> List Nat -> Type where
  LexHead : LT x y -> length xs = length ys -> Lcyc_1_1__lex_lt (x :: xs) (y :: ys)
  LexTail : Lcyc_1_1__lex_lt xs ys -> Lcyc_1_1__lex_lt (x :: xs) (x :: ys)

-- Accessibility is the base's `Control.WellFounded.Accessible` (constructor
-- `Access`), and every natural is accessible under `LT` by the base's
-- `WellFounded Nat LT` instance (`wellFounded`).

--@derives [LCYC.1.1]
lcyc_1_1__lex_nil : Lcyc_1_1__lex_lt xs [] -> Void
lcyc_1_1__lex_nil (LexHead _ _) impossible
lcyc_1_1__lex_nil (LexTail _) impossible

--@derives [LCYC.1.1]
export
lcyc_1_1__lex_len : Lcyc_1_1__lex_lt xs ys -> length xs = length ys
lcyc_1_1__lex_len (LexHead _ eq) = cong S eq
lcyc_1_1__lex_len (LexTail rest) = cong S (lcyc_1_1__lex_len rest)

--@derives [LCYC.1.1]
||| Accessibility by induction on the length: the tail of a smaller
||| vector has the same length as ours, so its accessibility is available
||| from the induction hypothesis on that length.
export
lcyc_1_1__lex_acc_len : (n : Nat) -> (ys : List Nat) -> length ys = n -> Accessible Lcyc_1_1__lex_lt ys
lcyc_1_1__lex_acc_len n [] eq = Access (\xs, lt => absurd (lcyc_1_1__lex_nil lt))
lcyc_1_1__lex_acc_len Z (y :: ys) eq = absurd eq
lcyc_1_1__lex_acc_len (S m) (y :: ys) eq = go y (wellFounded {rel = LT} y) ys (lcyc_1_1__lex_acc_len m ys (injective eq)) (injective eq)
  where
    go : (x : Nat) -> Accessible LT x -> (xs : List Nat) -> Accessible Lcyc_1_1__lex_lt xs -> length xs = m ->
         Accessible Lcyc_1_1__lex_lt (x :: xs)
    go x (Access hx) xs (Access hxs) lenXs = Access (\zs, lt => case lt of
      LexHead {xs = zs', x = z} zLTx lenEq =>
        go z (hx z zLTx) zs' (lcyc_1_1__lex_acc_len m zs' (trans lenEq lenXs)) (trans lenEq lenXs)
      LexTail {xs = zs'} rest =>
        go x (Access hx) zs' (hxs zs' rest) (trans (lcyc_1_1__lex_len rest) lenXs))

--@derives [LCYC.1.1]
export
lcyc_1_1__lex_acc : (ys : List Nat) -> Accessible Lcyc_1_1__lex_lt ys
lcyc_1_1__lex_acc ys = lcyc_1_1__lex_acc_len (length ys) ys Refl

-- ---------------------------------------------------------------------
-- The state invariant the proof carries
-- ---------------------------------------------------------------------

--@spec [LCYC.1.1]
||| Every live value is in `dom`; every rule has a token table; every
||| token's facts have the pattern kinds of its rule and values in `dom`;
||| and every table is settled against the current working memory.
public export
record Lcyc_1_1__inv (p : Lcyc_3_2_1__program) (dom : List (Nat, Nat)) (st : Rarc_5_6_5__state) where
  constructor MkInv
  wmDom   : All (\f => Elem (lfac_2_5_1__val f) dom) (wm st)
  tokLen  : length (toks st) = length (rules p)
  tokOk   : (ri : Nat) -> (r : Lgra_6_1__rule) -> (ts : List Iret_11__tok) ->
            rarc_5_6_5__nth ri (rules p) = Just r -> rarc_5_6_5__nth ri (toks st) = Just ts -> All (Iret_7_4__tok_ok r dom) ts
  settled : (ri : Nat) -> (r : Lgra_6_1__rule) -> (ts : List Iret_11__tok) ->
            rarc_5_6_5__nth ri (rules p) = Just r -> rarc_5_6_5__nth ri (toks st) = Just ts ->
            Iret_8_1__settled r (iret_7_4__match_tuples r (wm st)) (iret_7_9__neg_facts r (wm st)) ts

--@derives [LCYC.1.1]
||| The domain of a run: the program's literals and the input's values.
public export
lcyc_1_1__dom_of : Lcyc_3_1_1__certified p -> Rarc_5_6_4__wm -> List (Nat, Nat)
lcyc_1_1__dom_of c wm0 = lits c ++ map (\f => lfac_2_5_1__val f) wm0

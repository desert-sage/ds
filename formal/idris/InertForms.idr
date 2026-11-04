-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Inert slots, the three source forms: `latest`, `then … within`, and
||| V5's hoisting put no new read anywhere. Obligation 1 of the inert-slot
||| proposal, the part `InertSlots.idr` left to no file.
|||
||| EVIDENCE FOR A PROPOSAL, NOT A MODEL OF A CLAUSE. No clause states inert
||| slots, so every element here is a gap.
|||
||| WHAT `InertSlots` PROVED, and what it left. A clean expression -- one
||| that reads no inert slot -- is worth the same in two working memories
||| that differ in inert values alone, for every expression, and a rule
||| every one of whose deciding expressions is clean decides alike in both.
||| The proposal's obligation 1 names four source forms the theorem must
||| reach through: `let`, `latest`, `then` / `within`, and V5's hoisting.
||| `let` was carried across there (`gap__let_agrees`). The other three are
||| carried across here.
|||
||| WHAT EACH FORM IS, read in the clauses. Each is a rewriting of source
||| into expressions at a deciding position of the rule:
|||
|||   * `latest(S where p)` ([LGRA.9.8.4]) synthesises a positive `S x`
|||     pattern and a negated twin that guards the most-recent-by-`ts`
|||     selection, and adds the filter to both twins: three tests, `p` on
|||     the anchor, `p` on the twin, and the twin's `ts` against the
|||     anchor's.
|||   * `X then Y within T` ([LTHE.2.2.2]): `Y.ts > X.ts` and
|||     `Y.ts - X.ts < T`, two tests.
|||   * V5's hoisting (RLOW.5.5, [IRET.6.4]): a decided conjunct leaves the
|||     join test for an alpha test. No expression is new; the set of tests
|||     is the set the `where` had.
|||
||| So every expression a form puts at a deciding position is one the
||| source already had, or a read of `ts`. THE THEOREM: the three forms
||| preserve "clean" exactly when `ts` is not inert (`gap__desugar_clean_*`),
||| and a form the rule admits is then worth one value in two working
||| memories that differ in inert values alone (`gap__form_agrees`). The
||| witnesses say what the "exactly" costs: with `ts` inert, a `then` and a
||| `latest` each read the difference (`gap__inert_ts_leaks_through_then`,
||| `gap__inert_ts_leaks_through_latest`) -- finding a3 of the answer sent,
||| that 1.2 bars a key and a series source and does not bar `ts`, as a
||| theorem with its leak.
|||
||| HOISTING, and what this file does not say of it. Here a hoist is a
||| selection: the conjuncts a predicate picks go first, the rest follow
||| (`gap__hoist`), and "all clean" survives any selection
||| (`gap__hoist_clean`). WHICH conjuncts may be picked is RLOW.5.5's
||| condition -- decided: no `null`, no fault -- and that condition is
||| `Rete/WhereV5.idr`'s theorem (`rlow_5_5__hoist_sound`), over values this
||| file does not have: every value here is a number and every operation
||| total. This file says only that hoisting any conjunct puts no new read
||| anywhere, and that a conjunct that reads an inert slot is refused on
||| either side of the join.
|||
||| NOT MODELLED, as in `InertSlots`: identity (obligation 2, the Alloy
||| model), `null`, faults, NaN; truth maintenance, replay and hydration.
||| The twin of a `latest` is a second pattern over the same schema; that
||| its marks are the anchor's is a hypothesis here, not a construction.
module InertForms

import Data.List
import Data.Nat
import InertSlots

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- The comparisons a form writes, as numbers: 1 for true, 0 for false
-- ---------------------------------------------------------------------

--@gap
||| `a > b`, as a form's test: 1 or 0.
public export
gap__gt : Nat -> Nat -> Nat
gap__gt Z b = 0
gap__gt (S a) Z = 1
gap__gt (S a) (S b) = gap__gt a b

--@gap
||| `a < b`, as a form's test: 1 or 0.
public export
gap__lt : Nat -> Nat -> Nat
gap__lt a b = gap__gt b a

-- ---------------------------------------------------------------------
-- A hoist is a selection
-- ---------------------------------------------------------------------

--@gap
||| One conjunct kept or dropped by a selection.
public export
gap__keep : Bool -> Gap__expr -> List Gap__expr -> List Gap__expr
gap__keep True e r = e :: r
gap__keep False e r = r

--@gap
||| The conjuncts a predicate picks, in their order.
public export
gap__select : (Gap__expr -> Bool) -> List Gap__expr -> List Gap__expr
gap__select pick [] = []
gap__select pick (e :: es) = gap__keep (pick e) e (gap__select pick es)

--@gap
||| A HOIST: the conjuncts the compiler takes to an alpha test, then the
||| rest, which stay in the join test (RLOW.5.5). The same conjuncts, in two
||| places.
public export
gap__hoist : (Gap__expr -> Bool) -> List Gap__expr -> List Gap__expr
gap__hoist pick src = gap__select pick src ++ gap__select (\e => not (pick e)) src

-- ---------------------------------------------------------------------
-- The three forms, and what each desugars to
-- ---------------------------------------------------------------------

--@gap
||| The three source forms. `Latest p twin ts filter`: the anchor pattern
||| `p`, its negated twin `twin`, the slot `ts`, and the filter as a
||| function of the pattern it is applied to. `Then x y ts bound`: the two
||| patterns, the slot `ts`, the bound `T`. `Hoist pick src`: a `where`'s
||| conjuncts and the predicate that picks the hoisted ones.
public export
data Gap__form : Type where
  Latest : (p : Nat) -> (twin : Nat) -> (ts : Nat) -> (flt : Nat -> Gap__expr) -> Gap__form
  Then   : (x : Nat) -> (y : Nat) -> (ts : Nat) -> (bound : Nat) -> Gap__form
  Hoist  : (pick : Gap__expr -> Bool) -> (src : List Gap__expr) -> Gap__form

--@gap
||| WHAT A FORM DESUGARS TO: the tests it puts at the deciding positions of
||| the rule, written from the clauses. `latest`: the filter on the anchor,
||| the filter on the twin, the twin's `ts` later than the anchor's
||| ([LGRA.9.8.4]). `then`: `Y.ts > X.ts`, `Y.ts - X.ts < T`
||| ([LTHE.2.2.2]). A hoist: the picked conjuncts, then the rest.
public export
gap__desugar : Gap__form -> List Gap__expr
gap__desugar (Latest p twin ts flt) =
  [ flt p
  , flt twin
  , Op gap__gt (Read twin ts) (Read p ts) ]
gap__desugar (Then x y ts bound) =
  [ Op gap__gt (Read y ts) (Read x ts)
  , Op gap__lt (Op minus (Read y ts) (Read x ts)) (Lit bound) ]
gap__desugar (Hoist pick src) = gap__hoist pick src

-- ---------------------------------------------------------------------
-- "All clean" survives an append and a selection
-- ---------------------------------------------------------------------

--@gap
||| Two lists of clean expressions, appended, are clean.
export
gap__all_clean_append : (xs, ys : List Gap__expr) -> (marks : List (List Bool)) ->
                        gap__all_clean xs marks = True -> gap__all_clean ys marks = True ->
                        gap__all_clean (xs ++ ys) marks = True
gap__all_clean_append [] ys marks p q = q
gap__all_clean_append (x :: xs) ys marks p q =
  gap__and_both (gap__clean x marks) (gap__all_clean (xs ++ ys) marks)
    (gap__and_left (gap__clean x marks) (gap__all_clean xs marks) p)
    (gap__all_clean_append xs ys marks (gap__and_right (gap__clean x marks) (gap__all_clean xs marks) p) q)

--@gap
||| A clean conjunct kept or dropped before clean conjuncts leaves them
||| clean.
export
gap__all_clean_keep : (b : Bool) -> (e : Gap__expr) -> (r : List Gap__expr) -> (marks : List (List Bool)) ->
                      gap__clean e marks = True -> gap__all_clean r marks = True ->
                      gap__all_clean (gap__keep b e r) marks = True
gap__all_clean_keep True e r marks p q = gap__and_both (gap__clean e marks) (gap__all_clean r marks) p q
gap__all_clean_keep False e r marks p q = q

--@gap
||| A selection from clean expressions is clean, whatever it picks.
export
gap__all_clean_select : (pick : Gap__expr -> Bool) -> (xs : List Gap__expr) -> (marks : List (List Bool)) ->
                        gap__all_clean xs marks = True ->
                        gap__all_clean (gap__select pick xs) marks = True
gap__all_clean_select pick [] marks p = Refl
gap__all_clean_select pick (x :: xs) marks p =
  gap__all_clean_keep (pick x) x (gap__select pick xs) marks
    (gap__and_left (gap__clean x marks) (gap__all_clean xs marks) p)
    (gap__all_clean_select pick xs marks (gap__and_right (gap__clean x marks) (gap__all_clean xs marks) p))

-- ---------------------------------------------------------------------
-- The theorem, form by form: clean survives the rewriting iff ts is not inert
-- ---------------------------------------------------------------------

--@gap
||| A `latest` WHOSE FILTER IS CLEAN AND WHOSE `ts` IS NOT INERT desugars
||| to clean tests: on the anchor, on the twin, and the guard that reads
||| `ts` on both.
export
gap__desugar_clean_latest : (p, twin, ts : Nat) -> (flt : Nat -> Gap__expr) -> (marks : List (List Bool)) ->
                            gap__clean (flt p) marks = True ->
                            gap__clean (flt twin) marks = True ->
                            gap__inert_at (gap__marks_at marks p) ts = False ->
                            gap__inert_at (gap__marks_at marks twin) ts = False ->
                            gap__all_clean (gap__desugar (Latest p twin ts flt)) marks = True
gap__desugar_clean_latest p twin ts flt marks fp ft hp ht =
  gap__and_both (gap__clean (flt p) marks)
                (gap__all_clean [flt twin, Op gap__gt (Read twin ts) (Read p ts)] marks)
    fp
    (gap__and_both (gap__clean (flt twin) marks)
                   (gap__all_clean [Op gap__gt (Read twin ts) (Read p ts)] marks)
       ft
       (gap__and_both (gap__clean (Op gap__gt (Read twin ts) (Read p ts)) marks) True
          (gap__and_both (gap__clean (Read twin ts) marks) (gap__clean (Read p ts) marks)
             (cong not ht) (cong not hp))
          Refl))

--@gap
||| A `then … within` WHOSE `ts` IS NOT INERT on either pattern desugars to
||| clean tests: both read `ts` and nothing else.
export
gap__desugar_clean_then : (x, y, ts, bound : Nat) -> (marks : List (List Bool)) ->
                          gap__inert_at (gap__marks_at marks x) ts = False ->
                          gap__inert_at (gap__marks_at marks y) ts = False ->
                          gap__all_clean (gap__desugar (Then x y ts bound)) marks = True
gap__desugar_clean_then x y ts bound marks hx hy =
  let pair : (gap__clean (Op gap__gt (Read y ts) (Read x ts)) marks = True)
      pair = gap__and_both (gap__clean (Read y ts) marks) (gap__clean (Read x ts) marks)
               (cong not hy) (cong not hx)
      window : (gap__clean (Op gap__lt (Op minus (Read y ts) (Read x ts)) (Lit bound)) marks = True)
      window = gap__and_both (gap__clean (Op minus (Read y ts) (Read x ts)) marks) True pair Refl
  in gap__and_both (gap__clean (Op gap__gt (Read y ts) (Read x ts)) marks)
                   (gap__all_clean [Op gap__lt (Op minus (Read y ts) (Read x ts)) (Lit bound)] marks)
       pair
       (gap__and_both (gap__clean (Op gap__lt (Op minus (Read y ts) (Read x ts)) (Lit bound)) marks) True
          window Refl)

--@gap
||| A HOIST OF CLEAN CONJUNCTS IS CLEAN, whatever the compiler picks: the
||| picked and the rest are two selections from one clean list. Which
||| conjuncts MAY be picked (decided ones, RLOW.5.5) is `WhereV5`'s.
export
gap__hoist_clean : (pick : Gap__expr -> Bool) -> (src : List Gap__expr) -> (marks : List (List Bool)) ->
                   gap__all_clean src marks = True ->
                   gap__all_clean (gap__desugar (Hoist pick src)) marks = True
gap__hoist_clean pick src marks p =
  gap__all_clean_append (gap__select pick src) (gap__select (\e => not (pick e)) src) marks
    (gap__all_clean_select pick src marks p)
    (gap__all_clean_select (\e => not (pick e)) src marks p)

-- ---------------------------------------------------------------------
-- And then the base theorem carries across
-- ---------------------------------------------------------------------

--@gap
||| CLEAN TESTS, ONE AND ALL, are worth the same in two working memories
||| that differ in inert values alone: `InertSlots`' theorem over a list.
export
gap__tests_agree : (tests : List Gap__expr) -> (env, env' : List (List Nat)) -> (marks : List (List Bool)) ->
                   gap__all_clean tests marks = True ->
                   gap__erase env marks = gap__erase env' marks ->
                   gap__values tests env = gap__values tests env'
gap__tests_agree tests env env' marks prf same =
  trans (sym (gap__values_ignore_inert tests env marks prf))
        (trans (cong (gap__values tests) same) (gap__values_ignore_inert tests env' marks prf))

--@gap
||| A FORM THE RULE ADMITS IGNORES EVERY INERT VALUE: its desugared tests,
||| clean by the theorems above, are worth one value in two working
||| memories that differ in inert values alone. The rewriting adds no read
||| the rule did not see.
export
gap__form_agrees : (f : Gap__form) -> (env, env' : List (List Nat)) -> (marks : List (List Bool)) ->
                   gap__all_clean (gap__desugar f) marks = True ->
                   gap__erase env marks = gap__erase env' marks ->
                   gap__values (gap__desugar f) env = gap__values (gap__desugar f) env'
gap__form_agrees f env env' marks prf same = gap__tests_agree (gap__desugar f) env env' marks prf same

-- ---------------------------------------------------------------------
-- What the "iff" costs: ts inert, and the forms read the difference
-- ---------------------------------------------------------------------

--@gap
||| Two patterns, two slots each, the second slot inert in both: `ts`
||| declared inert, at slot 1.
public export
gap__ts_inert : List (List Bool)
gap__ts_inert = [[False, True], [False, True]]

--@gap
||| The two working memories of the leak differ in the second pattern's `ts`
||| and in nothing else.
export
gap__ts_leak_differs_in_inert_alone :
  gap__erase [[1, 7], [1, 9]] gap__ts_inert = gap__erase [[1, 7], [1, 20]] gap__ts_inert
gap__ts_leak_differs_in_inert_alone = Refl

--@gap
||| AN INERT `ts` LEAKS THROUGH A `then`: `X then Y within 5`, in two
||| working memories that differ in Y's `ts` alone (9 and 20, X's 7):
||| within the window in one, outside it in the other. 1.2 bars a key and a
||| series source and does not bar `ts`; this is what that costs.
export
gap__inert_ts_leaks_through_then :
  Not (gap__values (gap__desugar (Then 0 1 1 5)) [[1, 7], [1, 9]]
         = gap__values (gap__desugar (Then 0 1 1 5)) [[1, 7], [1, 20]])
gap__inert_ts_leaks_through_then Refl impossible

--@gap
||| AND THROUGH A `latest`: the twin's guard, `twin.ts > x.ts`, in two
||| working memories that differ in the twin's `ts` alone (9 and 5, the
||| anchor's 7): a later twin in one, none in the other, so the anchor is
||| the latest in one and not in the other. The filter reads nothing.
export
gap__inert_ts_leaks_through_latest :
  Not (gap__values (gap__desugar (Latest 0 1 1 (\q => Lit 1))) [[1, 7], [1, 9]]
         = gap__values (gap__desugar (Latest 0 1 1 (\q => Lit 1))) [[1, 7], [1, 5]])
gap__inert_ts_leaks_through_latest Refl impossible

--@gap
||| The rule, applied to the desugared tests, refuses the `then`: its reads
||| of `ts` are not clean.
export
gap__then_on_inert_ts_is_refused :
  gap__all_clean (gap__desugar (Then 0 1 1 5)) gap__ts_inert = False
gap__then_on_inert_ts_is_refused = Refl

--@gap
||| A `latest` whose filter reads an inert slot is refused, as 1.1 lists
||| (`latest(... where ...)`): here the filter is the read, the `ts` is
||| slot 0 and not inert, and the two filters are what fails.
export
gap__latest_filter_on_inert_is_refused :
  gap__all_clean (gap__desugar (Latest 0 1 0 (\q => Read q 1))) gap__ts_inert = False
gap__latest_filter_on_inert_is_refused = Refl

--@gap
||| AND WITH `ts` AT A SLOT THAT IS NOT INERT the same `then` is admitted:
||| `gap__desugar_clean_then`'s hypotheses met, its conclusion computed.
export
gap__then_on_plain_ts_is_admitted :
  gap__all_clean (gap__desugar (Then 0 1 0 5)) gap__ts_inert = True
gap__then_on_plain_ts_is_admitted = Refl

--@gap
||| AND A `latest` WITH A CLEAN FILTER on such a `ts` is admitted:
||| `gap__desugar_clean_latest`'s hypotheses met.
export
gap__latest_on_plain_ts_is_admitted :
  gap__all_clean (gap__desugar (Latest 0 1 0 (\q => Read q 0))) gap__ts_inert = True
gap__latest_on_plain_ts_is_admitted = Refl

--@gap
||| Whether an expression reads a pattern: the predicate a compiler hoists
||| on, a conjunct over one pattern being the alpha test's shape.
public export
gap__reads_pattern : Nat -> Gap__expr -> Bool
gap__reads_pattern n (Lit k) = False
gap__reads_pattern n (Read p s) = p == n
gap__reads_pattern n (Op f a b) = gap__reads_pattern n a || gap__reads_pattern n b
gap__reads_pattern n (Whole f p) = p == n

--@gap
||| A HOIST MOVES A CONJUNCT AND MAKES NONE: of two conjuncts, the one over
||| pattern 1 goes first, the other follows; the two lists hold the same
||| reads.
export
gap__hoist_moves_a_conjunct :
  gap__desugar (Hoist (gap__reads_pattern 1) [Read 0 0, Read 1 0]) = [Read 1 0, Read 0 0]
gap__hoist_moves_a_conjunct = Refl

--@gap
||| AND THE SAME HOIST OF CLEAN CONJUNCTS IS ADMITTED under the marking:
||| `gap__hoist_clean`'s hypothesis met, its conclusion computed.
export
gap__hoist_of_clean_is_admitted :
  gap__all_clean (gap__desugar (Hoist (gap__reads_pattern 1) [Read 0 0, Read 1 0])) gap__ts_inert = True
gap__hoist_of_clean_is_admitted = Refl

--@gap
||| And a conjunct that reads an inert slot is refused on either side of the
||| join: hoisted, it is the alpha test the rule forbids; left, it is the
||| join test it forbids.
export
gap__hoisted_inert_read_is_refused :
  gap__all_clean (gap__desugar (Hoist (gap__reads_pattern 0) [Read 0 1, Read 1 0])) gap__ts_inert = False
gap__hoisted_inert_read_is_refused = Refl

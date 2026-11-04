-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| Inert slots: a value the network never inspects decides nothing.
||| Obligations 1, 4 and 5 of the inert-slot proposal.
|||
||| EVIDENCE FOR A PROPOSAL, NOT A MODEL OF A CLAUSE. No clause states inert
||| slots, so every element here is a gap.
|||
||| THE PROPOSAL. A slot marked `inert` may be read by no `where`, negated
||| pattern, `latest` filter or temporal condition (its 1.1), is no key and no
||| series source (1.2), and in a right-hand side may be copied into an inert
||| slot or passed to a `call`, and operated on by nothing (1.4). Obligation 1
||| asks that no well-typed program let an inert value reach "a comparison,
||| an arithmetic operation, an alpha test, a join test, an index probe, a key
||| or a series".
|||
||| WHAT IS PROVED. That is a claim about every program, so it is proved of
||| every expression and not run on some. An expression is CLEAN when it reads
||| no inert slot. `gap__clean_ignores_inert` says a clean expression is worth
||| the same in an environment and in that environment with every inert value
||| ERASED; so two working memories that differ in inert values alone give
||| every clean expression one value (`gap__clean_agrees`), and a rule every
||| one of whose deciding expressions is clean decides alike in both
||| (`gap__decisions_ignore_inert`). Whatever the network computes from clean
||| expressions -- a test, a probe, a key, a sample -- it computes without
||| the inert values, and whatever a right-hand side writes to a slot that is
||| not inert it writes without them.
|||
||| NOT PROVED, because there is nothing to prove: the pass-through of 1.4. A
||| copy is a bare read of an inert slot, written to an inert slot. That is a
||| rule of syntax, and a theorem that a copy is worth what the read is worth
||| would restate the definition of a copy.
|||
||| WHAT THE THEOREM RESTS ON, which is where the proposal is incomplete. It
||| says nothing of an expression the rule does not reach. `gap__rule` lists
||| the positions whose value decides something or is written where it can be
||| read: the tests, the outputs to slots that are not inert, and with them
||| the correlation key of an `as`, the rate key of a `cooldown`, and the `ts`
||| a `then` orders by. The proposal's 1.1 names the first, its 1.4 the
||| second, and neither names the other three.
||| `gap__unchecked_position_leaks` is what each costs if it is left
||| out: one expression, two working memories that differ in an inert value
||| alone, two values. And an operation on a whole fact reads every slot of
||| it, so it is clean only of a schema with no inert slot
||| (`gap__whole_fact_reads_inert`).
|||
||| OBLIGATION 5, its half that is about expressions. Where no slot is inert
||| the rule refuses nothing (`gap__unmarked_admits_all`) and erasure hides
||| nothing (`gap__unmarked_erases_nothing`). What an expression is WORTH
||| does not take the marking at all, so that it is worth today what it was
||| is by construction and is not stated as a theorem.
|||
||| A `let`. A name bound to an inert read is a reference to no slot, and
||| read where a value decides it is the leak again
||| (`gap__let_carries_the_leak`). The rule on a source expression marks a
||| name TAINTED when what it is bound to is not clean, and refuses the
||| name, not the binding: the binding is how a right-hand side comes to
||| hold what it passes through. `gap__inline_clean` says the rule on names
||| is the rule on what they are bound to: replace every name by its
||| expression and what the one admits the other finds clean. With
||| `gap__inline_value`, that replacing names changes no value, the theorem
||| above carries over (`gap__let_agrees`). It rests on the taints saying no
||| less than the truth; a rule that looks at the deciding expression and no
||| further takes every name for untainted, and admits the leak
||| (`gap__untracked_name_is_admitted`).
|||
||| OBLIGATION 4. A fact is admitted when each of its inert payloads is
||| within the maximum its slot declares (the proposal's A.2). Then what a
||| working memory holds in inert payloads is within the product of the cap
||| on its facts and the sum of the schema's maxima (`gap__memory_within`),
||| and an operation that touches every byte of a fact's payloads costs no
||| more than its rate times that sum (`gap__work_within`). The bound is
||| reached, so it is the least (`gap__bound_is_reached`), and one payload
||| over its maximum breaks it (`gap__over_breaks_the_bound`). This is
||| arithmetic and was never in doubt. What it pins is WHICH product: the
||| realtime contract has no cap that counts these bytes, and its formulas
||| no term that grows with a payload. One schema, its lengths in bytes.
|||
||| NOT MODELLED. Identity, which DOES compare an inert value (1.3): that is
||| obligation 2, and formal/alloy/counterexamples/inert_identity.als. Types:
||| every value here is a number, and every operation is total, so there is
||| no `null`, no fault and no NaN. A `latest`, and a `then` with its
||| `within`, as source forms, and V5's hoisting: each is rewritten into
||| expressions at the positions of `gap__rule` before anything here
||| applies, and that the rewriting keeps "clean" is proved of `let` alone.
||| The words the change reserves.
module InertSlots

import Data.List
import Data.Nat

%default total
%unbound_implicits off

-- ---------------------------------------------------------------------
-- Facts, marks, and erasure
-- ---------------------------------------------------------------------

-- An ENVIRONMENT is the facts a rule's patterns bind, each a list of slot
-- values: `List (List Nat)`. A MARKING says, for each pattern, which of its
-- schema's slots are inert: `List (List Bool)`. Both are written out in every
-- signature below; neither is given a name, because a synonym in a type does
-- not reduce where a definition is matched on it.

--@gap
||| The fact a pattern binds; none, past the last.
public export
gap__fact_at : List (List Nat) -> Nat -> List Nat
gap__fact_at [] p = []
gap__fact_at (f :: fs) Z = f
gap__fact_at (f :: fs) (S k) = gap__fact_at fs k

--@gap
||| The marks of a pattern's schema; none, past the last.
public export
gap__marks_at : List (List Bool) -> Nat -> List Bool
gap__marks_at [] p = []
gap__marks_at (m :: ms) Z = m
gap__marks_at (m :: ms) (S k) = gap__marks_at ms k

--@gap
||| A slot's value; zero, past the last.
public export
gap__val_at : List Nat -> Nat -> Nat
gap__val_at [] s = 0
gap__val_at (x :: xs) Z = x
gap__val_at (x :: xs) (S k) = gap__val_at xs k

--@gap
||| Whether a slot is inert; it is not, past the last mark.
public export
gap__inert_at : List Bool -> Nat -> Bool
gap__inert_at [] s = False
gap__inert_at (m :: ms) Z = m
gap__inert_at (m :: ms) (S k) = gap__inert_at ms k

--@gap
||| Whether a schema has no inert slot.
public export
gap__none_inert : List Bool -> Bool
gap__none_inert [] = True
gap__none_inert (True :: ms) = False
gap__none_inert (False :: ms) = gap__none_inert ms

--@gap
||| A slot's value with an inert one erased.
public export
gap__erase_slot : Bool -> Nat -> Nat
gap__erase_slot True x = 0
gap__erase_slot False x = x

--@gap
||| A fact with every inert value erased. The fact is matched first, so that
||| an empty fact is empty whatever the marks.
public export
gap__erase_fact : List Nat -> List Bool -> List Nat
gap__erase_fact [] ms = []
gap__erase_fact (x :: xs) [] = x :: xs
gap__erase_fact (x :: xs) (m :: ms) = gap__erase_slot m x :: gap__erase_fact xs ms

--@gap
||| An environment with every inert value erased.
public export
gap__erase : List (List Nat) -> List (List Bool) -> List (List Nat)
gap__erase [] mss = []
gap__erase (f :: fs) [] = f :: fs
gap__erase (f :: fs) (ms :: mss) = gap__erase_fact f ms :: gap__erase fs mss

-- ---------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------

--@gap
||| An expression: a literal, a slot read, any operation on two expressions
||| (arithmetic, a comparison, a builtin: the operation is a parameter), and
||| any operation on a whole fact (`fact::Json` is one).
public export
data Gap__expr : Type where
  Lit   : Nat -> Gap__expr
  Read  : (p : Nat) -> (s : Nat) -> Gap__expr
  Op    : (Nat -> Nat -> Nat) -> Gap__expr -> Gap__expr -> Gap__expr
  Whole : (List Nat -> Nat) -> (p : Nat) -> Gap__expr

--@gap
||| What an expression is worth in an environment.
public export
gap__eval : Gap__expr -> List (List Nat) -> Nat
gap__eval (Lit k) env = k
gap__eval (Read p s) env = gap__val_at (gap__fact_at env p) s
gap__eval (Op f a b) env = f (gap__eval a env) (gap__eval b env)
gap__eval (Whole f p) env = f (gap__fact_at env p)

--@gap
||| CLEAN: the expression reads no inert slot. A read of one slot is clean
||| when that slot is not inert; an operation on a whole fact, when no slot
||| of the fact's schema is.
public export
gap__clean : Gap__expr -> List (List Bool) -> Bool
gap__clean (Lit k) marks = True
gap__clean (Read p s) marks = not (gap__inert_at (gap__marks_at marks p) s)
gap__clean (Op f a b) marks = gap__clean a marks && gap__clean b marks
gap__clean (Whole f p) marks = gap__none_inert (gap__marks_at marks p)

-- ---------------------------------------------------------------------
-- Erasure leaves what is not inert
-- ---------------------------------------------------------------------

--@gap
||| A negation that is true is of a falsehood.
export
gap__not_true : (b : Bool) -> not b = True -> b = False
gap__not_true False prf = Refl
gap__not_true True prf = absurd prf

--@gap
||| Both sides of a conjunction that is true.
export
gap__and_left : (x, y : Bool) -> x && y = True -> x = True
gap__and_left True y prf = Refl
gap__and_left False y prf = absurd prf

--@gap
export
gap__and_right : (x, y : Bool) -> x && y = True -> y = True
gap__and_right True y prf = prf
gap__and_right False y prf = absurd prf

--@gap
||| The fact a pattern binds in the erased environment is that pattern's fact,
||| erased by that pattern's marks.
export
gap__erased_fact_at : (env : List (List Nat)) -> (marks : List (List Bool)) -> (p : Nat) ->
                      gap__fact_at (gap__erase env marks) p
                        = gap__erase_fact (gap__fact_at env p) (gap__marks_at marks p)
gap__erased_fact_at [] marks p = Refl
gap__erased_fact_at (f :: fs) [] Z = sym (gap__erase_no_marks f)
  where
    gap__erase_no_marks : (g : List Nat) -> gap__erase_fact g [] = g
    gap__erase_no_marks [] = Refl
    gap__erase_no_marks (x :: xs) = Refl
gap__erased_fact_at (f :: fs) [] (S k) = sym (gap__erase_no_marks (gap__fact_at fs k))
  where
    gap__erase_no_marks : (g : List Nat) -> gap__erase_fact g [] = g
    gap__erase_no_marks [] = Refl
    gap__erase_no_marks (x :: xs) = Refl
gap__erased_fact_at (f :: fs) (ms :: mss) Z = Refl
gap__erased_fact_at (f :: fs) (ms :: mss) (S k) = gap__erased_fact_at fs mss k

--@gap
||| A slot that is not inert has, in the erased fact, the value it had.
export
gap__erased_val_at : (f : List Nat) -> (ms : List Bool) -> (s : Nat) ->
                     gap__inert_at ms s = False ->
                     gap__val_at (gap__erase_fact f ms) s = gap__val_at f s
gap__erased_val_at [] ms s prf = Refl
gap__erased_val_at (x :: xs) [] s prf = Refl
gap__erased_val_at (x :: xs) (True :: ms) Z prf = absurd prf
gap__erased_val_at (x :: xs) (False :: ms) Z prf = Refl
gap__erased_val_at (x :: xs) (m :: ms) (S k) prf = gap__erased_val_at xs ms k prf

--@gap
||| A fact whose schema has no inert slot is, erased, the fact it was.
export
gap__erased_whole : (f : List Nat) -> (ms : List Bool) -> gap__none_inert ms = True ->
                    gap__erase_fact f ms = f
gap__erased_whole [] ms prf = Refl
gap__erased_whole (x :: xs) [] prf = Refl
gap__erased_whole (x :: xs) (True :: ms) prf = absurd prf
gap__erased_whole (x :: xs) (False :: ms) prf = cong (x ::) (gap__erased_whole xs ms prf)

-- ---------------------------------------------------------------------
-- The theorem
-- ---------------------------------------------------------------------

--@gap
||| A CLEAN EXPRESSION IGNORES EVERY INERT VALUE: it is worth in the erased
||| environment what it is worth in the environment. For every expression,
||| every operation, every environment and every marking.
export
gap__clean_ignores_inert : (e : Gap__expr) -> (env : List (List Nat)) -> (marks : List (List Bool)) ->
                           gap__clean e marks = True ->
                           gap__eval e (gap__erase env marks) = gap__eval e env
gap__clean_ignores_inert (Lit k) env marks prf = Refl
gap__clean_ignores_inert (Read p s) env marks prf =
  trans (cong (\f => gap__val_at f s) (gap__erased_fact_at env marks p))
        (gap__erased_val_at (gap__fact_at env p) (gap__marks_at marks p) s
           (gap__not_true (gap__inert_at (gap__marks_at marks p) s) prf))
gap__clean_ignores_inert (Op f a b) env marks prf =
  cong2 f (gap__clean_ignores_inert a env marks (gap__and_left (gap__clean a marks) (gap__clean b marks) prf))
          (gap__clean_ignores_inert b env marks (gap__and_right (gap__clean a marks) (gap__clean b marks) prf))
gap__clean_ignores_inert (Whole f p) env marks prf =
  cong f (trans (gap__erased_fact_at env marks p)
                (gap__erased_whole (gap__fact_at env p) (gap__marks_at marks p) prf))

--@gap
||| TWO WORKING MEMORIES THAT DIFFER IN INERT VALUES ALONE give a clean
||| expression one value.
export
gap__clean_agrees : (e : Gap__expr) -> (env, env' : List (List Nat)) -> (marks : List (List Bool)) ->
                    gap__clean e marks = True ->
                    gap__erase env marks = gap__erase env' marks ->
                    gap__eval e env = gap__eval e env'
gap__clean_agrees e env env' marks prf same =
  trans (sym (gap__clean_ignores_inert e env marks prf))
        (trans (cong (gap__eval e) same) (gap__clean_ignores_inert e env' marks prf))

-- ---------------------------------------------------------------------
-- A rule: every position whose value decides something
-- ---------------------------------------------------------------------

--@gap
||| The expressions of a rule whose values decide something, or are written
||| where they can be read. `tests` are the `where`s, negated patterns,
||| `latest` filters and temporal conditions of the proposal's 1.1. `outputs`
||| are what a right-hand side writes to a slot that is not inert, or hands
||| to a verb, other than a bare copy: its 1.4. The other three it does not
||| name: the correlation key of an `as` on a `call` or an `after`, which is
||| compared; the rate key of a `cooldown`, built from binding values; and
||| the `ts` a `then` orders its patterns by.
public export
record Gap__rule where
  constructor MkRule
  tests     : List Gap__expr
  outputs   : List Gap__expr
  corr_keys : List Gap__expr
  rate_keys : List Gap__expr
  ts_reads  : List Gap__expr

--@gap
||| Every expression of a rule whose value decides something or is written
||| where it can be read.
public export
gap__deciding : Gap__rule -> List Gap__expr
gap__deciding r = tests r ++ outputs r ++ corr_keys r ++ rate_keys r ++ ts_reads r

--@gap
||| Every expression of a list is clean.
public export
gap__all_clean : List Gap__expr -> List (List Bool) -> Bool
gap__all_clean [] marks = True
gap__all_clean (e :: es) marks = gap__clean e marks && gap__all_clean es marks

--@gap
||| What each expression of a list is worth.
public export
gap__values : List Gap__expr -> List (List Nat) -> List Nat
gap__values [] env = []
gap__values (e :: es) env = gap__eval e env :: gap__values es env

--@gap
||| Clean expressions, one and all, are worth in the erased environment what
||| they are worth in the environment.
export
gap__values_ignore_inert : (es : List Gap__expr) -> (env : List (List Nat)) -> (marks : List (List Bool)) ->
                           gap__all_clean es marks = True ->
                           gap__values es (gap__erase env marks) = gap__values es env
gap__values_ignore_inert [] env marks prf = Refl
gap__values_ignore_inert (e :: es) env marks prf =
  cong2 (::) (gap__clean_ignores_inert e env marks (gap__and_left (gap__clean e marks) (gap__all_clean es marks) prf))
             (gap__values_ignore_inert es env marks (gap__and_right (gap__clean e marks) (gap__all_clean es marks) prf))

--@gap
||| A WELL-TYPED RULE DECIDES WITHOUT THE INERT VALUES: if every deciding
||| expression of a rule is clean, then every test, every output, every
||| correlation key, every rate key and every `ts` it reads is worth, in two
||| working memories that differ in inert values alone, the same. No inert
||| value reaches a comparison, a test, a probe or a key through any of
||| them, and none reaches a slot that is not inert.
export
gap__decisions_ignore_inert : (r : Gap__rule) -> (env, env' : List (List Nat)) -> (marks : List (List Bool)) ->
                              gap__all_clean (gap__deciding r) marks = True ->
                              gap__erase env marks = gap__erase env' marks ->
                              gap__values (gap__deciding r) env = gap__values (gap__deciding r) env'
gap__decisions_ignore_inert r env env' marks prf same =
  trans (sym (gap__values_ignore_inert (gap__deciding r) env marks prf))
        (trans (cong (gap__values (gap__deciding r)) same)
               (gap__values_ignore_inert (gap__deciding r) env' marks prf))

-- ---------------------------------------------------------------------
-- What the theorem rests on
-- ---------------------------------------------------------------------

--@gap
||| One pattern, two slots, the second inert.
public export
gap__second_inert : List (List Bool)
gap__second_inert = [[False, True]]

--@gap
||| A POSITION LEFT OUT OF THE RULE LEAKS. The bare read of an inert slot --
||| an `as t.payload`, a `cooldown` keyed on a binding's values, a `ts`
||| declared inert -- in two working memories that differ in that slot
||| alone: two values. Their erasures are one
||| (`gap__leak_differs_in_inert_alone`), so this is the difference the
||| proposal means to make unobservable, observed.
export
gap__unchecked_position_leaks :
  Not (gap__eval (Read 0 1) [[5, 7]] = gap__eval (Read 0 1) [[5, 9]])
gap__unchecked_position_leaks Refl impossible

--@gap
||| The two working memories of the leak differ in the inert slot and in
||| nothing else.
export
gap__leak_differs_in_inert_alone :
  gap__erase [[5, 7]] gap__second_inert = gap__erase [[5, 9]] gap__second_inert
gap__leak_differs_in_inert_alone = Refl

--@gap
||| And the typing rule, where it is applied, refuses it.
export
gap__leak_is_not_clean : gap__clean (Read 0 1) gap__second_inert = False
gap__leak_is_not_clean = Refl

--@gap
||| AND A CLEAN READ OF THE SAME FACT IS ADMITTED AND AGREES: the slot that
||| is not inert, read in the two working memories of the leak, one value.
||| The hypothesis of `gap__clean_ignores_inert` met where the erasure is
||| not the identity.
export
gap__clean_read_agrees :
  ( gap__clean (Read 0 0) gap__second_inert = True
  , gap__eval (Read 0 0) [[5, 7]] = gap__eval (Read 0 0) [[5, 9]] )
gap__clean_read_agrees = (Refl, Refl)

--@gap
||| A rule of one test, one output, one correlation key, one rate key and
||| one `ts` read, every one of them clean of the second slot.
public export
gap__clean_rule : Gap__rule
gap__clean_rule = MkRule [Read 0 0] [Lit 3] [Read 0 0] [Op plus (Read 0 0) (Lit 1)] [Read 0 0]

--@gap
||| THE RULE IS ADMITTED AND DECIDES ALIKE in the two working memories of the
||| leak: `gap__decisions_ignore_inert`'s hypothesis met, and its conclusion
||| computed.
export
gap__clean_rule_decides_alike :
  ( gap__all_clean (gap__deciding gap__clean_rule) gap__second_inert = True
  , gap__values (gap__deciding gap__clean_rule) [[5, 7]] = gap__values (gap__deciding gap__clean_rule) [[5, 9]] )
gap__clean_rule_decides_alike = (Refl, Refl)

--@gap
||| Summing a fact's slots: an operation on the whole fact, as `fact::Json`
||| is.
public export
gap__sum : List Nat -> Nat
gap__sum [] = 0
gap__sum (x :: xs) = x + gap__sum xs

--@gap
||| AN OPERATION ON A WHOLE FACT READS ITS INERT SLOTS. No slot is named in
||| it, so a rule that looks for a reference to an inert slot does not find
||| one; the value differs all the same.
export
gap__whole_fact_reads_inert :
  Not (gap__eval (Whole gap__sum 0) [[5, 7]] = gap__eval (Whole gap__sum 0) [[5, 9]])
gap__whole_fact_reads_inert Refl impossible

--@gap
||| Clean, as defined here, refuses it; the proposal's 1.1 and 1.4 do not
||| say.
export
gap__whole_fact_is_not_clean : gap__clean (Whole gap__sum 0) gap__second_inert = False
gap__whole_fact_is_not_clean = Refl

-- ---------------------------------------------------------------------
-- Obligation 5: with no inert slot, nothing is refused and nothing hidden
-- ---------------------------------------------------------------------

--@gap
||| Whether no slot of any pattern's schema is inert: a program of today.
public export
gap__unmarked : List (List Bool) -> Bool
gap__unmarked [] = True
gap__unmarked (ms :: mss) = gap__none_inert ms && gap__unmarked mss

--@gap
export
gap__and_both : (x, y : Bool) -> x = True -> y = True -> x && y = True
gap__and_both True True Refl Refl = Refl

--@gap
||| In a marking with no inert slot, no pattern's schema has one.
export
gap__unmarked_at : (marks : List (List Bool)) -> (p : Nat) -> gap__unmarked marks = True ->
                   gap__none_inert (gap__marks_at marks p) = True
gap__unmarked_at [] p prf = Refl
gap__unmarked_at (ms :: mss) Z prf = gap__and_left (gap__none_inert ms) (gap__unmarked mss) prf
gap__unmarked_at (ms :: mss) (S k) prf =
  gap__unmarked_at mss k (gap__and_right (gap__none_inert ms) (gap__unmarked mss) prf)

--@gap
||| In a schema with no inert slot, no slot is inert.
export
gap__none_inert_at : (ms : List Bool) -> (s : Nat) -> gap__none_inert ms = True ->
                     gap__inert_at ms s = False
gap__none_inert_at [] s prf = Refl
gap__none_inert_at (True :: ms) s prf = absurd prf
gap__none_inert_at (False :: ms) Z prf = Refl
gap__none_inert_at (False :: ms) (S k) prf = gap__none_inert_at ms k prf

--@gap
||| THE RULE REFUSES NO PROGRAM OF TODAY: where no slot is inert, every
||| expression is clean, whatever it reads and whatever it does.
export
gap__unmarked_admits_all : (e : Gap__expr) -> (marks : List (List Bool)) ->
                           gap__unmarked marks = True -> gap__clean e marks = True
gap__unmarked_admits_all (Lit k) marks prf = Refl
gap__unmarked_admits_all (Read p s) marks prf =
  cong not (gap__none_inert_at (gap__marks_at marks p) s (gap__unmarked_at marks p prf))
gap__unmarked_admits_all (Op f a b) marks prf =
  gap__and_both (gap__clean a marks) (gap__clean b marks)
                (gap__unmarked_admits_all a marks prf) (gap__unmarked_admits_all b marks prf)
gap__unmarked_admits_all (Whole f p) marks prf = gap__unmarked_at marks p prf

--@gap
||| AND ERASURE HIDES NOTHING OF IT: where no slot is inert, the erased
||| environment is the environment. Two working memories that "differ in
||| inert values alone" are then one working memory, so the theorem above
||| says of a program of today that it is worth what it is worth, and no
||| more.
export
gap__unmarked_erases_nothing : (env : List (List Nat)) -> (marks : List (List Bool)) ->
                               gap__unmarked marks = True -> gap__erase env marks = env
gap__unmarked_erases_nothing [] marks prf = Refl
gap__unmarked_erases_nothing (f :: fs) [] prf = Refl
gap__unmarked_erases_nothing (f :: fs) (ms :: mss) prf =
  cong2 (::) (gap__erased_whole f ms (gap__and_left (gap__none_inert ms) (gap__unmarked mss) prf))
             (gap__unmarked_erases_nothing fs mss (gap__and_right (gap__none_inert ms) (gap__unmarked mss) prf))

-- ---------------------------------------------------------------------
-- A `let`: a name bound to an expression, and read later
-- ---------------------------------------------------------------------

--@gap
||| A source expression: an expression, a name a `let` bound (counted from
||| the innermost binding), and a `let` that binds one for its body.
public export
data Gap__src : Type where
  SLit   : Nat -> Gap__src
  SRead  : (p : Nat) -> (s : Nat) -> Gap__src
  SOp    : (Nat -> Nat -> Nat) -> Gap__src -> Gap__src -> Gap__src
  SWhole : (List Nat -> Nat) -> (p : Nat) -> Gap__src
  SVar   : (n : Nat) -> Gap__src
  SLet   : Gap__src -> Gap__src -> Gap__src

--@gap
||| What a source expression is worth in an environment, the names in
||| scope being worth `vars`. A name no `let` binds is worth zero.
public export
gap__src_eval : Gap__src -> List (List Nat) -> List Nat -> Nat
gap__src_eval (SLit k) env vars = k
gap__src_eval (SRead p s) env vars = gap__val_at (gap__fact_at env p) s
gap__src_eval (SOp f a b) env vars = f (gap__src_eval a env vars) (gap__src_eval b env vars)
gap__src_eval (SWhole f p) env vars = f (gap__fact_at env p)
gap__src_eval (SVar n) env vars = gap__val_at vars n
gap__src_eval (SLet a b) env vars = gap__src_eval b env (gap__src_eval a env vars :: vars)

--@gap
||| The expression a name is bound to; the literal zero, past the last.
public export
gap__bound_at : List Gap__expr -> Nat -> Gap__expr
gap__bound_at [] n = Lit 0
gap__bound_at (b :: bs) Z = b
gap__bound_at (b :: bs) (S k) = gap__bound_at bs k

--@gap
||| A source expression with every name replaced by the expression it is
||| bound to: what is left reads slots and nothing else.
public export
gap__inline : Gap__src -> List Gap__expr -> Gap__expr
gap__inline (SLit k) bs = Lit k
gap__inline (SRead p s) bs = Read p s
gap__inline (SOp f a b) bs = Op f (gap__inline a bs) (gap__inline b bs)
gap__inline (SWhole f p) bs = Whole f p
gap__inline (SVar n) bs = gap__bound_at bs n
gap__inline (SLet a b) bs = gap__inline b (gap__inline a bs :: bs)

--@gap
||| A name is worth what the expression it is bound to is worth.
export
gap__bound_value : (bs : List Gap__expr) -> (n : Nat) -> (env : List (List Nat)) ->
                   gap__eval (gap__bound_at bs n) env = gap__val_at (gap__values bs env) n
gap__bound_value [] n env = Refl
gap__bound_value (b :: bs) Z env = Refl
gap__bound_value (b :: bs) (S k) env = gap__bound_value bs k env

--@gap
||| REPLACING NAMES CHANGES NO VALUE: the expression that is left is worth
||| what the source expression is worth, the names being worth what they
||| are bound to.
export
gap__inline_value : (e : Gap__src) -> (bs : List Gap__expr) -> (env : List (List Nat)) ->
                    gap__eval (gap__inline e bs) env = gap__src_eval e env (gap__values bs env)
gap__inline_value (SLit k) bs env = Refl
gap__inline_value (SRead p s) bs env = Refl
gap__inline_value (SOp f a b) bs env = cong2 f (gap__inline_value a bs env) (gap__inline_value b bs env)
gap__inline_value (SWhole f p) bs env = Refl
gap__inline_value (SVar n) bs env = gap__bound_value bs n env
gap__inline_value (SLet a b) bs env =
  trans (gap__inline_value b (gap__inline a bs :: bs) env)
        (cong (\v => gap__src_eval b env (v :: gap__values bs env)) (gap__inline_value a bs env))

--@gap
||| Whether a name is bound to an expression that is not clean. A name no
||| `let` binds is refused with the tainted.
public export
gap__taint_at : List Bool -> Nat -> Bool
gap__taint_at [] n = True
gap__taint_at (t :: ts) Z = t
gap__taint_at (t :: ts) (S k) = gap__taint_at ts k

--@gap
||| CLEAN, for a source expression: it reads no inert slot and no tainted
||| name. A `let` is as clean as its body, in which the name it binds is
||| tainted when what it is bound to is not clean. The BINDING is refused
||| nowhere.
public export
gap__src_clean : Gap__src -> List (List Bool) -> List Bool -> Bool
gap__src_clean (SLit k) marks ts = True
gap__src_clean (SRead p s) marks ts = not (gap__inert_at (gap__marks_at marks p) s)
gap__src_clean (SOp f a b) marks ts = gap__src_clean a marks ts && gap__src_clean b marks ts
gap__src_clean (SWhole f p) marks ts = gap__none_inert (gap__marks_at marks p)
gap__src_clean (SVar n) marks ts = not (gap__taint_at ts n)
gap__src_clean (SLet a b) marks ts = gap__src_clean b marks (not (gap__src_clean a marks ts) :: ts)

--@gap
||| Whether every name marked untainted is bound to a clean expression.
public export
gap__reflects : List Bool -> List Gap__expr -> List (List Bool) -> Bool
gap__reflects [] bs marks = True
gap__reflects (t :: ts) [] marks = False
gap__reflects (t :: ts) (b :: bs) marks = (t || gap__clean b marks) && gap__reflects ts bs marks

--@gap
||| Under taints that say no less than the truth, a name that is not
||| tainted is bound to a clean expression.
export
gap__untainted_is_clean : (ts : List Bool) -> (bs : List Gap__expr) -> (marks : List (List Bool)) ->
                          (n : Nat) -> gap__reflects ts bs marks = True -> gap__taint_at ts n = False ->
                          gap__clean (gap__bound_at bs n) marks = True
gap__untainted_is_clean [] bs marks n ok prf = absurd prf
gap__untainted_is_clean (t :: ts) [] marks n ok prf = absurd ok
gap__untainted_is_clean (True :: ts) (b :: bs) marks Z ok prf = absurd prf
gap__untainted_is_clean (False :: ts) (b :: bs) marks Z ok prf =
  gap__and_left (gap__clean b marks) (gap__reflects ts bs marks) ok
gap__untainted_is_clean (t :: ts) (b :: bs) marks (S k) ok prf =
  gap__untainted_is_clean ts bs marks k
    (gap__and_right (t || gap__clean b marks) (gap__reflects ts bs marks) ok) prf

--@gap
||| What follows from a truth, or the negation of that truth, is true.
export
gap__implies : (x, y : Bool) -> (x = True -> y = True) -> (not x || y) = True
gap__implies False y f = Refl
gap__implies True y f = f Refl

--@gap
||| REPLACING NAMES KEEPS "CLEAN". A source expression the rule admits,
||| under taints that say no less than the truth, is a clean expression
||| once every name in it is replaced by what it is bound to.
export
gap__inline_clean : (e : Gap__src) -> (marks : List (List Bool)) -> (ts : List Bool) ->
                    (bs : List Gap__expr) -> gap__reflects ts bs marks = True ->
                    gap__src_clean e marks ts = True ->
                    gap__clean (gap__inline e bs) marks = True
gap__inline_clean (SLit k) marks ts bs ok prf = Refl
gap__inline_clean (SRead p s) marks ts bs ok prf = prf
gap__inline_clean (SOp f a b) marks ts bs ok prf =
  gap__and_both (gap__clean (gap__inline a bs) marks) (gap__clean (gap__inline b bs) marks)
    (gap__inline_clean a marks ts bs ok
       (gap__and_left (gap__src_clean a marks ts) (gap__src_clean b marks ts) prf))
    (gap__inline_clean b marks ts bs ok
       (gap__and_right (gap__src_clean a marks ts) (gap__src_clean b marks ts) prf))
gap__inline_clean (SWhole f p) marks ts bs ok prf = prf
gap__inline_clean (SVar n) marks ts bs ok prf =
  gap__untainted_is_clean ts bs marks n ok (gap__not_true (gap__taint_at ts n) prf)
gap__inline_clean (SLet a b) marks ts bs ok prf =
  gap__inline_clean b marks (not (gap__src_clean a marks ts) :: ts) (gap__inline a bs :: bs)
    (gap__and_both (not (gap__src_clean a marks ts) || gap__clean (gap__inline a bs) marks)
                   (gap__reflects ts bs marks)
                   (gap__implies (gap__src_clean a marks ts) (gap__clean (gap__inline a bs) marks)
                                 (\h => gap__inline_clean a marks ts bs ok h))
                   ok)
    prf

--@gap
||| A SOURCE EXPRESSION THE RULE ADMITS IGNORES EVERY INERT VALUE, whatever
||| it binds and however deep: in two working memories that differ in inert
||| values alone it is worth one value.
export
gap__let_agrees : (e : Gap__src) -> (env, env' : List (List Nat)) -> (marks : List (List Bool)) ->
                  gap__src_clean e marks [] = True ->
                  gap__erase env marks = gap__erase env' marks ->
                  gap__src_eval e env [] = gap__src_eval e env' []
gap__let_agrees e env env' marks prf same =
  trans (sym (gap__inline_value e [] env))
        (trans (gap__clean_agrees (gap__inline e []) env env' marks
                  (gap__inline_clean e marks [] [] Refl prf) same)
               (gap__inline_value e [] env'))

--@gap
||| A NAME CARRIES WHAT IT IS BOUND TO. `let x = t.payload`, and then `x`
||| where a value decides: no inert slot is named where it is read, and the
||| two working memories of the leak give it two values.
export
gap__let_carries_the_leak :
  Not (gap__src_eval (SLet (SRead 0 1) (SVar 0)) [[5, 7]] []
         = gap__src_eval (SLet (SRead 0 1) (SVar 0)) [[5, 9]] [])
gap__let_carries_the_leak Refl impossible

--@gap
||| The rule refuses it: the name is tainted by what it is bound to.
export
gap__let_use_is_refused : gap__src_clean (SLet (SRead 0 1) (SVar 0)) gap__second_inert [] = False
gap__let_use_is_refused = Refl

--@gap
||| And admits the binding where the name is not read: a `let` bound to an
||| inert slot, over a body that reads a slot that is not.
export
gap__let_unread_is_admitted :
  gap__src_clean (SLet (SRead 0 1) (SRead 0 0)) gap__second_inert [] = True
gap__let_unread_is_admitted = Refl

--@gap
||| AND THE ADMITTED `let` IS WORTH ONE VALUE in the two working memories of
||| the leak: `gap__let_agrees`' hypothesis met where a name is bound to
||| the inert slot and not read.
export
gap__let_unread_agrees :
  gap__src_eval (SLet (SRead 0 1) (SRead 0 0)) [[5, 7]] [] = gap__src_eval (SLet (SRead 0 1) (SRead 0 0)) [[5, 9]] []
gap__let_unread_agrees = Refl

--@gap
||| A RULE THAT LOOKS AT THE DECIDING EXPRESSION AND NO FURTHER takes every
||| name for untainted, and admits the name that carries the leak.
export
gap__untracked_name_is_admitted : gap__src_clean (SVar 0) gap__second_inert [False] = True
gap__untracked_name_is_admitted = Refl

--@gap
||| What it took for granted is false: the name is bound to an inert read,
||| so taints that call it untainted say less than the truth, and the
||| theorem's premise does not hold of them.
export
gap__untracked_name_is_a_lie : gap__reflects [False] [Read 0 1] gap__second_inert = False
gap__untracked_name_is_a_lie = Refl

-- ---------------------------------------------------------------------
-- Obligation 4: what is held is within what was declared
-- ---------------------------------------------------------------------

-- The order lemmas are the base's: `reflexive`, `transitive`,
-- `lteSuccRight`, `lteAddRight`, `succNotLTEzero` (Data.Nat, 0.8.0). Two
-- are proved here because the base states them the other way round.

--@gap
||| The base's `lteAddRight` puts the summand on the right; this puts it
||| on the left.
export
gap__lte_left : (a, b : Nat) -> LTE b (a + b)
gap__lte_left a b = replace {p = \z => LTE b z} (plusCommutative b a) (lteAddRight b)

--@gap
||| Sums of what is within are within.
export
gap__lte_plus : {a, c : Nat} -> (b, d : Nat) -> LTE a b -> LTE c d -> LTE (a + c) (b + d)
gap__lte_plus b d LTEZero q = transitive q (gap__lte_left b d)
gap__lte_plus (S b) d (LTESucc p) q = LTESucc (gap__lte_plus b d p q)

--@gap
||| And so are multiples.
export
gap__lte_times : {n : Nat} -> (c, b : Nat) -> LTE n c -> LTE (n * b) (c * b)
gap__lte_times c b LTEZero = LTEZero
gap__lte_times (S c) b (LTESucc p) = gap__lte_plus b (c * b) reflexive (gap__lte_times c b p)

--@gap
||| The test an assert is admitted on is the Prelude's `lte`; this is what a
||| true answer means.
export
gap__le_sound : (a, b : Nat) -> lte a b = True -> LTE a b
gap__le_sound Z b prf = LTEZero
gap__le_sound (S a) Z prf = absurd prf
gap__le_sound (S a) (S b) prf = LTESucc (gap__le_sound a b prf)

--@gap
||| Whether a fact's inert payloads, by their lengths, are each within the
||| maximum its slot declares, slot by slot and as many.
public export
gap__fits : List Nat -> List Nat -> Bool
gap__fits [] [] = True
gap__fits [] (m :: ms) = False
gap__fits (l :: ls) [] = False
gap__fits (l :: ls) (m :: ms) = lte l m && gap__fits ls ms

--@gap
||| A FACT THAT IS ADMITTED HOLDS NO MORE THAN ITS SCHEMA DECLARES.
export
gap__fact_within : (ls, ms : List Nat) -> gap__fits ls ms = True ->
                   LTE (gap__sum ls) (gap__sum ms)
gap__fact_within [] [] prf = LTEZero
gap__fact_within [] (m :: ms) prf = absurd prf
gap__fact_within (l :: ls) [] prf = absurd prf
gap__fact_within (l :: ls) (m :: ms) prf =
  gap__lte_plus m (gap__sum ms)
    (gap__le_sound l m (gap__and_left (lte l m) (gap__fits ls ms) prf))
    (gap__fact_within ls ms (gap__and_right (lte l m) (gap__fits ls ms) prf))

--@gap
||| Whether every fact of a working memory was admitted.
public export
gap__all_fit : List (List Nat) -> List Nat -> Bool
gap__all_fit [] ms = True
gap__all_fit (f :: fs) ms = gap__fits f ms && gap__all_fit fs ms

--@gap
||| What a working memory holds in inert payloads.
public export
gap__held : List (List Nat) -> Nat
gap__held [] = 0
gap__held (f :: fs) = gap__sum f + gap__held fs

--@gap
||| What is held is within the count of facts times the sum of the maxima.
export
gap__held_within : (wm : List (List Nat)) -> (ms : List Nat) -> gap__all_fit wm ms = True ->
                   LTE (gap__held wm) (length wm * gap__sum ms)
gap__held_within [] ms prf = LTEZero
gap__held_within (f :: fs) ms prf =
  gap__lte_plus (gap__sum ms) (length fs * gap__sum ms)
    (gap__fact_within f ms (gap__and_left (gap__fits f ms) (gap__all_fit fs ms) prf))
    (gap__held_within fs ms (gap__and_right (gap__fits f ms) (gap__all_fit fs ms) prf))

--@gap
||| WHAT A WORKING MEMORY HOLDS IN INERT PAYLOADS IS WITHIN THE PRODUCT of
||| the cap on its facts and the sum of its schema's maxima: for every
||| working memory within the cap, every payload and every declaration.
export
gap__memory_within : (wm : List (List Nat)) -> (ms : List Nat) -> (cap : Nat) ->
                     gap__all_fit wm ms = True -> LTE (length wm) cap ->
                     LTE (gap__held wm) (cap * gap__sum ms)
gap__memory_within wm ms cap fit within =
  transitive (gap__held_within wm ms fit) (gap__lte_times cap (gap__sum ms) within)

--@gap
||| AN OPERATION THAT TOUCHES EVERY BYTE OF A FACT'S PAYLOADS, at `c` a
||| byte -- the copy of an assert or of an `emit`, the comparison of a
||| reassert, a validation -- costs no more than `c` times the sum of the
||| schema's maxima, which is a constant of the deployment.
export
gap__work_within : (c : Nat) -> (ls, ms : List Nat) -> gap__fits ls ms = True ->
                   LTE (gap__sum ls * c) (gap__sum ms * c)
gap__work_within c ls ms prf = gap__lte_times (gap__sum ms) c (gap__fact_within ls ms prf)

--@gap
||| THE BOUND IS REACHED, so it is the least: two facts at their maxima
||| hold the product exactly.
export
gap__bound_is_reached : gap__held [[4, 2], [4, 2]] = 2 * gap__sum [4, 2]
gap__bound_is_reached = Refl

--@gap
||| A payload one over its maximum is not admitted.
export
gap__over_is_refused : gap__fits [3, 1] [2, 1] = False
gap__over_is_refused = Refl

--@gap
||| WHAT THE REFUSAL IS FOR: admitted all the same, that one fact, in a
||| working memory within its cap, holds more than the product.
export
gap__over_breaks_the_bound : Not (LTE (gap__held [[3, 1]]) (1 * gap__sum [2, 1]))
gap__over_breaks_the_bound (LTESucc (LTESucc (LTESucc p))) = succNotLTEzero p

--@gap
||| AND THE HYPOTHESES OF THE BOUND ARE MET by the two facts that reach it:
||| each fits its maxima, and two is within a cap of two.
export
gap__bound_hypotheses_met : (gap__all_fit [[4, 2], [4, 2]] [4, 2] = True, LTE (length [[4, 2], [4, 2]]) 2)
gap__bound_hypotheses_met = (Refl, reflexive)

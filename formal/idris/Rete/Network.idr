-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The Rete network as the specs define it: the alpha network [IRET.6],
||| the beta network [IRET.7], terminals and the agenda [IRET.8], [IRET.11],
||| working-memory operations [IRET.19], and the firing loop [IRET.11.4] —
||| incremental, node by node, under the recompute that Rete/FireLoop.idr
||| states directly.
|||
||| NORMATIVE COMPANION, on the same mechanisms as Rete/FireLoop.idr, and
||| a model of the specification, not of the reference engine: every
||| definition is read from the clause named above it.
|||
||| WHAT IS MODELLED. One alpha node per (schema, tests) [IRET.6.1],
||| [IRET.6.6], holding the facts of its schema that pass its tests
||| [IRET.6.5]. One linear chain of beta nodes per rule, in LHS pattern
||| order RLOW.4.2.1, [IRET.7.10.1]; a beta node references its right
||| alpha, carries its join tests over (positive prefix, candidate)
||| [IRET.7.5], [IRET.7.6], [RDSC.4a.9.1], a negative flag [IRET.7.9], its
||| left memory of prefix tokens [IRET.7.4], and, for a NOT node, block
||| counts by token identity [IRET.7.9.4]. A root node's left input is the
||| nil token [RDSC.4a.7]. The four propagation paths of [IRET.7.7] and the
||| NOT paths of [IRET.7.9.1]–[IRET.7.9.3] are `iret_7_7__wave`,
||| `iret_7_8__unwave`, `iret_7_7__right_activate` and
||| `iret_7_7__right_retract`; each threads the rule's terminal through,
||| so an activation ends or begins at the node that decides it. A fact
||| reaching several nodes of one chain right-activates the deeper node
||| first, so a token the shallower activation creates never meets its own
||| fact twice (the reading [IRET.7.7] needs to produce each match once). A terminal holds the rule's
||| activations [IRET.8.1] in
||| timetag order, and the timetag of a match is its canonical key
||| [LDET.5.5], [LDET.5.9]: the assertion positions of its facts, the
||| latest first, then in pattern order. Selection is by
||| (ordinal, timetag) [IRET.11.1], [LDET.5.1]; refraction is the `fired`
||| flag [IDAT.6.2.2]. Assert and retract are Rete/FireLoop.idr's
||| lifecycle-aware operations [IRET.19.1], [IRET.19.2], followed by alpha
||| dispatch [IRET.6.4], [IRET.1.7].
|||
||| WHAT IS NOT. Expression evaluation (alpha and join tests are
||| predicates), `__ClockTick__`, `within`, `then`, `latest`, activation
||| scope, hash pre-filters (identity is the fact tuple), and every cap.
module Rete.Network

import Rete.FireLoop
import Rete.PumpBoundary
import Lcyc.Lemmas
import Data.List
import Data.List.Elem
import Data.List.Quantifiers
import Data.Nat
import Decidable.Equality

%default total

-- ---------------------------------------------------------------------
-- The alpha network [IRET.6]
-- ---------------------------------------------------------------------

--@spec [IRET.6.1]
||| One pattern-schema participation: the schema it matches, its inline
||| tests over one fact [IRET.6.2], and its memory — the facts of that
||| schema currently passing the tests [IRET.6.5].
public export
record Iret_6_1__alpha where
  constructor MkAlpha
  akind : Nat
  atest : Lfac_1_7_1__fact -> Bool
  amem  : List Lfac_1_7_1__fact

--@spec [IRET.6.4]
||| A fact of the node's schema that passes all its tests.
public export
iret_6_4__admits : Iret_6_1__alpha -> Lfac_1_7_1__fact -> Bool
iret_6_4__admits a f = (fkind f == akind a) && atest a f

--@spec [IRET.6.5]
public export
iret_6_5__insert : Lfac_1_7_1__fact -> Iret_6_1__alpha -> Iret_6_1__alpha
iret_6_5__insert f a = MkAlpha (akind a) (atest a) (amem a ++ [f])

--@spec [IRET.6.5]
public export
iret_6_5__remove : Lfac_1_7_1__fact -> Iret_6_1__alpha -> Iret_6_1__alpha
iret_6_5__remove f a = MkAlpha (akind a) (atest a) (rarc_5_6_4__remove_exact f (amem a))

--@derives [IRET.6.5]
||| What the memory must hold: the facts of the schema passing the tests,
||| in working-memory order.
public export
iret_6_5__view : Iret_6_1__alpha -> Rarc_5_6_4__wm -> List Lfac_1_7_1__fact
iret_6_5__view a wm = filter (iret_6_4__admits a) wm

--@spec [IRET.6.6]
||| The node a reference resolves to; a dangling reference is a node that
||| admits nothing. A function of its own so that a proof can reduce it
||| by rewriting the lookup alone.
public export
iret_6_6__alpha_or : Maybe Iret_6_1__alpha -> Iret_6_1__alpha
iret_6_6__alpha_or (Just a) = a
iret_6_6__alpha_or Nothing = MkAlpha 0 (\_ => False) []

--@spec [IRET.6.6]
||| A beta node references its right alpha by position [RDSC.4a.3]; a
||| dangling reference admits nothing.
public export
iret_6_6__alpha_at : List Iret_6_1__alpha -> Nat -> Iret_6_1__alpha
iret_6_6__alpha_at alphas i = iret_6_6__alpha_or (rarc_5_6_5__nth i alphas)

--@spec [IRET.6.6]
public export
iret_6_6__mem_at : List Iret_6_1__alpha -> Nat -> List Lfac_1_7_1__fact
iret_6_6__mem_at alphas i = amem (iret_6_6__alpha_at alphas i)

-- ---------------------------------------------------------------------
-- Tokens and beta nodes [IRET.7]
-- ---------------------------------------------------------------------

--@spec [IRET.7.1]
||| A token: the facts bound so far, one per positive pattern, in pattern
||| order. Its identity is the tuple [IRET.11.3]; its timetag is a
||| function of the tuple (`ldet_5_5__before`), so it is not stored.
public export
Iret_7_1__token : Type
Iret_7_1__token = List Lfac_1_7_1__fact

--@spec [IRET.7.4]
||| A beta node: its right alpha, its join tests over the positive prefix
||| and the candidate [IRET.7.5], whether it is a NOT node [IRET.7.9], its
||| left memory, and — NOT nodes only — the block count of each blocked
||| token, keyed by identity [IRET.7.9.4]. The right memory is the alpha's.
public export
record Iret_7_4__beta where
  constructor MkBeta
  balpha  : Nat
  bjoin   : Iret_7_1__token -> Lfac_1_7_1__fact -> Bool
  bneg    : Bool
  blmem   : List Iret_7_1__token
  bcounts : List (Iret_7_1__token, Nat)

--@spec [IRET.7.4]
public export
iret_7_4__with_lmem : List Iret_7_1__token -> List (Iret_7_1__token, Nat) -> Iret_7_4__beta -> Iret_7_4__beta
iret_7_4__with_lmem lm cs b = MkBeta (balpha b) (bjoin b) (bneg b) lm cs

--@spec [IRET.7.5]
||| A node's join tests, as one predicate over the positive prefix and the
||| candidate. The propagation lemmas are stated over this predicate and
||| the negative flag rather than over the node, so that a node's stored
||| memory never enters a statement about what it passes on.
public export
Iret_7_5__join : Type
Iret_7_5__join = Iret_7_1__token -> Lfac_1_7_1__fact -> Bool

--@spec [IRET.7.6]
||| The candidate facts of the right memory that pass every join test
||| against the token.
public export
iret_7_6__joining : Iret_7_5__join -> List Lfac_1_7_1__fact -> Iret_7_1__token -> List Lfac_1_7_1__fact
iret_7_6__joining j mem t = filter (j t) mem

--@spec [IRET.7.2]
||| The extended tokens: the token plus each joining fact, last.
public export
iret_7_2__extend_tok : Iret_7_5__join -> List Lfac_1_7_1__fact -> Iret_7_1__token -> List Iret_7_1__token
iret_7_2__extend_tok j mem t = map (\f => t ++ [f]) (iret_7_6__joining j mem t)

--@spec [IRET.7.7]
public export
iret_7_7__extend_front : Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_7__extend_front j mem front = rarc_5_6_5__concat_map (iret_7_2__extend_tok j mem) front

--@spec [IRET.7.9.4]
||| The block count of a token: zero when no entry is held.
public export
iret_7_9_4__count : Iret_7_1__token -> List (Iret_7_1__token, Nat) -> Nat
iret_7_9_4__count t [] = 0
iret_7_9_4__count t ((u, n) :: rest) = if u == t then n else iret_7_9_4__count t rest

--@spec [IRET.7.9.4]
||| Set a token's count; a zero count holds no entry.
public export
iret_7_9_4__set_count : Iret_7_1__token -> Nat -> List (Iret_7_1__token, Nat) -> List (Iret_7_1__token, Nat)
iret_7_9_4__set_count t n cs =
  let rest = filter (\e => not (fst e == t)) cs
  in if n == 0 then rest else (t, n) :: rest

--@spec [IRET.7.9.1]
||| How many right facts block a token.
public export
iret_7_9_1__blockers : Iret_7_5__join -> List Lfac_1_7_1__fact -> Iret_7_1__token -> Nat
iret_7_9_1__blockers j mem t = length (iret_7_6__joining j mem t)

--@spec [IRET.7.9.1]
||| The tokens a NOT node passes: those nothing blocks.
public export
iret_7_9_1__pass : Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_9_1__pass j mem front = filter (\t => iret_7_9_1__blockers j mem t == 0) front

--@spec [IRET.7.9.1]
||| Record the block count of each arriving token.
public export
iret_7_9_1__record : Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List (Iret_7_1__token, Nat) -> List (Iret_7_1__token, Nat)
iret_7_9_1__record j mem [] cs = cs
iret_7_9_1__record j mem (t :: ts) cs = iret_7_9_1__record j mem ts (iret_7_9_4__set_count t (iret_7_9_1__blockers j mem t) cs)

--@spec [IRET.7.9.2]
||| A new blocking fact: every left token it joins gains a blocker.
public export
iret_7_9_2__block : List Iret_7_1__token -> List (Iret_7_1__token, Nat) -> List (Iret_7_1__token, Nat)
iret_7_9_2__block [] cs = cs
iret_7_9_2__block (t :: ts) cs = iret_7_9_2__block ts (iret_7_9_4__set_count t (S (iret_7_9_4__count t cs)) cs)

--@spec [IRET.7.9.3]
||| A blocking fact retracted: every left token it joined loses one.
public export
iret_7_9_3__unblock : List Iret_7_1__token -> List (Iret_7_1__token, Nat) -> List (Iret_7_1__token, Nat)
iret_7_9_3__unblock [] cs = cs
iret_7_9_3__unblock (t :: ts) cs = iret_7_9_3__unblock ts (iret_7_9_4__set_count t (pred (iret_7_9_4__count t cs)) cs)

--@spec [IRET.7.7]
--@spec [IRET.7.9.1]
||| What a node passes on from the tokens it receives: their joins with
||| its right memory, or, for a NOT node, those the memory leaves
||| unblocked, unextended [IRET.7.9.5]. By the negative flag and the join
||| tests.
public export
iret_7_7__next_of : Bool -> Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_7__next_of True  j mem front = iret_7_9_1__pass j mem front
iret_7_7__next_of False j mem front = iret_7_7__extend_front j mem front

--@spec [IRET.7.7]
public export
iret_7_7__next : Iret_7_4__beta -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_7__next b mem front = iret_7_7__next_of (bneg b) (bjoin b) mem front

--@spec [IRET.7.9.1]
||| The counts after arrivals: a NOT node records theirs.
public export
iret_7_9_1__counts_of : Bool -> Iret_7_5__join -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List (Iret_7_1__token, Nat) -> List (Iret_7_1__token, Nat)
iret_7_9_1__counts_of True  j mem front cs = iret_7_9_1__record j mem front cs
iret_7_9_1__counts_of False j mem front cs = cs

--@spec [IRET.7.7]
--@spec [IRET.7.4]
--@spec [IRET.7.9.1]
||| Store arriving tokens in the left memory; a NOT node records their
||| block counts.
public export
iret_7_7__store : Iret_7_4__beta -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> Iret_7_4__beta
iret_7_7__store b mem front =
  iret_7_4__with_lmem (blmem b ++ front) (iret_7_9_1__counts_of (bneg b) (bjoin b) mem front (bcounts b)) b

--@spec [IRET.7.8]
||| Drop departing tokens from the left memory, and their counts.
public export
iret_7_8__drop : Iret_7_4__beta -> List Iret_7_1__token -> Iret_7_4__beta
iret_7_8__drop b gone =
  iret_7_4__with_lmem (filter (\t => not (rarc_5_6_5__elem t gone)) (blmem b)) (filter (\e => not (rarc_5_6_5__elem (fst e) gone)) (bcounts b)) b

--@spec [IRET.7.8]
||| What leaves downstream when tokens leave a node: every extension built
||| from them — their joins with the current right memory — or, for a NOT
||| node, those it had passed. By the flag, the join tests and the counts.
public export
iret_7_8__gone_of : Bool -> Iret_7_5__join -> List (Iret_7_1__token, Nat) -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_8__gone_of True  j cs mem gone = filter (\t => iret_7_9_4__count t cs == 0) gone
iret_7_8__gone_of False j cs mem gone = iret_7_7__extend_front j mem gone

--@spec [IRET.7.8]
public export
iret_7_8__gone : Iret_7_4__beta -> List Lfac_1_7_1__fact -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_8__gone b mem gone = iret_7_8__gone_of (bneg b) (bjoin b) (bcounts b) mem gone

-- ---------------------------------------------------------------------
-- Terminals and timetags [IRET.8], [LDET.5]
-- ---------------------------------------------------------------------

--@spec [IRET.8.1]
--@spec [IRET.11]
||| An activation: the match, and whether it has fired [IDAT.6.2.2].
public export
record Iret_8_1__act where
  constructor MkAct
  atuple : Iret_7_1__token
  afired : Bool

--@spec [IRET.8.1]
public export
iret_8_1__tuples : List Iret_8_1__act -> List Iret_7_1__token
iret_8_1__tuples acts = map atuple acts

--@spec [LDET.5.5]
||| The assertion position of a live fact: its index in the working-memory
||| sequence, which with never-reused ids [IRET.4.4] is its id's rank.
public export
ldet_5_5__pos : Rarc_5_6_4__wm -> Lfac_1_7_1__fact -> Nat
ldet_5_5__pos [] f = 0
ldet_5_5__pos (g :: gs) f = if g == f then 0 else S (ldet_5_5__pos gs f)

--@spec [LDET.5.5]
||| Strict order on positions, by structural recursion so that a proof
||| can unfold it.
public export
ldet_5_5__lt : Nat -> Nat -> Bool
ldet_5_5__lt _ Z = False
ldet_5_5__lt Z (S _) = True
ldet_5_5__lt (S a) (S b) = ldet_5_5__lt a b

--@spec [LDET.5.5]
public export
ldet_5_5__max : Nat -> Nat -> Nat
ldet_5_5__max Z b = b
ldet_5_5__max (S a) Z = S a
ldet_5_5__max (S a) (S b) = S (ldet_5_5__max a b)

--@spec [LDET.5.5]
||| The key: the positions of the tuple's facts, in pattern order.
public export
ldet_5_5__key : Rarc_5_6_4__wm -> Iret_7_1__token -> List Nat
ldet_5_5__key wm t = map (ldet_5_5__pos wm) t

--@spec [LDET.5.5]
||| The latest position of a key: when the match completed.
public export
ldet_5_5__latest : List Nat -> Nat
ldet_5_5__latest [] = 0
ldet_5_5__latest (x :: xs) = ldet_5_5__max x (ldet_5_5__latest xs)

--@spec [LDET.5.5]
public export
ldet_5_5__lex_lt : List Nat -> List Nat -> Bool
ldet_5_5__lex_lt [] [] = False
ldet_5_5__lex_lt [] (_ :: _) = True
ldet_5_5__lex_lt (_ :: _) [] = False
ldet_5_5__lex_lt (x :: xs) (y :: ys) = if ldet_5_5__lt x y then True else if x == y then ldet_5_5__lex_lt xs ys else False

--@spec [LDET.5.5]
||| The order on keys: the earlier completion first, then pattern order.
public export
ldet_5_5__before_keys : List Nat -> List Nat -> Bool
ldet_5_5__before_keys ks kt =
  if ldet_5_5__lt (ldet_5_5__latest ks) (ldet_5_5__latest kt) then True
  else if ldet_5_5__latest ks == ldet_5_5__latest kt then ldet_5_5__lex_lt ks kt
  else False

--@spec [LDET.5.5]
--@spec [LDET.5.9]
||| THE CREATION TIMETAG, as an order: `s` was created before `t` when it
||| completed at an earlier assertion, or at the same one and its facts
||| come first in pattern order. A function of the two matches and of
||| working memory alone, never of how either was reached.
public export
ldet_5_5__before : Rarc_5_6_4__wm -> Iret_7_1__token -> Iret_7_1__token -> Bool
ldet_5_5__before wm s t = ldet_5_5__before_keys (ldet_5_5__key wm s) (ldet_5_5__key wm t)

--@spec [LDET.5.5]
||| A new activation takes its timetag's place among the rule's.
public export
ldet_5_5__insert : Rarc_5_6_4__wm -> Iret_8_1__act -> List Iret_8_1__act -> List Iret_8_1__act
ldet_5_5__insert wm a [] = [a]
ldet_5_5__insert wm a (b :: bs) = if ldet_5_5__before wm (atuple a) (atuple b) then a :: b :: bs else b :: ldet_5_5__insert wm a bs

--@spec [IRET.8.1]
||| New matches become unfired activations, each at its place.
public export
iret_8_1__activate : Rarc_5_6_4__wm -> List Iret_7_1__token -> List Iret_8_1__act -> List Iret_8_1__act
iret_8_1__activate wm [] acts = acts
iret_8_1__activate wm (t :: ts) acts = iret_8_1__activate wm ts (ldet_5_5__insert wm (MkAct t False) acts)

--@spec [IRET.8.1]
--@spec [IRET.7.8]
||| Ended matches leave, fired or not.
public export
iret_8_1__end : List Iret_7_1__token -> List Iret_8_1__act -> List Iret_8_1__act
iret_8_1__end gone acts = filter (\a => not (rarc_5_6_5__elem (atuple a) gone)) acts

-- ---------------------------------------------------------------------
-- The four propagation paths [IRET.7.7], [IRET.7.9]
-- ---------------------------------------------------------------------

--@spec [IRET.7.7]
--@spec [IRET.7.9.1]
--@spec [IRET.8.1]
||| LEFT-ACTIVATION, as a wave: the tokens arriving at the head node from
||| its left parent are stored in its left memory and joined against its
||| right memory; the extended tokens flow on. A NOT node stores the
||| arrivals, records how many right facts block each, and passes only
||| the unblocked. What leaves the last node activates the terminal.
public export
iret_7_7__wave : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_8_1__act -> (List Iret_7_4__beta, List Iret_8_1__act)
iret_7_7__wave wm alphas [] front acts = ([], iret_8_1__activate wm front acts)
iret_7_7__wave wm alphas (b :: rest) front acts =
  let mem = iret_6_6__mem_at alphas (balpha b)
      r = iret_7_7__wave wm alphas rest (iret_7_7__next b mem front) acts
  in (iret_7_7__store b mem front :: fst r, snd r)

--@spec [IRET.7.7]
--@spec [IRET.7.8]
||| LEFT-RETRACTION, as a wave: the tokens leaving the head node are
||| dropped from its left memory; every extension built from them leaves
||| too, or, for a NOT node, the tokens it had passed. What leaves the
||| last node ends the corresponding activations.
public export
iret_7_8__unwave : List Iret_6_1__alpha -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_8_1__act -> (List Iret_7_4__beta, List Iret_8_1__act)
iret_7_8__unwave alphas [] gone acts = ([], iret_8_1__end gone acts)
iret_7_8__unwave alphas (b :: rest) gone acts =
  let mem = iret_6_6__mem_at alphas (balpha b)
      r = iret_7_8__unwave alphas rest (iret_7_8__gone b mem gone) acts
  in (iret_7_8__drop b gone :: fst r, snd r)

--@spec [IRET.7.7]
--@spec [IRET.7.9.2]
||| RIGHT-ACTIVATION of every node of a chain fed by alpha `a`, deepest
||| node first, for a fact just admitted to `a`'s memory. A positive node
||| extends each left token the fact joins and sends the extensions down
||| the chain; a NOT node counts the fact against each left token it
||| joins and retracts downstream the tokens it newly blocks.
public export
iret_7_7__right_activate : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> List Iret_7_4__beta -> List Iret_8_1__act -> (List Iret_7_4__beta, List Iret_8_1__act)
iret_7_7__right_activate wm alphas a f [] acts = ([], acts)
iret_7_7__right_activate wm alphas a f (b :: rest) acts =
  let r1 = iret_7_7__right_activate wm alphas a f rest acts
      hit = filter (\t => bjoin b t f) (blmem b)
  in if balpha b == a
       then if bneg b
              then let r2 = iret_7_8__unwave alphas (fst r1) (filter (\t => iret_7_9_4__count t (bcounts b) == 0) hit) (snd r1)
                   in (iret_7_4__with_lmem (blmem b) (iret_7_9_2__block hit (bcounts b)) b :: fst r2, snd r2)
              else let r2 = iret_7_7__wave wm alphas (fst r1) (map (\t => t ++ [f]) hit) (snd r1)
                   in (b :: fst r2, snd r2)
       else (b :: fst r1, snd r1)

--@spec [IRET.7.7]
--@spec [IRET.7.9.3]
||| RIGHT-RETRACTION of every node of a chain fed by alpha `a`, deepest
||| node first, for a fact just removed from `a`'s memory. A positive
||| node retracts downstream each extension it had built from the fact;
||| a NOT node uncounts the fact against each left token it joined and
||| releases downstream the tokens it no longer blocks.
public export
iret_7_7__right_retract : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> List Iret_7_4__beta -> List Iret_8_1__act -> (List Iret_7_4__beta, List Iret_8_1__act)
iret_7_7__right_retract wm alphas a f [] acts = ([], acts)
iret_7_7__right_retract wm alphas a f (b :: rest) acts =
  let r1 = iret_7_7__right_retract wm alphas a f rest acts
      hit = filter (\t => bjoin b t f) (blmem b)
  in if balpha b == a
       then if bneg b
              then let r2 = iret_7_7__wave wm alphas (fst r1) (filter (\t => iret_7_9_4__count t (bcounts b) == 1) hit) (snd r1)
                   in (iret_7_4__with_lmem (blmem b) (iret_7_9_3__unblock hit (bcounts b)) b :: fst r2, snd r2)
              else let r2 = iret_7_8__unwave alphas (fst r1) (map (\t => t ++ [f]) hit) (snd r1)
                   in (b :: fst r2, snd r2)
       else (b :: fst r1, snd r1)

--@derives [IRET.7.7]
--@derives [RARC.5.6.5]
||| THE RECOMPUTE, node by node: the tokens each prefix of a chain should
||| pass, from the nil token, over working memory alone. This is what the
||| memories are proved to hold.
public export
iret_7_7__view : List Iret_6_1__alpha -> Rarc_5_6_4__wm -> List Iret_7_4__beta -> List Iret_7_1__token -> List Iret_7_1__token
iret_7_7__view alphas wm [] front = front
iret_7_7__view alphas wm (b :: rest) front =
  iret_7_7__view alphas wm rest (iret_7_7__next b (iret_6_5__view (iret_6_6__alpha_at alphas (balpha b)) wm) front)

-- ---------------------------------------------------------------------
-- Chains, the network, the engine
-- ---------------------------------------------------------------------

--@spec [RLOW.4.2.1]
--@spec [IRET.7.10.1]
||| A rule's network: its chain of beta nodes in LHS order, its terminal's
||| activations, and its RHS [IRET.8]. The terminal ordinal is the rule's
||| position among the chains [LDET.5.4], RLOW.1.3.
public export
record Rlow_4_2_1__chain where
  constructor MkChain
  cnodes   : List Iret_7_4__beta
  cacts    : List Iret_8_1__act
  cactions : List Lgra_10_1__action

--@spec [RARC.5.3.1]
||| The network: the alpha nodes and one chain per rule.
public export
record Rarc_5_3_1__network where
  constructor MkNetwork
  nalphas : List Iret_6_1__alpha
  nchains : List Rlow_4_2_1__chain

--@spec [IRET.19]
||| The engine: working memory and the network over it.
public export
record Iret_19__engine where
  constructor MkEngine
  ewm  : Rarc_5_6_4__wm
  enet : Rarc_5_3_1__network

-- ---------------------------------------------------------------------
-- Alpha dispatch and working-memory operations [IRET.1.7], [IRET.19]
-- ---------------------------------------------------------------------

--@spec [IRET.7.7]
||| One chain's response to a fact admitted to alpha `a`.
public export
iret_7_7__activate_chain : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> Rlow_4_2_1__chain -> Rlow_4_2_1__chain
iret_7_7__activate_chain wm alphas a f c =
  let r = iret_7_7__right_activate wm alphas a f (cnodes c) (cacts c)
  in MkChain (fst r) (snd r) (cactions c)

--@spec [IRET.7.7]
||| One chain's response to a fact removed from alpha `a`.
public export
iret_7_7__retract_chain : Rarc_5_6_4__wm -> List Iret_6_1__alpha -> Nat -> Lfac_1_7_1__fact -> Rlow_4_2_1__chain -> Rlow_4_2_1__chain
iret_7_7__retract_chain wm alphas a f c =
  let r = iret_7_7__right_retract wm alphas a f (cnodes c) (cacts c)
  in MkChain (fst r) (snd r) (cactions c)

--@spec [IRET.1.7]
||| The alpha nodes in dispatch order: by position.
public export
iret_1_7__indices : Nat -> List Nat
iret_1_7__indices Z = []
iret_1_7__indices (S n) = iret_1_7__indices n ++ [n]

--@spec [IRET.6.4]
--@spec [IRET.1.7]
||| ALPHA DISPATCH ON ASSERT: for each alpha node of the fact's schema, in
||| order, evaluate the tests; on pass, insert the fact into the memory
||| and right-activate every chain.
public export
iret_6_4__dispatch_assert : Rarc_5_6_4__wm -> Lfac_1_7_1__fact -> List Nat -> Rarc_5_3_1__network -> Rarc_5_3_1__network
iret_6_4__dispatch_assert wm f [] net = net
iret_6_4__dispatch_assert wm f (i :: is) net =
  if iret_6_4__admits (iret_6_6__alpha_at (nalphas net) i) f
    then let alphas' = rarc_5_6_5__set_at i (iret_6_5__insert f) (nalphas net)
         in iret_6_4__dispatch_assert wm f is (MkNetwork alphas' (map (iret_7_7__activate_chain wm alphas' i f) (nchains net)))
    else iret_6_4__dispatch_assert wm f is net

--@spec [IRET.19.2]
||| ALPHA DISPATCH ON RETRACT: for each alpha node whose memory holds the
||| fact — the nodes admitting it — remove it and right-retract every
||| chain.
public export
iret_19_2__dispatch_retract : Rarc_5_6_4__wm -> Lfac_1_7_1__fact -> List Nat -> Rarc_5_3_1__network -> Rarc_5_3_1__network
iret_19_2__dispatch_retract wm f [] net = net
iret_19_2__dispatch_retract wm f (i :: is) net =
  if iret_6_4__admits (iret_6_6__alpha_at (nalphas net) i) f
    then let alphas' = rarc_5_6_5__set_at i (iret_6_5__remove f) (nalphas net)
         in iret_19_2__dispatch_retract wm f is (MkNetwork alphas' (map (iret_7_7__retract_chain wm alphas' i f) (nchains net)))
    else iret_19_2__dispatch_retract wm f is net

--@spec [IRET.19.1]
||| Insert a fresh fact: append to working memory, then dispatch.
public export
iret_19_1__insert : Lfac_1_7_1__fact -> Iret_19__engine -> Iret_19__engine
iret_19_1__insert f eng =
  let wm' = ewm eng ++ [f]
  in MkEngine wm' (iret_6_4__dispatch_assert wm' f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng))

--@spec [IRET.19.2]
--@spec [LDET.5.9]
||| Retract a live fact: remove from working memory, then dispatch. The
||| dispatch stamps what it releases against the working memory the
||| retraction found: a match a NOT node releases fires under the timetag
||| it first completed with [LDET.5.9], and the survivors' order is the
||| same under either working memory.
public export
iret_19_2__retract : Lfac_1_7_1__fact -> Iret_19__engine -> Iret_19__engine
iret_19_2__retract f eng =
  MkEngine (rarc_5_6_4__remove_exact f (ewm eng))
           (iret_19_2__dispatch_retract (ewm eng) f (iret_1_7__indices (length (nalphas (enet eng)))) (enet eng))

--@spec [IRET.19.1]
--@spec [LFAC.2.5.1]
--@spec [LFAC.2.5.3]
||| ASSERT under the kind's lifecycle, exactly as Rete/FireLoop.idr's
||| `iret_19_1__assert_fact` decides it: a no-op reassertion changes
||| nothing; a meaningful change of an entity retracts the old fact then
||| inserts the new one, whose id was chosen while the old was live.
public export
iret_19_1__assert : (Nat -> Lscp_1_3__lifecycle) -> List Nat -> Nat -> Nat -> Nat -> Iret_19__engine -> Iret_19__engine
iret_19_1__assert life avoid k key pay eng =
  let new = MkFact (lfac_2_5_3__fresh_id avoid (ewm eng)) k key pay
  in case life k of
       Explicit => iret_19_1__insert new eng
       Relation => case iret_19_1__find_relation k key pay (ewm eng) of
         Just _  => eng
         Nothing => iret_19_1__insert new eng
       Entity => case iret_19_1__find_entity k key (ewm eng) of
         Nothing  => iret_19_1__insert new eng
         Just old => if fpay old == pay then eng else iret_19_1__insert new (iret_19_2__retract old eng)

--@spec [LSCP.2.1.1]
||| Withdraw a bound fact; a no-op when it is already gone.
public export
lscp_2_1_1__withdraw : Lfac_1_7_1__fact -> Iret_19__engine -> Iret_19__engine
lscp_2_1_1__withdraw f eng = if rarc_5_6_5__any (\g => lfac_2_5_4__same_fact g f) (ewm eng) then iret_19_2__retract f eng else eng

-- ---------------------------------------------------------------------
-- Selection and firing [IRET.11], [IRET.11.4]
-- ---------------------------------------------------------------------

--@spec [IRET.11.3.1]
--@spec [IDAT.6.2.2]
||| The first activation not yet fired, in timetag order.
public export
iret_11_3_1__first_unfired : List Iret_8_1__act -> Maybe Nat
iret_11_3_1__first_unfired [] = Nothing
iret_11_3_1__first_unfired (a :: as) = if afired a then map S (iret_11_3_1__first_unfired as) else Just 0

--@spec [IRET.11.1]
--@spec [LDET.5.1]
||| The activation that fires next: the lowest ordinal with an unfired
||| activation, then its earliest.
public export
iret_11_1__select : List Rlow_4_2_1__chain -> Maybe (Nat, Nat)
iret_11_1__select [] = Nothing
iret_11_1__select (c :: cs) = case iret_11_3_1__first_unfired (cacts c) of
  Just j  => Just (0, j)
  Nothing => map (\(r, j) => (S r, j)) (iret_11_1__select cs)

--@spec [IDAT.6.2.2]
public export
idat_6_2_2__mark_act : Iret_8_1__act -> Iret_8_1__act
idat_6_2_2__mark_act (MkAct t _) = MkAct t True

--@spec [IDAT.6.2.2]
||| Set `fired` on activation j. Named, rather than written as the update
||| of the list, because an unapplied function in a statement is a
||| variable to Idris.
public export
idat_6_2_2__mark_acts : Nat -> List Iret_8_1__act -> List Iret_8_1__act
idat_6_2_2__mark_acts j acts = rarc_5_6_5__set_at j idat_6_2_2__mark_act acts

--@spec [IDAT.6.2.2]
public export
idat_6_2_2__mark_chain : Nat -> Rlow_4_2_1__chain -> Rlow_4_2_1__chain
idat_6_2_2__mark_chain j c = MkChain (cnodes c) (idat_6_2_2__mark_acts j (cacts c)) (cactions c)

--@spec [IDAT.6.2.2]
--@spec [IRET.11.3.1]
||| Set `fired` on activation j of rule r.
public export
idat_6_2_2__mark_net : Nat -> Nat -> Iret_19__engine -> Iret_19__engine
idat_6_2_2__mark_net r j eng = MkEngine (ewm eng) (MkNetwork (nalphas (enet eng)) (rarc_5_6_5__set_at r (idat_6_2_2__mark_chain j) (nchains (enet eng))))

--@spec [RARC.5.6.7]
||| One RHS action against the engine; `bound` is the fired match.
public export
rarc_5_6_7__do_action_net : (Nat -> Lscp_1_3__lifecycle) -> List Lfac_1_7_1__fact -> Lgra_10_1__action -> Iret_19__engine -> Iret_19__engine
rarc_5_6_7__do_action_net life bound (Emit k value) eng =
  iret_19_1__assert life (iret_11_3__fact_ids bound) k (fst (value bound)) (snd (value bound)) eng
rarc_5_6_7__do_action_net life bound (Withdraw i) eng = case rarc_5_6_5__nth i bound of
  Nothing => eng
  Just f  => lscp_2_1_1__withdraw f eng

--@spec [RARC.5.6.7]
public export
rarc_5_6_7__do_actions_net : (Nat -> Lscp_1_3__lifecycle) -> List Lfac_1_7_1__fact -> List Lgra_10_1__action -> Iret_19__engine -> Iret_19__engine
rarc_5_6_7__do_actions_net life bound [] eng = eng
rarc_5_6_7__do_actions_net life bound (a :: as) eng = rarc_5_6_7__do_actions_net life bound as (rarc_5_6_7__do_action_net life bound a eng)

--@spec [IRET.11.4]
||| One firing: select, mark fired, run the RHS. `Nothing` when nothing
||| is pending.
public export
iret_11_4__step_net : (Nat -> Lscp_1_3__lifecycle) -> Iret_19__engine -> Maybe Iret_19__engine
iret_11_4__step_net life eng = case iret_11_1__select (nchains (enet eng)) of
  Nothing => Nothing
  Just (r, j) => case rarc_5_6_5__nth r (nchains (enet eng)) of
    Nothing => Nothing
    Just c => case rarc_5_6_5__nth j (cacts c) of
      Nothing => Nothing
      Just a  => Just (rarc_5_6_7__do_actions_net life (atuple a) (cactions c) (idat_6_2_2__mark_net r j eng))

--@spec [IRET.11.4]
--@spec [IRET.11.5]
||| The bounded run.
public export
iret_11_4__run_net : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Iret_19__engine -> (Iret_19__engine, Iret_11_4__halt, Nat)
iret_11_4__run_net life Z eng = (eng, FuelOut, 0)
iret_11_4__run_net life (S fuel) eng = case iret_11_4__step_net life eng of
  Nothing   => (eng, Quiescent, 0)
  Just eng' => let (e, h, n) = iret_11_4__run_net life fuel eng' in (e, h, S n)

-- ---------------------------------------------------------------------
-- Load [IRET.18.2], [RDSC.4a.5] and the history [LFST.9.2.1]
-- ---------------------------------------------------------------------

--@spec [IRET.16.4]
||| An alpha node as loaded: its schema and tests, an empty memory.
public export
iret_16_4__alpha_node : (Nat, Lfac_1_7_1__fact -> Bool) -> Iret_6_1__alpha
iret_16_4__alpha_node (k, test) = MkAlpha k test []

--@spec [IRET.16.4]
||| The alpha nodes as loaded, in atom order.
public export
iret_16_4__alpha_nodes : List (Nat, Lfac_1_7_1__fact -> Bool) -> List Iret_6_1__alpha
iret_16_4__alpha_nodes kts = map iret_16_4__alpha_node kts

--@spec [IRET.16.5]
||| A beta node as loaded: its right alpha, join tests and negative
||| flag; an empty left memory and no counts.
public export
iret_16_5__beta_node : (Nat, Iret_7_5__join, Bool) -> Iret_7_4__beta
iret_16_5__beta_node (a, j, neg) = MkBeta a j neg [] []

--@spec [IRET.16.5]
||| A chain's beta nodes as loaded, in LHS order.
public export
iret_16_5__beta_nodes : List (Nat, Iret_7_5__join, Bool) -> List Iret_7_4__beta
iret_16_5__beta_nodes ns = map iret_16_5__beta_node ns

--@spec [IRET.16.6]
||| A rule as loaded: its chain, no activations, its actions.
public export
iret_16_6__terminal : (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Rlow_4_2_1__chain
iret_16_6__terminal (nodes, actions) = MkChain (iret_16_5__beta_nodes nodes) [] actions

--@spec [RDSC.4a.5]
--@spec [RDSC.4a.7]
||| Seed a root with the nil token: the wave it starts over the empty
||| memories runs to the terminal, so a rule of only NOT patterns is
||| active from the start.
public export
rdsc_4a_5__seed : List Iret_6_1__alpha -> Rlow_4_2_1__chain -> Rlow_4_2_1__chain
rdsc_4a_5__seed alphas (MkChain nodes acts actions) =
  let r = iret_7_7__wave [] alphas nodes [[]] acts
  in MkChain (fst r) (snd r) actions

--@spec [RDSC.4a.5]
--@spec [IRET.18.2]
||| LOAD: the alpha nodes from their schemas and tests, the chains from
||| their nodes and actions, every memory empty, then every root seeded.
public export
rdsc_4a_5__load : List (Nat, Lfac_1_7_1__fact -> Bool) -> List (List (Nat, Iret_7_5__join, Bool), List Lgra_10_1__action) -> Iret_19__engine
rdsc_4a_5__load alphas rules =
  MkEngine [] (MkNetwork (iret_16_4__alpha_nodes alphas)
                         (map (rdsc_4a_5__seed (iret_16_4__alpha_nodes alphas)) (map iret_16_6__terminal rules)))

--@spec [RARC.5.6.4]
||| An input applied to the engine: an adapter assert under the kind's
||| lifecycle, with no bound ids to avoid, or the retraction of a live
||| fact by id; an id not live is a no-op. The events are
||| Rete/PumpBoundary.idr's.
public export
rarc_5_6_4__apply_net : (Nat -> Lscp_1_3__lifecycle) -> Rarc_5_6_1__event -> Iret_19__engine -> Iret_19__engine
rarc_5_6_4__apply_net life (Assert k key pay) eng = iret_19_1__assert life [] k key pay eng
rarc_5_6_4__apply_net life (Retract i) eng = case rarc_5_6_4__lookup_fact i (ewm eng) of
  Nothing => eng
  Just f  => iret_19_2__retract f eng

--@spec [LFST.9.2.1]
||| The canonical cadence: one input, then a pump.
public export
lfst_9_2_1__boundary_net : (Nat -> Lscp_1_3__lifecycle) -> Nat -> Rarc_5_6_1__event -> Iret_19__engine -> Iret_19__engine
lfst_9_2_1__boundary_net life fuel ev eng = fst (iret_11_4__run_net life fuel (rarc_5_6_4__apply_net life ev eng))

--@spec [LFST.9.2.1]
||| A history: the inputs, each pumped, in order.
public export
lfst_9_2_1__replay_net : (Nat -> Lscp_1_3__lifecycle) -> Nat -> List Rarc_5_6_1__event -> Iret_19__engine -> Iret_19__engine
lfst_9_2_1__replay_net life fuel [] eng = eng
lfst_9_2_1__replay_net life fuel (ev :: evs) eng = lfst_9_2_1__replay_net life fuel evs (lfst_9_2_1__boundary_net life fuel ev eng)

-- ---------------------------------------------------------------------
-- The rule a chain lowers from RLOW.4.2.1, for the recompute
-- ---------------------------------------------------------------------

--@spec [RLOW.5.1]
||| The positive patterns' kinds, in order.
public export
rlow_5_1__pos_kinds : List Iret_6_1__alpha -> List Iret_7_4__beta -> List Nat
rlow_5_1__pos_kinds alphas [] = []
rlow_5_1__pos_kinds alphas (b :: bs) = if bneg b then rlow_5_1__pos_kinds alphas bs else akind (iret_6_6__alpha_at alphas (balpha b)) :: rlow_5_1__pos_kinds alphas bs

--@spec [RLOW.5.5]
||| The guard at one positive node, on the fact looked up at its
||| position: the fact must pass the alpha tests and the join tests
||| against its prefix, and the rest of the guard must hold. Its own
||| function so that a proof can reduce it by rewriting the lookup alone.
public export
rlow_5_5__guard_at : List Iret_6_1__alpha -> Iret_7_4__beta -> Nat -> Iret_7_1__token -> Bool -> Maybe Lfac_1_7_1__fact -> Bool
rlow_5_5__guard_at alphas b i tuple restOk Nothing = False
rlow_5_5__guard_at alphas b i tuple restOk (Just f) =
  (iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b)) f && bjoin b (take i tuple) f) && restOk

--@spec [RLOW.5.5]
||| The guard: every positive node's alpha tests on its fact and join
||| tests on its prefix, `i` counting the positives so far.
public export
rlow_5_5__guard_from : List Iret_6_1__alpha -> List Iret_7_4__beta -> Nat -> Iret_7_1__token -> Bool
rlow_5_5__guard_from alphas [] i tuple = True
rlow_5_5__guard_from alphas (b :: bs) i tuple =
  if bneg b then rlow_5_5__guard_from alphas bs i tuple
  else rlow_5_5__guard_at alphas b i tuple (rlow_5_5__guard_from alphas bs (S i) tuple) (rarc_5_6_5__nth i tuple)

--@spec [RLOW.5.3]
||| Each NOT node as a blocker over its positive prefix.
public export
rlow_5_3__negs_from : List Iret_6_1__alpha -> List Iret_7_4__beta -> Nat -> List (Nat, Iret_7_1__token -> Lfac_1_7_1__fact -> Bool)
rlow_5_3__negs_from alphas [] i = []
rlow_5_3__negs_from alphas (b :: bs) i =
  if bneg b
    then (akind (iret_6_6__alpha_at alphas (balpha b)), \tuple, f => iret_6_4__admits (iret_6_6__alpha_at alphas (balpha b)) f && bjoin b (take i tuple) f) :: rlow_5_3__negs_from alphas bs i
    else rlow_5_3__negs_from alphas bs (S i)

--@spec [RLOW.4.2.1]
||| The rule Rete/FireLoop.idr's recompute reads for a chain.
public export
rlow_4_2_1__rule_of : List Iret_6_1__alpha -> Rlow_4_2_1__chain -> Lgra_6_1__rule
rlow_4_2_1__rule_of alphas c =
  MkRule (rlow_5_1__pos_kinds alphas (cnodes c)) (rlow_5_5__guard_from alphas (cnodes c) 0) (rlow_5_3__negs_from alphas (cnodes c) 0) (cactions c)

--@spec [LCYC.3.2.1]
||| The program the network lowers from.
public export
lcyc_3_2_1__program_of : (Nat -> Lscp_1_3__lifecycle) -> Rarc_5_3_1__network -> Lcyc_3_2_1__program
lcyc_3_2_1__program_of life net = MkProgram life (map (rlow_4_2_1__rule_of (nalphas net)) (nchains net))

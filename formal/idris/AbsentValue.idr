-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
||| The absent value and what consumes it ([LNUL.11.1]), and the two predicate
||| sites the corpus states for it ([LNUL.4.3], [LNUL.4.8]).
|||
||| THE CLAUSE: "An argument that cannot be evaluated is `null` — one absent
||| value, not a separate sentinel." Then a per-verb table:
|||
|||     log                            the message degrades to a partial string
|||     emit, publish, record_event    the slot takes null, reading back as the
|||                                    zero of its declared type, and the verb
|||                                    PROCEEDS
|||     call                           a bad kwarg prevents the call
|||     cache                          the stored value may be null, and it is
|||                                    stored as one
|||
||| and the clause's own gloss that `cache` is a FOURTH policy, not a variant of
||| the second: a slot has a declared type to take the zero of, a cache entry
||| has none, so `null` is stored as itself. The counter
||| `ds.calls.arg_error_total` is a row of the metric inventory ([NMET.4.1]), and
||| this model says nothing about counting.
|||
||| plus the exclusion: "A trap is not this. A trap has no honest answer, is not
||| an absent value, and never reaches a slot — it abandons the activation."
|||
||| That is a complete, total policy over ACTION VERBS, and this module proves
||| it is one. What the clause does not cover is the other place a value is
||| consumed: AS A PREDICATE. A `where` test, a beta join test, a fire guard —
||| each takes a value and can only ask "yes or no". None is an argument to a
||| verb, so none is in the table, and the clause's "one absent value" says what
||| the value IS without saying what a boolean consumer does with it.
|||
||| The corpus states the predicate sites one by one (below).
|||
||| WHY THE SITES MATTER. A second runtime measured that the two directions fail OPPOSITELY:
|||
|||   fire guard, failing closed   every rate-limited rule silently DELETED —
|||                                fire_begin/fire_end around nothing
|||   fire guard, failing open     the rule acts too often; bounded and visible
|||   match test, failing closed   the rule never fires
|||   match test, failing open     the rule fires on exactly the data the author
|||                                excluded
|||
||| One undefined case, four behaviours, and the right answer depends on the
||| SITE rather than on the value. That runtime now refuses to load a bundle
||| whose beta tests it cannot evaluate, rather than pick a direction.
|||
||| ⚠ IT WAS NOT AN OPEN QUESTION IN THE CODE, and that is the update the
||| re-home brought. `runtime/src/libds/rete/engine.c:355` had already decided
||| it, in the quadrant the table above calls catastrophic-and-silent:
|||
|||     bool allow = (v.kind == DS_RETE_VAL_BOOL) ? v.b : false;
|||
||| A fire guard evaluating to `null` suppresses the rule, forever, with no
||| diagnostic. The ternary also collapses two kinds `rete/val.h:47` is explicit
||| about keeping apart — a real `null` data value, and the
||| type-error marker — and its comment argues the ERR policy ([IRET.9.6]),
||| which is defensible, while saying nothing about `null`. So the absent-value
||| rule for the most dangerous predicate position in the engine is a side
||| effect of a line written for type errors. Filed as `FIREGUARD1`.
|||
||| THE CORPUS HAS SINCE CHOSEN, AND CHOSE BY SITE. `[LNUL.4.3]` rules that
||| a `where` clause fires iff it evaluates to `true` — the match test fails
||| CLOSED on `null`. `[LNUL.4.8]` rules that a GUARD (the compiler-emitted
||| cooldown gate, `[IRET.25.5.1]`) admits on `null` — the fire guard fails
||| OPEN, and only an explicit `false` suppresses. So the two predicate
||| functions below are no longer two candidate readings of one silence:
||| `lnul_4_3__admits_closed` is the `where` site and `lnul_4_8__admits_open`
||| is the guard site, each tied to the clause that rules it, and the pair is
||| a witness that the two sites take OPPOSITE dispositions of the same value.
|||
||| The code half is still open: `engine.c`'s fire guard fails closed, which
||| `[LNUL.4.8]` forbids.
|||
||| WHAT IS PROVEN HERE. That the verb policy is total (so `[LNUL.11.1]` is
||| complete where it speaks), and that the two predicate dispositions agree
||| on every evaluable value and disagree exactly on the absent one — which is
||| why the choice `[LNUL.4.3]` and `[LNUL.4.8]` make is invisible to any test
||| over evaluable data, and why a clause has to state it.
module AbsentValue

%default total

--@spec [LNUL.11.1]
||| A value reaching a consumer: either it evaluated, or it is THE absent value.
||| One `Absent`, not a family of sentinels — the clause is explicit that there
||| is a single absent value, and modelling two would assume the finding.
data Lnul_11_1__value : Type where
  Evaluated : Nat -> Lnul_11_1__value
  Absent    : Lnul_11_1__value

--@spec [LNUL.11.1]
||| The four verb classes the clause's table distinguishes. `record_event` sits
||| with `emit`/`publish` rather than taking a fourth policy: "the same failure in an `emit` over the same typed slot has to
||| do the same thing, because they are the same operation on the same slot."
||| `cache` IS the fourth: the clause says so in as many words, because a cache
||| entry has no declared type to take the zero of.
data Lnul_11_1__verb : Type where
  MessageVerb  : Lnul_11_1__verb
  SlotVerb     : Lnul_11_1__verb
  CallVerb     : Lnul_11_1__verb
  CacheVerb    : Lnul_11_1__verb

--@spec [LNUL.11.1]
||| What a verb does when its argument is absent. `Prevent` is the whole of the
||| `call` row: the clause no longer says the call is counted, and the counter
||| (`ds.calls.arg_error_total`, [NMET.4.1]) is a metric, not a policy of this
||| clause. `StoreNull` is `cache`'s: the absent value is stored as itself,
||| which is why a later `cached(key)` cannot tell it from a miss
||| (AbsentTrichotomy.idr's `lnul_11_1__collapse_loses_the_miss`).
data Lnul_11_1__policy : Type where
  DegradeToPartial : Lnul_11_1__policy
  ZeroAndProceed   : Lnul_11_1__policy
  Prevent          : Lnul_11_1__policy
  StoreNull        : Lnul_11_1__policy

--@spec [LNUL.11.1]
||| The clause's table, as a total function. Every verb class has an answer for
||| the absent value, and the answers are distinct — which is what makes the
||| table informative rather than a restatement of "something happens".
lnul_11_1__on_absent : Lnul_11_1__verb -> Lnul_11_1__policy
lnul_11_1__on_absent MessageVerb = DegradeToPartial
lnul_11_1__on_absent SlotVerb    = ZeroAndProceed
lnul_11_1__on_absent CallVerb    = Prevent
lnul_11_1__on_absent CacheVerb   = StoreNull

--@spec [LNUL.4.8]
||| The GUARD site: a fire guard admits on the absent value — only an explicit
||| `false` suppresses. FAILING OPEN, as the clause rules.
lnul_4_8__admits_open : Lnul_11_1__value -> Bool
lnul_4_8__admits_open (Evaluated n) = n > 0
lnul_4_8__admits_open Absent        = True

--@spec [LNUL.4.3]
||| The `where` site: a match test fires iff it evaluates to `true`, so the
||| absent value does not match. FAILING CLOSED, as the clause rules. Identical
||| to the guard site everywhere the value evaluated.
|||
||| This is also the disposition `engine.c:355` gives the FIRE guard, by a
||| ternary whose comment is about type errors — the site `[LNUL.4.8]` rules
||| the other way (FIREGUARDOPEN1).
lnul_4_3__admits_closed : Lnul_11_1__value -> Bool
lnul_4_3__admits_closed (Evaluated n) = n > 0
lnul_4_3__admits_closed Absent        = False

--@derives [LNUL.4.3] [LNUL.4.8]
||| The two sites agree on EVERY evaluable value.
|||
||| This is the half that makes the disagreement below dangerous rather than
||| obvious: a runtime taking either disposition at both sites behaves
||| identically on all data that evaluates, so a test suite over evaluable
||| inputs cannot tell the sites apart. The difference appears only on the
||| absent value.
|||
||| It is also why `FIREGUARD1` sat green. No gate disagreed with the ternary,
||| because until `[LNUL.4.8]` there was no clause for a gate to check it
||| against, and no evaluable input distinguishes the two readings.
lnul_4_3__sites_agree_when_evaluable :
  (n : Nat) -> lnul_4_8__admits_open (Evaluated n)
             = lnul_4_3__admits_closed (Evaluated n)
lnul_4_3__sites_agree_when_evaluable n = Refl

--@derives [LNUL.4.8] [LNUL.4.3]
||| And they disagree exactly on the absent value: the two sites take opposite
||| dispositions of the same value, which is what the corpus states and what a
||| runtime applying one disposition to both sites gets wrong at one of them.
|||
||| This used to be the finding that `[LNUL.11.1]` determines what every VERB
||| does with an absent argument and not what a PREDICATE does with one — an
||| incompleteness, not a falsehood. `[LNUL.4.3]` and `[LNUL.4.8]` are the two
||| rows that were missing, and this is now the witness that they differ.
lnul_4_8__sites_disagree_on_absent :
  Not (lnul_4_8__admits_open Absent = lnul_4_3__admits_closed Absent)
lnul_4_8__sites_disagree_on_absent Refl impossible

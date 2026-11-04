// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [RLOW.1.3] [RLOW.4.2] [RLOW.4.6.1] [RLOW.5.3] [RLOW.5.4] [RLOW.5.5]
//@spec [RLOW.5.6.1] [RLOW.5.6.4] [RLOW.5.6.5.2]
//
// rlow.k -- DS -> native-Rete / IR LOWERING as executable rewrite semantics (K
// Framework). Where the other K defs run the language's *values* (dsexpr,
// dscast) and its *fact lifecycle* (lfac), this one runs
// the COMPILER'S front-half: it lowers a rule's LHS surface pattern into the base
// Rete node graph the engine builds, as a pure syntactic transform. `krun`
// reduces `lower(rule)` to a canonical rendering of the lowered node structure --
// the compiler-correctness lane. (A K def of the language's *execution*, rpir.k,
// was deleted with the portable IR it ran, and the RPIR clauses are retired.)
//
// NORMATIVE COMPANION (specs/runtime/LOWERING, the RLOW clauses). Formalizes the lowering
// rewrite rules:
//   * [RLOW.4.2] a rule lowers to a chain of Rete nodes ending in a TERM
//     terminal. It carries no ordering weight — see below.
//   * [RLOW.1.3] a rule carries NO ordering weight. Order is the terminal's
//     position in the emitted sequence, which is canonical source order
//     ([RLOW.14.3]) — so lowering ONE rule cannot express it and does not try.
//   * [RLOW.4.6.1/.6.2] a rule-header `cooldown T` lowers to a `ds-rate-allow`
//     gate on the terminal.
//   * [RLOW.5.3] `no P where E` lowers to a NOT negative beta node over P's
//     alpha node -- the token passes only when no matching fact exists.
//   * [RLOW.5.4] `P within T` lowers to P's alpha node plus a join test on the
//     fact's AGE: the monotonic clock's sample less the fact's ENTRY STAMP
//     ([LTIM.2.8.6]), under `T` in nanoseconds, re-evaluated as the tick
//     advances the clock. Not the wall clock (`now()` reads that and nothing
//     else does, [LTIM.2.8.3]) and not a slot: the entry stamp is engine
//     state, and `within` reads no slot a schema declares, `ts` included.
//     Rendered `mono-entry(v)<T`. A SEQUENCE's `then … within` is the other
//     mechanism and compares `ts` (below): event time, by [LTIM.2.8.2].
//   * [RLOW.5.5] `where E` lowers to a beta-node join test over the bound slots.
//   * [RLOW.5.6.1/.6.2] `X then Y within T` lowers to a left-associative chain of
//     beta joins; each `then Y within T` contributes two predicates
//     (`Y.ts > X.ts` and `Y.ts - X.ts < T`).
//   * [RLOW.5.6.4] a trailing `where` on a sequence is the LAST STEP's
//     ([LGRA.8.5.10]; a sequence has no sequence-wide `where`): it lowers as
//     part of that step's join test, after the step's ordering and window
//     predicates, and adds no node. The compiler unrolls the sequence into
//     its steps and lowers the `where` as the last step's own
//     (`dsc.rete.m`, `pat_specs`).
//   * [RLOW.5.6.5.2/.5.3] the `latest` anchor prefix adds a NOT sub-node
//     after the first follower's join, excluding any anchor f of the anchor's
//     schema with ts(d) < ts(f) < ts(m) -- one that would itself match this
//     follower -- reducing the activation set to the latest qualifying anchor
//     per follower. (The window and `where` conditions on f are opaque here,
//     like every `where`.) `latest` modifies only the first pattern
//     (RLOW.5.6.5.4).
//
// THE MEANING. krun lowers a surface rule to its Rete node graph. A fact's
// `ts` slot renders as `ts(v)` (dot-free) and its age as `mono-entry(v)`,
// nodes as ALFA / BETA / NOT / NOTLATEST / JOIN / GATE / TERM. `where` predicates are opaque labels (their internal expression
// lowering is RLOW.6, covered by dsexpr). The tie is file-level, the tag lines
// at the head of this file, and the crossref gates it in both directions.
//
// RULE REACHABILITY. `rlow.where_then` and `rlow.within_then` pin `lastVar` on a
// `where` and a `within`. `lastVar` on a `no` as the LEFT anchor of a `then`, `lastVar(neg(...))`, is left unpinned on purpose: a `no` pattern binds
// no fact and so has no timestamp for the pair predicate to anchor on, and
// whether the grammar admits `no X then Y` at all is a question for [LGRA], not
// a case to pin by running it. `lastVar(latest(P))` is fired only by a `then`
// chained after a `latest` sequence, which no program here writes either. The
// seventeenth rule, a `where` on a sequence, is `rlow.seq_where`'s; the
// generic `where` rule is `rlow.where`'s, `rlow.where_then`'s and
// `rlow.within_where`'s. A `where` trailing a `latest` sequence is not
// modelled: the generic rule would wrap the NOTLATEST node, where the clause
// puts the `where` in the last step's join and in the exclusion test with the
// anchor substituted (RLOW.5.6.5.2); no program writes it.

module RLOW-SYNTAX
  imports INT-SYNTAX
  imports STRING-SYNTAX

  // surface LHS patterns. Schema/binding/where-predicate are Strings; a
  // where-predicate is an opaque label (its expression internals are RLOW.6).
  syntax Pat ::= "pat" "(" String "," String ")"                  // Schema binding
               | "wher" "(" Pat "," String ")"                    // P where <pred>
               | "neg" "(" String "," String "," String ")"       // no Schema binding where <pred>
               | "within" "(" String "," String "," Int ")"       // Schema binding within T
               | "seq" "(" Pat "," String "," String "," Int ")"  // P then Schema binding within T
               | "latest" "(" Pat ")"                             // latest <anchor sequence>

  // a rule: an LHS, optionally a header cooldown. No ordering weight —
  // [RLOW.1.3], the order is the emission sequence and one rule has none.
  syntax Rule ::= "rule" "(" Pat ")"
                | "cooldownRule" "(" Pat "," Int ")"

  // the program: lower a rule to its rendered lowered form.
  syntax Prog ::= "lower" "(" Rule ")"
endmodule

module RLOW
  imports RLOW-SYNTAX
  imports INT
  imports STRING

  syntax KResult ::= String

  configuration <k> $PGM:Prog </k>

  // entrypoint: reduce the program to the rendered lowered node graph.
  rule <k> lower(R:Rule) => lowerR(R) ...</k>

  // rendering helpers (all pure functions returning the canonical node string).
  syntax String ::= lowerR(Rule) [function]
                  | lowerP(Pat)  [function]

                  | lastVar(Pat) [function]
                  | seqPred(String, String, Int) [function]

  // ---- rule -> TERM chain; cooldown -> a ds-rate-allow GATE ([RLOW.4.2] / [RLOW.4.6.1]) ----
  rule lowerR(rule(P:Pat))
    => "TERM(" +String lowerP(P) +String ")"
  rule lowerR(cooldownRule(P:Pat, T:Int))
    => "TERM(GATE(" +String lowerP(P) +String ";cd=" +String Int2String(T) +String "))"

  // ---- pattern lowering ----
  // basic pattern -> ALFA alpha node ([RLOW.4.2]).
  rule lowerP(pat(S:String, _:String)) => "ALFA(" +String S +String ")"
  // a trailing where on a sequence is the LAST STEP's ([LGRA.8.5.10]): it joins
  // that step's join test after the ordering and window predicates, and adds
  // no node ([RLOW.5.6.4]). X is the left chain's last binding, as for `seq`.
  rule lowerP(wher(seq(P:Pat, S:String, V:String, T:Int), Pr:String))
    => "JOIN(" +String lowerP(P) +String "|ALFA(" +String S +String ");" +String seqPred(lastVar(P), V, T) +String "&" +String Pr +String ")"
  // where on any other pattern -> a beta join TEST over the input node ([RLOW.5.5]).
  rule lowerP(wher(P:Pat, Pr:String))
    => "BETA(" +String lowerP(P) +String ";" +String Pr +String ")" [owise]
  // no -> NOT negative beta node over the alpha ([RLOW.5.3]).
  rule lowerP(neg(S:String, _:String, Pr:String))
    => "NOT(ALFA(" +String S +String ");" +String Pr +String ")"
  // within -> alpha + a join test on the fact's age: the monotonic sample less
  // v's entry stamp, under T ([RLOW.5.4], [LTIM.2.8.6]). No slot is read.
  rule lowerP(within(S:String, V:String, T:Int))
    => "BETA(ALFA(" +String S +String ");mono-entry(" +String V +String ")<" +String Int2String(T) +String ")"
  // then ... within -> left-associative BETA join; the pair test pins strict-after
  // + within-duration ([RLOW.5.6.1/.6.2]). X is the left chain's last binding.
  rule lowerP(seq(P:Pat, S:String, V:String, T:Int))
    => "JOIN(" +String lowerP(P) +String "|ALFA(" +String S +String ");" +String seqPred(lastVar(P), V, T) +String ")"
  // latest <anchor sequence> -> the sequence join, then a NOTLATEST sub-node over
  // it, where anchor and follower are both bound; it excludes an anchor-schema
  // fact strictly between them (RLOW.5.6.5.2; only the first pattern).
  rule lowerP(latest(seq(pat(S0:String, V0:String), S:String, V:String, T:Int)))
    => "NOTLATEST(JOIN(ALFA(" +String S0 +String ")|ALFA(" +String S +String ");"
         +String seqPred(V0, V, T) +String ")," +String S0 +String ";ts("
         +String V0 +String ")<ts(f)<ts(" +String V +String "))"

  // the pair predicate `ts(Y) > ts(X) & ts(Y) - ts(X) < T` ([RLOW.5.6.1], strict-after).
  rule seqPred(X:String, Y:String, T:Int)
    => "ts(" +String Y +String ")>ts(" +String X +String ")&ts(" +String Y +String ")-ts(" +String X +String ")<" +String Int2String(T)

  // the last binding of a (left) chain -- the anchor `X` for the next `then` pair.
  rule lastVar(pat(_:String, V:String))       => V
  rule lastVar(wher(P:Pat, _:String))         => lastVar(P)
  rule lastVar(neg(_:String, V:String, _:String)) => V
  rule lastVar(within(_:String, V:String, _:Int)) => V
  rule lastVar(seq(_:Pat, _:String, V:String, _:Int)) => V
  rule lastVar(latest(P:Pat))                 => lastVar(P)
endmodule

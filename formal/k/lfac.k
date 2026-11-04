// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LFAC.1.1] [LFAC.1.2.2] [LFAC.1.7.2] [LFAC.1.3.2] [LFAC.1.3.3] [LFAC.2.5.1] [LFAC.2.5.3]
//
// lfac.k -- the DS FACT LIFECYCLE as small-step operational semantics (K
// Framework). A fact store stepped by assert / retract / tick, distinguishing
// two of the five lifecycle categories a schema's `scope` picks ([LFAC.1.1]),
// the two that [LFAC.1] covers:
//
//   * `logical` -- keyed identity, ONE live fact per key. Re-asserting the same
//     key UPSERTS: an identical payload (within any declared tolerance) is a
//     NO-OP; a meaningful change is a retract-and-replace that keeps exactly one
//     live fact. The width of the key selects singleton / entity / relation.
//   * `ttl` -- no identity. Facts ACCUMULATE (identical asserts do NOT dedup),
//     each carrying its own deadline, and EXPIRE when the clock passes it.
//
// NORMATIVE COMPANION (specs/language/FACT_MODEL, the LFAC clauses). Formalizes:
//   * [LFAC.1.1] a schema picks its lifecycle category. Five are admitted;
//     `logical` and `ttl` are the two modelled. `explicit`, `activation` and
//     `ambient` are [LSCP.2]'s and are NOT MODELLED here.
//   * [LFAC.1.7.1/.7.2] a logical fact's identity is its `key` slots; two
//     asserts with the same key are the same fact -- the later supersedes,
//     its payload replacing the prior. Key width: key=one -> entity-state,
//     key=all (payload mirrors key) -> relation (identical tuples coalesce),
//     key=none (a fixed key here) -> singleton (latest wins).
//   * [LFAC.1.2.2] retract-and-replace on each meaningful change; exactly one
//     live fact per identity key.
//   * [LFAC.1.3.2/.1.7.6] ttl facts accumulate -- no per-identity uniqueness,
//     no dedup.
//   * [LFAC.1.3.3] ttl facts expire via their (per-schema) TTL deadline.
//   * [LFAC.2.5.1] engine-side no-op dedup: a re-assert whose payload is equal
//     -- for Int/Float slots, within the declared `tolerance` band -- is
//     SUPPRESSED; dwell does not reset; `ds_noop_reassert_suppressed_total`
//     increments (the <noop> cell here).
//   * [LFAC.2.5.3] the complement: a value moving OUTSIDE tolerance (or any
//     exact-compared change) is a meaningful change applied as a
//     FACT_RETRACT(old) + FACT_ASSERT(new) pair, leaving exactly one live fact.
//
// THE MEANING. krun replays a sequence of store operations; the <trace> cell
// holds the lifecycle events (assert / noop / retract+assert / ttl_assert /
// ttl_expire) and `count` stamps the live-fact total -- the observable a
// conforming engine's stream (NCBK) would produce.
//
// (Scalar slots are modeled as a single Int key + single Int payload -- enough
// to exhibit all three logical sub-modes and the tolerance band.) The tie is
// file-level, the tag line at the head of this file, and
// the crossref gates it in both directions.

module LFAC-SYNTAX
  imports INT-SYNTAX
  imports STRING-SYNTAX

  // A program is a sequence of store operations over named schemas.
  //   schema S logical tol T   -- declare a logical schema, tolerance T (0 = exact)
  //   schema S ttl D           -- declare a ttl schema, per-schema duration D
  //   assert S K P             -- assert schema S with key K, payload P
  //                               (logical: keyed upsert; ttl: accumulate, K is payload-side)
  //   retract S K              -- explicit retract of the logical fact keyed K
  //   tick N                   -- advance the clock by N, sweeping ttl expiries
  //   count                    -- stamp the live-fact total into the trace
  syntax Stmt ::= "schema" String "logical" "tol" Int
                | "schema" String "ttl" Int
                | "assert" String Int Int
                | "retract" String Int
                | "tick" Int
                | "count"
                > Stmt Stmt [left]
endmodule

module LFAC
  imports LFAC-SYNTAX
  imports INT
  imports BOOL
  imports STRING
  imports MAP
  imports LIST

  // category tag, schema info, and the store records (all inert constructors).
  syntax Cat   ::= "cLogical" | "cTtl"
  syntax SInfo ::= sinfo(Cat, Int)          // category, tolerance (logical) | duration (ttl)
  syntax LKey  ::= lkey(String, Int)        // (schema, key) -- the logical-store map key
  syntax LFact ::= lfact(Int, Int)          // (payload, ts)
  syntax TFact ::= tfact(String, Int, Int)  // (schema, payload, deadline)

  // ---------------------------------------------------------------------------
  // The store. <lstore> holds ONE logical fact per (schema,key) -- the
  // one-live-per-key invariant ([LFAC.1.7.2]). <tstore> is an ordered list of
  // ttl facts -- they accumulate ([LFAC.1.3.2]). <noop> is the suppressed-
  // reassert counter ([LFAC.2.5.1]). <trace> is the lifecycle-event observable.
  // ---------------------------------------------------------------------------
  configuration
    <T>
      <k> $PGM:Stmt </k>
      <schemas> .Map </schemas>     // String -> SInfo
      <lstore> .Map </lstore>       // LKey -> LFact         (logical: keyed, one-per-key)
      <tstore> .List </tstore>      // ListItem(TFact)       (ttl: accumulate, ordered)
      <clock> 0 </clock>
      <trace> "" </trace>
      <noop> 0 </noop>              // ds_noop_reassert_suppressed_total
    </T>

  rule <k> S1:Stmt S2:Stmt => S1 ~> S2 ...</k>                                   // sequencing

  // ---- schema declaration ([LFAC.1.1]) ----
  rule <k> schema S:String logical tol T:Int => . ...</k>
       <schemas> M => M[S <- sinfo(cLogical, T)] </schemas>
  rule <k> schema S:String ttl D:Int => . ...</k>
       <schemas> M => M[S <- sinfo(cTtl, D)] </schemas>

  // ---- assert: dispatch by the schema's declared category ----
  syntax KItem ::= lassert(String, Int, Int) | tassert(String, Int, Int)
  rule <k> assert S:String K:Int P:Int => lassert(S, K, P) ...</k>
       <schemas> ... S |-> sinfo(cLogical, _) ... </schemas>
  rule <k> assert S:String K:Int P:Int => tassert(S, K, P) ...</k>
       <schemas> ... S |-> sinfo(cTtl, _) ... </schemas>

  // ---- logical assert: insert / no-op / replace ([LFAC.1.7.2] / [LFAC.2.5]) ----
  // (a) no live fact for this key -> INSERT.
  rule <k> lassert(S:String, K:Int, P:Int) => . ...</k>
       <lstore> LS => LS[lkey(S, K) <- lfact(P, C)] </lstore>
       <clock> C </clock>
       <trace> Tr => Tr +String "assert:" +String S +String ":" +String Int2String(K)
                        +String "=" +String Int2String(P) +String "|" </trace>
    requires notBool (lkey(S, K) in_keys(LS))
  // (b) live fact, payload within tolerance -> NO-OP (suppressed; counter++). [LFAC.2.5.1]
  rule <k> lassert(S:String, K:Int, P:Int) => . ...</k>
       <schemas> ... S |-> sinfo(cLogical, Tol) ... </schemas>
       <lstore> ... lkey(S, K) |-> lfact(Pold, _) ... </lstore>
       <noop> N => N +Int 1 </noop>
       <trace> Tr => Tr +String "noop:" +String S +String ":" +String Int2String(K) +String "|" </trace>
    requires absInt(P -Int Pold) <=Int Tol
  // (c) live fact, payload outside tolerance -> meaningful change: RETRACT+ASSERT,
  //     one live fact remains, ts advances. [LFAC.2.5.3] / [LFAC.1.2.2]
  rule <k> lassert(S:String, K:Int, P:Int) => . ...</k>
       <schemas> ... S |-> sinfo(cLogical, Tol) ... </schemas>
       <lstore> ... lkey(S, K) |-> (lfact(Pold, _) => lfact(P, C)) ... </lstore>
       <clock> C </clock>
       <trace> Tr => Tr +String "retract:" +String S +String ":" +String Int2String(K)
                        +String "=" +String Int2String(Pold)
                        +String "|assert:" +String S +String ":" +String Int2String(K)
                        +String "=" +String Int2String(P) +String "|" </trace>
    requires absInt(P -Int Pold) >Int Tol

  // ---- ttl assert: accumulate a fresh fact with deadline = now + duration ----
  // ([LFAC.1.3.2] no dedup / [LFAC.1.7.6] no identity). K carries no identity here.
  rule <k> tassert(S:String, _:Int, P:Int) => . ...</k>
       <schemas> ... S |-> sinfo(cTtl, D) ... </schemas>
       <clock> C </clock>
       <tstore> TS => TS ListItem(tfact(S, P, C +Int D)) </tstore>
       <trace> Tr => Tr +String "ttl_assert:" +String S +String ":" +String Int2String(P)
                        +String "@" +String Int2String(C +Int D) +String "|" </trace>

  // ---- explicit retract of a logical fact ([LFAC.1.2.2] / LLOG.8) ----
  rule <k> retract S:String K:Int => . ...</k>
       <lstore> ... lkey(S, K) |-> lfact(Pold, _) => .Map ... </lstore>
       <trace> Tr => Tr +String "retract:" +String S +String ":" +String Int2String(K)
                        +String "=" +String Int2String(Pold) +String "|" </trace>
  rule <k> retract S:String K:Int => . ...</k>
       <lstore> LS </lstore>
       <trace> Tr => Tr +String "retract_miss:" +String S +String ":" +String Int2String(K) +String "|" </trace>
    requires notBool (lkey(S, K) in_keys(LS))

  // ---- tick: advance the clock, then sweep every ttl fact whose deadline
  //      has passed, in insertion order ([LFAC.1.3.3]). ----
  syntax KItem ::= "sweep" | sweepGo(List, List)
  rule <k> tick N:Int => sweep ...</k> <clock> C => C +Int N </clock>
  rule <k> sweep => sweepGo(TS, .List) ...</k> <tstore> TS => .List </tstore>
  rule <k> sweepGo((ListItem(tfact(S:String, P:Int, Dl:Int)) Rest:List), Kept:List) => sweepGo(Rest, Kept) ...</k>
       <clock> C </clock>
       <trace> Tr => Tr +String "ttl_expire:" +String S +String ":" +String Int2String(P) +String "|" </trace>
    requires Dl <=Int C                                                          // due -> expire, drop
  rule <k> sweepGo((ListItem(F:TFact) Rest:List), Kept:List) => sweepGo(Rest, (Kept ListItem(F))) ...</k>
       <clock> C </clock>
    requires notBool due(F, C)                                                   // not due -> keep, in order
  rule <k> sweepGo(.List, Kept:List) => . ...</k> <tstore> _ => Kept </tstore>

  syntax Bool ::= due(TFact, Int) [function]
  rule due(tfact(_, _, Dl:Int), C:Int) => Dl <=Int C

  // ---- count: stamp the live-fact total (logical + ttl) into the trace ----
  rule <k> count => . ...</k>
       <lstore> LS </lstore> <tstore> TS </tstore>
       <trace> Tr => Tr +String "live=" +String Int2String(size(LS) +Int size(TS)) +String "|" </trace>
endmodule

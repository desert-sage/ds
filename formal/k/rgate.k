requires "rkey.k"
// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [RLOW.4.6.2] [RLOW.4.6.2.1] [IRET.10.4]
//
// rgate.k -- the DS RATE-ALLOW GATE (cooldown) as small-step operational
// semantics (K Framework). Where rlow.k lowers a `cooldown` header to a
// `ds_rate_allow` GATE *structurally*, this def runs the gate's *behaviour over
// time*: a per-`(rule, activation_key)` state machine stepped by activation
// attempts (`act` / `actv`) interleaved with clock ticks, deciding fire vs
// suppress at each attempt.
//
// THE KEY IS THE CLAUSE'S IDENTITY, NOT A RENDERING. This def imports `rkey.k`'s
// identity (RLOW.4.6.2.1) and keys its state on the canonical component list: an Int and a String that
// read alike are two keys with two windows (`rgate.key_int_str_distinct`), a
// Time and an Int holding one count are one key with one window
// (`rgate.key_time_is_int`).
//
// NORMATIVE COMPANION (specs/runtime/LOWERING, RLOW.4.6). Formalizes:
//   * [RLOW.4.6.2.2] COOLDOWN. State `(rule,key) -> last_fire_ns`. At the gate,
//     if `now - last_fire < window` -> suppress; else -> fire and stamp
//     `last_fire = now`. A key with no recorded firing fires, and every
//     instant, zero included, is a valid stamp: `<cool>` is a K MAP, so "no
//     prior fire" is a real absence test, distinct from every instant.
//   * [RLOW.4.6.2.3] cooldown state is per activation key -- distinct keys have
//     independent cooldown state.
//   * [IRET.10.4]'s cooldown paragraph, the libds side of the same gate: the
//     `ds-rate-allow` builtin keeps per-engine state keyed by
//     `(rule_name, activation_key)`, the key's components composed from the
//     bound facts ([LCDB.3.3.3]; their identity `rkey.k`'s), whose value is
//     `last_fire_ns`; it returns allow when `now_ns - last_fire_ns >=
//     cooldown_ns` and on allow sets `last_fire_ns = now_ns`. That paragraph
//     is the three `actk` rules. The clause's other two -- cooldown lowering
//     to an `IF` whose condition is the builtin, and the duration living in
//     the RETP atom's terminal -- are the lowering's (rlow.k, RLOW.4.6.1) and
//     the artefact's, not this file's.
//
// COOLDOWN IS THE ONLY RATE MODIFIER ([LCDB.5.1]), so it is the only thing this
// gate decides. An on-delay is a `where` condition on `dwell` ([LCDB.3.2.3]):
// the engine keeps no rate state for it, and nothing of it is modelled here.
// The gate has no notion of an activation ENDING either. Its state is per key
// and outlives the activation that stamped it, because [LCDB.3.2.1] suppresses
// further fires of the same activation KEY, whichever activation carries it.
//
// THE MEANING. krun replays a schedule of activation attempts and clock ticks;
// the <trace> cell records the gate verdict at each attempt -- fire@t /
// cool_suppress@t, the key rendered component by component under its tag --
// the observable a conforming ds_rate_allow tracker ([IRET.25.5]) produces.
// Durations are ns as small Ints. The tie is file-level, the tag line at the
// head of this file, and the crossref gates it in both directions.
//
// ============================================================================
// THIS MODEL AND THE REFERENCE RUNTIME
// ============================================================================
//
// This model formalizes the CLAUSES; `adapter_ds_rate_allow` in
// runtime/src/libds/rete/adapters.c is what ships. They differed once, and the
// vector that shows where is still here.
//
// `ds_rate_entry_t` is calloc'd, and `last_fire_ns == 0` is a valid instant, so
// it cannot spell "no prior fire". The entry carries a `has_fired` flag beside the
// instant, and RLOW.4.6.2.2 says the sentence the flag realises.
//
// `rgate.cool_suppress` -- the simplest cooldown vector in this corpus -- is
// that case: its schedule starts at 0 because this model's clock does. The
// conformance fixture `logical/LCDB.3.2.1_rgate_cool_suppress` is its twin on
// the runtimes, and `formal/idris/Rete/RateGate.idr` proves what the zero
// sentinel lost.
//
// WHAT TIES THE VECTORS TO THE RUNTIMES, AND WHAT DOES NOT. The `cool_*`
// vectors and `key_separates` each have a twin in the conformance corpus
// (`logical/LCDB.3.2.1_rgate_*`, `logical/LCDB.3.3.3_rgate_*`); the three
// `key_*_distinct` / `key_time_is_int` vectors have none. The four `cool_*`
// schedules are also transcribed in `runtime/mercury/test/test_ds.m`
// (`rgate_corpus`), as schedules and verdicts, not as this trace. Twins and
// transcription are copies made by hand: nothing compares either with the
// `.expected` file beside the `.prog`.
//
// NOTHING IN THIS MODEL IS CHANGED TO MATCH THE C, and that is the point. The
// standing rule that a second implementation follows the reference once an
// ambiguity is filed governs RUNTIMES; this file's job is to say what the
// clauses require, so that a disagreement is visible rather than absorbed.

module RGATE-SYNTAX
  imports INT-SYNTAX
  imports STRING-SYNTAX
  imports RKEY-SYNTAX

  // schedule operations over named rate-limited rules.
  //   cooldown R T       -- declare rule R has a cooldown window T
  //   act R K            -- an activation of rule R whose key is the one Int K
  //   actv R Vs          -- an activation of rule R with activation key Vs
  //   tick N             -- advance the clock by N
  syntax Stmt ::= "cooldown" String Int
                | "act" String Int
                | "actv" String Vals
                | "actk" String Vals
                | "tick" Int
                > Stmt Stmt [left]
endmodule

module RGATE
  imports RGATE-SYNTAX
  imports INT
  imports BOOL
  imports STRING
  imports MAP
  imports RKEY-IDENTITY

  // the per-(rule,key) state key (an inert constructor): the rule, and the
  // activation key as its canonical components, compared whole.
  syntax KItem ::= coolkey(String, Vals)     // (rule, activation key) -> last_fire_ns

  configuration
    <T>
      <k> $PGM:Stmt </k>
      <rules> .Map </rules>       // String -> Int, the rule's cooldown window
      <cool> .Map </cool>         // coolkey(R,K) -> last_fire_ns
      <clock> 0 </clock>
      <trace> "" </trace>
    </T>

  rule <k> S1:Stmt S2:Stmt => S1 ~> S2 ...</k>                                    // sequencing

  // ---- declaration: the rule's cooldown window. ----
  rule <k> cooldown R:String T:Int => . ...</k> <rules> M => M[R <- T] </rules>

  rule <k> tick N:Int => . ...</k> <clock> C => C +Int N </clock>

  // helper: emit a verdict event `<tag>:R:<key>@now|`, the key rendered as
  // rkey.k renders it.
  syntax String ::= ev(String, String, Vals, Int) [function]
  rule ev(Tag:String, R:String, K:Vals, C:Int)
    => Tag +String ":" +String R +String ":" +String rendAll(K) +String "@" +String Int2String(C) +String "|"


  // ---- THE TWO SURFACE FORMS, BOTH KEYING ON THE CANONICAL KEY. ------------
  //
  // `act R K` is the one-Int key, which the cooldown vectors write; `actv R
  // Vs` any key. Both reach `actk` over the canonical components, so the gate
  // keys on what the clause says a key is.
  //
  // The one-component key is spelled as a list. In a rule's right-hand side a
  // bare `Val` where a `Vals` is expected is an injection, not the singleton
  // list the program parser makes of `(i 1)`, and `rendAll` has no case for
  // an injection: `actk R (i K)` left every `act` vector stuck at
  // `rendAll(i 1)`.
  syntax Vals ::= one(Val) [function]
  rule one(V:Val) => V , .Vals

  rule <k> act R:String K:Int => actk R one(i K) ...</k>
  rule <k> actv R:String Vs:Vals => actk R normAll(Vs) ...</k>
  // ===========================================================================
  // THE GATE.  RLOW.4.6.2
  // ===========================================================================
  // first attempt (no prior fire) -> FIRE, stamp last_fire.
  rule <k> actk R:String K:Vals => . ...</k>
       <rules> ... R |-> _:Int ... </rules>
       <cool> CM => CM[coolkey(R, K) <- C] </cool>
       <clock> C </clock>
       <trace> Tr => Tr +String ev("fire", R, K, C) </trace>
    requires notBool (coolkey(R, K) in_keys(CM))
  // prior fire, cooldown elapsed (now - last >= window) -> RE-FIRE, restamp.
  rule <k> actk R:String K:Vals => . ...</k>
       <rules> ... R |-> Cool:Int ... </rules>
       <cool> ... coolkey(R, K) |-> (Last => C) ... </cool>
       <clock> C </clock>
       <trace> Tr => Tr +String ev("fire", R, K, C) </trace>
    requires (C -Int Last) >=Int Cool
  // prior fire, still within cooldown -> SUPPRESS.
  rule <k> actk R:String K:Vals => . ...</k>
       <rules> ... R |-> Cool:Int ... </rules>
       <cool> ... coolkey(R, K) |-> Last ... </cool>
       <clock> C </clock>
       <trace> Tr => Tr +String ev("cool_suppress", R, K, C) </trace>
    requires (C -Int Last) <Int Cool
endmodule

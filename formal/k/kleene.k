// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LNUL.4.2]
//
// kleene.k -- DS null/Kleene 3-valued boolean logic as EXECUTABLE operational
// semantics (K Framework). The pilot for the "language -> meaning" lane: where
// Alloy bounds structure, TLC checks behavior over time, and SAW proves the C
// bit-exact, K *runs the language* -- a reference interpreter and, later, the
// object metatheorems are proved about.
//
// NORMATIVE COMPANION. Formalizes [LNUL.4.2]: `and` / `or` / `not` over
// {true, false, null} by the standard Kleene tables (and = min, or = max under
// false < null < true; not flips true/false and fixes null). Each rule group
// names its clause in a comment. The tie is file-level, the tag line at the
// head of this file, and the crossref gates it in both directions.
//
// THE MEANING. krun reduces a boolean expression to its Kleene value; the gate's
// test programs pin the boundary rows the spec table names (true and null = null,
// false or null = null, ...), which is where a naive two-valued evaluator breaks.
//
// EVERY RULE IS REACHED BY A NAMED VECTOR. `kleene.<op>_<cell>.prog` pins each
// cell once, named for the cell, so a wrong entry in the table fails the lane.

module KLEENE-SYNTAX
  // The three truth values ([LNUL.4.2]).
  syntax KVal ::= "true" | "false" | "null"
  // Boolean expressions; [strict] evaluates operands to values first.
  syntax KExp ::= KVal
                | "not" KExp        [strict]
                | KExp "and" KExp   [strict, left]
                | KExp "or"  KExp   [strict, left]
                | "(" KExp ")"      [bracket]
endmodule

module KLEENE
  imports KLEENE-SYNTAX
  syntax KResult ::= KVal

  // not: true<->false, null fixed ([LNUL.4.2]).
  rule not true  => false
  rule not false => true
  rule not null  => null

  // and = min over false < null < true ([LNUL.4.2]).
  rule true  and B:KVal => B
  rule false and _:KVal => false
  rule null  and true   => null
  rule null  and null   => null
  rule null  and false  => false

  // or = max over false < null < true ([LNUL.4.2]).
  rule false or B:KVal => B
  rule true  or _:KVal  => true
  rule null  or true    => true
  rule null  or null    => null
  rule null  or false   => null
endmodule

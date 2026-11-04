// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LUNI.14.5] [LEXP.5.7.3]
//
// fpcompose.k -- the PINNED DECOMPOSITIONS of composite Float operations, as
// executable reductions (K Framework). A composition of correctly rounded steps
// is not itself correctly rounded, so the clause fixes the steps, and two
// conforming engines agree bit for bit only if both take exactly these steps,
// in this order, rounding once per step ([LDET.3.4.4], [LDET.3.6.1]).
//
// THE MEANING. `reduce(op)` rewrites an operation to the sequence of primitive
// calls the clause pins, written as a term: `mul(x,y)` is one correctly rounded
// multiplication, `add`, `sub`, `div`, `sqrt` likewise, and `exp`, `cos`, `sin`
// one correctly rounded transcendental ([LEXP.3.9.2]). A shared intermediate is
// a `let`: it is computed once and used where it is named.
//
//   * `exp(z)`, z = a + bi ([LUNI.14.5]):
//       Re = mul(exp(a), cos(b)),  Im = mul(exp(a), sin(b)),  exp(a) once.
//   * `distance.cosine(a, b)` ([LEXP.5.7.3]; the `distance` module's):
//     1 - (a.b) / (sqrt(a.a) * sqrt(b.b)),
//       every dot product summed LEFT TO RIGHT over the components in argument
//       order, the two norms taken separately and then multiplied. Floating-point
//       addition is not associative, so the order of the sum is the specification.
//
// WHAT THIS IS FOR. The reference the two-runtime differential and the
// conformance vectors are read against: a runtime whose
// trace of primitive calls is not this term computes another function. What it
// is NOT: a model of the values. The primitives are uninterpreted here; their
// bits are [LEXP.3.9.2]'s and IEEE 754's.
//
// RULE REACHABILITY. Every rule below is reached by a named vector:
// `fpcompose.cexp` (the `cexp` rule), `fpcompose.cosdist_one` (dot of one
// component: the seed rule and the empty-tail rule), `fpcompose.cosdist_three`
// (the accumulating rule, twice per dot product). Vectors of unequal length
// match no `dotAcc` rule and do not reduce: the reduction is stuck rather than
// silently truncated. No vector pins that, because a stuck function application
// has no stable rendering to compare against.

module FPCOMPOSE-SYNTAX
  imports STRING-SYNTAX

  // A vector's components, by name: ["a1"; "a2"; ...].
  syntax Comps ::= List{String, ";"}

  // The composite operations.
  syntax Op ::= "cexp" "(" String "," String ")"                 // exp(a + bi)
              | "cosdist" "(" "[" Comps "]" "," "[" Comps "]" ")" // distance.cosine(a, b)

  // The program: reduce an operation to its pinned primitive calls.
  syntax Prog ::= "reduce" "(" Op ")"
endmodule

module FPCOMPOSE
  imports FPCOMPOSE-SYNTAX
  imports STRING

  syntax KResult ::= String

  rule <k> reduce(O:Op) => red(O) ...</k>

  syntax String ::= red(Op)                       [function]
                  | dot(Comps, Comps)             [function]
                  | dotAcc(String, Comps, Comps)  [function]

  // ---- exp(z): Euler, exp(a) evaluated once ([LUNI.14.5]) ----
  rule red(cexp(A:String, B:String))
    => "let e=exp(" +String A +String ") in cplx(mul(e,cos(" +String B
       +String ")),mul(e,sin(" +String B +String ")))"

  // ---- distance.cosine: separate norms, left-to-right sums ([LEXP.5.7.3]) ----
  rule red(cosdist([ As:Comps ], [ Bs:Comps ]))
    => "sub(1,div(" +String dot(As, Bs) +String ",mul(sqrt(" +String dot(As, As)
       +String "),sqrt(" +String dot(Bs, Bs) +String "))))"

  // the first product seeds the sum ...
  rule dot(A:String ; As:Comps, B:String ; Bs:Comps)
    => dotAcc("mul(" +String A +String "," +String B +String ")", As, Bs)
  // ... each later one is added to everything before it ...
  rule dotAcc(Acc:String, A:String ; As:Comps, B:String ; Bs:Comps)
    => dotAcc("add(" +String Acc +String ",mul(" +String A +String "," +String B +String "))",
              As, Bs)
  // ... and the sum ends when both vectors do. Unequal lengths match no rule.
  rule dotAcc(Acc:String, .Comps, .Comps) => Acc
endmodule

// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [RLOW.4.5.1] [RLOW.4.5.2.1] [RLOW.4.5.3.1]
//
// rlet.k -- DS `let`-binding TIER LOWERING as executable rewrite semantics (K
// Framework). The final K slice of the compiler front-half (with rlow.k): a
// let's RHS belongs to one of two purity tiers (RLOW.4.5.1, per [LGRA.9.8.4])
// that decide how it lowers. `krun lower(rule)` reduces a rule's let list + body
// use-sites to the lowered form: pure lets vanish (inlined), sync-impure lets
// become BIND nodes.
//
// NORMATIVE COMPANION (specs/runtime/LOWERING, RLOW.4.5). Formalizes:
//   * RLOW.4.5.1 TWO TIERS, per [LGRA.9.8.4]: pure and sync-impure, and no
//     third. `Tier` has two alternatives for that reason.
//   * RLOW.4.5.2.1 A PURE `let` IS INLINED: its right-hand side, with any
//     earlier `let` it names already substituted, replaces every use and is
//     lowered as any expression. No atom, no node, no bind slot, and no
//     memoisation -- a pure `let` used at N sites is evaluated N times
//     ([LLET.10.3]).
//   * RLOW.4.5.3.1 A SYNC-IMPURE `let` IS BOUND ONCE PER FIRING. The tier is
//     the one [LGRA.9.8.4] names -- `now()`, `monotonic_ns()`, `cached(key)` --
//     and the clause cites it rather than listing it. The compiler emits,
//     ahead of the rule's other actions and in source order, an `ACTION_CALL`
//     whose expression is a `bind` (`BindExpr`) carrying the let's bind index
//     and its right-hand side, and lowers every use to a `bind_ref` of that
//     index; `TERM.bind_count` is how many such lets there are. Here a bind is
//     `BIND(name, expr)` and a use `BIND_REF(name)`, the name standing for the
//     index, and `BINDS(...)` ahead of `BODY(...)` is the order the clause
//     fixes; every use reads one evaluation, made once per firing.
//
// THERE IS NO THIRD TIER, and this file models none. [LGRA.9.8.4] says so in
// those words. A `let` naming `latest` is refused before lowering as an unknown
// function ([LGRA.9.8.2], [LGRA.9.8.11]), so there is nothing for a lowering model
// to say about it.
//
// `cached(key)` IS SYNC-IMPURE. RLOW.4.5.1 defines the tiers "per LGRA.9.8.4",
// and [LGRA.9.8.4] lists `cached(key)` under SYNC-IMPURE -- "`now()`,
// `monotonic_ns()` and `cached(key)`. Bound once per rule activation".
// [LSTO.4.3.1] is explicit at the language surface
// ("`cached("<key>")` is ALWAYS SYNCHRONOUS ... MUST return the value inline,
// in the same rule activation") and [LSTO.4.3.1b] classifies it `sync_impure`
// by name. `rlet.sync_cached` is that case: one BIND, BIND_REF at each use.
//
// THE MEANING. krun lowers a rule's lets + body. The result is
// `BINDS(<bind nodes>)BODY(<lowered use sites>)` -- pure lets leave no BIND and
// their uses carry the inlined expansion; sync lets contribute one BIND and
// their uses carry BIND_REF. Expressions are opaque fragments (`lit`), let
// references (`ref`), one-arg applications (`app`), `now`, `monotonicNs`,
// `cached`; deep expression lowering is RLOW.6 (dsexpr). `monotonic_ns` is the
// third sync-impure builtin [LGRA.9.8.4] names, and `rlet.sync_monotonic_ns`
// lowers it as `rlet.sync_bind` lowers `now()`: one BIND, a BIND_REF at every
// use. The tier is given with the `let` (`pure` / `sync`) rather than decided
// here: the compiler decides it by the whole right-hand side being a call of a
// sync-impure builtin (`dsc.rete.m`, `sync_impure_call`), and what this file
// runs is the lowering each tier gets. The tie is file-level, the tag line at
// the head of this file naming the two normative clauses and the tiers'
// clause, and the crossref gates it in both directions.
//
// RULE REACHABILITY. The ten programs fire every one of
// the fifteen rules below: `rend` of `app` by pure_app, of `now` by sync_bind,
// of `monotonicNs` by sync_monotonic_ns, of `cached` by sync_cached, of `ref` and
// `lookup` by every program with a let; the pure and sync `doLets` rules by the
// `pure_*` and `sync_*` programs; the rest by every program.

module RLET-SYNTAX
  imports STRING-SYNTAX

  // let-RHS / use-site expressions.
  syntax Expr ::= "lit" "(" String ")"           // an opaque expression fragment
                | "ref" "(" String ")"           // a reference to a let name
                | "app" "(" String "," Expr ")"  // a one-arg application f(<expr>)
                | "now"                          // the now() sync-impure builtin
                | "monotonicNs"                  // monotonic_ns() -- sync-impure ([LGRA.9.8.4])
                | "cached" "(" String ")"        // cached(key) -- ALSO sync-impure ([LGRA.9.8.4])

  // a let's pre-classified purity tier (RLOW.4.5.1 / [LGRA.9.8.4]): two, no third.
  syntax Tier ::= "pure" | "sync"
  syntax Let  ::= "let" "(" String "," Tier "," Expr ")"
  syntax Lets ::= ".Lets" | Let Lets                 // let list, declaration order
  syntax Use  ::= "use" "(" Expr ")"                 // a body use-site (an RHS action)
  syntax Uses ::= ".Uses" | Use Uses
  syntax Rule ::= "rule" "(" Lets "," Uses ")"
  syntax Prog ::= "lower" "(" Rule ")"
endmodule

module RLET
  imports RLET-SYNTAX
  imports BOOL
  imports STRING
  imports MAP

  syntax KResult ::= String

  configuration
    <T>
      <k> $PGM:Prog </k>
      <env> .Map </env>          // let name -> its resolved expansion (String)
      <binds> "" </binds>        // emitted BIND(...) nodes (sync tier)
      <body> "" </body>          // lowered body use-sites
    </T>

  syntax KItem ::= doLets(Lets) | doUses(Uses) | finish(Uses) | "emit"

  rule <k> lower(rule(Ls:Lets, Us:Uses)) => doLets(Ls) ~> finish(Us) ...</k>

  // ---- render an expression, substituting let refs via the env ----
  syntax String ::= rend(Expr, Map) [function] | lookup(String, Map) [function]
  rule rend(lit(S:String), _:Map)        => S
  rule rend(ref(N:String), Env:Map)      => lookup(N, Env)
  rule rend(app(F:String, E:Expr), Env:Map) => F +String "(" +String rend(E, Env) +String ")"
  rule rend(now, _:Map)                  => "now()"
  rule rend(monotonicNs, _:Map)          => "monotonic_ns()"
  rule rend(cached(K:String), _:Map)     => "cached(" +String K +String ")"
  rule lookup(N:String, (N |-> V:String) _:Map) => V

  // ---- process the let list in declaration order ----
  rule <k> doLets(.Lets) => . ...</k>
  // PURE -> inline: store the resolved expansion, emit no BIND (RLOW.4.5.2).
  rule <k> doLets(let(N:String, pure, E:Expr) Rest:Lets) => doLets(Rest) ...</k>
       <env> Env => Env[N <- rend(E, Env)] </env>
  // SYNC-IMPURE -> one BIND; the name resolves to BIND_REF (RLOW.4.5.3).
  rule <k> doLets(let(N:String, sync, E:Expr) Rest:Lets) => doLets(Rest) ...</k>
       <env> Env => Env[N <- ("BIND_REF(" +String N +String ")")] </env>
       <binds> B => B +String "BIND(" +String N +String "," +String rend(E, Env) +String ")|" </binds>

  // ---- after the lets: lower the body, then emit ----
  rule <k> finish(Us:Uses) => doUses(Us) ~> emit ...</k>

  rule <k> doUses(.Uses) => . ...</k>
  rule <k> doUses(use(E:Expr) Rest:Uses) => doUses(Rest) ...</k>
       <env> Env </env>
       <body> Bd => Bd +String rend(E, Env) +String "|" </body>

  // ---- assemble the lowered form ----
  rule <k> emit => "BINDS(" +String B +String ")BODY(" +String Bd +String ")" ...</k>
       <binds> B </binds> <body> Bd </body>
endmodule

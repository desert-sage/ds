// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [RLOW.4.6.2.1]
//
// rkey.k -- the ACTIVATION KEY'S IDENTITY, executed. `rgate.k` runs the gate's
// behaviour over time and keys its state on what this def computes.
//
// THE CLAUSE FIXES AN IDENTITY, NOT AN ENCODING (RLOW.4.6.2.1). A key is the sequence
// of values [LCDB.3.3.3] composes, and two keys are the same key only if they
// have the same length and, position by position, values of the same
// representation -- [LNUL.4.9]'s tag, not the declared type -- that are equal
// under it: `1`, `"1"` and `true` are three keys; a Time and an Int holding
// one count are one key; `0.0` and `-0.0` are one key; `null` equals only
// `null`; nothing is rounded, truncated or compared by prefix, and a key has
// no length limit of its own. How a runtime stores a key is its own, provided
// the storage preserves this identity.
//
// WHAT THIS FILE RUNS. libds keys typed and whole
// (`rk_walk`, runtime/src/libds/rete/adapters.c) and the Mercury runtime
// compares a `list(key_part)` as a term (`ds.rate.m`). What runs here is the
// identity both runtimes realise;
// `formal/idris/Rete/ActivationKey.idr` proves of the same identity that
// libds's byte frame is injective over it. K executes the identity's cases,
// which Idris's `Refl` does not reach for a Float or a String of 600 bytes;
// Idris proves the frame for every key, which no vector can.
//
// THE OBSERVABLE. `same A ; B` writes `same` or `different` to `<key>` -- the
// clause's identity decided on two keys -- and the two component counts to
// `<len>` as `len=<n>,<m>`. `key Vs` writes the key with every component
// under its tag, `int(1)|str(1)|bool(true)`, so a reader sees what keeps `1`,
// `"1"` and `true` apart, and its component count as `len=<n>`. The rendering
// is not a storage format: it is the identity made visible, and a Time renders
// as the Int it keys as.
//
// WHAT IS NOT HERE. A Json component (deep structural equality,
// [LFAC.2.5.1]) and a Bytes component: K has no Json model and no vector needs
// either. A NaN, which reaches no slot ([LEXP.4.2]). The composition of the
// key from the bound facts, which is [LCDB.3.3.3]'s and
// `formal/idris/Lcdb/RuleGlobal.idr`'s.

module RKEY-SYNTAX
  imports INT-SYNTAX
  imports STRING-SYNTAX
  imports BOOL-SYNTAX
  imports FLOAT-SYNTAX

  // A key component: a value under its representation's tag.
  //   i N      an Int
  //   t N      a Time, Date or Duration: an Int by its count ([LNUL.4.9])
  //   f F      a Float
  //   b B      a Bool
  //   s S      a String
  //   null     null
  syntax Val ::= "i" Int
               | "t" Int
               | "f" Float
               | "b" Bool
               | "s" String
               | "null"

  // Parenthesisation, so a schedule can write `actv "R" (s "1")` without the
  // Vals list swallowing the statement that follows it. K does not generate
  // bracket productions.
  syntax Val  ::= "(" Val ")" [bracket]

  syntax Vals ::= List{Val, ","}

  // `rep(N, S)`: N copies of S, so a program can write a long String without
  // carrying its characters; `cat(A, B)`: their concatenation; `ctrl1()`: the
  // byte the retired encoder used as its separator.
  syntax String ::= rep(Int, String) [function]
                  | cat(String, String) [function]
                  | ctrl1() [function]

  syntax Stmt ::= "key" Vals
                | "same" Vals ";" Vals
endmodule

// THE IDENTITY, IN ITS OWN MODULE SO `rgate.k` CAN IMPORT IT. A module carrying
// a `configuration` cannot be imported into a definition that has its own, so
// the functions live here and the `<key>`/`<len>` cells stay in RKEY below.
module RKEY-IDENTITY
  imports RKEY-SYNTAX
  imports INT
  imports BOOL
  imports STRING
  imports FLOAT

  rule rep(N:Int, _:String) => "" requires N <=Int 0
  rule rep(N:Int, S:String) => S +String rep(N -Int 1, S) requires N >Int 0
  rule cat(A:String, B:String) => A +String B
  rule ctrl1() => chrChar(1)

  // ---- the canonical component. ----------------------------------------
  //
  // A Time keys as its count, and the two zeros as one: the two normalisations
  // both runtimes make as they key (`case DS_RETE_VAL_TIME: ... RK_INT` and
  // `if (f == 0.0) f = 0.0`, rete/adapters.c; `key_part_of`, ds.rate.m). Every
  // other component is itself.
  syntax Val ::= norm(Val) [function]
  rule norm(t N:Int) => i N
  rule norm(f F:Float) => f 0.0 requires F ==Float 0.0
  rule norm(V:Val) => V [owise]

  syntax Vals ::= normAll(Vals) [function]
  rule normAll(.Vals) => .Vals
  rule normAll(V:Val , Vs:Vals) => norm(V) , normAll(Vs)

  // ---- the identity. ---------------------------------------------------
  //
  // Two components are one when their representations are one and their
  // values are equal under it: `1` and `"1"` are not, whatever `"1"` says, and
  // `1` and `1.0` are not either.
  syntax Bool ::= samePart(Val, Val) [function]
  rule samePart(i N:Int, i M:Int) => N ==Int M
  rule samePart(f F:Float, f G:Float) => F ==Float G
  rule samePart(b B:Bool, b C:Bool) => B ==Bool C
  rule samePart(s S:String, s T:String) => S ==String T
  rule samePart(null, null) => true
  rule samePart(_:Val, _:Val) => false [owise]

  // The same length -- a key that runs out while the other has a component
  // left is a different key -- and then component by component, each
  // canonical first. `vs` separates the two keys because `,` separates their
  // components.
  syntax Bool ::= "sameKey" "(" Vals "vs" Vals ")" [function]
  rule sameKey(.Vals vs .Vals) => true
  rule sameKey(V:Val , Vs:Vals vs W:Val , Ws:Vals)
    => samePart(norm(V), norm(W)) andBool sameKey(Vs vs Ws)
  rule sameKey(_:Vals vs _:Vals) => false [owise]

  // ---- the rendering, for `<key>` and for rgate's trace. ---------------
  syntax String ::= rend(Val) [function] | rendAll(Vals) [function]
  rule rend(i N:Int) => "int(" +String Int2String(N) +String ")"
  rule rend(t N:Int) => rend(norm(t N))
  rule rend(f F:Float) => "float(" +String Float2String(F) +String ")"
  rule rend(b true) => "bool(true)"
  rule rend(b false) => "bool(false)"
  rule rend(s S:String) => "str(" +String S +String ")"
  rule rend(null) => "null"
  rule rendAll(.Vals) => ""
  rule rendAll(V:Val , .Vals) => rend(V)
  rule rendAll(V:Val , W:Val , Ws:Vals) => rend(V) +String "|" +String rendAll(W , Ws)

  syntax Int ::= count(Vals) [function]
  rule count(.Vals) => 0
  rule count(_:Val , Vs:Vals) => 1 +Int count(Vs)
endmodule

module RKEY
  imports RKEY-IDENTITY

  configuration
    <T>
      <k> $PGM:Stmt </k>
      <key> "" </key>
      <len> "" </len>
    </T>

  syntax String ::= verdict(Bool) [function]
  rule verdict(true) => "same"
  rule verdict(false) => "different"

  // ---- the observables. ------------------------------------------------
  rule <k> key Vs:Vals => . ...</k>
       <key> _ => rendAll(Vs) </key>
       <len> _ => "len=" +String Int2String(count(Vs)) </len>

  rule <k> same Vs:Vals ; Ws:Vals => . ...</k>
       <key> _ => verdict(sameKey(Vs vs Ws)) </key>
       <len> _ => "len=" +String Int2String(count(Vs)) +String "," +String Int2String(count(Ws)) </len>
endmodule

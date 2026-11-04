// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
//@spec [LNUL.4.2] [IRET.9.5] [IRET.7.6] [RFCS.21.1] [LERR.1]
//@derives [LNUL.5.4] [IRET.6.4] [IRET.7.5.1] [RLOW.5.5] [IRET.9.6] [LNUL.4.7]
//@derives [LERR.1.4.11] [LDET.1.11] [RLOW.6.1.4]
//
// dswherev5.k -- a `where` WITH FAULTS: V5, and only
// V5. An executable semantics of one `where` as a flat list of conjuncts, and a
// search over every `where` of up to three conjuncts. Written
// independently of formal/alloy/where_v5.als (relational, solver-quantified)
// and formal/idris/Rete/WhereV5.idr (unbounded, by structural recursion).
//
// A CONJUNCT is c(Out, Raises, Nullable, Body):
//   Out       what it yields for the pair at hand: yes / no / unk (null), or a
//             fault -- trap (ComputationError), te (TypeError), ee (EngineError)
//   Raises    whether it can raise by its declared types
//   Nullable  whether its slot is declared nullable
//   Body      the body of the atom its fault would record, as an ordered key
//
// V5: the conjuncts run in ANY order; the first `no` stops evaluation and
// decides; every fault is absorbed and evaluation goes on; at the end the
// recorded fault is the one no other beats, by kind (ee, then te, then trap)
// and then by the lesser body (T2I); otherwise null; otherwise yes. Only that
// fault is recorded (M1). Filters -- an alpha test, an index probe -- run
// first, as a `where` of their own under V5 ([IRET.6.4]): a `no` among them rejects the candidate whatever
// the others answer; otherwise a fault among them is raised there, the one T2I
// selects of two, and nothing of the rest is evaluated; otherwise unk rejects
// (the model's own); otherwise the rest.
//
// OBSERVABLE: ob(fires, blocked, record) -- whether a positive pattern fires
// ([LNUL.4.3]), whether a `no` pattern is blocked (unless false or rejected,
// [LNUL.4.7]), and the atom recorded.
//
// PROGRAMS
//   search(determ)  every order gives one observable                -> ok
//   search(table)   the answer is [LNUL.4.2]'s absorbing table      -> ok
//   search(hoist)   for an artefact that does not lie, filters on decided
//                   conjuncts (cannot raise, not nullable), then the rest,
//                   give the observable of the whole `where`         -> ok
//   obs(...)        the observable of one `where`
//   hoisted(...)    the observable with the first conjunct taken as a filter
//   hoisted2(...)   the same with the first two taken as filters, in that order
// The .expected files were written from the reading above, by hand, before the
// first run -- not copied from its output.
//
// TEETH (measured on temp branches):
//   the first fault in evaluation order wins -> search(determ) fails on x[R101,R102],
//                                               and the selfjoin / kinds vectors
//   a false does not absorb ee               -> search(determ) and search(table)
//                                               fail on x[F000,X001], and ee_absorbed
//   a nullable conjunct may be a filter      -> search(hoist) fails on x[N010]
//   a faulting filter ends the filter phase  -> fault_then_false_hoisted reads
//                                               fires=0 blocked=1 rec=R#1

module DSWHEREV5-SYNTAX
  imports INT-SYNTAX
  imports BOOL-SYNTAX

  syntax Out ::= "yes" | "no" | "unk" | "trap" | "te" | "ee"
  syntax Cj ::= c(Out, Bool, Bool, Int)
  syntax Cjs ::= List{Cj, ","}
  syntax Prop ::= "determ" | "table" | "hoist"
  syntax Pgm ::= obs(Cjs) | hoisted(Cjs) | hoisted2(Cjs) | search(Prop)
endmodule

module DSWHEREV5
  imports DSWHEREV5-SYNTAX
  imports INT
  imports BOOL
  imports STRING
  imports LIST
  imports SET
  imports K-EQUAL

  configuration <k> $PGM:Pgm </k>

  syntax KItem ::= flt(Out, Int)
                 | "noRec"
                 | ob(Bool, Bool, KItem)
                 | "aYes" | "aNo" | "aNull" | "aRej" | aFault(KItem)
                 | sp(List, List)
                 | "okay" | cex(List)

  // ---- attributes ----
  syntax Out ::= outOf(Cj) [function]
  rule outOf(c(O, _, _, _)) => O
  syntax Bool ::= raisesC(Cj) [function]
  rule raisesC(c(_, R, _, _)) => R
  syntax Bool ::= nullableC(Cj) [function]
  rule nullableC(c(_, _, N, _)) => N
  syntax Int ::= bodyOf(Cj) [function]
  rule bodyOf(c(_, _, _, B)) => B

  syntax Bool ::= isFault(Out) [function]
  rule isFault(trap) => true
  rule isFault(te) => true
  rule isFault(ee) => true
  rule isFault(_) => false [owise]

  // Kind priority, higher first: EngineError, then TypeError, then trap.
  syntax Int ::= prio(Out) [function]
  rule prio(ee) => 3
  rule prio(te) => 2
  rule prio(trap) => 1
  rule prio(_) => 0 [owise]

  // T2I: G beats F by kind, then by the lesser body. Position never enters.
  syntax Bool ::= beats(KItem, KItem) [function]
  rule beats(flt(G, J), flt(F, I)) => prio(G) >Int prio(F) orBool (prio(G) ==Int prio(F) andBool J <Int I)

  syntax KItem ::= bestOf(KItem, List) [function]
  rule bestOf(F, .List) => F
  rule bestOf(F, ListItem(G) R) => bestOf(G, R) requires beats(G, F)
  rule bestOf(F, ListItem(G) R) => bestOf(F, R) requires notBool beats(G, F)

  // ---- V5 over the rest, in the order given ----
  syntax KItem ::= go(List, List, Bool) [function]
  rule go(.List, .List, false) => aYes
  rule go(.List, .List, true) => aNull
  rule go(.List, ListItem(F) N, _) => aFault(bestOf(F, N))
  rule go(ListItem(C:Cj) _, _, _) => aNo requires outOf(C) ==K no
  rule go(ListItem(C:Cj) R, N, S) => go(R, N ListItem(flt(outOf(C), bodyOf(C))), S) requires isFault(outOf(C))
  rule go(ListItem(C:Cj) R, N, _) => go(R, N, true) requires outOf(C) ==K unk
  rule go(ListItem(C:Cj) R, N, S) => go(R, N, S) requires outOf(C) ==K yes

  // ---- filters first, as a `where` of their own, then the rest ----
  // The filters' own V5 answer decides the phase: a `no` among them rejects
  // whatever else they answer; else a fault among them, the one T2I selects,
  // is raised and the rest is not evaluated; else unk rejects; else the rest.
  syntax KItem ::= filt(List, List) [function]
  rule filt(F, R) => filtOn(go(F, .List, false), R)
  syntax KItem ::= filtOn(KItem, List) [function]
  rule filtOn(aYes, R) => go(R, .List, false)
  rule filtOn(aNo, _) => aRej
  rule filtOn(aNull, _) => aRej
  rule filtOn(aFault(X), _) => aFault(X)

  // ---- the observable ----
  syntax KItem ::= obsOf(KItem) [function]
  rule obsOf(A) => ob(A ==K aYes, notBool (A ==K aNo orBool A ==K aRej), recOf(A))
  syntax KItem ::= recOf(KItem) [function]
  rule recOf(aFault(F)) => F
  rule recOf(_) => noRec [owise]

  // ---- the orders V5 may take: every permutation ----
  syntax Set ::= perms(List) [function]
  rule perms(.List) => SetItem(.List)
  rule perms(L) => permsPick(L, .List) requires size(L) >Int 0
  syntax Set ::= permsPick(List, List) [function]
  rule permsPick(.List, _) => .Set
  rule permsPick(ListItem(X) Rest, Before) => prefixAll(X, perms(Before Rest)) |Set permsPick(Rest, Before ListItem(X))
  syntax Set ::= prefixAll(KItem, Set) [function]
  rule prefixAll(_, .Set) => .Set
  rule prefixAll(X, SetItem(L:List) S) => SetItem(ListItem(X) L) |Set prefixAll(X, S)

  // The observables of filters F, then the rest in every order it may take.
  syntax Set ::= obsAll(List, Set) [function]
  rule obsAll(_, .Set) => .Set
  rule obsAll(F, SetItem(O:List) S) => SetItem(obsOf(filt(F, O))) |Set obsAll(F, S)
  syntax Set ::= refSet(List) [function]
  rule refSet(W) => obsAll(.List, perms(W))

  // ---- [LNUL.4.2]'s absorbing table, folded: no, then a fault, then null, then yes ----
  syntax Int ::= proj(KItem) [function]
  rule proj(aYes) => 1
  rule proj(aNo) => 2
  rule proj(aNull) => 3
  rule proj(aFault(_)) => 4
  rule proj(aRej) => 5
  syntax Bool ::= hasOut(List, Out) [function]
  rule hasOut(.List, _) => false
  rule hasOut(ListItem(C:Cj) R, O) => outOf(C) ==K O orBool hasOut(R, O)
  syntax Bool ::= hasFault(List) [function]
  rule hasFault(.List) => false
  rule hasFault(ListItem(C:Cj) R) => isFault(outOf(C)) orBool hasFault(R)
  syntax Int ::= tbl(List) [function]
  rule tbl(W) => 2 requires hasOut(W, no)
  rule tbl(W) => 4 requires notBool hasOut(W, no) andBool hasFault(W)
  rule tbl(W) => 3 requires notBool hasOut(W, no) andBool notBool hasFault(W) andBool hasOut(W, unk)
  rule tbl(W) => 1 requires notBool hasOut(W, no) andBool notBool hasFault(W) andBool notBool hasOut(W, unk)
  syntax Bool ::= allTbl(Set, Int) [function]
  rule allTbl(.Set, _) => true
  rule allTbl(SetItem(O:List) S, T) => proj(filt(.List, O)) ==Int T andBool allTbl(S, T)

  // ---- hoisting: every split into decided filters (source order kept) and the rest ----
  syntax Bool ::= decided(Cj) [function]
  rule decided(C) => notBool raisesC(C) andBool notBool nullableC(C)
  syntax Set ::= splits(List) [function]
  rule splits(.List) => SetItem(sp(.List, .List))
  rule splits(ListItem(C:Cj) Rest) => addTo(C, splits(Rest), decided(C))
  syntax Set ::= addTo(Cj, Set, Bool) [function]
  rule addTo(_, .Set, _) => .Set
  rule addTo(X, SetItem(sp(S, R)) Ss, false) => SetItem(sp(S, ListItem(X) R)) |Set addTo(X, Ss, false)
  rule addTo(X, SetItem(sp(S, R)) Ss, true) =>
    SetItem(sp(ListItem(X) S, R)) |Set SetItem(sp(S, ListItem(X) R)) |Set addTo(X, Ss, true)
  syntax Bool ::= hoistOk(Set, Set) [function]
  rule hoistOk(.Set, _) => true
  rule hoistOk(SetItem(sp(F, R)) S, Ref) => obsAll(F, perms(R)) ==K Ref andBool hoistOk(S, Ref)

  // ---- one property on one `where` ----
  syntax Bool ::= holds(Prop, List) [function]
  rule holds(determ, W) => size(refSet(W)) ==Int 1
  rule holds(table, W) => allTbl(perms(W), tbl(W))
  rule holds(hoist, W) => hoistOk(splits(W), refSet(W))

  // ---- the search domains ----
  // Well-formed conjuncts: a trap or TypeError only where the declared types
  // can raise; null only from a nullable slot; an EngineError anywhere -- a
  // value the artefact lied about. Bodies matter only for faults; two of each.
  syntax List ::= dom() [function]
  rule dom() =>
    ListItem(c(yes, false, false, 0)) ListItem(c(yes, true, false, 0)) ListItem(c(yes, false, true, 0)) ListItem(c(yes, true, true, 0))
    ListItem(c(no, false, false, 0)) ListItem(c(no, true, false, 0)) ListItem(c(no, false, true, 0)) ListItem(c(no, true, true, 0))
    ListItem(c(unk, false, true, 0)) ListItem(c(unk, true, true, 0))
    ListItem(c(trap, true, false, 1)) ListItem(c(trap, true, false, 2)) ListItem(c(trap, true, true, 1)) ListItem(c(trap, true, true, 2))
    ListItem(c(te, true, false, 1)) ListItem(c(te, true, false, 2)) ListItem(c(te, true, true, 1)) ListItem(c(te, true, true, 2))
    ListItem(c(ee, false, false, 1)) ListItem(c(ee, false, false, 2)) ListItem(c(ee, true, false, 1)) ListItem(c(ee, true, false, 2))
    ListItem(c(ee, false, true, 1)) ListItem(c(ee, true, true, 2))
  // An artefact that does not lie: no EngineError.
  syntax List ::= honest(List) [function]
  rule honest(.List) => .List
  rule honest(ListItem(C:Cj) R) => honest(R) requires outOf(C) ==K ee
  rule honest(ListItem(C:Cj) R) => ListItem(C) honest(R) requires outOf(C) =/=K ee
  syntax List ::= domFor(Prop) [function]
  rule domFor(determ) => dom()
  rule domFor(table) => dom()
  rule domFor(hoist) => honest(dom())

  // Every list of one to three conjuncts over a domain.
  syntax List ::= wheres(List) [function]
  rule wheres(D) => singles(D) extend(singles(D), D) extend(extend(singles(D), D), D)
  syntax List ::= singles(List) [function]
  rule singles(.List) => .List
  rule singles(ListItem(X) R) => ListItem(ListItem(X)) singles(R)
  syntax List ::= extend(List, List) [function]
  rule extend(.List, _) => .List
  rule extend(ListItem(L:List) Ls, D) => appendEach(L, D) extend(Ls, D)
  syntax List ::= appendEach(List, List) [function]
  rule appendEach(_, .List) => .List
  rule appendEach(L, ListItem(X) R) => ListItem(L ListItem(X)) appendEach(L, R)

  // ---- rendering ----
  syntax String ::= o2s(Out) [function]
  rule o2s(yes) => "T"
  rule o2s(no) => "F"
  rule o2s(unk) => "N"
  rule o2s(trap) => "R"
  rule o2s(te) => "E"
  rule o2s(ee) => "X"
  syntax String ::= b2s(Bool) [function]
  rule b2s(true) => "1"
  rule b2s(false) => "0"
  syntax String ::= c2s(Cj) [function]
  rule c2s(c(O, R, N, B)) => o2s(O) +String b2s(R) +String b2s(N) +String Int2String(B)
  syntax String ::= w2s(List) [function]
  rule w2s(.List) => ""
  rule w2s(ListItem(C:Cj)) => c2s(C)
  rule w2s(ListItem(C:Cj) ListItem(D) R) => c2s(C) +String "," +String w2s(ListItem(D) R)
  syntax String ::= rec2s(KItem) [function]
  rule rec2s(noRec) => "none"
  rule rec2s(flt(O, B)) => o2s(O) +String "#" +String Int2String(B)
  syntax String ::= ob2s(KItem) [function]
  rule ob2s(ob(P, N, R)) => "fires=" +String b2s(P) +String " blocked=" +String b2s(N) +String " rec=" +String rec2s(R)
  syntax String ::= set2s(Set) [function]
  rule set2s(.Set) => ""
  rule set2s(SetItem(X)) => ob2s(X)
  rule set2s(SetItem(X) S) => ob2s(X) +String " | " +String set2s(S) requires size(S) >Int 0

  syntax List ::= cjsToList(Cjs) [function]
  rule cjsToList(.Cjs) => .List
  rule cjsToList((C, Cs)) => ListItem(C) cjsToList(Cs)

  // ---- programs ----
  rule <k> obs(Cs) => set2s(refSet(cjsToList(Cs))) </k>
  syntax String ::= hoistedOf(List) [function]
  rule hoistedOf(ListItem(C:Cj) R) => set2s(obsAll(ListItem(C), perms(R)))
  rule <k> hoisted(Cs) => hoistedOf(cjsToList(Cs)) </k>
  syntax String ::= hoisted2Of(List) [function]
  rule hoisted2Of(ListItem(C:Cj) ListItem(D:Cj) R) => set2s(obsAll(ListItem(C) ListItem(D), perms(R)))
  rule <k> hoisted2(Cs) => hoisted2Of(cjsToList(Cs)) </k>

  // One `where` per REWRITE STEP, so the LLVM backend can collect garbage
  // between them.
  syntax KItem ::= loop(Prop, List)
  rule <k> search(P) => loop(P, wheres(domFor(P))) </k>
  rule <k> loop(P, ListItem(W:List) Ws) => loop(P, Ws) </k> requires holds(P, W)
  rule <k> loop(P, ListItem(W:List) _) => "x[" +String w2s(W) +String "]" </k> requires notBool holds(P, W)
  rule <k> loop(_, .List) => "ok" </k>
endmodule

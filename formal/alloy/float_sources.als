/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * Where a Float operand comes from, and that none of them is a signalling NaN
 * ([NDET.1.4]'s admission scope; Alloy 6).
 *
 * NORMATIVE COMPANION, named and tagged as kleene_logic.als describes: every
 * element is <lowercased-clause-id>__<tag>, with the clause repeated above it.
 *
 * WHY. [NDET.1.4] admits a hosted row's double arithmetic once TestFloat has
 * shown it correct. On amd64 the check fails on two input classes, a
 * signalling-NaN operand (libds's `fma` and glibc's `rint` return it
 * unquieted) and an out-of-range double-to-unsigned conversion, and the
 * check leaves an input class out only
 * on a proof that DS cannot present it. This model is the first claim: NO
 * FLOAT VALUE EITHER RUNTIME COMPUTES ON IS A SIGNALLING NaN. The second
 * claim, that no double-to-unsigned conversion of an out-of-range value
 * runs, is a property of the C and is a census.
 *
 * THE SOURCES. A Float operand is a value a Float operation takes, and it
 * came into the runtime by one of the paths the spec names:
 *   - a value stored by a host assert, a call argument, a `FactExternal` or a
 *     replayed fact body ([LEXP.4.2]: NaN is refused on every path into a
 *     slot, `DS_ERR_NAN_REJECTED`; [RFCS.23.2]'s `Arg` and a replayed
 *     `FactAssert` reach the same refusal);
 *   - `String :: Float?` ([LCST.4.5.8]: a NaN spelling is `null`, and the
 *     accepted spellings denote a finite value or an infinity);
 *   - a JSON number ([LGRA.5.8.10]: a `Json` float is finite, a literal past
 *     the largest double is malformed, and RFC 8259 has no NaN token);
 *   - the result of a Float operation ([LDET.3.6.2]: an IEEE result, an
 *     infinity or a NaN included; IEEE 754 §6.2 gives such a result as a
 *     QUIET NaN whenever no operand is signalling, and a conversion from an
 *     Int, a Duration or a Time is finite);
 *   - a `double` field of the artefact: an `AlphaLiteral.float_val`, an
 *     `Expr.lit_float`, a slot's `tolerance`, a `TestSlotLiteral.f_val`
 *     ([RDSC.9.10]: a loader refuses an artefact that holds a NaN, of any
 *     payload, in any of them, with `DS_ERR_DSC_SEMANTIC`; an infinity is
 *     not refused. A conforming compiler writes none in any case, `nan`
 *     being `DS_VALIDATE_NAN_VALUE` in every value position, [LEXP.4.2]).
 *
 * WHAT IS CHECKED. That under those clauses no operand is a signalling NaN,
 * however it was derived (`ndet_1_4__no_signalling_operand`), and that
 * nothing stronger is claimed: a quiet NaN is a Float an expression may
 * compute and flow on ([LDET.3.6.2]), and the model admits it
 * (`probe__quiet_nan_flows`).
 *
 * THE ARTEFACT'S FIELDS. [RDSC.9.10] has a loader refuse an artefact holding a
 * NaN in a `double` field, a cheap structural need of [RDSC.9.9]'s kind. The
 * refusal is a fact here, and the claim holds on the spec alone; the branch is
 * the TEETH below. Whether each loader refuses is the Implementer's; this model
 * is of the spec.
 *
 * WHAT IT DOES NOT CHECK. That the code has no other entry for bits into a
 * double: that is the census the Implementer writes under §12.4,
 * mapping every such site of both runtimes to one of these
 * sources and failing on an unmapped one. That CORE-MATH and musl's `fma`
 * build no NaN from a bit pattern: read, not checked (no `nans` constructor
 * and no signalling pattern in the pinned sources). That negation, which
 * IEEE 754 §5.5.1 treats as a copy and which keeps a signalling NaN
 * signalling, ever meets one: it cannot, by this model, since no source
 * hands it one.
 *
 * TEETH. Drop `rdsc_9_10__loader_refuses_nan` and the check fails with an
 * `ArtefactLiteral` operand of class `SignallingNaN`. Weaken `lexp_4_2__slot_paths_refuse_nan` to let a host assert
 * through and it fails with a `HostAssert` operand. Drop
 * `ldet_3_6_2__results_are_quiet` and it fails with an `Operation` whose
 * inputs are finite and whose class is `SignallingNaN`. Those three were
 * measured. By the same
 * reading and not run: `lcst_4_5_8__parse_yields_no_nan` and
 * `lgra_5_8_10__json_float_is_finite` each guard one source alone, and
 * dropping either fails with that source's operand.
 */
module ds/float_sources

// ── vocabulary ───────────────────────────────────────────────────────────────

//@spec [LEXP.4.2]
// A Float value by its class: finite, an infinity, a quiet NaN, a signalling
// NaN. The clause keeps every NaN out of working memory and every payload;
// the two kinds are told apart here because only one of them is the
// TestFloat input class the check leaves out.
abstract sig lexp_4_2__class {}
one sig Finite, Infinite, QuietNaN, SignallingNaN extends lexp_4_2__class {}

//@spec [LEXP.4.2]
// The NaNs, of either kind.
fun lexp_4_2__nan: set lexp_4_2__class { QuietNaN + SignallingNaN }

//@spec [NDET.1.4]
// Where a Float operand came from: the paths by which bits or text become a
// Float in either runtime (the header). The stored-value paths of [LEXP.4.2]
// -- a host assert, a call argument, a `FactExternal` ([RFCS.23.2]), a
// replayed fact body ([RFCS.6.3], asserted as a host assert is); `String ::
// Float?` ([LCST.4.5.8]); a JSON number read from text ([LGRA.5.8.10]); the
// result of a Float operation, or of a conversion from an Int, a Duration or
// a Time, which has no Float operand ([LDET.3.6.2]); a `double` field of the
// artefact -- an alpha literal, an expression literal, a slot's tolerance, a
// test seed ([RDSC.9.10]).
abstract sig ndet_1_4__source {}
one sig HostAssert, CallArgument, ExternalFact, ReplayedFact, TextParse, JsonParse, Operation, ArtefactLiteral extends ndet_1_4__source {}

//@spec [NDET.1.4]
// A Float operand: a value a Float operation computes on, with its source,
// its class, and, for the result of an operation, the operands it was
// computed from.
sig ndet_1_4__operand {
  source: one ndet_1_4__source,
  class: one lexp_4_2__class,
  inputs: set ndet_1_4__operand
}

//@spec [LDET.3.6.2]
// Only an operation's result has inputs, and a derivation is finite: no
// operand is among its own inputs' inputs.
fact ldet_3_6_2__derivations {
  all o: ndet_1_4__operand | o.source != Operation implies no o.inputs
  no o: ndet_1_4__operand | o in o.^inputs
}

// ── the clauses, one fact each ───────────────────────────────────────────────

//@spec [LEXP.4.2]
// "NaN must never enter working memory ... what is refused is storing one in
// a slot, on every path into one": a host assert (`DS_ERR_NAN_REJECTED`), a
// call argument ("refuses the call with `DS_ERR_NAN_REJECTED`"), a
// `FactExternal` and a replayed fact, which reach the same refusal.
fact lexp_4_2__slot_paths_refuse_nan {
  all o: ndet_1_4__operand |
    o.source in HostAssert + CallArgument + ExternalFact + ReplayedFact
      implies o.class not in lexp_4_2__nan
}

//@spec [LCST.4.5.8]
// The accepted spellings denote a finite value or `inf`; "a NaN spelling" is
// among the strings that yield `null`, which is no Float operand.
fact lcst_4_5_8__parse_yields_no_nan {
  all o: ndet_1_4__operand | o.source = TextParse implies o.class not in lexp_4_2__nan
}

//@spec [LGRA.5.8.10]
// "A `Json` float is finite": a literal past the largest double is malformed,
// and RFC 8259 spells no NaN.
fact lgra_5_8_10__json_float_is_finite {
  all o: ndet_1_4__operand | o.source = JsonParse implies o.class = Finite
}

//@spec [LDET.3.6.2]
// An IEEE result, "an infinity or a NaN" included, "returns it, and none
// traps": IEEE 754 §6.2 delivers a QUIET NaN from an operation whose operands
// are not signalling, and a conversion from an integer is finite. Negation,
// a copy operation, keeps a signalling NaN; with no signalling input it
// keeps none.
fact ldet_3_6_2__results_are_quiet {
  all o: ndet_1_4__operand |
    (o.source = Operation and SignallingNaN not in o.inputs.class)
      implies o.class != SignallingNaN
}

//@spec [RDSC.9.10]
// "A loader must refuse with `DS_ERR_DSC_SEMANTIC` an artefact that holds a
// NaN, of any payload, quiet or signalling, in a `double` field of an atom it
// decodes ... An infinity is not refused": an operand from an artefact's
// `double` field is finite or an infinity. The four fields are one source
// here; which field, and the refusal's code, are not modelled.
fact rdsc_9_10__loader_refuses_nan {
  all o: ndet_1_4__operand | o.source = ArtefactLiteral implies o.class not in lexp_4_2__nan
}

// ── consistency ──────────────────────────────────────────────────────────────

//@probe
// The facts admit an instance in which every source hands over an operand and
// an operation derives from two of them.
run probe__every_source {
  ndet_1_4__source in ndet_1_4__operand.source
  some o: ndet_1_4__operand | o.source = Operation and #o.inputs = 2
} for 10

//@probe
// A quiet NaN is a Float an expression may compute and flow on: an operation
// on finite operands yields one, and a later operation takes it.
run probe__quiet_nan_flows {
  some disj a, b: ndet_1_4__operand |
    a.source = Operation and a.class = QuietNaN and a.inputs.class = Finite
    and b.source = Operation and a in b.inputs
} for 8

// ── the claim ────────────────────────────────────────────────────────────────

// No hypothesis outside the facts: every source is gated by its clause, the
// artefact's by [RDSC.9.10].
assert ndet_1_4__no_signalling_operand {
  no o: ndet_1_4__operand | o.class = SignallingNaN
}
//@derives [NDET.1.4]
//@derives [LEXP.4.2]
//@derives [LDET.3.6.2]
//@derives [RDSC.9.10]
check ndet_1_4__no_signalling_operand for 10

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 *@spec [RFCS.16.2]
 *@spec [RFCS.16.3]
 *
 * rfcs_16_2__band.c -- CBMC harnesses for the band geometry and the blind
 * disposition it decides.
 *
 * TWO TAGS. What every assertion below establishes -- a number outside
 * 1..2047 has no band, and no band means malformed -- is [RFCS.16.2]'s
 * exhaustive three-band table, so the ties are [RFCS.16.2] and [RFCS.16.3]
 * alone. Neither [RFCS.16.5] (band-overflow migration) nor [RFCS.16.6] is
 * checked here. The cbmc tie is one-directional ([STYL.5.3.6.1]): a clause
 * that exists is all it checks, and nothing reads the harness's tags against
 * the clauses' content, so a wrong tag would pass.
 *
 * THE CBMC LANE, and how it differs from its neighbours. This is the second
 * tool in the `C |= spec` lane that formal/saw/oa_mix64.saw opened. SAW proves
 * EQUIVALENCE to a bit-precise Cryptol reference over a whole domain; CBMC
 * proves a STATED PROPERTY, and where a loop is involved it proves it only up
 * to an unwind bound. Which of the two a reader is holding must never have to
 * be inferred, so every harness below says so in its own header.
 *
 * Same traceability discipline as the .als / .tla / .saw models: the harness
 * entry points are named <lowercased-clause-id>__<tag> after the clause each
 * one discharges.
 *
 * EACH ENTRY POINT CARRIES ITS OWN INVOCATION, in a `@cbmc` directive on the
 * line above it:
 *
 *     @cbmc <function> [extra cbmc flags...]
 *
 * scripts/formal/check_cbmc.py reads those and runs one CBMC invocation per directive. The
 * bound therefore lives beside the function it bounds rather than in a build
 * file, which is the whole point: a reader of the proof sees what it was proved
 * over without leaving the file.
 *
 * AND the implementation TUs this harness proves ABOUT, which are not optional:
 *
 *@cbmc-src runtime/src/libds/dsc/pbf_reader.c runtime/src/libds/dsc/atom_registry.c
 *
 * Headers declare; they do not define. Given only the headers, CBMC models
 * ds_pbf_band as an undefined function returning nondet and checks every
 * assertion against a value with no relationship to the real code -- which
 * fails, but fails in a way that reads exactly like an ordinary counterexample.
 * That is how the first run of this gate failed, and it is why check_cbmc.py
 * now refuses a harness with no @cbmc-src rather than running one.
 *
 * TWO OF THE THREE HARNESSES HERE ARE UNBOUNDED. ds_pbf_band is straight-line
 * comparison against four constants, so CBMC quantifies over the ENTIRE uint32
 * domain -- all 2^32 field numbers, no unwind limit, no sampling. That is a
 * stronger guarantee than any vector set can state, and it is the reason this
 * clause was picked as the lane's first target. Only the third harness, which
 * reaches ds_pbf_lookup's binary search, carries a bound -- and that bound is
 * derived rather than chosen (see its header).
 */

#include <stdint.h>
#include <stddef.h>

#include "dsc/atom_registry.h"
#include "dsc/pbf_reader.h"

/* -------------------------------------------------------------------------
 * rfcs_16_2__band_is_total
 *
 * [RFCS.16.2] -- the bands are a PARTITION of the field-number space. Every
 * uint32 lands in exactly one, and the four are mutually exclusive.
 *
 * UNBOUNDED: quantifies over all 2^32 inputs. No unwind bound applies.
 *
 * Why totality is the property and not the ranges: the ranges are readable off
 * the source. What a reader needs is that there is no field number for which
 * the function falls through, returns twice, or leaves the caller without a
 * disposition -- because [RFCS.16.3] requires an answer for EVERY unknown
 * number, including ones invented after this reader shipped.
 *
 * WHAT THIS HARNESS DOES NOT PIN, established by seeding rather than assumed.
 * It states the partition in terms of the SAME constants the implementation
 * uses, so it moves with them: seeding DS_ATOM_BAND_REJECT_HI 255 -> 254 left
 * this harness GREEN, because a shifted boundary is still a partition. It
 * proves the SHAPE -- total, disjoint, exhaustive -- and not the VALUES.
 *
 * rfcs_16_2__boundaries_are_exact is what pins the values, because it uses
 * literals. The two are complementary and neither is redundant; reading this
 * one as covering the boundaries is the mistake the seeded run would have let
 * someone make.
 * ------------------------------------------------------------------------- */
/*@cbmc rfcs_16_2__band_is_total */
void rfcs_16_2__band_is_total(void)
{
    uint32_t field;
    __CPROVER_havoc_object(&field);

    ds_atom_band_t b = ds_pbf_band(field);

    /* Exactly one of the four, and nothing else. */
    __CPROVER_assert(b == DS_ATOM_BAND_INJECT ||
                     b == DS_ATOM_BAND_REJECT ||
                     b == DS_ATOM_BAND_SKIP   ||
                     b == DS_ATOM_BAND_NONE,
                     "RFCS.16.2: every field number has a band");

    /* And it is the RIGHT one -- the partition, stated independently of the
       implementation's if-chain order so a reordering cannot satisfy it
       vacuously. */
    if (field >= DS_ATOM_BAND_INJECT_LO && field <= DS_ATOM_BAND_INJECT_HI) {
        __CPROVER_assert(b == DS_ATOM_BAND_INJECT, "RFCS.16.2: 1..127 inject");
    } else if (field >= DS_ATOM_BAND_REJECT_LO && field <= DS_ATOM_BAND_REJECT_HI) {
        __CPROVER_assert(b == DS_ATOM_BAND_REJECT, "RFCS.16.2: 128..255 reject");
    } else if (field >= DS_ATOM_BAND_SKIP_LO && field <= DS_ATOM_BAND_SKIP_HI) {
        __CPROVER_assert(b == DS_ATOM_BAND_SKIP, "RFCS.16.2: 256..2047 skip");
    } else {
        /* Zero, or above 2047: outside every band of [RFCS.16.2]'s table,
           so no band -- NOT a future skip atom. */
        __CPROVER_assert(b == DS_ATOM_BAND_NONE,
                         "RFCS.16.2: outside 1..2047 is no band");
    }
}

/* -------------------------------------------------------------------------
 * rfcs_16_2__boundaries_are_exact
 *
 * [RFCS.16.2] -- the boundaries are powers of two so classification is a
 * high-bit test, and the three live bands are contiguous with no gap and no
 * overlap. An off-by-one at 127/128 or 255/256 would put an atom in the wrong
 * band, which changes a REJECT into a SKIP: silent data loss rather than a
 * refusal.
 *
 * UNBOUNDED: the four boundary pairs are checked directly, not sampled.
 * ------------------------------------------------------------------------- */
/*@cbmc rfcs_16_2__boundaries_are_exact */
void rfcs_16_2__boundaries_are_exact(void)
{
    __CPROVER_assert(ds_pbf_band(0u) == DS_ATOM_BAND_NONE,
                     "RFCS.16.2: 0 is not a field number");

    __CPROVER_assert(ds_pbf_band(1u) == DS_ATOM_BAND_INJECT,
                     "RFCS.16.2: inject starts at 1");
    __CPROVER_assert(ds_pbf_band(127u) == DS_ATOM_BAND_INJECT,
                     "RFCS.16.2: inject ends at 127");
    __CPROVER_assert(ds_pbf_band(128u) == DS_ATOM_BAND_REJECT,
                     "RFCS.16.2: reject starts at 128");
    __CPROVER_assert(ds_pbf_band(255u) == DS_ATOM_BAND_REJECT,
                     "RFCS.16.2: reject ends at 255");
    __CPROVER_assert(ds_pbf_band(256u) == DS_ATOM_BAND_SKIP,
                     "RFCS.16.2: skip starts at 256");
    __CPROVER_assert(ds_pbf_band(2047u) == DS_ATOM_BAND_SKIP,
                     "RFCS.16.2: skip ends at 2047");
    __CPROVER_assert(ds_pbf_band(2048u) == DS_ATOM_BAND_NONE,
                     "RFCS.16.2: 2048 tips out of every band -- not a skip atom");

    /* The 1-byte sub-range is NOT a fourth disposition ([RFCS.16.4]) -- it is
       inside inject and must classify as inject, not as something of its own. */
    __CPROVER_assert(ds_pbf_band(15u) == DS_ATOM_BAND_INJECT,
                     "RFCS.16.4: the fast lane is inject, not a fourth band");
    __CPROVER_assert(ds_pbf_band(16u) == DS_ATOM_BAND_INJECT,
                     "RFCS.16.4: 16 is still inject, only 2-byte");
}

/* -------------------------------------------------------------------------
 * rfcs_16_3__unknown_is_decided_by_band_alone
 *
 * [RFCS.16.3] -- "A reader MUST determine the band of any unknown field number
 * FROM THE NUMBER ALONE and apply the band's disposition." This is the
 * property the whole forward-compat design rests on, and the one a vector set
 * cannot state: it quantifies over numbers that do not exist yet.
 *
 * BOUNDED, and the bound is DERIVED, not chosen. ds_pbf_disposition consults
 * ds_pbf_lookup, a binary search over DS_ATOM_REGISTRY_COUNT entries. A binary
 * search over N terminates in at most ceil(log2(N)) + 1 iterations, so for any
 * N <= 255 that is at most 8. Run with --unwind 9 (8 iterations plus the
 * loop-exit check) and CBMC's unwinding assertions PROVE the bound sufficient
 * rather than assuming it -- so this harness is bounded in form but complete
 * in effect, for every registry size the bound admits.
 *
 * THE BOUND MOVES WITH THE REGISTRY. If DS_ATOM_REGISTRY_COUNT exceeds 255 the
 * bound must rise to 10. The unwinding assertion is what will catch that, which
 * is why it must not be disabled.
 *
 * NO LIVE COUNT IS QUOTED HERE, deliberately. The derivation is stated over the
 * range the bound admits, so it cannot go stale on a registry edit: the bound is
 * slack, so a quoted count could drift with nothing failing.
 * ------------------------------------------------------------------------- */
/*@cbmc rfcs_16_3__unknown_is_decided_by_band_alone --unwind 9 --unwinding-assertions */
void rfcs_16_3__unknown_is_decided_by_band_alone(void)
{
    uint32_t field;
    __CPROVER_havoc_object(&field);

    /* Restrict to atoms this reader has NO entry for -- the case the bands
       exist for. A known atom answers SKIP for a different reason ("nothing to
       refuse"), which pbf_reader.h is explicit is not a dispatch decision. */
    __CPROVER_assume(ds_pbf_lookup(field) == NULL);

    ds_pbf_disposition_t d = ds_pbf_disposition(field);

    switch (ds_pbf_band(field)) {
    case DS_ATOM_BAND_INJECT:
        __CPROVER_assert(d == DS_PBF_DISP_REJECT_INJECT,
                         "RFCS.16.3: unknown inject rejects");
        break;
    case DS_ATOM_BAND_REJECT:
        __CPROVER_assert(d == DS_PBF_DISP_REJECT_VERSION,
                         "RFCS.16.3: unknown reject-band rejects");
        break;
    case DS_ATOM_BAND_SKIP:
        __CPROVER_assert(d == DS_PBF_DISP_SKIP,
                         "RFCS.16.3: unknown skip-band skips");
        break;
    case DS_ATOM_BAND_NONE:
    default:
        __CPROVER_assert(d == DS_PBF_DISP_MALFORMED,
                         "RFCS.16.2: no band means malformed");
        break;
    }

    /* [RFCS.16.3] -- "Blind-wise the outcomes are only two." The split between
       the two reject bands selects the error code, a KNOWN-reader concern; a
       blind reader either refuses or skips. Stated separately because it is the
       claim an integrator reads, and it must not depend on which reject arm
       fired. */
    __CPROVER_assert(d == DS_PBF_DISP_SKIP ||
                     d == DS_PBF_DISP_REJECT_INJECT ||
                     d == DS_PBF_DISP_REJECT_VERSION ||
                     d == DS_PBF_DISP_MALFORMED,
                     "RFCS.16.3: blind outcomes are refuse or skip");
}

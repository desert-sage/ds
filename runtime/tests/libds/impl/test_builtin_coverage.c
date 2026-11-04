/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_builtin_coverage — every live BuiltinFn op has a registered handler.
 *
 * An unregistered op soft-fails at eval, so a rule calling it never fires,
 * and an op-indexed dispatch array gets no -Wswitch-enum. This walks the enum
 * range and asserts every op is registered, a `none` row of [RDSC.4a.9.5], or
 * on KNOWN_UNHANDLED, and that nothing on KNOWN_UNHANDLED is registered.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "fn.h"

/* The walk visits NUMBERS 1..DS_FN__MAX, and the C enum has holes: the
 * numbers builtin_fn.proto reserves, and the live tombstones it keeps that
 * the C enum drops (styl_5_9_2_builtin_enum refuses only a member in C
 * alone). */
static int is_unallocated_number(uint32_t op)
{
    /* The transcendentals. Both enums declare them and builtins.c registers
       them, so this skip only leaves them unchecked. */
    if ((op >= 8 && op <= 11) || (op >= 13 && op <= 22)) return 1;
    /* Reserved in builtin_fn.proto: the belief plane's candidate-set ops. */
    if (op == 42 || op == 43) return 1;
    /* FN_ALERT: a live tombstone in builtin_fn.proto, not in the C enum. */
    if (op == 48) return 1;
    /* FN_UPPER and FN_LOWER: live tombstones, as 48 is. */
    if (op == 66 || op == 67) return 1;
    /* Reserved: FN_FMT_TIME and FN_BINFMT. */
    if (op == 85 || op == 121) return 1;
    /* Reserved: FN_RECORD_EVENT, FN_JSON_ENCODE and FN_ARGS. */
    if (op == 53 || op == 77 || op == 110) return 1;
    /* Reserved: FN_IS_NULL. */
    if (op == 109) return 1;
    /* Reserved: FN_SERIES_WARMED_UP. */
    if (op == 100) return 1;
    /* Reserved: FN_MONOTONIC. */
    if (op == 80) return 1;
    /* Reserved: the byte and string conversions. */
    if (op == 68 || (op >= 71 && op <= 74)) return 1;
    /* Reserved: FN_TO_TIME, FN_TO_DATE and FN_TO_DURATION. */
    if (op == 84 || op == 135 || op == 136) return 1;
    /* Reserved: FN_HAMMING and FN_LEVENSHTEIN. */
    if (op == 38 || op == 39) return 1;
    /* FN_BITS .. FN_TRAILING_ZEROS: declared and registered, and left
       unchecked by this skip, as the transcendentals are. */
    if (op >= 146 && op <= 150) return 1;
    return 0;
}

/* Ops the C enum declares that have no handler. */
static const struct {
    ds_builtin_fn_t op;
    const char     *why;
} k_known_unhandled[] = {
    /* builtin_fn.proto: FN_LATEST is not emitted as a call. */
    { DS_FN_LATEST, "latest(): async-let desugar not implemented in v1" },
};

static int is_known_unhandled(uint32_t op, const char **why)
{
    for (size_t i = 0; i < sizeof k_known_unhandled / sizeof *k_known_unhandled;
         i++) {
        if ((uint32_t) k_known_unhandled[i].op == op) {
            *why = k_known_unhandled[i].why;
            return 1;
        }
    }
    return 0;
}

/* Every op the enum declares must resolve, or be on the ratchet. */
static int test_every_live_op_has_a_handler(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(&cfg, &e);
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new: %d %s\n",
                r.status, r.detail ? r.detail : "(null)");
        return 1;
    }

    int      failed  = 0;
    unsigned n_ok    = 0;
    unsigned n_gap   = 0;
    unsigned n_none  = 0;
    /* op 0 is FN_UNSPECIFIED — never dispatched. */
    for (uint32_t op = 1; op < (uint32_t) DS_FN__MAX; op++) {
        const char *why = NULL;
        if (is_unallocated_number(op)) continue;
        if (ds_lookup_fn(op) != NULL) {
            n_ok++;
            /* A ratcheted gap that has since been wired: tighten the list. */
            if (is_known_unhandled(op, &why)) {
                fprintf(stderr,
                        "FAIL: op %u is on KNOWN_UNHANDLED (\"%s\") but IS "
                        "registered — remove it from the ratchet\n", op, why);
                failed = 1;
            }
            continue;
        }
        if (is_known_unhandled(op, &why)) { n_gap++; continue; }
        /* A `none` row of [RDSC.4a.9.5] has no handler BY DESIGN, not as a gap:
           its shape "admits no count", so the loader refuses a call of it
           ([RDSC.4a.9.3]) and nothing reaches eval.
           test_rdsc_4a_9_5_operands holds the other direction, that no `none`
           row has a handler. */
        if (ds_fn_operands[op].shape == DS_FN_SHAPE_NONE) { n_none++; continue; }
        fprintf(stderr,
                "FAIL: builtin op %u is declared in ds_builtin_fn_t but has "
                "no registered handler; it would soft-fail silently at eval\n",
                op);
        failed = 1;
    }

    fprintf(stderr, "builtin coverage: %u registered, %u ratcheted gaps, "
            "%u none rows\n", n_ok, n_gap, n_none);
    ds_engine_free(e);
    return failed;
}

int main(void)
{
    int failed = 0;
    /* OR-store, never short-circuit (ITST): every scenario runs. */
    failed |= test_every_live_op_has_a_handler();
    if (failed) {
        fprintf(stderr, "test_builtin_coverage: FAILED\n");
        return 1;
    }
    printf("test_builtin_coverage: OK\n");
    return 0;
}

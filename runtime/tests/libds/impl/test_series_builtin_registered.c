/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * An engine from `ds_engine_new` arrives with the closed series-backend set
 * registered, and so does one from `ds_engine_clone`. Only `libds.h` is
 * included: an integrator has no registration call to make ([NSBK.2.3]).
 *
 * The set is read from the platform signature, which lists
 * `<atom>:<name>:<version>` per registered slot ([LDET.2.3]), `<atom>` being
 * the backing atom's body message ([NDET.2.2]).
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* The seven backings [NSBK.6.1] fixes, by the body message the signature
   names each with ([NDET.2.2], [RDSC.7.1]). */
static const char *const k_atoms[] = {
    "SeriesBackendWelfordEwma", "SeriesBackendRingBuffer",
    "SeriesBackendMonotonicDeque", "SeriesBackendFifoDeque",
    "SeriesBackendReservoir", "SeriesBackendIntervalPulse",
    "SeriesBackendNumericIntegral",
};
#define N_ATOMS (sizeof(k_atoms) / sizeof(k_atoms[0]))

/* Every one of the seven listed exactly once, and nothing else. The whole
   first field is compared, up to its `:`, so `SeriesBackendRingBuffer` is not
   found inside a longer name, nor a four-letter magic taken for one. */
static int check_closed_set(ds_engine_t *e, const char *who)
{
    ds_platform_signature_t sig;
    if (ds_engine_get_platform_signature(e, &sig).status != DS_OK)
        return fail("platform signature");
    if (sig.n_backends != N_ATOMS) {
        fprintf(stderr, "FAIL: %s lists %zu series backends, expected %zu "
                "(the engine registers the closed set itself)\n",
                who, sig.n_backends, (size_t)N_ATOMS);
        return 1;
    }
    for (size_t m = 0; m < N_ATOMS; m++) {
        size_t len = strlen(k_atoms[m]);
        size_t seen = 0;
        for (size_t i = 0; i < sig.n_backends; i++) {
            if (sig.backends[i] != NULL
                && strncmp(sig.backends[i], k_atoms[m], len) == 0
                && sig.backends[i][len] == ':')
                seen++;
        }
        if (seen != 1) {
            fprintf(stderr, "FAIL: %s lists %s %zu time(s), expected once\n",
                    who, k_atoms[m], seen);
            return 1;
        }
    }
    return 0;
}

/* NDET.2.2's own example, whole: the ring buffer's entry. */
/* @spec [NDET.2.2] */
static int test_ring_buffer_entry_is_the_clause_example(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    ds_platform_signature_t sig;
    int fails = 0;
    if (ds_engine_get_platform_signature(e, &sig).status != DS_OK) {
        fails = fail("platform signature");
    } else {
        size_t seen = 0;
        for (size_t i = 0; i < sig.n_backends; i++)
            if (sig.backends[i] != NULL
                && strcmp(sig.backends[i],
                          "SeriesBackendRingBuffer:ds-ring-buffer:1.0.0") == 0)
                seen++;
        if (seen != 1)
            fails = fail("no `SeriesBackendRingBuffer:ds-ring-buffer:1.0.0` "
                         "entry (NDET.2.2)");
    }
    (void)ds_engine_free(e);
    return fails;
}

/* [NDET.2.5]'s table, whole and in slot order, written out from the clause
   rather than read from builtin_backends.c, which it checks. */
static const char *const k_ndet_2_5_entries[] = {
    "SeriesBackendWelfordEwma:ds-welford-ewma:0.1.0",
    "SeriesBackendMonotonicDeque:ds-monotonic-deque:0.1.0",
    "SeriesBackendFifoDeque:ds-fifo-deque:0.1.0",
    "SeriesBackendReservoir:ds-reservoir:0.1.0",
    "SeriesBackendIntervalPulse:ds-interval-pulse:0.1.0",
    "SeriesBackendNumericIntegral:ds-numeric-integral:0.1.0",
    "SeriesBackendRingBuffer:ds-ring-buffer:1.0.0",
};
#define N_NDET_2_5 (sizeof(k_ndet_2_5_entries) / sizeof(k_ndet_2_5_entries[0]))

/* @spec [NDET.2.5] */
static int test_ndet_2_5__backends_are_the_clause_table(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    ds_platform_signature_t sig;
    int fails = 0;
    if (ds_engine_get_platform_signature(e, &sig).status != DS_OK) {
        fails = fail("platform signature");
    } else if (sig.n_backends != N_NDET_2_5) {
        fprintf(stderr, "FAIL: %zu backends, NDET.2.5 lists %zu\n",
                sig.n_backends, (size_t)N_NDET_2_5);
        fails = 1;
    } else {
        for (size_t i = 0; i < N_NDET_2_5; i++) {
            if (sig.backends[i] == NULL
                || strcmp(sig.backends[i], k_ndet_2_5_entries[i]) != 0) {
                fprintf(stderr, "FAIL: slot %zu is `%s`, NDET.2.5 says `%s`\n",
                        i, sig.backends[i] ? sig.backends[i] : "(null)",
                        k_ndet_2_5_entries[i]);
                fails = 1;
            }
        }
    }
    (void)ds_engine_free(e);
    return fails;
}

/* @spec [NDET.2.2] */
static int test_new_engine_has_the_closed_set(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    int fails = check_closed_set(e, "ds_engine_new");
    (void)ds_engine_free(e);
    return fails;
}

static int test_clone_has_the_closed_set(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    ds_engine_t *c = NULL;
    if (ds_engine_clone(e, &c).status != DS_OK) {
        (void)ds_engine_free(e);
        return fail("engine_clone");
    }
    /* A clone replaces the table its own ds_engine_new registered with the
       source's; it must neither double it nor lose it. */
    int fails = check_closed_set(c, "ds_engine_clone");
    (void)ds_engine_free(c);
    (void)ds_engine_free(e);
    return fails;
}

/* The `backends` strings are engine-lifetime, as libds.h says: a signature
   read earlier stays valid after another read, the same array and the same
   strings. The memcheck lane sees a read of freed strings. */
static int test_signature_backends_are_engine_lifetime(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    ds_platform_signature_t first, second;
    int fails = 0;
    if (ds_engine_get_platform_signature(e, &first).status != DS_OK
        || ds_engine_get_platform_signature(e, &second).status != DS_OK) {
        fails = fail("platform signature");
    } else {
        if (first.backends != second.backends
            || first.n_backends != second.n_backends)
            fails = fail("a second read replaced the first read's backends");
        for (size_t i = 0; fails == 0 && i < first.n_backends; i++) {
            if (first.backends[i] != second.backends[i]
                || strcmp(first.backends[i], second.backends[i]) != 0)
                fails = fail("a first read's backend string did not survive");
        }
    }
    (void)ds_engine_free(e);
    return fails;
}

int main(void)
{
    int fails = 0;
    fails += test_new_engine_has_the_closed_set();
    fails += test_clone_has_the_closed_set();
    fails += test_signature_backends_are_engine_lifetime();
    fails += test_ring_buffer_entry_is_the_clause_example();
    fails += test_ndet_2_5__backends_are_the_clause_table();
    if (fails == 0)
        printf("OK  test_series_builtin_registered (%d tests)\n", 5);
    else
        fprintf(stderr, "FAILED: %d test(s) failed\n", fails);
    return fails ? 1 : 0;
}

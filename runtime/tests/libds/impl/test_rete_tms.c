/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The TMS dependency table (IRET.12): a withdrawal leaves no hole mid probe
 * chain, so an entry that collided past a withdrawn one stays reachable and
 * its logical facts are withdrawn. Table-level and deterministic: no engine,
 * no timing.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "ds_alloc.h"
#include "rete/tms.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* Withdraw one timetag and assert it yields exactly the expected single id. */
static int withdraw_expect1(ds_tms_table_t *tms, int64_t tt, uint32_t want)
{
    uint32_t *ids = NULL, n = 0;
    bool must_free = false;
    ds_result_t r = ds_tms_withdraw(tms, tt, &ids, &n, &must_free);
    if (r.status != DS_OK) return fail("withdraw returned error");
    int bad = 0;
    if (n != 1) {
        fprintf(stderr, "  tt=%lld got n=%u want 1\n", (long long)tt, n);
        bad = 1;
    } else if (ids[0] != want) {
        fprintf(stderr, "  tt=%lld got id=%u want %u\n", (long long)tt, ids[0], want);
        bad = 1;
    }
    if (must_free) DS_FREE(ids);
    return bad;
}

/* Many entries (forcing hash collisions and grows), each supporting one fact,
 * withdrawn in insertion order: every withdrawal returns its own id. */
static int test_withdraw_forward_order(void)
{
    enum { K = 200 };
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);

    for (int i = 1; i <= K; i++) {
        ds_result_t r = ds_tms_add(&tms, (int64_t)i, "r", (uint32_t)(i + 1000));
        if (r.status != DS_OK) { ds_tms_table_destroy(&tms); return fail("add"); }
    }
    if (oa_len(&tms.map) != K) { ds_tms_table_destroy(&tms); return fail("count after adds"); }

    for (int i = 1; i <= K; i++) {
        if (withdraw_expect1(&tms, (int64_t)i, (uint32_t)(i + 1000))) {
            ds_tms_table_destroy(&tms);
            return fail("forward-order withdrawal lost an entry");
        }
    }
    if (oa_len(&tms.map) != 0) { ds_tms_table_destroy(&tms); return fail("count not 0 after withdraws"); }
    ds_tms_table_destroy(&tms);
    return 0;
}

/* Same population, withdrawn in reverse — exercises the other shift direction. */
static int test_withdraw_reverse_order(void)
{
    enum { K = 200 };
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);
    for (int i = 1; i <= K; i++)
        if (ds_tms_add(&tms, (int64_t)i, "r", (uint32_t)(i + 1000)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("add"); }
    for (int i = K; i >= 1; i--)
        if (withdraw_expect1(&tms, (int64_t)i, (uint32_t)(i + 1000))) {
            ds_tms_table_destroy(&tms); return fail("reverse-order withdrawal lost an entry"); }
    if (oa_len(&tms.map) != 0) { ds_tms_table_destroy(&tms); return fail("count not 0"); }
    ds_tms_table_destroy(&tms);
    return 0;
}

/* Interleaved add/withdraw churn: withdraw half, add more (reusing freed
 * slots), then withdraw everything — no entry may be lost across the holes. */
static int test_interleaved_churn(void)
{
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);
    int64_t tt = 1;

    for (int i = 0; i < 100; i++, tt++)
        if (ds_tms_add(&tms, tt, "r", (uint32_t)(tt + 1000)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("add phase1"); }
    /* Withdraw the first 60 in order — leaves holes mid-table. */
    for (int64_t k = 1; k <= 60; k++)
        if (withdraw_expect1(&tms, k, (uint32_t)(k + 1000))) {
            ds_tms_table_destroy(&tms); return fail("withdraw phase1"); }
    /* Add 100 more on top of the churned table. */
    for (int i = 0; i < 100; i++, tt++)
        if (ds_tms_add(&tms, tt, "r", (uint32_t)(tt + 1000)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("add phase2"); }
    /* Withdraw all remaining: 61..(tt-1). */
    for (int64_t k = 61; k < tt; k++)
        if (withdraw_expect1(&tms, k, (uint32_t)(k + 1000))) {
            ds_tms_table_destroy(&tms); return fail("withdraw remaining (lost across holes)"); }
    if (oa_len(&tms.map) != 0) { ds_tms_table_destroy(&tms); return fail("count not 0"); }
    ds_tms_table_destroy(&tms);
    return 0;
}

/* A single activation supporting many facts (heap spill past DS_TMS_INLINE)
 * must round-trip every id, and its slot must not corrupt neighbours. */
static int test_multi_id_entry(void)
{
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);
    enum { M = 40 }; /* > DS_TMS_INLINE (16): forces heap spill */
    for (int i = 0; i < M; i++)
        if (ds_tms_add(&tms, 7, "r", (uint32_t)(500 + i)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("multi add"); }
    /* A couple of neighbours that may collide with timetag 7. */
    if (ds_tms_add(&tms, 8, "r", 999).status != DS_OK) { ds_tms_table_destroy(&tms); return fail("nbr add"); }

    uint32_t *ids = NULL, n = 0; bool mf = false;
    if (ds_tms_withdraw(&tms, 7, &ids, &n, &mf).status != DS_OK) {
        ds_tms_table_destroy(&tms);
        return fail("multi withdraw");
    }
    if (n != M) {
        fprintf(stderr, "  multi got n=%u want %u\n", n, M);
        if (mf) DS_FREE(ids);
        ds_tms_table_destroy(&tms);
        return fail("multi count");
    }
    /* Check before the neighbour's withdrawal reuses the scratch. */
    int ok = 1;
    for (int i = 0; i < M; i++) {
        int found = 0;
        for (int j = 0; j < M; j++) if (ids[j] == (uint32_t)(500 + i)) { found = 1; break; }
        if (!found) ok = 0;
    }
    if (mf) DS_FREE(ids);
    if (!ok) { ds_tms_table_destroy(&tms); return fail("multi id set incomplete"); }
    /* neighbour still reachable after the multi-id slot was vacated */
    if (withdraw_expect1(&tms, 8, 999)) { ds_tms_table_destroy(&tms); return fail("neighbour lost"); }
    ds_tms_table_destroy(&tms);
    return 0;
}

/* [IRET.12.2]: an activation's withdrawal can run nested inside another's --
 * a retraction the outer walk makes ends a second activation synchronously --
 * so the ids a withdrawal hands out above DS_TMS_INLINE must be the caller's
 * own. A nested withdrawal, of a few ids and of more than the scratch holds,
 * must leave the outer array exactly as it was. Before the fix the outer
 * withdrawal of 20 ids was the scratch itself: the nested withdrawal of 3
 * wrote its ids over the first three (and one of 30 reallocated it, which
 * ASan reports as a use after free). */
static int test_nested_withdraw_keeps_owned_ids(void)
{
    ds_tms_table_t tms;
    ds_tms_table_init(&tms);
    enum { OUTER = 20, FEW = 3, MANY = 30 };   /* OUTER > DS_TMS_INLINE (16) */
    for (int i = 0; i < OUTER; i++)
        if (ds_tms_add(&tms, 7, "outer", (uint32_t)(500 + i)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("outer add"); }
    for (int i = 0; i < FEW; i++)
        if (ds_tms_add(&tms, 8, "few", (uint32_t)(900 + i)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("few add"); }
    for (int i = 0; i < MANY; i++)
        if (ds_tms_add(&tms, 9, "many", (uint32_t)(2000 + i)).status != DS_OK) {
            ds_tms_table_destroy(&tms); return fail("many add"); }

    uint32_t *outer = NULL, n_outer = 0; bool outer_free = false;
    if (ds_tms_withdraw(&tms, 7, &outer, &n_outer, &outer_free).status != DS_OK
            || n_outer != OUTER) {
        if (outer_free) DS_FREE(outer);
        ds_tms_table_destroy(&tms);
        return fail("outer withdraw");
    }
    int bad = 0;
    if (!outer_free || outer == tms.withdraw_scratch) {
        fprintf(stderr, "  a withdrawal of %u ids handed out the shared scratch\n",
                n_outer);
        bad = 1;
    }

    /* The two nested withdrawals, as a cascade inside the outer walk makes
       them. Each borrowed result is used and dropped, as the terminal does. */
    uint32_t *few = NULL, n_few = 0; bool few_free = false;
    if (ds_tms_withdraw(&tms, 8, &few, &n_few, &few_free).status != DS_OK
            || n_few != FEW)
        bad = 1;
    if (few_free) DS_FREE(few);
    uint32_t *many = NULL, n_many = 0; bool many_free = false;
    if (ds_tms_withdraw(&tms, 9, &many, &n_many, &many_free).status != DS_OK
            || n_many != MANY)
        bad = 1;
    if (many_free) DS_FREE(many);

    for (int i = 0; i < OUTER && !bad; i++)
        if (outer[i] != (uint32_t)(500 + i)) {
            fprintf(stderr, "  outer id %d is %u after the nested withdrawals, "
                            "want %u\n", i, outer[i], (uint32_t)(500 + i));
            bad = 1;
        }
    if (outer_free) DS_FREE(outer);
    ds_tms_table_destroy(&tms);
    return bad ? fail("a nested withdrawal changed the outer withdrawal's ids")
               : 0;
}

int main(void)
{
    int fails = 0;
    printf("=== test_rete_tms ===\n");
#define RUN(t) do { \
    if ((t)()) { fprintf(stderr, "  FAIL: " #t "\n"); fails++; } \
    else       { printf("  pass: " #t "\n"); } \
} while (0)
    RUN(test_withdraw_forward_order);
    RUN(test_withdraw_reverse_order);
    RUN(test_interleaved_churn);
    RUN(test_multi_id_entry);
    RUN(test_nested_withdraw_keeps_owned_ids);
#undef RUN
    if (fails) { printf("=== test_rete_tms: %d FAILED ===\n", fails); return 1; }
    printf("=== test_rete_tms: ALL PASSED ===\n");
    return 0;
}

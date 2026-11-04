/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Refcounted fact-slot String and Bytes values in the intern table
 * (IRET.1.4):
 *   - N distinct strings asserted and retracted return the counted-entry
 *     count to its baseline;
 *   - K identical reassertions keep refcount 1, so one retract frees the
 *     value;
 *   - a supersede frees the old value, and an unchanged value it shares
 *     keeps one entry and never drops to 0 (acquire before retract);
 *   - a value held by two live facts is one entry, freed with the last
 *     holder;
 *   - an oversized (> slab) string frees on release;
 *   - a computed string stays in the fire arena, out of the table, until
 *     it is emitted into a slot;
 *   - value churn leaves the pinned count flat, and the freelist recycles
 *     counted blocks with no new allocation.
 *
 * Every test skips RT mode; test_rete_wm covers assert and retract under RT.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/intern.h"
static int g_mode = 0;
#include "test_dual_mode.h"

#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* Live interned-entry count (pinned + counted). */
static size_t icount(ds_rete_engine_t *e)
{
    size_t n = 0;
    ds_rete_intern_mem(e->intern, &n, NULL, NULL);
    return n;
}

/* Intern a fact-slot value (counted, born at refcount 0). */
static const char *vstr(ds_rete_engine_t *e, const char *s, size_t len)
{
    const char *p = NULL;
    ds_rete_intern_value(e->intern, s, len, &p);
    return p;
}

/* Schema "Reading": Int "id" (identity key), Str "label" (value). */
static ds_rete_engine_t *make_engine2(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "id",    .type = DS_RETE_VAL_INT, .is_key = true  },
        { .name = "label", .type = DS_RETE_VAL_STR, .is_key = false },
    };
    ds_rete_schema_t *s = NULL;
    ds_rete_schema_register(e, "Reading", DS_RETE_SCOPE_PLAIN, 0, slots, 2, &s);
    apply_rt(e, 0);
    return e;
}

/* Schema "Tagged": Int "id" (key), Str "label" (value), Int "tag" (value). */
static ds_rete_engine_t *make_engine3(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name = "id",    .type = DS_RETE_VAL_INT, .is_key = true  },
        { .name = "label", .type = DS_RETE_VAL_STR, .is_key = false },
        { .name = "tag",   .type = DS_RETE_VAL_INT, .is_key = false },
    };
    ds_rete_schema_t *s = NULL;
    ds_rete_schema_register(e, "Tagged", DS_RETE_SCOPE_PLAIN, 0, slots, 3, &s);
    apply_rt(e, 0);
    return e;
}

#define RECLAIM_N 10

static int test_reclamation(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    ds_rete_fact_t *facts[RECLAIM_N];
    for (int i = 0; i < RECLAIM_N; i++) {
        char buf[32];
        int  n = snprintf(buf, sizeof(buf), "label_%d", i);
        ds_rete_val_t s[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(vstr(e, buf, (size_t)n), (uint32_t)n),
        };
        facts[i] = NULL;
        if (ds_rete_wm_assert(e, 0, s, &facts[i]).status != DS_OK)
            return fail("reclamation: assert");
    }
    if (icount(e) != base + RECLAIM_N)
        return fail("reclamation: expected N counted entries after assert");

    for (int i = 0; i < RECLAIM_N; i++)
        if (ds_rete_wm_retract(e, facts[i]).status != DS_OK)
            return fail("reclamation: retract");

    if (icount(e) != base)
        return fail("reclamation: counted entries not reclaimed to baseline");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_noop_non_leak(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    ds_rete_val_t s0[] = {
        ds_rete_val_int(1),
        ds_rete_val_str(vstr(e, "keep", 4), 4),
    };
    ds_rete_fact_t *f = NULL;
    if (ds_rete_wm_assert(e, 0, s0, &f).status != DS_OK)
        return fail("noop: initial assert");
    if (icount(e) != base + 1)
        return fail("noop: value not interned once");

    for (int k = 0; k < 5; k++) {
        ds_rete_val_t s[] = {
            ds_rete_val_int(1),
            ds_rete_val_str(vstr(e, "keep", 4), 4),
        };
        ds_rete_fact_t *f2 = NULL;
        if (ds_rete_wm_assert(e, 0, s, &f2).status != DS_OK)
            return fail("noop: reassert");
        if (f2 != f) return fail("noop: reassert should return same fact");
    }
    if (icount(e) != base + 1)
        return fail("noop: reassertion grew the intern table");

    /* One retract must free the value: refcount is 1, not 6. */
    if (ds_rete_wm_retract(e, f).status != DS_OK)
        return fail("noop: retract");
    if (icount(e) != base)
        return fail("noop: single retract did not free (refcount inflated by no-ops)");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_supersede_balance(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    ds_rete_val_t sa[] = { ds_rete_val_int(1), ds_rete_val_str(vstr(e, "a", 1), 1) };
    ds_rete_fact_t *f = NULL;
    if (ds_rete_wm_assert(e, 0, sa, &f).status != DS_OK) return fail("supersede: assert a");
    if (icount(e) != base + 1) return fail("supersede: a not counted");

    ds_rete_val_t sb[] = { ds_rete_val_int(1), ds_rete_val_str(vstr(e, "b", 1), 1) };
    if (ds_rete_wm_assert(e, 0, sb, &f).status != DS_OK) return fail("supersede: assert b");
    /* "a" freed on retract-old, "b" counted → still exactly one value entry. */
    if (icount(e) != base + 1) return fail("supersede: old value not freed");

    ds_rete_val_t sc[] = { ds_rete_val_int(1), ds_rete_val_str(vstr(e, "c", 1), 1) };
    if (ds_rete_wm_assert(e, 0, sc, &f).status != DS_OK) return fail("supersede: assert c");
    if (icount(e) != base + 1) return fail("supersede: value count drifted");

    if (ds_rete_wm_retract(e, f).status != DS_OK) return fail("supersede: retract");
    if (icount(e) != base) return fail("supersede: final value not reclaimed");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_supersede_unchanged_value(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine3();
    size_t base = icount(e);

    ds_rete_val_t s1[] = {
        ds_rete_val_int(1), ds_rete_val_str(vstr(e, "x", 1), 1), ds_rete_val_int(10),
    };
    ds_rete_fact_t *f = NULL;
    if (ds_rete_wm_assert(e, 0, s1, &f).status != DS_OK) return fail("unchanged: assert");
    if (icount(e) != base + 1) return fail("unchanged: x not counted");

    /* tag changes, label unchanged → meaningful change (supersede), but the
       shared "x" must never drop to 0 and free (acquire-before-retract). */
    ds_rete_val_t s2[] = {
        ds_rete_val_int(1), ds_rete_val_str(vstr(e, "x", 1), 1), ds_rete_val_int(20),
    };
    if (ds_rete_wm_assert(e, 0, s2, &f).status != DS_OK) return fail("unchanged: supersede");
    if (icount(e) != base + 1)
        return fail("unchanged: shared value should keep exactly one entry");

    if (ds_rete_wm_retract(e, f).status != DS_OK) return fail("unchanged: retract");
    if (icount(e) != base) return fail("unchanged: value not reclaimed");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_shared_value_refcount(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    ds_rete_val_t s1[] = { ds_rete_val_int(1), ds_rete_val_str(vstr(e, "shared", 6), 6) };
    ds_rete_fact_t *f1 = NULL;
    if (ds_rete_wm_assert(e, 0, s1, &f1).status != DS_OK) return fail("shared: assert 1");

    ds_rete_val_t s2[] = { ds_rete_val_int(2), ds_rete_val_str(vstr(e, "shared", 6), 6) };
    ds_rete_fact_t *f2 = NULL;
    if (ds_rete_wm_assert(e, 0, s2, &f2).status != DS_OK) return fail("shared: assert 2");

    /* Two facts, one interned value. */
    if (icount(e) != base + 1) return fail("shared: value should be a single entry");

    if (ds_rete_wm_retract(e, f1).status != DS_OK) return fail("shared: retract 1");
    if (icount(e) != base + 1)
        return fail("shared: value freed while a holder is still live (refcount>1 broken)");

    if (ds_rete_wm_retract(e, f2).status != DS_OK) return fail("shared: retract 2");
    if (icount(e) != base) return fail("shared: value not freed after last holder");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_oversized_reclaim(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    size_t big_len = 5000;                 /* > SLAB_CAPACITY (4096) */
    char  *big = malloc(big_len + 1);
    if (!big) return fail("oversized: malloc");
    memset(big, 'a', big_len);
    big[big_len] = '\0';

    ds_rete_val_t s[] = {
        ds_rete_val_int(1),
        ds_rete_val_str(vstr(e, big, big_len), (uint32_t)big_len),
    };
    ds_rete_fact_t *f = NULL;
    if (ds_rete_wm_assert(e, 0, s, &f).status != DS_OK) { free(big); return fail("oversized: assert"); }
    if (icount(e) != base + 1) { free(big); return fail("oversized: not counted"); }

    if (ds_rete_wm_retract(e, f).status != DS_OK) { free(big); return fail("oversized: retract"); }
    if (icount(e) != base) { free(big); return fail("oversized: not reclaimed on release"); }

    free(big);
    ds_rete_engine_destroy(e);
    return 0;
}

/* A computed string the engine does not store in a fact slot lives in the
   fire-scoped arena and never touches the intern table. */
static int test_arena_transient_no_intern_growth(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    for (int i = 0; i < 100; i++) {
        char buf[32];
        int  n = snprintf(buf, sizeof buf, "computed_%d", i);
        const char *p = ds_rete_arena_dup(&e->comp_arena, buf, (size_t)n);
        if (p == NULL) return fail("arena: dup");
        if (memcmp(p, buf, (size_t)n) != 0 || p[n] != '\0')
            return fail("arena: content / NUL terminator");
    }
    if (icount(e) != base)
        return fail("arena: transient computed strings grew the intern table");

    ds_rete_arena_reset(&e->comp_arena);
    if (icount(e) != base)
        return fail("arena: reset perturbed the intern table");

    ds_rete_engine_destroy(e);
    return 0;
}

/* A computed (arena) string emitted into a fact slot is interned counted at
   the emit's commit and reclaims on retract, like any counted value. */
static int test_emit_of_computed_reclaim(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base = icount(e);

    const char *a = ds_rete_arena_dup(&e->comp_arena, "n=3", 3);
    if (a == NULL) return fail("emit-computed: arena dup");
    if (icount(e) != base) return fail("emit-computed: arena string was interned");

    /* RHS emit interns the slot value counted (find-or-insert by bytes). */
    const char *ip = NULL;
    if (ds_rete_intern_value(e->intern, a, 3, &ip).status != DS_OK)
        return fail("emit-computed: intern_value");
    if (icount(e) != base + 1) return fail("emit-computed: not counted");

    ds_rete_intern_acquire_ptr(e->intern, ip, 3);   /* commit */
    ds_rete_intern_release(e->intern, ip, 3);        /* retract */
    if (icount(e) != base)
        return fail("emit-computed: not reclaimed on release");

    ds_rete_engine_destroy(e);
    return 0;
}

/* [IRET.1.4c]'s boundedness signal: churning distinct String values through
   slots leaves the pinned count flat; a value mis-routed to pinned would
   grow it. */
static int test_pinned_watermark_flat_under_value_churn(void)
{
    SKIP_IF_RT;
    ds_rete_engine_t *e = make_engine2();
    size_t base_pinned = ds_rete_intern_pinned_count(e->intern);
    size_t base_total  = icount(e);

    for (int i = 0; i < 200; i++) {
        char buf[32];
        int  n = snprintf(buf, sizeof buf, "churn_%d", i);
        ds_rete_val_t s[] = {
            ds_rete_val_int(i),
            ds_rete_val_str(vstr(e, buf, (size_t)n), (uint32_t)n),
        };
        ds_rete_fact_t *f = NULL;
        if (ds_rete_wm_assert(e, 0, s, &f).status != DS_OK)
            return fail("churn: assert");
        if (ds_rete_wm_retract(e, f).status != DS_OK)
            return fail("churn: retract");
    }

    if (ds_rete_intern_pinned_count(e->intern) != base_pinned)
        return fail("churn: pinned watermark grew (a value was mis-routed to pinned)");
    if (icount(e) != base_total)
        return fail("churn: counted values not reclaimed to baseline");

    ds_rete_engine_destroy(e);
    return 0;
}

/* The counted-string freelist: after a warmup of one size class, assert and
   retract churn reuses freed blocks and makes no further counted DS_MALLOC. */
static int test_freelist_recycles_steady_state(void)
{
    SKIP_IF_RT;   /* recycling is mode-independent; suite is non-RT scoped */
    ds_rete_engine_t *e = make_engine2();

    /* Warm up one size class. */
    {
        ds_rete_val_t s[] = {
            ds_rete_val_int(1), ds_rete_val_str(vstr(e, "recy", 4), 4),
        };
        ds_rete_fact_t *f = NULL;
        if (ds_rete_wm_assert(e, 0, s, &f).status != DS_OK) return fail("recy: warmup assert");
        if (ds_rete_wm_retract(e, f).status != DS_OK) return fail("recy: warmup retract");
    }
    size_t after_warmup = ds_rete_intern_counted_mallocs(e->intern);

    /* Steady state: 500 distinct same-class values, each retract feeding the
       next assert through the freelist — zero new counted mallocs. */
    for (int i = 0; i < 500; i++) {
        char buf[8];
        int  n = snprintf(buf, sizeof buf, "r%03d", i);   /* 4 chars, same class */
        ds_rete_val_t s[] = {
            ds_rete_val_int(2), ds_rete_val_str(vstr(e, buf, (size_t)n), (uint32_t)n),
        };
        ds_rete_fact_t *f = NULL;
        if (ds_rete_wm_assert(e, 0, s, &f).status != DS_OK) return fail("recy: assert");
        if (ds_rete_wm_retract(e, f).status != DS_OK) return fail("recy: retract");
    }

    if (ds_rete_intern_counted_mallocs(e->intern) != after_warmup)
        return fail("recy: steady-state churn allocated (freelist not recycling)");

    ds_rete_engine_destroy(e);
    return 0;
}

int main(void)
{
    int total_fails = 0;
    const char *tags[] = {"non-RT", "RT"};

    for (int mode = 0; mode <= 1; mode++) {
        g_mode = mode;
        const char *tag = tags[mode];
        int fails = 0;
        printf("\n=== test_rete_intern_seal [%s] ===\n", tag);

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL [%s]: " #t "\n", tag); fails++; } \
    else    { printf("  pass [%s]: " #t "\n", tag); } \
} while (0)

        RUN(test_reclamation);
        RUN(test_noop_non_leak);
        RUN(test_supersede_balance);
        RUN(test_supersede_unchanged_value);
        RUN(test_shared_value_refcount);
        RUN(test_oversized_reclaim);
        RUN(test_arena_transient_no_intern_growth);
        RUN(test_emit_of_computed_reclaim);
        RUN(test_pinned_watermark_flat_under_value_churn);
        RUN(test_freelist_recycles_steady_state);

#undef RUN

        if (fails == 0)
            printf("=== test_rete_intern_seal [%s]: ALL PASSED ===\n", tag);
        else
            fprintf(stderr, "=== test_rete_intern_seal [%s]: %d FAILED ===\n", tag, fails);
        total_fails += fails;
    }
    return total_fails ? 1 : 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A seeded fuzz of the rete/intern.c primitives against a model: after every
 * operation the live and pinned counts match the model, and draining every
 * counted entry leaves only the pinned ones. The pool's strings span every
 * size class and the oversized path.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/intern.h"

static int fail(const char *m) { fprintf(stderr, "FAIL: %s\n", m); return 1; }

static size_t icount(const ds_rete_intern_t *t)
{ size_t n = 0; ds_rete_intern_mem(t, &n, NULL, NULL); return n; }

static uint64_t g_rng;
static void rng_seed(uint64_t s) { g_rng = s ? s : 1; }
static uint32_t rng_next(void)
{ g_rng = g_rng * 6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(g_rng >> 33); }

enum { POOL = 48, ABSENT = 0, COUNTED = 1, PINNED = 2 };

static const size_t g_lens[] = {
    1, 2, 7, 8, 9, 15, 16, 31, 63, 100, 255, 500, 1000, 4095, 4096, 4097, 8192,
};
#define NLENS (sizeof(g_lens) / sizeof(g_lens[0]))

typedef struct {
    char        *buf;      /* owned by the test (the content bytes) */
    size_t       len;
    int          state;    /* ABSENT / COUNTED / PINNED */
    uint32_t     refc;     /* meaningful when COUNTED */
    const char  *interned; /* the interned pointer when present */
} pool_slot_t;

static pool_slot_t g_pool[POOL];

static int pool_init(void)
{
    for (int i = 0; i < POOL; i++) {
        size_t L = g_lens[i % NLENS];
        char *b = malloc(L + 1);
        if (!b) return -1;
        for (size_t k = 0; k < L; k++)
            b[k] = (char)(33 + ((i * 131 + (int)k * 7) % 94));
        b[0] = (char)(33 + i);            /* distinct per slot while POOL <= 94 */
        b[L] = '\0';
        g_pool[i].buf = b; g_pool[i].len = L; g_pool[i].state = ABSENT;
        g_pool[i].refc = 0; g_pool[i].interned = NULL;
    }
    return 0;
}
static void pool_free_bufs(void) { for (int i = 0; i < POOL; i++) free(g_pool[i].buf); }

static size_t model_count(void)
{ size_t n = 0; for (int i = 0; i < POOL; i++) if (g_pool[i].state != ABSENT) n++; return n; }
static size_t model_pinned(void)
{ size_t n = 0; for (int i = 0; i < POOL; i++) if (g_pool[i].state == PINNED) n++; return n; }

static int check(ds_rete_intern_t *t)
{
    if (icount(t) != model_count()) return fail("balance: entry count diverged from model");
    if (ds_rete_intern_pinned_count(t) != model_pinned()) return fail("balance: pinned count diverged");
    return 0;
}

static int fuzz_seed(uint64_t seed, int ops)
{
    rng_seed(seed);
    for (int i = 0; i < POOL; i++) { g_pool[i].state = ABSENT; g_pool[i].refc = 0; g_pool[i].interned = NULL; }

    ds_rete_intern_t *t = NULL;
    if (ds_rete_intern_init(&t).status != DS_OK) return fail("init");

    for (int step = 0; step < ops; step++) {
        pool_slot_t *s = &g_pool[rng_next() % POOL];
        uint32_t choice = rng_next() % 100;

        if (s->state == ABSENT) {
            if (choice < 70) {                         /* value → counted@0 */
                const char *v = NULL;
                if (ds_rete_intern_value(t, s->buf, s->len, &v).status != DS_OK) continue; /* OOM: skip */
                s->state = COUNTED; s->refc = 0; s->interned = v;
            } else {                                    /* pin */
                const char *p = NULL;
                if (ds_rete_intern(t, s->buf, s->len, &p).status != DS_OK) continue;
                s->state = PINNED; s->interned = p;
            }
        } else if (s->state == COUNTED) {
            if (choice < 25) {                          /* value again → shares, no change */
                const char *v = NULL; ds_rete_intern_value(t, s->buf, s->len, &v);
                if (v != s->interned) return fail("value on a present entry must return the same pointer");
            } else if (choice < 60) {                   /* acquire */
                ds_rete_intern_acquire_ptr(t, s->interned, s->len); s->refc++;
            } else if (choice < 90) {                   /* release (only valid at refc>=1) */
                if (s->refc >= 1) {
                    ds_rete_intern_release(t, s->interned, s->len);
                    if (--s->refc == 0) { s->state = ABSENT; s->interned = NULL; }
                }
            } else {                                    /* pin → promote */
                const char *p = NULL; ds_rete_intern(t, s->buf, s->len, &p);
                if (p != s->interned) return fail("promote must keep the pointer");
                s->state = PINNED;
            }
        } else { /* PINNED — value/pin/acquire/release all no-ops on the entry */
            if (choice < 50) {
                const char *v = NULL; ds_rete_intern_value(t, s->buf, s->len, &v);
                if (v != s->interned) return fail("value on a pinned entry must share its pointer");
            } else if (choice < 75) {
                ds_rete_intern_acquire_ptr(t, s->interned, s->len);   /* no-op */
            } else {
                ds_rete_intern_release(t, s->interned, s->len);       /* no-op */
            }
        }

        if (check(t)) return 1;
    }

    /* A counted entry never acquired is removed by an acquire and a release. */
    for (int i = 0; i < POOL; i++) {
        pool_slot_t *s = &g_pool[i];
        if (s->state != COUNTED) continue;
        if (s->refc == 0) { ds_rete_intern_acquire_ptr(t, s->interned, s->len); s->refc = 1; }
        while (s->refc > 0) { ds_rete_intern_release(t, s->interned, s->len); s->refc--; }
        s->state = ABSENT; s->interned = NULL;
    }
    if (icount(t) != model_pinned()) return fail("teardown: counted entries not fully reclaimed");

    ds_rete_intern_destroy(t);
    return 0;
}

int main(void)
{
    int fails = 0;
    printf("=== test_intern_fuzz ===\n");
    if (pool_init() != 0) { fprintf(stderr, "pool_init OOM\n"); return 1; }

    static const uint64_t seeds[] = { 1, 2, 3, 7, 42, 1337, 0xC0FFEE, 0xDEADBEEF };
    for (size_t i = 0; i < sizeof(seeds) / sizeof(seeds[0]); i++) {
        int r = fuzz_seed(seeds[i], 4000);
        if (r) { fprintf(stderr, "  FAIL: seed 0x%llx\n", (unsigned long long)seeds[i]); fails++; }
        else   { printf("  pass: seed 0x%llx (4000 ops)\n", (unsigned long long)seeds[i]); }
    }

    pool_free_bufs();
    if (fails == 0) { printf("=== test_intern_fuzz: ALL PASSED ===\n"); return 0; }
    fprintf(stderr, "=== test_intern_fuzz: %d seed(s) FAILED ===\n", fails);
    return 1;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The open-addressing map ([IRET.28]), as [IRET.28.16] asks: each op's
 * contract; a model test against a reference, including collision storms (a
 * deliberately bad hash) and grow-boundary crossings; named regressions; and
 * seeded fuzz of the oa_list multimap and the count adapter.
 *
 * ds_oa_check (RI-1..RI-7) is compiled in debug builds (NDEBUG unset) and
 * called after every mutating op; a violation aborts the process.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "oa.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

#ifndef NDEBUG
#  define OA_CK(t) ds_oa_check(t)
#else
#  define OA_CK(t) ((void)0)
#endif

/* deterministic xorshift64 (no time/rand: reproducible). */
static uint64_t g_rng;
static void     rng_seed(uint64_t s) { g_rng = s ? s : 0x9e3779b97f4a7c15ULL; }
static uint32_t rnd(void)
{
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17;
    return (uint32_t)(g_rng >> 11);
}

static uint64_t hash_u32(const void *k, void *c) { (void)c; return *(const uint32_t *)k; }
static bool     eq_u32(const void *a, const void *b, void *c)
{ (void)c; return *(const uint32_t *)a == *(const uint32_t *)b; }

/* all keys collide -> one long probe chain (stresses probe/backward-shift). */
static uint64_t hash_bad(const void *k, void *c) { (void)c; (void)k; return 0; }

static uint64_t hash_ptr(const void *k, void *c)
{ (void)c; const void *p = *(const void *const *)k; return (uint64_t)(uintptr_t)p; }
static bool     eq_ptr(const void *a, const void *b, void *c)
{ (void)c; return *(const void *const *)a == *(const void *const *)b; }

static int g_dtor_calls;
static void counting_dtor(void *val, void *c) { (void)val; (void)c; g_dtor_calls++; }

static int test_empty(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 0,
                    hash_u32, eq_u32, NULL, NULL);
    OA_CK(&t);
    CHECK(t.cap == 0, "init allocates nothing");
    CHECK(t.load_pct == 70, "load_pct 0 -> 70 default");
    CHECK(oa_len(&t) == 0, "empty len 0");
    uint32_t k = 5;
    CHECK(ds_oa_get(&t, &k) == NULL, "get on empty -> NULL");
    CHECK(ds_oa_del(&t, &k) == false, "del on empty -> false");
    ds_oa_free(&t);
    return g_fails;
}

static int test_basic_put_get(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 0,
                    hash_u32, eq_u32, NULL, NULL);
    uint32_t k = 42; void *v; bool isnew;
    ds_result_t r = ds_oa_put(&t, &k, &v, &isnew);
    CHECK(r.status == DS_OK, "put ok");
    CHECK(isnew, "first put is_new");
    CHECK(t.cap == OA_INIT_CAP, "lazy first alloc -> OA_INIT_CAP");
    CHECK(*(uint32_t *)v == 0, "P2: new value zero-initialized");
    *(uint32_t *)v = 99;
    OA_CK(&t);

    void *v2; ds_result_t r2 = ds_oa_put(&t, &k, &v2, &isnew);
    CHECK(r2.status == DS_OK && !isnew, "second put finds, is_new false");
    CHECK(v2 == ds_oa_get(&t, &k), "put/get return same value ptr");
    CHECK(*(uint32_t *)ds_oa_get(&t, &k) == 99, "value retained");
    CHECK(oa_len(&t) == 1, "len 1 after dup put");

    uint32_t miss = 7;
    CHECK(ds_oa_get(&t, &miss) == NULL, "absent get -> NULL (OA_NONE path)");
    CHECK(ds_oa_del(&t, &miss) == false, "absent del -> false");
    CHECK(ds_oa_del(&t, &k) == true, "present del -> true");
    CHECK(oa_len(&t) == 0, "len 0 after del");
    CHECK(ds_oa_get(&t, &k) == NULL, "deleted key gone");
    OA_CK(&t);
    ds_oa_free(&t);
    return g_fails;
}

static int test_grow_findable(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 0,
                    hash_u32, eq_u32, NULL, NULL);
    enum { N = 1000 };
    for (uint32_t k = 0; k < N; k++) {
        void *v; bool isnew;
        ds_result_t r = ds_oa_put(&t, &k, &v, &isnew);
        CHECK(r.status == DS_OK && isnew, "grow: insert ok");
        *(uint32_t *)v = k * 3 + 1;
        OA_CK(&t);
    }
    CHECK(oa_len(&t) == N, "grow: len == N");
    for (uint32_t k = 0; k < N; k++) {
        void *v = ds_oa_get(&t, &k);
        CHECK(v && *(uint32_t *)v == k * 3 + 1, "grow: all findable w/ value");
    }
    /* delete every other key, survivors still findable. */
    for (uint32_t k = 0; k < N; k += 2) CHECK(ds_oa_del(&t, &k), "grow: del even");
    OA_CK(&t);
    CHECK(oa_len(&t) == N / 2, "grow: len after half-delete");
    for (uint32_t k = 1; k < N; k += 2)
        CHECK(ds_oa_get(&t, &k), "grow: odd survivors findable");
    for (uint32_t k = 0; k < N; k += 2)
        CHECK(ds_oa_get(&t, &k) == NULL, "grow: evens gone");
    uint32_t cap_before = t.cap;
    for (uint32_t k = 1; k < N; k += 2) ds_oa_del(&t, &k);
    CHECK(oa_len(&t) == 0, "grow: emptied");
    CHECK(t.cap == cap_before, "del never shrinks cap");
    OA_CK(&t);
    ds_oa_free(&t);
    return g_fails;
}

static int test_reserve_and_locked(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 0,
                    hash_u32, eq_u32, NULL, NULL);
    ds_result_t r = ds_oa_reserve(&t, 10);
    CHECK(r.status == DS_OK, "reserve ok");
    uint32_t cap0 = t.cap;
    CHECK(cap0 >= 16, "reserve(10)@70% -> cap >= 16");
    for (uint32_t k = 0; k < 10; k++) {
        void *v; bool isnew;
        ds_oa_put(&t, &k, &v, &isnew);
        OA_CK(&t);
    }
    CHECK(t.cap == cap0, "no grow within reserved capacity");

    t.locked = true;
    /* re-putting an existing key never grows -> always ok. */
    uint32_t ek = 3; void *v; bool isnew;
    CHECK(ds_oa_put(&t, &ek, &v, &isnew).status == DS_OK && !isnew,
          "locked: existing put ok");

    /* insert new keys until a grow would be needed -> RT_UNSAFE, table intact. */
    bool hit_rt = false;
    for (uint32_t k = 100; k < 100 + cap0; k++) {
        ds_result_t rr = ds_oa_put(&t, &k, &v, &isnew);
        if (rr.status == DS_ERR_RT_UNSAFE) {
            hit_rt = true;
            CHECK(ds_oa_get(&t, &k) == NULL, "locked: failed put left key absent");
            OA_CK(&t);
            break;
        }
        CHECK(rr.status == DS_OK, "locked: pre-bound put ok");
    }
    CHECK(hit_rt, "locked: a grow attempt was refused (RT_UNSAFE)");
    CHECK(t.cap == cap0, "locked: cap never changed");
    ds_oa_free(&t);
    return g_fails;
}

static int test_dtor(void)
{
    g_fails = 0;
    g_dtor_calls = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 0,
                    hash_u32, eq_u32, counting_dtor, NULL);
    for (uint32_t k = 0; k < 5; k++) { void *v; bool n; ds_oa_put(&t, &k, &v, &n); }
    uint32_t d0 = 0, d1 = 1;
    ds_oa_del(&t, &d0); ds_oa_del(&t, &d1);
    CHECK(g_dtor_calls == 2, "dtor fires once per del");
    ds_oa_clear(&t);
    CHECK(g_dtor_calls == 5, "dtor fires for each live value on clear");
    CHECK(oa_len(&t) == 0 && t.cap != 0, "clear: len 0, cap kept");
    for (uint32_t k = 0; k < 4; k++) { void *v; bool n; ds_oa_put(&t, &k, &v, &n); }
    ds_oa_free(&t);
    CHECK(g_dtor_calls == 9, "dtor fires for each live value on free");
    return g_fails;
}

/* random put/get/del over [0,DOMAIN) vs a reference, ds_oa_check after each op. */
static int model_run(uint64_t seed, oa_hash_fn hash, uint32_t domain,
                     uint32_t ops, uint8_t load_pct)
{
    int fails = 0;
    rng_seed(seed);
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), load_pct,
                    hash, eq_u32, NULL, NULL);
    char    *present = calloc(domain, 1);
    uint32_t *mval   = calloc(domain, sizeof(uint32_t));
    uint32_t  live   = 0;

    for (uint32_t step = 0; step < ops; step++) {
        uint32_t k = rnd() % domain;
        uint32_t pick = rnd() % 3;
        if (pick == 0) {                    /* put */
            void *v; bool isnew;
            ds_result_t r = ds_oa_put(&t, &k, &v, &isnew);
            if (r.status != DS_OK) { fprintf(stderr, "model: put err\n"); fails++; break; }
            if (isnew) {
                if (present[k]) fails++;     /* dup reported new */
                present[k] = 1; live++;
                mval[k] = (k * 2654435761u) ^ step;
                *(uint32_t *)v = mval[k];
            } else {
                if (!present[k]) fails++;    /* existing not in ref */
                if (*(uint32_t *)v != mval[k]) fails++;
            }
        } else if (pick == 1) {             /* del */
            bool got = ds_oa_del(&t, &k);
            if (got != (bool)present[k]) fails++;
            if (present[k]) { present[k] = 0; live--; }
        } else {                            /* get */
            void *v = ds_oa_get(&t, &k);
            if ((v != NULL) != (bool)present[k]) fails++;
            if (v && *(uint32_t *)v != mval[k]) fails++;
        }
        OA_CK(&t);

        /* full membership + len equivalence every few ops (cheaper). */
        if ((step & 31) == 0) {
            if (oa_len(&t) != live) fails++;
            for (uint32_t kk = 0; kk < domain; kk++) {
                void *v = ds_oa_get(&t, &kk);
                if ((v != NULL) != (bool)present[kk]) { fails++; break; }
                if (v && *(uint32_t *)v != mval[kk]) { fails++; break; }
            }
            /* iteration yields exactly the live set, once each. */
            char *seen = calloc(domain, 1);
            uint32_t it = oa_len(&t);
            for (uint32_t i = 0; i < it; i++) {
                uint32_t kk = *(uint32_t *)ds_oa_key_at(&t, i);
                if (kk >= domain || !present[kk] || seen[kk]) { fails++; break; }
                if (*(uint32_t *)ds_oa_val_at(&t, i) != mval[kk]) { fails++; break; }
                seen[kk] = 1;
            }
            free(seen);
        }
        if (fails) break;
    }
    free(present); free(mval);
    ds_oa_free(&t);
    if (fails)
        fprintf(stderr, "model_run(seed=%llu, dom=%u, ops=%u, load=%u): %d fail\n",
                (unsigned long long)seed, domain, ops, load_pct, fails);
    return fails;
}

static int test_model(void)
{
    g_fails = 0;
    /* normal hash: grow-boundary crossings come for free over many inserts. */
    for (uint64_t s = 1; s <= 12; s++)
        g_fails += model_run(s, hash_u32, 64, 4000, 70);
    /* collision storm: every key hashes to slot 0 -> max probe chains. */
    for (uint64_t s = 1; s <= 8; s++)
        g_fails += model_run(s * 7 + 1, hash_bad, 40, 3000, 70);
    /* high load factor -> denser tables, longer backward-shift runs. */
    for (uint64_t s = 1; s <= 6; s++)
        g_fails += model_run(s * 13 + 3, hash_u32, 80, 5000, 90);
    return g_fails;
}

/* At maximal density a backward-shift delete must terminate and leave no
 * zombie: the densest table (load 99%, locked so it cannot grow) under the bad
 * hash, emptied in three orders. Without the slots[s] = 0 pre-clear before the
 * scan, this hangs. */
static int test_rtbug1_full_table_delete(void)
{
    g_fails = 0;
    for (int order = 0; order < 3; order++) {
        oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 99,
                        hash_bad, eq_u32, NULL, NULL);
        CHECK(ds_oa_reserve(&t, 15).status == DS_OK, "rtbug1: reserve");
        t.locked = true;
        uint32_t cap = t.cap, fill = cap - 1;   /* densest: len == cap-1 */
        for (uint32_t k = 0; k < fill; k++) {
            void *v; bool n;
            ds_result_t r = ds_oa_put(&t, &k, &v, &n);
            CHECK(r.status == DS_OK, "rtbug1: dense insert ok (no grow)");
        }
        CHECK(oa_len(&t) == fill, "rtbug1: filled to cap-1");
        OA_CK(&t);
        for (uint32_t i = 0; i < fill; i++) {
            uint32_t k = (order == 0) ? i                       /* forward */
                       : (order == 1) ? (fill - 1 - i)          /* reverse */
                       : ((i * 7 + 3) % fill);                  /* scattered */
            /* scattered order may repeat; del is idempotent-safe. */
            ds_oa_del(&t, &k);
            OA_CK(&t);
        }
        /* whatever scattered order hit, force-empty the rest. */
        for (uint32_t k = 0; k < fill; k++) ds_oa_del(&t, &k);
        CHECK(oa_len(&t) == 0, "rtbug1: emptied without hang");
        OA_CK(&t);
        ds_oa_free(&t);
    }
    return g_fails;
}

/* Long backward-shift chains + delete-then-reinsert storm under the bad hash:
 * delete from the middle of a long chain, reinsert, repeat — survivors must
 * stay findable (RI-5). */
static int test_long_chains_and_churn(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 70,
                    hash_bad, eq_u32, NULL, NULL);
    enum { K = 50 };
    for (uint32_t k = 0; k < K; k++) { void *v; bool n; ds_oa_put(&t, &k, &v, &n); }
    OA_CK(&t);
    rng_seed(0xC0FFEE);
    for (int round = 0; round < 2000; round++) {
        uint32_t k = rnd() % K;
        if (ds_oa_del(&t, &k)) {
            OA_CK(&t);
            CHECK(ds_oa_get(&t, &k) == NULL, "churn: deleted key absent");
            void *v; bool n; ds_oa_put(&t, &k, &v, &n);   /* reinsert */
            OA_CK(&t);
        }
        CHECK(ds_oa_get(&t, &k) != NULL, "churn: key present after reinsert");
    }
    for (uint32_t k = 0; k < K; k++)
        CHECK(ds_oa_get(&t, &k) != NULL, "churn: all survive the storm");
    ds_oa_free(&t);
    return g_fails;
}

/* Grow exactly at the load boundary: cap must double precisely when the (n+1)th
 * insert would breach load_pct, and everything stays findable across it. */
static int test_grow_boundary(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(uint32_t), 70,
                    hash_u32, eq_u32, NULL, NULL);
    uint32_t prev_cap = 0; int grows = 0;
    for (uint32_t k = 0; k < 200; k++) {
        void *v; bool n; ds_oa_put(&t, &k, &v, &n);
        if (t.cap != prev_cap) {
            grows++;
            /* invariant the moment after a grow: load is under threshold. */
            CHECK((uint64_t)t.len * 100u <= (uint64_t)t.cap * t.load_pct,
                  "post-grow load under threshold");
            prev_cap = t.cap;
        }
        /* never exceed the load bound after any insert. */
        CHECK((uint64_t)t.len * 100u <= (uint64_t)t.cap * t.load_pct,
              "load bound holds after insert");
        OA_CK(&t);
    }
    CHECK(grows >= 4, "several grows occurred");
    for (uint32_t k = 0; k < 200; k++) CHECK(ds_oa_get(&t, &k), "all findable across grows");
    ds_oa_free(&t);
    return g_fails;
}

/* Pointer-key + simulated slab reuse: a full delete must remove every trace, so
 * a later alloc reusing the same address is a fresh key, never an alias. */
static int test_ptr_slab_reuse(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(void *), sizeof(uint32_t), 0,
                    hash_ptr, eq_ptr, NULL, NULL);
    for (int i = 0; i < 200; i++) {
        void *a = malloc(16);
        void *v; bool n;
        ds_oa_put(&t, &a, &v, &n); *(uint32_t *)v = 0xAAAA;
        CHECK(ds_oa_del(&t, &a), "slab: delete A");
        CHECK(ds_oa_get(&t, &a) == NULL, "slab: A leaves no residual");
        free(a);
        void *b = malloc(16);                 /* may reuse a's address */
        ds_oa_put(&t, &b, &v, &n); *(uint32_t *)v = 0xBBBB;
        void *gv = ds_oa_get(&t, &b);
        CHECK(gv && *(uint32_t *)gv == 0xBBBB, "slab: B is its own entry");
        CHECK(oa_len(&t) == 1, "slab: exactly one live entry");
        ds_oa_del(&t, &b);
        free(b);
        OA_CK(&t);
    }
    ds_oa_free(&t);
    return g_fails;
}

#define ENC(e) ((void *)(uintptr_t)((e) + 1))
#define DEC(p) ((uint32_t)((uintptr_t)(p) - 1))

static int test_oa_list_unit(void)
{
    g_fails = 0;
    oa_list l; memset(&l, 0, sizeof(l));
    for (uint32_t i = 0; i < OA_LIST_INLINE; i++)
        CHECK(ds_oa_list_add(&l, ENC(i), false).status == DS_OK, "list inline add");
    CHECK(ds_oa_list_len(&l) == OA_LIST_INLINE, "list inline full");
    CHECK(l.heap == NULL, "no heap while inline");

    /* heap overflow under locked must be refused, not allocated. */
    CHECK(ds_oa_list_add(&l, ENC(99), true).status == DS_ERR_RT_UNSAFE,
          "list: locked overflow refused");
    CHECK(l.heap == NULL && ds_oa_list_len(&l) == OA_LIST_INLINE,
          "list: refused add changed nothing");

    /* unlocked overflow grows the heap. */
    for (uint32_t i = OA_LIST_INLINE; i < 20; i++)
        CHECK(ds_oa_list_add(&l, ENC(i), false).status == DS_OK, "list heap add");
    CHECK(ds_oa_list_len(&l) == 20, "list len after overflow");
    CHECK(l.heap != NULL, "heap allocated on overflow");

    /* membership (order not stable): every 0..19 present exactly once. */
    char seen[20] = {0};
    for (uint32_t i = 0; i < ds_oa_list_len(&l); i++) {
        uint32_t e = DEC(ds_oa_list_at(&l, i));
        CHECK(e < 20 && !seen[e], "list: each element once");
        seen[e] = 1;
    }
    CHECK(ds_oa_list_remove(&l, ENC(0)), "list remove inline elem");
    CHECK(ds_oa_list_remove(&l, ENC(15)), "list remove heap elem");
    CHECK(!ds_oa_list_remove(&l, ENC(0)), "list remove absent -> false");
    CHECK(ds_oa_list_len(&l) == 18, "list len after removes");
    ds_oa_list_free(&l, NULL);
    CHECK(l.heap == NULL && ds_oa_list_len(&l) == 0, "list free clears");
    return g_fails;
}

/* count adapter (the `block` table shape): increment / decrement-and-delete. */
static int test_count_adapter(void)
{
    g_fails = 0;
    oa_t t; ds_oa_init(&t, sizeof(void *), sizeof(uint32_t), 0,
                    hash_ptr, eq_ptr, NULL, NULL);
    void *toks[8];
    for (int i = 0; i < 8; i++) toks[i] = (void *)(uintptr_t)(0x1000 + i * 0x40);

    /* increment tok[i] (i+1) times. */
    for (int i = 0; i < 8; i++)
        for (int j = 0; j <= i; j++) {
            void *v; bool n;
            ds_oa_put(&t, &toks[i], &v, &n);
            if (n) CHECK(*(uint32_t *)v == 0, "count: starts at 0 (P2)");
            (*(uint32_t *)v)++;
        }
    OA_CK(&t);
    for (int i = 0; i < 8; i++)
        CHECK(*(uint32_t *)ds_oa_get(&t, &toks[i]) == (uint32_t)(i + 1),
              "count: value == #increments");

    /* decrement-and-maybe-delete to zero. */
    for (int i = 0; i < 8; i++)
        for (int j = 0; j <= i; j++) {
            void *v = ds_oa_get(&t, &toks[i]);
            CHECK(v != NULL, "count: present while > 0");
            if (--*(uint32_t *)v == 0) ds_oa_del(&t, &toks[i]);
            OA_CK(&t);
        }
    CHECK(oa_len(&t) == 0, "count: all reached zero and were deleted");
    ds_oa_free(&t);
    return g_fails;
}

/* multimap fuzz: random add/remove(key,elem) vs a reference multiset; verify
 * membership + counts + ds_oa_check; empty lists are deleted (real-usage shape). */
static int multimap_run(uint64_t seed, uint32_t ops)
{
    int fails = 0;
    enum { DK = 16, DE = 12 };
    rng_seed(seed);
    oa_t t; ds_oa_init(&t, sizeof(uint32_t), sizeof(oa_list), 70,
                    hash_u32, eq_u32, ds_oa_list_free, NULL);
    uint32_t ref[DK][DE]; memset(ref, 0, sizeof(ref));

    for (uint32_t step = 0; step < ops; step++) {
        uint32_t k = rnd() % DK, e = rnd() % DE;
        if (rnd() & 1) {                                  /* add */
            void *v; bool n;
            if (ds_oa_put(&t, &k, &v, &n).status != DS_OK) { fails++; break; }
            if (ds_oa_list_add((oa_list *)v, ENC(e), false).status != DS_OK) { fails++; break; }
            ref[k][e]++;
        } else {                                          /* remove one e */
            void *v = ds_oa_get(&t, &k);
            if (ref[k][e] > 0) {
                if (!v) { fails++; break; }
                if (!ds_oa_list_remove((oa_list *)v, ENC(e))) { fails++; break; }
                ref[k][e]--;
                uint32_t tot = 0;
                for (uint32_t ee = 0; ee < DE; ee++) tot += ref[k][ee];
                if (tot == 0) ds_oa_del(&t, &k);             /* drop empty entry */
            }
        }
        OA_CK(&t);

        if ((step & 15) == 0) {
            for (uint32_t kk = 0; kk < DK; kk++) {
                uint32_t tot = 0, cnt[DE]; memset(cnt, 0, sizeof(cnt));
                for (uint32_t ee = 0; ee < DE; ee++) tot += ref[kk][ee];
                void *v = ds_oa_get(&t, &kk);
                if (tot == 0) { if (v) { fails++; break; } continue; }
                if (!v) { fails++; break; }
                oa_list *l = (oa_list *)v;
                if (ds_oa_list_len(l) != tot) { fails++; break; }
                for (uint32_t i = 0; i < ds_oa_list_len(l); i++) cnt[DEC(ds_oa_list_at(l, i))]++;
                if (memcmp(cnt, ref[kk], sizeof(cnt)) != 0) { fails++; break; }
            }
        }
        if (fails) break;
    }
    ds_oa_free(&t);                 /* exercises val_dtor over live lists */
    if (fails) fprintf(stderr, "multimap_run(seed=%llu): %d fail\n",
                       (unsigned long long)seed, fails);
    return fails;
}

static int test_multimap(void)
{
    g_fails = 0;
    for (uint64_t s = 1; s <= 16; s++) g_fails += multimap_run(s * 2654435761u + 1, 4000);
    return g_fails;
}

struct clone_delta { uint32_t kdelta, vdelta, edelta; };
static void remap_key_add(const void *s, void *d, void *c)
{ *(uint32_t *)d = *(const uint32_t *)s + ((struct clone_delta *)c)->kdelta; }
static void remap_val_add(const void *s, void *d, void *c)
{ *(uint32_t *)d = *(const uint32_t *)s + ((struct clone_delta *)c)->vdelta; }
/* value remap for an oa_list-valued map: rebuild the (zero-init) dst list by
   adding each source element shifted by edelta (models a fact/token ptr remap). */
static void remap_list_shift(const void *s, void *d, void *c)
{
    const oa_list *sl = (const oa_list *)s;
    oa_list       *dl = (oa_list *)d;
    uintptr_t      sh = ((struct clone_delta *)c)->edelta;
    for (uint32_t i = 0; i < ds_oa_list_len(sl); i++)
        ds_oa_list_add(dl, (void *)((uintptr_t)ds_oa_list_at(sl, i) + sh), false);
}

static int test_clone(void)
{
    g_fails = 0;

    /* 1. verbatim clone reproduces dense order (post-churn) + values, and is
          fully independent of the source afterwards. */
    oa_t src; ds_oa_init(&src, sizeof(uint32_t), sizeof(uint32_t), 0,
                      hash_u32, eq_u32, NULL, NULL);
    for (uint32_t k = 0; k < 20; k++) {
        void *v; ds_oa_put(&src, &k, &v, NULL); *(uint32_t *)v = k * 10;
    }
    uint32_t del[] = { 3, 7, 11, 17 };          /* swap-remove reorders dense */
    for (size_t i = 0; i < sizeof(del)/sizeof(del[0]); i++) ds_oa_del(&src, &del[i]);
    OA_CK(&src);

    oa_t dst; ds_oa_init(&dst, sizeof(uint32_t), sizeof(uint32_t), 0,
                      hash_u32, eq_u32, NULL, NULL);
    ds_result_t r = ds_oa_clone_into(&dst, &src, NULL, NULL, NULL);
    CHECK(r.status == DS_OK, "verbatim clone ok");
    OA_CK(&dst);
    CHECK(oa_len(&dst) == oa_len(&src), "clone len matches");
    bool order_ok = true;
    for (uint32_t i = 0; i < oa_len(&src); i++) {
        if (*(uint32_t *)ds_oa_key_at(&dst, i) != *(uint32_t *)ds_oa_key_at(&src, i) ||
            *(uint32_t *)ds_oa_val_at(&dst, i) != *(uint32_t *)ds_oa_val_at(&src, i))
            order_ok = false;
    }
    CHECK(order_ok, "clone preserves dense order + values verbatim");
    /* independence both directions */
    uint32_t k5 = 5; *(uint32_t *)ds_oa_get(&src, &k5) = 999;
    CHECK(*(uint32_t *)ds_oa_get(&dst, &k5) == 50, "src mutate does not touch dst");
    uint32_t knew = 100; void *nv; ds_oa_put(&src, &knew, &nv, NULL);
    CHECK(ds_oa_get(&dst, &knew) == NULL, "src insert does not touch dst");
    uint32_t knew2 = 200; void *nv2; ds_oa_put(&dst, &knew2, &nv2, NULL);
    CHECK(ds_oa_get(&src, &knew2) == NULL, "dst insert does not touch src");
    ds_oa_free(&src); ds_oa_free(&dst);

    /* 2. key + value remap. */
    struct clone_delta cd = { .kdelta = 1, .vdelta = 1000, .edelta = 500 };
    ds_oa_init(&src, sizeof(uint32_t), sizeof(uint32_t), 0, hash_u32, eq_u32, NULL, NULL);
    for (uint32_t k = 0; k < 10; k++) { void *v; ds_oa_put(&src, &k, &v, NULL); *(uint32_t *)v = k; }
    ds_oa_init(&dst, sizeof(uint32_t), sizeof(uint32_t), 0, hash_u32, eq_u32, NULL, NULL);
    r = ds_oa_clone_into(&dst, &src, remap_key_add, remap_val_add, &cd);
    CHECK(r.status == DS_OK, "remap clone ok");
    OA_CK(&dst);
    bool remap_ok = (oa_len(&dst) == 10);
    for (uint32_t k = 0; k < 10; k++) {
        uint32_t nk = k + 1; void *v = ds_oa_get(&dst, &nk);
        if (!v || *(uint32_t *)v != k + 1000) remap_ok = false;
    }
    CHECK(remap_ok, "remapped keys+values present");
    ds_oa_free(&src); ds_oa_free(&dst);

    /* 3. oa_list-valued map: clone rebuilds each list, elements shifted. */
    ds_oa_init(&src, sizeof(uint32_t), sizeof(oa_list), 70, hash_u32, eq_u32, ds_oa_list_free, NULL);
    for (uint32_t k = 0; k < 6; k++) {
        void *v; ds_oa_put(&src, &k, &v, NULL);
        for (uint32_t e = 0; e <= k; e++)               /* k+1 elements */
            ds_oa_list_add((oa_list *)v, (void *)(uintptr_t)(e + 1), false);
    }
    ds_oa_init(&dst, sizeof(uint32_t), sizeof(oa_list), 70, hash_u32, eq_u32, ds_oa_list_free, NULL);
    r = ds_oa_clone_into(&dst, &src, NULL, remap_list_shift, &cd);
    CHECK(r.status == DS_OK, "list-valued clone ok");
    OA_CK(&dst);
    bool list_ok = (oa_len(&dst) == 6);
    for (uint32_t k = 0; k < 6; k++) {
        oa_list *dl = (oa_list *)ds_oa_get(&dst, &k);
        if (!dl || ds_oa_list_len(dl) != k + 1) { list_ok = false; continue; }
        for (uint32_t e = 0; e <= k; e++)
            if ((uintptr_t)ds_oa_list_at(dl, e) != (uintptr_t)(e + 1) + cd.edelta) list_ok = false;
    }
    CHECK(list_ok, "cloned lists rebuilt with shifted elements, order kept");
    ds_oa_free(&src); ds_oa_free(&dst);   /* val_dtor frees both sides' list heaps */

    /* 4. empty source clones to an empty (untouched) dst. */
    ds_oa_init(&src, sizeof(uint32_t), sizeof(uint32_t), 0, hash_u32, eq_u32, NULL, NULL);
    ds_oa_init(&dst, sizeof(uint32_t), sizeof(uint32_t), 0, hash_u32, eq_u32, NULL, NULL);
    r = ds_oa_clone_into(&dst, &src, NULL, NULL, NULL);
    CHECK(r.status == DS_OK && oa_len(&dst) == 0, "empty clone ok");
    ds_oa_free(&src); ds_oa_free(&dst);

    return g_fails;
}

int main(void)
{
    int fails = 0;
    struct { const char *name; int (*fn)(void); } cases[] = {
        { "empty",                 test_empty },
        { "basic_put_get",         test_basic_put_get },
        { "grow_findable",         test_grow_findable },
        { "reserve_and_locked",    test_reserve_and_locked },
        { "dtor",                  test_dtor },
        { "model",                 test_model },
        { "rtbug1_full_delete",    test_rtbug1_full_table_delete },
        { "long_chains_churn",     test_long_chains_and_churn },
        { "grow_boundary",         test_grow_boundary },
        { "ptr_slab_reuse",        test_ptr_slab_reuse },
        { "oa_list_unit",          test_oa_list_unit },
        { "count_adapter",         test_count_adapter },
        { "multimap",              test_multimap },
        { "clone",                 test_clone },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        int f = cases[i].fn();
        printf("  %-22s %s\n", cases[i].name, f ? "FAIL" : "ok");
        fails += f;
    }
    if (fails) { printf("test_oa: %d FAILURES\n", fails); return 1; }
    printf("test_oa: ALL PASSED\n");
    return 0;
}

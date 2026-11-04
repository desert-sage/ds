/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* The rete/intern.c primitives, with no engine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "rete/intern.h"

static int fail(const char *m) { fprintf(stderr, "FAIL: %s\n", m); return 1; }

static size_t icount(const ds_rete_intern_t *t)
{ size_t n = 0; ds_rete_intern_mem(t, &n, NULL, NULL); return n; }
static size_t ibytes(const ds_rete_intern_t *t)
{ size_t b = 0; ds_rete_intern_mem(t, NULL, &b, NULL); return b; }

static int test_basic_ops(void)
{
    ds_rete_intern_t *t = NULL;
    if (ds_rete_intern_init(&t).status != DS_OK) return fail("init");

    const char *p = NULL;
    ds_rete_intern_find(t, "x", 1, &p);
    if (p != NULL) return fail("find absent should be NULL");

    const char *pin = NULL;
    ds_rete_intern_cstr(t, "schema", &pin);
    if (!pin || icount(t) != 1 || ds_rete_intern_pinned_count(t) != 1)
        return fail("pin");
    if (memcmp(pin, "schema", 7) != 0) return fail("pin content");

    ds_rete_intern_find(t, "schema", 6, &p);
    if (p != pin) return fail("find present must return the interned pointer");

    const char *pin2 = NULL;
    ds_rete_intern_cstr(t, "schema", &pin2);
    if (pin2 != pin || icount(t) != 1) return fail("re-pin dedup");

    const char *v = NULL;
    ds_rete_intern_value_cstr(t, "val", &v);
    if (!v || icount(t) != 2 || ds_rete_intern_pinned_count(t) != 1)
        return fail("value creates a counted entry");
    if (ibytes(t) != 6 + 3) return fail("bytes_used accounting");

    ds_rete_intern_destroy(t);
    return 0;
}

static int test_cross_class_sharing(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);

    const char *pin = NULL;
    ds_rete_intern_cstr(t, "shared", &pin);           /* pinned */
    const char *val = NULL;
    ds_rete_intern_value_cstr(t, "shared", &val);     /* value, same content */
    if (val != pin) return fail("counted value equal to a pinned literal must share its pointer");
    if (icount(t) != 1 || ds_rete_intern_pinned_count(t) != 1)
        return fail("shared entry stays a single pinned entry");

    ds_rete_intern_acquire_ptr(t, val, 6);
    ds_rete_intern_release(t, val, 6);
    if (icount(t) != 1 || ds_rete_intern_pinned_count(t) != 1)
        return fail("acquire/release on pinned must be no-ops");

    ds_rete_intern_destroy(t);
    return 0;
}

static int test_refcount_ladder(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    size_t base = icount(t);

    const char *v = NULL;
    ds_rete_intern_value(t, "abc", 3, &v);            /* born @0 */
    if (icount(t) != base + 1) return fail("value entry present @0");

    ds_rete_intern_acquire_ptr(t, v, 3);              /* @1 */
    ds_rete_intern_acquire_ptr(t, v, 3);              /* @2 (two holders) */
    if (icount(t) != base + 1) return fail("acquire must not create entries");

    ds_rete_intern_release(t, v, 3);                  /* @1 — survives */
    if (icount(t) != base + 1) return fail("release with a live holder must not free");
    ds_rete_intern_release(t, v, 3);                  /* @0, removed */
    if (icount(t) != base) return fail("last release must free + remove");

    ds_rete_intern_release(t, "not-interned", 12);
    if (icount(t) != base) return fail("release of non-interned must be a no-op");

    ds_rete_intern_destroy(t);
    return 0;
}

/* An entry never acquired is freed by destroy; the leak lanes judge it. */
static int test_born_zero_destroy_clean(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *v = NULL;
    ds_rete_intern_value(t, "never-acquired", 14, &v);
    ds_rete_intern_destroy(t);
    return 0;
}

/* Size-class boundaries and the oversized path. */
static int test_size_classes(void)
{
    static const size_t lens[] = { 0, 1, 7, 8, 9, 4095, 4096, 4097, 65536 };
    for (size_t i = 0; i < sizeof(lens) / sizeof(lens[0]); i++) {
        size_t L = lens[i];
        char *buf = malloc(L + 1);
        if (!buf) return fail("test buf alloc");
        for (size_t k = 0; k < L; k++) buf[k] = (char)('A' + (k % 26));
        buf[L] = '\0';

        ds_rete_intern_t *t = NULL;
        ds_rete_intern_init(&t);
        size_t base = icount(t);

        const char *v = NULL;
        if (ds_rete_intern_value(t, buf, L, &v).status != DS_OK) { free(buf); return fail("value alloc"); }
        if (L && memcmp(v, buf, L) != 0) { free(buf); return fail("content round-trip"); }
        if (v[L] != '\0') { free(buf); return fail("NUL terminator"); }
        if (icount(t) != base + 1) { free(buf); return fail("size-class count"); }

        ds_rete_intern_acquire_ptr(t, v, L);
        ds_rete_intern_release(t, v, L);
        if (icount(t) != base) { free(buf); return fail("size-class reclaim"); }

        ds_rete_intern_destroy(t);
        free(buf);
    }
    return 0;
}

static int test_embedded_nul(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char a[] = { 'x', '\0', 'y', '\0', 'z' };   /* len 5, interior NULs */
    const char b[] = { 'x', '\0', 'y' };              /* len 3, prefix of a */

    const char *va = NULL, *vb = NULL;
    ds_rete_intern_value(t, a, 5, &va);
    ds_rete_intern_value(t, b, 3, &vb);
    if (va == vb) return fail("distinct-length values must not alias (strlen would confuse them)");
    if (icount(t) != 2) return fail("embedded-NUL distinct entries");
    if (memcmp(va, a, 5) != 0 || memcmp(vb, b, 3) != 0) return fail("embedded-NUL content");

    const char *found = NULL;
    ds_rete_intern_find(t, a, 5, &found);
    if (found != va) return fail("length-aware find");

    ds_rete_intern_acquire_ptr(t, va, 5); ds_rete_intern_release(t, va, 5);
    ds_rete_intern_acquire_ptr(t, vb, 3); ds_rete_intern_release(t, vb, 3);
    if (icount(t) != 0) return fail("embedded-NUL reclaim");
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_grow_survives(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    size_t r0 = ds_rete_intern_resize_count(t);

    enum { N = 200 };
    const char *ptrs[N];
    for (int i = 0; i < N; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "sym_%d", i);
        ds_rete_intern_cstr(t, buf, &ptrs[i]);        /* pinned; forces grows */
        (void)n;
    }
    if (ds_rete_intern_resize_count(t) <= r0) return fail("table should have grown");
    if (icount(t) != N) return fail("grow lost entries");
    for (int i = 0; i < N; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "sym_%d", i);
        const char *f = NULL; ds_rete_intern_find(t, buf, (size_t)n, &f);
        if (f != ptrs[i]) return fail("grow: entry moved or lost");
    }
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_tombstone_reuse(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    enum { N = 100 };
    const char *v[N];
    for (int i = 0; i < N; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "v%d", i);
        ds_rete_intern_value(t, buf, (size_t)n, &v[i]);
        ds_rete_intern_acquire_ptr(t, v[i], (size_t)n);
    }
    if (icount(t) != N) return fail("insert N");
    for (int i = 0; i < N; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "v%d", i);
        ds_rete_intern_release(t, v[i], (size_t)n);   /* → tombstones */
    }
    if (icount(t) != 0) return fail("release all → 0 (tombstones don't count)");
    for (int i = 0; i < N; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "w%d", i);
        const char *w = NULL; ds_rete_intern_value(t, buf, (size_t)n, &w);
        if (memcmp(w, buf, (size_t)n) != 0) return fail("reinsert content");
        ds_rete_intern_acquire_ptr(t, w, (size_t)n);
        ds_rete_intern_release(t, w, (size_t)n);
    }
    if (icount(t) != 0) return fail("reinsert cycle → 0");
    ds_rete_intern_destroy(t);
    return 0;
}

/* Churn of distinct values does not grow the table ([LNLS.4.7]): a
 * tombstone-heavy rehash keeps its capacity, so the table tracks the live
 * count. */
static int test_churn_does_not_grow(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);                          /* cap 64 */
    enum { KEEP = 10, CHURN = 10000 };
    const char *keep[KEEP];
    for (int i = 0; i < KEEP; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "keep%d", i);
        ds_rete_intern_value(t, buf, (size_t)n, &keep[i]);
        ds_rete_intern_acquire_ptr(t, keep[i], (size_t)n);
    }
    size_t r0 = ds_rete_intern_resize_count(t);
    for (int i = 0; i < CHURN; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "churn%d", i);
        const char *v = NULL;
        if (ds_rete_intern_value(t, buf, (size_t)n, &v).status != DS_OK)
            return fail("churn: value");
        ds_rete_intern_acquire_ptr(t, v, (size_t)n);
        ds_rete_intern_release(t, v, (size_t)n);     /* → tombstone */
    }
    if (ds_rete_intern_resize_count(t) != r0)
        return fail("churn of distinct values grew the table");
    if (icount(t) != KEEP) return fail("churn: live count");
    for (int i = 0; i < KEEP; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "keep%d", i);
        const char *f = NULL; ds_rete_intern_find(t, buf, (size_t)n, &f);
        if (f != keep[i]) return fail("churn: a live entry moved or was lost");
    }
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_presz(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *p = NULL; ds_rete_intern_cstr(t, "keep", &p);
    if (ds_rete_intern_presz(t, 4096).status != DS_OK) return fail("presz");
    const char *f = NULL; ds_rete_intern_find(t, "keep", 4, &f);
    if (f != p) return fail("presz must preserve entries");
    if (ds_rete_intern_presz(t, 16).status != DS_OK) return fail("presz shrink-request is a no-op OK");
    ds_rete_intern_destroy(t);
    return 0;
}

/* A locked table refuses the insert that would grow it. */
static int test_rt_lock(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);          /* cap 64 */
    ds_rete_intern_lock(t);
    if (!ds_rete_intern_is_locked(t)) return fail("is_locked");
    int oom = 0;
    for (int i = 0; i < 128; i++) {
        char buf[32]; int n = snprintf(buf, sizeof buf, "L%d", i);
        const char *p = NULL;
        ds_result_t r = ds_rete_intern_cstr(t, buf, &p);
        if (r.status == DS_ERR_OOM) { oom = 1; break; }
        if (r.status != DS_OK) return fail("unexpected error under lock");
        (void)n;
    }
    if (!oom) return fail("locked table must OOM when it would grow");
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_contract_caps(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    ds_rete_intern_set_contract_caps(t, 3u, 0u);      /* cap_n = 3 */
    const char *p = NULL;
    ds_rete_intern_cstr(t, "a", &p);
    ds_rete_intern_cstr(t, "bb", &p);
    ds_rete_intern_cstr(t, "ccc", &p);
    if (icount(t) != 3) return fail("cap_n: 3 admitted");
    ds_result_t r = ds_rete_intern_cstr(t, "dddd", &p);
    if (r.status != DS_ERR_CONTRACT_BREACH) return fail("cap_n breach must reject");
    if (icount(t) != 3) return fail("cap_n breach must leave the table unmodified");

    ds_rete_intern_t *t2 = NULL;
    ds_rete_intern_init(&t2);
    ds_rete_intern_set_contract_caps(t2, 0u, 5u);     /* cap_bytes = 5 */
    ds_rete_intern_cstr(t2, "abc", &p);               /* 3 bytes */
    r = ds_rete_intern_cstr(t2, "xyz", &p);           /* would be 6 > 5 */
    if (r.status != DS_ERR_CONTRACT_BREACH) return fail("cap_bytes breach must reject");
    ds_rete_intern_destroy(t);
    ds_rete_intern_destroy(t2);
    return 0;
}

/* Steady-state churn in one size class recycles freed blocks. */
static int test_freelist_recycles(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *w = NULL;
    ds_rete_intern_value(t, "warm", 4, &w);
    ds_rete_intern_acquire_ptr(t, w, 4);
    ds_rete_intern_release(t, w, 4);
    size_t warm = ds_rete_intern_counted_mallocs(t);

    for (int i = 0; i < 500; i++) {
        char buf[8]; int n = snprintf(buf, sizeof buf, "r%03d", i);   /* same class */
        const char *v = NULL;
        ds_rete_intern_value(t, buf, (size_t)n, &v);
        ds_rete_intern_acquire_ptr(t, v, (size_t)n);
        ds_rete_intern_release(t, v, (size_t)n);
    }
    if (ds_rete_intern_counted_mallocs(t) != warm)
        return fail("steady-state churn must recycle (no new counted mallocs)");
    ds_rete_intern_destroy(t);
    return 0;
}

/* Pinning a counted value promotes it in place; release is then a no-op. */
static int test_promote(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *v = NULL; ds_rete_intern_value(t, "p", 1, &v);
    ds_rete_intern_acquire_ptr(t, v, 1);
    const char *pin = NULL; ds_rete_intern_cstr(t, "p", &pin);
    if (pin != v) return fail("promote must return the same pointer");
    if (ds_rete_intern_pinned_count(t) != 1) return fail("promote → pinned");
    ds_rete_intern_release(t, v, 1);
    if (icount(t) != 1 || ds_rete_intern_pinned_count(t) != 1)
        return fail("release after promote must be a no-op");
    ds_rete_intern_destroy(t);
    return 0;
}

int main(void)
{
    int fails = 0;
    printf("=== test_intern_unit ===\n");
#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fails++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    RUN(test_basic_ops);
    RUN(test_cross_class_sharing);
    RUN(test_refcount_ladder);
    RUN(test_born_zero_destroy_clean);
    RUN(test_size_classes);
    RUN(test_embedded_nul);
    RUN(test_grow_survives);
    RUN(test_tombstone_reuse);
    RUN(test_churn_does_not_grow);
    RUN(test_presz);
    RUN(test_rt_lock);
    RUN(test_contract_caps);
    RUN(test_freelist_recycles);
    RUN(test_promote);
#undef RUN

    if (fails == 0) { printf("=== test_intern_unit: ALL PASSED ===\n"); return 0; }
    fprintf(stderr, "=== test_intern_unit: %d FAILED ===\n", fails);
    return 1;
}

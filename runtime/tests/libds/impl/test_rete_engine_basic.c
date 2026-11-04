/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The Rete engine's intern table, create and destroy, clock, fire hooks, and
 * the isolation of two engines (IRET.18, IRET.1.4, IRET.22.9).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rete/engine.h"
#include "rete/intern.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want status %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int test_intern_basic(void)
{
    ds_rete_intern_t *t = NULL;
    if (expect_ok("intern_init", ds_rete_intern_init(&t))) return 1;

    const char *a, *b, *c;
    if (expect_ok("intern hello #1", ds_rete_intern_cstr(t, "hello", &a))) return 1;
    if (expect_ok("intern hello #2", ds_rete_intern_cstr(t, "hello", &b))) return 1;
    if (expect_ok("intern world",    ds_rete_intern_cstr(t, "world", &c))) return 1;

    if (a != b)
        return fail("intern: same content must yield same pointer");
    if (a == c)
        return fail("intern: different content must yield different pointer");
    if (strcmp(a, "hello") != 0)
        return fail("intern: value mismatch for 'hello'");
    if (strcmp(c, "world") != 0)
        return fail("intern: value mismatch for 'world'");

    ds_rete_intern_destroy(t);
    return 0;
}

static int test_intern_empty_string(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *a, *b;
    if (expect_ok("intern empty #1", ds_rete_intern_cstr(t, "", &a))) return 1;
    if (expect_ok("intern empty #2", ds_rete_intern_cstr(t, "", &b))) return 1;
    if (a != b) return fail("intern: empty string must be stable");
    if (a[0] != '\0') return fail("intern: empty string NUL missing");
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_intern_many(void)
{
    /* 200 strings force several rehashes. */
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    char         buf[32];
    const char  *ptrs[200];

    for (int i = 0; i < 200; i++) {
        snprintf(buf, sizeof(buf), "slot_%03d", i);
        if (expect_ok("intern_many insert",
                      ds_rete_intern_cstr(t, buf, &ptrs[i]))) return 1;
    }
    /* Verify all pointers are still stable after rehashing. */
    for (int i = 0; i < 200; i++) {
        snprintf(buf, sizeof(buf), "slot_%03d", i);
        const char *p;
        ds_rete_intern_cstr(t, buf, &p);
        if (p != ptrs[i]) {
            fprintf(stderr, "FAIL: intern_many: slot_%03d pointer changed\n", i);
            return 1;
        }
    }
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_intern_null_rejection(void)
{
    ds_rete_intern_t *t = NULL;
    ds_rete_intern_init(&t);
    const char *out;
    if (expect_status("intern NULL str",
                      ds_rete_intern_cstr(t, NULL, &out),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("intern NULL out",
                      ds_rete_intern_cstr(t, "x", NULL),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("intern NULL table",
                      ds_rete_intern_cstr(NULL, "x", &out),
                      DS_ERR_INVAL)) return 1;
    ds_rete_intern_destroy(t);
    return 0;
}

static int test_engine_create_destroy(void)
{
    ds_rete_engine_t *e = NULL;
    if (expect_ok("engine_create", ds_rete_engine_create(&e))) return 1;
    if (!e) return fail("engine_create: out is NULL after OK");
    if (expect_ok("engine_destroy", ds_rete_engine_destroy(e))) return 1;
    return 0;
}

static int test_engine_destroy_null(void)
{
    /* Destroying NULL must be a no-op. */
    if (expect_ok("destroy NULL", ds_rete_engine_destroy(NULL))) return 1;
    return 0;
}

static int test_engine_create_null_rejection(void)
{
    if (expect_status("create NULL out",
                      ds_rete_engine_create(NULL),
                      DS_ERR_INVAL)) return 1;
    return 0;
}

static int test_engine_default_clock(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    int64_t t1 = ds_rete_now_ns(e);
    int64_t t2 = ds_rete_now_ns(e);
    if (t1 <= 0) return fail("default clock: non-positive value");
    if (t2 < t1)  return fail("default clock: time went backwards");
    ds_rete_engine_destroy(e);
    return 0;
}

static int64_t mock_clock_fn(void *ctx)
{
    return *(int64_t *)ctx;
}

static int test_engine_mock_clock(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    int64_t mock_time = 42000000000LL;
    if (expect_ok("set_clock",
                  ds_rete_set_clock(e, mock_clock_fn, &mock_time))) return 1;
    if (ds_rete_now_ns(e) != 42000000000LL)
        return fail("mock clock: wrong value after set");
    mock_time = 99000000000LL;
    if (ds_rete_now_ns(e) != 99000000000LL)
        return fail("mock clock: value did not update");
    ds_rete_engine_destroy(e);
    return 0;
}

static int test_engine_clock_null_rejection(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    if (expect_status("set_clock NULL fn",
                      ds_rete_set_clock(e, NULL, NULL),
                      DS_ERR_INVAL)) return 1;
    if (expect_status("set_clock NULL engine",
                      ds_rete_set_clock(NULL, mock_clock_fn, NULL),
                      DS_ERR_INVAL)) return 1;
    ds_rete_engine_destroy(e);
    return 0;
}

static const char *g_last_rule = NULL;
static int         g_before_count = 0;
static int         g_after_count  = 0;

static void before_hook(const char *rule_name, void *ctx)
{
    (void)ctx;
    g_last_rule = rule_name;
    g_before_count++;
}
static void after_hook(const char *rule_name, void *ctx)
{
    (void)ctx;
    (void)rule_name;
    g_after_count++;
}

static int test_engine_fire_hooks(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);

    if (expect_ok("set_before_fire",
                  ds_rete_set_before_fire(e, before_hook, NULL))) return 1;
    if (expect_ok("set_after_fire",
                  ds_rete_set_after_fire(e, after_hook, NULL))) return 1;

    /* Hooks are registered; simulate a call as the firing loop would. */
    g_before_count = g_after_count = 0;
    e->before_fire("test_rule", e->fire_hook_ctx);
    e->after_fire("test_rule",  e->fire_hook_ctx);

    if (g_before_count != 1) return fail("before hook not called once");
    if (g_after_count  != 1) return fail("after hook not called once");
    if (strcmp(g_last_rule, "test_rule") != 0)
        return fail("before hook: wrong rule name");

    /* Clear hooks (NULL is allowed). */
    if (expect_ok("clear before_fire",
                  ds_rete_set_before_fire(e, NULL, NULL))) return 1;
    if (e->before_fire != NULL)
        return fail("before_fire should be NULL after clear");

    ds_rete_engine_destroy(e);
    return 0;
}

static int test_engine_isolation(void)
{
    ds_rete_engine_t *e1 = NULL, *e2 = NULL;
    ds_rete_engine_create(&e1);
    ds_rete_engine_create(&e2);

    /* Two engines must be distinct allocations. */
    if (e1 == e2) return fail("isolation: same pointer for two engines");

    /* Intern tables must be independent. */
    const char *p1, *p2;
    ds_rete_intern_cstr(e1->intern, "shared_name", &p1);
    ds_rete_intern_cstr(e2->intern, "shared_name", &p2);
    if (p1 == p2)
        return fail("isolation: intern tables share memory");

    /* Mock clock on one must not affect the other. */
    int64_t mock = 555LL;
    ds_rete_set_clock(e1, mock_clock_fn, &mock);
    int64_t t2 = ds_rete_now_ns(e2);
    if (t2 == 555LL)
        return fail("isolation: clock bleed between engines");

    ds_rete_engine_destroy(e1);
    ds_rete_engine_destroy(e2);
    return 0;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_engine_basic ===\n");

    RUN(test_intern_basic);
    RUN(test_intern_empty_string);
    RUN(test_intern_many);
    RUN(test_intern_null_rejection);

    RUN(test_engine_create_destroy);
    RUN(test_engine_destroy_null);
    RUN(test_engine_create_null_rejection);

    RUN(test_engine_default_clock);
    RUN(test_engine_mock_clock);
    RUN(test_engine_clock_null_rejection);

    RUN(test_engine_fire_hooks);
    RUN(test_engine_isolation);

#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_engine_basic: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_engine_basic: %d FAILED ===\n", fail_count);
    return 1;
}

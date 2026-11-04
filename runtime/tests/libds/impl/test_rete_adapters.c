/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The action-verb adapters, called through their dispatch slots:
 *   - ds-publish asserts nothing ([LTIE.4.3]) and hands the schema and the
 *     values to the publish callback;
 *   - ds-log reaches the log callback with its level, category and message;
 *   - ds-call reaches the call callback, or is DS_ERR_STORAGE_UNAVAILABLE;
 *   - ds-cache-get/set/delete reach the cache callbacks;
 *   - ds-rate-allow suppresses within its cooldown, keyed exactly.
 * FN_EMIT is a `none` row of [RDSC.4a.9.5] with no adapter
 * (test_rdsc_4a_9_5_operands).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "fn.h"
#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

#define WM_TOMB ((ds_rete_fact_t *)(uintptr_t)1)

static int fail(const char *msg) { fprintf(stderr, "FAIL: %s\n", msg); return 1; }
static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: %d (%s)\n", what, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

static ds_rete_engine_t *make_engine_with_schema(ds_rete_schema_t **out_schema)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_slot_desc_t slots[] = {
        { .name="val", .type=DS_RETE_VAL_INT, .is_key=true }
    };
    ds_rete_schema_register(e, "Thing", DS_RETE_SCOPE_PLAIN, 0, slots, 1, out_schema);
    return e;
}

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p; ds_rete_intern_cstr(e->intern, s, &p); return p;
}

/* Calls an adapter through its dispatch slot; its status is kept in
   g_last_fn_result. */
static ds_result_t g_last_fn_result;

static ds_rete_val_t call_adapter(ds_rete_engine_t *e, ds_builtin_fn_t op,
                                   ds_rete_val_t *args, uint32_t argc)
{
    const ds_fn_slot_t *slot = ds_lookup_fn(op);
    if (!slot) { g_last_fn_result = DS_ERR_R(DS_ERR_NOT_FOUND, "op"); return ds_rete_val_null(); }
    ds_rete_eval_ctx_t ctx = { .engine = e };
    ds_rete_val_t result = ds_rete_val_null();
    g_last_fn_result = slot->fn(e, &ctx, args, argc, &result);
    return result;
}

static int count_schema_facts(ds_rete_engine_t *e,
                               const ds_rete_schema_t *s, int64_t val)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&e->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&e->wm_map, i);
        if (!f) continue;
        if (f->schema == s && f->slots[0].i == val) n++;
    }
    return n;
}

static int g_publish_count = 0;
static const ds_rete_schema_t *g_publish_schema = NULL;
static int64_t g_publish_val = 0;
static ds_result_t publish_cb(ds_rete_engine_t *e, const ds_rete_schema_t *s,
                              const ds_rete_val_t *slots, void *u)
{
    (void)e; (void)u;
    g_publish_count++;
    g_publish_schema = s;
    g_publish_val = (slots[0].kind == DS_RETE_VAL_INT) ? slots[0].i : -1;
    return DS_OK_R;
}

/* [LTIE.4.3]: ds-publish puts nothing in working memory; the callback gets
   the schema and one value per slot. */
static int test_ds_publish(void)
{
    ds_rete_schema_t *schema = NULL;
    ds_rete_engine_t *e = make_engine_with_schema(&schema);
    g_publish_count = 0;
    g_publish_schema = NULL;
    g_publish_val = 0;

    ds_rete_adapter_config_t cfg = { .publish_cb = publish_cb };
    ds_rete_register_adapters(e, &cfg);

    ds_rete_val_t args[2] = {
        ds_rete_val_str(istr(e, "Thing"), 5),
        ds_rete_val_int(99),
    };
    ds_rete_val_t r = call_adapter(e, DS_FN_PUBLISH, args, 2);

    int n = count_schema_facts(e, schema, 99);
    ds_rete_engine_destroy(e);

    if (r.kind != DS_RETE_VAL_BOOL || !r.b) return fail("ds-publish: returned false");
    if (n != 0)                              return fail("ds-publish: a fact entered WM");
    if (g_publish_count != 1)               return fail("ds-publish: callback not called");
    if (g_publish_schema != schema)         return fail("ds-publish: callback's schema");
    if (g_publish_val != 99)                return fail("ds-publish: callback's value");
    return 0;
}

static ds_log_level_t g_log_level;
static const char    *g_log_cat = NULL;
static const char    *g_log_msg = NULL;

static ds_result_t log_cb(ds_rete_engine_t *e, const ds_rete_log_event_t *ev, void *u)
{
    (void)e; (void)u;
    g_log_level = ev->level;
    g_log_cat   = ev->category;
    g_log_msg   = ev->message;
    return DS_OK_R;
}

static int test_ds_log(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    g_log_level = -1; g_log_cat = NULL; g_log_msg = NULL;

    ds_rete_adapter_config_t cfg = { .log_cb = log_cb };
    ds_rete_register_adapters(e, &cfg);

    ds_rete_val_t args[3] = {
        ds_rete_val_int(1),  /* DS_LOG_INFO */
        ds_rete_val_str(istr(e, "rules"), 5),
        ds_rete_val_str(istr(e, "hello world"), 11),
    };
    call_adapter(e, DS_FN_LOG, args, 3);

    /* Compare before engine_destroy: strings are interned. */
    int ok_lv  = (g_log_level == DS_LOG_INFO);
    int ok_cat = (g_log_cat && strcmp(g_log_cat, "rules") == 0);
    int ok_msg = (g_log_msg && strcmp(g_log_msg, "hello world") == 0);
    ds_rete_engine_destroy(e);

    if (!ok_lv)  return fail("ds-log: wrong level");
    if (!ok_cat) return fail("ds-log: wrong category");
    if (!ok_msg) return fail("ds-log: wrong message");
    return 0;
}

static const char *g_call_service = NULL;
static ds_result_t call_cb(ds_rete_engine_t *e, const ds_rete_call_request_t *req, void *u)
{
    (void)e; (void)u; g_call_service = req->service; return DS_OK_R;
}

static int test_ds_call(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    g_call_service = NULL;

    ds_rete_adapter_config_t cfg = { .call_cb = call_cb };
    ds_rete_register_adapters(e, &cfg);

    /* The service and the correlation, and no kwargs: 2 + 2n with n = 0
       ([RDSC.4a.9.4]). */
    ds_rete_val_t args[2] = {
        ds_rete_val_str(istr(e, "weather.get"), 11),
        ds_rete_val_str(istr(e, "req-1"),       5),
    };
    ds_rete_val_t r = call_adapter(e, DS_FN_CALL, args, 2);
    int ok_r   = (r.kind == DS_RETE_VAL_BOOL && r.b);
    int ok_svc = (g_call_service && strcmp(g_call_service, "weather.get") == 0);
    ds_rete_engine_destroy(e);

    if (!ok_r)   return fail("ds-call: returned false");
    if (!ok_svc) return fail("ds-call: wrong service");
    return 0;
}

static int test_ds_call_no_cb(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    ds_rete_register_adapters(e, NULL);
    ds_rete_val_t args[2] = {
        ds_rete_val_str(istr(e, "svc"), 3),
        ds_rete_val_str(istr(e, "c"),   1),
    };
    ds_rete_val_t r = call_adapter(e, DS_FN_CALL, args, 2);
    ds_rete_engine_destroy(e);
    if (g_last_fn_result.status != DS_ERR_STORAGE_UNAVAILABLE)
        return fail("ds-call no-cb: expected STORAGE_UNAVAILABLE");
    return 0;
}

static char g_cache_store[64];
static ds_result_t cache_get(ds_rete_engine_t *e, const char *k,
                              char **out, void *u)
{
    (void)e; (void)u;
    if (strcmp(k, "mykey") == 0 && g_cache_store[0]) {
        *out = strdup(g_cache_store);
    } else {
        *out = NULL;
    }
    return DS_OK_R;
}
static ds_result_t cache_set(ds_rete_engine_t *e, const char *k,
                              const char *v, uint64_t ttl, void *u)
{
    (void)e; (void)ttl; (void)u;
    if (strcmp(k, "mykey") == 0 && v) strncpy(g_cache_store, v, 63);
    return DS_OK_R;
}
static ds_result_t cache_del(ds_rete_engine_t *e, const char *k, void *u)
{
    (void)e; (void)u;
    if (strcmp(k, "mykey") == 0) g_cache_store[0] = '\0';
    return DS_OK_R;
}

static int test_ds_cache(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    memset(g_cache_store, 0, sizeof(g_cache_store));

    ds_rete_adapter_config_t cfg = {
        .cache_get_cb = cache_get,
        .cache_set_cb = cache_set,
        .cache_delete_cb = cache_del,
    };
    ds_rete_register_adapters(e, &cfg);

    /* A miss is null, not Bool(false) ([LGRA.2.9.6.2]). */
    ds_rete_val_t gargs[1] = { ds_rete_val_str(istr(e, "mykey"), 5) };
    ds_rete_val_t r = call_adapter(e, DS_FN_CACHE_GET, gargs, 1);
    if (r.kind != DS_RETE_VAL_NULL) { ds_rete_engine_destroy(e); return fail("cache get miss"); }

    ds_rete_val_t sargs[3] = {
        ds_rete_val_str(istr(e, "mykey"),  5),
        ds_rete_val_str(istr(e, "\"hi\""), 4),
        ds_rete_val_int(0),
    };
    call_adapter(e, DS_FN_CACHE_SET, sargs, 3);

    /* A hit is an interned string, compared before the engine is freed. */
    ds_rete_val_t r2 = call_adapter(e, DS_FN_CACHE_GET, gargs, 1);
    int hit_ok = (r2.kind == DS_RETE_VAL_STR && strcmp(r2.s.ptr, "\"hi\"") == 0);
    if (!hit_ok) { ds_rete_engine_destroy(e); return fail("cache get hit"); }

    call_adapter(e, DS_FN_CACHE_DELETE, gargs, 1);
    ds_rete_val_t r3 = call_adapter(e, DS_FN_CACHE_GET, gargs, 1);
    if (r3.kind != DS_RETE_VAL_NULL) { ds_rete_engine_destroy(e); return fail("cache post-delete"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* The interpreted path refuses what the AOT path's ds_dispatcher_cache_set
   refuses ([IDSP.7.10]): a negative ttl and a value that is not JSON. The
   checks are in adapter_ds_cache_set because bridge_cache_set takes a
   uint64_t, where a negative ttl is already a huge positive one. No compiled
   rule reaches either case; this pins the two paths' agreement. */
static int test_ds_cache_set_rejections(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    memset(g_cache_store, 0, sizeof(g_cache_store));

    ds_rete_adapter_config_t cfg = {
        .cache_get_cb = cache_get,
        .cache_set_cb = cache_set,
        .cache_delete_cb = cache_del,
    };
    ds_rete_register_adapters(e, &cfg);

    /* Negative ttl → refused, and nothing written. */
    ds_rete_val_t neg[3] = {
        ds_rete_val_str(istr(e, "mykey"),  5),
        ds_rete_val_str(istr(e, "\"hi\""), 4),
        ds_rete_val_int(-1),
    };
    call_adapter(e, DS_FN_CACHE_SET, neg, 3);
    if (g_cache_store[0] != '\0') {
        ds_rete_engine_destroy(e); return fail("negative ttl was written");
    }

    /* Not JSON → refused, and nothing written. */
    ds_rete_val_t bad[3] = {
        ds_rete_val_str(istr(e, "mykey"),     5),
        ds_rete_val_str(istr(e, "{not json"), 9),
        ds_rete_val_int(0),
    };
    call_adapter(e, DS_FN_CACHE_SET, bad, 3);
    if (g_cache_store[0] != '\0') {
        ds_rete_engine_destroy(e); return fail("bad JSON was written");
    }

    /* ttl 0, no ttl, stays legal. */
    ds_rete_val_t ok[3] = {
        ds_rete_val_str(istr(e, "mykey"),  5),
        ds_rete_val_str(istr(e, "\"hi\""), 4),
        ds_rete_val_int(0),
    };
    call_adapter(e, DS_FN_CACHE_SET, ok, 3);
    if (strcmp(g_cache_store, "\"hi\"") != 0) {
        ds_rete_engine_destroy(e); return fail("valid write refused");
    }

    ds_rete_engine_destroy(e);
    return 0;
}

static int64_t g_mock_time = 0;
static int64_t mock_clock_rate(void *c) { (void)c; return g_mock_time; }

static int test_ds_rate_allow(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    ds_rete_register_adapters(e, NULL);

    g_mock_time = 1000000000LL; /* 1 second */
    ds_rete_set_clock(e, mock_clock_rate, NULL);

    const char *rname = istr(e, "test_rule");
    int64_t cooldown = 500000000LL; /* 500ms */

    /* Call shape: (rule_name, cooldown_ns) — no key args. */
    ds_rete_val_t args[2] = {
        ds_rete_val_str(rname, (uint32_t)strlen(rname)),
        ds_rete_val_int(cooldown),
    };
    ds_rete_val_t r = call_adapter(e, DS_FN_RATE_ALLOW, args, 2);
    if (r.kind != DS_RETE_VAL_BOOL || !r.b) { ds_rete_engine_destroy(e); return fail("rate-allow: first call not allowed"); }

    /* Second call immediately: still in cooldown → suppressed. */
    r = call_adapter(e, DS_FN_RATE_ALLOW, args, 2);
    if (r.kind != DS_RETE_VAL_BOOL || r.b)  { ds_rete_engine_destroy(e); return fail("rate-allow: second call not suppressed"); }

    /* Advance time past cooldown. */
    g_mock_time += 600000000LL;
    r = call_adapter(e, DS_FN_RATE_ALLOW, args, 2);
    if (r.kind != DS_RETE_VAL_BOOL || !r.b) { ds_rete_engine_destroy(e); return fail("rate-allow: after cooldown not allowed"); }

    ds_rete_engine_destroy(e);
    return 0;
}

/* One call of the gate with a single key value and a 500ms cooldown; true iff
   it allowed. At one instant, a key seen before is suppressed and a new key is
   allowed, so the answer says whether the key is new. */
static bool rate_allows_key(ds_rete_engine_t *e, const char *rname,
                            ds_rete_val_t key)
{
    ds_rete_val_t args[3] = {
        ds_rete_val_str(rname, (uint32_t)strlen(rname)),
        key,
        ds_rete_val_int(500000000LL),
    };
    ds_rete_val_t r = call_adapter(e, DS_FN_RATE_ALLOW, args, 3);
    return r.kind == DS_RETE_VAL_BOOL && r.b;
}

/* [IRET.25.5.3]: the key is compared component by component, representation
   and value, exact and whole. */
static int test_ds_rate_allow_key_identity(void)
{
    ds_rete_engine_t *e = NULL; ds_rete_engine_create(&e);
    ds_rete_register_adapters(e, NULL);
    g_mock_time = 1000000000LL;
    ds_rete_set_clock(e, mock_clock_rate, NULL);
    const char *rname = istr(e, "key_rule");

    /* 1, "1" and true: three keys. */
    const char *one = istr(e, "1");
    if (!rate_allows_key(e, rname, ds_rete_val_int(1)))
        return fail("rate key: first Int 1 not allowed");
    if (!rate_allows_key(e, rname, ds_rete_val_str(one, 1)))
        return fail("rate key: String \"1\" shared Int 1's key");
    if (!rate_allows_key(e, rname, ds_rete_val_bool(true)))
        return fail("rate key: true shared a key with 1 or \"1\"");
    if (rate_allows_key(e, rname, ds_rete_val_int(1)))
        return fail("rate key: a repeated Int 1 was not suppressed");

    /* Floats: no rounding, no clamp above 1e15; -0.0 and 0.0 are one key. */
    if (!rate_allows_key(e, rname, ds_rete_val_float(1.0000001)) ||
        !rate_allows_key(e, rname, ds_rete_val_float(1.0000002)))
        return fail("rate key: floats differing in the 7th decimal collided");
    if (!rate_allows_key(e, rname, ds_rete_val_float(2e15)) ||
        !rate_allows_key(e, rname, ds_rete_val_float(3e15)))
        return fail("rate key: floats above 1e15 collided");
    if (!rate_allows_key(e, rname, ds_rete_val_float(0.0)))
        return fail("rate key: first 0.0 not allowed");
    if (rate_allows_key(e, rname, ds_rete_val_float(-0.0)))
        return fail("rate key: -0.0 was a different key from 0.0");

    /* null is not the empty string. */
    const char *empty = istr(e, "");
    if (!rate_allows_key(e, rname, ds_rete_val_null()) ||
        !rate_allows_key(e, rname, ds_rete_val_str(empty, 0)))
        return fail("rate key: null and \"\" collided");

    /* No length limit: strings differing only at byte 600. */
    char a[602], b[602];
    memset(a, 'x', 600); memset(b, 'x', 600);
    a[600] = 'a'; b[600] = 'b'; a[601] = b[601] = '\0';
    if (!rate_allows_key(e, rname, ds_rete_val_str(istr(e, a), 601)) ||
        !rate_allows_key(e, rname, ds_rete_val_str(istr(e, b), 601)))
        return fail("rate key: strings differing after byte 511 collided");

    ds_rete_engine_destroy(e);
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

    printf("=== test_rete_adapters ===\n");
    RUN(test_ds_publish);
    RUN(test_ds_log);
    RUN(test_ds_call);
    RUN(test_ds_call_no_cb);
    RUN(test_ds_cache);
    RUN(test_ds_cache_set_rejections);
    RUN(test_ds_rate_allow);
    RUN(test_ds_rate_allow_key_identity);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_adapters: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_adapters: %d FAILED ===\n", fail_count);
    return 1;
}

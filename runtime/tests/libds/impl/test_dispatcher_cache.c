/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_dispatcher_cache — the IMPL path of the cache verbs ([IDSP.7.10]).
 *
 * spec/test_cache_spec drives the verbs through a compiled .dsc; this calls
 * ds_dispatcher_cache_set() / _delete() directly and reads engine->cache back
 * through cache.h, to show the ENGINE's cache is the authority and the
 * persistence callback a mirror of it ([LSTO.4.7.2]).
 *
 * The clause's "per-verb arity / type rejection" is not reachable from here:
 * the C signature fixes the arity. The compile-error corpus has it.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "cache.h"
#include "dispatcher.h"
#include "engine.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

/* ---- probes ---------------------------------------------------------- */

typedef struct {
    int         n_set;
    int         n_delete;
    char        last_key[64];
    uint64_t    last_ttl;
    int         last_tree_was_null;
    ds_result_t next_return;
} persist_probe_t;

static ds_result_t set_cb(ds_engine_t *e, const ds_cache_write_t *write, void *user)
{
    (void) e;
    persist_probe_t *p = (persist_probe_t *) user;
    p->n_set++;
    p->last_key[0] = '\0';
    if (write->key) strncpy(p->last_key, write->key, sizeof(p->last_key) - 1);
    p->last_ttl = write->ttl_ns;
    p->last_tree_was_null = (write->value == NULL);
    return p->next_return;
}

typedef struct {
    int  n_action_set;
    int  n_action_delete;
    int  n_action_get;
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    stream_probe_t *p = (stream_probe_t *) user;
    switch (ev->kind) {
    case DS_EV_ACTION_CACHE_SET:    p->n_action_set++;    break;
    case DS_EV_ACTION_CACHE_DELETE: p->n_action_delete++; break;
    case DS_EV_ACTION_CACHE_GET:    p->n_action_get++;    break;
    default: break;
    }
    return DS_OK_R;
}

static ds_engine_t *new_engine(void)
{
    ds_engine_t *e = NULL;
    ds_result_t  r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK || e == NULL) {
        fprintf(stderr, "FAIL: ds_engine_new: status=%d (%s)\n",
                r.status, r.detail ? r.detail : "(null)");
        return NULL;
    }
    return e;
}

/* Read engine->cache directly — the authority the verbs write to. */
static bool cache_hit_is(ds_engine_t *e, const char *key, const char *want)
{
    uint64_t now = 0;
    ds_clock_now_ns(&e->clock, &now);
    const char *v = NULL;
    if (!ds_cache_get(&e->cache, key, now, &v, NULL) || v == NULL) return false;
    return strcmp(v, want) == 0;
}

static bool cache_miss(ds_engine_t *e, const char *key)
{
    uint64_t now = 0;
    ds_clock_now_ns(&e->clock, &now);
    const char *v = NULL;
    return !ds_cache_get(&e->cache, key, now, &v, NULL);
}

/* ---- volatile round-trip with NO callback wired ---------------------- */

static void test_volatile_round_trip(void)
{
    /* A set with no persistence callback is a successful VOLATILE write, not
       DS_ERR_STORAGE_UNAVAILABLE. */
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    CHECK(ds_dispatcher_cache_set(e, "k1", "{\"v\":1}", 0).status == DS_OK,
          "set with no callback is OK");
    CHECK(cache_hit_is(e, "k1", "{\"v\":1}"),
          "the engine cache holds the value verbatim");
    CHECK(cache_miss(e, "absent"), "a miss is distinguishable from a hit");

    CHECK(ds_dispatcher_cache_delete(e, "k1").status == DS_OK,
          "delete with no callback is OK");
    CHECK(cache_miss(e, "k1"), "and the entry is gone");

    /* Deleting an absent key is a no-op, not an error. */
    CHECK(ds_dispatcher_cache_delete(e, "never_there").status == DS_OK,
          "delete of an absent key is OK");
    ds_engine_free(e);
}

/* ---- the persistence hooks are a mirror, and optional ---------------- */

static void test_persistence_hooks(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    persist_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, set_cb, NULL, &p).status == DS_OK,
          "wire the set hook only");

    CHECK(ds_dispatcher_cache_set(e, "k1", "{\"v\":1}", 5000).status == DS_OK, "set");
    CHECK(p.n_set == 1, "set hook fired");
    CHECK(strcmp(p.last_key, "k1") == 0, "with the key");
    CHECK(p.last_ttl == 5000, "and the ttl");
    CHECK(!p.last_tree_was_null, "and a parsed tree for valid JSON");

    /* The delete hook is NULL here — a missing hook is silence, not an error. */
    CHECK(ds_dispatcher_cache_delete(e, "k1").status == DS_OK,
          "delete with no delete hook is OK");
    CHECK(cache_miss(e, "k1"), "and still deletes from the engine cache");
    ds_engine_free(e);
}

/* ---- a hook error propagates and does NOT roll back ------------------ */

static void test_hook_error_no_rollback(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    persist_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_ERR_IO };
    CHECK(ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, set_cb, NULL, &p).status == DS_OK,
          "wire a failing set hook");

    ds_result_t r = ds_dispatcher_cache_set(e, "k1", "{\"v\":1}", 0);
    CHECK(r.status == DS_ERR_IO, "the hook's error propagates");
    CHECK(p.n_set == 1, "the hook ran");
    /* [LSTO.4.7.2] — the engine cache is authoritative and is NOT rolled back.
       The write happened; only the mirror failed. */
    CHECK(cache_hit_is(e, "k1", "{\"v\":1}"),
          "and the engine cache keeps the value anyway");
    ds_engine_free(e);
}

/* ---- ACTION_CACHE_SET / _DELETE fire; _GET does not ------------------ */

static void test_action_events(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    stream_probe_t s = {0};
    CHECK(ds_engine_set_stream_callback(e, stream_cb, &s).status == DS_OK,
          "attach stream");

    CHECK(ds_dispatcher_cache_set(e, "k1", "{\"v\":1}", 0).status == DS_OK, "set");
    CHECK(s.n_action_set == 1, "ACTION_CACHE_SET fired on the engine write");

    CHECK(ds_dispatcher_cache_delete(e, "k1").status == DS_OK, "delete");
    CHECK(s.n_action_delete == 1, "ACTION_CACHE_DELETE fired");

    /* A read is not a write, and the dispatcher has no get entry point —
       nothing on this path emits ACTION_CACHE_GET. */
    (void) cache_miss(e, "k1");
    CHECK(s.n_action_get == 0, "ACTION_CACHE_GET is not emitted by these verbs");
    ds_engine_free(e);
}

/* ---- negative ttl and bad JSON are REJECTED, and nothing is written -- */

static void test_negative_ttl_and_bad_json_are_rejected(void)
{
    /* [IDSP.7.10]'s "negative ttl and bad-JSON rejected": the status, and
       the cache UNMUTATED afterwards. */
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    persist_probe_t p = {0};
    p.next_return = (ds_result_t){ .status = DS_OK };
    CHECK(ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, set_cb, NULL, &p).status == DS_OK,
          "wire the set hook");

    CHECK(ds_dispatcher_cache_set(e, "neg", "{\"v\":1}", -1).status == DS_ERR_INVAL,
          "a negative ttl is refused");
    CHECK(!cache_hit_is(e, "neg", "{\"v\":1}"), "and nothing was written");
    CHECK(p.n_set == 0, "the persistence hook was never reached");

    CHECK(ds_dispatcher_cache_set(e, "bad", "{not json", 0).status == DS_ERR_INVAL,
          "a malformed value is refused");
    CHECK(!cache_hit_is(e, "bad", "{not json"), "and nothing was written");
    CHECK(p.n_set == 0, "the hook was not reached for that one either");

    /* ttl == 0 is not negative and stays legal — it means no expiry, and
       conflating "no ttl" with "bad ttl" would break every untimed write. */
    CHECK(ds_dispatcher_cache_set(e, "zero", "{\"v\":2}", 0).status == DS_OK,
          "a zero ttl is still accepted");
    CHECK(cache_hit_is(e, "zero", "{\"v\":2}"), "and is written");
    ds_engine_free(e);
}

/* ---- NULL key is INVAL on both verbs --------------------------------- */

static void test_null_key(void)
{
    ds_engine_t *e = new_engine();
    if (!e) { g_fails++; return; }

    CHECK(ds_dispatcher_cache_set(e, NULL, "{}", 0).status == DS_ERR_INVAL,
          "set with a NULL key is INVAL");
    CHECK(ds_dispatcher_cache_delete(e, NULL).status == DS_ERR_INVAL,
          "delete with a NULL key is INVAL");
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_dispatcher_cache ===\n");
    test_volatile_round_trip();
    test_persistence_hooks();
    test_hook_error_no_rollback();
    test_action_events();
    test_negative_ttl_and_bad_json_are_rejected();
    test_null_key();
    if (g_fails) {
        fprintf(stderr, "test_dispatcher_cache: %d FAILURE(S)\n", g_fails);
        return 1;
    }
    printf("=== test_dispatcher_cache: ALL PASSED ===\n");
    return 0;
}

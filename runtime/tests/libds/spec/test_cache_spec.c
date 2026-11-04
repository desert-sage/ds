/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Spec conformance for the cache verbs.
 *
 * Spec: IDSP.7 (IDSP.7.10 test contract); [NCBK.7] / [LSTO.4.7] /
 *       [RARC.5.7.9].
 *
 * The cache is engine-owned state, not integrator storage:
 *   - write:  `cache key: "<k>" value: <v> [ttl: <dur>]`   (action verb)
 *   - delete: `cache_delete key: "<k>"`                    (action verb)
 *   - read:   `let x = cached("<k>")`                       (sync let-RHS
 *             expression, LGRA.9.8 — the entire RHS of a `let`, a real action
 *             must follow it per the rule grammar). Returns the stored value on
 *             a hit and FALSE on a miss.
 *
 * The authoritative cache lives inside the engine (peer of working memory) and
 * is mutated ONLY by `cache` / `cache_delete` on the deterministic input
 * stream. A read is a pure engine-local lookup — there is NO read callback,
 * and it is NOT a recorded output (DS_EV_ACTION_CACHE_GET stays reserved but is
 * never emitted, [RARC.5.7.9] / [RFCS.15.7]). Writes/deletes record
 * DS_EV_ACTION_CACHE_{SET,DELETE} and then mirror to an OPTIONAL outbound
 * persistence hook (ds_engine_cache_callbacks(set_cb, delete_cb, user)); NULL
 * hooks ⇒ a volatile in-engine cache, and no error. The hook
 * is never a second writer: the engine mutates first and does NOT roll back on
 * a hook failure ([LSTO.4.7.2]).
 *
 * Since a read has no callback, the value read back is observed the only way
 * the public surface allows: a reader rule gates a literal `log critical "HIT"`
 * on a `where` cache read, `Trig t where t.tag == "r" and cached("k") == "1"`
 * (LSTO.4.3.1a). A hit satisfies the gate and the rule fires, logging "HIT"; a
 * miss returns FALSE (compares unequal to everything) so the rule does not fire
 * and nothing is logged. A CRITICAL-filtered log callback captures the outcome.
 *
 * Public API only.
 */
#include "spec_common.h"

/* ============== Test integrator: outbound persistence sink ==============
 * Records set/delete hook invocations and can inject an error return. There is
 * deliberately NO get hook — reads never leave the engine. */

typedef struct {
    int            n_set_calls;
    int            n_delete_calls;
    char           last_set_key[64];
    uint64_t       last_set_ttl_ns;
    ds_json_kind_t last_set_value_kind;
    const ds_json_t *last_set_tree_ptr;
    char           last_delete_key[64];
    ds_cache_removal_reason_t last_delete_reason;
    /* Optional injected error returns (probe the propagate/no-rollback path). */
    ds_result_t    next_set_return;
    ds_result_t    next_delete_return;
} store_t;

/* Kind of a possibly-NULL Json node (NULL → DS_JSON_NULL) via the opaque API. */
static ds_json_kind_t json_kind_or_null(const ds_json_t *n)
{
    ds_json_kind_t kind = DS_JSON_NULL;
    if (n != NULL) ds_json_get_kind(n, &kind);
    return kind;
}

static ds_result_t set_cb(ds_engine_t *e, const ds_cache_write_t *w, void *u)
{
    (void) e;
    store_t *s = (store_t *) u;
    s->n_set_calls++;
    s->last_set_key[0] = '\0';
    if (w->key) strncpy(s->last_set_key, w->key, sizeof(s->last_set_key) - 1);
    s->last_set_ttl_ns     = w->ttl_ns;
    s->last_set_tree_ptr   = w->value;
    s->last_set_value_kind = json_kind_or_null(w->value);
    if (s->next_set_return.status != DS_OK) return s->next_set_return;
    return DS_OK_R;
}

static ds_result_t delete_cb(ds_engine_t *e, const ds_cache_removal_t *rm,
                             void *u)
{
    (void) e;
    const char *k = rm ? rm->key : NULL;
    store_t *s = (store_t *) u;
    s->n_delete_calls++;
    s->last_delete_reason = rm ? rm->reason : DS_CACHE_REMOVED_DELETE;
    s->last_delete_key[0] = '\0';
    if (k) strncpy(s->last_delete_key, k, sizeof(s->last_delete_key) - 1);
    if (s->next_delete_return.status != DS_OK) return s->next_delete_return;
    return DS_OK_R;
}

/* ====== Critical-log probe — observes cached() read-back ==============
 *
 * It filters on level: the log callback also receives the engine's own logs,
 * and a fixture's `log critical` is the only CRITICAL here. */
typedef struct {
    int  n_hit;
    char last_msg[128];
} hit_probe_t;

static ds_result_t hit_log_cb(ds_engine_t *e, const ds_log_event_t *ev, void *u)
{
    (void) e;
    if (!ev || ev->level != DS_LOG_CRITICAL) return DS_OK_R;
    hit_probe_t *a = (hit_probe_t *) u;
    a->n_hit++;
    a->last_msg[0] = '\0';
    if (ev->message)
        strncpy(a->last_msg, ev->message, sizeof(a->last_msg) - 1);
    return DS_OK_R;
}

/* ============== Stream probe ============== */

typedef struct {
    int n_get;              /* must stay 0 — reads are not recorded */
    int n_set;
    int n_delete;
    int n_other_action;
    char           last_set_key[64];
    uint64_t       last_set_ttl;
    ds_json_kind_t last_set_value_kind;
    char           last_delete_key[64];
} stream_probe_t;

static ds_result_t stream_cb(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void) e;
    stream_probe_t *s = (stream_probe_t *) u;
    switch (ev->kind) {
    case DS_EV_ACTION_CACHE_GET:
        /* Reserved-but-never-emitted ([RARC.5.7.9]); reaching here is a bug. */
        s->n_get++;
        break;
    case DS_EV_ACTION_CACHE_SET:
        s->n_set++;
        s->last_set_key[0] = '\0';
        if (ev->p.action_cache_set.key)
            strncpy(s->last_set_key, ev->p.action_cache_set.key,
                    sizeof(s->last_set_key) - 1);
        s->last_set_ttl = ev->p.action_cache_set.ttl_ns;
        s->last_set_value_kind =
            json_kind_or_null(ev->p.action_cache_set.value);
        break;
    case DS_EV_ACTION_CACHE_DELETE:
        s->n_delete++;
        s->last_delete_key[0] = '\0';
        if (ev->p.action_cache_delete.key)
            strncpy(s->last_delete_key, ev->p.action_cache_delete.key,
                    sizeof(s->last_delete_key) - 1);
        break;
    case DS_EV_FACT_ASSERT:
    case DS_EV_FACT_RETRACT:
    case DS_EV_RULE_LHS_FACTS:
    case DS_EV_RULE_FIRE_BEGIN:
    case DS_EV_RULE_FIRE_END:
    case DS_EV_ACTION_LOG:
    /* A TICK is the engine's clock sample and a PUMP a pump beginning
       ([NCBK.2.3]): not actions. n_other_action catches unexpected ones. */
    case DS_EV_TICK:
    case DS_EV_PUMP:
        break;
    default:
        s->n_other_action++;
    }
    return DS_OK_R;
}

/* ============== Per-scenario fixture ==============
 * Loads a DS program, finds Trig (one STRING "tag" key), then registers the
 * stream + log callbacks and the OPTIONAL persistence-cb bundle AFTER the
 * load (the dsc loader emits its own events during load_dsc). Any of the
 * callbacks may be NULL — persistence NULL ⇒ a volatile cache (no error). */

#define TRIG_SCHEMA "schema Trig scope logical:\n    tag: String key\n\n"
/* 5_min in nanoseconds. */
#define TTL_5MIN_NS (5ULL * 60ULL * 1000000000ULL)

static int build_engine(ds_engine_t **out_engine,
                        const ds_schema_t **out_trig,
                        stream_probe_t *sp,
                        hit_probe_t    *ap,
                        store_t *store,
                        ds_cache_set_cb_t    scb,
                        ds_cache_delete_cb_t dcb,
                        const char *ds_src)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) return spec_fail("engine_new", r);
    r = spec_load_ds(e, ds_src);
    if (r.status != DS_OK) return spec_fail("spec_load_ds", r);
    const ds_schema_t *trig = NULL;
    r = ds_engine_schema_find(e, "Trig", &trig);
    if (r.status != DS_OK || !trig) return spec_fail("find Trig", r);
    if (sp != NULL) {
        r = ds_engine_set_stream_callback(e, stream_cb, sp);
        if (r.status != DS_OK) return spec_fail("set_stream_cb", r);
    }
    if (ap != NULL) {
        r = ds_engine_set_log_callback(e, hit_log_cb, ap);
        if (r.status != DS_OK) return spec_fail("set_log_cb", r);
    }
    /* Optional persistence hooks; NULL/NULL is a fully-functional volatile
       cache. The setter is always called so a test can wire either op. */
    r = ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, scb, dcb, store);
    if (r.status != DS_OK) return spec_fail("cache_callbacks", r);
    *out_engine = e;
    if (out_trig) *out_trig = trig;
    return 0;
}

/* Put the engine on the mock clock at `t0` so TTL deadlines are exact. */
static int use_mock_clock(ds_engine_t *e, uint64_t t0)
{
    ds_result_t r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    if (r.status != DS_OK) return spec_fail("clock_set_mode", r);
    r = ds_engine_clock_set(e, t0);
    if (r.status != DS_OK) return spec_fail("clock_set", r);
    return 0;
}

static int fire(ds_engine_t *e, const ds_schema_t *trig, const char *tag)
{
    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = tag } };
    ds_result_t r = ds_engine_assert(e, trig, v, 1, NULL);
    if (r.status != DS_OK) return spec_fail("assert trig", r);
    return 0;
}

static int assert_no_other_actions(const stream_probe_t *sp)
{
    if (sp->n_other_action != 0) {
        fprintf(stderr,
                "FAIL: stream observed %d unexpected action events\n",
                sp->n_other_action);
        return 1;
    }
    return 0;
}

/* DS rule fragments. Each rule is guarded by the Trig tag so a single assert
   drives exactly one rule.
 *
 * Read-back is observed via a `where`-clause `cached()` gate (LSTO.4.3.1a) that
 * fires a LITERAL `log critical "HIT"` iff `cached("k")` reads back as "1":
 *   - hit  → the equality holds, the rule fires, "HIT" is captured.
 *   - miss → `cached()` returns FALSE, which "compares unequal to everything"
 *            (LSTO.4.3.1a), so the rule does NOT fire → nothing logged.
 * Presence or absence of that CRITICAL log distinguishes hit from miss. */
#define RULE_SET_K1 \
    "rule s_set:\n    Trig t where t.tag == \"s\"\n" \
    "->\n    cache key: \"k\" value: 1\n"
#define RULE_SET_K1_TTL \
    "rule s_set:\n    Trig t where t.tag == \"s\"\n" \
    "->\n    cache key: \"k\" value: 1 ttl: 5_min\n"
#define RULE_SET_COLOR_TTL \
    "rule s_set:\n    Trig t where t.tag == \"s\"\n" \
    "->\n    cache key: \"color\" value: 1 ttl: 5_min\n"
#define RULE_DEL_K \
    "rule d_del:\n    Trig t where t.tag == \"d\"\n" \
    "->\n    cache_delete key: \"k\"\n"
#define RULE_DEL_DOOMED \
    "rule d_del:\n    Trig t where t.tag == \"d\"\n" \
    "->\n    cache_delete key: \"doomed\"\n"
/* Fires log critical "HIT" iff cached("k") reads back == "1". */
#define RULE_READ_HIT_K \
    "rule r_read:\n" \
    "    Trig t where t.tag == \"r\" and cached(\"k\") == \"1\"\n" \
    "->\n    log critical \"HIT\"\n"

/* ============== Scenarios ============== */

/* IDSP.7.10 — volatile round-trip with NO persistence callbacks: a `cache`
   write populates the engine cache and a later `cached()` read returns it. */
static int test_idsp_7_10__volatile_roundtrip(void)
{
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, NULL,
            TRIG_SCHEMA RULE_SET_K1 RULE_READ_HIT_K))
        return 1;
    /* Write — volatile, no hook. */
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set (volatile)", r);
    if (sp.n_set != 1) {
        fprintf(stderr, "FAIL: volatile set count=%d\n", sp.n_set); return 1;
    }
    /* Read back — the gate `cached("k") == "1"` holds, so "HIT" fires. */
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read", r);
    if (ap.n_hit != 1 || strcmp(ap.last_msg, "HIT") != 0) {
        fprintf(stderr, "FAIL: read-back did not hit (n=%d msg=\"%s\")\n",
                ap.n_hit, ap.last_msg);
        return 1;
    }
    /* Read is not a recorded output; no persistence hook was ever consulted. */
    if (sp.n_get != 0) {
        fprintf(stderr, "FAIL: read emitted ACTION_CACHE_GET (n=%d)\n", sp.n_get);
        return 1;
    }
    if (store.n_set_calls != 0) {
        fprintf(stderr, "FAIL: NULL hook still invoked (n=%d)\n",
                store.n_set_calls);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.7.10 — a miss returns FALSE, which compares unequal to everything: the
   gate `cached("k") == "1"` does NOT hold on an unpopulated cache, so "HIT"
   never fires. The read is still not recorded (n_get == 0). */
static int test_idsp_7_10__miss_no_hit(void)
{
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, NULL,
            TRIG_SCHEMA RULE_READ_HIT_K))
        return 1;
    /* Never write "k" — the gate reads a miss. */
    if (fire(e, trig, "r")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump read miss", r);
    if (ap.n_hit != 0) {
        fprintf(stderr, "FAIL: miss still fired HIT (n=%d msg=\"%s\")\n",
                ap.n_hit, ap.last_msg);
        return 1;
    }
    if (sp.n_get != 0) {
        fprintf(stderr, "FAIL: miss emitted ACTION_CACHE_GET (n=%d)\n", sp.n_get);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* RARC.5.7.9 — a read is never recorded, even on a hit: after a write + a hit
   read, the stream carries exactly one SET and zero GETs. */
static int test_rarc_5_7_9__read_not_recorded_on_hit(void)
{
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, NULL,
            TRIG_SCHEMA RULE_SET_K1 RULE_READ_HIT_K))
        return 1;
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set", r);
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read", r);
    if (ap.n_hit != 1) {
        fprintf(stderr, "FAIL: hit gate did not fire (n=%d)\n", ap.n_hit);
        return 1;
    }
    if (sp.n_get != 0) {
        fprintf(stderr, "FAIL: hit read emitted ACTION_CACHE_GET (n=%d)\n",
                sp.n_get);
        return 1;
    }
    if (sp.n_set != 1) {
        fprintf(stderr, "FAIL: SET count=%d, want 1\n", sp.n_set); return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.7.6 — DS_EV_ACTION_CACHE_SET payload: key + value tree kind + ttl_ns.
   `ttl: 5_min` exercises the verbatim-pass property; `value: 1` is a JSON int. */
static int test_idsp_7_6__action_cache_set_payload(void)
{
    stream_probe_t sp = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, NULL, &store, NULL, NULL,
            TRIG_SCHEMA RULE_SET_COLOR_TTL))
        return 1;
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_set != 1) {
        fprintf(stderr, "FAIL: ACTION_CACHE_SET count=%d\n", sp.n_set); return 1;
    }
    if (strcmp(sp.last_set_key, "color") != 0) {
        fprintf(stderr, "FAIL: SET key=\"%s\"\n", sp.last_set_key); return 1;
    }
    if (sp.last_set_ttl != TTL_5MIN_NS) {
        fprintf(stderr, "FAIL: SET ttl=%llu, want %llu\n",
                (unsigned long long) sp.last_set_ttl,
                (unsigned long long) TTL_5MIN_NS);
        return 1;
    }
    if (sp.last_set_value_kind != DS_JSON_INT) {
        fprintf(stderr, "FAIL: SET value kind=%d\n",
                (int) sp.last_set_value_kind);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* IDSP.7.6 — DS_EV_ACTION_CACHE_DELETE payload: key only. */
static int test_idsp_7_6__action_cache_delete_payload(void)
{
    stream_probe_t sp = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, NULL, &store, NULL, NULL,
            TRIG_SCHEMA RULE_DEL_DOOMED))
        return 1;
    if (fire(e, trig, "d")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump", r);
    if (sp.n_delete != 1) {
        fprintf(stderr, "FAIL: DELETE count=%d\n", sp.n_delete); return 1;
    }
    if (strcmp(sp.last_delete_key, "doomed") != 0) {
        fprintf(stderr, "FAIL: DELETE key=\"%s\"\n", sp.last_delete_key);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* IDSP.7.10 — volatile delete: with NO hooks, a write then a delete leaves the
   key absent, so the read gate misses and "HIT" does not fire. Proves delete
   mutates the engine cache (not just an outbound signal). */
static int test_idsp_7_10__volatile_delete(void)
{
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, NULL,
            TRIG_SCHEMA RULE_SET_K1 RULE_DEL_K RULE_READ_HIT_K))
        return 1;
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set", r);
    if (fire(e, trig, "d")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump delete (volatile)", r);
    if (sp.n_delete != 1) {
        fprintf(stderr, "FAIL: delete count=%d\n", sp.n_delete); return 1;
    }
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read", r);
    if (ap.n_hit != 0) {
        fprintf(stderr, "FAIL: post-delete read still hit (n=%d)\n", ap.n_hit);
        return 1;
    }
    if (store.n_delete_calls != 0) {
        fprintf(stderr, "FAIL: NULL delete hook invoked (n=%d)\n",
                store.n_delete_calls);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LSTO.4.7 — wired persistence hooks mirror writes/deletes: set_cb sees the
   key/value-kind/ttl; delete_cb sees the key. */
static int test_lsto_4_7__persistence_hooks_invoked(void)
{
    stream_probe_t sp = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, NULL, &store, set_cb, delete_cb,
            TRIG_SCHEMA RULE_SET_K1_TTL RULE_DEL_K))
        return 1;
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set", r);
    if (store.n_set_calls != 1 ||
        strcmp(store.last_set_key, "k") != 0 ||
        store.last_set_ttl_ns != TTL_5MIN_NS ||
        store.last_set_value_kind != DS_JSON_INT) {
        fprintf(stderr, "FAIL: set hook n=%d key=\"%s\" ttl=%llu kind=%d\n",
                store.n_set_calls, store.last_set_key,
                (unsigned long long) store.last_set_ttl_ns,
                (int) store.last_set_value_kind);
        return 1;
    }
    if (fire(e, trig, "d")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump delete", r);
    if (store.n_delete_calls != 1 || strcmp(store.last_delete_key, "k") != 0) {
        fprintf(stderr, "FAIL: delete hook n=%d key=\"%s\"\n",
                store.n_delete_calls, store.last_delete_key);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* LSTO.4.7.2 — a wired set hook's failure PROPAGATES through pump but the
   engine cache is NOT rolled back: the SET is still recorded (mutate-first) and
   a later `cached()` read still returns the written value: the hook is never
   a second writer. */
static int test_lsto_4_7_2__hook_error_no_rollback(void)
{
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    store.next_set_return = DS_ERR_R(DS_ERR_ACTION_FAILED, "probe-induced");
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, set_cb, NULL,
            TRIG_SCHEMA RULE_SET_K1 RULE_READ_HIT_K))
        return 1;
    /* Write — the engine mutates first, records the SET, then the hook fails. */
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_STATUS("pump set (hook error)", r, DS_ERR_ACTION_FAILED);
    if (store.n_set_calls != 1) {
        fprintf(stderr, "FAIL: set hook not called\n"); return 1;
    }
    if (sp.n_set != 1) {
        fprintf(stderr, "FAIL: hook failure un-recorded the SET (n=%d)\n",
                sp.n_set);
        return 1;
    }
    /* No rollback — the value is still in the engine cache, so the read gate
       hits. The read-back pump is not wedged by the prior pump's error
       (pending is drained per pump). */
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read after hook error", r);
    if (ap.n_hit != 1 || strcmp(ap.last_msg, "HIT") != 0) {
        fprintf(stderr, "FAIL: post-error read did not hit (n=%d msg=\"%s\") "
                "(cache was rolled back?)\n", ap.n_hit, ap.last_msg);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* ============== Removal reasons ==============
 *
 * One vector per reason, each asserting the reason ([NSTG.2.4]): `delete_cb`
 * means the key is gone from the engine's cache, and the reason says which of
 * the two exits it took. A write at the cap is refused rather than evicting
 * ([RTCT.7.1], [LDET.2.1]), so there is no capacity reason.
 *
 * Not covered here: the read-path backstop's notification. It fires only for
 * an entry that expires between pump entry and the read, which under the mock
 * clock cannot happen, since a pump reads one instant throughout. test_cache.c
 * covers it at the impl level. */

/* [NSTG.2.4.2] — the sweep at pump entry, and the case it exists for: a key
   written once, its TTL elapsing, nothing ever reading it again. The reason
   reads TTL, not DELETE. */
static int test_nstg_2_4_2__ttl_sweep_notifies_with_reason_ttl(void)
{
    const uint64_t T0 = 1000000ULL;
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_SET_K1_TTL RULE_READ_HIT_K))
        return 1;
    if (use_mock_clock(e, T0)) return 1;

    /* Write "k" with a 5-minute TTL: deadline = T0 + 5min. */
    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set", r);
    if (store.n_delete_calls != 0) {
        fprintf(stderr, "FAIL: removal notified before the deadline (n=%d)\n",
                store.n_delete_calls);
        return 1;
    }

    /* Advance past the deadline and pump with NOTHING asserted — no rule
       fires, and in particular nothing reads "k". The sweep is the only thing
       that can remove it. */
    r = ds_engine_clock_set(e, T0 + TTL_5MIN_NS);
    EXPECT_OK("advance past deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump sweep", r);

    if (store.n_delete_calls != 1) {
        fprintf(stderr, "FAIL: TTL sweep notified %d times, want 1\n",
                store.n_delete_calls);
        return 1;
    }
    if (strcmp(store.last_delete_key, "k") != 0) {
        fprintf(stderr, "FAIL: sweep notified key=\"%s\", want \"k\"\n",
                store.last_delete_key);
        return 1;
    }
    if (store.last_delete_reason != DS_CACHE_REMOVED_TTL) {
        fprintf(stderr, "FAIL: sweep reason=%d, want DS_CACHE_REMOVED_TTL (%d)\n",
                (int) store.last_delete_reason, (int) DS_CACHE_REMOVED_TTL);
        return 1;
    }
    /* TTL expiry is NOT a recorded action. DS_EV_ACTION_CACHE_DELETE denotes
       the `cache_delete` VERB — a rule doing something ([RFCS.15.7]) — and no
       rule did anything here. Replay re-derives the expiry from the recorded
       clock, so recording it would double the removal rather than preserve
       it. */
    if (sp.n_delete != 0) {
        fprintf(stderr, "FAIL: TTL expiry recorded ACTION_CACHE_DELETE (n=%d)\n",
                sp.n_delete);
        return 1;
    }

    /* The entry really LEFT the engine's cache — the notification is not a
       signal fired beside a still-live entry. The read gate now misses. */
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read after sweep", r);
    if (ap.n_hit != 0) {
        fprintf(stderr, "FAIL: swept key still read back (n=%d)\n", ap.n_hit);
        return 1;
    }
    /* ...and the read did not notify a SECOND time for the same entry. */
    if (store.n_delete_calls != 1) {
        fprintf(stderr, "FAIL: post-sweep read re-notified (n=%d)\n",
                store.n_delete_calls);
        return 1;
    }
    if (assert_no_other_actions(&sp)) return 1;
    ds_engine_free(e);
    return 0;
}

/* [NSTG.2.4] — the explicit verb's reason is DELETE, and the verb is a
   recorded action. */
static int test_nstg_2_4__delete_verb_notifies_with_reason_delete(void)
{
    const uint64_t T0 = 1000000ULL;
    stream_probe_t sp = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, NULL, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_SET_K1_TTL RULE_DEL_K))
        return 1;
    if (use_mock_clock(e, T0)) return 1;

    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set", r);

    /* Delete well inside the TTL, so the only removal is the verb's. */
    if (fire(e, trig, "d")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump delete", r);

    if (store.n_delete_calls != 1) {
        fprintf(stderr, "FAIL: delete verb notified %d times, want 1\n",
                store.n_delete_calls);
        return 1;
    }
    if (strcmp(store.last_delete_key, "k") != 0) {
        fprintf(stderr, "FAIL: delete notified key=\"%s\", want \"k\"\n",
                store.last_delete_key);
        return 1;
    }
    if (store.last_delete_reason != DS_CACHE_REMOVED_DELETE) {
        fprintf(stderr, "FAIL: verb reason=%d, want DS_CACHE_REMOVED_DELETE (%d)\n",
                (int) store.last_delete_reason, (int) DS_CACHE_REMOVED_DELETE);
        return 1;
    }
    if (sp.n_delete != 1) {
        fprintf(stderr, "FAIL: delete verb recorded %d ACTION_CACHE_DELETE, want 1\n",
                sp.n_delete);
        return 1;
    }

    /* The entry is gone, so crossing the deadline afterwards produces no
       second notification. */
    r = ds_engine_clock_set(e, T0 + 2 * TTL_5MIN_NS);
    EXPECT_OK("advance past deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump after deadline", r);
    if (store.n_delete_calls != 1) {
        fprintf(stderr, "FAIL: sweep re-notified a deleted key (n=%d)\n",
                store.n_delete_calls);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* [NSTG.2.4.2] — an entry with no ttl is not swept, at any clock value. */
static int test_nstg_2_4_2__no_ttl_entry_survives_the_sweep(void)
{
    const uint64_t T0 = 1000000ULL;
    stream_probe_t sp = {0};
    hit_probe_t    ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, &sp, &ap, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_SET_K1 RULE_READ_HIT_K))   /* no ttl: on the set */
        return 1;
    if (use_mock_clock(e, T0)) return 1;

    if (fire(e, trig, "s")) return 1;
    ds_result_t r = ds_engine_pump(e);
    EXPECT_OK("pump set (no ttl)", r);

    r = ds_engine_clock_set(e, T0 + 1000ULL * TTL_5MIN_NS);
    EXPECT_OK("advance far", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump sweep", r);
    if (store.n_delete_calls != 0) {
        fprintf(stderr, "FAIL: sweep removed a no-TTL entry (n=%d key=\"%s\")\n",
                store.n_delete_calls, store.last_delete_key);
        return 1;
    }
    /* Still readable — durable in intent ([LSTO.4.6.1]). */
    if (fire(e, trig, "r")) return 1;
    r = ds_engine_pump(e);
    EXPECT_OK("pump read", r);
    if (ap.n_hit != 1) {
        fprintf(stderr, "FAIL: no-TTL entry lost across the sweep (n=%d)\n",
                ap.n_hit);
        return 1;
    }
    ds_engine_free(e);
    return 0;
}

/* NLFC.9.1 — a host seed is setup-phase, in the window a load is
   ([NFCT.1.1]): before the engine's first stream event. A host assert emits
   that event, so a seed after it, even before any pump, is DS_ERR_STATE and
   the cache does not hold the key. The control: the same seed before any
   input is taken, and `r_read`'s gate reads it back. */
/* @spec [NLFC.9.1] */
static int test_nlfc_9_1__seed_after_first_event_refused(void)
{
    ds_json_t *one = NULL;
    ds_result_t r = ds_json_parse("1", 1, &one);
    EXPECT_OK("json_parse 1", r);

    /* The control: seeded before any input, read back. */
    {
        hit_probe_t ap = {0};
        store_t store = {0};
        ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
        if (build_engine(&e, &trig, NULL, &ap, &store, NULL, NULL,
                TRIG_SCHEMA RULE_READ_HIT_K))
            return 1;
        r = ds_engine_cache_seed(e, "k", one, DS_CACHE_TTL_NONE);
        EXPECT_OK("seed before any input", r);
        if (fire(e, trig, "r")) return 1;
        r = ds_engine_pump(e);
        EXPECT_OK("pump read (seeded)", r);
        if (ap.n_hit != 1) {
            fprintf(stderr, "FAIL: a seed before any input was not read back "
                    "(n=%d)\n", ap.n_hit);
            return 1;
        }
        ds_engine_free(e);
    }

    /* The refusal: an assert first, then the seed, before any pump. */
    {
        hit_probe_t ap = {0};
        store_t store = {0};
        ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
        if (build_engine(&e, &trig, NULL, &ap, &store, NULL, NULL,
                TRIG_SCHEMA RULE_READ_HIT_K))
            return 1;
        if (fire(e, trig, "r")) return 1;
        r = ds_engine_cache_seed(e, "k", one, DS_CACHE_TTL_NONE);
        EXPECT_STATUS("seed after the first stream event", r, DS_ERR_STATE);
        r = ds_engine_pump(e);
        EXPECT_OK("pump read (refused seed)", r);
        if (ap.n_hit != 0) {
            fprintf(stderr, "FAIL: a refused seed was read back (n=%d)\n",
                    ap.n_hit);
            return 1;
        }
        ds_engine_free(e);
    }
    ds_json_free(one);
    return 0;
}

/* ---- NLFC.9.4: a seed's TTL counts from the engine's first sample ---- */

/* Fires log critical "HIT" on every new Trig while cached("k") reads "1".
   Any tag, so each step can assert a fresh one: a logical Trig asserted again
   with the same tag is a no-op and would fire nothing. The tag test is there
   because a binding nothing reads is refused at compile time. */
#define RULE_READ_HIT_K_ANY \
    "rule r_any:\n" \
    "    Trig t where t.tag != \"\" and cached(\"k\") == \"1\"\n" \
    "->\n    log critical \"HIT\"\n"

#define SEC_NS 1000000000ULL

/* One step at mock instant `t`: set the clock, assert Trig `tag`, pump. */
static int read_at(ds_engine_t *e, const ds_schema_t *trig, uint64_t t,
                   const char *tag)
{
    ds_result_t r = ds_engine_clock_set(e, t);
    if (r.status != DS_OK) return spec_fail("clock_set", r);
    if (fire(e, trig, tag)) return 1;
    r = ds_engine_pump(e);
    if (r.status != DS_OK) return spec_fail("pump", r);
    return 0;
}

/* `want_hits` reads so far and `want_removed` TTL removals, both exact. */
static int expect_reads(const char *where, const hit_probe_t *ap,
                        const store_t *store, int want_hits, int want_removed)
{
    if (ap->n_hit != want_hits) {
        fprintf(stderr, "FAIL: %s: %d reads of k, want %d\n",
                where, ap->n_hit, want_hits);
        return 1;
    }
    if (store->n_delete_calls != want_removed) {
        fprintf(stderr, "FAIL: %s: %d removals of k, want %d\n",
                where, store->n_delete_calls, want_removed);
        return 1;
    }
    if (want_removed > 0
        && (strcmp(store->last_delete_key, "k") != 0
            || store->last_delete_reason != DS_CACHE_REMOVED_TTL)) {
        fprintf(stderr, "FAIL: %s: removal of \"%s\" reason %d, want \"k\" "
                "by TTL\n", where, store->last_delete_key,
                (int) store->last_delete_reason);
        return 1;
    }
    return 0;
}

/* NLFC.9.4 — the mock clock is set to 10 s before the engine samples it,
   then `k` is seeded with a 5 s TTL. The first sample is 10 s, so the
   deadline is 15 s: read at 10 s and at 14.999 999 999 s, and gone at 15 s,
   taken by the pump-entry sweep ([NSTG.2.4.2]) with the TTL reason. */
/* @spec [NLFC.9.4] */
static int test_nlfc_9_4__seed_ttl_counts_from_first_sample(void)
{
    ds_json_t *one = NULL;
    ds_result_t r = ds_json_parse("1", 1, &one);
    EXPECT_OK("json_parse 1", r);

    hit_probe_t ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, NULL, &ap, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_READ_HIT_K_ANY))
        return 1;
    if (use_mock_clock(e, 10 * SEC_NS)) return 1;
    r = ds_engine_cache_seed(e, "k", one, 5 * SEC_NS);
    EXPECT_OK("seed k, ttl 5 s", r);

    if (read_at(e, trig, 10 * SEC_NS, "a")) return 1;
    if (expect_reads("first sample, 10 s", &ap, &store, 1, 0)) return 1;
    if (read_at(e, trig, 15 * SEC_NS - 1, "b")) return 1;
    if (expect_reads("14.999999999 s", &ap, &store, 2, 0)) return 1;
    if (read_at(e, trig, 15 * SEC_NS, "c")) return 1;
    if (expect_reads("15 s", &ap, &store, 2, 1)) return 1;

    ds_engine_free(e);
    ds_json_free(one);
    return 0;
}

/* NLFC.9.4 — a clone made before the first sample holds the duration, and
   its own first sample fixes its deadline ([NLFC.8.1]). The source, sampled
   at 10 s, loses `k` at 15 s; the clone, first sampled at 20 s, reads it up
   to 24.999 999 999 s and loses it at 25 s. */
/* @spec [NLFC.9.4] */
static int test_nlfc_9_4__clone_holds_the_duration(void)
{
    ds_json_t *one = NULL;
    ds_result_t r = ds_json_parse("1", 1, &one);
    EXPECT_OK("json_parse 1", r);

    hit_probe_t ap = {0};
    store_t store = {0};
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, NULL, &ap, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_READ_HIT_K_ANY))
        return 1;
    if (use_mock_clock(e, 10 * SEC_NS)) return 1;
    r = ds_engine_cache_seed(e, "k", one, 5 * SEC_NS);
    EXPECT_OK("seed k, ttl 5 s", r);

    ds_engine_t *c = NULL;
    r = ds_engine_clone(e, &c);
    EXPECT_OK("clone before the first sample", r);
    hit_probe_t cap = {0};
    store_t cstore = {0};
    const ds_schema_t *ctrig = NULL;
    r = ds_engine_schema_find(c, "Trig", &ctrig);
    if (r.status != DS_OK || !ctrig) return spec_fail("clone: find Trig", r);
    r = ds_engine_set_log_callback(c, hit_log_cb, &cap);
    EXPECT_OK("clone: log callback", r);
    r = ds_engine_cache_callbacks(c, DS_CACHE_CB_ABI_VERSION, NULL, delete_cb,
                                  &cstore);
    EXPECT_OK("clone: cache callbacks", r);

    if (read_at(e, trig, 10 * SEC_NS, "a")) return 1;
    if (expect_reads("source, 10 s", &ap, &store, 1, 0)) return 1;
    if (read_at(e, trig, 15 * SEC_NS, "b")) return 1;
    if (expect_reads("source, 15 s", &ap, &store, 1, 1)) return 1;

    if (read_at(c, ctrig, 20 * SEC_NS, "a")) return 1;
    if (expect_reads("clone, first sample, 20 s", &cap, &cstore, 1, 0))
        return 1;
    if (read_at(c, ctrig, 25 * SEC_NS - 1, "b")) return 1;
    if (expect_reads("clone, 24.999999999 s", &cap, &cstore, 2, 0)) return 1;
    if (read_at(c, ctrig, 25 * SEC_NS, "c")) return 1;
    if (expect_reads("clone, 25 s", &cap, &cstore, 2, 1)) return 1;

    ds_engine_free(c);
    ds_engine_free(e);
    ds_json_free(one);
    return 0;
}

/* ---- NLFC.9.5: a seed's deadline past the Time range ---- */

/* Counts every stream event, of any kind. */
static ds_result_t count_events_cb(ds_engine_t *e, const ds_stream_ev_t *ev,
                                   void *u)
{
    (void) e; (void) ev;
    (*(int *) u)++;
    return DS_OK_R;
}

#define INT64_MAX_LESS_1S ((uint64_t) INT64_MAX - SEC_NS)
#define HOUR_NS (3600ULL * SEC_NS)

/* NLFC.9.5 — a seed whose TTL no `Time` can hold is refused at the call with
   DS_ERR_TIME_RANGE, and the cache does not hold the key: the first step, at
   a mock clock of 10 s, reads nothing. The control on a second engine: the
   largest TTL a `Time` can hold, INT64_MAX ns, is taken, and at a first
   sample of 0 its deadline is INT64_MAX, in range, so it is read. */
/* @spec [NLFC.9.5] */
static int test_nlfc_9_5__seed_ttl_past_range_refused(void)
{
    ds_json_t *one = NULL;
    ds_result_t r = ds_json_parse("1", 1, &one);
    EXPECT_OK("json_parse 1", r);

    {
        hit_probe_t ap = {0};
        store_t store = {0};
        ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
        if (build_engine(&e, &trig, NULL, &ap, &store, NULL, delete_cb,
                TRIG_SCHEMA RULE_READ_HIT_K_ANY))
            return 1;
        if (use_mock_clock(e, 0)) return 1;
        r = ds_engine_cache_seed(e, "k", one, (uint64_t) INT64_MAX + 1u);
        EXPECT_STATUS("seed k, ttl 2^63", r, DS_ERR_TIME_RANGE);
        if (read_at(e, trig, 10 * SEC_NS, "a")) return 1;
        if (expect_reads("after the refused seed", &ap, &store, 0, 0))
            return 1;
        ds_engine_free(e);
    }
    {
        hit_probe_t ap = {0};
        store_t store = {0};
        ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
        if (build_engine(&e, &trig, NULL, &ap, &store, NULL, delete_cb,
                TRIG_SCHEMA RULE_READ_HIT_K_ANY))
            return 1;
        if (use_mock_clock(e, 0)) return 1;
        r = ds_engine_cache_seed(e, "k", one, (uint64_t) INT64_MAX);
        EXPECT_OK("control: seed k, ttl 2^63 - 1", r);
        if (read_at(e, trig, 0, "a")) return 1;
        if (expect_reads("control: the first sample at 0", &ap, &store, 1, 0))
            return 1;
        ds_engine_free(e);
    }
    ds_json_free(one);
    return 0;
}

/* NLFC.9.5 — seeded with a 1 h TTL at a mock clock of INT64_MAX - 1 s, the
   first sample would give `k` a deadline past the `Time` range. So the calls
   that would take it, an assert and a pump, are refused with
   DS_ERR_TIME_RANGE and the engine is left as it was: the stream holds
   nothing; `set` back to 0 succeeds, which [NTST.3.1] admits only before the
   first sample; and the window is still open, so a second key, `j`, is
   seeded. `k` is left as it was seeded. Then the first step, at 0, reads that
   original `k`, and it expires at 1 h: the refusals fixed no deadline, and
   `k` still held its 1 h as a duration for that step's sample to fix. `j`
   never expires, so the one removal is `k`'s. */
/* @spec [NLFC.9.5] */
static int test_nlfc_9_5__first_step_refused_for_a_seed_deadline(void)
{
    ds_json_t *one = NULL;
    ds_result_t r = ds_json_parse("1", 1, &one);
    EXPECT_OK("json_parse 1", r);

    hit_probe_t ap = {0};
    store_t store = {0};
    int events = 0;
    ds_engine_t *e = NULL; const ds_schema_t *trig = NULL;
    if (build_engine(&e, &trig, NULL, &ap, &store, NULL, delete_cb,
            TRIG_SCHEMA RULE_READ_HIT_K_ANY))
        return 1;
    r = ds_engine_set_stream_callback(e, count_events_cb, &events);
    EXPECT_OK("set_stream_cb", r);
    if (use_mock_clock(e, INT64_MAX_LESS_1S)) return 1;
    r = ds_engine_cache_seed(e, "k", one, HOUR_NS);
    EXPECT_OK("seed k, ttl 1 h, at INT64_MAX - 1 s", r);

    ds_slot_value_t v[] = { { .kind = DS_SLOT_STRING, .v.s = "a" } };
    r = ds_engine_assert(e, trig, v, 1, NULL);
    EXPECT_STATUS("the first assert", r, DS_ERR_TIME_RANGE);
    r = ds_engine_pump(e);
    EXPECT_STATUS("the first pump", r, DS_ERR_TIME_RANGE);
    if (events != 0) {
        fprintf(stderr, "FAIL: the refused calls recorded %d events\n",
                events);
        return 1;
    }
    r = ds_engine_clock_set(e, 0);
    EXPECT_OK("set back to 0: no sample was taken", r);
    r = ds_engine_cache_seed(e, "j", one, DS_CACHE_TTL_NONE);
    EXPECT_OK("seed j: the window is open", r);

    if (read_at(e, trig, 0, "b")) return 1;
    if (expect_reads("the first step, at 0", &ap, &store, 1, 0)) return 1;
    if (read_at(e, trig, HOUR_NS - 1, "c")) return 1;
    if (expect_reads("1 h - 1 ns", &ap, &store, 2, 0)) return 1;
    if (read_at(e, trig, HOUR_NS, "d")) return 1;
    if (expect_reads("1 h", &ap, &store, 2, 1)) return 1;
    if (events == 0) {
        fprintf(stderr, "FAIL: the admitted steps recorded nothing\n");
        return 1;
    }

    ds_engine_free(e);
    ds_json_free(one);
    return 0;
}

/* ============== Driver ============== */

int main(void)
{
    int failed = 0;
    failed |= test_idsp_7_10__volatile_roundtrip();
    failed |= test_idsp_7_10__miss_no_hit();
    failed |= test_rarc_5_7_9__read_not_recorded_on_hit();
    failed |= test_idsp_7_6__action_cache_set_payload();
    failed |= test_idsp_7_6__action_cache_delete_payload();
    failed |= test_idsp_7_10__volatile_delete();
    failed |= test_lsto_4_7__persistence_hooks_invoked();
    failed |= test_lsto_4_7_2__hook_error_no_rollback();
    failed |= test_nstg_2_4_2__ttl_sweep_notifies_with_reason_ttl();
    failed |= test_nstg_2_4__delete_verb_notifies_with_reason_delete();
    failed |= test_nstg_2_4_2__no_ttl_entry_survives_the_sweep();
    failed |= test_nlfc_9_1__seed_after_first_event_refused();
    failed |= test_nlfc_9_4__seed_ttl_counts_from_first_sample();
    failed |= test_nlfc_9_4__clone_holds_the_duration();
    failed |= test_nlfc_9_5__seed_ttl_past_range_refused();
    failed |= test_nlfc_9_5__first_step_refused_for_a_seed_deadline();
    if (!failed) printf("test_cache_spec: OK\n");
    return failed;
}

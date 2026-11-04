/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NLFC.6.4]
 * "ds_engine_free must not invoke any callback the integrator registered: it
 * emits no stream event and no metric or log, and hands nothing to the cache
 * persistence callbacks".
 *
 * THE PATH: engine.c's ds_engine_free, which destroys the dispatcher, working
 * memory, the schema registry, the recorder and telemetry ([STYL.5.10.8]).
 *
 * The engine goes to the free holding a live fact with a TTL, a live logical
 * fact, and a cache entry with a TTL.
 *
 * THE CONTROL: before the free, the stream and cache-set callbacks have fired,
 * so they are registered and live, and the entry is there to drop. The metric,
 * log and delete counts may be zero then: the check on them is that they do not
 * move. The counters are this test's own, so they can be read after the free.
 */
#include "spec_common.h"

static const char *PROGRAM =
    "schema Trig scope logical:\n"
    "    k: Int key\n"
    "\n"
    "schema Timed scope ttl 1_h:\n"
    "    v: Int\n"
    "\n"
    "rule writer:\n"
    "    Trig t\n"
    "->\n"
    "    cache key: \"k\" value: t.k ttl: 1_h\n"
    "\n"
    "rule timed:\n"
    "    Timed\n"
    "->\n"
    "    log info \"timed\"\n";

typedef struct {
    int stream, metric, log, cache_set, cache_delete;
} counts_t;

static counts_t g_counts;

static ds_result_t on_stream(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e; (void) ev; (void) user;
    g_counts.stream++;
    return DS_OK_R;
}

static ds_result_t on_metric(ds_engine_t *e, const ds_metric_t *m, void *user)
{
    (void) e; (void) m; (void) user;
    g_counts.metric++;
    return DS_OK_R;
}

static ds_result_t on_log(ds_engine_t *e, const ds_log_event_t *ev, void *user)
{
    (void) e; (void) ev; (void) user;
    g_counts.log++;
    return DS_OK_R;
}

static ds_result_t on_cache_set(ds_engine_t *e, const ds_cache_write_t *write, void *user)
{
    (void) e; (void) write; (void) user;
    g_counts.cache_set++;
    return DS_OK_R;
}

static ds_result_t on_cache_delete(ds_engine_t *e, const ds_cache_removal_t *removal,
                                   void *user)
{
    (void) e; (void) removal; (void) user;
    g_counts.cache_delete++;
    return DS_OK_R;
}

static int assert_one_int(ds_engine_t *e, const char *schema, int64_t n)
{
    const ds_schema_t *s = NULL;
    EXPECT_OK(schema, ds_engine_schema_find(e, schema, &s));
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i  = n;
    EXPECT_OK(schema, ds_engine_assert(e, s, &v, 1, NULL));
    return 0;
}

int main(void)
{
    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("stream callback", ds_engine_set_stream_callback(e, on_stream, NULL));
    EXPECT_OK("metric callback", ds_engine_set_metric_callback(e, on_metric, NULL));
    EXPECT_OK("log callback", ds_engine_set_log_callback(e, on_log, NULL));
    EXPECT_OK("cache callbacks",
              ds_engine_cache_callbacks(e, DS_CACHE_CB_ABI_VERSION, on_cache_set,
                                        on_cache_delete, NULL));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));

    if (assert_one_int(e, "Trig", 1)) return 1;
    if (assert_one_int(e, "Timed", 2)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));

    if (g_counts.stream == 0 || g_counts.cache_set != 1) {
        fprintf(stderr, "FAIL: premise: stream=%d cache_set=%d before the free\n",
                g_counts.stream, g_counts.cache_set);
        return 1;
    }

    counts_t before = g_counts;
    EXPECT_OK("free", ds_engine_free(e));

    if (g_counts.stream != before.stream || g_counts.metric != before.metric
            || g_counts.log != before.log || g_counts.cache_set != before.cache_set
            || g_counts.cache_delete != before.cache_delete) {
        fprintf(stderr,
                "FAIL: the free fired a callback: stream %d->%d metric %d->%d "
                "log %d->%d cache_set %d->%d cache_delete %d->%d\n",
                before.stream, g_counts.stream, before.metric, g_counts.metric,
                before.log, g_counts.log, before.cache_set, g_counts.cache_set,
                before.cache_delete, g_counts.cache_delete);
        return 1;
    }
    printf("test_nlfc_6_4__free_fires_no_callback: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NSTG.2.3]
 * The set callback "receives the engine, a const pointer to the write, and
 * the user pointer registered alongside it", the write's members being the
 * key, the value as a parsed JSON tree, and the lifetime in nanoseconds,
 * "zero means no expiry".
 *
 * THE PATH: dispatcher.c's ds_dispatcher_notify_cache_set, which builds the
 * struct and passes its address ([STYL.5.10.8]).
 *
 * Two rules in source order, so two writes in a known order: one with `ttl: 5_s`
 * and one with no TTL. Each member is copied out inside the callback, the value
 * through ds_json_serialize, since the struct and its tree are borrowed for the
 * callback's duration ([NCBK.7.4]). The `user` pointer is this test's, which
 * shows it is the third argument, the one the registration gave.
 */
#include "spec_common.h"

#include <stdbool.h>

static const char *PROGRAM =
    "schema Trig scope logical:\n"
    "    k: Int key\n"
    "\n"
    "rule with_ttl:\n"
    "    Trig t\n"
    "->\n"
    "    cache key: \"k\" value: t.k ttl: 5_s\n"
    "\n"
    "rule no_ttl:\n"
    "    Trig\n"
    "->\n"
    "    cache key: \"n\" value: \"text\"\n";

typedef struct {
    char     key[16];
    char     value[32];
    uint64_t ttl_ns;
} seen_write_t;

typedef struct {
    int          calls;
    seen_write_t writes[2];
    bool         engine_given;
} seen_t;

static ds_engine_t *g_engine;

static ds_result_t on_set(ds_engine_t *e, const ds_cache_write_t *write, void *user)
{
    seen_t *s = user;
    if (s->calls < 2 && write != NULL) {
        seen_write_t *w = &s->writes[s->calls];
        snprintf(w->key, sizeof w->key, "%s", write->key);
        char  *text = NULL;
        size_t len  = 0;
        ds_result_t r = ds_json_serialize(write->value, &text, &len);
        if (r.status == DS_OK) {
            snprintf(w->value, sizeof w->value, "%s", text);
            ds_free(text);
        }
        w->ttl_ns = write->ttl_ns;
    }
    s->engine_given = e == g_engine;
    s->calls++;
    return DS_OK_R;
}

static int expect_write(const seen_write_t *w, const char *key, const char *value,
                        uint64_t ttl_ns)
{
    if (strcmp(w->key, key) != 0 || strcmp(w->value, value) != 0 || w->ttl_ns != ttl_ns) {
        fprintf(stderr, "FAIL: write key=%s value=%s ttl_ns=%llu, want %s %s %llu\n",
                w->key, w->value, (unsigned long long) w->ttl_ns,
                key, value, (unsigned long long) ttl_ns);
        return 1;
    }
    return 0;
}

int main(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof seen);

    EXPECT_OK("engine_new", ds_engine_new(NULL, &g_engine));
    EXPECT_OK("load", spec_load_ds(g_engine, PROGRAM));
    EXPECT_OK("cache callbacks",
              ds_engine_cache_callbacks(g_engine, DS_CACHE_CB_ABI_VERSION, on_set, NULL, &seen));

    const ds_schema_t *trig = NULL;
    EXPECT_OK("find Trig", ds_engine_schema_find(g_engine, "Trig", &trig));
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i  = 7;
    EXPECT_OK("assert", ds_engine_assert(g_engine, trig, &v, 1, NULL));
    EXPECT_OK("pump", ds_engine_pump(g_engine));

    if (seen.calls != 2) {
        fprintf(stderr, "FAIL: %d writes reached the callback, want 2\n", seen.calls);
        return 1;
    }
    if (!seen.engine_given) {
        fprintf(stderr, "FAIL: the callback's first argument is not the engine\n");
        return 1;
    }
    if (expect_write(&seen.writes[0], "k", "7", UINT64_C(5000000000))) return 1;
    if (expect_write(&seen.writes[1], "n", "\"text\"", DS_CACHE_TTL_NONE)) return 1;

    EXPECT_OK("free", ds_engine_free(g_engine));
    printf("test_nstg_2_3__set_cb_receives_the_write: OK\n");
    return 0;
}

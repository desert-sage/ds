/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A no-op reassertion of a fact whose only identity key is a `Json` slot
 * leaves one live fact ([LFAC.2.5.1], [LFAC.2.5.3]). A second live fact for
 * the key is non-conforming whichever readout shows it, so the table, the
 * stream and ds_engine_fact_count must all agree. The program is the
 * conformance fixture runtime/LFAC.2.5.1's:
 *
 *     schema Reading scope logical:
 *         payload: Json key
 *
 * asserted {"k": 1, ...} twice, then {"k": 2, ...}, then one pump. A second
 * round reorders the no-op's object members.
 *
 * PATH: ds_engine_assert -> ds_rete_wm_assert_bridge -> ds_rete_wm_assert_ex,
 * whose identity lookup is hash_idval / idkey_equal and whose no-op test is
 * slots_equal; the bridge re-records the live wrapper's FACT_ASSERT.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"   /* ds_engine_register_schema, libds-internal */

static int failures = 0;
#define CHECK(cond, msg)                                                      \
    do { if (!(cond)) {                                                       \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);     \
        failures++; } } while (0)
#define CHECK_OK(r, msg)                                                      \
    do { ds_result_t rr_ = (r);                                              \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__); failures++; } } while (0)

/* The stream readout: a live set kept from the Reading events. */
#define MAX_LIVE 16
static const ds_schema_t *g_reading = NULL;
static uint64_t g_live[MAX_LIVE];
static int      g_nlive    = 0;
static int      g_asserts  = 0;
static int      g_retracts = 0;

static bool reading_event(const ds_fact_t *f)
{
    const ds_schema_t *sc = NULL;
    return f != NULL && ds_fact_get_schema(f, &sc).status == DS_OK
           && sc == g_reading;
}

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    uint64_t id = 0;
    if (ev->kind == DS_EV_FACT_ASSERT && reading_event(ev->p.fact_assert.fact)) {
        (void)ds_fact_get_id(ev->p.fact_assert.fact, &id);
        g_asserts++;
        for (int i = 0; i < g_nlive; i++)
            if (g_live[i] == id) return DS_OK_R;   /* re-recorded: already live */
        if (g_nlive < MAX_LIVE) g_live[g_nlive++] = id;
    } else if (ev->kind == DS_EV_FACT_RETRACT
               && reading_event(ev->p.fact_retract.fact)) {
        (void)ds_fact_get_id(ev->p.fact_retract.fact, &id);
        g_retracts++;
        for (int i = 0; i < g_nlive; i++)
            if (g_live[i] == id) { g_live[i] = g_live[--g_nlive]; break; }
    }
    return DS_OK_R;
}

typedef struct { int count; uint64_t ids[MAX_LIVE]; } table_view_t;

static ds_result_t visit_reading(const ds_fact_t *f, void *user)
{
    table_view_t *v = (table_view_t *)user;
    if (v->count < MAX_LIVE) (void)ds_fact_get_id(f, &v->ids[v->count]);
    v->count++;
    return DS_OK_R;
}

static uint64_t assert_reading(ds_engine_t *e, const char *doc)
{
    ds_json_t *tree = NULL;
    CHECK_OK(ds_json_parse(doc, strlen(doc), &tree), doc);
    ds_slot_value_t v;
    memset(&v, 0, sizeof(v));
    v.kind   = DS_SLOT_JSON;
    v.v.json = tree;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, g_reading, &v, 1, &f), doc);
    uint64_t id = 0;
    if (f != NULL) (void)ds_fact_get_id(f, &id);
    ds_json_free(tree);       /* the engine cloned it ([NFCT.2.4]) */
    return id;
}

static void run(const char *label, const char *first, const char *again,
                const char *other)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (e == NULL) return;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 0), "clock 0");

    ds_slot_desc_t sd = { .name = "payload", .type = DS_SLOT_TYPE_JSON,
                          .identity_role = DS_IDENTITY_KEY };
    g_reading = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                       0, &sd, 1, &g_reading), "register Reading");
    if (g_reading == NULL) { ds_engine_free(e); return; }
    g_nlive = 0; g_asserts = 0; g_retracts = 0;
    CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");

    const uint64_t id1 = assert_reading(e, first);
    const uint64_t id2 = assert_reading(e, again);
    const uint64_t id3 = assert_reading(e, other);
    CHECK_OK(ds_engine_pump(e), "pump");

    table_view_t t;
    memset(&t, 0, sizeof(t));
    CHECK_OK(ds_engine_for_each_fact(e, g_reading, visit_reading, &t),
             "for_each Reading");
    size_t n = 0;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");

    printf("  %s: ids %llu %llu %llu | table %d | stream live %d "
           "(%d assert, %d retract) | count %zu\n", label,
           (unsigned long long)id1, (unsigned long long)id2,
           (unsigned long long)id3, t.count, g_nlive, g_asserts, g_retracts, n);

    CHECK(id2 == id1, "the equal-key reassert returns the live fact: a no-op "
                      "keeps its fact_id ([LFAC.2.5.1])");
    CHECK(id3 != id1, "another key is another fact");
    CHECK(g_retracts == 0, "nothing was retracted: a no-op is not a change, "
                           "and the third assert has its own key");
    CHECK(t.count == 2, "the table holds two Readings");
    CHECK(g_nlive == 2, "the stream leaves two Readings live");
    CHECK(n == 2, "fact_count is two");
    if (t.count == 2) {
        bool has1 = false, has3 = false;
        for (int i = 0; i < 2; i++) {
            has1 = has1 || t.ids[i] == id1;
            has3 = has3 || t.ids[i] == id3;
        }
        CHECK(has1 && has3, "the table's two are the first and third asserts' "
                            "facts, and no wrapper minted for the no-op");
    }

    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
}

int main(void)
{
    /* The fixture's program, as runtime/LFAC.2.5.1 writes it. */
    run("as written",
        "{\"k\": 1, \"n\": [1, 2, 3]}",
        "{\"k\": 1, \"n\": [1, 2, 3]}",
        "{\"k\": 2, \"n\": [1, 2, 3]}");
    /* The no-op with its members in another order: still the same value. */
    run("members reordered",
        "{\"k\": 1, \"n\": [1, 2, 3]}",
        "{\"n\": [1, 2, 3], \"k\": 1}",
        "{\"k\": 2, \"n\": [1, 2, 3]}");
    if (failures) {
        fprintf(stderr, "test_lfac_2_5_1_json_key_noop: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_lfac_2_5_1_json_key_noop: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NCBK.7.2]
 * "The caller passes the DS_CACHE_CB_ABI_VERSION it compiled against, which
 * is 3 in this edition. A mismatch is refused with DS_ERR_BACKEND_ABI_VERSION
 * and registers nothing".
 *
 * THE PATH: dispatcher.c's ds_engine_cache_callbacks ([STYL.5.10.8]).
 *
 *   version 2    the last version, whose set callback took five arguments: a
 *                caller built against that header must not be handed the
 *                payload. Refused, and a rule's later write reaches no callback
 *                while the engine's own cache still takes it, so the program
 *                did write.
 *   this version DS_OK, and the same write reaches the callback once. It is the
 *                control that shows the write above would have been seen.
 *   the number   this edition's version is 3, a literal on purpose: the clause
 *                states the number, and it is append-only.
 */
#include "spec_common.h"

#include <stdbool.h>

static const char *PROGRAM =
    "schema Trig scope logical:\n"
    "    k: Int key\n"
    "\n"
    "schema Seen scope logical:\n"
    "    k: Int key\n"
    "\n"
    "rule writer:\n"
    "    Trig t\n"
    "->\n"
    "    cache key: \"k\" value: t.k\n"
    "    emit Seen logical k: t.k\n";

static int g_sets;
static int g_set_events;

static ds_result_t on_set(ds_engine_t *e, const ds_cache_write_t *write, void *user)
{
    (void) e; (void) write; (void) user;
    g_sets++;
    return DS_OK_R;
}

static ds_result_t on_stream(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e; (void) user;
    if (ev->kind == DS_EV_ACTION_CACHE_SET) g_set_events++;
    return DS_OK_R;
}

/* A loaded engine; one Trig through one pump, so `writer` writes once. */
static int run_one_write(uint32_t abi_version, ds_status_t want_registration)
{
    g_sets = 0;
    g_set_events = 0;
    ds_engine_t *e = NULL;
    EXPECT_OK("engine_new", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("stream callback", ds_engine_set_stream_callback(e, on_stream, NULL));
    EXPECT_STATUS("registration",
                  ds_engine_cache_callbacks(e, abi_version, on_set, NULL, NULL),
                  want_registration);

    const ds_schema_t *trig = NULL;
    EXPECT_OK("find Trig", ds_engine_schema_find(e, "Trig", &trig));
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i  = 7;
    EXPECT_OK("assert", ds_engine_assert(e, trig, &v, 1, NULL));
    EXPECT_OK("pump", ds_engine_pump(e));
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (DS_CACHE_CB_ABI_VERSION != 3u) {
        fprintf(stderr, "FAIL: DS_CACHE_CB_ABI_VERSION is %u, not 3\n",
                (unsigned) DS_CACHE_CB_ABI_VERSION);
        return 1;
    }

    if (run_one_write(2u, DS_ERR_BACKEND_ABI_VERSION)) return 1;
    if (g_set_events != 1) {
        fprintf(stderr, "FAIL: premise: the rule wrote %d times\n", g_set_events);
        return 1;
    }
    if (g_sets != 0) {
        fprintf(stderr, "FAIL: a refused registration registered: %d calls\n", g_sets);
        return 1;
    }

    if (run_one_write(DS_CACHE_CB_ABI_VERSION, DS_OK)) return 1;
    if (g_sets != 1) {
        fprintf(stderr, "FAIL: the control: %d calls, want 1\n", g_sets);
        return 1;
    }

    printf("test_ncbk_7_2__abi_version_2_is_refused: OK\n");
    return 0;
}

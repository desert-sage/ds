/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NRTM.3.1]
 * This edition has no working-memory bound: the engine must not refuse an
 * assert for the size of working memory, and a loaded program does not
 * engage realtime. ds_engine_set_wm_max is internal (engine.h, [NRTM.9.1]):
 * with a program loaded, set_wm_max(1) and set_wm_max(0) each leave the
 * engine out of rt_mode, and two asserts both succeed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define CHECK_OK(r, msg)                                                      \
    do {                                                                      \
        ds_result_t rr_ = (r);                                                \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "v", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static void run(uint32_t n_max, const char *label)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       1000000000ull, SLOTS, 1, &sc),
             "register_schema");
    CHECK(e->rete_engine != NULL && e->rete_engine->schema_count > 0,
          "a program is loaded -- premise");

    CHECK_OK(ds_engine_set_wm_max(e, n_max), label);
    CHECK(e->rete_engine != NULL && !e->rete_engine->rt_mode,
          "the engine is not in rt_mode after set_wm_max");

    ds_slot_value_t v[1];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;
    v[0].v.i = 1;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, NULL), "first assert");
    v[0].v.i = 2;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, NULL), "second assert, past N_max");

    size_t n = 0;
    CHECK_OK(ds_engine_fact_count(e, &n), "fact_count");
    CHECK(n == 2, "both facts are live: nothing was refused for N_max");
    CHECK(e->rete_engine != NULL && !e->rete_engine->rt_mode,
          "still not in rt_mode after the asserts");

    ds_engine_free(e);
}

int main(void)
{
    run(1, "set_wm_max(1) after a load");
    run(0, "set_wm_max(0) after a load");

    if (failures == 0) {
        printf("OK  test_nrtm_3_1_wm_max_advisory\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}

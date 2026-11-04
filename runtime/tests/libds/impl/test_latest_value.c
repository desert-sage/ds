/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [LFAC.1.7.2]: a logical schema whose every slot is mutable has an empty
 * identity key, so each assert supersedes the last and working memory holds
 * one fact. A control schema with its slot marked `key` accumulates.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/wm_rete.h"

#define WM_TOMB ((ds_rete_fact_t *)(uintptr_t)1)

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "");
        return 1;
    }
    return 0;
}

static int reg_schema(ds_engine_t *engine, const char *name, bool key_slot,
                      const ds_schema_t **out_ds)
{
    ds_slot_desc_t sd = { .name = "val", .type = DS_SLOT_TYPE_INT,
                          .identity_role = key_slot ? DS_IDENTITY_KEY
                                                    : DS_IDENTITY_MUTABLE };
    ds_result_t r = ds_engine_register_schema(engine, name,
                                              DS_SCHEMA_LIFECYCLE_LOGICAL,
                                              0, &sd, 1, out_ds);
    if (r.status != DS_OK) return 1;
    return 0;
}

/* Count live RETE facts of `s` whose slot[0] int value equals `v`
 * (v < 0 ⇒ count all facts of the schema regardless of value). */
static int count_rete(ds_rete_engine_t *re, const ds_rete_schema_t *s, int64_t v)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (!f) continue;
        if (f->schema != s) continue;
        if (v < 0 || f->slots[0].i == v) n++;
    }
    return n;
}

static int assert_int(ds_engine_t *e, const ds_schema_t *sc, int64_t v)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_INT, .v.i = v };
    return ds_engine_assert(e, sc, &sv, 1, NULL).status;
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (expect_ok("engine_new", ds_engine_new(&cfg, &e))) return 1;

    /* Amb: key=∅, latest wins. Plain: key=all, distinct values accumulate. */
    const ds_schema_t *amb = NULL, *plain = NULL;
    if (reg_schema(e, "Amb",   false, &amb))  { fprintf(stderr, "FAIL: reg Amb\n");   return 1; }
    if (reg_schema(e, "Plain", true,  &plain)){ fprintf(stderr, "FAIL: reg Plain\n"); return 1; }

    ds_rete_engine_t *re = e->rete_engine;
    const ds_rete_schema_t *amb_rs   = ds_rete_schema_by_name(re, "Amb");
    const ds_rete_schema_t *plain_rs = ds_rete_schema_by_name(re, "Plain");
    if (!amb_rs || !plain_rs) { fprintf(stderr, "FAIL: rete schema lookup\n"); return 1; }

    for (int64_t v = 10; v <= 50; v += 10) {
        if (assert_int(e, amb, v) != DS_OK) {
            fprintf(stderr, "FAIL: assert Amb(%lld)\n", (long long)v); return 1;
        }
        int t = count_rete(re, amb_rs, -1);
        if (t != 1) {
            fprintf(stderr, "FAIL: Amb count after assert(%lld) = %d, want 1\n",
                    (long long)v, t);
            return 1;
        }
    }
    if (count_rete(re, amb_rs, 50) != 1 ||
        count_rete(re, amb_rs, 10) != 0 ||
        count_rete(re, amb_rs, 40) != 0) {
        fprintf(stderr, "FAIL: surviving Amb fact is not the latest (50)\n");
        return 1;
    }

    for (int64_t v = 1; v <= 5; v++) {
        if (assert_int(e, plain, v) != DS_OK) {
            fprintf(stderr, "FAIL: assert Plain(%lld)\n", (long long)v); return 1;
        }
    }
    int pc = count_rete(re, plain_rs, -1);
    if (pc != 5) {
        fprintf(stderr,
                "FAIL: Plain count = %d, want 5 (control must accumulate)\n", pc);
        return 1;
    }

    if (assert_int(e, amb, 60) != DS_OK) { fprintf(stderr, "FAIL: assert Amb(60)\n"); return 1; }
    if (count_rete(re, amb_rs, -1) != 1) {
        fprintf(stderr, "FAIL: Amb count != 1 after re-assert\n"); return 1;
    }

    ds_engine_free(e);
    printf("test_latest_value: OK\n");
    return 0;
}

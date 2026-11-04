/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [NFCT.2.10]: the host supplies `ts`. Where a schema declares `ts`, a
 * DS_SLOT_NULL there is a null in a slot that is not nullable, and
 * ds_engine_assert refuses it with DS_ERR_SLOT_TYPE_MISMATCH, leaving working
 * memory as it was. The same fact with `ts` a DS_SLOT_INT of UTC nanoseconds
 * is taken, so the refusal is the null's and not the schema's or the slot's
 * type's.
 *
 * Path: the public ds_engine_assert into the Rete bridge's slot-kind check,
 * rete/wm_rete.c rete_validate_slot_kinds, its null arm.
 */
#include "spec_common.h"

/* The index of the slot named `name` in `s`, with its descriptor. */
static int slot_named(const ds_schema_t *s, const char *name,
                      uint32_t *out_ix, ds_slot_desc_t *out_desc)
{
    uint32_t n = 0;
    ds_result_t r = ds_schema_get_slot_count(s, &n);
    if (r.status != DS_OK) return spec_fail("get_slot_count", r);
    for (uint32_t i = 0; i < n; i++) {
        r = ds_schema_get_slot(s, i, out_desc);
        if (r.status != DS_OK) return spec_fail("get_slot", r);
        if (out_desc->name != NULL && strcmp(out_desc->name, name) == 0) {
            *out_ix = i;
            return 0;
        }
    }
    fprintf(stderr, "FAIL: no slot named %s\n", name);
    return 1;
}

int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    EXPECT_OK("engine_new", r);
    r = spec_load_ds(e, "schema Reading scope logical:\n"
                        "    k: Int key\n"
                        "    ts: Time\n");
    EXPECT_OK("load Reading", r);
    const ds_schema_t *s = NULL;
    r = ds_engine_schema_find(e, "Reading", &s);
    if (r.status != DS_OK || s == NULL) return spec_fail("schema_find Reading", r);

    uint32_t k_ix = 0, ts_ix = 0;
    ds_slot_desc_t k_desc, ts_desc;
    if (slot_named(s, "k", &k_ix, &k_desc) || slot_named(s, "ts", &ts_ix, &ts_desc))
        return 1;
    if (ts_desc.type != DS_SLOT_TYPE_TIME || ts_desc.nullable) {
        fprintf(stderr, "FAIL: ts is type %d, nullable %d; want a non-nullable Time\n",
                (int) ts_desc.type, (int) ts_desc.nullable);
        return 1;
    }

    ds_slot_value_t vals[2];
    memset(vals, 0, sizeof vals);
    vals[k_ix].kind  = DS_SLOT_INT;
    vals[k_ix].v.i   = 1;
    vals[ts_ix].kind = DS_SLOT_NULL;

    ds_fact_t *f = NULL;
    r = ds_engine_assert(e, s, vals, 2, &f);
    EXPECT_STATUS("assert with a null ts", r, DS_ERR_SLOT_TYPE_MISMATCH);
    size_t live = 99;
    r = ds_engine_fact_count(e, &live);
    EXPECT_OK("fact_count after the refusal", r);
    if (live != 0) {
        fprintf(stderr, "FAIL: the refused assert left %zu facts; want 0\n", live);
        return 1;
    }

    vals[ts_ix].kind = DS_SLOT_INT;
    vals[ts_ix].v.i  = 1700000000000000000LL;
    r = ds_engine_assert(e, s, vals, 2, &f);
    EXPECT_OK("the same fact with ts supplied", r);
    r = ds_engine_fact_count(e, &live);
    EXPECT_OK("fact_count after the supplied ts", r);
    if (live != 1) {
        fprintf(stderr, "FAIL: %zu facts after the supplied ts; want 1\n", live);
        return 1;
    }

    ds_engine_free(e);
    printf("test_nfct_2_10__null_ts_refused: OK\n");
    return 0;
}

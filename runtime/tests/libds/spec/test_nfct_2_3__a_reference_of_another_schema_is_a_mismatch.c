/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NFCT.2.3]
 * @spec [NFCT.2.11]
 * A DS_SLOT_TYPE_SCHEMA slot takes "a live fact whose schema equals the
 * slot's `schema_ref`", and a value its slot does not admit is
 * DS_ERR_SLOT_TYPE_MISMATCH at [NFCT.2.11]'s step 4.
 *
 * THE PATH: ds_engine_assert -> wm_validate_assert_values, its
 * DS_SLOT_TYPE_SCHEMA arm ([STYL.5.10.8]).
 *
 * `Main.r` is a `Ref`; the wrong value is a live `Tag`, which is also what makes
 * it the target's schema that is judged rather than its liveness. Three refused
 * asserts, each changing nothing and recording nothing:
 *
 *   the reference alone; the reference beside a NaN in a later slot, which step 4
 *   comes ahead of; and the reference beside a kind mismatch in an earlier slot,
 *   the same status, so this one shows only that the call is still refused.
 *
 * THE CONTROL: the same assert naming a `Ref` is admitted, adds its fact and
 * records events, so the refusals are the target's and both counts can move. The
 * Mercury runtime's `test_nfct_2_3_wrong_target` holds the same three.
 */
#include <math.h>

#include "spec_common.h"

static const char *PROGRAM =
    "schema Ref scope logical:\n"
    "    id: String key\n"
    "\n"
    "schema Tag scope logical:\n"
    "    id: String key\n"
    "\n"
    "schema Main scope logical:\n"
    "    k: Int key\n"
    "    r: Ref mutable\n"
    "    x: Float mutable\n";

static int g_events;

static ds_result_t count_events(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e; (void) ev; (void) user;
    g_events++;
    return DS_OK_R;
}

static int refused(ds_engine_t *e, const ds_schema_t *main_schema,
                   const ds_slot_value_t *values, const char *what)
{
    size_t before = 0, after = 0;
    EXPECT_OK("fact_count", ds_engine_fact_count(e, &before));
    g_events = 0;
    EXPECT_STATUS(what, ds_engine_assert(e, main_schema, values, 3, NULL),
                  DS_ERR_SLOT_TYPE_MISMATCH);
    EXPECT_OK("fact_count", ds_engine_fact_count(e, &after));
    if (after != before || g_events != 0) {
        fprintf(stderr, "FAIL: %s: %zu facts became %zu and %d stream events, "
                "want no change and none\n", what, before, after, g_events);
        return 1;
    }
    return 0;
}

int main(void)
{
    ds_engine_t *e = NULL;
    const ds_schema_t *ref = NULL, *tag = NULL, *main_schema = NULL;
    ds_fact_t *a_ref = NULL, *a_tag = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, &e));
    EXPECT_OK("load", spec_load_ds(e, PROGRAM));
    EXPECT_OK("find Ref", ds_engine_schema_find(e, "Ref", &ref));
    EXPECT_OK("find Tag", ds_engine_schema_find(e, "Tag", &tag));
    EXPECT_OK("find Main", ds_engine_schema_find(e, "Main", &main_schema));

    ds_slot_value_t id;
    memset(&id, 0, sizeof id);
    id.kind = DS_SLOT_STRING;
    id.v.s = "x";
    EXPECT_OK("assert Ref", ds_engine_assert(e, ref, &id, 1, &a_ref));
    EXPECT_OK("assert Tag", ds_engine_assert(e, tag, &id, 1, &a_tag));
    EXPECT_OK("stream", ds_engine_set_stream_callback(e, count_events, NULL));

    ds_slot_value_t v[3];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT;      v[0].v.i = 1;
    v[1].kind = DS_SLOT_FACT_REF; v[1].v.ref = a_tag;
    v[2].kind = DS_SLOT_FLOAT;    v[2].v.f = 1.0;
    if (refused(e, main_schema, v, "a reference of another schema")) return 1;

    v[2].v.f = NAN;
    if (refused(e, main_schema, v, "the reference ahead of a NaN in a later slot"))
        return 1;
    v[2].v.f = 1.0;

    v[0].kind = DS_SLOT_STRING; v[0].v.s = "x";
    if (refused(e, main_schema, v, "a kind mismatch in an earlier slot"))
        return 1;
    v[0].kind = DS_SLOT_INT; v[0].v.i = 1;

    /* The control. */
    size_t before = 0, after = 0;
    EXPECT_OK("fact_count", ds_engine_fact_count(e, &before));
    g_events = 0;
    v[1].v.ref = a_ref;
    EXPECT_OK("a reference of the slot's schema",
              ds_engine_assert(e, main_schema, v, 3, NULL));
    EXPECT_OK("fact_count", ds_engine_fact_count(e, &after));
    if (after != before + 1 || g_events == 0) {
        fprintf(stderr, "FAIL: the control: %zu facts became %zu and %d stream "
                "events, want one more and some\n", before, after, g_events);
        return 1;
    }

    EXPECT_OK("free", ds_engine_free(e));
    printf("test_nfct_2_3__a_reference_of_another_schema_is_a_mismatch: OK\n");
    return 0;
}

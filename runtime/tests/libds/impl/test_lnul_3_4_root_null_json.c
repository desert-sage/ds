/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A `Json` value whose root is null is the canonical null ([LNUL.3.4]): in a
 * `Json?` slot it is stored as null, and in a `Json` slot it is refused as any
 * null into a slot not declared `T?` is ([LNUL.3.1]). A document that merely
 * contains a null is untouched. On both of libds's paths:
 *
 *   HOST.  ds_engine_assert: engine_assert_body (wm.c).
 *   RULE.  ds_rete_lnul_3_4_canonical (rete/wm_rete.c), which a rule's emit
 *          (rete/engine.c) and ds_rete_publish_values (rete/adapters.c) call
 *          before ds_rete_slot_refused. No DS source reaches it, so it is
 *          driven here directly. Mercury's ds.wm.assert_fact does the same.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fails;

#define CHECK(cond, msg) do { if (!(cond)) { \
    fprintf(stderr, "  FAIL: %s\n", (msg)); fails++; } } while (0)

static const ds_slot_desc_t J_SLOTS[2] = {
    { .name = "k",   .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "doc", .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
};
static const ds_slot_desc_t JQ_SLOTS[2] = {
    { .name = "k",   .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "doc", .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE,
      .nullable = true },
};

static ds_engine_t *engine_with(const ds_schema_t **j, const ds_schema_t **jq)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) return NULL;
    if (ds_engine_register_schema(e, "J", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  J_SLOTS, 2, j).status != DS_OK
        || ds_engine_register_schema(e, "JQ", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     JQ_SLOTS, 2, jq).status != DS_OK) {
        ds_engine_free(e);
        return NULL;
    }
    return e;
}

static ds_json_t *root_null(void)
{
    ds_json_t *j = NULL;
    return ds_json_new_null(&j).status == DS_OK ? j : NULL;
}

static ds_json_t *object_with_null(void)
{
    ds_json_t *obj = NULL, *leaf = NULL;
    if (ds_json_new_object(&obj).status != DS_OK) return NULL;
    if (ds_json_new_null(&leaf).status != DS_OK
        || ds_json_object_set(obj, "a", 1, leaf).status != DS_OK) {
        ds_json_free(obj);
        return NULL;
    }
    return obj;
}

/* @spec [LNUL.3.4] */
static void test_host_door(void)
{
    const ds_schema_t *j = NULL, *jq = NULL;
    ds_engine_t *e = engine_with(&j, &jq);
    CHECK(e != NULL, "host: engine with J and JQ");
    if (e == NULL) return;

    /* Json? : stored, and stored as null. */
    ds_json_t *doc = root_null();
    ds_slot_value_t v[2] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                             { .kind = DS_SLOT_JSON, .v.json = doc } };
    ds_fact_t *f = NULL;
    ds_result_t r = ds_engine_assert(e, jq, v, 2, &f);
    CHECK(r.status == DS_OK && f != NULL,
          "host: a root-null Json is admitted into a Json? slot");
    if (r.status == DS_OK && f != NULL) {
        ds_slot_value_t got;
        CHECK(ds_fact_get_slot(f, 1, NULL, &got).status == DS_OK
                  && got.kind == DS_SLOT_NULL,
              "host: and reads back as DS_SLOT_NULL, not a document");
    }
    ds_json_free(doc);   /* the caller's tree, whatever the assert did */

    /* Json : refused, as any null into a slot not declared T?. */
    doc = root_null();
    v[0].v.i = 2;
    v[1].v.json = doc;
    r = ds_engine_assert(e, j, v, 2, NULL);
    CHECK(r.status == DS_ERR_SLOT_TYPE_MISMATCH,
          "host: a root-null Json into a Json slot is DS_ERR_SLOT_TYPE_MISMATCH");
    ds_json_free(doc);

    /* A document that contains a null is a document, in either slot. */
    doc = object_with_null();
    v[0].v.i = 3;
    v[1].v.json = doc;
    f = NULL;
    r = ds_engine_assert(e, j, v, 2, &f);
    CHECK(r.status == DS_OK && f != NULL, "host: {\"a\": null} enters a Json slot");
    if (r.status == DS_OK && f != NULL) {
        ds_slot_value_t got;
        CHECK(ds_fact_get_slot(f, 1, NULL, &got).status == DS_OK
                  && got.kind == DS_SLOT_JSON,
              "host: and stays a document");
    }
    ds_json_free(doc);

    ds_engine_free(e);
}

/* @spec [LNUL.3.4] [RARC.5.2.7] */
static void test_rule_path(void)
{
    const ds_schema_t *j = NULL, *jq = NULL;
    ds_engine_t *e = engine_with(&j, &jq);
    CHECK(e != NULL, "rule: engine with J and JQ");
    if (e == NULL) return;
    const ds_rete_schema_t *rj  = ds_rete_schema_by_name(e->rete_engine, "J");
    const ds_rete_schema_t *rjq = ds_rete_schema_by_name(e->rete_engine, "JQ");
    CHECK(rj != NULL && rjq != NULL, "rule: both Rete schemas");
    if (rj == NULL || rjq == NULL) { ds_engine_free(e); return; }

    ds_json_t *doc = root_null();
    ds_json_t *obj = object_with_null();

    /* Json? : the document becomes the null, and the slot admits it. */
    ds_rete_val_t s[2] = { ds_rete_val_int(1), { .kind = DS_RETE_VAL_JSON_BORROW } };
    s[1].json = doc;
    ds_rete_lnul_3_4_canonical(rjq, s);
    CHECK(s[1].kind == DS_RETE_VAL_NULL,
          "rule: a root-null Json becomes the null before a Json? slot");
    CHECK(ds_rete_slot_refused(rjq, s) == -1, "rule: and a Json? slot admits it");

    /* Json : the same null, refused at the slot (RARC.5.2.7's TypeError). */
    s[1] = (ds_rete_val_t){ .kind = DS_RETE_VAL_JSON_BORROW };
    s[1].json = doc;
    ds_rete_lnul_3_4_canonical(rj, s);
    CHECK(s[1].kind == DS_RETE_VAL_NULL,
          "rule: a root-null Json becomes the null before a Json slot");
    CHECK(ds_rete_slot_refused(rj, s) == 1, "rule: and a Json slot refuses it");

    /* A document that contains a null is untouched. */
    s[1] = (ds_rete_val_t){ .kind = DS_RETE_VAL_JSON_BORROW };
    s[1].json = obj;
    ds_rete_lnul_3_4_canonical(rj, s);
    CHECK(s[1].kind == DS_RETE_VAL_JSON_BORROW && s[1].json == obj,
          "rule: {\"a\": null} stays the document it was");

    ds_json_free(doc);
    ds_json_free(obj);
    ds_engine_free(e);
}

int main(void)
{
    printf("=== test_lnul_3_4_root_null_json ===\n");
    test_host_door();
    test_rule_path();
    if (fails == 0) {
        printf("=== test_lnul_3_4_root_null_json: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_lnul_3_4_root_null_json: %d FAILED ===\n", fails);
    return 1;
}

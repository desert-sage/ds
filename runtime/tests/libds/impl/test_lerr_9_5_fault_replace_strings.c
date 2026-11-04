/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A fault fact that replaces the live one at its site ([LERR.9.5]) keeps the
 * strings the two share. assert_one (rete/fault_fact.c) interns the
 * replacement's strings as counted values, so a shared one is the live fact's
 * own entry, and retracting the live fact must not free it.
 *
 * Two faults of different kinds at one `(node, rule)` site, each drained, as
 * two inputs to one join test raise them (the lockstep pair
 * 125/92_fault_supersede). The rule is `$beta_4`, a counted
 * matching-time name; a terminal's rule name is pinned.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/fault_fact.h"

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

/* The built-in ComputationError, slots in [LERR.9.2]'s order, registered as
   test_fault_emission registers it: every slot MUTABLE, since the public API
   has no `explicit` lifecycle. The drain does not read the lifecycle. */
static const ds_slot_desc_t CE_SLOTS[5] = {
    { .name = "kind",   .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "rule",   .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "schema", .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "slot",   .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_MUTABLE },
    { .name = "node",   .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_MUTABLE },
};

/* The ComputationError events on the stream. */
static const ds_schema_t *g_ce = NULL;
static int g_asserts = 0, g_retracts = 0;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *u)
{
    (void)e; (void)u;
    const ds_fact_t *f = NULL;
    if (ev->kind == DS_EV_FACT_ASSERT)       f = ev->p.fact_assert.fact;
    else if (ev->kind == DS_EV_FACT_RETRACT) f = ev->p.fact_retract.fact;
    if (f == NULL) return DS_OK_R;
    const ds_schema_t *sc = NULL;
    if (ds_fact_get_schema(f, &sc).status != DS_OK || sc != g_ce)
        return DS_OK_R;
    if (ev->kind == DS_EV_FACT_ASSERT) g_asserts++; else g_retracts++;
    return DS_OK_R;
}

/* The live ComputationError: how many, and its string slots, copied out. */
typedef struct {
    int  count;
    char kind[32], rule[32], schema[32], slot[32];
} ce_view_t;

static void copy_slot(const ds_fact_t *f, uint32_t i, char *out, size_t cap)
{
    ds_slot_value_t sv;
    out[0] = '\0';
    if (ds_fact_get_slot(f, i, NULL, &sv).status != DS_OK
            || sv.kind != DS_SLOT_STRING || sv.v.s == NULL)
        return;
    /* Bounded: a corrupt slot need not be terminated where a name would be. */
    size_t n = 0;
    while (n + 1 < cap && sv.v.s[n] != '\0') { out[n] = sv.v.s[n]; n++; }
    out[n] = '\0';
}

static ds_result_t visit(const ds_fact_t *f, void *user)
{
    ce_view_t *v = (ce_view_t *)user;
    v->count++;
    copy_slot(f, 0, v->kind,   sizeof v->kind);
    copy_slot(f, 1, v->rule,   sizeof v->rule);
    copy_slot(f, 2, v->schema, sizeof v->schema);
    copy_slot(f, 3, v->slot,   sizeof v->slot);
    return DS_OK_R;
}

static ce_view_t live_ce(ds_engine_t *e)
{
    ce_view_t v;
    memset(&v, 0, sizeof v);
    CHECK_OK(ds_engine_for_each_fact(e, g_ce, visit, &v), "for_each CE");
    return v;
}

static void fault(ds_engine_t *e, const char *kind)
{
    /* The rule text from a buffer of its own, as a node's stored name is: the
       intern table must not be handed a literal it might already hold. */
    static char rule[16];
    strcpy(rule, "$beta_4");
    const ds_rete_fault_fact_t f = {
        .type_error = false, .what = kind, .rule = rule,
        .schema = "Q", .slot = "d", .node = 4u,
    };
    ds_rete_fault_fact_enqueue(e->rete_engine, &f);
    CHECK_OK(ds_rete_fault_fact_drain(e->rete_engine), "drain");
}

int main(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK) {
        fprintf(stderr, "FAIL: engine_new\n"); return 1;
    }
    CHECK_OK(ds_engine_register_schema(e, "ComputationError",
                                       DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       CE_SLOTS, 5, &g_ce),
             "register ComputationError");
    CHECK_OK(ds_engine_set_stream_callback(e, on_event, NULL), "stream cb");

    /* The first fault at the site: asserted. */
    fault(e, "DIVIDE_BY_ZERO");
    ce_view_t first = live_ce(e);
    CHECK(first.count == 1 && strcmp(first.rule, "$beta_4") == 0,
          "premise: the first fault fact is live, rule $beta_4");

    /* A different fault at the same site: the live fact is withdrawn and the
       replacement asserted ([LERR.9.5]). */
    g_asserts = g_retracts = 0;
    fault(e, "NOT_REPRESENTABLE");
    ce_view_t second = live_ce(e);
    printf("  replacement: %d live; kind=%s rule=%s schema=%s slot=%s; "
           "%d assert(s), %d retract(s)\n",
           second.count, second.kind, second.rule, second.schema, second.slot,
           g_asserts, g_retracts);
    CHECK(g_retracts == 1 && g_asserts == 1,
          "premise: the live fact was withdrawn and the replacement asserted");
    CHECK(second.count == 1, "one live fault fact at the site ([LERR.9.5])");
    CHECK(strcmp(second.kind, "NOT_REPRESENTABLE") == 0,
          "the replacement's kind is the new fault's");
    CHECK(strcmp(second.rule, "$beta_4") == 0,
          "the replacement keeps the rule the two share");
    CHECK(strcmp(second.schema, "Q") == 0,
          "the replacement keeps the schema the two share");
    CHECK(strcmp(second.slot, "d") == 0,
          "the replacement keeps the slot the two share");

    /* The same fault again is a suppressed no-op: the latch still finds the
       site, so the replacement's rule really is the site's. */
    g_asserts = g_retracts = 0;
    fault(e, "NOT_REPRESENTABLE");
    CHECK(g_asserts == 0 && g_retracts == 0 && live_ce(e).count == 1,
          "an identical fault at the site is a suppressed no-op");

    CHECK_OK(ds_engine_set_stream_callback(e, NULL, NULL), "stream cb off");
    ds_engine_free(e);
    if (failures) {
        fprintf(stderr, "test_lerr_9_5_fault_replace_strings: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_lerr_9_5_fault_replace_strings: OK\n");
    return 0;
}

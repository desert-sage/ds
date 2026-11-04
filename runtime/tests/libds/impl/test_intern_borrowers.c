/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Borrowers of an interned counted fact-slot string keep it alive
 * independently of the originating fact, by a private copy or a lock-step
 * intern ref ([IDAT.4.7]). A regression is a dangling read or a cross-engine
 * double free, so this file runs in the leak lanes (libds.build's ImplTest
 * `leak` column).
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "schema.h"
#include "rete/action.h"
#include "rete/beta.h"
#include "rete/expr.h"
#include "rete/loader.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/val.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
        g_fails++;                                                           \
    } } while (0)

/* Live counted-string entries = all interned entries minus the pinned
   (structural / engine-lifetime) set. Fact-slot values are the counted ones. */
static size_t counted(ds_engine_t *e)
{
    size_t n = 0;
    ds_rete_intern_mem(e->rete_engine->intern, &n, NULL, NULL);
    return n - ds_rete_intern_pinned_count(e->rete_engine->intern);
}

/* The interned pointer for `s` in e's table, or NULL if absent. Non-mutating. */
static const char *find_ptr(ds_engine_t *e, const char *s)
{
    const char *out = NULL;
    ds_rete_intern_find(e->rete_engine->intern, s, strlen(s), &out);
    return out;
}

static ds_result_t reg_str_schema(ds_engine_t *e, const char *name,
                                  const ds_schema_t **out)
{
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_STRING,
                          .identity_role = DS_IDENTITY_KEY };
    return ds_engine_register_schema(e, name, DS_SCHEMA_LIFECYCLE_LOGICAL,
                                     0, &sd, 1, out);
}

static ds_fact_t *assert_str(ds_engine_t *e, const ds_schema_t *sc, const char *s)
{
    ds_slot_value_t sv = { .kind = DS_SLOT_STRING, .v.s = s };
    ds_fact_t *f = NULL;
    if (ds_engine_assert(e, sc, &sv, 1, &f).status != DS_OK)
        return NULL;
    return f;
}

/* A clone re-interns each counted String into its own table, and its clock
   reads the clone, not the source: either engine frees first. */
static void test_clone_counted_slot_independence(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *src = NULL;
    CHECK(ds_engine_new(&cfg, &src).status == DS_OK, "engine_new src");
    if (src == NULL) return;

    const ds_schema_t *sc = NULL;
    CHECK(reg_str_schema(src, "S", &sc).status == DS_OK, "register string schema");

    size_t base = counted(src);
    ds_fact_t *fa = assert_str(src, sc, "alpha");
    ds_fact_t *fb = assert_str(src, sc, "beta");
    ds_fact_t *fc = assert_str(src, sc, "gamma");
    CHECK(fa && fb && fc, "assert three string facts");
    CHECK(counted(src) == base + 3, "src holds three counted strings");

    ds_engine_t *clone = NULL;
    CHECK(ds_engine_clone(src, &clone).status == DS_OK && clone != NULL, "clone ok");
    if (clone == NULL) { ds_engine_free(src); return; }

    CHECK(counted(clone) == counted(src), "clone re-interned every counted string");

    const char *p_src = find_ptr(src, "beta");
    const char *p_clone = find_ptr(clone, "beta");
    CHECK(p_src != NULL && p_clone != NULL, "both engines hold \"beta\"");
    CHECK(p_src != p_clone, "clone owns a distinct interned pointer, not src's");

    CHECK(ds_engine_retract(src, fb).status == DS_OK, "retract beta from src");
    CHECK(counted(src) == base + 2, "src released beta");
    CHECK(find_ptr(src, "beta") == NULL, "beta gone from src");
    CHECK(find_ptr(clone, "beta") != NULL, "clone still holds beta after src retract");
    CHECK(counted(clone) == base + 3, "clone counted set unchanged by src retract");

    CHECK(ds_engine_free(src).status == DS_OK, "free src first");
    CHECK(find_ptr(clone, "alpha") != NULL, "clone keeps its strings after src free");

    /* Reads the clone's clock, which must not point at the freed src. */
    CHECK(ds_engine_pump(clone).status == DS_OK, "clone pump after src free");

    const ds_schema_t *csc = NULL;
    ds_schema_registry_find(&clone->schemas, "S", &csc);
    CHECK(csc != NULL, "clone owns its schema");
    ds_fact_t *fd = assert_str(clone, csc, "delta");
    CHECK(fd != NULL, "clone still asserts after src free");
    CHECK(counted(clone) == base + 4, "clone interned the post-free value");

    CHECK(ds_engine_free(clone).status == DS_OK, "free clone");
}

static ds_rete_expr_t *var(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat;
    e->var.slot_index = slot;
    return e;
}

/*
 * A logical Derived copies a String slot from a TTL-bounded Source. The TTL
 * sweep retracts Source, whose cascade retracts Derived through the deferred
 * recorder scope; the flush reads Derived's wrapper slot after Source has
 * dropped its ref, so the wrapper must hold its own (rete_val_to_slot).
 */
static void test_logical_derived_bounded_by_ttl_source(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;

    CHECK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK).status == DS_OK, "clock -> mock");
    CHECK(ds_engine_clock_set(e, 0).status == DS_OK, "clock set 0");

    ds_slot_desc_t src_sd = { .name = "sid", .type = DS_SLOT_TYPE_STRING,
                              .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *src_ds = NULL;
    CHECK(ds_engine_register_schema(e, "Source", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &src_sd, 1, &src_ds).status == DS_OK, "reg Source");
    ds_slot_desc_t der_sd = { .name = "sid", .type = DS_SLOT_TYPE_STRING,
                              .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *der_ds = NULL;
    CHECK(ds_engine_register_schema(e, "Derived", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &der_sd, 1, &der_ds).status == DS_OK, "reg Derived");
    (void)der_ds;

    const ds_rete_schema_t *der_rs = ds_rete_schema_by_name(e->rete_engine, "Derived");
    CHECK(der_rs != NULL, "rete Derived handle");
    if (der_rs == NULL) { ds_engine_free(e); return; }

    /* Network: `Source s -> emit Derived logical sid: s.sid`. */
    ds_rete_expr_t *sid_expr = var(0, 0);
    ds_rete_slot_assign_t assign = { .slot_index = 0, .expr = sid_expr };
    ds_rete_action_t action = { .kind = DS_RETE_ACTION_LOGICAL_ASSERT,
                                .schema_id = der_rs->id,
                                .assigns = &assign, .assign_count = 1 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Source" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1, .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "derive",
                                 .actions = &action, .action_count = 1 }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    if (ds_rete_load_network(e->rete_engine, &net).status != DS_OK) {
        CHECK(0, "load network");
        ds_rete_expr_free_tree(sid_expr);
        ds_engine_free(e);
        return;
    }

    size_t base = counted(e);

    ds_slot_value_t sv = { .kind = DS_SLOT_STRING, .v.s = "shared" };
    ds_fact_t *src_fact = NULL;
    CHECK(ds_engine_assert_with_ttl(e, src_ds, &sv, 1,
                                    5000000000ULL, &src_fact).status == DS_OK,
          "assert Source ttl=5s");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump: derive fires");
    CHECK(find_ptr(e, "shared") != NULL, "shared interned after derive");
    CHECK(counted(e) > base, "derive interned the shared value");

    CHECK(ds_engine_clock_advance(e, 6000000000ULL).status == DS_OK, "advance 6s");
    CHECK(ds_engine_pump(e).status == DS_OK, "pump: ttl sweep + cascade retract");

    size_t n = 1;
    ds_engine_fact_count(e, &n);
    CHECK(n == 0, "Source (ttl) + Derived (cascade) both retracted -> wm empty");
    CHECK(find_ptr(e, "shared") == NULL, "shared reclaimed after cascade retract");
    CHECK(counted(e) == base, "counted set back to baseline (no leak)");

    CHECK(ds_engine_free(e).status == DS_OK, "free engine");
}

int main(void)
{
    g_fails = 0;
    test_clone_counted_slot_independence();
    test_logical_derived_bounded_by_ttl_source();

    if (g_fails) { printf("test_intern_borrowers: %d FAILURES\n", g_fails); return 1; }
    printf("test_intern_borrowers: ALL PASSED\n");
    return 0;
}

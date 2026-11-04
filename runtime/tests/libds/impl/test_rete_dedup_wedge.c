/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Bulk assert and re-sync of an identity schema through ds_engine_assert: a
 * 6-slot String schema whose slot 0 ("instance") is the constant "ha.home"
 * and whose slot 1 ("entity_id") is the discriminating identity. Each
 * scenario checks that
 *
 *   (a) every assert returns;
 *   (b) the per-schema wrapper list is acyclic (Floyd) and holds one wrapper
 *       per distinct identity, not one per assert;
 *   (c) the rete WM holds exactly one fact per identity.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "engine.h"
#include "schema.h"
#include "wm.h"
#include "rete/engine.h"
#include "rete/schema_reg.h"
#include "rete/wm_rete.h"

#define WM_TOMB ((ds_rete_fact_t *)(uintptr_t)1)

/* HassEntity slot layout. */
enum { SLOT_INSTANCE = 0, SLOT_ENTITY_ID, SLOT_STATE, SLOT_DOMAIN,
       SLOT_FRIENDLY, SLOT_TS, N_SLOTS };

static int expect(const char *what, int cond)
{
    if (!cond) { fprintf(stderr, "FAIL: %s\n", what); return 1; }
    return 0;
}

/* Register HassEntity in both registries with is_identity on `id_slot`. */
static int reg_hass(ds_engine_t *engine, const char *name, uint16_t id_slot,
                    const ds_schema_t **out_ds)
{
    /* The last slot is the entity's last-changed text. It is not named `ts`:
       on a logical schema that name is the engine's own Time slot, which
       register_schema refuses as a String KEY or MUTABLE ([NFCT.1.4.3]). */
    static const char *names[N_SLOTS] = {
        "instance", "entity_id", "state", "domain", "friendly_name",
        "last_changed" };

    ds_slot_desc_t ds_slots[N_SLOTS];
    for (int i = 0; i < N_SLOTS; i++) {
        ds_slots[i] = (ds_slot_desc_t){
            .name = names[i], .type = DS_SLOT_TYPE_STRING,
            .identity_role = (i == id_slot) ? DS_IDENTITY_KEY
                                            : DS_IDENTITY_MUTABLE };
    }
    ds_result_t r = ds_engine_register_schema(engine, name,
                                              DS_SCHEMA_LIFECYCLE_LOGICAL,
                                              0, ds_slots, N_SLOTS, out_ds);
    if (r.status != DS_OK) {
        fprintf(stderr, "  ds_engine_register_schema(%s) status=%d (%s)\n",
                name, r.status, r.detail ? r.detail : "");
        return 1;
    }
    /* ds_engine_register_schema registers the Rete schema too. */
    return 0;
}

static int assert_hass(ds_engine_t *e, const ds_schema_t *sc,
                       const char *entity_id, const char *state)
{
    ds_slot_value_t v[N_SLOTS] = {
        [SLOT_INSTANCE] = { .kind = DS_SLOT_STRING, .v.s = "ha.home" },
        [SLOT_ENTITY_ID]= { .kind = DS_SLOT_STRING, .v.s = entity_id },
        [SLOT_STATE]    = { .kind = DS_SLOT_STRING, .v.s = state },
        [SLOT_DOMAIN]   = { .kind = DS_SLOT_STRING, .v.s = "light" },
        [SLOT_FRIENDLY] = { .kind = DS_SLOT_STRING, .v.s = "Friendly" },
        [SLOT_TS]       = { .kind = DS_SLOT_STRING, .v.s = "2026-06-05" },
    };
    return ds_engine_assert(e, sc, v, N_SLOTS, NULL).status;
}

/* Walk the per-schema wrapper list with Floyd tortoise/hare cycle detection.
 * Returns the node count, or -1 if the list is cyclic (would spin forever). */
static long list_len_acyclic(const ds_schema_t *sc)
{
    const struct ds_schema *s = (const struct ds_schema *)(uintptr_t)sc;
    struct ds_fact *slow = s->fact_list_head;
    struct ds_fact *fast = s->fact_list_head;
    long n = 0;
    while (fast) {
        fast = fast->schema_next;
        if (!fast) break;
        fast = fast->schema_next;
        slow = slow->schema_next;
        if (slow == fast) return -1;   /* cycle */
    }
    for (struct ds_fact *f = s->fact_list_head; f; f = f->schema_next) n++;
    return n;
}

static long rete_count(ds_rete_engine_t *re, const ds_rete_schema_t *s)
{
    long n = 0;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (!f) continue;
        if (f->schema == s) n++;
    }
    return n;
}

/* A discriminating identity (slot 1): a bulk assert, then three re-syncs. */
static int test_discriminating_identity(void)
{
    const long N = 4000;            /* > a downstream tier's ~1000-entity sync */
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return expect("engine_new", 0);

    const ds_schema_t *sc = NULL;
    if (reg_hass(e, "HassEntity", SLOT_ENTITY_ID, &sc))
        return expect("reg HassEntity", 0);
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine,
                                                        "HassEntity");
    if (!rs) return expect("rete schema lookup", 0);

    char **ids = malloc(sizeof(char *) * N);
    for (long i = 0; i < N; i++) {
        ids[i] = malloc(32);
        snprintf(ids[i], 32, "light.kitchen_%ld", i);
    }

    int rc = 0;
    /* Round 0: initial sync. */
    for (long i = 0; i < N; i++)
        if (assert_hass(e, sc, ids[i], "on") != DS_OK)
            { rc |= expect("assert round0", 0); break; }

    long ll = list_len_acyclic(sc);
    rc |= expect("round0 wrapper list acyclic", ll != -1);
    rc |= expect("round0 wrapper list == N", ll == N);
    rc |= expect("round0 rete WM == N", rete_count(e->rete_engine, rs) == N);

    /* Rounds 1..3: re-sync with a flipped state slot (real updates -> the
     * identity-update detach/reattach path, once per existing identity). */
    for (int round = 1; round <= 3 && !rc; round++) {
        const char *st = (round & 1) ? "off" : "on";
        for (long i = 0; i < N; i++)
            if (assert_hass(e, sc, ids[i], st) != DS_OK)
                { rc |= expect("assert resync", 0); break; }
        ll = list_len_acyclic(sc);
        rc |= expect("resync wrapper list acyclic", ll != -1);
        rc |= expect("resync wrapper list stays == N", ll == N);
        rc |= expect("resync rete WM stays == N",
                     rete_count(e->rete_engine, rs) == N);
    }

    ds_engine_free(e);
    for (long i = 0; i < N; i++) free(ids[i]);
    free(ids);
    return rc;
}

/* A constant identity (slot 0) collapses to one fact. */
static int test_constant_identity(void)
{
    const long N = 4000;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return expect("engine_new(2)", 0);

    const ds_schema_t *sc = NULL;
    if (reg_hass(e, "HassConst", SLOT_INSTANCE, &sc))   /* identity = constant */
        return expect("reg HassConst", 0);
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine,
                                                        "HassConst");
    if (!rs) return expect("rete schema lookup(2)", 0);

    char **ids = malloc(sizeof(char *) * N);
    for (long i = 0; i < N; i++) {
        ids[i] = malloc(32);
        snprintf(ids[i], 32, "light.kitchen_%ld", i);
    }

    int rc = 0;
    for (long i = 0; i < N && !rc; i++) {
        if (assert_hass(e, sc, ids[i], "on") != DS_OK)
            { rc |= expect("assert const-id", 0); break; }
        long ll = list_len_acyclic(sc);
        if (ll == -1) { rc |= expect("const-id wrapper list acyclic", 0); break; }
    }
    /* All facts share the (constant) identity value -> WM holds exactly one. */
    long ll = list_len_acyclic(sc);
    rc |= expect("const-id wrapper list acyclic (final)", ll != -1);
    rc |= expect("const-id collapses wrapper list to 1", ll == 1);
    rc |= expect("const-id collapses rete WM to 1",
                 rete_count(e->rete_engine, rs) == 1);

    ds_engine_free(e);
    for (long i = 0; i < N; i++) free(ids[i]);
    free(ids);
    return rc;
}

/* Half the facts retracted, then the full set re-synced. */
static int test_retract_interleaved(void)
{
    const long N = 2000;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return expect("engine_new(3)", 0);

    const ds_schema_t *sc = NULL;
    if (reg_hass(e, "HassRetr", SLOT_ENTITY_ID, &sc))
        return expect("reg HassRetr", 0);
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine,
                                                        "HassRetr");
    if (!rs) return expect("rete schema lookup(3)", 0);

    char **ids = malloc(sizeof(char *) * N);
    for (long i = 0; i < N; i++) {
        ids[i] = malloc(32);
        snprintf(ids[i], 32, "sensor.x_%ld", i);
    }

    int rc = 0;
    for (long i = 0; i < N; i++)
        if (assert_hass(e, sc, ids[i], "on") != DS_OK)
            { rc |= expect("assert r3 round0", 0); break; }

    /* Retract every other fact via its wrapper, then re-assert the full set. */
    struct ds_schema *s = (struct ds_schema *)(uintptr_t)sc;
    long retracted = 0;
    for (struct ds_fact *f = s->fact_list_head, *nx; f; f = nx) {
        nx = f->schema_next;
        if ((retracted + (long)(uintptr_t)f) & 1) { /* arbitrary half */
            if (ds_engine_retract(e, f).status == DS_OK) retracted++;
        }
    }
    rc |= expect("r3 list acyclic after retract", list_len_acyclic(sc) != -1);

    for (long i = 0; i < N; i++)
        if (assert_hass(e, sc, ids[i], "off") != DS_OK)
            { rc |= expect("assert r3 resync", 0); break; }

    long ll = list_len_acyclic(sc);
    rc |= expect("r3 wrapper list acyclic (final)", ll != -1);
    rc |= expect("r3 wrapper list == N (no growth)", ll == N);
    rc |= expect("r3 rete WM == N", rete_count(e->rete_engine, rs) == N);

    ds_engine_free(e);
    for (long i = 0; i < N; i++) free(ids[i]);
    free(ids);
    return rc;
}

/* A host may overwrite its identity strings once ds_engine_assert returns:
 * the engine keeps interned copies, and a re-sync from fresh buffers finds
 * each identity, adding no wrapper. */
static int test_unstable_identity_string(void)
{
    const long N = 2000;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    if (ds_engine_new(&cfg, &e).status != DS_OK)
        return expect("engine_new(4)", 0);

    const ds_schema_t *sc = NULL;
    if (reg_hass(e, "HassUnstable", SLOT_ENTITY_ID, &sc))
        return expect("reg HassUnstable", 0);
    const ds_rete_schema_t *rs = ds_rete_schema_by_name(e->rete_engine,
                                                        "HassUnstable");
    if (!rs) return expect("rete schema lookup(4)", 0);

    char **round0 = malloc(sizeof(char *) * N);
    char **round1 = malloc(sizeof(char *) * N);
    for (long i = 0; i < N; i++) {
        round0[i] = malloc(32); snprintf(round0[i], 32, "light.k_%ld", i);
        round1[i] = malloc(32); snprintf(round1[i], 32, "light.k_%ld", i);
    }

    int rc = 0;
    /* Round 0: initial sync using the round0 buffers. */
    for (long i = 0; i < N; i++)
        if (assert_hass(e, sc, round0[i], "on") != DS_OK)
            { rc |= expect("assert unstable round0", 0); break; }
    rc |= expect("round0 wrapper list == N", list_len_acyclic(sc) == N);

    /* Overwrite every round0 identity string in place. */
    for (long i = 0; i < N; i++) snprintf(round0[i], 32, "stale.%ld", i);

    /* Round 1: re-sync the same entities with fresh buffers + a changed slot. */
    for (long i = 0; i < N; i++)
        if (assert_hass(e, sc, round1[i], "off") != DS_OK)
            { rc |= expect("assert unstable round1", 0); break; }

    long ll = list_len_acyclic(sc);
    rc |= expect("unstable wrapper list acyclic", ll != -1);
    rc |= expect("unstable wrapper list stays == N (no growth)", ll == N);
    rc |= expect("unstable rete WM == N", rete_count(e->rete_engine, rs) == N);

    ds_engine_free(e);
    for (long i = 0; i < N; i++) { free(round0[i]); free(round1[i]); }
    free(round0); free(round1);
    return rc;
}

int main(void)
{
    int failed = 0;
    failed |= test_discriminating_identity();
    failed |= test_constant_identity();
    failed |= test_retract_interleaved();
    failed |= test_unstable_identity_string();
    if (!failed) printf("OK\n");
    return failed;
}

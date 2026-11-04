/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/terminal.c — terminal node lifecycle and activation (IRET.8).
 */
#include <stdlib.h>
#include <string.h>

#include "rfcs/rfcs.h"
#include "libds.h"
#include "ds_alloc.h"

#include "rete/action.h"
#include "rete/clone.h"
#include "rete/expr.h"
#include "rete/agenda.h"
#include "rete/engine.h"
#include "rete/pool.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/token.h"
#include "rete/wm_rete.h"

ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                         struct ds_rete_fact   *rfact,
                                         uint8_t                cause);

/* ---- Refraction hash set ------------------------------------------ */

#define REFRACT_INIT_CAP 8u
#define REFRACT_MAX_LOAD 70u /* percent */

/* [IRET.11.3]: the identity is the whole tuple, so two activations whose tokens
 * collide on hash do not cross-suppress. An entry or a query with no ids matches on
 * the hash alone: outside RT mode that is only a token with no facts. RT mode is
 * hash-only, which [IRET.11.3.3] forbids; `realtime` and `constspace` are refused at
 * compile time. */
static bool refract_identity_match(const ds_rete_refract_entry_t *e,
                                   const uint32_t *fact_ids, uint32_t fact_count)
{
    if (e->fact_count == 0 || fact_count == 0) return true;
    if (e->fact_count != fact_count) return false;
    for (uint32_t k = 0; k < fact_count; k++)
        if (e->fact_ids[k] != fact_ids[k]) return false;
    return true;
}

/* True when the entry is in the table; otherwise *out_slot is an available slot. */
static bool refract_lookup(const ds_rete_terminal_t *t,
                            uint32_t token_hash, uint64_t gen,
                            const uint32_t *fact_ids, uint32_t fact_count,
                            uint32_t *out_slot)
{
    if (!t->refract_cap) { *out_slot = 0; return false; }
    uint32_t i = token_hash % t->refract_cap;
    for (;;) {
        const ds_rete_refract_entry_t *e = &t->refract[i];
        if (e->generation != gen) {
            *out_slot = i;
            return false;
        }
        if (e->token_hash == token_hash &&
            refract_identity_match(e, fact_ids, fact_count)) {
            *out_slot = i;
            return true;
        }
        /* The load factor guarantees a stale slot terminates the scan. */
        i = (i + 1) % t->refract_cap;
    }
}

ds_result_t ds_rete_terminal_presz_refract(ds_rete_terminal_t *terminal,
                                            uint32_t            cap)
{
    if (!terminal || cap == 0)
        return DS_ERR_R(DS_ERR_INVAL, "terminal_presz_refract");
    if (terminal->refract_cap >= cap) return DS_OK_R;

    uint32_t new_cap = terminal->refract_cap ? terminal->refract_cap
                                              : REFRACT_INIT_CAP;
    while (new_cap < cap) new_cap <<= 1;

    ds_rete_refract_entry_t *nb = DS_CALLOC(new_cap, sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "terminal_presz_refract");
    DS_FREE(terminal->refract);
    terminal->refract     = nb;
    terminal->refract_cap = new_cap;
    terminal->refract_n   = 0;
    return DS_OK_R;
}

bool ds_rete_terminal_is_refracted(const ds_rete_terminal_t *terminal,
                                    uint32_t token_hash, uint64_t generation,
                                    const uint32_t *fact_ids, uint32_t fact_count)
{
    if (!terminal || !terminal->refract_cap) return false;
    uint32_t slot;
    return refract_lookup(terminal, token_hash, generation,
                          fact_ids, fact_count, &slot);
}

ds_result_t ds_rete_terminal_mark_refracted(ds_rete_terminal_t *terminal,
                                             uint32_t token_hash,
                                             uint64_t generation,
                                             const uint32_t *fact_ids,
                                             uint32_t fact_count)
{
    if (terminal->refract_n * 100u / (terminal->refract_cap ? terminal->refract_cap : 1u)
            >= REFRACT_MAX_LOAD || !terminal->refract_cap) {
        uint32_t nc = terminal->refract_cap ? terminal->refract_cap * 2
                                            : REFRACT_INIT_CAP;
        ds_rete_refract_entry_t *nb = DS_CALLOC(nc, sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "refract grow");
        /* Stale entries are dropped. */
        for (uint32_t i = 0; i < terminal->refract_cap; i++) {
            ds_rete_refract_entry_t *e = &terminal->refract[i];
            if (!e->token_hash) continue;
            if (e->generation != generation) {
                DS_FREE(e->fact_ids);
                continue;
            }
            uint32_t j = e->token_hash % nc;
            while (nb[j].generation == generation) j = (j + 1) % nc;
            nb[j] = *e;
        }
        DS_FREE(terminal->refract);
        terminal->refract     = nb;
        terminal->refract_cap = nc;
    }

    uint32_t slot;
    bool found = refract_lookup(terminal, token_hash, generation,
                                fact_ids, fact_count, &slot);
    if (!found) {
        /* The copy first: an entry without its ids would match every colliding
           token ([LDET.1.1]). */
        uint32_t *copy = NULL;
        if (fact_ids && fact_count > 0) {
            copy = DS_MALLOC(fact_count * sizeof(*copy));
            if (!copy) return DS_ERR_R(DS_ERR_OOM, "refract fact_ids");
            memcpy(copy, fact_ids, fact_count * sizeof(*copy));
        }
        ds_rete_refract_entry_t *e = &terminal->refract[slot];
        /* The slot may be a stale entry still holding its ids. */
        DS_FREE(e->fact_ids);
        e->token_hash = token_hash;
        e->generation = generation;
        e->fact_ids   = copy;
        e->fact_count = copy ? fact_count : 0;
        terminal->refract_n++;
    }
    return DS_OK_R;
}

/* ---- Activation hash map ------------------------------------------- */
/*
 * Content-equal sibling activations collapse in the map: discard removes the entry
 * only when it is this activation, and left_retract falls back to a list scan.
 */
#define ACT_MAP_MAX_LOAD  70u

static uint64_t act_map_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (*(ds_rete_token_t *const *)key)->hash;
}
static bool act_map_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return ds_rete_tokens_equal(*(ds_rete_token_t *const *)a,
                                *(ds_rete_token_t *const *)b);
}

/* The value is a one-byte placeholder, so a present key's ds_oa_get is never NULL. */
static uint64_t oneshot_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    uint32_t k;
    memcpy(&k, key, sizeof k);
    return k;
}
static bool oneshot_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return memcmp(a, b, sizeof(uint32_t)) == 0;
}
static void oneshot_init(oa_t *t)
{
    ds_oa_init(t, sizeof(uint32_t), 1u, 70u, oneshot_oa_hash, oneshot_oa_eq,
            NULL, NULL);
}

static ds_result_t act_map_insert(ds_rete_terminal_t   *terminal,
                                   ds_rete_activation_t *act)
{
    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&terminal->act_map, &act->token, &vp, &is_new);
    if (r.status != DS_OK) return r;
    *(ds_rete_activation_t **)vp = act;
    return DS_OK_R;
}

ds_result_t ds_rete_terminal_create(const char          *rule_name,
                                     uint32_t             ordinal,
                                     ds_rete_terminal_t **out)
{
    if (!out || !rule_name)
        return DS_ERR_R(DS_ERR_INVAL, "terminal_create: NULL arg");
    ds_rete_terminal_t *t = DS_CALLOC(1, sizeof(*t));
    if (!t) return DS_ERR_R(DS_ERR_OOM, "terminal alloc");
    t->rule_name = rule_name;
    t->ordinal   = ordinal;
    ds_oa_init(&t->act_map, sizeof(ds_rete_token_t *), sizeof(ds_rete_activation_t *),
            ACT_MAP_MAX_LOAD, act_map_oa_hash, act_map_oa_eq, NULL, NULL);
    oneshot_init(&t->oneshot);
    *out = t;
    return DS_OK_R;
}

void ds_rete_terminal_destroy(ds_rete_terminal_t *terminal)
{
    if (!terminal) return;
    ds_rete_activation_t *a = terminal->activations;
    while (a) {
        ds_rete_activation_t *next = a->term_next;
        ds_rete_token_free(a->token);
        if (a->act_pool) ds_rete_pool_free(a->act_pool, a);
        else             DS_FREE(a);
        a = next;
    }
    if (terminal->actions) {
        for (uint32_t i = 0; i < terminal->action_count; i++)
            ds_rete_action_free(&terminal->actions[i]);
        DS_FREE(terminal->actions);
    }
    if (terminal->fire_guard) {
        ds_rete_expr_free_tree(terminal->fire_guard);
        terminal->fire_guard = NULL;
    }
    ds_oa_free(&terminal->act_map);
    for (uint32_t i = 0; i < terminal->refract_cap; i++)
        DS_FREE(terminal->refract[i].fact_ids);
    DS_FREE(terminal->refract);
    ds_oa_free(&terminal->oneshot);
    DS_FREE(terminal);
}

bool ds_rete_terminal_oneshot_fired(const ds_rete_terminal_t *terminal,
                                    uint32_t fact_id)
{
    if (!terminal || oa_len(&terminal->oneshot) == 0) return false;
    return ds_oa_get(&terminal->oneshot, &fact_id) != NULL;
}

ds_result_t ds_rete_terminal_oneshot_mark(ds_rete_terminal_t *terminal,
                                          uint32_t fact_id)
{
    if (!terminal) return DS_ERR_R(DS_ERR_INVAL, "oneshot_mark: NULL");
    return ds_oa_put(&terminal->oneshot, &fact_id, NULL, NULL);
}

void ds_rete_terminal_oneshot_clear(ds_rete_terminal_t *terminal,
                                    uint32_t fact_id)
{
    if (!terminal || oa_len(&terminal->oneshot) == 0) return;
    (void)ds_oa_del(&terminal->oneshot, &fact_id);
}

ds_result_t ds_rete_terminal_add_action(ds_rete_terminal_t     *terminal,
                                         const ds_rete_action_t *action)
{
    if (!terminal || !action)
        return DS_ERR_R(DS_ERR_INVAL, "terminal_add_action: NULL");

    ds_rete_action_t *nb = DS_REALLOC(terminal->actions,
        (terminal->action_count + 1) * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "terminal_add_action: OOM");

    ds_rete_action_t *slot = &nb[terminal->action_count];
    *slot = *action;

    /* The terminal owns its assigns array. */
    if (action->assign_count > 0 && action->assigns) {
        slot->assigns = DS_MALLOC(action->assign_count * sizeof(*slot->assigns));
        if (!slot->assigns) {
            terminal->actions = nb;
            return DS_ERR_R(DS_ERR_OOM, "terminal_add_action: assigns OOM");
        }
        memcpy(slot->assigns, action->assigns,
               action->assign_count * sizeof(*slot->assigns));
    } else {
        slot->assigns = NULL;
    }

    terminal->actions = nb;
    terminal->action_count++;
    return DS_OK_R;
}

/* ---- Truth maintenance at an activation's end (IRET.12.2) ---------- */

/* Retract each fact whose last justification this was. The cascade can
   re-enter ds_tms_withdraw before the loop moves on, so the loop reads ids of
   its own: the scratch copied to the stack, or the array it owns above
   DS_TMS_INLINE. */
static void withdraw_justification(struct ds_rete_engine *engine,
                                   int64_t                timetag)
{
    uint32_t *fact_ids      = NULL;
    uint32_t  n             = 0;
    bool      must_free_ids = false;
    ds_result_t r = ds_tms_withdraw(&engine->tms, timetag,
                                     &fact_ids, &n, &must_free_ids);
    if (r.status != DS_OK || n == 0) return;
    uint32_t local_ids[DS_TMS_INLINE];
    uint32_t *ids;
    if (must_free_ids) {
        ids = fact_ids;
    } else {
        memcpy(local_ids, fact_ids, n * sizeof(uint32_t));
        ids = local_ids;
    }
    for (uint32_t i = 0; i < n; i++) {
        /* [LERR.1.4.7]: the cascade stops at the halt, between facts. */
        if (engine->halted) break;
        ds_rete_fact_t *f = ds_rete_wm_find_by_id(engine, ids[i]);
        if (f && f->justif_count > 0) {
            f->justif_count--;
            if (f->justif_count == 0)
                /* [RARC.5.2.5] */
                ds_engine_retract_rete_fact(
                    engine, f, DS_FWTH_CAUSE_JUSTIFIER_ENDED);
        }
    }
    if (must_free_ids) DS_FREE(fact_ids);
}

void ds_rete_terminal_end_justification(struct ds_rete_engine *engine,
                                        int64_t                timetag)
{
    if (engine == NULL) return;
    withdraw_justification(engine, timetag);
}

ds_result_t ds_rete_terminal_justify(struct ds_rete_engine *engine,
                                     int64_t                timetag,
                                     const char            *rule_name,
                                     struct ds_rete_fact   *fact,
                                     bool                   made,
                                     bool                  *retract_out)
{
    *retract_out = false;
    if (engine->firing_act != NULL && engine->firing_act_freed) {
        *retract_out = made && fact->justif_count == 0;
        return DS_OK_R;
    }
    fact->justif_count++;
    return ds_tms_add(&engine->tms, timetag, rule_name, fact->id);
}

void ds_rete_terminal_retract_unjustified(struct ds_rete_engine *engine,
                                          struct ds_rete_fact   *fact)
{
    (void)ds_engine_retract_rete_fact(engine, fact,
                                      DS_FWTH_CAUSE_JUSTIFIER_ENDED);
}

/* ---- The tick's turnover ([IRET.19.5]) ----------------------------- */

/* UINT32_MAX when the token holds more than `cap`. */
static uint32_t non_tick_ids(const struct ds_rete_engine *engine,
                             const ds_rete_token_t *token,
                             uint32_t *out, uint32_t cap)
{
    uint32_t n = 0;
    for (uint32_t i = 0; i < token->fact_count; i++) {
        const ds_rete_fact_t *f = token->facts[i];
        if (f == NULL || f->schema == engine->clock_tick_schema) continue;
        if (n == cap) return UINT32_MAX;
        out[n++] = f->id;
    }
    return n;
}

/* [IRET.19.5], [IRET.12.2]: a tick turnover ends no activation. False when it could
   not be held: the caller withdraws then. */
static bool carry_across_tick(struct ds_rete_engine *engine,
                              ds_rete_terminal_t    *terminal,
                              const ds_rete_activation_t *dead)
{
    uint32_t n = dead->token->fact_count;
    uint32_t *ids = n > 0 ? DS_MALLOC(n * sizeof(*ids)) : NULL;
    if (n > 0 && ids == NULL) return false;
    n = non_tick_ids(engine, dead->token, ids, n);

    if (engine->tick_carry_n == engine->tick_carry_cap) {
        uint32_t nc = engine->tick_carry_cap ? engine->tick_carry_cap * 2u : 8u;
        ds_rete_tick_carry_t *nb =
            DS_REALLOC(engine->tick_carry, nc * sizeof(*nb));
        if (nb == NULL) { DS_FREE(ids); return false; }
        engine->tick_carry     = nb;
        engine->tick_carry_cap = nc;
    }
    engine->tick_carry[engine->tick_carry_n++] = (ds_rete_tick_carry_t){
        .terminal   = terminal,
        .timetag    = dead->creation_timetag,
        .fact_ids   = ids,
        .fact_count = n,
    };
    return true;
}

/* The index in engine->tick_carry of the activation `token` succeeds: the same
   terminal, the same facts but the tick. Else -1. */
static int64_t find_carried(const struct ds_rete_engine *engine,
                            const ds_rete_terminal_t    *terminal,
                            const ds_rete_token_t       *token)
{
    uint32_t ids[64];
    uint32_t n = non_tick_ids(engine, token, ids, 64);
    if (n == UINT32_MAX) return -1;
    for (uint32_t c = 0; c < engine->tick_carry_n; c++) {
        const ds_rete_tick_carry_t *k = &engine->tick_carry[c];
        if (k->terminal != terminal || k->fact_count != n) continue;
        if (n == 0 || memcmp(k->fact_ids, ids, n * sizeof(*ids)) == 0)
            return (int64_t)c;
    }
    return -1;
}

static void drop_carry(struct ds_rete_engine *engine, uint32_t c)
{
    DS_FREE(engine->tick_carry[c].fact_ids);
    engine->tick_carry[c] = engine->tick_carry[--engine->tick_carry_n];
}

void ds_rete_engine_tick_flush(struct ds_rete_engine *engine)
{
    if (engine == NULL || engine->tick_carry_n == 0) return;
    /* Off the engine first: no activation the cascade creates is a successor. */
    uint32_t n = engine->tick_carry_n;
    engine->tick_carry_n = 0;
    for (uint32_t c = 0; c < n; c++) {
        /* [LERR.1.4.7] */
        if (!engine->halted)
            withdraw_justification(engine, engine->tick_carry[c].timetag);
        DS_FREE(engine->tick_carry[c].fact_ids);
        engine->tick_carry[c].fact_ids = NULL;
    }
}

void ds_rete_tick_carry_free(struct ds_rete_engine *engine)
{
    if (engine == NULL) return;
    for (uint32_t c = 0; c < engine->tick_carry_n; c++)
        DS_FREE(engine->tick_carry[c].fact_ids);
    DS_FREE(engine->tick_carry);
    engine->tick_carry     = NULL;
    engine->tick_carry_n   = 0;
    engine->tick_carry_cap = 0;
}

/* ---- Activation paths --------------------------------------------- */

ds_result_t ds_rete_terminal_left_activate(ds_rete_terminal_t    *terminal,
                                            ds_rete_token_t       *token,
                                            struct ds_rete_engine *engine)
{
    if (!terminal || !token || !engine)
        return DS_ERR_R(DS_ERR_INVAL, "terminal_left_activate: NULL");
    /* [LERR.1.4.7] */
    if (engine->halted) return DS_OK_R;

    /* [RTCT.7.1]: refused before any mutation ([RTCT.7.2]). */
    if (engine->has_contract &&
        engine->agenda.count >= engine->contract_agenda_cap) {
        ds_rete_emit_breach(engine, DS_CAP_AGENDA,
                            engine->contract_agenda_cap,
                            (uint64_t)engine->agenda.count + 1u,
                            terminal->rule_name, 0);
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "terminal_left_activate: contract agenda_cap exceeded");
    }

    if (terminal->contract_capacity > 0 &&
        terminal->live_activations >= terminal->contract_capacity) {
        ds_rete_emit_breach(engine, DS_CAP_NODE_CAPACITY,
                            terminal->contract_capacity,
                            (uint64_t)terminal->live_activations + 1u,
                            terminal->rule_name, 0);
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "terminal_left_activate: contract per-node "
                        "activation capacity exceeded");
    }

    ds_rete_pool_t *tpool   = engine->pools_ready ? &engine->token_pool   : NULL;
    uint32_t       *tbudget = engine->pools_ready ? &engine->token_budget : NULL;
    ds_result_t rc;
    ds_rete_token_t *owned = ds_rete_token_copy(token, token->creation_timetag,
                                                 tpool, tbudget, &rc);
    if (!owned) return rc;

    ds_rete_activation_t *act;
    if (engine->pools_ready) {
        act = ds_rete_pool_alloc(&engine->act_pool);
        if (!act) {
            ds_rete_token_free(owned);
            return DS_ERR_R(DS_ERR_OOM, "activation: pool exhausted");
        }
        memset(act, 0, sizeof(*act));
        act->act_pool = &engine->act_pool;
    } else {
        act = DS_CALLOC(1, sizeof(*act));
        if (!act) {
            ds_rete_token_free(owned);
            return DS_ERR_R(DS_ERR_OOM, "activation alloc");
        }
    }
    act->terminal           = terminal;
    act->token              = owned;
    act->creation_timetag   = token->creation_timetag;

    act->term_next          = terminal->activations;
    act->term_prev          = NULL;
    if (terminal->activations) terminal->activations->term_prev = act;
    terminal->activations   = act;

    {
        ds_result_t mr = act_map_insert(terminal, act);
        if (mr.status != DS_OK) {
            terminal->activations = act->term_next;
            if (act->term_next) act->term_next->term_prev = NULL;
            ds_rete_token_free(owned);
            if (act->act_pool) ds_rete_pool_free(act->act_pool, act);
            else               DS_FREE(act);
            return mr;
        }
    }

    /* [IRET.19.5]: a token the fresh tick re-formed is the match the old tick
       carried, and takes its justification ([IRET.12.2]). With no condition it is
       that activation, fired already. A condition is re-read on every tick, so
       that activation is queued; its edge-once mark stops a second firing
       ([LTIM.2.5.1]). */
    if (engine->tick_carry_n > 0) {
        int64_t c = find_carried(engine, terminal, owned);
        if (c >= 0) {
            ds_result_t kr = ds_tms_rekey(&engine->tms,
                                           engine->tick_carry[c].timetag,
                                           act->creation_timetag);
            drop_carry(engine, (uint32_t)c);
            if (kr.status != DS_OK) return kr;
            if (!ds_rete_terminal_has_condition(terminal)) {
                act->fired = true;
                act->refracts = true;   /* [NDBG.4.3] */
                terminal->live_activations++;
                return DS_OK_R;
            }
        }
    }

    ds_result_t ar = ds_rete_agenda_insert(&engine->agenda, act);
    if (ar.status == DS_OK) terminal->live_activations++;
    return ar;
}

void ds_rete_terminal_discard_activation(ds_rete_terminal_t   *terminal,
                                          ds_rete_activation_t *act)
{
    if (!terminal || !act) return;

    if (act->token) {
        /* By pointer: a sibling that already fired can carry an equal token. */
        ds_rete_activation_t **vp =
            (ds_rete_activation_t **)ds_oa_get(&terminal->act_map, &act->token);
        if (vp && *vp == act) ds_oa_del(&terminal->act_map, &act->token);
    }

    if (act->term_prev) act->term_prev->term_next = act->term_next;
    else                terminal->activations      = act->term_next;
    if (act->term_next) act->term_next->term_prev = act->term_prev;

    if (terminal->live_activations > 0) terminal->live_activations--;

    ds_rete_token_free(act->token);
    if (act->act_pool) ds_rete_pool_free(act->act_pool, act);
    else               DS_FREE(act);
}

ds_result_t ds_rete_terminal_left_retract(ds_rete_terminal_t    *terminal,
                                           ds_rete_token_t       *token,
                                           struct ds_rete_engine *engine)
{
    if (!terminal || !token || !engine)
        return DS_ERR_R(DS_ERR_INVAL, "terminal_left_retract: NULL");
    /* [LERR.1.4.7] */
    if (engine->halted) return DS_OK_R;

    ds_rete_activation_t *dead = NULL;
    ds_rete_activation_t **vp =
        (ds_rete_activation_t **)ds_oa_get(&terminal->act_map, &token);
    if (vp) {
        dead = *vp;
        if (dead->term_prev) dead->term_prev->term_next = dead->term_next;
        else                 terminal->activations      = dead->term_next;
        if (dead->term_next) dead->term_next->term_prev = dead->term_prev;
        ds_oa_del(&terminal->act_map, &token);
    } else {
        /* Drains a content-equal sibling the map collapsed. */
        ds_rete_activation_t **pp = &terminal->activations;
        while (*pp) {
            if (ds_rete_tokens_equal((*pp)->token, token)) {
                dead = *pp;
                *pp = dead->term_next;
                if (dead->term_next) dead->term_next->term_prev = dead->term_prev;
                break;
            }
            pp = &(*pp)->term_next;
        }
    }
    if (!dead) return DS_OK_R;

    /* [LTIM.2.5.1], [IRET.11.3.2]: the activation ends, and its edge-once mark with
       it, unless the tick's own retraction removed the token ([IRET.19.5]). */
    if (!engine->retracting_tick && oa_len(&terminal->oneshot) > 0) {
        for (uint32_t i = 0; i < dead->token->fact_count; i++) {
            const ds_rete_fact_t *f = dead->token->facts[i];
            if (f != NULL && f->schema != engine->clock_tick_schema)
                ds_rete_terminal_oneshot_clear(terminal, f->id);
        }
    }

    /* The firing activation counts as fired: its own action ended its match before
       ds_rete_run marked it, and it has already left the agenda ([IRET.12.2]). In
       the stream the withdrawal follows the trigger's record ([RFCS.7a.4]). The
       Mercury runtime ends or carries every removed activation in
       `ds.engine.settle_turnover`. */
    if (dead->fired || dead == engine->firing_act) {
        /* The tick's own retraction ends no match ([IRET.19.5]): the justification
           waits for the token the fresh tick re-forms. */
        if (!engine->retracting_tick
                || !carry_across_tick(engine, terminal, dead))
            withdraw_justification(engine, dead->creation_timetag);
    } else {
        /* Off the agenda first, so no cascade below can select it. */
        ds_rete_agenda_remove(&engine->agenda, dead);
        /* A queued activation can hold a justification: the successor of a carried
           match, when the guard has a condition. Removed before it pops it ends
           ([IRET.12.2]), or the tick's own retraction carries it again
           ([IRET.19.5]). Only there: a carried successor elsewhere is marked fired,
           which an activation that never fired must not be. */
        if (!engine->retracting_tick
                || !ds_rete_terminal_has_condition(terminal)
                || !carry_across_tick(engine, terminal, dead))
            withdraw_justification(engine, dead->creation_timetag);
    }

    if (dead == engine->firing_act) engine->firing_act_freed = true;

    ds_rete_token_free(dead->token);
    if (dead->act_pool) ds_rete_pool_free(dead->act_pool, dead);
    else                DS_FREE(dead);
    if (terminal->live_activations > 0) terminal->live_activations--;
    return DS_OK_R;
}

/* ---- Terminal node deep-copy ----------------------------------------- */

static uint64_t tptr_hash(const void *k, void *c)
{ (void) c; return (uint64_t) (uintptr_t) *(void *const *) k; }
static bool tptr_eq(const void *a, const void *b, void *c)
{ (void) c; return *(void *const *) a == *(void *const *) b; }

typedef struct { oa_t *tokmap; ds_rete_clone_ctx_t *cx; } term_cc_t;

static void t_remap_tok(const void *sv, void *dv, void *ctx)
{
    term_cc_t *t = (term_cc_t *) ctx;
    ds_rete_token_t *st = *(ds_rete_token_t *const *) sv;
    void *v = st ? ds_oa_get(t->tokmap, &st) : NULL;
    *(ds_rete_token_t **) dv = v ? *(ds_rete_token_t **) v : NULL;
}
static void t_remap_act(const void *sv, void *dv, void *ctx)
{
    term_cc_t *t = (term_cc_t *) ctx;
    ds_rete_activation_t *sa = *(ds_rete_activation_t *const *) sv;
    *(ds_rete_activation_t **) dv = ds_rete_clone_act_lookup(t->cx, sa);
}

ds_result_t ds_rete_terminal_clone(ds_rete_clone_ctx_t     *cx,
                                   const ds_rete_terminal_t *src,
                                   ds_rete_terminal_t      **out)
{
    ds_rete_terminal_t *n = DS_CALLOC(1, sizeof(*n));
    if (!n) return DS_ERR_R(DS_ERR_OOM, "terminal_clone: alloc");

    n->rule_name = src->rule_name
        ? ds_rete_clone_intern(cx, src->rule_name, (uint32_t) strlen(src->rule_name))
        : NULL;
    n->ordinal           = src->ordinal;
    n->node_id           = src->node_id;
    n->fault_handler     = src->fault_handler;
    n->contract_capacity = src->contract_capacity;
    n->live_activations  = src->live_activations;
    n->action_count      = src->action_count;
    n->bind_count        = src->bind_count;
    n->fire_fn           = src->fire_fn;
    n->fire_ctx          = src->fire_ctx;
    n->rhs_fn            = src->rhs_fn;

    ds_oa_init(&n->act_map, sizeof(ds_rete_token_t *), sizeof(ds_rete_activation_t *),
            ACT_MAP_MAX_LOAD, act_map_oa_hash, act_map_oa_eq, NULL, NULL);
    oneshot_init(&n->oneshot);

    ds_result_t r = DS_OK_R;
    ds_rete_activation_t *prev = NULL;
    oa_t tokmap;
    ds_oa_init(&tokmap, sizeof(void *), sizeof(void *), 70, tptr_hash, tptr_eq, NULL, NULL);

    if (src->action_count > 0) {
        n->actions = DS_CALLOC(src->action_count, sizeof(*n->actions));
        if (!n->actions) { r = DS_ERR_R(DS_ERR_OOM, "terminal_clone: actions"); goto fail; }
        for (uint32_t i = 0; i < src->action_count; i++) {
            r = ds_rete_clone_action(cx, &src->actions[i], &n->actions[i]);
            if (r.status != DS_OK) goto fail;
        }
    }
    n->fire_guard = ds_rete_clone_expr(cx, src->fire_guard);

    for (ds_rete_activation_t *sa = src->activations; sa; sa = sa->term_next) {
        ds_rete_activation_t *ca = DS_CALLOC(1, sizeof(*ca));
        if (!ca) { r = DS_ERR_R(DS_ERR_OOM, "terminal_clone: activation"); goto fail; }
        ca->terminal         = n;
        ca->token            = ds_rete_token_clone(cx, sa->token);
        ca->creation_timetag = sa->creation_timetag;
        ca->heap_index       = sa->heap_index;
        ca->fired            = sa->fired;
        ca->refracts         = sa->refracts;
        ca->act_pool         = NULL;
        ca->term_prev        = prev;
        ca->term_next        = NULL;
        if (prev) prev->term_next = ca; else n->activations = ca;
        prev = ca;

        void *vp;
        r = ds_oa_put(&cx->act_map, &sa, &vp, NULL);
        if (r.status != DS_OK) goto fail;
        *(ds_rete_activation_t **) vp = ca;
        if (sa->token) {
            ds_rete_token_t *stok = sa->token;
            r = ds_oa_put(&tokmap, &stok, &vp, NULL);
            if (r.status != DS_OK) goto fail;
            *(ds_rete_token_t **) vp = ca->token;
        }
    }
    if (cx->oom) { r = DS_ERR_R(DS_ERR_OOM, "terminal_clone: token"); goto fail; }

    {
        term_cc_t tc = { &tokmap, cx };
        r = ds_oa_clone_into(&n->act_map, &src->act_map, t_remap_tok, t_remap_act, &tc);
        if (r.status != DS_OK) goto fail;
    }

    n->refract_cap = src->refract_cap;
    n->refract_n   = src->refract_n;
    if (src->refract_cap > 0 && src->refract) {
        n->refract = DS_CALLOC(src->refract_cap, sizeof(*n->refract));
        if (!n->refract) { r = DS_ERR_R(DS_ERR_OOM, "terminal_clone: refract"); goto fail; }
        for (uint32_t i = 0; i < src->refract_cap; i++) {
            n->refract[i] = src->refract[i];
            n->refract[i].fact_ids = NULL;
            if (src->refract[i].fact_ids && src->refract[i].fact_count > 0) {
                size_t bytes = src->refract[i].fact_count * sizeof(uint32_t);
                n->refract[i].fact_ids = DS_MALLOC(bytes);
                if (!n->refract[i].fact_ids) { r = DS_ERR_R(DS_ERR_OOM, "terminal_clone: fact_ids"); goto fail; }
                memcpy(n->refract[i].fact_ids, src->refract[i].fact_ids, bytes);
            }
        }
    }

    r = ds_oa_clone_into(&n->oneshot, &src->oneshot, NULL, NULL, NULL);
    if (r.status != DS_OK) goto fail;

    ds_oa_free(&tokmap);
    *out = n;
    return DS_OK_R;

fail:
    ds_oa_free(&tokmap);
    ds_rete_terminal_destroy(n);
    return r;
}

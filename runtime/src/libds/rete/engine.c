/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/engine.c — DS Rete engine lifecycle (IRET.18.1-18.2).
 */
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"

#include "clock.h"
#include "fn.h"
#include "rete/action.h"
#include "rete/agenda.h"
#include "rete/alpha.h"
#include "rete/clone.h"
#include "rete/beta.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/pool.h"
#include "rete/schema.h"
#include "rete/fault_fact.h"
#include "rete/terminal.h"
#include "rete/tms.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"
#include "rfcs/rfcs.h"

/* Defined in engine_rete_adapters.c; rete/adapters.c says why it is not in a
   header, and the two externs below are declared here for the same reason. */
ds_result_t ds_engine_retract_rete_fact(struct ds_rete_engine *re,
                                         struct ds_rete_fact   *rfact,
                                         uint8_t                cause);

struct ds_engine;
extern void ds_engine_series_go_live(struct ds_engine *engine);

extern ds_result_t ds_recorder_emit_bounds_error(struct ds_engine *engine,
                                                   ds_cap_name_t     cap,
                                                   uint64_t          limit,
                                                   uint64_t          observed,
                                                   const char       *rule_name,
                                                   int64_t           timetag);

void ds_rete_emit_breach(ds_rete_engine_t *engine,
                          ds_cap_name_t     cap,
                          uint64_t          limit,
                          uint64_t          observed,
                          const char       *rule_name,
                          int64_t           timetag)
{
    if (engine == NULL || engine->ds_engine_back == NULL) return;
    (void)ds_recorder_emit_bounds_error((struct ds_engine *)engine->ds_engine_back,
                                        cap, limit, observed,
                                        rule_name, timetag);
}

/* Also the pump's elapsed-time measurement below. */
static int64_t engine_now_ns(void)
{
    return (int64_t) ds_clock_platform_mono_ns();
}

static int64_t default_clock_fn(void *ctx)
{
    (void)ctx;
    return engine_now_ns();
}

static bool default_wall_fn(void *ctx, int64_t *out_utc_ns)
{
    (void)ctx;
    return ds_clock_platform_wall_ns(out_utc_ns);
}

#define NAME_MAP_INIT_CAP 16u

ds_result_t ds_rete_engine_create(ds_rete_engine_t **out)
{
    if (!out) return DS_ERR_R(DS_ERR_INVAL, "engine_create: NULL out");

    ds_rete_engine_t *e = DS_CALLOC(1, sizeof(*e));
    if (!e) return DS_ERR_R(DS_ERR_OOM, "engine_create: engine");

    /* In step with the DS-level counter: ds_engine_get_justifiers takes a DS
       `fact_id` and matches it against the TMS, which stores rete ids. */
    e->next_fact_id = 1;

    ds_result_t r = ds_rete_intern_init(&e->intern);
    if (r.status != DS_OK) { DS_FREE(e); return r; }
    ds_rete_intern_set_fault_hook(e->intern, ds_rete_raise_intern_fault, e);

    e->schema_name_map = DS_CALLOC(NAME_MAP_INIT_CAP, sizeof(ds_rete_schema_t *));
    if (!e->schema_name_map) {
        ds_rete_intern_destroy(e->intern);
        DS_FREE(e);
        return DS_ERR_R(DS_ERR_OOM, "engine_create: schema_name_map");
    }
    e->schema_name_cap = NAME_MAP_INIT_CAP;

    ds_rete_wm_map_init(e);

    e->clock_fn  = default_clock_fn;
    e->wall_fn   = default_wall_fn;
    e->clock_ctx = NULL;

    ds_rete_agenda_init(&e->agenda);

    /* Timetag 0 marks an empty slot in tms.c. */
    e->next_timetag = 1;

    /* Generation 0 is "never". */
    e->cycle_generation = 1;

    ds_tms_table_init(&e->tms);

    e->str_cat_scratch_cap = 4096u;
    e->str_cat_scratch = DS_MALLOC(e->str_cat_scratch_cap);
    if (!e->str_cat_scratch) {
        ds_tms_table_destroy(&e->tms);
        ds_oa_free(&e->wm_map);
        DS_FREE(e->schema_name_map);
        ds_rete_intern_destroy(e->intern);
        DS_FREE(e);
        return DS_ERR_R(DS_ERR_OOM, "engine_create: str_cat_scratch");
    }

    ds_rete_arena_init(&e->comp_arena);

    *out = e;
    return DS_OK_R;
}

static void free_schema(ds_rete_schema_t *s)
{
    if (!s) return;
    for (uint16_t i = 0; i < s->slot_count; i++) {     /* [RDSC.5.5.9] */
        ds_rete_expr_free_tree(s->slots[i].to_stored);
        ds_rete_expr_free_tree(s->slots[i].from_stored);
    }
    DS_FREE(s->slots); /* slot names are interned */
    ds_oa_free(&s->id_map);
    DS_FREE(s->id_key_slots);
    DS_FREE(s);
}

ds_text_t ds_rete_engine_detail(ds_rete_engine_t *engine)
{
    if (engine == NULL) return ds_text(NULL, 0);
    return ds_text(engine->detail_scratch, sizeof engine->detail_scratch);
}

const char *ds_rete_engine_detail_text(const ds_text_t *t, const char *fallback)
{
    return t->cap > 0 ? t->buf : fallback;
}

ds_result_t ds_rete_transient_json_keep(ds_rete_engine_t *engine,
                                        struct ds_json *tree)
{
    if (engine->transient_json_n == engine->transient_json_cap) {
        uint32_t cap = engine->transient_json_cap ? engine->transient_json_cap * 2u
                                                  : 4u;
        struct ds_json **nt = DS_REALLOC(engine->transient_json,
                                         cap * sizeof(*nt));
        if (nt == NULL)
            return DS_ERR_R(DS_ERR_OOM, "rete: a transient Json tree");
        engine->transient_json     = nt;
        engine->transient_json_cap = cap;
    }
    engine->transient_json[engine->transient_json_n++] = tree;
    return DS_OK_R;
}

void ds_rete_transient_json_free(ds_rete_engine_t *engine)
{
    for (uint32_t i = 0; i < engine->transient_json_n; i++)
        ds_json_free(engine->transient_json[i]);
    engine->transient_json_n = 0;
}

ds_result_t ds_rete_engine_destroy(ds_rete_engine_t *engine)
{
    if (!engine) return DS_OK_R;

    {
        uint32_t wm_n = oa_len(&engine->wm_map);
        for (uint32_t i = 0; i < wm_n; i++) {
            struct ds_rete_fact *f =
                *(struct ds_rete_fact **)ds_oa_val_at(&engine->wm_map, i);
            if (f) {
                /* A JSON_BORROW slot is not this fact's to free. */
                if (f->schema != NULL) {
                    for (uint16_t s = 0; s < f->schema->slot_count; s++) {
                        if (f->slots[s].kind == DS_RETE_VAL_JSON
                                && f->slots[s].json != NULL) {
                            ds_json_free(f->slots[s].json);
                        }
                    }
                }
                if (f->owner_pool) ds_rete_pool_free(f->owner_pool, f);
                else               DS_FREE(f);
            }
        }
        ds_oa_free(&engine->wm_map);
    }
    ds_rete_tz_index_free(engine);

    if (engine->alpha_dispatch) {
        for (size_t i = 0; i < engine->schema_count; i++)
            DS_FREE(engine->alpha_dispatch[i].nodes);
        DS_FREE(engine->alpha_dispatch);
    }

    /* The by-id array owns the schema objects. */
    for (size_t i = 0; i < engine->schema_count; i++)
        free_schema(engine->schemas_by_id[i]);
    DS_FREE(engine->schemas_by_id);
    DS_FREE(engine->schema_name_map);

    if (engine->adapter._cleanup)
        engine->adapter._cleanup(engine->adapter._cleanup_state);

    for (uint32_t i = 0; i < engine->owned_terminal_count; i++)
        ds_rete_terminal_destroy(engine->owned_terminals[i]);
    DS_FREE(engine->owned_terminals);

    for (uint32_t i = 0; i < engine->owned_beta_count; i++)
        ds_rete_beta_node_destroy(engine->owned_betas[i]);
    DS_FREE(engine->owned_betas);

    for (uint32_t i = 0; i < engine->owned_alpha_count; i++)
        ds_rete_alpha_node_destroy(engine->owned_alphas[i]);
    DS_FREE(engine->owned_alphas);

    ds_tms_table_destroy(&engine->tms);
    ds_rete_tick_carry_free(engine);
    ds_rete_fault_fact_free(engine);
    ds_rete_beta_free_match_traps(engine);

    DS_FREE(engine->str_cat_scratch);

    ds_rete_arena_destroy(&engine->comp_arena);
    ds_rete_transient_json_free(engine);
    DS_FREE(engine->transient_json);

    /* The items array only: terminals own the activations. */
    ds_rete_agenda_destroy(&engine->agenda);

    /* After everything that borrows a name pointer from it. */
    ds_rete_intern_destroy(engine->intern);

    if (engine->regex_cache) {
        for (uint32_t i = 0; i < engine->regex_cache_cap; i++) {
            if (engine->regex_cache[i].pat) {
                ds_re2_free(engine->regex_cache[i].compiled);
            }
        }
        DS_FREE(engine->regex_cache);
    }

    DS_FREE(engine->bind_frame_scratch);

    DS_FREE(engine->deadline_heap_items);

    /* After all node, fact and token frees above. */
    if (engine->pools_ready) {
        ds_rete_pool_destroy(&engine->fact_pool);
        ds_rete_pool_destroy(&engine->token_pool);
        ds_rete_pool_destroy(&engine->act_pool);
    }

    DS_FREE(engine->contract_nodes);
    DS_FREE(engine->contract_series);

    DS_FREE(engine);
    return DS_OK_R;
}

ds_result_t ds_rete_set_clock(ds_rete_engine_t *engine,
                               int64_t (*fn)(void *ctx),
                               void             *ctx)
{
    if (!engine || !fn)
        return DS_ERR_R(DS_ERR_INVAL, "set_clock: NULL arg");
    engine->clock_fn  = fn;
    engine->clock_ctx = ctx;
    return DS_OK_R;
}

int64_t ds_rete_now_ns(ds_rete_engine_t *engine)
{
    return engine->clock_fn(engine->clock_ctx);
}

ds_result_t ds_rete_set_wall_clock(ds_rete_engine_t *engine,
                                    bool (*fn)(void *ctx, int64_t *out_utc_ns))
{
    if (!engine || !fn)
        return DS_ERR_R(DS_ERR_INVAL, "set_wall_clock: NULL arg");
    engine->wall_fn = fn;
    return DS_OK_R;
}

bool ds_rete_wall_ns(ds_rete_engine_t *engine, int64_t *out_utc_ns)
{
    return engine->wall_fn(engine->clock_ctx, out_utc_ns);
}

ds_result_t ds_rete_set_before_fire(ds_rete_engine_t *engine,
                                     void (*hook)(const char *, void *),
                                     void             *ctx)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "set_before_fire: NULL engine");
    engine->before_fire    = hook; /* NULL clears the hook */
    engine->fire_hook_ctx  = ctx;
    return DS_OK_R;
}

ds_result_t ds_rete_set_after_fire(ds_rete_engine_t *engine,
                                    void (*hook)(const char *, void *),
                                    void             *ctx)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "set_after_fire: NULL engine");
    engine->after_fire    = hook;
    engine->fire_hook_ctx = ctx;
    return DS_OK_R;
}

/* ---- The fire guard's two parts ([RDSC.4a.8.2]) --------------------- */

/* [RDSC.4a.8.2.1]: the guard is the condition alone, the rate gate alone, or
   BINOP_AND(condition, rate gate). A call is the gate only when its op is
   FN_RATE_ALLOW. */
static bool guard_is_rate_gate(const ds_rete_expr_t *e)
{
    return e != NULL && e->kind == DS_RETE_EXPR_CALL
        && e->call.op == (uint32_t)DS_FN_RATE_ALLOW;
}

static bool guard_is_conjunction(const ds_rete_expr_t *g)
{
    return g != NULL && g->kind == DS_RETE_EXPR_BINOP
        && g->binop.op == DS_RETE_BINOP_AND
        && guard_is_rate_gate(g->binop.right);
}

/* Read at selection ([RDSC.4a.8.2.2]). */
static const ds_rete_expr_t *guard_condition(const ds_rete_expr_t *g)
{
    if (g == NULL || guard_is_rate_gate(g)) return NULL;
    return guard_is_conjunction(g) ? g->binop.left : g;
}

/* Read once inside the firing ([RDSC.4a.8.2.3]). */
static const ds_rete_expr_t *guard_gate(const ds_rete_expr_t *g)
{
    if (guard_is_rate_gate(g)) return g;
    return guard_is_conjunction(g) ? g->binop.right : NULL;
}

bool ds_rete_terminal_has_condition(const ds_rete_terminal_t *terminal)
{
    return terminal != NULL && guard_condition(terminal->fire_guard) != NULL;
}

/* ---- Action evaluation -------------------------------------------- */

/* [RLOW.7.2.1] */
static bool action_is_publish(const ds_rete_action_t *act)
{
    return act->expr != NULL && act->expr->kind == DS_RETE_EXPR_CALL
        && act->expr->call.op == (uint32_t)DS_FN_PUBLISH;
}

/* Whether a `publish`'s schema declares `ts`, read off the call's first operand,
   a literal ([RDSC.4a.9.3]). Any other shape answers false, and
   `adapter_ds_publish` refuses it. */
static bool publish_declares_ts(const ds_rete_engine_t *engine,
                                const ds_rete_expr_t   *call)
{
    if (call->call.arg_count < 1 || call->call.args[0] == NULL
        || call->call.args[0]->kind != DS_RETE_EXPR_LIT_STR
        || call->call.args[0]->lit_str == NULL)
        return false;
    const char *name = call->call.args[0]->lit_str;
    for (size_t id = 0; id < engine->schema_count; id++) {
        const ds_rete_schema_t *schema = engine->schemas_by_id[id];
        if (schema == NULL || schema->name == NULL
            || strcmp(schema->name, name) != 0)
            continue;
        for (uint16_t s = 0; s < schema->slot_count; s++)
            if (schema->slots[s].name != NULL
                && strcmp(schema->slots[s].name, "ts") == 0)
                return true;
        return false;
    }
    return false;
}

static ds_result_t eval_actions(ds_rete_engine_t         *engine,
                                  ds_rete_terminal_t       *term,
                                  ds_rete_token_t          *token,
                                  int64_t                   timetag)
{
    ds_rete_val_t  bind_buf[16];
    ds_rete_val_t *bind_frame = NULL;

    if (term->bind_count > 0) {
        if (engine->bind_frame_scratch &&
            term->bind_count <= engine->bind_frame_scratch_cap) {
            bind_frame = engine->bind_frame_scratch;
        } else if (term->bind_count <= 16) {
            bind_frame = bind_buf;
        } else {
            /* Both halves of the pair: the static analyser cannot see that a
               non-zero cap implies a live pointer. */
            if (!engine->bind_frame_scratch ||
                term->bind_count > engine->bind_frame_scratch_cap) {
                ds_rete_val_t *nb = DS_REALLOC(engine->bind_frame_scratch,
                                            term->bind_count * sizeof(*nb));
                if (!nb) return DS_ERR_R(DS_ERR_OOM, "bind_frame");
                engine->bind_frame_scratch     = nb;
                engine->bind_frame_scratch_cap = term->bind_count;
            }
            bind_frame = engine->bind_frame_scratch;
        }
        /* The only producer of UNBOUND: a BIND_REF reading it is a read before
           its binding ([RARC.5.6.11]). Not `null`, which a `let` may bind. */
        for (uint32_t i = 0; i < term->bind_count; i++)
            bind_frame[i] = ds_rete_val_unbound();
    }

    /* [IRET.25.4.1]: one now() for the entire firing. */
    int64_t fire_now = engine->rt_mode && engine->cached_clock_valid
        ? engine->cached_clock_ns
        : engine->clock_fn(engine->clock_ctx);

    ds_rete_eval_ctx_t ctx = {
        .token       = token,
        .right_fact  = NULL,
        .bind_frame  = bind_frame,
        .bind_count  = term->bind_count,
        .engine      = engine,
        .fire_now_ns    = fire_now,
        .fire_now_valid = true,
        .timetag     = timetag,
        .rule_name   = term->rule_name,
        .node_id     = term->node_id,
        .fault_handler_site = term->fault_handler,   /* [LERR.9.6] */
    };

    /* A fault does not fail the pump: a `break` on one abandons the activation
       ([LERR.1]) and leaves `r` OK. `r` carries only what the engine itself
       could not do. */
    ds_result_t r = DS_OK_R;

    /* [RDSC.4a.8.2.3]: evaluated once: it records the firing it admits
       ([LCDB.3.2.1]). `null` admits ([LNUL.4.8]); only an explicit false
       suppresses the actions, and the firing stands ([LCDB.3.2.1.1]). */
    const ds_rete_expr_t *gate = guard_gate(term->fire_guard);
    if (gate != NULL) {
        ds_rete_val_t v = ds_rete_eval(&ctx, gate);
        bool allow = !ctx.faulted
            && !(v.kind == DS_RETE_VAL_BOOL && !v.b);
        if (!allow) {
            /* The after-fire hook arms nothing ([NCBK.2.6]). */
            engine->current_fire_gate_denied = true;
            if (bind_frame && bind_frame != bind_buf &&
                bind_frame != engine->bind_frame_scratch) DS_FREE(bind_frame);
            return DS_OK_R;
        }
    }

    for (uint32_t i = 0; i < term->action_count; i++) {
        /* [LERR.1.4.7]: one raised elsewhere while an action ran, such as a join
           test under an `emit`'s propagation, which `ctx.faulted` never sees. */
        if (engine->halted) break;
        const ds_rete_action_t *act = &term->actions[i];

        if (act->kind == DS_RETE_ACTION_CALL) {
            /* A `publish` judges its values in [LFAC.9.2]'s order ([LTIE.4.8]):
               the `ts` fill, then its slot values. It is one FN_PUBLISH call,
               so the `ts` fill is judged here ([LTIM.2.8.3]). It has no
               deadline ([LTIE.4.9]), so a ttl_override on it is not
               evaluated. */
            const bool publish = action_is_publish(act);
            if (publish && publish_declares_ts(engine, act->expr)) {
                int64_t wall = 0;
                if (!ds_rete_eval_wall_ns(&ctx, &wall)) {
                    (void)ds_rete_fault(&ctx, NULL, DS_FAULT_DOMAIN);
                    break;
                }
            }
            int64_t saved_override = engine->pending_ttl_override_ns;
            if (act->ttl_override && !publish) {
                ds_rete_val_t tv = ds_rete_eval(&ctx, act->ttl_override);
                if (ctx.faulted) break;
                int64_t ns = (tv.kind == DS_RETE_VAL_TIME) ? tv.time.utc_ns
                           : (tv.kind == DS_RETE_VAL_INT)  ? tv.i : 0;
                if (ns > 0) engine->pending_ttl_override_ns = ns;
            }
            (void) ds_rete_eval(&ctx, act->expr);
            engine->pending_ttl_override_ns = saved_override;
            if (ctx.faulted) break;
            /* LSTO.4.7.5: a bound refused this action; `r` stays OK. */
            if (ctx.bounds_refused) break;
            continue;
        }

        if (act->kind == DS_RETE_ACTION_WITHDRAW) {
            /* IRET.10.5. A position outside the token names no pattern of the
               rule: PATTERN_INDEX, and the tier halts ([RDSC.4a.9.1],
               [RARC.5.3.3]). The firing goes on: the compiler refuses a later
               reference to the binding (LGRA.10.1.3). */
            uint8_t pi = act->withdraw_pattern_index;
            if (token == NULL || pi >= token->fact_count) {
                (void)ds_rete_fault(&ctx, NULL, DS_FAULT_PATTERN_INDEX);
                break;
            }
            if (token->facts[pi] != NULL) {
                ds_result_t wr = ds_engine_retract_rete_fact(
                    engine, token->facts[pi], DS_FWTH_CAUSE_AUTHOR_WITHDRAWN);
                if (wr.status != DS_OK) { r = wr; break; }
            }
            continue;
        }

        if (act->kind == DS_RETE_ACTION_WITHDRAW_BY_ID) {
            /* IRET.10.7: `withdraw b` in a nested body, through the fact
               reference the capture fact took. Ids are never reused, so a
               reference to no live fact does nothing, as does a value that is
               not a reference. */
            ds_rete_val_t fv = ds_rete_eval(&ctx, act->expr);
            if (ctx.faulted) break;
            if (fv.kind == DS_RETE_VAL_FACT_REF && fv.fact_ref_id != 0u) {
                ds_rete_fact_t *live =
                    ds_rete_wm_find_by_id(engine, fv.fact_ref_id);
                if (live != NULL) {
                    ds_result_t wr = ds_engine_retract_rete_fact(
                        engine, live, DS_FWTH_CAUSE_AUTHOR_WITHDRAWN);
                    if (wr.status != DS_OK) { r = wr; break; }
                }
            }
            continue;
        }

        /* ASSERT or LOGICAL_ASSERT */
        if (act->schema_id >= engine->schema_count) {
            r = DS_ERR_R(DS_ERR_INVAL, "eval_actions: schema_id OOB");
            break;
        }
        const ds_rete_schema_t *schema = engine->schemas_by_id[act->schema_id];

        ds_rete_val_t slot_buf[32];
        ds_rete_val_t *slots = (schema->slot_count <= 32)
            ? slot_buf : DS_CALLOC(schema->slot_count, sizeof(*slots));
        if (!slots) { r = DS_ERR_R(DS_ERR_OOM, "slot_buf"); break; }

        /* An unassigned slot defaults to the zero of its declared type. JSON
           stays at INT 0: its zero would allocate on the assert path. */
        int ts_ix = -1;
        for (uint16_t s = 0; s < schema->slot_count; s++) {
            if (schema->slots[s].name != NULL &&
                strcmp(schema->slots[s].name, "ts") == 0)
                ts_ix = (int)s;
            switch (schema->slots[s].type) {
            case DS_RETE_VAL_STR:
            case DS_RETE_VAL_BYTES: {
                const char *empty = "";
                (void)ds_rete_intern_cstr(engine->intern, "", &empty);
                slots[s] = (schema->slots[s].type == DS_RETE_VAL_STR)
                         ? ds_rete_val_str(empty, 0)
                         : ds_rete_val_bytes(empty, 0);
                break;
            }
            case DS_RETE_VAL_BOOL:
                slots[s] = ds_rete_val_bool(false);
                break;
            case DS_RETE_VAL_FLOAT:
                slots[s] = ds_rete_val_float(0.0);
                break;
            default:
                slots[s] = ds_rete_val_int(0);
                break;
            }
        }

        /* LFAC.9.2, RLOW.7.1.2: the engine fills `ts` with the instant every
           now() in this firing reads (LTIM.2.8.4), a TIME at offset 0, which an
           INT-declared Time slot admits. With no wall value: DOMAIN
           ([LTIM.2.8.3]). The compiler writes no `ts`. */
        if (ts_ix >= 0) {
            int64_t wall = 0;
            if (!ds_rete_eval_wall_ns(&ctx, &wall)) {
                (void)ds_rete_fault(&ctx, NULL, DS_FAULT_DOMAIN);
                if (slots != slot_buf) DS_FREE(slots);
                break;
            }
            slots[ts_ix] = ds_rete_val_time(wall, 0);
        }

        /* A slot index past the schema is ARTEFACT_LIED, before its expression
           is evaluated ([RDSC.4a.9.1]). */
        bool faulted = false;
        for (uint32_t a = 0; a < act->assign_count; a++) {
            uint8_t si = act->assigns[a].slot_index;
            if (si >= schema->slot_count) {
                (void)ds_rete_fault(&ctx, NULL, DS_FAULT_ARTEFACT);
                faulted = true;
                break;
            }
            slots[si] = ds_rete_eval(&ctx, act->assigns[a].expr);
            if (ctx.faulted) { faulted = true; break; }
        }
        if (faulted) {
            if (slots != slot_buf) DS_FREE(slots);
            break;
        }

        /* LDTL.4.1: restored right after the assert consumes it. */
        int64_t saved_override = engine->pending_ttl_override_ns;
        if (act->ttl_override) {
            ds_rete_val_t tv = ds_rete_eval(&ctx, act->ttl_override);
            if (ctx.faulted) {
                if (slots != slot_buf) DS_FREE(slots);
                break;
            }
            int64_t ns = (tv.kind == DS_RETE_VAL_TIME) ? tv.time.utc_ns
                       : (tv.kind == DS_RETE_VAL_INT)  ? tv.i : 0;
            if (ns > 0) engine->pending_ttl_override_ns = ns;
        }

        /* [LTIM.1.1.5]: a deadline past the `Time` range is NOT_REPRESENTABLE,
           after the override is evaluated and before the slots are judged. */
        if (!ds_rete_deadline_in_range(engine, schema,
                                       engine->clock_fn(engine->clock_ctx))) {
            engine->pending_ttl_override_ns = saved_override;
            (void)ds_rete_fault(&ctx, NULL, DS_FAULT_NOT_REPRESENTABLE);
            if (slots != slot_buf) DS_FREE(slots);
            break;
        }

        /* [RARC.5.2.7]: a slot the schema does not admit is a TypeError, before
           the interning below, so a refused emit acquires nothing. A `Json` root
           null is null first ([LNUL.3.4]). */
        ds_rete_lnul_3_4_canonical(schema, slots);
        {
            const int32_t bad = ds_rete_slot_refused(schema, slots);
            if (bad >= 0) {
                engine->pending_ttl_override_ns = saved_override;
                (void)ds_rete_fault_slot_refused(&ctx, schema->name,
                                                 schema->slots[bad].name,
                                                 &slots[bad]);
                if (slots != slot_buf) DS_FREE(slots);
                break;
            }
        }

        /* A fact owns its own tree: a slot read answers with the matched fact's,
           and two facts sharing one would free it twice. */
        {
            uint16_t es = 0;
            for (; es < schema->slot_count; es++) {
                if ((slots[es].kind != DS_RETE_VAL_JSON
                     && slots[es].kind != DS_RETE_VAL_JSON_BORROW)
                    || slots[es].json == NULL)
                    continue;
                ds_json_t *cloned = NULL;
                if (ds_json_clone(slots[es].json, &cloned).status != DS_OK)
                    break;
                slots[es].kind = DS_RETE_VAL_JSON;
                slots[es].json = cloned;
            }
            if (es < schema->slot_count) {
                for (uint16_t c = 0; c < es; c++)
                    if (slots[c].kind == DS_RETE_VAL_JSON
                        && slots[c].json != NULL)
                        ds_json_free(slots[c].json);
                engine->pending_ttl_override_ns = saved_override;
                (void)ds_rete_fault(&ctx, NULL, DS_FAULT_RESOURCE);
                if (slots != slot_buf) DS_FREE(slots);
                break;
            }
        }

        /* A slot value may be a transient arena string, and the arena is reset
           next pump, so each is interned counted. */
        for (uint16_t es = 0; es < schema->slot_count; es++) {
            const char *ip = NULL;
            if (slots[es].kind == DS_RETE_VAL_STR && slots[es].s.ptr != NULL) {
                if (ds_rete_intern_value(engine->intern, slots[es].s.ptr,
                                         slots[es].s.len, &ip).status == DS_OK)
                    slots[es] = ds_rete_val_str(ip, slots[es].s.len);
            } else if (slots[es].kind == DS_RETE_VAL_BYTES && slots[es].s.ptr != NULL) {
                if (ds_rete_intern_value(engine->intern, slots[es].s.ptr,
                                         slots[es].s.len, &ip).status == DS_OK)
                    slots[es] = ds_rete_val_bytes(ip, slots[es].s.len);
            }
        }

        ds_rete_fact_t *fact = NULL;
        /* Ids are minted in order, so a fact at or past this one is the
           assert's own and not a no-op's standing fact ([LLOG.15.1]). */
        const uint32_t first_new_id = engine->next_fact_id;
        r = ds_rete_wm_assert(engine, act->schema_id, slots, &fact);
        engine->pending_ttl_override_ns = saved_override;
        /* A refused assert takes nothing: the clones are still ours. */
        if (r.status != DS_OK)
            for (uint16_t c = 0; c < schema->slot_count; c++)
                if (slots[c].kind == DS_RETE_VAL_JSON && slots[c].json != NULL)
                    ds_json_free(slots[c].json);
        if (slots != slot_buf) DS_FREE(slots);
        if (r.status != DS_OK) break;

        /* [LLOG.15.1]: set when the firing's own match has ended, and this fact
           is new with nothing else holding it. Retracted after the emit's
           records below. */
        bool unjustified = false;
        if (act->kind == DS_RETE_ACTION_LOGICAL_ASSERT && fact) {
            r = ds_rete_terminal_justify(engine, timetag, term->rule_name,
                                         fact, fact->id >= first_new_id,
                                         &unjustified);
            if (r.status != DS_OK) {
                /* RFCS.6a.4: emit_cb is not reached, so a fact this assert
                   superseded is recorded as withdrawn here. */
                ds_rete_wm_settle_supersede(engine);
                break;
            }
        }

        if (fact && engine->adapter.emit_cb) {
            engine->adapter.emit_cb(
                engine, fact, engine->adapter.emit_user);
        }
        /* `publish` does not come this way, so does not fire it (IDSP.4.5). */
        if (fact && engine->adapter.emit_action_cb) {
            engine->adapter.emit_action_cb(
                engine, fact, engine->adapter.emit_action_user);
        }
        if (unjustified)
            ds_rete_terminal_retract_unjustified(engine, fact);
    }

    return r;
}

/* Under DS_DEBUG alone ([IRET.28.15]), never by default: run at every pump,
 * the walk costs more than linear in what each node holds. The gate's lanes
 * define DS_DEBUG; a release row does not. */
#ifdef DS_DEBUG
static void rete_invariant_check(const ds_rete_engine_t *engine)
{
    for (uint32_t i = 0; i < engine->owned_beta_count; i++)
        ds_rete_beta_check(engine->owned_betas[i]);
}
#endif

/* ---- Firing loop (IRET.11.4) --------------------------------------- */

/* Whether a fire token is a clock-driven now()/dwell re-eval ([LTIM.2.4],
 * [LTIM.2.5]): it carries a $ClockTick fact and no $Timer_ fact, which would make
 * it an after-clause follow-up. On true, *out_id is the matched real fact's id
 * ([LTIM.2.6]), the key for the edge-once one-shot. */
static bool now_reeval_token(const ds_rete_engine_t *engine,
                             const ds_rete_token_t   *tok,
                             uint32_t                *out_id)
{
    bool has_tick = false, have_real = false;
    uint32_t real_id = 0;
    for (uint32_t i = 0; i < tok->fact_count; i++) {
        const ds_rete_fact_t *f = tok->facts[i];
        if (f == NULL || f->schema == NULL) return false;
        if (engine->clock_tick_schema != NULL
                && f->schema == engine->clock_tick_schema) {
            has_tick = true;
            continue;
        }
        const char *nm = f->schema->name;
        if (nm != NULL
                && strncmp(nm, DS_RETE_TIMER_PREFIX, DS_RETE_TIMER_PREFIX_LEN) == 0)
            return false;
        real_id = f->id;
        have_real = true;
    }
    if (has_tick && have_real) { *out_id = real_id; return true; }
    return false;
}

/* ---- Refraction's tuple -------------------------------------------- */

/* A fast path, not a bound: [IRET.11.3]'s identity is the whole tuple. */
#define REFRACT_TUPLE_INLINE 64u

/* The token's fact ids in order, in `buf` when they fit, else on the heap. NULL
   when the heap copy cannot be made; a result other than `buf` is the caller's
   to free. */
static uint32_t *refract_tuple(const ds_rete_token_t *tok,
                               uint32_t buf[REFRACT_TUPLE_INLINE])
{
    uint32_t *ids = buf;
    if (tok->fact_count > REFRACT_TUPLE_INLINE) {
        ids = DS_MALLOC((size_t)tok->fact_count * sizeof(*ids));
        if (ids == NULL) return NULL;
    }
    for (uint32_t i = 0; i < tok->fact_count; i++)
        ids[i] = tok->facts[i]->id;
    return ids;
}

/* An allocation the pump needed for a firing and did not get: EngineError
   ALLOCATION for the activation's rule, and the tier halts ([LERR.1.4.7]). */
static void firing_alloc_fault(ds_rete_engine_t         *engine,
                               const ds_rete_terminal_t *term,
                               int64_t                   timetag)
{
    ds_rete_eval_ctx_t fctx = {
        .engine             = engine,
        .timetag            = timetag,
        .rule_name          = term->rule_name,
        .node_id            = term->node_id,
        .fault_handler_site = term->fault_handler,   /* [LERR.9.6] */
    };
    (void)ds_rete_fault(&fctx, NULL, DS_FAULT_RESOURCE);
}

ds_result_t ds_rete_run(ds_rete_engine_t *engine,
                         uint32_t          max_fires,
                         uint32_t         *fires_out)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "ds_rete_run: NULL engine");

    if (engine->rt_mode) {
        if (max_fires == 0)
            return DS_ERR_R(DS_ERR_RT_UNSAFE,
                            "ds_rete_run: rt_mode requires max_fires > 0");
        if (engine->max_fires_rt > 0 && max_fires < engine->max_fires_rt)
            return DS_ERR_R(DS_ERR_RT_UNSAFE,
                            "ds_rete_run: max_fires below required minimum "
                            "(set via ds_rete_engine_set_max_fires_rt)");
    }

    if (engine->has_contract &&
        max_fires > engine->contract_max_fires_per_pump) {
        ds_rete_emit_breach(engine, DS_CAP_MAX_FIRES_PER_PUMP,
                            engine->contract_max_fires_per_pump,
                            (uint64_t)max_fires, NULL, 0);
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "ds_rete_run: max_fires above contract "
                        "max_fires_per_pump");
    }

    /* The previous pump's breach, reported before this one starts. */
    if (engine->has_contract && engine->last_pump_breached) {
        engine->last_pump_breached = false;
        return DS_ERR_R(DS_ERR_CONTRACT_BREACH,
                        "ds_rete_run: previous pump exceeded contract "
                        "pump_wcet_ns");
    }

    /* Error returns skip the timing. */
    int64_t pump_start_ns = 0;
    if (engine->has_contract && engine->contract_pump_wcet_ns > 0) {
        pump_start_ns = engine_now_ns();
    }

    if (engine->rt_mode)
        ds_rete_refresh_clock_cache(engine);

    if (engine->pools_ready && engine->token_pool_cap > 0)
        engine->token_budget = engine->token_pool_cap;

    /* At entry, not exit: this runs however the prior pump exited. */
    ds_rete_arena_reset(&engine->comp_arena);
    ds_rete_transient_json_free(engine);

    uint32_t fired = 0;

    /* [RFCS.6.7], [LERR.1.5]: a refusal inside a pump ends the firing, not the
       pump. The rest of the agenda still fires, and the run returns the first
       such status at whichever exit it reaches. */
    ds_result_t refused = DS_OK_R;

    for (;;) {
        /* [LERR.1.4.7]: draining asserts, and nothing enters a halted tier. */
        if (engine->halted) break;
        /* [LERR.9.7]: queued fault facts are asserted before the next agenda
           selection. The status is not the pump's. */
        (void)ds_rete_fault_fact_drain(engine);
        ds_rete_activation_t *act = ds_rete_agenda_pop(&engine->agenda);
        if (!act) break;

        ds_rete_terminal_t *term = act->terminal;

        /* IRET.11.3.1: the whole tuple, so a hash collision between two
           activations does not suppress the second. RT stays hash-only and
           allocation-free. */
        uint32_t  refr_buf[REFRACT_TUPLE_INLINE];
        uint32_t *refr_ids = NULL;
        uint32_t  refr_n   = 0;
        if (!engine->rt_mode) {
            refr_ids = refract_tuple(act->token, refr_buf);
            if (refr_ids == NULL) {
                firing_alloc_fault(engine, term, act->creation_timetag);
                ds_rete_terminal_discard_activation(term, act);
                continue;
            }
            refr_n = act->token->fact_count;
        }
        bool refracted = ds_rete_terminal_is_refracted(
            term, act->token->hash, engine->cycle_generation,
            refr_n ? refr_ids : NULL, refr_n);
        if (refr_ids != refr_buf) DS_FREE(refr_ids);
        if (refracted) {
            ds_rete_terminal_discard_activation(term, act);
            continue;
        }

        /* RHS actions may retract this very activation and free its token, so
           the hash is taken now and the eval ctx gets a private copy. */
        uint32_t token_hash = act->token->hash;

        ds_result_t token_err = DS_OK_R;
        ds_rete_pool_t *tpool   = engine->pools_ready ? &engine->token_pool   : NULL;
        uint32_t       *tbudget = engine->pools_ready ? &engine->token_budget : NULL;
        ds_rete_token_t *fire_token = ds_rete_token_copy(
            act->token, act->creation_timetag, tpool, tbudget, &token_err);
        if (!fire_token) {
            /* With a pool, the failure is a cap of the realtime contract, not an
               allocation. */
            if (tpool != NULL) return token_err;
            firing_alloc_fault(engine, term, act->creation_timetag);
            ds_rete_terminal_discard_activation(term, act);
            continue;
        }

        engine->current_fire_token = fire_token;
        engine->current_fire_rule  = term->rule_name;
        engine->current_fire_gate_denied = false;

        /* LTAC.4.2: the guard's condition ([RDSC.4a.8.2.2]) is evaluated before
           the fire_begin/end bracket, so an immature tick counts no firing. The
           rate gate stays in eval_actions ([RDSC.4a.8.2.3]). */
        bool     is_nowreeval = false;
        uint32_t nowreeval_id = 0;
        const ds_rete_expr_t *cond = guard_condition(term->fire_guard);
        if (cond != NULL) {
            int64_t g_now = engine->rt_mode && engine->cached_clock_valid
                ? engine->cached_clock_ns
                : engine->clock_fn(engine->clock_ctx);
            ds_rete_eval_ctx_t gctx = {
                .token       = fire_token,
                .right_fact  = NULL,
                .bind_frame  = NULL,
                .bind_count  = 0,
                .engine      = engine,
                .fire_now_ns    = g_now,
                .fire_now_valid = true,
                .timetag     = act->creation_timetag,
                .rule_name   = term->rule_name,     /* [LERR.9.11] */
                .node_id     = term->node_id,
                .fault_handler_site = term->fault_handler,   /* [LERR.9.6] */
            };
            ds_rete_val_t gv = ds_rete_eval(&gctx, cond);
            /* `false` and `null` both withhold ([RDSC.4a.8.2.2], [LNUL.4.3]). */
            if (gv.kind != DS_RETE_VAL_BOOL || !gv.b) {
                /* Immature: no firing is recorded, and it is not reconsidered
                   until a fresh ClockTick yields a new token.

                   [LTIM.2.5.1]: a condition that closes ends the match, so its
                   edge-once mark goes with it. */
                uint32_t ended_id = 0;
                if (now_reeval_token(engine, fire_token, &ended_id))
                    ds_rete_terminal_oneshot_clear(term, ended_id);
                uint32_t  imm_buf[REFRACT_TUPLE_INLINE];
                uint32_t *imm_ids = NULL;
                uint32_t  imm_n   = 0;
                bool      imm_oom = false;
                if (!engine->rt_mode) {
                    imm_ids = refract_tuple(fire_token, imm_buf);
                    if (imm_ids == NULL) imm_oom = true;
                    else imm_n = fire_token->fact_count;
                }
                ds_rete_token_free(fire_token);
                engine->current_fire_token = NULL;
                engine->current_fire_rule  = NULL;
                if (!imm_oom
                        && ds_rete_terminal_mark_refracted(
                               term, token_hash, engine->cycle_generation,
                               imm_n ? imm_ids : NULL, imm_n).status != DS_OK)
                    imm_oom = true;
                if (imm_ids != imm_buf) DS_FREE(imm_ids);
                if (imm_oom)
                    firing_alloc_fault(engine, term, act->creation_timetag);
                act->fired = true;
                /* [LLOG.3.11.1]: the match has ended, so what it justified is
                   retracted at this pump. No fact changed, so no retraction
                   reaches it. Last: the cascade may free `act`. */
                ds_rete_terminal_end_justification(engine,
                                                   act->creation_timetag);
                continue;
            }
            /* Edge-once ([LTIM.2.5.1]): a matched fact that already fired its
               false->true edge is suppressed until it retracts or updates. The
               one-shot persists across generations, unlike refraction. */
            is_nowreeval = now_reeval_token(engine, fire_token, &nowreeval_id);
            if (is_nowreeval
                    && ds_rete_terminal_oneshot_fired(term, nowreeval_id)) {
                ds_rete_token_free(fire_token);
                engine->current_fire_token = NULL;
                engine->current_fire_rule  = NULL;
                act->fired = true;
                act->refracts = true;   /* [NDBG.4.3] */
                continue;
            }
        }

        /* Before the actions run, since one may free a fact of this token. The
           mark itself comes after the firing. RT skips the capture, keeping the
           pump allocation-free and the entry hash-only. */
        uint32_t  refract_buf[REFRACT_TUPLE_INLINE];
        uint32_t *refract_fact_ids   = NULL;
        uint32_t  refract_fact_count = 0;
        bool      refract_oom        = false;
        if (!engine->rt_mode) {
            refract_fact_ids = refract_tuple(fire_token, refract_buf);
            if (refract_fact_ids == NULL) refract_oom = true;
            else refract_fact_count = fire_token->fact_count;
        }

        /* An action may free the activation; see `firing_act`. */
        const int64_t act_timetag = act->creation_timetag;
        engine->firing_act       = act;
        engine->firing_act_freed = false;

        if (engine->before_fire)
            engine->before_fire(term->rule_name, engine->fire_hook_ctx);

        ds_result_t r = DS_OK_R;
        if (term->rhs_fn != NULL) {
            term->rhs_fn(engine->ds_engine_back,
                         fire_token,
                         (const struct ds_dispatch_t *)engine->ds_dispatch_table_ptr);
        } else if (term->action_count > 0) {
            r = eval_actions(engine, term, fire_token, act_timetag);
        } else if (term->fire_fn) {
            term->fire_fn(term->rule_name, fire_token, term->fire_ctx);
        }

        if (engine->after_fire)
            engine->after_fire(term->rule_name, engine->fire_hook_ctx);

        engine->current_fire_token = NULL;
        engine->current_fire_rule  = NULL;
        engine->current_fire_gate_denied = false;
        const bool act_freed     = engine->firing_act_freed;
        engine->firing_act       = NULL;
        engine->firing_act_freed = false;
        /* After after_fire, which reads the token. */
        ds_rete_token_free(fire_token);

        /* IRET.11.3 */
        if (!refract_oom
                && ds_rete_terminal_mark_refracted(
                       term, token_hash, engine->cycle_generation,
                       refract_fact_count ? refract_fact_ids : NULL,
                       refract_fact_count).status != DS_OK)
            refract_oom = true;
        if (refract_fact_ids != refract_buf) DS_FREE(refract_fact_ids);
        if (refract_oom)
            firing_alloc_fault(engine, term, act_timetag);

        /* It stays on the terminal's list for TMS withdrawal. */
        if (!act_freed) {
            act->fired = true;
            act->refracts = true;
        }

        /* The matured edge ([LTIM.2.5.1]). A status other than OOM is a grow of
           a set the realtime strategy locked. */
        if (is_nowreeval) {
            ds_result_t osr = ds_rete_terminal_oneshot_mark(term, nowreeval_id);
            if (osr.status == DS_ERR_OOM) {
                firing_alloc_fault(engine, term, act_timetag);
            } else if (osr.status != DS_OK) {
                if (fires_out) *fires_out = fired;
                return osr;
            }
        }

        fired++;

        if (r.status == DS_ERR_CONTRACT_BREACH) {   /* see `refused` above */
            if (refused.status == DS_OK) refused = r;
            r = DS_OK_R;
        }

        if (r.status != DS_OK) {
            if (fires_out) *fires_out = fired;
            return r;
        }

        if (max_fires > 0 && fired >= max_fires) {
            if (fires_out) *fires_out = fired;
            if (pump_start_ns > 0) {
                uint64_t elapsed = (uint64_t)(engine_now_ns() - pump_start_ns);
                engine->last_pump_elapsed_ns = elapsed;
                engine->last_pump_breached =
                    elapsed > engine->contract_pump_wcet_ns;
                /* Recorded at the pump that overran; the status is deferred to
                   the next. */
                if (engine->last_pump_breached)
                    ds_rete_emit_breach(engine, DS_CAP_PUMP_WCET_NS,
                                        engine->contract_pump_wcet_ns,
                                        elapsed, NULL, 0);
            }
            if (refused.status != DS_OK) return refused;
            return engine->agenda.count > 0
                ? DS_ERR_R(DS_ERR_BUDGET_EXCEEDED, "ds_rete_run: budget exceeded")
                : DS_OK_R;
        }
    }

#ifdef DS_DEBUG
    /* Not after a halt ([LERR.1.4.7]): a cascade may have been cut short, and a
       halted tier is never matched against again. */
    if (!engine->halted) rete_invariant_check(engine);
#endif
    if (fires_out) *fires_out = fired;
    if (pump_start_ns > 0) {
        uint64_t elapsed = (uint64_t)(engine_now_ns() - pump_start_ns);
        engine->last_pump_elapsed_ns = elapsed;
        engine->last_pump_breached =
            elapsed > engine->contract_pump_wcet_ns;
        if (engine->last_pump_breached)
            ds_rete_emit_breach(engine, DS_CAP_PUMP_WCET_NS,
                                engine->contract_pump_wcet_ns,
                                elapsed, NULL, 0);
    }
    return refused;
}

/* Object storage plus free-index stack. Zero when the pool is not initialised. */
static size_t pool_arena_bytes(const ds_rete_pool_t *p)
{
    if (p == NULL || p->base == NULL) return 0;
    return (size_t)p->cap * p->obj_size + (size_t)p->cap * sizeof(uint32_t);
}

ds_result_t ds_rete_engine_mem(const ds_rete_engine_t *e, ds_engine_mem_t *out)
{
    if (e == NULL || out == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "ds_rete_engine_mem: NULL arg");
    memset(out, 0, sizeof(*out));

    uint32_t wm_n = oa_len(&e->wm_map);
    out->wm_fact_count = wm_n;
    for (uint32_t i = 0; i < wm_n; i++) {
        const ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&e->wm_map, i);
        if (f == NULL) continue;
        out->wm_fact_bytes += sizeof(ds_rete_fact_t)
            + (size_t)f->schema->slot_count * sizeof(ds_rete_val_t);
    }
    out->wm_index_bytes += ds_oa_footprint_bytes(&e->wm_map);

    out->alpha_node_count = e->owned_alpha_count;
    for (uint32_t i = 0; i < e->owned_alpha_count; i++) {
        const ds_rete_alpha_node_t *a = e->owned_alphas[i];
        if (a == NULL) continue;
        const ds_rete_alpha_mem_t *m = &a->memory;
        out->alpha_match_count += oa_len(&m->map);
        out->alpha_index_bytes += ds_oa_footprint_bytes(&m->map);
    }

    out->beta_node_count = e->owned_beta_count;
    for (uint32_t i = 0; i < e->owned_beta_count; i++) {
        const ds_rete_beta_node_t *b = e->owned_betas[i];
        if (b == NULL) continue;
        out->beta_token_count += b->left_count;

        /* A pooled token embeds its facts[], counted under pool_reserved_bytes. */
        for (const ds_rete_token_t *t = b->left_head; t != NULL; t = t->next) {
            out->beta_token_bytes += sizeof(ds_rete_token_t);
            if (t->tok_pool == NULL)
                out->beta_token_bytes +=
                    (size_t)t->fact_count * sizeof(ds_rete_fact_t *);
        }

        out->beta_index_bytes += ds_oa_footprint_bytes(&b->lmem_map);
        out->beta_index_bytes += ds_oa_footprint_bytes(&b->ridx_map);
        out->beta_index_bytes += ds_oa_footprint_bytes(&b->lmem_idx_map);
        out->beta_index_bytes += ds_oa_footprint_bytes(&b->ralpha_idx_map);
        out->beta_index_bytes += ds_oa_footprint_bytes(&b->ltok_idx_map);
        if (b->beta_children)
            out->beta_index_bytes += b->beta_child_cap     * sizeof(*b->beta_children);
        if (b->terminal_children)
            out->beta_index_bytes += b->terminal_child_cap * sizeof(*b->terminal_children);
    }

    ds_rete_intern_mem(e->intern, &out->intern_count,
                       &out->intern_string_bytes, &out->intern_index_bytes);

    out->pool_reserved_bytes = pool_arena_bytes(&e->fact_pool)
                             + pool_arena_bytes(&e->token_pool)
                             + pool_arena_bytes(&e->act_pool);

    /* Without pool_reserved_bytes: in rt_mode it is the arena backing the live
     * facts and tokens, and counting both would double. */
    out->total_bytes = out->wm_fact_bytes + out->wm_index_bytes
                     + out->alpha_index_bytes
                     + out->beta_token_bytes + out->beta_index_bytes
                     + out->intern_string_bytes + out->intern_index_bytes;
    return DS_OK_R;
}

void ds_rete_bump_cycle(ds_rete_engine_t *e)
{
    e->cycle_generation++;
    /* The generation change makes all prior entries stale. */
    for (uint32_t i = 0; i < e->owned_terminal_count; i++)
        e->owned_terminals[i]->refract_n = 0;
}

/* ---- RT mode ------------------------------------------------------------- */

ds_result_t ds_rete_engine_set_rt_mode(ds_rete_engine_t *engine, bool enabled)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "set_rt_mode: NULL engine");
    if (enabled && engine->wm_max_facts == 0)
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
                        "set_rt_mode: rt_mode requires wm_max_facts > 0 "
                        "(call ds_rete_engine_set_wm_max first)");
    engine->rt_mode = enabled;
    /* wm_max × n_rules bounds activations per cycle. */
    if (enabled && engine->max_fires_rt == 0) {
        uint32_t n_rules = engine->owned_terminal_count > 0
                           ? engine->owned_terminal_count : 256u;
        engine->max_fires_rt = engine->wm_max_facts * n_rules;
        if (engine->max_fires_rt == 0) engine->max_fires_rt = 1024u;
    }
    return DS_OK_R;
}

ds_result_t ds_rete_engine_set_wm_max(ds_rete_engine_t *engine,
                                       uint32_t          max_facts)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "set_wm_max: NULL engine");
    engine->wm_max_facts = max_facts;
    return DS_OK_R;
}

ds_result_t ds_rete_engine_set_token_depth(ds_rete_engine_t *engine,
                                            uint32_t          depth)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "set_token_depth: NULL engine");
    engine->max_token_depth = depth;
    return DS_OK_R;
}

ds_result_t ds_rete_engine_set_token_pool_cap(ds_rete_engine_t *engine,
                                               uint32_t          cap)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "set_token_pool_cap: NULL engine");
    engine->token_pool_cap = cap;
    return DS_OK_R;
}

ds_result_t ds_rete_engine_set_max_fires_rt(ds_rete_engine_t *engine,
                                             uint32_t          min_fires)
{
    if (!engine) return DS_ERR_R(DS_ERR_INVAL, "set_max_fires_rt: NULL engine");
    engine->max_fires_rt = min_fires;
    return DS_OK_R;
}

ds_result_t ds_rete_engine_init_rt_pools(ds_rete_engine_t *engine)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "init_rt_pools: NULL engine");
    if (!engine->rt_mode)
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
                        "init_rt_pools: rt_mode must be enabled first");
    if (engine->wm_max_facts == 0)
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
                        "init_rt_pools: wm_max_facts must be non-zero");
    if (engine->pools_ready)
        return DS_OK_R; /* idempotent */

    size_t max_fact_sz = sizeof(ds_rete_fact_t);
    for (size_t i = 0; i < engine->schema_count; i++) {
        const ds_rete_schema_t *s = engine->schemas_by_id[i];
        size_t sz = sizeof(ds_rete_fact_t) +
                    (size_t)s->slot_count * sizeof(ds_rete_val_t);
        if (sz > max_fact_sz) max_fact_sz = sz;
    }

    uint32_t k_max = engine->max_token_depth > 0 ? engine->max_token_depth : 16u;

    uint32_t tok_cap = engine->token_pool_cap > 0
                       ? engine->token_pool_cap
                       : engine->wm_max_facts * 8u;
    if (tok_cap == 0) tok_cap = 64u;
    engine->token_pool_cap = tok_cap;
    /* A fact asserted before the first pump needs a budget too. */
    engine->token_budget = tok_cap;

    /* Header + embedded facts[] array. */
    size_t tok_sz = sizeof(ds_rete_token_t) +
                    (size_t)k_max * sizeof(ds_rete_fact_t *);

    ds_result_t r;

    /* [LERR.9.10]: before any pool, so a failure leaves nothing half-built. */
    r = ds_rete_fault_fact_reserve(engine);
    if (r.status != DS_OK) return r;

    /* [LERR.9.10]: `fault_fact_sites` slots beside `wm_max_facts`, in the same
       arena. The N_max check holds ordinary facts, the latch fault facts. */
    r = ds_rete_pool_init(&engine->fact_pool, max_fact_sz,
                          engine->wm_max_facts + engine->fault_fact_sites);
    if (r.status != DS_OK) return r;

    r = ds_rete_pool_init(&engine->token_pool, tok_sz, tok_cap);
    if (r.status != DS_OK) {
        ds_rete_pool_destroy(&engine->fact_pool);
        return r;
    }

    r = ds_rete_pool_init(&engine->act_pool,
                          sizeof(ds_rete_activation_t), tok_cap);
    if (r.status != DS_OK) {
        ds_rete_pool_destroy(&engine->fact_pool);
        ds_rete_pool_destroy(&engine->token_pool);
        return r;
    }

    struct ds_rete_fact **dh =
        DS_CALLOC(engine->wm_max_facts, sizeof(*dh));
    if (!dh) {
        ds_rete_pool_destroy(&engine->fact_pool);
        ds_rete_pool_destroy(&engine->token_pool);
        ds_rete_pool_destroy(&engine->act_pool);
        return DS_ERR_R(DS_ERR_OOM, "init_rt_pools: deadline heap");
    }
    engine->deadline_heap_items = dh;
    engine->deadline_heap_cap   = engine->wm_max_facts;
    engine->deadline_heap_count = 0;

    /* The hint matters when this is called before DSC load, with no terminals. */
    uint32_t max_bind = 16u;
    if (engine->max_bind_count_hint > max_bind)
        max_bind = engine->max_bind_count_hint;
    for (uint32_t i = 0; i < engine->owned_terminal_count; i++) {
        if (engine->owned_terminals[i]->bind_count > max_bind)
            max_bind = engine->owned_terminals[i]->bind_count;
    }
    ds_rete_val_t *bf = DS_CALLOC(max_bind, sizeof(*bf));
    if (!bf) {
        ds_rete_pool_destroy(&engine->fact_pool);
        ds_rete_pool_destroy(&engine->token_pool);
        ds_rete_pool_destroy(&engine->act_pool);
        DS_FREE(engine->deadline_heap_items);
        engine->deadline_heap_items = NULL;
        return DS_ERR_R(DS_ERR_OOM, "init_rt_pools: bind_frame_scratch");
    }
    engine->bind_frame_scratch     = bf;
    engine->bind_frame_scratch_cap = max_bind;

    engine->pools_ready  = true;
    return DS_OK_R;
}

/* ---- RT table pre-sizing -------------------------------------------- */

/* The next power of two >= 4n, minimum 8. */
static size_t _presz_cap(uint32_t n)
{
    size_t target = (n == 0) ? 8u : (size_t)n * 4u;
    size_t c = 8u;
    while (c < target) c <<= 1;
    return c;
}

ds_result_t ds_rete_engine_presz_rt_tables(ds_rete_engine_t *engine)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "presz_rt_tables: NULL engine");
    if (engine->live)
        return DS_ERR_R(DS_ERR_RT_LIVE,
                        "presz_rt_tables: engine is already LIVE (RTDS.7.4)");
    if (!engine->rt_mode)
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
                        "presz_rt_tables: rt_mode must be enabled first");
    if (!engine->pools_ready)
        return DS_ERR_R(DS_ERR_RT_UNSAFE,
                        "presz_rt_tables: call init_rt_pools first");

    /* Live facts can number wm_max plus the fault-fact sites ([LERR.9.10]). */
    uint32_t N = engine->wm_max_facts + engine->fault_fact_sites;
    size_t   cap = engine->presz_cap_override
                   ? (size_t)engine->presz_cap_override
                   : _presz_cap(N);

    uint32_t tok_cap = engine->token_pool_cap > 0
                       ? engine->token_pool_cap
                       : N * 8u;
    if (tok_cap == 0) tok_cap = 64u;

    ds_result_t r;
#define _PSTEP(n) (engine->presz_diag_step = (n))

    _PSTEP(1);
    r = ds_rete_wm_presz(engine, cap);
    if (r.status != DS_OK) return r;

    _PSTEP(2);
    /* Rebuilt with any live facts, so entities asserted during warm-up are still
       found. */
    r = ds_rete_wm_rebuild_id_hashes(engine, cap);
    if (r.status != DS_OK) return r;

    _PSTEP(3);
    for (uint32_t i = 0; i < engine->owned_alpha_count; i++) {
        ds_rete_alpha_mem_t *amem = &engine->owned_alphas[i]->memory;
        r = ds_rete_alpha_mem_presz(amem, cap);
        if (r.status != DS_OK) return r;
    }

    _PSTEP(4);
    if (engine->agenda.cap < tok_cap) {
        ds_rete_activation_t **nb =
            DS_REALLOC(engine->agenda.items, tok_cap * sizeof(*nb));
        if (!nb) return DS_ERR_R(DS_ERR_OOM, "presz: agenda heap");
        engine->agenda.items = nb;
        engine->agenda.cap   = tok_cap;
    }

    _PSTEP(5);
    for (uint32_t i = 0; i < engine->owned_terminal_count; i++) {
        r = ds_rete_terminal_presz_refract(engine->owned_terminals[i],
                                            (uint32_t)cap);
        if (r.status != DS_OK) return r;
    }

    _PSTEP(6);
    /* Under +nological the compiler guarantees no logical facts exist. */
    if (!engine->cap_nological) {
        r = ds_tms_presz(&engine->tms, (uint32_t)cap);
        if (r.status != DS_OK) return r;
        if (!engine->tms.withdraw_scratch) {
            engine->tms.withdraw_scratch =
                DS_CALLOC(DS_TMS_INLINE, sizeof(*engine->tms.withdraw_scratch));
            if (!engine->tms.withdraw_scratch)
                return DS_ERR_R(DS_ERR_OOM, "presz: tms withdraw scratch");
            engine->tms.withdraw_scratch_cap = DS_TMS_INLINE;
        }
        engine->tms.rt_locked = true;
    }

    _PSTEP(9);
    for (uint32_t i = 0; i < engine->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = engine->owned_betas[i];
        if (b->is_negative) continue;
        ds_result_t r = ds_oa_reserve(&b->lmem_map, (uint32_t)cap);
        if (r.status != DS_OK) return r;
    }

    _PSTEP(10);
    for (uint32_t i = 0; i < engine->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = engine->owned_betas[i];
        r = ds_rete_beta_presz_ridx(b, (uint32_t)cap);
        if (r.status != DS_OK) return r;
        if (!b->is_negative && b->ralpha_idx_enabled) {
            r = ds_rete_beta_presz_ralpha(b, (uint32_t)cap);
            if (r.status != DS_OK) return r;
        }
        if (!b->is_negative && b->lmem_idx_enabled) {
            r = ds_rete_beta_presz_lmem_idx(b, (uint32_t)cap);
            if (r.status != DS_OK) return r;
        }
        r = ds_rete_beta_presz_ltok(b, (uint32_t)cap);
        if (r.status != DS_OK) return r;
    }

    _PSTEP(11);
    for (uint32_t i = 0; i < engine->owned_terminal_count; i++) {
        ds_rete_terminal_t *term = engine->owned_terminals[i];
        r = ds_oa_reserve(&term->act_map, (uint32_t)cap);
        if (r.status != DS_OK) return r;
    }

    _PSTEP(12);
    r = ds_rete_intern_presz(engine->intern, cap);
    if (r.status != DS_OK) return r;
    ds_rete_intern_lock(engine->intern);

#undef _PSTEP
    return DS_OK_R;
}

ds_result_t ds_rete_go_live(ds_rete_engine_t *engine)
{
    if (!engine)
        return DS_ERR_R(DS_ERR_INVAL, "go_live: NULL engine");

    if (engine->live)
        return DS_ERR_R(DS_ERR_RT_LIVE,
                        "go_live: engine is already in LIVE mode (RTDS.8)");

    if (!engine->rt_mode)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: rt_mode not enabled; call "
                        "ds_rete_engine_set_rt_mode(true) first (RTDS.8.2/P1)");

    if (engine->wm_max_facts == 0)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: wm_max_facts is 0; call "
                        "ds_rete_engine_set_wm_max(N) first (RTDS.8.2/P2)");

    if (!engine->pools_ready)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: pools not ready; call "
                        "ds_rete_engine_init_rt_pools() first (RTDS.8.2/P3)");

    /* The lock is the proxy for presz_rt_tables having run. */
    if (!ds_rete_intern_is_locked(engine->intern))
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: intern table not locked; call "
                        "ds_rete_engine_presz_rt_tables() first (RTDS.8.2/P4)");

    if (engine->max_fires_rt == 0)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: max_fires_rt is 0; set via RTCF or "
                        "ds_rete_engine_set_max_fires_rt() (RTDS.8.2/P5)");

    if (!engine->clock_fn)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: no clock source; call "
                        "ds_rete_set_clock() first (RTDS.8.2/P6)");

    /* A known fanout past the inline budget would refuse joins in LIVE. */
    if (engine->max_join_fanout > 0 &&
        engine->max_join_fanout > 8u /* DS_RIDX_INLINE */ &&
        !engine->cap_nolinscan)
        return DS_ERR_R(DS_ERR_RT_PRECOND,
                        "go_live: max_join_fanout > DS_RIDX_INLINE=8; "
                        "add +nolinscan (J_max=1) or ensure fanout <= 8 "
                        "(RETE7b/P7)");

    for (uint32_t i = 0; i < engine->owned_beta_count; i++)
        engine->owned_betas[i]->rt_locked = true;

    if (engine->ds_engine_back)
        ds_engine_series_go_live((struct ds_engine *)engine->ds_engine_back);

    ds_rete_refresh_clock_cache(engine);

    engine->live = true;

    return DS_OK_R;
}

void ds_rete_refresh_clock_cache(ds_rete_engine_t *engine)
{
    if (engine) {
        engine->cached_clock_ns    = engine->clock_fn(engine->clock_ctx);
        engine->cached_clock_valid = true;
    }
}

/* ---- Rete engine clone ---------------------------------------------- */

/* Pointer-keyed src-node -> dst-node maps for the wiring pass. */
static uint64_t nodeptr_hash(const void *k, void *c)
{ (void) c; return (uint64_t) (uintptr_t) *(void *const *) k; }
static bool nodeptr_eq(const void *a, const void *b, void *c)
{ (void) c; return *(void *const *) a == *(void *const *) b; }

static void *nodemap_get(oa_t *m, const void *src)
{
    if (!src) return NULL;
    void *v = ds_oa_get(m, &src);
    return v ? *(void **) v : NULL;
}
static ds_result_t nodemap_put(oa_t *m, const void *src, void *dst)
{
    void *vp;
    ds_result_t r = ds_oa_put(m, &src, &vp, NULL);
    if (r.status == DS_OK) *(void **) vp = dst;
    return r;
}

ds_result_t ds_rete_engine_clone(ds_rete_clone_ctx_t    *cx,
                                 const ds_rete_engine_t *src,
                                 ds_rete_engine_t       *dst)
{
    ds_result_t r;
    oa_t amap, bmap, tmap;
    ds_oa_init(&amap, sizeof(void *), sizeof(void *), 0, nodeptr_hash, nodeptr_eq, NULL, NULL);
    ds_oa_init(&bmap, sizeof(void *), sizeof(void *), 0, nodeptr_hash, nodeptr_eq, NULL, NULL);
    ds_oa_init(&tmap, sizeof(void *), sizeof(void *), 0, nodeptr_hash, nodeptr_eq, NULL, NULL);

    if ((r = ds_rete_schemas_clone(cx, src, dst)).status != DS_OK) goto done;

    if ((r = ds_rete_wm_clone(cx, src, dst)).status != DS_OK) goto done;

    /* Node structs with empty wiring, then the wiring. */
    dst->owned_alpha_count = src->owned_alpha_count;
    if (src->owned_alpha_count > 0) {
        dst->owned_alphas = DS_CALLOC(src->owned_alpha_count, sizeof(*dst->owned_alphas));
        if (!dst->owned_alphas) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: alphas"); goto done; }
        for (uint32_t i = 0; i < src->owned_alpha_count; i++) {
            if ((r = ds_rete_alpha_node_clone(cx, src->owned_alphas[i], &dst->owned_alphas[i])).status != DS_OK) goto done;
            if ((r = nodemap_put(&amap, src->owned_alphas[i], dst->owned_alphas[i])).status != DS_OK) goto done;
        }
    }
    dst->owned_beta_count = src->owned_beta_count;
    if (src->owned_beta_count > 0) {
        dst->owned_betas = DS_CALLOC(src->owned_beta_count, sizeof(*dst->owned_betas));
        if (!dst->owned_betas) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: betas"); goto done; }
        for (uint32_t i = 0; i < src->owned_beta_count; i++) {
            if ((r = ds_rete_beta_node_clone(cx, src->owned_betas[i], &dst->owned_betas[i])).status != DS_OK) goto done;
            if ((r = nodemap_put(&bmap, src->owned_betas[i], dst->owned_betas[i])).status != DS_OK) goto done;
        }
    }
    dst->owned_terminal_count = src->owned_terminal_count;
    if (src->owned_terminal_count > 0) {
        dst->owned_terminals = DS_CALLOC(src->owned_terminal_count, sizeof(*dst->owned_terminals));
        if (!dst->owned_terminals) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: terminals"); goto done; }
        for (uint32_t i = 0; i < src->owned_terminal_count; i++) {
            if ((r = ds_rete_terminal_clone(cx, src->owned_terminals[i], &dst->owned_terminals[i])).status != DS_OK) goto done;
            if ((r = nodemap_put(&tmap, src->owned_terminals[i], dst->owned_terminals[i])).status != DS_OK) goto done;
        }
    }

    for (uint32_t i = 0; i < src->owned_alpha_count; i++) {
        const ds_rete_alpha_node_t *sa = src->owned_alphas[i];
        ds_rete_alpha_node_t       *da = dst->owned_alphas[i];
        if (sa->beta_output_count > 0) {
            da->beta_outputs = DS_CALLOC(sa->beta_output_count, sizeof(*da->beta_outputs));
            if (!da->beta_outputs) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: beta_outputs"); goto done; }
            da->beta_output_count = sa->beta_output_count;
            for (uint32_t j = 0; j < sa->beta_output_count; j++)
                da->beta_outputs[j] = nodemap_get(&bmap, sa->beta_outputs[j]);
        }
    }
    for (uint32_t i = 0; i < src->owned_beta_count; i++) {
        const ds_rete_beta_node_t *sb = src->owned_betas[i];
        ds_rete_beta_node_t       *db = dst->owned_betas[i];
        db->left_parent = (ds_rete_beta_node_t *)  nodemap_get(&bmap, sb->left_parent);
        db->right_alpha = (ds_rete_alpha_node_t *) nodemap_get(&amap, sb->right_alpha);
        if (sb->beta_child_count > 0) {
            uint32_t cap = sb->beta_child_cap ? sb->beta_child_cap : sb->beta_child_count;
            db->beta_children = DS_CALLOC(cap, sizeof(*db->beta_children));
            if (!db->beta_children) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: beta_children"); goto done; }
            db->beta_child_count = sb->beta_child_count;
            db->beta_child_cap   = cap;
            for (uint32_t j = 0; j < sb->beta_child_count; j++)
                db->beta_children[j] = (ds_rete_beta_node_t *) nodemap_get(&bmap, sb->beta_children[j]);
        }
        if (sb->terminal_child_count > 0) {
            uint32_t cap = sb->terminal_child_cap ? sb->terminal_child_cap : sb->terminal_child_count;
            db->terminal_children = DS_CALLOC(cap, sizeof(*db->terminal_children));
            if (!db->terminal_children) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: terminal_children"); goto done; }
            db->terminal_child_count = sb->terminal_child_count;
            db->terminal_child_cap   = cap;
            for (uint32_t j = 0; j < sb->terminal_child_count; j++)
                db->terminal_children[j] = (ds_rete_terminal_t *) nodemap_get(&tmap, sb->terminal_children[j]);
        }
    }
    for (size_t sid = 0; sid < src->schema_count; sid++) {
        const ds_rete_dispatch_entry_t *se = &src->alpha_dispatch[sid];
        ds_rete_dispatch_entry_t       *de = &dst->alpha_dispatch[sid];
        if (se->count > 0) {
            uint32_t cap = se->cap ? se->cap : se->count;
            de->nodes = DS_CALLOC(cap, sizeof(*de->nodes));
            if (!de->nodes) { r = DS_ERR_R(DS_ERR_OOM, "engine_clone: alpha_dispatch"); goto done; }
            de->count = se->count;
            de->cap   = cap;
            for (uint32_t j = 0; j < se->count; j++)
                de->nodes[j] = (ds_rete_alpha_node_t *) nodemap_get(&amap, se->nodes[j]);
        }
    }

    if ((r = ds_rete_tms_clone(cx, &src->tms, &dst->tms)).status != DS_OK) goto done;
    if ((r = ds_rete_agenda_clone(cx, &src->agenda, &dst->agenda)).status != DS_OK) goto done;
    /* [LERR.9.5]: the clone keeps the source's fact ids, so its latches. */
    if ((r = ds_rete_fault_fact_clone(dst, src)).status != DS_OK) goto done;

    dst->next_fact_id     = src->next_fact_id;
    dst->next_gensym      = src->next_gensym;
    dst->next_timetag     = src->next_timetag;
    dst->cycle_generation = src->cycle_generation;
    /* Not the clock or the fire hooks: their contexts are the owning ds_engine,
       already wired to dst ([NLFC.8.1]). */
    dst->cap_nological    = src->cap_nological;
    dst->cap_nolinscan    = src->cap_nolinscan;
    dst->cap_dynamic_ttl  = src->cap_dynamic_ttl;
    dst->cap_realtime     = src->cap_realtime;
    dst->cap_constspace   = src->cap_constspace;
    dst->fault_fact_sites = src->fault_fact_sites;
    dst->fault_fact_live  = src->fault_fact_live;
    dst->clock_tick_schema = src->clock_tick_schema
        ? dst->schemas_by_id[src->clock_tick_schema->id] : NULL;
    dst->clock_tick_fact = src->clock_tick_fact
        ? ds_rete_clone_fact_lookup(cx, src->clock_tick_fact->id) : NULL;

    r = cx->oom ? DS_ERR_R(DS_ERR_OOM, "engine_clone: sticky oom") : DS_OK_R;

done:
    ds_oa_free(&amap);
    ds_oa_free(&bmap);
    ds_oa_free(&tmap);
    return r;
}

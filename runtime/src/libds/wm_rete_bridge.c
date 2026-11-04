/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * wm_rete_bridge.c — between ds_engine_assert/retract and the Rete working memory
 * ([IRET.19]).
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "libds.h"
#include "ds_alloc.h"
#include "clock.h"           /* ds_clock_now_ns / _wall_ns: a publish view's instant */
#include "engine.h"
#include "recorder.h"
#include "rfcs/rfcs.h"
#include "wm.h"
#include "schema.h"
#include "rete/clone.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

/* Raises with a NULL ctx: on the assert path there is no node, activation or expression.
   Sound because each fault here is an EngineError whatever the taint. A
   DS_FAULT_TYPE_MISMATCH here would read as untainted and halt the tier. */
static ds_rete_val_t slot_to_rete_val(ds_rete_engine_t     *re,
                                       ds_slot_type_t        type,
                                       const ds_slot_value_t *v)
{
    /* [LNUL.9.1]. */
    if (v->kind == DS_SLOT_NULL)
        return ds_rete_val_null();
    switch (type) {
    case DS_SLOT_TYPE_INT:   return ds_rete_val_int(v->v.i);
    /* [RDSC.5.5.8]. */
    case DS_SLOT_TYPE_TIME:
    case DS_SLOT_TYPE_DATE:
    case DS_SLOT_TYPE_DURATION:
                             return ds_rete_val_int(v->v.i);
    case DS_SLOT_TYPE_FLOAT: return ds_rete_val_float(v->v.f);
    case DS_SLOT_TYPE_BOOL:  return ds_rete_val_bool(v->v.b);
    case DS_SLOT_TYPE_STRING: {
        const char *ptr = v->v.s ? v->v.s : "";
        const char *ip  = NULL;
        /* Counted, born at refcount 0: ds_rete_wm_assert_ex acquires it, retract
           releases it. */
        if (ds_rete_intern_value_cstr(re->intern, ptr, &ip).status != DS_OK)
            return ds_rete_fault(NULL, NULL, DS_FAULT_RESOURCE);
        return ds_rete_val_str(ip, (uint32_t)strlen(ip));
    }
    case DS_SLOT_TYPE_BYTES: {
        const char *ptr = (const char *)(v->v.bytes.data
                                          ? v->v.bytes.data : (const uint8_t *)"");
        const char *ip = NULL;
        ds_result_t ir = ds_rete_intern_value(
            re->intern, ptr, v->v.bytes.len, &ip);
        if (ir.status != DS_OK) return ds_rete_fault(NULL, NULL, DS_FAULT_RESOURCE);
        return ds_rete_val_bytes(ip, (uint32_t)v->v.bytes.len);
    }
    case DS_SLOT_TYPE_SCHEMA: {
        /* The target's rete id, never its address; 0 for no target. */
        ds_rete_val_t rv;
        rv.kind = DS_RETE_VAL_FACT_REF;
        rv.fact_ref_id = 0u;
        if (v->v.ref != NULL && v->v.ref->rete_fact != NULL) {
            rv.fact_ref_id = v->v.ref->rete_id;
        }
        return rv;
    }
    case DS_SLOT_TYPE_JSON: {
        /* The Rete fact owns an independent copy: a host frees its tree once
           ds_engine_assert returns. Retract frees it; ds_rete_wm_assert_inner frees it
           on a refused assert. */
        ds_rete_val_t rv;
        rv.kind = DS_RETE_VAL_JSON;
        rv.json = NULL;
        if (v->v.json != NULL) {
            ds_json_t *cloned = NULL;
            if (ds_json_clone(v->v.json, &cloned).status != DS_OK)
                return ds_rete_fault(NULL, NULL, DS_FAULT_RESOURCE);
            rv.json = cloned;
        }
        return rv;
    }
    }
    /* Outside the switch, not a `default:`, so a new ds_slot_type_t meets -Wswitch. */
    return ds_rete_fault(NULL, NULL, DS_FAULT_ARTEFACT);
}

/* The Rete fact, unwrapped, and via out_replaced any fact an identity update retracted. */
ds_result_t ds_rete_wm_assert_inner(struct ds_engine          *engine,
                                  const ds_schema_t         *schema,
                                  const ds_slot_value_t     *values,
                                  uint32_t                   n_values,
                                  struct ds_rete_fact      **out_rete_fact,
                                  struct ds_rete_fact      **out_replaced)
{
    if (out_replaced) *out_replaced = NULL;
    ds_rete_engine_t *re = engine->rete_engine;

    const ds_rete_schema_t *rs = ds_rete_schema_by_name(re, schema->type_name);
    if (!rs) {
        /* A literal: inside a pump, a failure can be stashed and read after further
           calls, which only a literal or interned string survives (engine.h). */
        return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN,
                        "rete_wm_assert: the schema is registered with the "
                        "engine but not with its Rete network");
    }

#define RETE_VALS_INLINE 16
    ds_rete_val_t  vals_buf[RETE_VALS_INLINE];
    ds_rete_val_t *rete_vals     = NULL;
    bool           vals_heap     = false;
    if (n_values > 0) {
        if (n_values <= RETE_VALS_INLINE) {
            rete_vals = vals_buf;
        } else {
            rete_vals = DS_MALLOC(n_values * sizeof(*rete_vals));
            if (!rete_vals)
                return DS_ERR_R(DS_ERR_OOM, "rete_wm_assert: val array alloc");
            vals_heap = true;
        }
        for (uint32_t i = 0; i < n_values; i++)
            rete_vals[i] = slot_to_rete_val(re, schema->slots[i].type, &values[i]);
    }
#undef RETE_VALS_INLINE

    ds_rete_fact_t *rete_fact = NULL;
    /* Never negative: the assert refused an override above INT64_MAX ([RFCS.6.7]). */
    re->pending_ttl_override_ns = (int64_t)engine->wm.ttl_override_ns;
    ds_result_t r = ds_rete_wm_assert_ex(re, rs->id, rete_vals, &rete_fact,
                                         out_replaced);
    re->pending_ttl_override_ns = 0;
    if (r.status != DS_OK) {
        /* A refused assert takes nothing: the clones are still ours. */
        if (rete_vals != NULL) {
            for (uint32_t i = 0; i < n_values; i++) {
                if (rete_vals[i].kind == DS_RETE_VAL_JSON
                        && rete_vals[i].json != NULL) {
                    ds_json_free(rete_vals[i].json);
                }
            }
        }
        if (vals_heap) DS_FREE(rete_vals);
        return r;
    }
    if (vals_heap) DS_FREE(rete_vals);

    *out_rete_fact = rete_fact;
    return DS_OK_R;
}

extern ds_result_t ds_wm_fact_detach(ds_wm_state_t *wm, ds_fact_t *fact);
extern ds_result_t ds_wm_fact_reattach(ds_wm_state_t *wm, ds_fact_t *fact);

/* Points a wrapper slot at the engine's interned copy, and takes the reference
   wm_fact_release drops: the slot's invariant is "engine-interned; engine-lifetime"
   (libds.h). */
static void wrapper_bind_interned(struct ds_engine    *engine,
                                  ds_slot_value_t     *slot,
                                  const ds_rete_val_t *rv)
{
    if (engine == NULL || engine->rete_engine == NULL) return;
    if (rv->kind != DS_RETE_VAL_STR && rv->kind != DS_RETE_VAL_BYTES) return;
    if (rv->s.ptr == NULL) return;

    if (slot->kind == DS_SLOT_STRING) {
        slot->v.s = rv->s.ptr;
    } else if (slot->kind == DS_SLOT_BYTES) {
        slot->v.bytes.data = (const uint8_t *)rv->s.ptr;
        slot->v.bytes.len  = rv->s.len;
    } else {
        return;
    }
    ds_rete_intern_acquire_ptr(engine->rete_engine->intern,
                               rv->s.ptr, rv->s.len);
}

/* [RFCS.6.7], [LFAC.2.5.3]: recorded after the replacement's FactAssert. The detached
   wrapper is released here, or by the recorder after a buffered dispatch. */
static void emit_superseded(struct ds_engine *engine, ds_fact_t *old_wrap)
{
    const char   *prev_reason = engine->wm.retract_reason;
    const uint8_t prev_cause  = engine->wm.retract_cause;
    engine->wm.retract_reason = "replaced";
    engine->wm.retract_cause  = DS_FWTH_CAUSE_SUPERSEDED;
    bool buffered = ds_recorder_should_buffer(engine);
    ds_recorder_emit_fact_retract(engine, old_wrap);
    engine->wm.retract_reason = prev_reason;
    engine->wm.retract_cause  = prev_cause;
    if (!buffered)
        ds_wm_fact_release_detached(&engine->wm, old_wrap);
}

static ds_result_t assert_bridge_body(struct ds_engine      *engine,
                                      const ds_schema_t     *schema,
                                      const ds_slot_value_t *values,
                                      uint32_t               n_values,
                                      ds_fact_t            **out_fact);

/* [RFCS.6.7]: the arriving assert precedes everything its evaluation produces, a fault
   its propagation raises included. */
ds_result_t ds_rete_wm_assert_bridge(struct ds_engine      *engine,
                                   const ds_schema_t     *schema,
                                   const ds_slot_value_t *values,
                                   uint32_t               n_values,
                                   ds_fact_t            **out_fact)
{
    ds_recorder_hold_faults(engine);
    ds_result_t r = assert_bridge_body(engine, schema, values, n_values,
                                       out_fact);
    ds_result_t hr = ds_recorder_release_faults(engine);
    return r.status != DS_OK ? r : hr;
}

static ds_result_t assert_bridge_body(struct ds_engine      *engine,
                                      const ds_schema_t     *schema,
                                      const ds_slot_value_t *values,
                                      uint32_t               n_values,
                                      ds_fact_t            **out_fact)
{
    ds_rete_fact_t *rete_fact = NULL;
    ds_rete_fact_t *replaced  = NULL;
    /* [RFCS.6.7]: a bound that refuses this input records it first. */
    ds_recorder_input_begin(engine, schema, values, n_values);
    ds_result_t r = ds_rete_wm_assert_inner(
        engine, schema, values, n_values, &rete_fact, &replaced);
    /* [LERR.1.4.7], [RFCS.6.7]: an upsert the halt cut still arrived. Its old fact's
       withdrawal follows, and the held EngineError after both. */
    if (r.status == DS_ERR_ENGINE_HALTED && replaced != NULL)
        ds_recorder_emit_cut_input(engine);
    ds_recorder_input_end(engine);
    if (r.status != DS_OK) {
        /* An upsert refused after its retract: the old fact has left working memory, so
           its wrapper goes, keyed on a freed rete fact the LIFO pool hands to the next
           assert. */
        if (replaced != NULL) {
            ds_fact_t *gone = NULL;
            (void)ds_wm_fact_lookup(&engine->wm, (void *)replaced, &gone);
            if (gone != NULL) {
                ds_wm_fact_detach(&engine->wm, gone);
                emit_superseded(engine, gone);
            }
        }
        return r;
    }

    /* Keyed by the freed replaced fact on an identity update, never dereferenced, or by
       the returned fact on a no-op reassertion. */
    ds_fact_t *old_wrap = NULL;
    (void)ds_wm_fact_lookup(&engine->wm,
                            replaced ? (void *)replaced : (void *)rete_fact,
                            &old_wrap);

    /* [RFCS.6.7], [LFAC.2.5.3]: a meaningful change mints a new wrapper, then FactAssert(new),
       then FactRetract(old) with cause SUPERSEDED. `replaced` is the signal, not a pointer
       test: the pool is LIFO, so the new fact may take the freed address. */
    ds_fact_t *superseded = NULL;
    if (replaced != NULL) {
        if (old_wrap != NULL) {
            /* Before ds_wm_fact_new, so in the aliasing case the table slot is free. */
            ds_wm_fact_detach(&engine->wm, old_wrap);
            superseded = old_wrap;
            old_wrap = NULL;
        }
    } else if (old_wrap != NULL) {
        /* A no-op reassertion is silent to the network and recorded anyway, against the
           live wrapper: a FactAssert records an assert arriving ([RFCS.6.7], [RARC.5.8.10]).
           The wrapper may be a rule's, so assert_from_host says who sent it. */
        const bool prev_host = engine->wm.assert_from_host;
        engine->wm.assert_from_host = true;
        ds_recorder_emit_fact_assert(engine, old_wrap);
        engine->wm.assert_from_host = prev_host;
        if (out_fact) *out_fact = old_wrap;
        return DS_OK_R;
    }

    ds_fact_t *fact = NULL;
    r = ds_wm_fact_new(&engine->wm, schema, (void *)rete_fact, &fact);
    if (r.status != DS_OK) {
        ds_rete_wm_retract(engine->rete_engine, rete_fact);
        /* The old fact left working memory all the same; record it. */
        if (superseded != NULL) emit_superseded(engine, superseded);
        return r;
    }
    fact->rete_id = rete_fact->id;
    /* Without its deadline the wrapper is skipped by the sweep and orphaned with a dangling
       rete_fact when ds_rete_wm_tick_ttl frees the fact. The two clocks share a time base. */
    if (rete_fact->deadline_ns > 0) {
        fact->ttl_deadline_ns = (uint64_t)rete_fact->deadline_ns;
        ds_wm_deadline_track(&engine->wm, fact);
    }

    /* The caller's memory is needed only for this call: JSON is cloned, and String and Bytes
       point at the rete fact's interned copy. */
    const uint16_t n_rete_slots =
        rete_fact->schema ? rete_fact->schema->slot_count : 0;
    for (uint32_t i = 0; i < n_values && i < fact->n_slots; i++) {
        fact->slots[i] = values[i];
        if (fact->slots[i].kind == DS_SLOT_FACT_REF) {
            /* The caller's pointer is a borrow for this call only ([NFCT.2.4]). */
            fact->slots[i] = ds_wm_slot_of_ref_id(
                values[i].v.ref ? values[i].v.ref->fact_id : 0u);
        } else if (fact->slots[i].kind == DS_SLOT_JSON
                && fact->slots[i].v.json != NULL) {
            ds_json_t *cloned = NULL;
            ds_result_t cr = ds_json_clone(fact->slots[i].v.json, &cloned);
            if (cr.status != DS_OK) {
                /* So wm_fact_release does not free a borrowed pointer. */
                fact->slots[i].v.json = NULL;
                ds_rete_wm_retract(engine->rete_engine, rete_fact);
                ds_wm_fact_free(&engine->wm, fact);
                if (superseded != NULL) emit_superseded(engine, superseded);
                return cr;
            }
            fact->slots[i].v.json = cloned;
        } else if (i < n_rete_slots) {
            wrapper_bind_interned(engine, &fact->slots[i], &rete_fact->slots[i]);
        }
    }

    ds_recorder_emit_fact_assert(engine, fact);
    if (superseded != NULL) emit_superseded(engine, superseded);

    if (out_fact) *out_fact = fact;
    return DS_OK_R;
}

void ds_rete_wm_retract_inner(struct ds_engine    *engine,
                           struct ds_rete_fact *rete_fact)
{
    ds_rete_wm_retract(engine->rete_engine, rete_fact);
}

ds_result_t ds_rete_wm_retract_bridge(struct ds_engine *engine, ds_fact_t *fact)
{
    ds_rete_fact_t *rete_fact = (ds_rete_fact_t *)fact->rete_fact;
    if (!rete_fact)
        return DS_ERR_R(DS_ERR_FACT_INVALID, "rete_wm_retract: NULL rete_fact");

    /* The TTL pump can leave this wrapper alive past its rete fact, whose memory may be
       back in the pool, so rete_fact is not dereferenced: the recorded id finds the live
       fact, and its address must match, since the LIFO pool reuses addresses. */
    bool rete_alive = false;
    ds_rete_engine_t *re = engine->rete_engine;
    if (re) {
        ds_rete_fact_t *live = ds_rete_wm_find_by_id(re, fact->rete_id);
        if (live && (void *)live == (void *)rete_fact) {
            rete_alive = true;
        }
    }

    /* [RFCS.6.7]: a retract is recorded before the faults its propagation raises.

       [LFST.7.3.6], [RFCS.7a.4]: a cascade retract's record takes its place in the buffer
       before it propagates, so every withdrawal precedes its own consequences, recursively.
       Its wrapper is detached before the push: if the buffer cannot grow the record is
       delivered and the wrapper released at once, so nothing below may touch `fact`.

       An immediate retract records after propagating: its faults are held and its cascades
       buffered. */
    const bool buffered = ds_recorder_should_buffer(engine);
    ds_recorder_hold_faults(engine);
    if (buffered) {
        ds_wm_fact_detach(&engine->wm, fact);
        ds_recorder_emit_fact_retract(engine, fact);   /* owns `fact` now */
    }
    if (rete_alive) {
        ds_rete_wm_retract_inner(engine, rete_fact);
    }

    if (!buffered) {
        /* The table only compares the freed rete_fact's pointer. */
        ds_recorder_emit_fact_retract(engine, fact);
        ds_wm_fact_free(&engine->wm, fact);
    }
    return ds_recorder_release_faults(engine);
}

/* `engine` may be NULL on a test path. */
static ds_slot_value_t rete_val_to_slot(struct ds_engine     *engine,
                                          ds_slot_type_t        type,
                                          const ds_rete_val_t  *v)
{
    ds_slot_value_t out;
    memset(&out, 0, sizeof(out));
    /* [LNUL.9.1]. */
    if (v->kind == DS_RETE_VAL_NULL) {
        out.kind = DS_SLOT_NULL;
        return out;
    }
    switch (type) {
    case DS_SLOT_TYPE_INT:
    /* [RDSC.5.5.8]. */
    case DS_SLOT_TYPE_TIME:
    case DS_SLOT_TYPE_DATE:
    case DS_SLOT_TYPE_DURATION:
        out.kind = DS_SLOT_INT;
        /* now() stored in a Time slot arrives as TIME. */
        out.v.i = (v->kind == DS_RETE_VAL_INT)  ? v->i
                : (v->kind == DS_RETE_VAL_TIME)  ? v->time.utc_ns
                                                 : 0;
        return out;
    case DS_SLOT_TYPE_FLOAT:
        out.kind = DS_SLOT_FLOAT;
        /* [RARC.5.2.6]: rete_slot_kind_admissible admits no INT here. */
        out.v.f = (v->kind == DS_RETE_VAL_FLOAT) ? v->f : 0.0;
        return out;
    case DS_SLOT_TYPE_BOOL:
        out.kind = DS_SLOT_BOOL;
        out.v.b = (v->kind == DS_RETE_VAL_BOOL) ? v->b : false;
        return out;
    case DS_SLOT_TYPE_STRING:
        out.kind = DS_SLOT_STRING;
        if (v->kind == DS_RETE_VAL_STR && v->s.ptr) {
            out.v.s = v->s.ptr;
            /* [IRET.1.4]: released in wm_fact_release. */
            if (engine != NULL && engine->rete_engine != NULL)
                ds_rete_intern_acquire_ptr(engine->rete_engine->intern,
                                           v->s.ptr, v->s.len);
        } else {
            out.v.s = "";
        }
        return out;
    case DS_SLOT_TYPE_BYTES:
        out.kind = DS_SLOT_BYTES;
        /* [RARC.5.2.6]: rete_slot_kind_admissible admits no STR here. */
        if (v->kind == DS_RETE_VAL_BYTES && v->s.ptr) {
            out.v.bytes.data = (const uint8_t *)v->s.ptr;
            out.v.bytes.len  = v->s.len;
            if (engine != NULL && engine->rete_engine != NULL)
                ds_rete_intern_acquire_ptr(engine->rete_engine->intern,
                                           v->s.ptr, v->s.len);
        } else {
            out.v.bytes.data = (const uint8_t *)"";
            out.v.bytes.len  = 0;
        }
        return out;
    case DS_SLOT_TYPE_JSON:
        out.kind = DS_SLOT_JSON;
        out.v.json = (v->kind == DS_RETE_VAL_JSON ||
                      v->kind == DS_RETE_VAL_JSON_BORROW) ? v->json : NULL;
        return out;
    case DS_SLOT_TYPE_SCHEMA: {
        /* The target's fact_id, through the rete id the value carries. A rule emits a
           reference to a fact it matched, so the target is live here. */
        uint64_t target_id = 0u;
        if (engine != NULL && v->kind == DS_RETE_VAL_FACT_REF
                           && v->fact_ref_id != 0u) {
            ds_rete_fact_t *tf =
                ds_rete_wm_find_by_id(engine->rete_engine, v->fact_ref_id);
            ds_fact_t *tw = NULL;
            if (tf != NULL)
                ds_wm_fact_lookup(&engine->wm, (void *)tf, &tw);
            if (tw != NULL)
                target_id = tw->fact_id;
        }
        return ds_wm_slot_of_ref_id(target_id);
    }
    }
    /* Outside the switch, not a `default:`, so a new ds_slot_type_t meets -Wswitch. */
    out.kind = DS_SLOT_INT;
    out.v.i = 0;
    return out;
}

/* Through the referrer's rete fact, whose slot carries the target's rete id. The rete id
   is 32 bits and counts every assertion, so the fact_id check keeps a reference from
   resolving to a later fact once the counter has come round. */
ds_fact_t *ds_wm_fact_ref_resolve(const ds_fact_t *referrer, uint32_t index)
{
    if (referrer == NULL || index >= referrer->n_slots)
        return NULL;
    const ds_slot_value_t *slot = &referrer->slots[index];
    if (slot->kind != DS_SLOT_FACT_REF)
        return NULL;
    const uint64_t want = ds_wm_slot_ref_id(slot);
    struct ds_engine *engine = referrer->engine;
    /* A publish's view has no rete fact ([NCBK.2.5]): it holds the target's
       fact_id, which is never reused, so the id index answers whether that
       fact is live. */
    if (referrer->publish_view)
        return (want == 0u || engine == NULL)
            ? NULL : ds_wm_fact_by_id(&engine->wm, want);
    const ds_rete_fact_t *rf = (const ds_rete_fact_t *) referrer->rete_fact;
    if (want == 0u || engine == NULL || rf == NULL
            || rf->schema == NULL || index >= rf->schema->slot_count)
        return NULL;
    const ds_rete_val_t *rv = &rf->slots[index];
    if (rv->kind != DS_RETE_VAL_FACT_REF || rv->fact_ref_id == 0u)
        return NULL;
    ds_rete_fact_t *tf = ds_rete_wm_find_by_id(engine->rete_engine,
                                               rv->fact_ref_id);
    if (tf == NULL)
        return NULL;
    ds_fact_t *tw = NULL;
    ds_wm_fact_lookup(&engine->wm, (void *) tf, &tw);
    return (tw != NULL && tw->fact_id == want) ? tw : NULL;
}

/* The superseded half of a rule's emit-upsert: the old fact's FactRetract, if it had a
   wrapper, then the activation facts waiting on it ([LSCP.3.1] step 7). */
static void finish_supersede(struct ds_engine *engine, ds_fact_t *superseded,
                             bool superseding, uint32_t old_id)
{
    if (superseded != NULL) emit_superseded(engine, superseded);
    if (superseding)
        ds_engine_act_discharge(engine, engine->rete_engine, old_id);
}

/* [RFCS.6a.4]: a supersede whose successor will not be wrapped. */
void ds_engine_finish_supersede(struct ds_rete_engine *re,
                                struct ds_rete_fact   *old_key,
                                uint32_t               old_id)
{
    if (re == NULL || old_key == NULL) return;
    struct ds_engine *engine = (struct ds_engine *)re->ds_engine_back;
    if (engine == NULL) return;
    ds_fact_t *old_wrap = NULL;
    (void)ds_wm_fact_lookup(&engine->wm, (void *)old_key, &old_wrap);
    if (old_wrap != NULL) ds_wm_fact_detach(&engine->wm, old_wrap);
    finish_supersede(engine, old_wrap, true, old_id);
}

/* Wraps a fact the rule emit path asserted, which bypasses ds_engine_assert. */
ds_result_t ds_rete_wm_wrap_emitted_fact(struct ds_engine    *engine,
                                       struct ds_rete_fact *rete_fact)
{
    if (engine == NULL || rete_fact == NULL || rete_fact->schema == NULL)
        return DS_OK_R;

    /* [RFCS.6a.4], [LFAC.2.5.3]: a rule's emit that supersedes a live fact records the new
       fact and then the old one's withdrawal. The old wrapper is detached before the guard
       below, since the new rete fact can take the freed address and read as a coalesce.
       Before the schema lookup: a compiler-synthesised schema has no wrapper, and its
       superseded fact must still discharge the activation facts waiting on it. */
    ds_fact_t *superseded  = NULL;
    bool       superseding = false;
    uint32_t   old_id      = 0;
    if (engine->rete_engine != NULL
            && engine->rete_engine->supersede_new == rete_fact
            && engine->rete_engine->supersede_old != NULL) {
        ds_fact_t *old_wrap = NULL;
        (void)ds_wm_fact_lookup(&engine->wm,
                                (void *)engine->rete_engine->supersede_old,
                                &old_wrap);
        superseding = true;
        old_id = engine->rete_engine->supersede_old_id;
        engine->rete_engine->supersede_old    = NULL;
        engine->rete_engine->supersede_new    = NULL;
        engine->rete_engine->supersede_old_id = 0;
        if (old_wrap != NULL) {
            ds_wm_fact_detach(&engine->wm, old_wrap);
            superseded = old_wrap;
        }
    }

    const ds_schema_t *schema = NULL;
    ds_schema_registry_find(
        &engine->schemas, rete_fact->schema->name, &schema);
    if (schema == NULL) {
        finish_supersede(engine, superseded, superseding, old_id);
        return DS_OK_R;
    }

    /* A multi-justified logical fact is emitted once per justifying rule: a coalesced
       re-emit added only a justification. */
    {
        ds_fact_t *existing = NULL;
        ds_result_t lr = ds_wm_fact_lookup(&engine->wm, rete_fact, &existing);
        if (lr.status == DS_OK && existing != NULL) {
            finish_supersede(engine, superseded, superseding, old_id);
            return DS_OK_R;
        }
    }

    ds_fact_t *wrapper = NULL;
    ds_result_t r = ds_wm_fact_new(
        &engine->wm, schema, (void *)rete_fact, &wrapper);
    if (r.status != DS_OK) {
        /* The old fact left working memory all the same; record it. */
        finish_supersede(engine, superseded, superseding, old_id);
        return r;
    }

    /* As ds_rete_wm_assert_bridge. */
    wrapper->rete_id = rete_fact->id;
    if (rete_fact->deadline_ns > 0) {
        wrapper->ttl_deadline_ns = (uint64_t)rete_fact->deadline_ns;
        ds_wm_deadline_track(&engine->wm, wrapper);
    }

    uint16_t n = rete_fact->schema->slot_count;
    for (uint16_t i = 0; i < n && i < wrapper->n_slots; i++) {
        wrapper->slots[i] = rete_val_to_slot(
            engine, schema->slots[i].type, &rete_fact->slots[i]);
        /* rete_val_to_slot copies the pointer, and each side frees its own tree. */
        if (wrapper->slots[i].kind == DS_SLOT_JSON
                && wrapper->slots[i].v.json != NULL) {
            ds_json_t *cloned = NULL;
            ds_result_t cr = ds_json_clone(wrapper->slots[i].v.json, &cloned);
            if (cr.status != DS_OK) {
                /* The release frees every Json slot. Slot i still borrows the rete fact's
                   tree, and so would any slot after it. */
                for (uint16_t j = i; j < wrapper->n_slots; j++)
                    if (wrapper->slots[j].kind == DS_SLOT_JSON)
                        wrapper->slots[j].v.json = NULL;
                ds_wm_fact_free(&engine->wm, wrapper);
                finish_supersede(engine, superseded, superseding, old_id);
                return cr;
            }
            wrapper->slots[i].v.json = cloned;
        }
    }

    /* The event fires for either producer; the mark decides the atom the recorder writes. */
    wrapper->rule_emitted = true;
    ds_recorder_emit_fact_assert(engine, wrapper);
    finish_supersede(engine, superseded, superseding, old_id);
    return DS_OK_R;
}

/* [NCBK.2.5]: `p.action_publish.fact`, valid for the callback only: a view of
   the judged values in no working memory ([LTIE.4.3]), freed with DS_FREE once
   the event is out. No fact id (0) and no table. `asserted_at` is the
   `publish`'s instant ([RFCS.23.5]). A string or bytes value borrows the
   caller's argument, which outlives the callback, so no intern reference is
   taken. A fact-reference slot holds its target's fact_id and resolves through
   the id index. */
ds_result_t ds_wm_publish_view(struct ds_engine       *engine,
                               const ds_rete_schema_t *rschema,
                               const ds_rete_val_t    *slots,
                               ds_fact_t             **out)
{
    *out = NULL;
    if (engine == NULL || rschema == NULL || slots == NULL)
        return DS_ERR_R(DS_ERR_INVAL, "publish view: NULL arg");
    const ds_schema_t *schema = NULL;
    ds_schema_registry_find(&engine->schemas, rschema->name, &schema);
    if (schema == NULL)
        return DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN, "publish view: unknown schema");

    const uint32_t n = schema->n_slots;
    ds_fact_t *view = DS_CALLOC(1, sizeof(ds_fact_t)
                                   + (size_t)n * sizeof(ds_slot_value_t));
    if (view == NULL)
        return DS_ERR_R(DS_ERR_OOM, "publish view");
    view->schema       = schema;
    view->engine       = engine;
    view->n_slots      = n;
    view->publish_view = true;
    if (ds_clock_now_ns(&engine->clock, &view->asserted_ns).status != DS_OK)
        view->asserted_ns = 0;
    bool wall_set = false;
    if (ds_clock_wall_ns(&engine->clock, &view->asserted_wall_ns, &wall_set)
            .status != DS_OK)
        wall_set = false;
    view->asserted_wall_set = wall_set;
    if (!wall_set) view->asserted_wall_ns = 0;

    for (uint32_t i = 0; i < n && i < rschema->slot_count; i++) {
        if (schema->slots[i].type == DS_SLOT_TYPE_SCHEMA) {
            uint64_t target_id = 0u;
            if (slots[i].kind == DS_RETE_VAL_FACT_REF
                    && slots[i].fact_ref_id != 0u) {
                ds_rete_fact_t *tf = ds_rete_wm_find_by_id(engine->rete_engine,
                                                           slots[i].fact_ref_id);
                ds_fact_t *tw = NULL;
                if (tf != NULL)
                    ds_wm_fact_lookup(&engine->wm, (void *)tf, &tw);
                if (tw != NULL)
                    target_id = tw->fact_id;
            }
            view->slots[i] = (slots[i].kind == DS_RETE_VAL_NULL)
                ? rete_val_to_slot(NULL, schema->slots[i].type, &slots[i])
                : ds_wm_slot_of_ref_id(target_id);
        } else {
            /* engine NULL: no intern reference is taken (see above). */
            view->slots[i] = rete_val_to_slot(NULL, schema->slots[i].type,
                                              &slots[i]);
        }
    }
    *out = view;
    return DS_OK_R;
}

/* src wrapper* -> clone wrapper*, for the schema-list remap. */
static uint64_t wmap_ptr_hash(const void *k, void *c)
{ (void) c; return (uint64_t) (uintptr_t) *(void *const *) k; }
static bool wmap_ptr_eq(const void *a, const void *b, void *c)
{ (void) c; return *(void *const *) a == *(void *const *) b; }
static ds_fact_t *wmap_get(oa_t *m, const void *sw)
{
    if (!sw) return NULL;
    void *v = ds_oa_get(m, &sw);
    return v ? *(ds_fact_t **) v : NULL;
}

ds_result_t ds_wm_bridge_clone(ds_rete_clone_ctx_t *cx,
                               struct ds_engine *src, struct ds_engine *dst)
{
    oa_t wmap;
    ds_oa_init(&wmap, sizeof(void *), sizeof(void *), 0, wmap_ptr_hash, wmap_ptr_eq, NULL, NULL);

    const uint32_t n = oa_len(&src->wm.table);
    ds_result_t r = DS_OK_R;

    /* In src dense order, keyed by the clone rete fact. */
    for (uint32_t i = 0; i < n; i++) {
        ds_fact_t *sw = *(ds_fact_t *const *) ds_oa_val_at(&src->wm.table, i);
        ds_rete_fact_t *crf =
            (ds_rete_fact_t *) ds_rete_clone_fact_lookup(cx, sw->rete_id);
        if (crf == NULL) { r = DS_ERR_R(DS_ERR_STATE, "wm_bridge_clone: unmapped rete fact"); goto done; }

        const ds_schema_t *dsch = NULL;
        if (sw->schema)
            ds_schema_registry_find(&dst->schemas, sw->schema->type_name, &dsch);
        if (sw->schema && dsch == NULL) { r = DS_ERR_R(DS_ERR_STATE, "wm_bridge_clone: schema missing"); goto done; }

        size_t sz = sizeof(ds_fact_t) + (size_t) sw->n_slots * sizeof(ds_slot_value_t);
        ds_fact_t *cw = DS_CALLOC(1, sz);
        if (!cw) { r = DS_ERR_R(DS_ERR_OOM, "wm_bridge_clone: wrapper"); goto done; }
        cw->fact_id         = sw->fact_id;
        cw->schema          = dsch;
        cw->rete_fact       = crf;
        cw->rete_id         = sw->rete_id;
        cw->engine          = dst;
        cw->asserted_ns     = sw->asserted_ns;
        cw->assert_seq        = sw->assert_seq;
        cw->assert_seq_set    = sw->assert_seq_set;
        cw->asserted_wall_ns  = sw->asserted_wall_ns;
        cw->asserted_wall_set = sw->asserted_wall_set;
        cw->ttl_deadline_ns = sw->ttl_deadline_ns;
        cw->n_slots         = sw->n_slots;
        cw->schema_prev = cw->schema_next = NULL;

        for (uint32_t s = 0; s < sw->n_slots; s++) {
            ds_slot_type_t stype = dsch ? dsch->slots[s].type : DS_SLOT_TYPE_INT;
            if (stype == DS_SLOT_TYPE_SCHEMA) {
                /* The target's fact_id: the clone keeps every fact_id. */
                cw->slots[s] = sw->slots[s];
                continue;
            }
            cw->slots[s] = rete_val_to_slot(dst, stype, &crf->slots[s]);
            /* The wrapper owns its own tree. */
            if (cw->slots[s].kind == DS_SLOT_JSON && cw->slots[s].v.json != NULL) {
                ds_json_t *cj = NULL;
                if (ds_json_clone(cw->slots[s].v.json, &cj).status != DS_OK) {
                    /* The wrapper holds intern references, so the release path, which
                       skips the calloc-zeroed slots not yet filled. */
                    cw->slots[s].v.json = NULL;
                    ds_wm_fact_release_detached(&dst->wm, cw);
                    r = DS_ERR_R(DS_ERR_OOM, "wm_bridge_clone: json"); goto done;
                }
                cw->slots[s].v.json = cj;
            }
        }

        void *vp;
        r = ds_oa_put(&dst->wm.table, &cw->rete_fact, &vp, NULL);
        if (r.status != DS_OK) { ds_wm_fact_release_detached(&dst->wm, cw); goto done; }
        *(ds_fact_t **) vp = cw;
        /* [NFCT.6.4]. On failure `table` owns the wrapper, and the caller's teardown frees it. */
        r = ds_wm_index_id(&dst->wm, cw);
        if (r.status != DS_OK) goto done;

        void *mp;
        r = ds_oa_put(&wmap, &sw, &mp, NULL);
        if (r.status != DS_OK) goto done;
        *(ds_fact_t **) mp = cw;
    }

    for (uint32_t i = 0; i < n; i++) {
        ds_fact_t *sw = *(ds_fact_t *const *) ds_oa_val_at(&src->wm.table, i);
        ds_fact_t *cw = wmap_get(&wmap, sw);
        cw->schema_prev = wmap_get(&wmap, sw->schema_prev);
        cw->schema_next = wmap_get(&wmap, sw->schema_next);
        /* Rebuilt, not remapped: the sweep tests each entry's deadline, so only membership
           matters. */
        ds_wm_deadline_track(&dst->wm, cw);
    }

    for (size_t si = 0; si < src->schemas.n_schemas; si++) {
        const ds_schema_t *ss = src->schemas.schemas[si];
        const ds_schema_t *cs = NULL;
        ds_schema_registry_find(&dst->schemas, ss->type_name, &cs);
        if (cs)
            ((ds_schema_t *) cs)->fact_list_head = wmap_get(&wmap, ss->fact_list_head);
    }

done:
    ds_oa_free(&wmap);
    return r;
}

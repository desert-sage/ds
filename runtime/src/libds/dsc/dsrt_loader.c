/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/* dsrt_loader.c — RealtimeContract atom handler ([RTCT.6]). */
#include "dsrt_loader.h"
#include "ds_alloc.h"
#include "ds_pb_alloc.h"

#include <stdlib.h>
#include <string.h>

#include "engine.h"
#include "rete/engine.h"
#include "rete/intern.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/terminal.h"
#include "sha256.h"
#include "realtime_contract.pb-c.h"

/* ---------------------------------------------------------------- */
/* Canonical RBND.4b serialization.                                 */
/* ---------------------------------------------------------------- */

static const char *kind_to_str(uint8_t kind)
{
    switch (kind) {
    case DS_RETE_CONTRACT_KIND_ALPHA: return "alpha";
    case DS_RETE_CONTRACT_KIND_BETA:  return "beta";
    case DS_RETE_CONTRACT_KIND_TERM:  return "term";
    default: return "?";
    }
}

static int parse_kind(const char *s, uint8_t *out)
{
    if (strcmp(s, "alpha") == 0) { *out = DS_RETE_CONTRACT_KIND_ALPHA; return 0; }
    if (strcmp(s, "beta")  == 0) { *out = DS_RETE_CONTRACT_KIND_BETA;  return 0; }
    if (strcmp(s, "term")  == 0) { *out = DS_RETE_CONTRACT_KIND_TERM;  return 0; }
    return -1;
}

/* Returns the full length, excluding the NUL. NULL/0 is the sizing pass. */
static size_t emit_canonical(const ds_rete_engine_t *e,
                              char *out_buf, size_t buf_cap)
{
    /* The bytes rt_config_sha256 hashes: fixed text and decimal integers only. */
    ds_text_t t = ds_text(out_buf, out_buf ? buf_cap : 0);
    #define LINE_U(key, v) do {                                           \
        ds_text_str(&t, key "=");                                         \
        ds_text_u64(&t, (uint64_t)(v));                                   \
        ds_text_char(&t, '\n');                                           \
    } while (0)

    ds_text_str(&t, "ds.contract.v1\n");
    LINE_U("wm_max",             e->contract_wm_max);
    LINE_U("agenda_cap",         e->contract_agenda_cap);
    LINE_U("max_fires_per_pump", e->contract_max_fires_per_pump);
    LINE_U("token_pool_cap",     e->contract_token_pool_cap);
    LINE_U("intern_cap",         e->contract_intern_cap);
    LINE_U("intern_bytes_cap",   e->contract_intern_bytes_cap);
    LINE_U("pump_wcet_ns",       e->contract_pump_wcet_ns);

    ds_text_str(&t, "nodes=");
    for (uint32_t i = 0; i < e->contract_n_nodes; i++) {
        if (i > 0) ds_text_char(&t, ',');
        ds_text_u64(&t, e->contract_nodes[i].node_id);
        ds_text_char(&t, ':');
        ds_text_str(&t, kind_to_str(e->contract_nodes[i].kind));
        ds_text_char(&t, ':');
        ds_text_u64(&t, e->contract_nodes[i].capacity);
    }
    ds_text_char(&t, '\n');

    ds_text_str(&t, "series=");
    for (uint32_t i = 0; i < e->contract_n_series; i++) {
        if (i > 0) ds_text_char(&t, ',');
        ds_text_u64(&t, e->contract_series[i].series_id);
        ds_text_char(&t, ':');
        ds_text_u64(&t, e->contract_series[i].capacity);
    }
    ds_text_char(&t, '\n');

    /* Each cache bound only when non-zero. */
    if (e->contract_cache_cap)
        LINE_U("cache_cap", e->contract_cache_cap);
    if (e->contract_cache_bytes_cap)
        LINE_U("cache_bytes_cap", e->contract_cache_bytes_cap);
    #undef LINE_U
    return t.len;
}

size_t ds_dsrt_canonical_bytes(const ds_engine_t *engine,
                                char              *out_buf,
                                size_t             buf_cap)
{
    if (!engine || !engine->rete_engine || !engine->rete_engine->has_contract)
        return 0;
    return emit_canonical(engine->rete_engine, out_buf, buf_cap);
}

static int  cmp_node_cap(const void *a, const void *b);   /* fwd */
static void clear_contract(ds_rete_engine_t *re);         /* fwd */

/* [RTCT.6.5], [RDSC.16.3.3] step 3, over the materialized contract_nodes. The caller
 * clears the contract on failure. */
static ds_result_t verify_contract_hash(ds_rete_engine_t *re)
{
    size_t need = emit_canonical(re, NULL, 0);
    if (need == (size_t)-1)
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                              "RealtimeContract: canonical-serialization formatting error" };
    char *canon = DS_MALLOC(need + 1);
    if (!canon)
        return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM on canonical buffer" };
    (void)emit_canonical(re, canon, need + 1);

    uint8_t expected[DS_SHA256_DIGEST_LEN];
    ds_sha256((const uint8_t *)canon, need, expected);
    DS_FREE(canon);

    if (memcmp(expected, re->contract_rt_config_sha256, 32) != 0)
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
            "RealtimeContract: rt_config_sha256 disagrees with recomputed canonical hash" };
    return DS_OK_R;
}

/* No contract-binding getter: realtime is out of the edition ([NRTM.9.1]). */

/* ---------------------------------------------------------------- */
/* Per-node cap application ([RTCT.7.1]).                           */
/* ---------------------------------------------------------------- */

static uint32_t cap_for_node(const ds_rete_engine_t *re,
                              uint32_t node_id, uint8_t want_kind)
{
    uint32_t lo = 0, hi = re->contract_n_nodes;
    while (lo < hi) {
        uint32_t mid = (lo + hi) / 2;
        const ds_rete_contract_node_cap_t *e = &re->contract_nodes[mid];
        if (e->node_id == node_id) {
            return (e->kind == want_kind) ? e->capacity : 0;
        }
        if (e->node_id < node_id) lo = mid + 1;
        else                      hi = mid;
    }
    return 0;
}

/* [RTCT.6.7]: expand a deferred compact contract now the network is loaded, then
 * verify the hash. The compact wire carries no per-node kind, so kinds come from the
 * owned nodes. */
static ds_result_t expand_compact_contract(ds_rete_engine_t *re)
{
    uint32_t n = 0;
    for (uint32_t i = 0; i < re->owned_alpha_count; i++)
        if (re->owned_alphas[i]) n++;
    for (uint32_t i = 0; i < re->owned_beta_count; i++)
        if (re->owned_betas[i]) n++;
    for (uint32_t i = 0; i < re->owned_terminal_count; i++)
        if (re->owned_terminals[i]) n++;

    if (n != re->contract_compact_node_count) {
        clear_contract(re);
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
            "RealtimeContract: compact node_count disagrees with loaded network" };
    }

    if (n > 0) {
        re->contract_nodes = DS_CALLOC(n, sizeof(*re->contract_nodes));
        if (!re->contract_nodes) {
            clear_contract(re);
            return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM expanding contract" };
        }
        uint32_t k = 0;
        for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
            if (!re->owned_alphas[i]) continue;
            re->contract_nodes[k].node_id = re->owned_alphas[i]->node_id;
            re->contract_nodes[k].kind    = DS_RETE_CONTRACT_KIND_ALPHA;
            k++;
        }
        for (uint32_t i = 0; i < re->owned_beta_count; i++) {
            if (!re->owned_betas[i]) continue;
            re->contract_nodes[k].node_id = re->owned_betas[i]->node_id;
            re->contract_nodes[k].kind    = DS_RETE_CONTRACT_KIND_BETA;
            k++;
        }
        for (uint32_t i = 0; i < re->owned_terminal_count; i++) {
            if (!re->owned_terminals[i]) continue;
            re->contract_nodes[k].node_id = re->owned_terminals[i]->node_id;
            re->contract_nodes[k].kind    = DS_RETE_CONTRACT_KIND_TERM;
            k++;
        }
        re->contract_n_nodes = n;
        qsort(re->contract_nodes, n, sizeof(*re->contract_nodes), cmp_node_cap);

        if (re->contract_compact_packed) {
            /* [RTCT.6.7.4]: in ascending node_id order. */
            for (uint32_t i = 0; i < n; i++)
                re->contract_nodes[i].capacity = re->contract_compact_packed[i];
        } else {
            /* [RTCT.6.7.3] */
            for (uint32_t i = 0; i < n; i++)
                re->contract_nodes[i].capacity = re->contract_compact_default;
            uint32_t prev_id = 0;
            for (uint32_t j = 0; j < re->contract_compact_n_overrides; j++) {
                uint32_t id  = re->contract_compact_overrides[j].node_id;
                uint32_t cap = re->contract_compact_overrides[j].capacity;
                if (j > 0 && id <= prev_id) {
                    clear_contract(re);
                    return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                        "RealtimeContract: overrides not strictly ascending node_id" };
                }
                prev_id = id;
                uint32_t lo = 0, hi = n, found = n;
                while (lo < hi) {
                    uint32_t mid = (lo + hi) / 2;
                    uint32_t mid_id = re->contract_nodes[mid].node_id;
                    if (mid_id == id) { found = mid; break; }
                    if (mid_id < id) lo = mid + 1; else hi = mid;
                }
                if (found == n) {
                    clear_contract(re);
                    return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                        "RealtimeContract: override for unknown node_id" };
                }
                re->contract_nodes[found].capacity = cap;
            }
        }
    }

    DS_FREE(re->contract_compact_overrides);
    DS_FREE(re->contract_compact_packed);
    re->contract_compact_overrides   = NULL;
    re->contract_compact_packed      = NULL;
    re->contract_compact_n_overrides = 0;
    re->contract_compact_n_packed    = 0;
    re->contract_compact_pending     = false;

    ds_result_t hr = verify_contract_hash(re);
    if (hr.status != DS_OK) {
        clear_contract(re);
        return hr;
    }
    return DS_OK_R;
}

ds_result_t ds_dsrt_apply_node_caps(ds_engine_t *engine)
{
    if (!engine || !engine->rete_engine) return DS_OK_R;
    ds_rete_engine_t *re = engine->rete_engine;
    if (!re->has_contract) return DS_OK_R;

    if (re->contract_compact_pending) {
        ds_result_t er = expand_compact_contract(re);
        if (er.status != DS_OK) return er;
    }

    for (uint32_t i = 0; i < re->owned_alpha_count; i++) {
        ds_rete_alpha_node_t *a = re->owned_alphas[i];
        if (!a) continue;
        a->contract_capacity =
            cap_for_node(re, a->node_id, DS_RETE_CONTRACT_KIND_ALPHA);
    }
    for (uint32_t i = 0; i < re->owned_beta_count; i++) {
        ds_rete_beta_node_t *b = re->owned_betas[i];
        if (!b) continue;
        b->contract_capacity =
            cap_for_node(re, b->node_id, DS_RETE_CONTRACT_KIND_BETA);
    }
    for (uint32_t i = 0; i < re->owned_terminal_count; i++) {
        ds_rete_terminal_t *t = re->owned_terminals[i];
        if (!t) continue;
        t->contract_capacity =
            cap_for_node(re, t->node_id, DS_RETE_CONTRACT_KIND_TERM);
    }
    return DS_OK_R;
}

ds_result_t ds_contract_dump_canonical_body(const ds_engine_t *engine,
                                            char             **out_buf,
                                            size_t            *out_len)
{
    if (out_buf) *out_buf = NULL;
    if (out_len) *out_len = 0;
    if (!engine || !out_buf || !out_len)
        return (ds_result_t){ DS_ERR_INVAL,
                              "ds_contract_dump_canonical: NULL arg" };
    DS_ENGINE_REFUSE_IF_HALTED(engine);
    if (!engine->rete_engine || !engine->rete_engine->has_contract)
        return (ds_result_t){ DS_ERR_CONTRACT_MISSING,
                              "ds_contract_dump_canonical: no contract loaded" };

    size_t need = emit_canonical(engine->rete_engine, NULL, 0);
    if (need == (size_t)-1)
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                              "ds_contract_dump_canonical: format error" };

    char *buf = DS_MALLOC(need + 1);
    if (!buf)
        return (ds_result_t){ DS_ERR_OOM,
                              "ds_contract_dump_canonical: OOM" };
    (void)emit_canonical(engine->rete_engine, buf, need + 1);
    *out_buf = buf;
    *out_len = need;
    return DS_OK_R;
}

/* ---------------------------------------------------------------- */
/* Loader.                                                          */
/* ---------------------------------------------------------------- */

static void clear_contract(ds_rete_engine_t *re)
{
    if (!re) return;
    DS_FREE(re->contract_nodes);
    DS_FREE(re->contract_series);
    DS_FREE(re->contract_compact_overrides);
    DS_FREE(re->contract_compact_packed);
    re->contract_nodes   = NULL;
    re->contract_series  = NULL;
    re->contract_compact_overrides = NULL;
    re->contract_compact_packed    = NULL;
    re->contract_n_nodes  = 0;
    re->contract_n_series = 0;
    re->contract_compact_n_overrides = 0;
    re->contract_compact_n_packed    = 0;
    re->contract_compact_node_count  = 0;
    re->contract_compact_default     = 0;
    re->contract_compact_pending     = false;
    re->has_contract = false;
}

static int cmp_node_cap(const void *a, const void *b)
{
    const ds_rete_contract_node_cap_t *na = a;
    const ds_rete_contract_node_cap_t *nb = b;
    return (na->node_id < nb->node_id) ? -1
         : (na->node_id > nb->node_id) ?  1 : 0;
}

static int cmp_series_cap(const void *a, const void *b)
{
    const ds_rete_contract_series_cap_t *sa = a;
    const ds_rete_contract_series_cap_t *sb = b;
    return (sa->series_id < sb->series_id) ? -1
         : (sa->series_id > sb->series_id) ?  1 : 0;
}

ds_result_t ds_dsrt_handle_atom(ds_engine_t   *engine,
                                 const uint8_t *body,
                                 size_t         body_len)
{
    if (!engine || !engine->rete_engine || !body) {
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                              "RealtimeContract: null engine or body" };
    }

    /* [RDSC.9.5] */
    if (ds_pb_rdsc_9_5_repeats(&ds__v1__realtime_contract__descriptor, body,
                               body_len)) {
        return (ds_result_t){ DS_ERR_DSC_DECODE,
                              "dsc: RealtimeContract body holds a message "
                              "field that is not repeated more than once" };
    }
    Ds__V1__RealtimeContract *msg =
        ds__v1__realtime_contract__unpack(&ds_pb_allocator, body_len, body);
    if (!msg) {
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                              "RealtimeContract: protobuf decode failed" };
    }

    ds_rete_engine_t *re = engine->rete_engine;
    clear_contract(re);

    re->contract_wm_max             = msg->wm_max;
    re->contract_agenda_cap         = msg->agenda_cap;
    re->contract_max_fires_per_pump = msg->max_fires_per_pump;
    re->contract_token_pool_cap     = msg->token_pool_cap;
    re->contract_intern_cap         = msg->intern_cap;
    re->contract_intern_bytes_cap   = msg->intern_bytes_cap;
    re->contract_pump_wcet_ns       = msg->pump_wcet_ns;
    re->contract_cache_cap          = msg->cache_cap;
    re->contract_cache_bytes_cap    = msg->cache_bytes_cap;

    if (msg->rt_config_sha256.len != 32) {
        ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
        clear_contract(re);
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                              "RealtimeContract: rt_config_sha256 must be 32 bytes" };
    }
    memcpy(re->contract_rt_config_sha256, msg->rt_config_sha256.data, 32);

    /* [RTCT.6.7.1]: exactly one of legacy `nodes` and the compact fields. Compact
     * carries no kind, so it waits for the network (apply_node_caps). */
    bool has_legacy  = msg->n_nodes > 0;
    bool has_compact = msg->node_count > 0
                    || msg->n_node_overrides > 0
                    || msg->n_node_caps_packed > 0;
    if (has_legacy && has_compact) {
        ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
        clear_contract(re);
        return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
            "RealtimeContract: both legacy nodes and compact node-cap fields present" };
    }

    if (has_legacy) {
        re->contract_nodes = DS_CALLOC(msg->n_nodes,
                                    sizeof(*re->contract_nodes));
        if (!re->contract_nodes) {
            ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
            clear_contract(re);
            return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM on nodes" };
        }
        for (size_t i = 0; i < msg->n_nodes; i++) {
            const Ds__V1__NodeCap *n = msg->nodes[i];
            re->contract_nodes[i].node_id  = n->node_id;
            re->contract_nodes[i].capacity = n->capacity;
            uint8_t kind_byte = 0;
            if (!n->kind || parse_kind(n->kind, &kind_byte) != 0) {
                ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
                clear_contract(re);
                return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                                      "RealtimeContract: unknown node kind" };
            }
            re->contract_nodes[i].kind = kind_byte;
        }
        re->contract_n_nodes = (uint32_t)msg->n_nodes;
        qsort(re->contract_nodes, re->contract_n_nodes,
              sizeof(*re->contract_nodes), cmp_node_cap);
    } else if (has_compact) {
        /* [RTCT.6.7.4]: the shape now; the rest at end-of-load. */
        if (msg->n_node_caps_packed > 0) {
            if (msg->default_node_cap != 0 || msg->n_node_overrides > 0) {
                ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
                clear_contract(re);
                return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                    "RealtimeContract: packed encoding with default_node_cap/overrides set" };
            }
            if (msg->n_node_caps_packed != msg->node_count) {
                ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
                clear_contract(re);
                return (ds_result_t){ DS_ERR_CONTRACT_INVALID,
                    "RealtimeContract: packed length != node_count" };
            }
            re->contract_compact_packed =
                DS_CALLOC(msg->n_node_caps_packed, sizeof(uint32_t));
            if (!re->contract_compact_packed) {
                ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
                clear_contract(re);
                return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM on packed caps" };
            }
            for (size_t i = 0; i < msg->n_node_caps_packed; i++)
                re->contract_compact_packed[i] = msg->node_caps_packed[i];
            re->contract_compact_n_packed = (uint32_t)msg->n_node_caps_packed;
        } else if (msg->n_node_overrides > 0) {
            re->contract_compact_overrides =
                DS_CALLOC(msg->n_node_overrides,
                          sizeof(*re->contract_compact_overrides));
            if (!re->contract_compact_overrides) {
                ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
                clear_contract(re);
                return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM on overrides" };
            }
            for (size_t i = 0; i < msg->n_node_overrides; i++) {
                const Ds__V1__NodeCapOverride *o = msg->node_overrides[i];
                re->contract_compact_overrides[i].node_id  = o->node_id;
                re->contract_compact_overrides[i].capacity = o->capacity;
                re->contract_compact_overrides[i].kind     = 0;
            }
            re->contract_compact_n_overrides = (uint32_t)msg->n_node_overrides;
        }
        re->contract_compact_default    = msg->default_node_cap;
        re->contract_compact_node_count = msg->node_count;
        re->contract_compact_pending    = true;
    }

    if (msg->n_series > 0) {
        re->contract_series = DS_CALLOC(msg->n_series,
                                     sizeof(*re->contract_series));
        if (!re->contract_series) {
            ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);
            clear_contract(re);
            return (ds_result_t){ DS_ERR_OOM, "RealtimeContract: OOM on series" };
        }
        for (size_t i = 0; i < msg->n_series; i++) {
            const Ds__V1__SeriesCap *s = msg->series[i];
            re->contract_series[i].series_id = s->series_id;
            re->contract_series[i].capacity  = s->capacity;
        }
        re->contract_n_series = (uint32_t)msg->n_series;
        qsort(re->contract_series, re->contract_n_series,
              sizeof(*re->contract_series), cmp_series_cap);
    }

    re->has_contract = true;
    ds__v1__realtime_contract__free_unpacked(msg, &ds_pb_allocator);

    /* An integrator's value set before load stands. */
    if (re->wm_max_facts == 0)   re->wm_max_facts   = re->contract_wm_max;
    if (re->token_pool_cap == 0) re->token_pool_cap = re->contract_token_pool_cap;
    if (re->max_fires_rt == 0)   re->max_fires_rt   = re->contract_max_fires_per_pump;

    if (re->intern) {
        ds_rete_intern_set_contract_caps(re->intern,
                                          re->contract_intern_cap,
                                          re->contract_intern_bytes_cap);
    }

    ds_cache_set_caps(&engine->cache, re->contract_cache_cap,
                      re->contract_cache_bytes_cap);

    /* A compact contract's hash waits for ds_dsrt_apply_node_caps. */
    if (!re->contract_compact_pending) {
        ds_result_t hr = verify_contract_hash(re);
        if (hr.status != DS_OK) {
            clear_contract(re);
            return hr;
        }
    }

    return DS_OK_R;
}

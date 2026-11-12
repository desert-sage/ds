/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/loader.c — Rete network loader (IRET.15, RDSC.4a).
 */
#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "ds_alloc.h"
#include "ds_re2.h"

#include "rete/action.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/fault_fact.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/wm_rete.h"

/* ---- Node-id map: node_id -> node; capacity a power of two ---------- */

typedef enum { NM_ALPHA, NM_BETA, NM_TERM } nm_kind_t;

typedef struct {
    uint32_t   id;    /* 0 = empty slot */
    nm_kind_t  kind;
    void      *ptr;
} nm_slot_t;

typedef struct {
    nm_slot_t *slots;
    uint32_t   cap;
    uint32_t   count;
} node_map_t;

static ds_result_t nm_init(node_map_t *m, uint32_t initial_cap)
{
    uint32_t cap = 16;
    while (cap < initial_cap) cap <<= 1;
    m->slots = DS_CALLOC(cap, sizeof(*m->slots));
    if (!m->slots) return DS_ERR_R(DS_ERR_OOM, "loader: node_map");
    m->cap   = cap;
    m->count = 0;
    return DS_OK_R;
}

static void nm_free(node_map_t *m)
{
    DS_FREE(m->slots);
    m->slots = NULL;
}

static ds_result_t nm_insert(node_map_t *m, uint32_t id, nm_kind_t kind, void *ptr)
{
    if (id == 0)
        return DS_ERR_R(DS_ERR_RETP_INVALID, "loader: node_id 0 is reserved");

    if (m->count * 4 >= m->cap * 3) {
        uint32_t newcap = m->cap << 1;
        nm_slot_t *ns = DS_CALLOC(newcap, sizeof(*ns));
        if (!ns) return DS_ERR_R(DS_ERR_OOM, "loader: node_map grow");
        for (uint32_t i = 0; i < m->cap; i++) {
            if (!m->slots[i].id) continue;
            uint32_t h = m->slots[i].id & (newcap - 1);
            while (ns[h].id) h = (h + 1) & (newcap - 1);
            ns[h] = m->slots[i];
        }
        DS_FREE(m->slots);
        m->slots = ns;
        m->cap   = newcap;
    }

    uint32_t h = id & (m->cap - 1);
    while (m->slots[h].id) {
        if (m->slots[h].id == id)
            return DS_ERR_R(DS_ERR_RETP_INVALID, "loader: duplicate node_id");
        h = (h + 1) & (m->cap - 1);
    }
    m->slots[h] = (nm_slot_t){ .id = id, .kind = kind, .ptr = ptr };
    m->count++;
    return DS_OK_R;
}

static nm_slot_t *nm_find(const node_map_t *m, uint32_t id)
{
    if (!id || !m->cap) return NULL;
    uint32_t h = id & (m->cap - 1);
    for (uint32_t i = 0; i < m->cap; i++) {
        nm_slot_t *s = &m->slots[h];
        if (!s->id)     return NULL;
        if (s->id == id) return s;
        h = (h + 1) & (m->cap - 1);
    }
    return NULL;
}

/* ---- Engine node registration helpers ----------------------------- */

static ds_result_t engine_own_alpha(ds_rete_engine_t     *e,
                                     ds_rete_alpha_node_t *n)
{
    ds_rete_alpha_node_t **nb =
        DS_REALLOC(e->owned_alphas,
                (e->owned_alpha_count + 1) * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "own_alpha");
    nb[e->owned_alpha_count++] = n;
    e->owned_alphas = nb;
    return DS_OK_R;
}

static ds_result_t engine_own_beta(ds_rete_engine_t    *e,
                                    ds_rete_beta_node_t *n)
{
    ds_rete_beta_node_t **nb =
        DS_REALLOC(e->owned_betas,
                (e->owned_beta_count + 1) * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "own_beta");
    nb[e->owned_beta_count++] = n;
    e->owned_betas = nb;
    return DS_OK_R;
}

static ds_result_t engine_own_terminal(ds_rete_engine_t   *e,
                                        ds_rete_terminal_t *n)
{
    ds_rete_terminal_t **nb =
        DS_REALLOC(e->owned_terminals,
                (e->owned_terminal_count + 1) * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "own_terminal");
    nb[e->owned_terminal_count++] = n;
    e->owned_terminals = nb;
    return DS_OK_R;
}

/* ---- Right-activation order ([IRET.7.7]) ------------------------------
 *
 * Each chain sharing an alpha is right-activated deepest node first, so a match
 * holding the fact at two depths of a self-join is built once: a shallow node's
 * extensions reach a deeper node already activated with the fact. Chains keep
 * their order. Retraction walks the same list. This is
 * `iret_7_7__right_activate` and `iret_7_7__right_retract` in
 * formal/idris/Rete/Network.idr.
 *
 * A chain is identified by its root, reached by following left parents; depth is
 * the number of left parents above a node. O(n^2) in one alpha's fan-out. */
static const ds_rete_beta_node_t *beta_root(const ds_rete_beta_node_t *b,
                                            uint32_t *depth)
{
    uint32_t d = 0;
    while (b->left_parent) { b = b->left_parent; d++; }
    *depth = d;
    return b;
}

/* [RDSC.4a.5]: every left_parent chain ends at a root beta, or the artefact is
   refused with DS_ERR_RETP_INVALID. A beta has one parent at most, so a walk down
   the children from the roots reaches each beta once, and one it never reaches is
   on or below a cycle. One pass, linear in the betas ([RDSC.9.9]); beta_root and
   every later walk up a chain rely on it. */
static ds_result_t rdsc_4a_5_chains_end_at_a_root(ds_rete_beta_node_t **betas,
                                                  uint32_t              n)
{
    if (n == 0) return DS_OK_R;
    ds_rete_beta_node_t **stack = DS_MALLOC((size_t)n * sizeof(*stack));
    if (!stack) return DS_ERR_R(DS_ERR_OOM, "loader: beta chain check");
    uint32_t top = 0, reached = 0;
    for (uint32_t i = 0; i < n; i++)
        if (betas[i]->left_parent == NULL) stack[top++] = betas[i];
    while (top > 0) {
        const ds_rete_beta_node_t *b = stack[--top];
        reached++;
        for (uint32_t c = 0; c < b->beta_child_count; c++)
            stack[top++] = b->beta_children[c];
    }
    DS_FREE(stack);
    if (reached < n)
        return DS_ERR_R(DS_ERR_RETP_INVALID,
                        "loader: BetaNode left_parent_id references form a cycle "
                        "(RDSC.4a.5)");
    return DS_OK_R;
}

static void alpha_outputs_deepest_first(ds_rete_alpha_node_t *alpha)
{
    uint32_t n = alpha->beta_output_count;
    if (n < 2) return;
    ds_rete_beta_node_t **out = alpha->beta_outputs;
    /* In place: chains in order of first appearance, each gathered and sorted. */
    uint32_t next = 0;
    while (next < n) {
        uint32_t d0;
        const ds_rete_beta_node_t *root = beta_root(out[next], &d0);
        uint32_t end = next + 1;
        for (uint32_t j = next + 1; j < n; j++) {
            uint32_t dj;
            if (beta_root(out[j], &dj) != root) continue;
            ds_rete_beta_node_t *m = out[j];
            for (uint32_t k = j; k > end; k--) out[k] = out[k - 1];
            out[end++] = m;
        }
        /* [next, end) by depth, descending */
        for (uint32_t j = next + 1; j < end; j++) {
            ds_rete_beta_node_t *m = out[j];
            uint32_t dm;
            (void)beta_root(m, &dm);
            uint32_t k = j;
            while (k > next) {
                uint32_t dk;
                (void)beta_root(out[k - 1], &dk);
                if (dk >= dm) break;
                out[k] = out[k - 1];
                k--;
            }
            out[k] = m;
        }
        next = end;
    }
}

static ds_result_t convert_alpha_test(ds_rete_engine_t           *engine,
                                       const ds_retp_alpha_test_t *in,
                                       ds_rete_alpha_test_t       *out)
{
    out->kind        = in->kind;
    out->slot_index  = in->slot_index;
    out->op          = in->op;
    out->literal     = in->literal;
    out->compiled_re = NULL;

    if (in->kind == DS_RETE_ALPHA_REGEX) {
        /* [RDSC.4a.6]: compiled once, at load. AlphaTest has no flags field: a
           `/pat/i` arrives as an inline `(?i)`. */
        if (in->pattern == NULL) {
            return DS_ERR_R(DS_ERR_RETP_INVALID,
                            "loader: alpha REGEX test has no pattern");
        }
        char re_err[256];
        re_err[0] = '\0';
        ds_re2_t *re = ds_re2_compile(in->pattern, 0, re_err, sizeof re_err);
        if (re == NULL) {
            /* [IALC.3.6] */
            if (strcmp(re_err, DS_RE2_ERR_OOM) == 0)
                return DS_ERR_R(DS_ERR_OOM,
                                "loader: out of memory compiling an alpha REGEX test");
            /* [RDSC.4a.6.1]; Mercury: `ds.dsc.invalid_alpha_regex`. */
            return DS_ERR_R(DS_ERR_DSC_SEMANTIC,
                            "loader: alpha REGEX test pattern does not compile "
                            "(RDSC.4a.6.1)");
        }
        out->compiled_re = re;
        /* Interned: it outlives the atom, and a clone recompiles from it. */
        ds_result_t pr = ds_rete_intern_cstr(engine->intern, in->pattern,
                                             &out->pattern);
        if (pr.status != DS_OK) { ds_re2_free(re); out->compiled_re = NULL; return pr; }
        return DS_OK_R;
    }

    if (in->kind != DS_RETE_ALPHA_REGEX &&
        out->literal.kind == DS_RETE_VAL_STR && out->literal.s.ptr) {
        const char *ip;
        ds_result_t r = ds_rete_intern(engine->intern, out->literal.s.ptr,
                                       out->literal.s.len, &ip);
        if (r.status != DS_OK) return r;
        out->literal.s.ptr = ip;
    }
    return DS_OK_R;
}

/* ---- Public API --------------------------------------------------- */

ds_result_t ds_rete_load_network(ds_rete_engine_t        *engine,
                                   const ds_rete_network_t *network)
{
    if (!engine || !network)
        return DS_ERR_R(DS_ERR_INVAL, "load_network: NULL arg");

    ds_result_t r = DS_OK_R;

    uint32_t total = network->alfa_count + network->beta_count
                     + network->term_count;
    node_map_t map = {0};
    r = nm_init(&map, total ? total * 2 : 16);
    if (r.status != DS_OK) return r;

    ds_rete_alpha_node_t **alpha_ptrs = NULL;
    ds_rete_beta_node_t  **beta_ptrs  = NULL;
    ds_rete_terminal_t   **term_ptrs  = NULL;

    if (network->alfa_count) {
        alpha_ptrs = DS_CALLOC(network->alfa_count, sizeof(*alpha_ptrs));
        if (!alpha_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "loader: alpha_ptrs"); goto cleanup; }
    }
    if (network->beta_count) {
        beta_ptrs = DS_CALLOC(network->beta_count, sizeof(*beta_ptrs));
        if (!beta_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "loader: beta_ptrs"); goto cleanup; }
    }
    if (network->term_count) {
        term_ptrs = DS_CALLOC(network->term_count, sizeof(*term_ptrs));
        if (!term_ptrs) { r = DS_ERR_R(DS_ERR_OOM, "loader: term_ptrs"); goto cleanup; }
    }

    /* ---- 1. Create alpha nodes ------------------------------------ */

    for (uint32_t i = 0; i < network->alfa_count; i++) {
        const ds_alfa_atom_t *aa = &network->alfas[i];

        const ds_rete_schema_t *schema = ds_rete_schema_by_name(engine, aa->schema_name);
        if (!schema) {
            ds_text_t d = ds_rete_engine_detail(engine);
            ds_text_str(&d, "loader: AlphaNode[");
            ds_text_u64(&d, i);
            ds_text_str(&d, "] references schema '");
            ds_text_str(&d, aa->schema_name ? aa->schema_name : "(null)");
            ds_text_str(&d, "' not registered in the Rete engine");
            r = DS_ERR_R(DS_ERR_SCHEMA_UNKNOWN, ds_rete_engine_detail_text(&d,
                     "loader: an AlphaNode references a schema not registered in "
                     "the Rete engine"));
            goto cleanup;
        }

        ds_rete_alpha_test_t *tests = NULL;
        if (aa->test_count > 0) {
            tests = DS_CALLOC(aa->test_count, sizeof(*tests));
            if (!tests) { r = DS_ERR_R(DS_ERR_OOM, "loader: alpha tests"); goto cleanup; }
            for (uint32_t t = 0; t < aa->test_count; t++) {
                r = convert_alpha_test(engine, &aa->tests[t], &tests[t]);
                if (r.status != DS_OK) { DS_FREE(tests); goto cleanup; }
            }
        }

        r = ds_rete_alpha_node_create(schema->id, tests, aa->test_count,
                                       &alpha_ptrs[i]);
        DS_FREE(tests);
        if (r.status != DS_OK) goto cleanup;

        /* The engine frees only what it owns; until then the node is ours. */
        r = engine_own_alpha(engine, alpha_ptrs[i]);
        if (r.status != DS_OK) {
            ds_rete_alpha_node_destroy(alpha_ptrs[i]);
            alpha_ptrs[i] = NULL;
            goto cleanup;
        }

        r = ds_rete_dispatch_add(engine, schema->id, alpha_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;

        alpha_ptrs[i]->node_id = aa->node_id;
        ds_rete_fault_rule_name(alpha_ptrs[i]->fault_rule, true, aa->node_id);

        r = nm_insert(&map, aa->node_id, NM_ALPHA, alpha_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;
    }

    /* ---- 2. Create beta nodes (left_parent wired at 4) ------------- */

    for (uint32_t i = 0; i < network->beta_count; i++) {
        const ds_beta_atom_t *ba = &network->betas[i];

        nm_slot_t *aslot = nm_find(&map, ba->right_alpha_id);
        if (!aslot || aslot->kind != NM_ALPHA) {
            r = DS_ERR_R(DS_ERR_RETP_INDEX_OOB,
                         "loader: BetaNode right_alpha_id not found");
            goto cleanup;
        }
        ds_rete_alpha_node_t *right_alpha = aslot->ptr;

        r = ds_rete_beta_node_create(NULL, right_alpha,
                                      ba->join_tests, ba->join_test_count,
                                      ba->is_negative, &beta_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;

        /* The join-test exprs moved into the node: NULLed here so the DSC
           loader's failure cleanup does not free them again. */
        {
            ds_beta_atom_t *ba_mut = (ds_beta_atom_t *)ba;
            for (uint32_t j = 0; j < ba->join_test_count; j++)
                ba_mut->join_tests[j].expr = NULL;
        }

        r = engine_own_beta(engine, beta_ptrs[i]);
        if (r.status != DS_OK) {
            ds_rete_beta_node_destroy(beta_ptrs[i]);
            beta_ptrs[i] = NULL;
            goto cleanup;
        }

        r = ds_rete_alpha_add_beta_output(right_alpha, beta_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;

        beta_ptrs[i]->node_id = ba->node_id;
        ds_rete_fault_rule_name(beta_ptrs[i]->fault_rule, false, ba->node_id);

        r = nm_insert(&map, ba->node_id, NM_BETA, beta_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;
    }

    /* ---- 3. Create terminal nodes --------------------------------- */

    for (uint32_t i = 0; i < network->term_count; i++) {
        const ds_term_atom_t *ta = &network->terms[i];

        const char *rname;
        r = ds_rete_intern_cstr(engine->intern, ta->rule_name, &rname);
        if (r.status != DS_OK) goto cleanup;

        /* [LDET.5.4]: the ordinal is the atom's index, which is source order
           ([RLOW.14.3]). */
        r = ds_rete_terminal_create(rname, i, &term_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;

        /* Owned before anything moves into it: a failed add leaves what moved
           with the engine and the rest with the atom, each freed once. */
        r = engine_own_terminal(engine, term_ptrs[i]);
        if (r.status != DS_OK) {
            ds_rete_terminal_destroy(term_ptrs[i]);
            term_ptrs[i] = NULL;
            goto cleanup;
        }

        term_ptrs[i]->node_id         = ta->node_id;
        term_ptrs[i]->bind_count      = ta->bind_count;

        /* The fire guard and every action's exprs move, each source NULLed. */
        ds_term_atom_t *ta_mut = (ds_term_atom_t *)ta;
        term_ptrs[i]->fire_guard = ta->fire_guard;
        ta_mut->fire_guard = NULL;

        for (uint32_t a = 0; a < ta->action_count; a++) {
            r = ds_rete_terminal_add_action(term_ptrs[i], &ta->actions[a]);
            if (r.status != DS_OK) goto cleanup;
            ds_rete_action_t *act = &ta_mut->actions[a];
            act->expr = NULL;
            act->ttl_override = NULL;
            for (uint32_t k = 0; k < act->assign_count; k++)
                act->assigns[k].expr = NULL;
        }

        r = nm_insert(&map, ta->node_id, NM_TERM, term_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;
    }

    /* ---- 4. Wire deferred left_parent relationships --------------- */

    for (uint32_t i = 0; i < network->beta_count; i++) {
        const ds_beta_atom_t *ba = &network->betas[i];

        if (ba->left_parent_id != 0) {
            nm_slot_t *bslot = nm_find(&map, ba->left_parent_id);
            if (!bslot || bslot->kind != NM_BETA) {
                r = DS_ERR_R(DS_ERR_RETP_INDEX_OOB,
                             "loader: BetaNode left_parent_id not found");
                goto cleanup;
            }
            beta_ptrs[i]->left_parent = bslot->ptr;
            r = ds_rete_beta_add_child(bslot->ptr, beta_ptrs[i]);
            if (r.status != DS_OK) goto cleanup;
        }
    }

    for (uint32_t i = 0; i < network->term_count; i++) {
        const ds_term_atom_t *ta = &network->terms[i];

        nm_slot_t *bslot = nm_find(&map, ta->parent_beta_id);
        if (!bslot || bslot->kind != NM_BETA) {
            r = DS_ERR_R(DS_ERR_RETP_INDEX_OOB,
                         "loader: TerminalNode parent_beta_id not found");
            goto cleanup;
        }
        r = ds_rete_beta_add_terminal(bslot->ptr, term_ptrs[i]);
        if (r.status != DS_OK) goto cleanup;
    }

    /* ---- 4a. No left_parent cycle, before anything walks a chain --- */

    r = rdsc_4a_5_chains_end_at_a_root(beta_ptrs, network->beta_count);
    if (r.status != DS_OK) goto cleanup;

    /* ---- 4b. Each alpha right-activates its chains deepest node first */

    for (uint32_t i = 0; i < network->alfa_count; i++)
        alpha_outputs_deepest_first(alpha_ptrs[i]);

    /* ---- 4c. The fault handlers' sites ([LERR.9.6]) --------------- *
     * Before anything propagates: seeding a root beta can run a join test,
     * and a fault there must already know whether it is a handler's. */
    ds_rete_fault_fact_mark_handlers(engine);

    /* ---- 5. Seed root betas with nil tokens ----------------------- */

    for (uint32_t i = 0; i < network->beta_count; i++) {
        if (network->betas[i].left_parent_id != 0) continue;
        ds_rete_token_t *nil = ds_rete_token_create_nil(NULL, NULL, &r);
        if (!nil) goto cleanup;
        r = ds_rete_beta_left_activate(beta_ptrs[i], nil, engine);
        ds_rete_token_free(nil);
        if (r.status != DS_OK) goto cleanup;
    }

    /* Pre-size the intern table off RT (RT presizes its own). The node count
       stands in for the vocabulary. */
    if (r.status == DS_OK && !engine->pools_ready) {
        size_t hint = ((size_t)network->alfa_count +
                       (size_t)network->beta_count +
                       (size_t)network->term_count) * 4 + 64;
        /* [RDSC.9.8]'s exception: the table also grows on demand, so a failure
           here is absorbed and leaves it whole. */
        (void)ds_rete_intern_presz(engine->intern, hint);
    }

cleanup:
    nm_free(&map);
    DS_FREE(alpha_ptrs);
    DS_FREE(beta_ptrs);
    DS_FREE(term_ptrs);
    return r;
}

ds_result_t ds_rete_load(struct ds_rete_engine *engine,
                          const uint8_t         *atom_bytes,
                          size_t                 len)
{
    (void)engine; (void)atom_bytes; (void)len;
    return DS_ERR_R(DS_ERR_UNSUPPORTED,
                    "ds_rete_load: protobuf decoder not yet implemented");
}

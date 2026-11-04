/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/alpha.c — alpha network implementation (IRET.6).
 */
#include <stdlib.h>
#include <string.h>
#include <math.h>    /* fabs */

#include "libds.h"
#include "ds_alloc.h"
#include "ds_re2.h"

#include "rete/alpha.h"
#include "rete/clone.h"
#include "rete/eval.h"
#include "rete/fact.h"
#include "rete/val.h"

/* ---- A matching-time fault's rule name ([LERR.9.11]) --------------- */

/* Synthetic names ([LLEX.10.6.1]): `$` is no NAME character. */
const char ds_rete_fault_rule_engine[] = "$engine";

/* By hand: libds links no printf family. */
void ds_rete_fault_rule_name(char out[DS_RETE_FAULT_RULE_CAP], bool alpha,
                             uint32_t node_id)
{
    static const char a[] = "$alpha_", b[] = "$beta_";
    const char *prefix = alpha ? a : b;
    size_t n = 0;
    for (; prefix[n] != '\0'; n++) out[n] = prefix[n];
    char digits[10];
    size_t d = 0;
    do { digits[d++] = (char)('0' + node_id % 10u); node_id /= 10u; }
    while (node_id != 0u);
    while (d > 0) out[n++] = digits[--d];
    out[n]   = '\0';
}

/* ---- Alpha node lifecycle ----------------------------------------- */

#define ALPHA_MEM_MAX_LOAD  70u

/* oa mixes the returned hash, so the raw id suffices. */
static uint64_t alpha_id_oa_hash(const void *key, void *ctx)
{
    (void)ctx;
    return (uint64_t)*(const uint32_t *)key;
}

static bool alpha_id_oa_eq(const void *a, const void *b, void *ctx)
{
    (void)ctx;
    return *(const uint32_t *)a == *(const uint32_t *)b;
}

ds_result_t ds_rete_alpha_node_create(uint16_t               schema_id,
                                       ds_rete_alpha_test_t  *tests,
                                       uint32_t               test_count,
                                       ds_rete_alpha_node_t **out)
{
    if (!out) return DS_ERR_R(DS_ERR_INVAL, "alpha_node_create: NULL out");

    ds_rete_alpha_node_t *n = DS_CALLOC(1, sizeof(*n));
    if (!n) return DS_ERR_R(DS_ERR_OOM, "alpha_node alloc");

    if (test_count > 0) {
        n->tests = DS_CALLOC(test_count, sizeof(ds_rete_alpha_test_t));
        if (!n->tests) { DS_FREE(n); return DS_ERR_R(DS_ERR_OOM, "alpha tests"); }
        memcpy(n->tests, tests, test_count * sizeof(*tests));
    }

    n->schema_id  = schema_id;
    n->test_count = test_count;

    ds_oa_init(&n->memory.map, sizeof(uint32_t), sizeof(ds_rete_fact_t *),
            ALPHA_MEM_MAX_LOAD, alpha_id_oa_hash, alpha_id_oa_eq, NULL, NULL);

    *out = n;
    return DS_OK_R;
}

ds_result_t ds_rete_alpha_add_beta_output(ds_rete_alpha_node_t    *alpha,
                                           struct ds_rete_beta_node *beta)
{
    if (!alpha || !beta)
        return DS_ERR_R(DS_ERR_INVAL, "alpha_add_beta_output: NULL");
#define BETA_OUT_INIT_CAP 4u
    struct ds_rete_beta_node **nb =
        DS_REALLOC(alpha->beta_outputs,
                (alpha->beta_output_count + 1) * sizeof(*nb));
    if (!nb) return DS_ERR_R(DS_ERR_OOM, "alpha beta_outputs grow");
    alpha->beta_outputs = nb;
    alpha->beta_outputs[alpha->beta_output_count++] = beta;
    return DS_OK_R;
}

void ds_rete_alpha_node_destroy(ds_rete_alpha_node_t *node)
{
    if (!node) return;
    if (node->tests)
        for (uint32_t i = 0; i < node->test_count; i++)
            ds_re2_free(node->tests[i].compiled_re);
    DS_FREE(node->tests);
    ds_oa_free(&node->memory.map);
    DS_FREE(node->beta_outputs);
    DS_FREE(node);
}

/* ---- Alpha test evaluation (IRET.6.4) ----------------------------- */

/* Int and Float compare across kinds through double, as eval.c's val_cmp does: an
 * alpha test is the same comparison hoisted. Other kind mismatches answer false. */
static bool cmp_vals(ds_rete_cmp_op_t op,
                     const ds_rete_val_t *a,
                     const ds_rete_val_t *b)
{
    /* Time compares on utc_ns ([LTIM.5.2]) and is interoperable with Int
       (a literal time bound in a rule arrives as an Int); the offset is
       irrelevant to ordering. Must precede the same-kind guard. */
    if (a->kind == DS_RETE_VAL_TIME || b->kind == DS_RETE_VAL_TIME) {
        if ((a->kind == DS_RETE_VAL_TIME || a->kind == DS_RETE_VAL_INT) &&
            (b->kind == DS_RETE_VAL_TIME || b->kind == DS_RETE_VAL_INT)) {
            int64_t av = (a->kind == DS_RETE_VAL_TIME) ? a->time.utc_ns : a->i;
            int64_t bv = (b->kind == DS_RETE_VAL_TIME) ? b->time.utc_ns : b->i;
            switch (op) {
            case DS_RETE_CMP_EQ:  return av == bv;
            case DS_RETE_CMP_NEQ: return av != bv;
            case DS_RETE_CMP_LT:  return av <  bv;
            case DS_RETE_CMP_GT:  return av >  bv;
            case DS_RETE_CMP_LTE: return av <= bv;
            case DS_RETE_CMP_GTE: return av >= bv;
            }
        }
        return false;
    }
    if (a->kind != b->kind) {
        if ((a->kind == DS_RETE_VAL_INT || a->kind == DS_RETE_VAL_FLOAT) &&
            (b->kind == DS_RETE_VAL_INT || b->kind == DS_RETE_VAL_FLOAT)) {
            double av = (a->kind == DS_RETE_VAL_INT) ? (double)a->i : a->f;
            double bv = (b->kind == DS_RETE_VAL_INT) ? (double)b->i : b->f;
            switch (op) {
            case DS_RETE_CMP_EQ:  return av == bv;
            case DS_RETE_CMP_NEQ: return av != bv;
            case DS_RETE_CMP_LT:  return av <  bv;
            case DS_RETE_CMP_GT:  return av >  bv;
            case DS_RETE_CMP_LTE: return av <= bv;
            case DS_RETE_CMP_GTE: return av >= bv;
            }
        }
        return false;
    }
    switch (a->kind) {
    case DS_RETE_VAL_INT: {
        int64_t av = a->i, bv = b->i;
        switch (op) {
        case DS_RETE_CMP_EQ:  return av == bv;
        case DS_RETE_CMP_NEQ: return av != bv;
        case DS_RETE_CMP_LT:  return av <  bv;
        case DS_RETE_CMP_GT:  return av >  bv;
        case DS_RETE_CMP_LTE: return av <= bv;
        case DS_RETE_CMP_GTE: return av >= bv;
        }
        break;
    }
    case DS_RETE_VAL_FLOAT: {
        double av = a->f, bv = b->f;
        switch (op) {
        case DS_RETE_CMP_EQ:  return av == bv;
        case DS_RETE_CMP_NEQ: return av != bv;
        case DS_RETE_CMP_LT:  return av <  bv;
        case DS_RETE_CMP_GT:  return av >  bv;
        case DS_RETE_CMP_LTE: return av <= bv;
        case DS_RETE_CMP_GTE: return av >= bv;
        }
        break;
    }
    case DS_RETE_VAL_STR:
        /* String comparisons: pointer equality for EQ/NEQ (interned),
         * lexicographic for ordering. */
        if (op == DS_RETE_CMP_EQ)  return a->s.ptr == b->s.ptr;
        if (op == DS_RETE_CMP_NEQ) return a->s.ptr != b->s.ptr;
        {
            int c = strncmp(a->s.ptr, b->s.ptr,
                            a->s.len < b->s.len ? a->s.len : b->s.len);
            if (c == 0) c = (int)a->s.len - (int)b->s.len;
            switch (op) {
            case DS_RETE_CMP_LT:  return c <  0;
            case DS_RETE_CMP_GT:  return c >  0;
            case DS_RETE_CMP_LTE: return c <= 0;
            case DS_RETE_CMP_GTE: return c >= 0;
            default: break;
            }
        }
        break;
    case DS_RETE_VAL_BOOL:
        if (op == DS_RETE_CMP_EQ)  return a->b == b->b;
        if (op == DS_RETE_CMP_NEQ) return a->b != b->b;
        return false; /* ordering on bool not meaningful */
    default:
        break;
    }
    return false;
}

bool ds_rete_alpha_test_fact(const ds_rete_alpha_node_t *node,
                              const ds_rete_fact_t       *fact,
                              struct ds_rete_eval_ctx    *ctx)
{
    /* The compiled path's ABI has no error channel. */
    if (node->alpha_fn != NULL)
        return node->alpha_fn(fact);

    /* [RDSC.4a.9.1], [IRET.6.4]: a lying test is one conjunct. A test that answers
       false decides the fact wherever it stands, so the fault is held until the
       rest have run: every runtime meets it at the same facts. */
    bool lied = false;
    for (uint32_t t = 0; t < node->test_count; t++) {
        const ds_rete_alpha_test_t *test = &node->tests[t];
        if (test->slot_index >= fact->schema->slot_count) {
            lied = true;
            continue;
        }

        const ds_rete_val_t *slot = &fact->slots[test->slot_index];

        switch (test->kind) {
        case DS_RETE_ALPHA_EQ:
            if (!cmp_vals(DS_RETE_CMP_EQ, slot, &test->literal))
                return false;
            break;
        case DS_RETE_ALPHA_CMP:
            if (!cmp_vals(test->op, slot, &test->literal))
                return false;
            break;
        case DS_RETE_ALPHA_REGEX:
            /* [RDSC.4a.6.2]: held like the slot-past-schema fault. A slot holds
             * exactly its declared kind ([RARC.5.2.6]), so the value's kind alone
             * decides; Bytes is not a String ([LREG.1.1]). */
            if (slot->kind != DS_RETE_VAL_STR ||
                slot->s.ptr == NULL ||
                test->compiled_re == NULL) {
                lied = true;
                continue;
            }
            {
                /* IALC.3.6: a false with oom set is a refusal, not "no match". */
                bool oom = false;
                if (!ds_re2_match_n((const ds_re2_t *)test->compiled_re,
                                    slot->s.ptr, slot->s.len, &oom) && !oom)
                    return false;
                if (oom) {
                    ds_rete_fault(ctx, NULL, DS_FAULT_RESOURCE);
                    return false;
                }
            }
            break;
        }
    }
    if (lied) {
        ds_rete_fault(ctx, NULL, DS_FAULT_ARTEFACT);
        return false;
    }
    return true;
}

/* ---- Alpha memory (IRET.6.5) -------------------------------------- */

ds_result_t ds_rete_alpha_mem_insert(ds_rete_alpha_mem_t *mem,
                                      ds_rete_fact_t      *fact)
{
    if (!mem || !fact) return DS_ERR_R(DS_ERR_INVAL, "alpha_mem_insert: NULL");

    void *vp;
    bool  is_new;
    ds_result_t r = ds_oa_put(&mem->map, &fact->id, &vp, &is_new);
    if (r.status != DS_OK) return r;
    if (!is_new)
        return DS_ERR_R(DS_ERR_STATE, "alpha_mem: fact already present");
    *(ds_rete_fact_t **)vp = fact;
    return DS_OK_R;
}

ds_result_t ds_rete_alpha_mem_remove(ds_rete_alpha_mem_t *mem,
                                      ds_rete_fact_t      *fact)
{
    if (!mem || !fact) return DS_ERR_R(DS_ERR_INVAL, "alpha_mem_remove: NULL");
    return ds_oa_del(&mem->map, &fact->id)
         ? DS_OK_R
         : DS_ERR_R(DS_ERR_NOT_FOUND, "alpha_mem_remove: fact not found");
}

bool ds_rete_alpha_mem_contains(const ds_rete_alpha_mem_t *mem,
                                 const ds_rete_fact_t      *fact)
{
    /* Before touching fact->id: a caller may probe with a fact already freed. */
    if (!mem || !fact || oa_len(&mem->map) == 0) return false;
    return ds_oa_get(&mem->map, &fact->id) != NULL;
}

ds_result_t ds_rete_alpha_mem_presz(ds_rete_alpha_mem_t *mem, size_t cap)
{
    if (!mem || cap == 0) return DS_ERR_R(DS_ERR_INVAL, "alpha_mem_presz");
    return ds_oa_reserve(&mem->map, (uint32_t)cap);
}

int ds_rete_alpha_mem_for_each(const ds_rete_alpha_mem_t *mem,
                                int (*visitor)(ds_rete_fact_t *fact,
                                               void           *ctx),
                                void *ctx)
{
    if (!mem || !visitor) return 0;
    /* The hot join scan ([IRET.28.0.1]): the dense vector, whose order feeds
       timetag assignment ([IRET.28.10]). */
    ds_rete_fact_t **dv = (ds_rete_fact_t **)mem->map.dvals;
    uint32_t n = mem->map.len;
    for (uint32_t i = 0; i < n; i++) {
        int r = visitor(dv[i], ctx);
        if (r) return r;
    }
    return 0;
}

/* ---- alpha node deep-copy ------------------------------------------- */

static void alpha_mem_val_remap(const void *sv, void *dv, void *ctx)
{
    ds_rete_clone_ctx_t *cx = (ds_rete_clone_ctx_t *) ctx;
    ds_rete_fact_t *sf = *(ds_rete_fact_t *const *) sv;
    *(ds_rete_fact_t **) dv = sf ? ds_rete_clone_fact_lookup(cx, sf->id) : NULL;
}

ds_result_t ds_rete_alpha_node_clone(ds_rete_clone_ctx_t        *cx,
                                     const ds_rete_alpha_node_t *src,
                                     ds_rete_alpha_node_t      **out)
{
    ds_rete_alpha_node_t *n = DS_CALLOC(1, sizeof(*n));
    if (!n) return DS_ERR_R(DS_ERR_OOM, "alpha_clone: node alloc");

    n->schema_id         = src->schema_id;
    n->test_count        = src->test_count;
    n->node_id           = src->node_id;
    memcpy(n->fault_rule, src->fault_rule, sizeof n->fault_rule);
    n->fault_handler     = src->fault_handler;
    n->alpha_fn          = src->alpha_fn;          /* AOT compiled test fn ptr */
    n->contract_capacity = src->contract_capacity;

    if (src->test_count > 0) {
        n->tests = DS_CALLOC(src->test_count, sizeof(*n->tests));
        if (!n->tests) { DS_FREE(n); return DS_ERR_R(DS_ERR_OOM, "alpha_clone: tests"); }
        for (uint32_t i = 0; i < src->test_count; i++) {
            n->tests[i]         = src->tests[i];   /* kind / slot_index / op */
            n->tests[i].literal = ds_rete_clone_val(cx, &src->tests[i].literal);
            /* Recompiled: the node destructor frees `compiled_re`. */
            n->tests[i].compiled_re = NULL;
            if (src->tests[i].kind == DS_RETE_ALPHA_REGEX &&
                src->tests[i].pattern != NULL) {
                n->tests[i].compiled_re =
                    ds_re2_compile(src->tests[i].pattern, 0, NULL, 0);
                if (n->tests[i].compiled_re == NULL) {
                    for (uint32_t j = 0; j < i; j++)
                        ds_re2_free(n->tests[j].compiled_re);
                    DS_FREE(n->tests);
                    DS_FREE(n);
                    return DS_ERR_R(DS_ERR_OOM, "alpha_clone: regex recompile");
                }
            }
        }
    }

    ds_oa_init(&n->memory.map, sizeof(uint32_t), sizeof(ds_rete_fact_t *),
            ALPHA_MEM_MAX_LOAD, alpha_id_oa_hash, alpha_id_oa_eq, NULL, NULL);
    ds_result_t r = ds_oa_clone_into(&n->memory.map, &src->memory.map,
                                  NULL, alpha_mem_val_remap, cx);
    if (r.status != DS_OK || cx->oom) {
        ds_rete_alpha_node_destroy(n);
        return r.status != DS_OK ? r : DS_ERR_R(DS_ERR_OOM, "alpha_clone: memory");
    }

    /* beta_outputs wired in the orchestration's node-map pass. */
    n->beta_outputs      = NULL;
    n->beta_output_count = 0;

    *out = n;
    return DS_OK_R;
}

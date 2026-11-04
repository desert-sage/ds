/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * A fact owns its own `Json` tree, and an assert that does not happen takes
 * nothing, so the caller frees what it handed over exactly once. Two paths
 * reach ds_rete_wm_assert_ex with a `Json` slot:
 *
 *   HOST.    ds_engine_assert; the bridge clones the caller's tree
 *            (wm_rete_bridge.c, slot_to_rete_val).
 *   EMIT.    A rule's `emit` of a slot it read from a matched fact, which
 *            must not leave two facts owning one tree.
 *
 * The ds_publish builtin reaches none: a `publish` asserts nothing
 * ([LTIE.4.3]), and its values are borrowed for the publish callback alone
 * (rete/adapters.c, ds_rete_publish_values).
 *
 * Each runs again as a no-op: a reassertion equal to a live fact
 * ([LFAC.2.5.1]) succeeds, keeps nothing, and still frees what it was handed.
 *
 * This binary supplies the strong ds_* set ([IALC.5]). While a case runs it
 * quarantines every block libds frees, so a double free is counted rather
 * than corrupting the heap, and it refuses the k-th allocation; each case is
 * swept over k until the operation runs with no refusal. After every case
 * nothing is freed twice and nothing is left live.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "engine.h"
#include "fn.h"
#include "rete/action.h"
#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/loader.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int g_fails;
#define CHECK(cond, ...)                                                      \
    do { if (!(cond)) {                                                       \
        fprintf(stderr, "FAIL [%s:%d] ", __func__, __LINE__);                 \
        fprintf(stderr, __VA_ARGS__);                                         \
        fputc('\n', stderr);                                                  \
        g_fails++;                                                            \
    } } while (0)

/* Every block allocated while a case runs, by address: live, or freed and
   held. Open addressing, never deleted from, cleared between cases. A case
   makes a few thousand allocations; the table has room for many more. */
enum { TAB = 1u << 18 };
enum { ST_EMPTY = 0, ST_LIVE = 1, ST_FREED = 2 };
typedef struct { void *p; size_t n; unsigned char st; } blk_t;
static blk_t g_tab[TAB];

static bool   g_track;         /* a case is running */
static long   g_arm_k;         /* refuse the k-th allocation; 0 = never */
static long   g_seen;          /* allocations since armed */
static int    g_refused;       /* refusals made */
static int    g_double;        /* blocks freed a second time */
static int    g_after_free;    /* reallocs of a freed block */

static blk_t *tab_find(void *p, bool insert)
{
    uintptr_t h = ((uintptr_t)p >> 4) * 0x9E3779B97F4A7C15ull;
    for (uint32_t i = 0; i < TAB; i++) {
        blk_t *b = &g_tab[(h + i) & (TAB - 1)];
        if (b->st == ST_EMPTY) return insert ? b : NULL;
        if (b->p == p) return b;
    }
    fprintf(stderr, "test_json_slot_ownership: tracking table full\n");
    abort();
}

static bool refuse_now(void)
{
    if (!g_track || g_arm_k == 0) return false;
    if (++g_seen != g_arm_k) return false;
    g_refused++;
    return true;
}

static void *track_alloc(size_t n, bool zero)
{
    if (refuse_now()) return NULL;
    void *p = zero ? calloc(1, n ? n : 1) : malloc(n ? n : 1);
    if (p != NULL && g_track) {
        blk_t *b = tab_find(p, true);
        /* An address libc hands out again was freed for real, so it was
           never in quarantine: it is a new block. */
        b->p = p; b->n = n; b->st = ST_LIVE;
    }
    return p;
}

void *ds_malloc(size_t n) { return track_alloc(n, false); }

void *ds_calloc(size_t n, size_t sz)
{
    if (sz != 0 && n > SIZE_MAX / sz) return NULL;
    return track_alloc(n * sz, true);
}

void ds_free(void *p)
{
    if (p == NULL) return;
    blk_t *b = g_track ? tab_find(p, false) : NULL;
    if (b == NULL) { free(p); return; }   /* allocated before the case */
    if (b->st == ST_FREED) { g_double++; return; }
    b->st = ST_FREED;                     /* held: the address is not reused */
}

void *ds_realloc(void *p, size_t n)
{
    if (p == NULL) return track_alloc(n, false);
    blk_t *b = g_track ? tab_find(p, false) : NULL;
    if (b == NULL) {
        if (refuse_now()) return NULL;
        void *q = realloc(p, n ? n : 1);
        if (q != NULL && g_track) {
            blk_t *nb = tab_find(q, true);
            nb->p = q; nb->n = n; nb->st = ST_LIVE;
        }
        return q;
    }
    if (b->st == ST_FREED) { g_after_free++; return NULL; }
    void *q = track_alloc(n, false);
    if (q == NULL) return NULL;           /* p is untouched, as realloc's is */
    memcpy(q, p, b->n < n ? b->n : n);
    b = tab_find(p, false);
    b->st = ST_FREED;
    return q;
}

char *ds_strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = track_alloc(n, false);
    if (p) memcpy(p, s, n);
    return p;
}

char *ds_strndup(const char *s, size_t n)
{
    size_t len = 0;
    while (len < n && s[len] != '\0') len++;
    char *p = track_alloc(len + 1, false);
    if (p) { memcpy(p, s, len); p[len] = '\0'; }
    return p;
}

static void case_begin(void)
{
    memset(g_tab, 0, sizeof g_tab);
    g_arm_k = 0; g_seen = 0; g_refused = 0; g_double = 0; g_after_free = 0;
    g_track = true;
}

static void arm(long k)  { g_arm_k = k; g_seen = 0; }
static void disarm(void) { g_arm_k = 0; }

/* Ends the case: counts what is still live, then returns the held blocks to
   libc. A block still live is left alone -- if it is a leak it stays one,
   and if it is something libds keeps it must not be pulled from under it. */
static int case_end(void)
{
    g_track = false;
    int live = 0;
    for (uint32_t i = 0; i < TAB; i++) {
        if (g_tab[i].st == ST_LIVE) live++;
        else if (g_tab[i].st == ST_FREED) free(g_tab[i].p);
    }
    memset(g_tab, 0, sizeof g_tab);
    return live;
}

static ds_json_t *doc(void)
{
    static const char text[] = "{\"a\":[1,2,3],\"b\":\"text\",\"c\":{\"d\":true}}";
    ds_json_t *j = NULL;
    if (ds_json_parse(text, sizeof text - 1, &j).status != DS_OK) return NULL;
    return j;
}

static const ds_slot_desc_t KJ_SLOTS[2] = {
    { .name = "k", .type = DS_SLOT_TYPE_INT,  .identity_role = DS_IDENTITY_KEY },
    { .name = "j", .type = DS_SLOT_TYPE_JSON, .identity_role = DS_IDENTITY_MUTABLE },
};

static ds_rete_expr_t *var_ref(uint16_t pat, uint16_t slot)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    e->var.pattern_index = pat;
    e->var.slot_index = slot;
    return e;
}

static ds_rete_expr_t *lit_int(int64_t v)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = v;
    return e;
}

/* Each path's no-op variant runs while this is set. */
static bool g_noop;

/* `Src s -> emit Out k: s.k, j: s.j` when `emit` is set -- `k: 1` in the
   no-op variant, so two Src facts emit one Out twice; otherwise one rule over
   Src with no actions, so an assert into Src reaches an alpha memory and a
   beta. Node ids: alpha 1, beta 2, terminal 3. */
static int load_net(ds_engine_t *e, bool emit, uint16_t out_id)
{
    /* The expression trees are the engine's once loaded. */
    ds_rete_slot_assign_t as[2] = { { .slot_index = 0 }, { .slot_index = 1 } };
    if (emit) {
        as[0].expr = g_noop ? lit_int(1) : var_ref(0, 0);
        as[1].expr = var_ref(0, 1);
    }
    ds_rete_action_t act = { .kind = DS_RETE_ACTION_ASSERT,
                             .schema_id = out_id,
                             .assigns = as, .assign_count = 2 };
    ds_alfa_atom_t alfas[1] = {{ .node_id = 1, .schema_name = "Src" }};
    ds_beta_atom_t betas[1] = {{ .node_id = 2, .right_alpha_id = 1,
                                 .left_parent_id = 0 }};
    ds_term_atom_t terms[1] = {{ .node_id = 3, .parent_beta_id = 2,
                                 .rule_name = "r",
                                 .actions = emit ? &act : NULL,
                                 .action_count = emit ? 1u : 0u }};
    ds_rete_network_t net = { .alfas = alfas, .alfa_count = 1,
                              .betas = betas, .beta_count = 1,
                              .terms = terms, .term_count = 1 };
    return ds_rete_load_network(e->rete_engine, &net).status != DS_OK;
}

typedef struct {
    ds_result_t r;          /* the operation under test */
    bool        ran;        /* setup succeeded */
    bool        aliased;    /* EMIT only: Out and Src hold one tree */
    bool        out_live;   /* EMIT only: an Out fact is in working memory */
    bool        noop;       /* no-op variant: the reassertion was a no-op */
} outcome_t;

/* The live facts of one Rete schema. */
static int count_of(ds_rete_engine_t *re, const ds_rete_schema_t *rs)
{
    int n = 0;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (f != NULL && f->schema == rs) n++;
    }
    return n;
}

/* One host assert of Src(1, doc) into an engine with a rule over Src. The
   refusal is armed around the assert alone. In the no-op variant Src(1, doc)
   is asserted first, unarmed, and the assert under test is Src(1, doc) again
   from a tree of its own. */
static outcome_t run_host(long k)
{
    outcome_t o = { .r = DS_OK_R };
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *src = NULL;
    ds_json_t *j = NULL, *j2 = NULL;
    ds_fact_t *first = NULL, *second = NULL;
    ds_slot_value_t sv[2] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                              { .kind = DS_SLOT_JSON } };
    if (ds_engine_new(&cfg, &e).status != DS_OK) return o;
    if (ds_engine_register_schema(e, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  KJ_SLOTS, 2, &src).status != DS_OK
        || load_net(e, false, 0) || (j = doc()) == NULL
        || (j2 = doc()) == NULL)
        goto done;
    if (g_noop) {
        sv[1].v.json = j2;
        if (ds_engine_assert(e, src, sv, 2, &first).status != DS_OK) goto done;
    }
    sv[1].v.json = j;
    o.ran = true;
    arm(k);
    o.r = ds_engine_assert(e, src, sv, 2, &second);
    disarm();
    o.noop = g_noop && o.r.status == DS_OK && first != NULL && second == first;
done:
    ds_json_free(j);            /* the caller's trees: ours to free either way */
    ds_json_free(j2);
    ds_engine_free(e);
    return o;
}

/* Src(1, doc) asserted, then one pump firing `emit Out k: s.k, j: s.j`. The
   refusal is armed around the pump alone. */
static outcome_t run_emit(long k)
{
    outcome_t o = { .r = DS_OK_R };
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    const ds_schema_t *src = NULL, *out = NULL;
    const ds_rete_schema_t *rs_src = NULL, *rs_out = NULL;
    const ds_json_t *src_tree = NULL, *out_tree = NULL;
    ds_json_t *j = NULL;
    ds_slot_value_t sv[2] = { { .kind = DS_SLOT_INT, .v.i = 1 },
                              { .kind = DS_SLOT_JSON } };
    if (ds_engine_new(&cfg, &e).status != DS_OK) return o;
    if (ds_engine_register_schema(e, "Src", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                  KJ_SLOTS, 2, &src).status != DS_OK
        || ds_engine_register_schema(e, "Out", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                     KJ_SLOTS, 2, &out).status != DS_OK)
        goto done;
    rs_src = ds_rete_schema_by_name(e->rete_engine, "Src");
    rs_out = ds_rete_schema_by_name(e->rete_engine, "Out");
    if (rs_src == NULL || rs_out == NULL || load_net(e, true, rs_out->id)
        || (j = doc()) == NULL)
        goto done;
    sv[1].v.json = j;
    if (ds_engine_assert(e, src, sv, 2, NULL).status != DS_OK) goto done;
    if (g_noop) {
        /* A second Src with the same body: its firing emits Out(1, doc)
           again, equal to the live one, which is the no-op under test. */
        sv[0].v.i = 2;
        if (ds_engine_assert(e, src, sv, 2, NULL).status != DS_OK) goto done;
    }
    o.ran = true;
    arm(k);
    o.r = ds_engine_pump(e);
    disarm();

    ds_rete_engine_t *re = e->rete_engine;
    o.noop = g_noop && count_of(re, rs_src) == 2 && count_of(re, rs_out) == 1;
    for (uint32_t i = 0; i < oa_len(&re->wm_map); i++) {
        ds_rete_fact_t *f = *(ds_rete_fact_t **)ds_oa_val_at(&re->wm_map, i);
        if (f == NULL || f->slots[1].kind != DS_RETE_VAL_JSON) continue;
        if (f->schema == rs_src) src_tree = f->slots[1].json;
        if (f->schema == rs_out) { out_tree = f->slots[1].json; o.out_live = true; }
    }
    o.aliased = src_tree != NULL && src_tree == out_tree;
done:
    ds_json_free(j);
    ds_engine_free(e);
    return o;
}

typedef outcome_t (*path_fn)(long k);

/* Runs `path` once to warm up, so whatever libds sets up once per process is
   set up before every case -- quarantined like a case, because a defect this
   file looks for is a real double free that would abort the run, and what it
   leaves live is left alone. Then once with no refusal, then once per
   allocation the operation makes. Every case: nothing freed twice, nothing
   reallocated after its free, nothing left live. */
static void sweep(const char *label, path_fn path)
{
    case_begin();
    (void)path(0);
    (void)case_end();

    case_begin();
    outcome_t base = path(0);
    int live = case_end();
    CHECK(base.ran, "%s: premise: the case sets up", label);
    CHECK(base.r.status == DS_OK, "%s: premise: with no refusal it succeeds "
          "(status %d)", label, base.r.status);
    CHECK(g_double == 0, "%s: with no refusal, %d block(s) freed twice",
          label, g_double);
    CHECK(live == 0, "%s: with no refusal, %d block(s) left live", label, live);
    if (g_noop)
        CHECK(base.noop, "%s: premise: the reassertion is a no-op", label);
    if (path == run_emit) {
        CHECK(base.out_live, "EMIT: premise: the rule's Out fact is live");
        CHECK(!base.aliased,
              "EMIT: Out holds the very tree Src holds -- two facts own one tree");
    }

    long k = 1, failed = 0;
    for (; k < 20000; k++) {
        case_begin();
        outcome_t o = path(k);
        int refused = g_refused;
        live = case_end();
        if (refused == 0) break;      /* the operation made fewer than k */
        if (o.r.status != DS_OK) failed++;
        CHECK(g_double == 0, "%s: refusing allocation %ld (status %d): %d "
              "block(s) freed twice", label, k, o.r.status, g_double);
        CHECK(g_after_free == 0, "%s: refusing allocation %ld: %d realloc(s) "
              "of a freed block", label, k, g_after_free);
        CHECK(live == 0, "%s: refusing allocation %ld (status %d): %d block(s) "
              "left live", label, k, o.r.status, live);
    }
    printf("  %s: %ld allocation(s) refused in turn, %ld of them failing the "
           "operation\n", label, k - 1, failed);
    CHECK(k > 1, "%s: premise: the operation allocates", label);
}

int main(void)
{
    printf("=== test_json_slot_ownership ===\n");
    sweep("HOST", run_host);
    sweep("EMIT", run_emit);
    g_noop = true;
    sweep("HOST no-op", run_host);
    sweep("EMIT no-op", run_emit);
    if (g_fails) {
        fprintf(stderr, "test_json_slot_ownership: %d failure(s)\n", g_fails);
        return 1;
    }
    printf("test_json_slot_ownership: OK\n");
    return 0;
}

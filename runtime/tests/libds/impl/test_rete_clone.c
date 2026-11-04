/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The leaf helpers of rete/clone.c that the graph clone is built from:
 * expression trees (re-interned, with intern dedup), actions, tokens (facts
 * remapped through id2fact) and alpha nodes. The graph clone is
 * test_engine_clone.c, and [LDET.2.2b]'s diverge-compare check is the
 * `runtime/LDET.2.2b*` vectors.
 */
#include <stdio.h>
#include <string.h>

#include "ds_alloc.h"
#include "rete/action.h"
#include "rete/alpha.h"
#include "rete/clone.h"
#include "rete/expr.h"
#include "builtin_fn.h"
#include "rete/fact.h"
#include "rete/intern.h"
#include "rete/token.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL [%s]: %s (%s:%d)\n",                           \
                __func__, (msg), __FILE__, __LINE__);                        \
        g_fails++;                                                           \
    } } while (0)

static ds_rete_expr_t *e_lit_str(const char *s)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR); e->lit_str = s; return e; }
static ds_rete_expr_t *e_lit_int(int64_t v)
{ ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT); e->lit_int = v; return e; }

static int test_expr_clone(void)
{
    g_fails = 0;
    ds_rete_intern_t *dst = NULL;
    CHECK(ds_rete_intern_init(&dst).status == DS_OK, "intern init");
    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst);

    /* INTERP[ text "a", value{d,+,width 3} CALL fn(LIT_STR "a", LIT_INT 5),
       time{ text "a", %Y } ] -- exercises a text primitive, a spec
       copied by value, a nested value tree, a time pattern, and the intern
       DEDUP ("a" appears three times). */
    ds_rete_expr_t *call = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    call->call.op = DS_FN_GREAT_CIRCLE;   /* any op — clone copies the scalar */
    call->call.arg_count = 2;
    call->call.args = DS_CALLOC(2, sizeof(*call->call.args));
    call->call.args[0] = e_lit_str("a");
    call->call.args[1] = e_lit_int(5);

    ds_rete_expr_t *in = ds_rete_expr_alloc(DS_RETE_EXPR_INTERP);
    in->interp.prim_count = 3;
    in->interp.prims = DS_CALLOC(3, sizeof(*in->interp.prims));
    in->interp.prims[0].kind = DS_RETE_FPRIM_TEXT;
    in->interp.prims[0].text = "a";
    in->interp.prims[0].text_len = 1;
    in->interp.prims[1].kind  = DS_RETE_FPRIM_VALUE;
    in->interp.prims[1].value = call;
    in->interp.prims[1].type  = DS_RETE_FTYPE_D;
    in->interp.prims[1].plus  = true;
    in->interp.prims[1].width = 3;
    in->interp.prims[2].kind  = DS_RETE_FPRIM_TIME;
    in->interp.prims[2].value = e_lit_int(0);
    in->interp.prims[2].item_count = 2;
    in->interp.prims[2].items = DS_CALLOC(2, sizeof(ds_rete_titem_t));
    in->interp.prims[2].items[0].text = "a";
    in->interp.prims[2].items[0].text_len = 1;
    in->interp.prims[2].items[1].field = DS_RETE_TFIELD_YEAR;

    ds_rete_expr_t *cl = ds_rete_clone_expr(&cx, in);
    CHECK(!cx.oom, "no oom");
    CHECK(cl != NULL && cl != in, "root is an independent copy");
    CHECK(cl->kind == DS_RETE_EXPR_INTERP && cl->interp.prim_count == 3, "root kind/count");
    CHECK(cl->interp.prims != in->interp.prims, "prims array is a copy");

    const ds_rete_fprim_t *p0 = &cl->interp.prims[0];
    CHECK(p0->kind == DS_RETE_FPRIM_TEXT && p0->text_len == 1
          && strcmp(p0->text, "a") == 0, "text content");
    CHECK(p0->text != in->interp.prims[0].text, "text re-interned (new ptr)");

    const ds_rete_fprim_t *p1 = &cl->interp.prims[1];
    CHECK(p1->type == DS_RETE_FTYPE_D && p1->plus && p1->width == 3, "spec copied");
    ds_rete_expr_t *clcall = p1->value;
    CHECK(clcall != NULL && clcall != call, "call is a copy");
    CHECK(clcall->kind == DS_RETE_EXPR_CALL && clcall->call.op == DS_FN_GREAT_CIRCLE, "call op");
    CHECK(clcall->call.arg_count == 2, "call arg_count");
    CHECK(clcall->call.args[0]->kind == DS_RETE_EXPR_LIT_STR, "call arg0 kind");
    CHECK(clcall->call.args[1]->lit_int == 5, "call arg1 int");

    const ds_rete_fprim_t *p2 = &cl->interp.prims[2];
    CHECK(p2->item_count == 2 && p2->items != in->interp.prims[2].items, "items copied");
    CHECK(p2->items[1].text == NULL && p2->items[1].field == DS_RETE_TFIELD_YEAR, "field copied");
    /* intern dedup: the three "a"s must resolve to ONE clone pointer. */
    CHECK(p0->text == clcall->call.args[0]->lit_str
          && p0->text == p2->items[0].text, "intern dedup shares one ptr");

    ds_rete_expr_free_tree(cl);
    ds_rete_expr_free_tree(in);      /* src nodes; C-literal strings untouched */
    ds_rete_clone_ctx_dispose(&cx);
    ds_rete_intern_destroy(dst);
    return g_fails;
}

/* A clone keeps what each node says, not only what its kind's arm copies:
   ENTRY_STAMP's pattern index ([LTIM.2.8.6]) at a nonzero position and at the
   right-fact sentinel `within` reads, and `json_tainted`, which sits outside
   the union and so on every kind. The node allocator zeroes both, so each
   value below is one the allocator cannot give. */
static int test_expr_clone_keeps_entry_stamp_and_taint(void)
{
    g_fails = 0;
    ds_rete_intern_t *dst = NULL;
    CHECK(ds_rete_intern_init(&dst).status == DS_OK, "intern init");
    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst);

    /* SUB(ENTRY_STAMP(3), ENTRY_STAMP(right fact)), the SUB tainted. */
    ds_rete_expr_t *at3 = ds_rete_expr_alloc(DS_RETE_EXPR_ENTRY_STAMP);
    at3->entry_stamp.pattern_index = 3;
    ds_rete_expr_t *atr = ds_rete_expr_alloc(DS_RETE_EXPR_ENTRY_STAMP);
    atr->entry_stamp.pattern_index = DS_RETE_VAR_RIGHT_FACT;
    ds_rete_expr_t *sub = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    sub->binop.op = DS_RETE_BINOP_SUB;
    sub->binop.left = at3;
    sub->binop.right = atr;
    sub->json_tainted = true;

    ds_rete_expr_t *cl = ds_rete_clone_expr(&cx, sub);
    CHECK(!cx.oom, "no oom");
    CHECK(cl != NULL && cl != sub, "root is an independent copy");
    CHECK(cl->json_tainted, "json_tainted copied on the root");
    CHECK(cl->binop.left != NULL && cl->binop.left != at3, "left is a copy");
    CHECK(cl->binop.left->kind == DS_RETE_EXPR_ENTRY_STAMP, "left kind");
    CHECK(cl->binop.left->entry_stamp.pattern_index == 3,
          "entry_stamp pattern index copied");
    CHECK(!cl->binop.left->json_tainted, "an untainted child stays untainted");
    CHECK(cl->binop.right != NULL
          && cl->binop.right->entry_stamp.pattern_index == DS_RETE_VAR_RIGHT_FACT,
          "entry_stamp right-fact sentinel copied");

    ds_rete_expr_free_tree(cl);
    ds_rete_expr_free_tree(sub);
    ds_rete_clone_ctx_dispose(&cx);
    ds_rete_intern_destroy(dst);
    return g_fails;
}

static int test_action_clone(void)
{
    g_fails = 0;
    ds_rete_intern_t *dst = NULL;
    CHECK(ds_rete_intern_init(&dst).status == DS_OK, "intern init");
    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst);

    ds_rete_action_t src;
    memset(&src, 0, sizeof(src));
    src.kind = DS_RETE_ACTION_ASSERT;
    src.schema_id = 3;
    src.assign_count = 2;
    src.assigns = DS_CALLOC(2, sizeof(*src.assigns));
    src.assigns[0].slot_index = 0; src.assigns[0].expr = e_lit_str("x");
    src.assigns[1].slot_index = 1; src.assigns[1].expr = e_lit_int(7);
    src.ttl_override = e_lit_int(1000);

    ds_rete_action_t dact;
    memset(&dact, 0, sizeof(dact));
    ds_result_t r = ds_rete_clone_action(&cx, &src, &dact);
    CHECK(r.status == DS_OK && !cx.oom, "action clone ok");
    CHECK(dact.kind == DS_RETE_ACTION_ASSERT && dact.schema_id == 3, "kind + schema_id");
    CHECK(dact.assign_count == 2 && dact.assigns != NULL, "assign count");
    CHECK(dact.assigns != src.assigns, "assigns array copied");
    CHECK(dact.assigns[0].slot_index == 0 &&
          strcmp(dact.assigns[0].expr->lit_str, "x") == 0, "assign0 value");
    CHECK(dact.assigns[1].expr->lit_int == 7, "assign1 value");
    CHECK(dact.ttl_override != NULL && dact.ttl_override->lit_int == 1000, "ttl override copied");

    ds_rete_action_free(&dact);
    ds_rete_action_free(&src);
    ds_rete_clone_ctx_dispose(&cx);
    ds_rete_intern_destroy(dst);
    return g_fails;
}

/* token clone + the id2fact remap: hand-populate cx->id2fact with two
   old-id -> new-fact mappings, build a src token over the OLD facts, and check
   the clone's facts[] point at the NEW facts (with timetag/hash preserved). */
static int test_token_clone(void)
{
    g_fails = 0;
    ds_rete_intern_t *dst = NULL;
    CHECK(ds_rete_intern_init(&dst).status == DS_OK, "intern init");
    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst);

    /* Fake facts: only ->id matters for the remap. */
    ds_rete_fact_t *old_a = DS_CALLOC(1, sizeof(ds_rete_fact_t)); old_a->id = 10;
    ds_rete_fact_t *old_b = DS_CALLOC(1, sizeof(ds_rete_fact_t)); old_b->id = 20;
    ds_rete_fact_t *new_a = DS_CALLOC(1, sizeof(ds_rete_fact_t)); new_a->id = 10;
    ds_rete_fact_t *new_b = DS_CALLOC(1, sizeof(ds_rete_fact_t)); new_b->id = 20;

    /* id2fact: 10 -> new_a, 20 -> new_b. */
    void *vp;
    uint32_t k10 = 10, k20 = 20;
    ds_oa_put(&cx.id2fact, &k10, &vp, NULL); *(ds_rete_fact_t **)vp = new_a;
    ds_oa_put(&cx.id2fact, &k20, &vp, NULL); *(ds_rete_fact_t **)vp = new_b;

    ds_rete_token_t src;
    memset(&src, 0, sizeof(src));
    ds_rete_fact_t *sfacts[2] = { old_a, old_b };
    src.fact_count = 2;
    src.facts = sfacts;
    src.creation_timetag = 4242;
    src.hash = 0xABCD;

    ds_rete_token_t *cl = ds_rete_token_clone(&cx, &src);
    CHECK(cl != NULL && !cx.oom, "token clone ok");
    CHECK(cl->fact_count == 2, "fact_count copied");
    CHECK(cl->creation_timetag == 4242, "timetag verbatim");
    CHECK(cl->hash == 0xABCD, "hash verbatim");
    CHECK(cl->facts != sfacts, "facts[] is a fresh array");
    CHECK(cl->facts[0] == new_a, "facts[0] remapped to clone fact");
    CHECK(cl->facts[1] == new_b, "facts[1] remapped to clone fact");
    CHECK(cl->tok_pool == NULL && cl->next == NULL && cl->prev == NULL, "unlinked non-pool token");

    ds_rete_token_free(cl);
    DS_FREE(old_a); DS_FREE(old_b); DS_FREE(new_a); DS_FREE(new_b);
    ds_rete_clone_ctx_dispose(&cx);
    ds_rete_intern_destroy(dst);
    return g_fails;
}

/* alpha node clone: an EQ test with an interned string literal + one fact in
   the alpha memory. Verifies the literal is re-interned (new ptr) and the
   memory entry is remapped to the clone fact via id2fact. */
static int test_alpha_clone(void)
{
    g_fails = 0;
    ds_rete_intern_t *dst = NULL;
    CHECK(ds_rete_intern_init(&dst).status == DS_OK, "intern init");
    ds_rete_clone_ctx_t cx;
    ds_rete_clone_ctx_init(&cx, dst);

    ds_rete_fact_t *old_f = DS_CALLOC(1, sizeof(ds_rete_fact_t)); old_f->id = 5;
    ds_rete_fact_t *new_f = DS_CALLOC(1, sizeof(ds_rete_fact_t)); new_f->id = 5;
    void *vp; uint32_t k5 = 5;
    ds_oa_put(&cx.id2fact, &k5, &vp, NULL); *(ds_rete_fact_t **)vp = new_f;

    ds_rete_alpha_test_t test;
    memset(&test, 0, sizeof(test));
    test.kind = DS_RETE_ALPHA_EQ;
    test.slot_index = 0;
    test.op = DS_RETE_CMP_EQ;
    test.literal = ds_rete_val_str("hi", 2);

    ds_rete_alpha_node_t *src = NULL;
    CHECK(ds_rete_alpha_node_create(7, &test, 1, &src).status == DS_OK, "src node");
    src->node_id = 42;
    CHECK(ds_rete_alpha_mem_insert(&src->memory, old_f).status == DS_OK, "mem insert");

    ds_rete_alpha_node_t *cl = NULL;
    CHECK(ds_rete_alpha_node_clone(&cx, src, &cl).status == DS_OK && !cx.oom, "alpha clone ok");
    CHECK(cl != NULL && cl != src, "independent node");
    CHECK(cl->schema_id == 7 && cl->node_id == 42 && cl->test_count == 1, "scalars copied");
    CHECK(cl->tests[0].kind == DS_RETE_ALPHA_EQ, "test kind");
    CHECK(cl->tests[0].literal.kind == DS_RETE_VAL_STR &&
          strncmp(cl->tests[0].literal.s.ptr, "hi", 2) == 0, "literal content");
    CHECK(cl->tests[0].literal.s.ptr != src->tests[0].literal.s.ptr, "literal re-interned");
    /* memory: key 5 present and its value is the remapped clone fact. */
    ds_rete_fact_t **mv = (ds_rete_fact_t **) ds_oa_get(&cl->memory.map, &k5);
    CHECK(mv != NULL && *mv == new_f, "alpha memory entry remapped to clone fact");
    CHECK(cl->beta_outputs == NULL && cl->beta_output_count == 0, "outputs deferred to wiring");

    ds_rete_alpha_node_destroy(cl);
    ds_rete_alpha_node_destroy(src);
    DS_FREE(old_f); DS_FREE(new_f);
    ds_rete_clone_ctx_dispose(&cx);
    ds_rete_intern_destroy(dst);
    return g_fails;
}

int main(void)
{
    int fails = 0;
    struct { const char *name; int (*fn)(void); } cases[] = {
        { "expr_clone",   test_expr_clone },
        { "expr_clone_stamp_taint", test_expr_clone_keeps_entry_stamp_and_taint },
        { "action_clone", test_action_clone },
        { "token_clone",  test_token_clone },
        { "alpha_clone",  test_alpha_clone },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        int f = cases[i].fn();
        printf("  %-22s %s\n", cases[i].name, f ? "FAIL" : "ok");
        fails += f;
    }
    if (fails) { printf("test_rete_clone: %d FAILURES\n", fails); return 1; }
    printf("test_rete_clone: ALL PASSED\n");
    return 0;
}

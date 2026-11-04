/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * Terminal nodes, agenda ordering, refraction, and ds_rete_run (IRET.8,
 * IRET.11, IRET.22.4–22.6).
 *
 * Covers:
 *   - Terminal left_activate / left_retract
 *   - Agenda insertion and priority ordering (terminal ordinal + timetag),
 *     never a token hash (IRET.11.2)
 *   - ds_rete_run: firing, fire_fn callback, fire hooks
 *   - Refraction: same token does not fire twice in one cycle
 *   - Retraction before fire: activation removed from agenda
 *   - max_fires budget (DS_ERR_BUDGET_EXCEEDED)
 *   - End-to-end: assert → alpha → beta → terminal → run → fire
 *   - Refraction's identity is the whole tuple, never the hash alone
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libds.h"
#include "ds_alloc.h"
#include "rete/agenda.h"
#include "rete/alpha.h"
#include "rete/beta.h"
#include "rete/dispatch.h"
#include "rete/engine.h"
#include "rete/expr.h"
#include "rete/fact.h"
#include "rete/schema.h"
#include "rete/schema_reg.h"
#include "rete/terminal.h"
#include "rete/token.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

static int expect_ok(const char *what, ds_result_t r)
{
    if (r.status != DS_OK) {
        fprintf(stderr, "FAIL: %s: status=%d (%s)\n",
                what, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

static int expect_status(const char *what, ds_result_t r, int want)
{
    if (r.status != want) {
        fprintf(stderr, "FAIL: %s: want %d, got %d (%s)\n",
                what, want, r.status, r.detail ? r.detail : "(null)");
        return 1;
    }
    return 0;
}

/* A strong ds_* set, overriding libds's weak defaults for this binary
   ([IALC.5]), as test_fault_emission's does: libc, except that ds_malloc
   refuses the next g_refuse_mallocs requests and ds_calloc the next
   g_refuse_callocs. Disarmed (0) it is libc exactly, so every other case in
   this file runs on the default allocator. */
static int g_refuse_mallocs;
static int g_refused_mallocs;
static int g_refuse_callocs;
static int g_refused_callocs;

void *ds_malloc(size_t n)
{
    if (g_refuse_mallocs > 0) {
        g_refuse_mallocs--;
        g_refused_mallocs++;
        return NULL;
    }
    return malloc(n);
}
void  ds_free(void *p)                      { free(p); }
void *ds_calloc(size_t n, size_t sz)
{
    if (g_refuse_callocs > 0) {
        g_refuse_callocs--;
        g_refused_callocs++;
        return NULL;
    }
    return calloc(n, sz);
}
void *ds_realloc(void *p, size_t n)         { return realloc(p, n); }
char *ds_strdup(const char *s)              { return strdup(s); }
char *ds_strndup(const char *s, size_t n)   { return strndup(s, n); }

#define MAX_FIRED 32
typedef struct {
    const char *rule_name;
    uint32_t    fact0_id;   /* first fact in token */
    uint32_t    fcount;     /* token->fact_count at fire time */
    int         count;
} FiredEntry;

typedef struct {
    FiredEntry entries[MAX_FIRED];
    int        n;
} FiredLog;

static void record_fire(const char *rule_name, ds_rete_token_t *token,
                        void *ctx)
{
    FiredLog *log = (FiredLog *)ctx;
    if (log->n >= MAX_FIRED) return;
    log->entries[log->n].rule_name  = rule_name;
    log->entries[log->n].fact0_id   = token->fact_count > 0
                                       ? token->facts[0]->id : 0;
    log->entries[log->n].fcount     = token->fact_count;
    log->entries[log->n].count      = 0;
    log->n++;
}

typedef struct {
    ds_rete_engine_t    *engine;
    ds_rete_schema_t    *schema;
    ds_rete_alpha_node_t *alpha_all;
} Ctx;

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p;
    ds_rete_intern_cstr(e->intern, s, &p);
    return p;
}

static Ctx make_ctx(void)
{
    Ctx c = {0};
    ds_rete_engine_create(&c.engine);
    ds_rete_slot_desc_t slot = { .name = "val", .type = DS_RETE_VAL_INT };
    ds_rete_schema_register(c.engine, "Ev", DS_RETE_SCOPE_PLAIN, 0,
                             &slot, 1, &c.schema);
    ds_rete_alpha_node_create(0, NULL, 0, &c.alpha_all);
    ds_rete_dispatch_add(c.engine, 0, c.alpha_all);
    return c;
}

static void destroy_ctx(Ctx *c)
{
    ds_rete_alpha_node_destroy(c->alpha_all);
    ds_rete_engine_destroy(c->engine);
}

static ds_rete_fact_t *assert_val(Ctx *c, int64_t val)
{
    ds_rete_val_t v = ds_rete_val_int(val);
    ds_rete_fact_t *f = NULL;
    ds_rete_wm_assert(c->engine, 0, &v, &f);
    return f;
}

static int test_agenda_insert_pop_order(void)
{
    /* [LDET.5.1]: the outer key is the terminal ordinal (source order), the
       inner key is the creation timetag, and the inner one decides only
       between activations of the same rule. `first` gets the later timetag,
       so the test passes only if the ordinal outranks the timetag. */
    ds_rete_terminal_t *first = NULL, *second = NULL;
    ds_rete_terminal_create("first_rule",  0, &first);
    ds_rete_terminal_create("second_rule", 1, &second);

    ds_rete_agenda_t ag;
    ds_rete_agenda_init(&ag);

    /* Dummy activations — tokens not needed for heap ordering test. */
    ds_rete_activation_t a1 = { .terminal = second, .creation_timetag = 1 };
    ds_rete_activation_t a2 = { .terminal = first,  .creation_timetag = 2 };
    ds_rete_activation_t a3 = { .terminal = second, .creation_timetag = 3 };

    ds_rete_agenda_insert(&ag, &a1);
    ds_rete_agenda_insert(&ag, &a2);
    ds_rete_agenda_insert(&ag, &a3);

    ds_rete_activation_t *p1 = ds_rete_agenda_pop(&ag);
    ds_rete_activation_t *p2 = ds_rete_agenda_pop(&ag);
    ds_rete_activation_t *p3 = ds_rete_agenda_pop(&ag);
    ds_rete_activation_t *p4 = ds_rete_agenda_pop(&ag);

    /* Validate before cleanup (terminal ptrs must be live for the ordinal
       check). */
    int rc = 0;
    if (!p1 || !p2 || !p3)
        rc = fail("agenda: pop returned NULL early");
    else if (p4)
        rc = fail("agenda: pop should return NULL when empty");
    else if (p1->terminal->ordinal != 0)
        rc = fail("agenda: first pop should be the lower ordinal");
    else if (p1->creation_timetag != 2)
        rc = fail("agenda: ordinal must outrank the timetag");
    else if (p2->terminal->ordinal != 1)
        rc = fail("agenda: second pop ordinal wrong");
    else if (p2->creation_timetag != 1)
        rc = fail("agenda: same-rule ties break on the earlier timetag");
    else if (p3->creation_timetag != 3)
        rc = fail("agenda: third pop timetag wrong");

    ds_rete_agenda_destroy(&ag);
    ds_rete_terminal_destroy(first);
    ds_rete_terminal_destroy(second);
    return rc;
}

static int test_agenda_remove(void)
{
    ds_rete_terminal_t *t = NULL;
    ds_rete_terminal_create("r", 0, &t);
    ds_rete_agenda_t ag;
    ds_rete_agenda_init(&ag);

    ds_rete_activation_t a1 = { .terminal = t, .creation_timetag = 1 };
    ds_rete_activation_t a2 = { .terminal = t, .creation_timetag = 2 };
    ds_rete_activation_t a3 = { .terminal = t, .creation_timetag = 3 };

    ds_rete_agenda_insert(&ag, &a1);
    ds_rete_agenda_insert(&ag, &a2);
    ds_rete_agenda_insert(&ag, &a3);

    /* Remove the middle one; remaining should pop in order 1, 3. */
    ds_rete_agenda_remove(&ag, &a2);

    ds_rete_activation_t *p1 = ds_rete_agenda_pop(&ag);
    ds_rete_activation_t *p2 = ds_rete_agenda_pop(&ag);
    ds_rete_activation_t *p3 = ds_rete_agenda_pop(&ag);

    ds_rete_agenda_destroy(&ag);
    ds_rete_terminal_destroy(t);

    if (!p1 || !p2)             return fail("remove: early pop returned NULL");
    if (p3)                     return fail("remove: agenda should be empty");
    if (p1->creation_timetag != 1) return fail("remove: first pop wrong");
    if (p2->creation_timetag != 3) return fail("remove: second pop wrong");
    return 0;
}

static int test_refraction_basic(void)
{
    ds_rete_terminal_t *t = NULL;
    ds_rete_terminal_create("r", 0, &t);

    uint64_t gen = 5;
    uint32_t h   = 0xABCDu;

    if (ds_rete_terminal_is_refracted(t, h, gen, NULL, 0))
        return fail("refract: should not be refracted before mark");

    if (expect_ok("mark", ds_rete_terminal_mark_refracted(t, h, gen, NULL, 0))) return 1;
    if (!ds_rete_terminal_is_refracted(t, h, gen, NULL, 0))
        return fail("refract: should be refracted after mark");

    /* Different generation: not refracted. */
    if (ds_rete_terminal_is_refracted(t, h, gen + 1, NULL, 0))
        return fail("refract: old entry should not match new generation");

    /* Mark in new generation; old entry is now stale. */
    if (expect_ok("mark2", ds_rete_terminal_mark_refracted(t, h, gen + 1, NULL, 0))) return 1;
    if (!ds_rete_terminal_is_refracted(t, h, gen + 1, NULL, 0))
        return fail("refract: new gen entry missing");
    /* Old gen entry naturally expired. */
    if (ds_rete_terminal_is_refracted(t, h, gen, NULL, 0))
        return fail("refract: old gen should not show up");

    ds_rete_terminal_destroy(t);
    return 0;
}

/* [IRET.11.3]: a mark that cannot keep its tuple is refused, not stored on
   the hash alone. An entry with no ids would match every token of the
   terminal whose hash collides, dropping a distinct activation unfired
   depending on the allocator ([LDET.1.1]). The mark answers DS_ERR_OOM and
   stores nothing; the pump raises that as EngineError ALLOCATION
   (test_fault_emission).

   (3,1) and (1,0) hash alike under the token hash (rete/token.c): 3 ^ rotl(1,1)
   and 1 ^ rotl(0,1) are both 1. The terminal is pre-sized so the mark's only
   allocation is the tuple's copy, and g_refused_mallocs says it was that one. */
/* @spec [IRET.11.3.3] [IRET.8.2] */
static int test_refraction_mark_without_its_tuple_is_refused(void)
{
    ds_rete_terminal_t *t = NULL;
    if (expect_ok("create", ds_rete_terminal_create("r217", 0, &t))) return 1;
    if (expect_ok("presize", ds_rete_terminal_presz_refract(t, 64))) return 1;

    const uint64_t gen      = 3;
    const uint32_t h        = 1u;
    const uint32_t fired[2] = { 3u, 1u };
    const uint32_t other[2] = { 1u, 0u };

    g_refused_mallocs = 0;
    g_refuse_mallocs  = 1;
    ds_result_t r = ds_rete_terminal_mark_refracted(t, h, gen, fired, 2);
    g_refuse_mallocs  = 0;

    int rc = 0;
    if (g_refused_mallocs != 1)
        rc = fail("tuple: the tuple's copy was not the request refused");
    else if (expect_status("tuple: refused mark", r, DS_ERR_OOM))
        rc = 1;
    else if (ds_rete_terminal_is_refracted(t, h, gen, other, 2))
        rc = fail("tuple: a distinct tuple with the same hash is refracted");
    else if (ds_rete_terminal_is_refracted(t, h, gen, fired, 2))
        rc = fail("tuple: the refused mark was stored");
    /* The allocator back: the same mark is kept with its tuple, and the tuple,
       not the hash, decides. */
    else if (expect_ok("tuple: mark", ds_rete_terminal_mark_refracted(t, h, gen,
                                                                     fired, 2)))
        rc = 1;
    else if (!ds_rete_terminal_is_refracted(t, h, gen, fired, 2))
        rc = fail("tuple: the fired tuple is not refracted");
    else if (ds_rete_terminal_is_refracted(t, h, gen, other, 2))
        rc = fail("tuple: a colliding distinct tuple is refracted");

    ds_rete_terminal_destroy(t);
    return rc;
}

/* [LTIM.2.5.1]: the persistent edge-once one-shot: mark records a
   matched fact's id, fired() detects it, and clear() reclaims the slot when the
   fact retracts (the leak-freedom half — ds_rete_wm_retract calls clear so the
   set stays bounded across mature/retract cycles). Unlike refraction, no
   generation: an entry survives until explicitly cleared. */
static int test_oneshot_mark_fired_clear(void)
{
    ds_rete_terminal_t *t = NULL;
    ds_rete_terminal_create("r", 0, &t);

    if (ds_rete_terminal_oneshot_fired(t, 100))
        return fail("oneshot: fired before mark");

    if (expect_ok("mark 100", ds_rete_terminal_oneshot_mark(t, 100))) return 1;
    if (expect_ok("mark 200", ds_rete_terminal_oneshot_mark(t, 200))) return 1;
    if (!ds_rete_terminal_oneshot_fired(t, 100)) return fail("oneshot: 100 not fired after mark");
    if (!ds_rete_terminal_oneshot_fired(t, 200)) return fail("oneshot: 200 not fired after mark");
    if (oa_len(&t->oneshot) != 2) return fail("oneshot: expected 2 entries");

    /* Idempotent mark — re-marking an already-fired id does not grow the set. */
    if (expect_ok("mark 100 again", ds_rete_terminal_oneshot_mark(t, 100))) return 1;
    if (oa_len(&t->oneshot) != 2) return fail("oneshot: idempotent mark grew the set");

    /* Clear of an absent id is a harmless no-op (the $ClockTick retract path
       hits this every pump: the tick fact's id is never in the set). */
    ds_rete_terminal_oneshot_clear(t, 999);
    if (oa_len(&t->oneshot) != 2) return fail("oneshot: clear of absent id changed the set");

    /* Clear reclaims the slot — the leak-freedom guarantee. */
    ds_rete_terminal_oneshot_clear(t, 100);
    if (ds_rete_terminal_oneshot_fired(t, 100)) return fail("oneshot: 100 still fired after clear");
    if (!ds_rete_terminal_oneshot_fired(t, 200)) return fail("oneshot: clear of 100 dropped 200");
    if (oa_len(&t->oneshot) != 1) return fail("oneshot: clear did not reclaim the slot");

    /* A fresh id (an upsert mints a new fact_id) is absent -> re-arms. */
    if (ds_rete_terminal_oneshot_fired(t, 300)) return fail("oneshot: fresh id 300 unexpectedly fired");

    ds_rete_terminal_oneshot_clear(t, 200);
    if (oa_len(&t->oneshot) != 0) return fail("oneshot: set not empty after clearing all");

    /* Past the table's first grow, cleared out of order: membership must
       survive the backward-shift deletes ([LNLS.4.7]: the set is an oa map,
       so a retraction clears in O(1) amortized). */
    for (uint32_t id = 1; id <= 1000; id++)
        if (expect_ok("mark many", ds_rete_terminal_oneshot_mark(t, id))) return 1;
    for (uint32_t id = 1000; id >= 2; id -= 2)
        ds_rete_terminal_oneshot_clear(t, id);
    if (oa_len(&t->oneshot) != 500) return fail("oneshot: expected 500 after clearing the evens");
    for (uint32_t id = 1; id <= 1000; id++) {
        bool want = (id % 2u) == 1u;
        if (ds_rete_terminal_oneshot_fired(t, id) != want)
            return fail("oneshot: membership wrong after interleaved clears");
    }

    ds_rete_terminal_destroy(t);
    return 0;
}

static int test_terminal_left_activate_retract(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    if (expect_ok("terminal_create",
                  ds_rete_terminal_create(istr(c.engine, "rule1"), 0, &term))) return 1;
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    /* Build a root token manually. */
    ds_rete_fact_t *f = assert_val(&c, 42);
    ds_result_t err;
    ds_rete_token_t *root = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    if (!root) return fail("token_create failed");

    /* Left-activate: creates an activation in the agenda. */
    if (expect_ok("left_activate",
                  ds_rete_terminal_left_activate(term, root, c.engine))) return 1;
    if (c.engine->agenda.count != 1) return fail("agenda should have 1 entry");

    /* Left-retract: removes the activation. */
    if (expect_ok("left_retract",
                  ds_rete_terminal_left_retract(term, root, c.engine))) return 1;
    if (c.engine->agenda.count != 0) return fail("agenda should be empty after retract");

    ds_rete_token_free(root);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

static int test_run_fires_activation(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "rule1"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;
    ds_rete_token_t *root = ds_rete_token_create(NULL, f, c.engine->next_timetag++, NULL, NULL, &err);
    ds_rete_terminal_left_activate(term, root, c.engine);
    ds_rete_token_free(root);

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired != 1) {
        fprintf(stderr, "FAIL: run: want 1 fire, got %u\n", fired);
        return 1;
    }
    if (log.n != 1) return fail("run: fire_fn not called once");
    if (strcmp(log.entries[0].rule_name, "rule1") != 0)
        return fail("run: wrong rule_name in fire_fn");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

static int test_run_source_order(void)
{
    /* End-to-end twin of test_agenda_insert_pop_order: two rules, the
       later-in-source one activated FIRST, and the run must still fire the
       earlier one first. [LDET.5.4] — source order is the outer key, and
       [LTES.12.9] is why it cannot be left to match-completion order. */
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *first = NULL, *second = NULL;
    ds_rete_terminal_create(istr(c.engine, "first_rule"),  0, &first);
    ds_rete_terminal_create(istr(c.engine, "second_rule"), 1, &second);
    first->fire_fn = second->fire_fn = record_fire;
    first->fire_ctx = second->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;

    /* Activate `second` first and give it the earlier timetag; source order
       still decides. */
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    ds_rete_token_t *t2 = ds_rete_token_create(NULL, f, 2, NULL, NULL, &err);
    ds_rete_terminal_left_activate(second, t1, c.engine);
    ds_rete_terminal_left_activate(first,  t2, c.engine);
    ds_rete_token_free(t1);
    ds_rete_token_free(t2);

    if (expect_ok("run", ds_rete_run(c.engine, 0, NULL))) return 1;
    if (log.n != 2) return fail("source order: want 2 fires");
    if (strcmp(log.entries[0].rule_name, "first_rule") != 0)
        return fail("source order: the earlier rule should fire first");
    if (strcmp(log.entries[1].rule_name, "second_rule") != 0)
        return fail("source order: the later rule should fire second");

    ds_rete_terminal_destroy(first);
    ds_rete_terminal_destroy(second);
    destroy_ctx(&c);
    return 0;
}

/* [IRET.11.2]: THE AGENDA ORDERS BY NO HASH. Six activations of one rule, so
   the terminal ordinal ties and only the creation timetag may decide. The
   facts are ranked by their token hash and given timetags in the OPPOSITE
   order, then activated in an order that is neither, so a fire order equal to
   the timetag order is one no hash-keyed or insertion-keyed agenda produces:
   ordering by hash fires them exactly reversed. */
static int test_iret_11_2__same_rule_fires_by_timetag_not_by_hash(void)
{
    enum { NF = 6 };
    Ctx c = make_ctx();
    FiredLog log = {0};
    ds_result_t err;

    ds_rete_terminal_t *term = NULL;
    if (expect_ok("11.2: create",
                  ds_rete_terminal_create(istr(c.engine, "one_rule"), 0, &term)))
        return 1;
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    ds_rete_fact_t *f[NF];
    uint32_t hash[NF];
    for (int i = 0; i < NF; i++) {
        f[i] = assert_val(&c, 100 + i);
        ds_rete_token_t *probe = ds_rete_token_create(NULL, f[i], 0, NULL, NULL, &err);
        if (!probe) return fail("11.2: token_create");
        hash[i] = probe->hash;
        ds_rete_token_free(probe);
    }
    /* rank[k] is the fact with the k-th HIGHEST hash; it gets timetag k + 1. */
    int rank[NF];
    for (int i = 0; i < NF; i++) rank[i] = i;
    for (int a = 0; a < NF; a++)
        for (int b = a + 1; b < NF; b++)
            if (hash[rank[b]] > hash[rank[a]]) {
                int t = rank[a]; rank[a] = rank[b]; rank[b] = t;
            }
    for (int k = 1; k < NF; k++)
        if (hash[rank[k]] == hash[rank[k - 1]])
            return fail("11.2: premise -- two facts share a token hash");

    static const int insert_order[NF] = { 3, 0, 5, 1, 4, 2 };
    for (int j = 0; j < NF; j++) {
        int k = insert_order[j];
        ds_rete_token_t *tok = ds_rete_token_create(NULL, f[rank[k]],
                                                    (uint64_t)(k + 1),
                                                    NULL, NULL, &err);
        if (!tok) return fail("11.2: token_create");
        if (expect_ok("11.2: activate",
                      ds_rete_terminal_left_activate(term, tok, c.engine)))
            return 1;
        ds_rete_token_free(tok);
    }

    uint32_t fired = 0;
    int rc = 0;
    if (expect_ok("11.2: run", ds_rete_run(c.engine, 0, &fired)))
        rc = 1;
    else if (fired != NF || log.n != NF)
        rc = fail("11.2: every activation fires once");
    else
        for (int k = 0; k < NF && rc == 0; k++)
            if (log.entries[k].fact0_id != f[rank[k]]->id) {
                fprintf(stderr, "FAIL: 11.2: fire %d is fact %u, want fact %u "
                        "(timetag %d) -- the agenda did not order by the "
                        "creation timetag\n", k, log.entries[k].fact0_id,
                        f[rank[k]]->id, k + 1);
                rc = 1;
            }

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return rc;
}

/* @spec [IRET.11.3.1] [IRET.8.2] */
static int test_run_refraction(void)
{
    /* Same token activates twice in the same cycle; should fire only once. */
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "rule1"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;
    /* Two activations with identical token (same fact → same hash). */
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    ds_rete_token_t *t2 = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    ds_rete_terminal_left_activate(term, t1, c.engine);
    ds_rete_terminal_left_activate(term, t2, c.engine);
    ds_rete_token_free(t1);
    ds_rete_token_free(t2);

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(c.engine, 0, &fired))) return 1;
    /* Second activation should be refracted and skipped. */
    if (fired != 1) {
        fprintf(stderr, "FAIL: refraction: want 1 fire, got %u\n", fired);
        return 1;
    }
    if (log.n != 1) return fail("refraction: fire_fn called wrong number of times");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

/* [IRET.11.3.3]: an immature activation's mark does not refract a distinct
   match that collides with it. When a terminal's fire guard reads false, the
   pump refracts the token without firing it, keyed by its tuple, so a mature
   activation of the same rule whose hash collides, popped later in the
   generation, still fires. The Mercury runtime keys refraction on the exact
   tuple too (ds.agenda).

   An impl test, not a differential scenario: no compiled program reaches this.
   A clock-driven rule has one positive pattern ([LTIM.2.6.2]) and a pump one
   tick, so no two of its tokens share a hash; the network here is built by
   hand, two-fact tokens under a condition guard.

   The colliding pair is found among the WM's own fact ids rather than assumed,
   with distinct first facts so the guard `p0.val == X` tells them apart: the
   earlier timetag is immature and pops first, the later one is mature. */
/* @spec [IRET.11.3.3] */
static int test_immature_mark_does_not_refract_a_colliding_match(void)
{
    enum { NF = 8 };
    Ctx c = make_ctx();
    FiredLog log = {0};
    ds_result_t err;

    ds_rete_fact_t *f[NF];
    for (int i = 0; i < NF; i++) f[i] = assert_val(&c, i);   /* val = i */

    uint32_t hash[NF][NF] = {{0}};
    for (int a = 0; a < NF; a++)
        for (int b = 0; b < NF; b++) {
            if (a == b) continue;
            ds_rete_token_t *l = ds_rete_token_create(NULL, f[a], 0, NULL, NULL, &err);
            ds_rete_token_t *p = ds_rete_token_create(l, f[b], 0, NULL, NULL, &err);
            if (!l || !p) return fail("immature: token_create");
            hash[a][b] = p->hash;
            ds_rete_token_free(p);
            ds_rete_token_free(l);
        }
    int A = -1, B = -1, X = -1, Y = -1;
    for (int a = 0; a < NF && X < 0; a++)
        for (int b = 0; b < NF && X < 0; b++)
            for (int x = 0; x < NF && X < 0; x++)
                for (int y = 0; y < NF && X < 0; y++)
                    if (a != b && x != y && a != x
                            && hash[a][b] == hash[x][y]) {
                        A = a; B = b; X = x; Y = y;
                    }
    if (X < 0) return fail("immature: no colliding pair among the facts");

    ds_rete_terminal_t *term = NULL;
    if (expect_ok("immature: create",
                  ds_rete_terminal_create(istr(c.engine, "guarded"), 0, &term)))
        return 1;
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;
    ds_rete_expr_t *p0 = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    p0->var.pattern_index = 0;
    p0->var.slot_index    = 0;
    ds_rete_expr_t *k = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    k->lit_int = X;
    ds_rete_expr_t *eq = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    eq->binop.op    = DS_RETE_BINOP_EQ;
    eq->binop.left  = p0;
    eq->binop.right = k;
    term->fire_guard = eq;   /* owned by the terminal */

    ds_rete_token_t *il = ds_rete_token_create(NULL, f[A], 1, NULL, NULL, &err);
    ds_rete_token_t *imm = ds_rete_token_create(il, f[B], 1, NULL, NULL, &err);
    ds_rete_token_t *ml = ds_rete_token_create(NULL, f[X], 2, NULL, NULL, &err);
    ds_rete_token_t *mat = ds_rete_token_create(ml, f[Y], 2, NULL, NULL, &err);
    if (!imm || !mat) return fail("immature: token_create");
    if (imm->hash != mat->hash) return fail("immature: the pair does not collide");
    if (expect_ok("immature: activate immature",
                  ds_rete_terminal_left_activate(term, imm, c.engine))) return 1;
    if (expect_ok("immature: activate mature",
                  ds_rete_terminal_left_activate(term, mat, c.engine))) return 1;
    ds_rete_token_free(il);  ds_rete_token_free(imm);
    ds_rete_token_free(ml);  ds_rete_token_free(mat);

    uint32_t fired = 0;
    int rc = 0;
    if (expect_ok("immature: run", ds_rete_run(c.engine, 0, &fired)))
        rc = 1;
    else if (fired != 1 || log.n != 1) {
        fprintf(stderr, "FAIL: immature: want the mature match to fire once, "
                "got %u fire(s), %d logged -- the immature mark refracted a "
                "distinct colliding match\n", fired, log.n);
        rc = 1;
    } else if (log.entries[0].fact0_id != f[X]->id
               || log.entries[0].fcount != 2)
        rc = fail("immature: the fired token is not the mature match");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return rc;
}

/* [LERR.1.4.7]: the firing token's copy failing abandons the activation and
   is not the pump's status: it is the RESOURCE fault. This standalone engine
   has no ds_engine behind it, so the fault records nothing here;
   test_fault_emission pins the recorded EngineError ALLOCATION and the halt.

   Nothing allocates in the pump before the copy -- an empty fault-fact queue,
   the agenda pop, a tuple on the stack, an empty refraction table -- so the
   one refused ds_calloc is the copy's first. */
static int test_token_copy_failure_abandons_the_activation(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};
    ds_rete_terminal_t *term = NULL;
    if (expect_ok("token copy: create",
                  ds_rete_terminal_create(istr(c.engine, "copy"), 0, &term)))
        return 1;
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;
    ds_rete_token_t *t = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    if (!t) return fail("token copy: token_create");
    if (expect_ok("token copy: activate",
                  ds_rete_terminal_left_activate(term, t, c.engine))) return 1;
    ds_rete_token_free(t);

    uint32_t fired = 0;
    g_refused_callocs = 0;
    g_refuse_callocs  = 1;
    ds_result_t r = ds_rete_run(c.engine, 0, &fired);
    g_refuse_callocs  = 0;

    int rc = 0;
    if (g_refused_callocs != 1)
        rc = fail("token copy: the copy's allocation was not the one refused");
    else if (expect_ok("token copy: the pump's status", r))
        rc = 1;
    else if (fired != 0 || log.n != 0)
        rc = fail("token copy: an activation whose token was not copied fired");
    else if (term->live_activations != 0 || term->activations != NULL)
        rc = fail("token copy: the popped activation was left on the terminal");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return rc;
}

/* The firing callback for the edge-once case below: records the firing, then
   arms one ds_calloc refusal for what the pump allocates after it. */
static void record_fire_then_refuse_a_calloc(const char *rule_name,
                                             ds_rete_token_t *token, void *ctx)
{
    record_fire(rule_name, token, ctx);
    g_refuse_callocs = 1;
}

/* [LERR.1.4.7]: the edge-once mark failing is not the pump's status. A
   matured clock-driven firing records its fact in the terminal's one-shot set
   ([LTIM.2.5.1]); a failed allocation there is the RESOURCE fault
   (test_fault_emission pins the halt), and the pump goes on.

   A clock-driven token by hand: a fact and a tick under a condition guard,
   with the engine's tick schema set. The refraction table is pre-sized, so
   after the firing the only ds_calloc is the one-shot set's first grow (oa.c
   allocates on the first put) -- and the set staying empty says the refusal
   landed there. */
static int test_edge_once_mark_failure_is_not_the_pumps_status(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};
    ds_result_t err;

    ds_rete_slot_desc_t slot = { .name = "val", .type = DS_RETE_VAL_INT };
    ds_rete_schema_t *tick_schema = NULL;
    ds_rete_schema_register(c.engine, "Tick", DS_RETE_SCOPE_PLAIN, 0, &slot, 1,
                            &tick_schema);
    if (!tick_schema) return fail("edge mark: tick schema");
    ds_rete_alpha_node_t *alpha_tick = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &alpha_tick);
    ds_rete_dispatch_add(c.engine, tick_schema->id, alpha_tick);

    ds_rete_fact_t *f = assert_val(&c, 5);
    ds_rete_val_t tv = ds_rete_val_int(0);
    ds_rete_fact_t *k = NULL;
    ds_rete_wm_assert(c.engine, tick_schema->id, &tv, &k);
    if (!f || !k) return fail("edge mark: assert");

    ds_rete_terminal_t *term = NULL;
    if (expect_ok("edge mark: create",
                  ds_rete_terminal_create(istr(c.engine, "edge"), 0, &term)))
        return 1;
    term->fire_fn  = record_fire_then_refuse_a_calloc;
    term->fire_ctx = &log;
    if (expect_ok("edge mark: presize",
                  ds_rete_terminal_presz_refract(term, 64))) return 1;
    ds_rete_expr_t *p0 = ds_rete_expr_alloc(DS_RETE_EXPR_VAR);
    p0->var.pattern_index = 0;
    p0->var.slot_index    = 0;
    ds_rete_expr_t *five = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    five->lit_int = 5;
    ds_rete_expr_t *eq = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    eq->binop.op    = DS_RETE_BINOP_EQ;
    eq->binop.left  = p0;
    eq->binop.right = five;
    term->fire_guard = eq;   /* owned by the terminal; mature: f.val == 5 */

    ds_rete_token_t *t0 = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    ds_rete_token_t *t  = ds_rete_token_create(t0, k, 1, NULL, NULL, &err);
    if (!t0 || !t) return fail("edge mark: token_create");
    if (expect_ok("edge mark: activate",
                  ds_rete_terminal_left_activate(term, t, c.engine))) return 1;
    ds_rete_token_free(t0);
    ds_rete_token_free(t);
    /* Set only now, so the asserts above took the plain path: the pump reads
       it to know a clock-driven token (now_reeval_token, rete/engine.c). */
    c.engine->clock_tick_schema = tick_schema;

    uint32_t fired = 0;
    g_refused_callocs = 0;
    ds_result_t r = ds_rete_run(c.engine, 0, &fired);
    g_refuse_callocs = 0;

    int rc = 0;
    if (fired != 1 || log.n != 1)
        rc = fail("edge mark: the mature clock-driven match did not fire once");
    else if (g_refused_callocs != 1)
        rc = fail("edge mark: no allocation after the firing was refused");
    else if (ds_rete_terminal_oneshot_fired(term, f->id))
        rc = fail("edge mark: the refusal did not land on the edge-once mark");
    else if (expect_ok("edge mark: the pump's status", r))
        rc = 1;

    ds_rete_terminal_destroy(term);
    ds_rete_alpha_node_destroy(alpha_tick);
    destroy_ctx(&c);
    return rc;
}

static int test_run_max_fires(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "rule1"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    /* Queue 3 activations of distinct facts. */
    ds_rete_fact_t *f1 = assert_val(&c, 1);
    ds_rete_fact_t *f2 = assert_val(&c, 2);
    ds_rete_fact_t *f3 = assert_val(&c, 3);
    ds_result_t err;
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f1, 1, NULL, NULL, &err);
    ds_rete_token_t *t2 = ds_rete_token_create(NULL, f2, 2, NULL, NULL, &err);
    ds_rete_token_t *t3 = ds_rete_token_create(NULL, f3, 3, NULL, NULL, &err);

    /* Bump cycle_generation past the assert cycle so refraction resets. */
    c.engine->cycle_generation++;

    ds_rete_terminal_left_activate(term, t1, c.engine);
    ds_rete_terminal_left_activate(term, t2, c.engine);
    ds_rete_terminal_left_activate(term, t3, c.engine);
    ds_rete_token_free(t1);
    ds_rete_token_free(t2);
    ds_rete_token_free(t3);

    uint32_t fired = 0;
    ds_result_t r = ds_rete_run(c.engine, 2, &fired);
    if (expect_status("budget run", r, DS_ERR_BUDGET_EXCEEDED)) return 1;
    if (fired != 2) {
        fprintf(stderr, "FAIL: max_fires: want 2 got %u\n", fired);
        return 1;
    }

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

static int g_hook_before = 0, g_hook_after = 0;
static void hook_before(const char *r, void *ctx) { (void)r; (void)ctx; g_hook_before++; }
static void hook_after(const char *r, void *ctx)  { (void)r; (void)ctx; g_hook_after++;  }

static int test_run_fire_hooks(void)
{
    Ctx c = make_ctx();
    g_hook_before = g_hook_after = 0;
    ds_rete_set_before_fire(c.engine, hook_before, NULL);
    ds_rete_set_after_fire(c.engine, hook_after,   NULL);

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "r"), 0, &term);

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;
    ds_rete_token_t *t = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    ds_rete_terminal_left_activate(term, t, c.engine);
    ds_rete_token_free(t);

    ds_rete_run(c.engine, 0, NULL);

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);

    if (g_hook_before != 1) return fail("hooks: before_fire not called once");
    if (g_hook_after  != 1) return fail("hooks: after_fire not called once");
    return 0;
}

static int test_e2e_assert_fires_rule(void)
{
    /* alpha_all -> beta -> terminal, with a root token seeded in the beta's
     * left memory. An asserted fact right-activates the beta, the extended
     * token reaches the terminal, and ds_rete_run fires it. */
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "e2e_rule"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    /* Single-pattern beta: WM root → alpha_all */
    ds_rete_beta_node_t *beta = NULL;
    ds_rete_beta_node_create(NULL, c.alpha_all, NULL, 0, false, &beta);
    ds_rete_alpha_add_beta_output(c.alpha_all, beta);
    ds_rete_beta_add_terminal(beta, term);

    /* Seed beta's left memory with a root token. */
    ds_rete_fact_t *seed_fact = assert_val(&c, 0);
    ds_result_t err;
    ds_rete_token_t *root = ds_rete_token_create(NULL, seed_fact, 0, NULL, NULL, &err);
    ds_rete_beta_left_activate(beta, root, c.engine);
    ds_rete_token_free(root);

    /* Now assert the real fact — right-activates beta — produces token → terminal. */
    /* Reset cycle generation so refraction won't suppress the new activation. */
    c.engine->cycle_generation++;
    assert_val(&c, 99);

    uint32_t fired = 0;
    if (expect_ok("e2e run", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired < 1) {
        fprintf(stderr, "FAIL: e2e: want ≥1 fire, got %u\n", fired);
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return 1;
    }
    /* At least one fire_fn call for e2e_rule. */
    int found = 0;
    for (int i = 0; i < log.n; i++)
        if (strcmp(log.entries[i].rule_name, "e2e_rule") == 0) found++;
    if (!found) {
        fprintf(stderr, "FAIL: e2e: e2e_rule not in fire log (%d total fires)\n", log.n);
        ds_rete_beta_node_destroy(beta);
        ds_rete_terminal_destroy(term);
        destroy_ctx(&c);
        return 1;
    }

    ds_rete_beta_node_destroy(beta);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

/*
 * A positive pattern after a NOT keeps its fact in the token. A rule
 * `A a / no N n / B b -> alert "{b.v}"` compiles to the chain A(beta0) ->
 * NOT N(beta1) -> B(beta2) with the terminal on beta2, and the token at fire
 * time is [A, B] (fact_count 2): the negated N contributes no fact. A token
 * without B makes `{b.v}` (token index 1) read out of range, and the action
 * is dropped.
 *
 * Built node by node (the loader's own wiring: left_parent add_child,
 * terminal on the last beta, root betas seeded with a nil token), so a
 * failure is the Rete propagation's, not the compiler's or the loader's.
 */
/* Join-test exprs: `<right>.x == a.x` — right fact slot 0 vs token A (index 0)
   slot 0. These take the lmem_idx / ralpha_idx indexed join paths, as the
   compiled `where n.x == a.x` and `where b.x == a.x` do. */
static ds_rete_expr_t g_right_x = {
    .kind = DS_RETE_EXPR_VAR,
    .var  = { .pattern_index = DS_RETE_VAR_RIGHT_FACT, .slot_index = 0 },
};
static ds_rete_expr_t g_tok_a_x = {
    .kind = DS_RETE_EXPR_VAR,
    .var  = { .pattern_index = 0, .slot_index = 0 },
};
static ds_rete_expr_t g_eq_join = {
    .kind  = DS_RETE_EXPR_BINOP,
    .binop = { .op = DS_RETE_BINOP_EQ, .left = &g_right_x, .right = &g_tok_a_x },
};

static int test_positive_pattern_after_not_keeps_token(void)
{
    ds_rete_engine_t *e = NULL;
    ds_rete_engine_create(&e);
    ds_rete_join_test_t jt[1] = { { .expr = &g_eq_join } };

    /* Logical keyed schemas (`x: Int key`), so asserts take the
       identity-dedup path. B also carries v (mutable). */
    ds_rete_slot_desc_t s1[1] = {
        { .name = "x", .type = DS_RETE_VAL_INT, .is_key = true, .is_marked = true },
    };
    ds_rete_slot_desc_t sB[2] = {
        { .name = "x", .type = DS_RETE_VAL_INT, .is_key = true,  .is_marked = true },
        { .name = "v", .type = DS_RETE_VAL_INT, .is_key = false, .is_marked = true },
    };
    ds_rete_schema_t *scA = NULL, *scN = NULL, *scB = NULL;
    ds_rete_schema_register(e, "A", DS_RETE_SCOPE_LOGICAL, 0, s1, 1, &scA);
    ds_rete_schema_register(e, "N", DS_RETE_SCOPE_LOGICAL, 0, s1, 1, &scN);
    ds_rete_schema_register(e, "B", DS_RETE_SCOPE_LOGICAL, 0, sB, 2, &scB);
    /* schema ids assigned sequentially: A=0, N=1, B=2. */

    ds_rete_alpha_node_t *aA = NULL, *aN = NULL, *aB = NULL;
    ds_rete_alpha_node_create(0, NULL, 0, &aA); ds_rete_dispatch_add(e, 0, aA);
    ds_rete_alpha_node_create(0, NULL, 0, &aN); ds_rete_dispatch_add(e, 1, aN);
    ds_rete_alpha_node_create(0, NULL, 0, &aB); ds_rete_dispatch_add(e, 2, aB);

    /* beta0: positive A, left = WM root. */
    ds_rete_beta_node_t *b0 = NULL, *b1 = NULL, *b2 = NULL;
    ds_rete_beta_node_create(NULL, aA, NULL, 0, false, &b0);
    ds_rete_alpha_add_beta_output(aA, b0);
    /* beta1: NOT N with join `n.x == a.x`, left = beta0. */
    ds_rete_beta_node_create(b0, aN, jt, 1, true, &b1);
    ds_rete_beta_add_child(b0, b1);
    ds_rete_alpha_add_beta_output(aN, b1);
    /* beta2: positive B with join `b.x == a.x`, left = beta1 (the NOT), on
       the indexed join path. */
    ds_rete_beta_node_create(b1, aB, jt, 1, false, &b2);
    ds_rete_beta_add_child(b1, b2);
    ds_rete_alpha_add_beta_output(aB, b2);

    FiredLog log = {0};
    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(e, "r"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;
    ds_rete_beta_add_terminal(b2, term);

    /* Seed the root beta with a nil token, exactly as the loader does. */
    ds_result_t serr;
    ds_rete_token_t *nil = ds_rete_token_create_nil(NULL, NULL, &serr);
    ds_rete_beta_left_activate(b0, nil, e);
    ds_rete_token_free(nil);

    /* Assert A(x=7) then B(x=7); no N. The NOT is satisfied, B joins. */
    ds_rete_val_t va = ds_rete_val_int(7);
    ds_rete_fact_t *fa = NULL;
    ds_rete_wm_assert(e, 0, &va, &fa);
    ds_rete_val_t vb[2] = { ds_rete_val_int(7), ds_rete_val_int(99) };
    ds_rete_fact_t *fb = NULL;
    ds_rete_wm_assert(e, 2, vb, &fb);

    uint32_t fired = 0;
    if (expect_ok("run", ds_rete_run(e, 0, &fired))) {
        ds_rete_engine_destroy(e);
        return 1;
    }

    int rc = 0;
    if (log.n != 1) {
        fprintf(stderr, "FAIL: pos-after-NOT: want 1 fire, got %d\n", log.n);
        rc = 1;
    } else if (log.entries[0].fcount != 2) {
        fprintf(stderr,
                "FAIL: pos-after-NOT: token fact_count=%u, want 2 — B dropped "
                "from the token after the NOT node\n",
                log.entries[0].fcount);
        rc = 1;
    } else if (log.entries[0].fact0_id != fa->id) {
        /* Token order must be [A, B]: A (token index 0) then B (index 1).
           A reversed [B, A] makes b.v read A, which has no v slot, and the
           interpolated action is dropped. */
        fprintf(stderr,
                "FAIL: pos-after-NOT: token[0] is fact %u, want A (fact %u) — "
                "the positive pattern after the NOT is mis-ordered\n",
                log.entries[0].fact0_id, fa->id);
        rc = 1;
    }

    ds_rete_engine_destroy(e);
    return rc;
}

static int test_retract_removes_activation(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};

    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "r"), 0, &term);
    term->fire_fn  = record_fire;
    term->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 1);
    ds_result_t err;
    ds_rete_token_t *t = ds_rete_token_create(NULL, f, 0, NULL, NULL, &err);
    ds_rete_terminal_left_activate(term, t, c.engine);

    /* Retract before run. */
    ds_rete_terminal_left_retract(term, t, c.engine);
    ds_rete_token_free(t);

    uint32_t fired = 0;
    if (expect_ok("run after retract", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired != 0) {
        fprintf(stderr, "FAIL: retract-before-fire: want 0 fires, got %u\n", fired);
        return 1;
    }
    if (log.n != 0) return fail("retract-before-fire: fire_fn should not be called");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

/* The terminal's act_map, an oa map keyed by token hash, deletes by backward
 * shift; a hole left mid probe chain would make a colliding later activation
 * unreachable, and its left_retract would find nothing. N distinct pending
 * activations force rehashes and collisions; each left_retract, in insertion
 * order, must find its activation (live_activations falls by one each time),
 * and the table empties. */
static int test_act_map_delete_under_collision(void)
{
    enum { N = 150 };
    Ctx c = make_ctx();
    ds_rete_terminal_t *term = NULL;
    if (expect_ok("terminal_create",
                  ds_rete_terminal_create(istr(c.engine, "rcol"), 0, &term))) return 1;

    ds_rete_token_t *toks[N];
    for (int i = 0; i < N; i++) {
        ds_rete_fact_t *f = assert_val(&c, i);   /* distinct val -> distinct token */
        ds_result_t err;
        toks[i] = ds_rete_token_create(NULL, f, (uint32_t)(i + 1), NULL, NULL, &err);
        if (!toks[i]) return fail("token_create");
        if (expect_ok("left_activate",
                      ds_rete_terminal_left_activate(term, toks[i], c.engine))) return 1;
    }
    if (term->live_activations != (uint32_t)N)
        return fail("live_activations != N after activates");

    for (int i = 0; i < N; i++) {
        if (expect_ok("left_retract",
                      ds_rete_terminal_left_retract(term, toks[i], c.engine))) return 1;
        if (term->live_activations != (uint32_t)(N - 1 - i)) {
            fprintf(stderr, "FAIL: retract %d did not find its activation "
                    "(live=%u want %d) — act_map probe chain broken\n",
                    i, term->live_activations, N - 1 - i);
            return 1;
        }
        ds_rete_token_free(toks[i]);
    }
    if (term->activations != NULL) return fail("activation list not empty");

    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

/* A refraction discard evicts the activation from the act_map and the list.
 * An activation fires and is marked refracted; an equal token re-forms in the
 * same cycle generation, so ds_rete_run pops it and discards it. The fired
 * activation then retracts cleanly and teardown frees each activation once;
 * the valgrind run checks the frees, and the assertions the live count and
 * the list. */
static int test_refraction_discard_no_leak(void)
{
    Ctx c = make_ctx();
    FiredLog log = {0};
    ds_rete_terminal_t *term = NULL;
    if (expect_ok("create", ds_rete_terminal_create(istr(c.engine, "r57"), 0, &term)))
        return 1;
    term->fire_fn = record_fire; term->fire_ctx = &log;

    ds_rete_fact_t *f = assert_val(&c, 7);
    ds_result_t err;

    /* A fires, is marked refracted (cycle generation does not change after). */
    ds_rete_token_t *t1 = ds_rete_token_create(NULL, f, 1, NULL, NULL, &err);
    if (expect_ok("activate A", ds_rete_terminal_left_activate(term, t1, c.engine))) return 1;
    uint32_t fired = 0;
    if (expect_ok("run 1", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired != 1) return fail("discard: A should fire once");

    /* Equal token re-forms in the same generation -> refraction-discard. */
    ds_rete_token_t *t2 = ds_rete_token_create(NULL, f, 2, NULL, NULL, &err);
    if (expect_ok("activate A'", ds_rete_terminal_left_activate(term, t2, c.engine))) return 1;
    fired = 0;
    if (expect_ok("run 2", ds_rete_run(c.engine, 0, &fired))) return 1;
    if (fired != 0) return fail("discard: A' must be refraction-discarded, not re-fire");

    /* Exactly the fired activation A remains, live and retractable; the
       discarded A' must be gone from both the list and the act_map. */
    if (term->live_activations != 1) {
        fprintf(stderr, "discard: live_activations=%u after discard (want 1)\n",
                term->live_activations);
        return 1;
    }
    ds_rete_token_t *t3 = ds_rete_token_create(NULL, f, 3, NULL, NULL, &err);
    if (expect_ok("retract A", ds_rete_terminal_left_retract(term, t3, c.engine))) return 1;
    ds_rete_token_free(t3);
    if (term->activations != NULL) return fail("discard: list not empty after retract");
    if (term->live_activations != 0) return fail("discard: live_activations leaked");

    ds_rete_token_free(t1);
    ds_rete_token_free(t2);
    ds_rete_terminal_destroy(term);   /* must not double-free */
    destroy_ctx(&c);
    return 0;
}

/* Discarding a middle activation keeps the doubly-linked
 * list and the act_map consistent — the neighbours stay reachable and the live
 * count tracks. */
static int test_discard_activation_unlinks_cleanly(void)
{
    Ctx c = make_ctx();
    ds_rete_terminal_t *term = NULL;
    ds_rete_terminal_create(istr(c.engine, "rd57"), 0, &term);
    ds_rete_fact_t *fa = assert_val(&c, 1);
    ds_rete_fact_t *fb = assert_val(&c, 2);
    ds_rete_fact_t *fc = assert_val(&c, 3);
    ds_result_t err;
    ds_rete_token_t *ta = ds_rete_token_create(NULL, fa, 1, NULL, NULL, &err);
    ds_rete_token_t *tb = ds_rete_token_create(NULL, fb, 2, NULL, NULL, &err);
    ds_rete_token_t *tc = ds_rete_token_create(NULL, fc, 3, NULL, NULL, &err);
    ds_rete_terminal_left_activate(term, ta, c.engine);
    ds_rete_terminal_left_activate(term, tb, c.engine);
    ds_rete_terminal_left_activate(term, tc, c.engine);
    if (term->live_activations != 3) return fail("middle: setup 3 live");

    ds_rete_activation_t *mid = NULL;
    for (ds_rete_activation_t *a = term->activations; a; a = a->term_next)
        if (ds_rete_tokens_equal(a->token, tb)) { mid = a; break; }
    if (!mid) return fail("middle: middle activation not found");
    /* Mimic ds_rete_run: the activation is popped off the agenda before being
       discarded (the discard helper does not touch the agenda — its caller has
       already popped). Remove it here so the later left_retracts don't walk a
       freed agenda entry. */
    ds_rete_agenda_remove(&c.engine->agenda, mid);
    ds_rete_terminal_discard_activation(term, mid);

    if (term->live_activations != 2) return fail("middle: live not decremented");
    /* Discarded one is gone; neighbours still present and prev-chain intact. */
    int seen_a = 0, seen_c = 0;
    ds_rete_activation_t *prev = NULL;
    for (ds_rete_activation_t *a = term->activations; a; prev = a, a = a->term_next) {
        if (ds_rete_tokens_equal(a->token, tb)) return fail("middle: discarded still in list");
        if (a->term_prev != prev) return fail("middle: term_prev chain corrupted");
        if (ds_rete_tokens_equal(a->token, ta)) seen_a = 1;
        if (ds_rete_tokens_equal(a->token, tc)) seen_c = 1;
    }
    if (!seen_a || !seen_c) return fail("middle: a neighbour vanished");

    /* Both neighbours retract cleanly via the act_map (no stale tb entry). */
    ds_rete_token_t *ta2 = ds_rete_token_create(NULL, fa, 4, NULL, NULL, &err);
    ds_rete_token_t *tc2 = ds_rete_token_create(NULL, fc, 5, NULL, NULL, &err);
    if (expect_ok("middle: retract a", ds_rete_terminal_left_retract(term, ta2, c.engine))) return 1;
    if (expect_ok("middle: retract c", ds_rete_terminal_left_retract(term, tc2, c.engine))) return 1;
    ds_rete_token_free(ta2); ds_rete_token_free(tc2);
    if (term->live_activations != 0) return fail("middle: live not zero after retracts");

    ds_rete_token_free(ta); ds_rete_token_free(tb); ds_rete_token_free(tc);
    ds_rete_terminal_destroy(term);
    destroy_ctx(&c);
    return 0;
}

int main(void)
{
    int fail_count = 0;

#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_terminal_agenda ===\n");

    RUN(test_agenda_insert_pop_order);
    RUN(test_agenda_remove);
    RUN(test_refraction_basic);
    RUN(test_refraction_mark_without_its_tuple_is_refused);
    RUN(test_oneshot_mark_fired_clear);
    RUN(test_terminal_left_activate_retract);
    RUN(test_run_fires_activation);
    RUN(test_run_source_order);
    RUN(test_iret_11_2__same_rule_fires_by_timetag_not_by_hash);
    RUN(test_run_refraction);
    RUN(test_immature_mark_does_not_refract_a_colliding_match);
    RUN(test_token_copy_failure_abandons_the_activation);
    RUN(test_edge_once_mark_failure_is_not_the_pumps_status);
    RUN(test_run_max_fires);
    RUN(test_run_fire_hooks);
    RUN(test_e2e_assert_fires_rule);
    RUN(test_positive_pattern_after_not_keeps_token);
    RUN(test_retract_removes_activation);
    RUN(test_act_map_delete_under_collision);
    RUN(test_refraction_discard_no_leak);
    RUN(test_discard_activation_unlinks_cleanly);

#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_terminal_agenda: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_terminal_agenda: %d FAILED ===\n", fail_count);
    return 1;
}

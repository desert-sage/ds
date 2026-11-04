/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [NDBG.5.1] [NDBG.5.2] [NDBG.7.1] [NDBG.4.1]
 * ds_engine_get_justifiers under every allocation failure, and the NULL
 * arguments of it and ds_engine_rete_network. Each allocation of a
 * two-justifier call fails in turn; the control counts them, so a call that
 * comes to allocate more is not left half swept.
 *
 * A read of a freed block usually returns what it held, and valgrind cannot
 * run a test that wraps the allocator, so realloc, strdup and free are wrapped
 * (libds's ds_realloc, ds_strdup and ds_free are weak over them) and, while
 * `g_watching`, keep a ledger of the blocks the call holds. free poisons a
 * block before releasing it, so a pointer read back out of a freed array is
 * no block's, and refuses a pointer the ledger does not hold, as a double free
 * is. A block left in the ledger leaked.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "wm.h"              /* ds_fact_t — fact_id / rete_id are internal */
#include "rete/engine.h"     /* tms */
#include "rete/loader.h"     /* ds_rete_load_network */
#include "rete/tms.h"        /* ds_tms_add */

static int failures = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            failures++;                                                       \
        }                                                                     \
    } while (0)

#define CHECK_OK(r, msg)                                                      \
    do {                                                                      \
        ds_result_t rr_ = (r);                                                \
        if (rr_.status != DS_OK) {                                            \
            fprintf(stderr, "FAIL: %s: status=%d detail=%s (%s:%d)\n", (msg), \
                    rr_.status, rr_.detail ? rr_.detail : "(null)",           \
                    __FILE__, __LINE__);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

void *__real_realloc(void *p, size_t sz);
char *__real_strdup(const char *s);
void  __real_free(void *p);

#define POISON_BYTE 0xA5
#define MAX_BLOCKS  16

typedef struct { void *p; size_t n; } block_t;

static block_t g_blocks[MAX_BLOCKS];
static int     g_n_blocks  = 0;
static bool    g_watching  = false;
static int     g_requests  = 0;   /* allocations asked for while watching */
static int     g_fail_at   = 0;   /* the request that fails; 0: none */
static int     g_bad_frees = 0;   /* frees of a pointer the ledger does not hold */

static void ledger_add(void *p, size_t n)
{
    if (g_n_blocks == MAX_BLOCKS) {
        fprintf(stderr, "FAIL: more than %d blocks live\n", MAX_BLOCKS);
        failures++;
        return;
    }
    g_blocks[g_n_blocks].p = p;
    g_blocks[g_n_blocks].n = n;
    g_n_blocks++;
}

/* Takes the block out of the ledger; false if it was not in it. */
static bool ledger_take(const void *p, size_t *out_n)
{
    for (int i = 0; i < g_n_blocks; i++) {
        if (g_blocks[i].p == p) {
            if (out_n != NULL) *out_n = g_blocks[i].n;
            g_blocks[i] = g_blocks[--g_n_blocks];
            return true;
        }
    }
    return false;
}

static bool request_fails(void)
{
    g_requests++;
    return g_requests == g_fail_at;
}

void *__wrap_realloc(void *p, size_t sz)
{
    if (!g_watching) return __real_realloc(p, sz);
    if (request_fails()) return NULL;   /* `p` stays live, as C says */

    void *q = __real_realloc(p, sz);
    if (q != NULL) {
        if (p != NULL && !ledger_take(p, NULL)) g_bad_frees++;
        ledger_add(q, sz);
    }
    return q;
}

char *__wrap_strdup(const char *s)
{
    if (!g_watching) return __real_strdup(s);
    if (request_fails()) return NULL;

    char *q = __real_strdup(s);
    if (q != NULL) ledger_add(q, strlen(s) + 1);
    return q;
}

void __wrap_free(void *p)
{
    if (!g_watching || p == NULL) {
        __real_free(p);
        return;
    }
    size_t n = 0;
    if (!ledger_take(p, &n)) {
        g_bad_frees++;          /* not released: it is no block of ours */
        return;
    }
    memset(p, POISON_BYTE, n);
    __real_free(p);
}

static void watch(int fail_at)
{
    g_n_blocks  = 0;
    g_requests  = 0;
    g_bad_frees = 0;
    g_fail_at   = fail_at;
    g_watching  = true;
}

static const ds_slot_desc_t SLOTS[1] = {
    { .name = "v", .type = DS_SLOT_TYPE_INT, .identity_role = DS_IDENTITY_KEY },
};

#define RULE "derives_it"

static ds_engine_t *engine_with_two_justifiers(uint64_t *out_fact_id)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (!e) return NULL;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Pkt", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc), "register_schema");
    ds_slot_value_t v[1];
    memset(v, 0, sizeof(v));
    v[0].kind = DS_SLOT_INT;
    v[0].v.i  = 7;
    ds_fact_t *fact = NULL;
    CHECK_OK(ds_engine_assert(e, sc, v, 1, &fact), "assert");
    if (!fact) { ds_engine_free(e); return NULL; }

    /* As a rule firing would: the TMS records the rete id. */
    CHECK_OK(ds_tms_add(&e->rete_engine->tms, 101, RULE, fact->rete_id), "tms 1");
    CHECK_OK(ds_tms_add(&e->rete_engine->tms, 102, RULE, fact->rete_id), "tms 2");
    *out_fact_id = fact->fact_id;
    return e;
}

/* Two justifiers: two array growths and one name, twice. */
#define REQUESTS_OF_TWO_JUSTIFIERS 6

/* The control: with memory, both come back, and the ledger holds exactly what
   the caller now owns. Without this, a call that allocated nothing and reported
   nothing would pass the sweep. */
static void test_with_memory_both_come_back(void)
{
    uint64_t id = 0;
    ds_engine_t *e = engine_with_two_justifiers(&id);
    if (!e) return;

    int64_t  *tts = NULL;
    char    **rns = NULL;
    uint32_t  n   = 0;
    watch(0);
    ds_result_t r = ds_engine_get_justifiers(e, id, &tts, &rns, &n);
    g_watching = false;

    CHECK_OK(r, "get_justifiers with memory");
    CHECK(n == 2, "both justifiers");
    CHECK(g_requests == REQUESTS_OF_TWO_JUSTIFIERS,
          "the sweep below covers every allocation of the call");
    CHECK(g_n_blocks == 2 + (int)n, "two arrays and a name each are the caller's");
    CHECK(g_bad_frees == 0, "nothing freed that was not held");
    for (uint32_t i = 0; i < n; i++) {
        CHECK(strcmp(rns[i], RULE) == 0, "the rule name");
        ds_free(rns[i]);
    }
    CHECK((n == 2 && tts[0] != tts[1]), "two activations, not one twice");
    ds_free(tts);
    ds_free(rns);
    ds_engine_free(e);
}

/* Each allocation fails in its turn: DS_ERR_OOM, nothing handed out, every
   block of the call released exactly once, none read after it went. */
static void test_each_allocation_fails_in_turn(void)
{
    for (int at = 1; at <= REQUESTS_OF_TWO_JUSTIFIERS; at++) {
        uint64_t id = 0;
        ds_engine_t *e = engine_with_two_justifiers(&id);
        if (!e) return;

        int64_t  *tts = (int64_t *)&id;     /* to see them cleared */
        char    **rns = (char **)&id;
        uint32_t  n   = 99;
        watch(at);
        ds_result_t r = ds_engine_get_justifiers(e, id, &tts, &rns, &n);
        g_watching = false;

        char what[64];
        snprintf(what, sizeof what, "allocation %d of the call fails", at);
        if (r.status != DS_ERR_OOM) {
            fprintf(stderr, "FAIL: %s: status=%d\n", what, r.status);
            failures++;
        }
        if (g_requests < at || g_bad_frees != 0 || g_n_blocks != 0
            || tts != NULL || rns != NULL || n != 0) {
            fprintf(stderr,
                    "FAIL: %s: requests=%d bad_frees=%d leaked=%d count=%u\n",
                    what, g_requests, g_bad_frees, g_n_blocks, n);
            failures++;
        }
        ds_engine_free(e);
    }
}

static void test_justifiers_null_arguments(void)
{
    uint64_t id = 0;
    ds_engine_t *e = engine_with_two_justifiers(&id);
    if (!e) return;

    int64_t  *tts = (int64_t *)&id;
    char    **rns = (char **)&id;
    uint32_t  n   = 99;

    CHECK(ds_engine_get_justifiers(NULL, id, &tts, &rns, &n).status == DS_ERR_INVAL,
          "a NULL engine is DS_ERR_INVAL");
    CHECK(tts == NULL && rns == NULL && n == 0,
          "and clears every out-pointer it was given");

    tts = (int64_t *)&id;
    CHECK(ds_engine_get_justifiers(e, id, NULL, &rns, &n).status == DS_ERR_INVAL,
          "a NULL out_timetags is DS_ERR_INVAL");
    CHECK(ds_engine_get_justifiers(e, id, &tts, NULL, &n).status == DS_ERR_INVAL,
          "a NULL out_rule_names is DS_ERR_INVAL");
    CHECK(tts == NULL, "and clears the others");
    CHECK(ds_engine_get_justifiers(e, id, &tts, &rns, NULL).status == DS_ERR_INVAL,
          "a NULL out_count is DS_ERR_INVAL");

    ds_engine_free(e);
}

typedef struct { int nodes; int edges; } net_seen_t;

static void net_node_cb(const char *id, const char *kind, const char *label,
                        const char *filter, uint32_t occ, bool neg, void *user)
{
    (void) id; (void) kind; (void) label; (void) filter; (void) occ; (void) neg;
    ((net_seen_t *) user)->nodes++;
}

static void net_edge_cb(const char *from, const char *to, void *user)
{
    (void) from; (void) to;
    ((net_seen_t *) user)->edges++;
}

/* The network has edges (the control says so), so the walk reaches the call. */
static void test_network_null_edge_cb(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "network: engine_new");
    if (!e) return;

    const ds_schema_t *sc = NULL;
    CHECK_OK(ds_engine_register_schema(e, "A", DS_SCHEMA_LIFECYCLE_LOGICAL, 0,
                                       SLOTS, 1, &sc), "network: register A");
    ds_alfa_atom_t alfa = { .node_id = 9, .schema_name = "A" };
    ds_beta_atom_t beta = { .node_id = 11, .right_alpha_id = 9 };
    ds_term_atom_t term = { .node_id = 13, .parent_beta_id = 11, .rule_name = RULE };
    ds_rete_network_t net = { .alfas = &alfa, .alfa_count = 1,
                              .betas = &beta, .beta_count = 1,
                              .terms = &term, .term_count = 1 };
    CHECK_OK(ds_rete_load_network(e->rete_engine, &net), "network: load");

    net_seen_t both = {0, 0};
    CHECK_OK(ds_engine_rete_network(e, NULL, false, net_node_cb, &both,
                                    net_edge_cb, &both), "network: both callbacks");
    CHECK(both.nodes == 3 && both.edges == 2, "the control: three nodes, two edges");

    net_seen_t nodes_only = {0, 0};
    CHECK_OK(ds_engine_rete_network(e, NULL, false, net_node_cb, &nodes_only,
                                    NULL, NULL), "network: no edge_cb");
    CHECK(nodes_only.nodes == 3, "a NULL edge_cb still enumerates the nodes");

    net_seen_t filtered = {0, 0};
    CHECK_OK(ds_engine_rete_network(e, RULE, false, net_node_cb, &filtered,
                                    NULL, NULL), "network: filtered, no edge_cb");
    CHECK(filtered.nodes == 3, "and the filtered walk, which frees its working set");

    ds_engine_free(e);
}

int main(void)
{
    test_with_memory_both_come_back();
    test_each_allocation_fails_in_turn();
    test_justifiers_null_arguments();
    test_network_null_edge_cb();

    if (failures) {
        fprintf(stderr, "test_ndbg_5_1_justifiers_oom: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_ndbg_5_1_justifiers_oom: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [IARC.3.2.5]
 * test_iarc_3_2_5_rete_create_cleanup — when ds_rete_engine_create
 * fails inside ds_engine_new, the error path reverses whatever succeeded:
 * every allocation ds_engine_new made before it is freed, and the call
 * returns the rete engine's refusal with *out NULL.
 *
 * HOW. A strong ds_* set ([IALC.5]) over libc that counts outstanding
 * allocations, and once armed refuses the first request of exactly
 * sizeof(ds_rete_engine_t): the rete engine's own DS_CALLOC, the first thing
 * ds_rete_engine_create allocates. The refusal's detail, "engine_create:
 * engine", shows it landed there and nowhere else. An engine is made and
 * freed first, so anything libds allocates once per process is counted in
 * the baseline rather than as a leak.
 *
 * WHAT IT CAN AND CANNOT SEE. Before the rete engine, ds_engine_new allocates
 * the engine itself, the schema registry's array and working memory's two
 * tables; the count shows each is freed, and the run checks at least two
 * were made, so the check is not over nothing. It cannot see the order
 * [IARC.3.2.5] gives the teardown (working memory is empty here), nor a
 * missed destroy of a part whose init allocates nothing (the recorder,
 * telemetry). Under the leak lanes (valgrind --leak-check=full, and LSan) any
 * unfreed byte fails as well.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"

static int failures = 0;
#define CHECK(cond, msg)                                                      \
    do { if (!(cond)) {                                                       \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);     \
        failures++; } } while (0)

/* ---- a strong ds_* set ([IALC.5]) ------------------------------------- */

/* libc, counting live allocations; once armed it refuses the first request
   of exactly g_refuse_size bytes, then disarms. */
static size_t g_refuse_size;
static int    g_refused;
static long   g_live;    /* allocations not yet freed */
static long   g_made;    /* allocations made, ever */

static bool refuse(size_t n)
{
    if (g_refuse_size != 0 && n == g_refuse_size) {
        g_refuse_size = 0;
        g_refused++;
        return true;
    }
    return false;
}

static void *counted(void *p)
{
    if (p != NULL) { g_live++; g_made++; }
    return p;
}

void *ds_malloc(size_t n) { return refuse(n) ? NULL : counted(malloc(n)); }
void  ds_free(void *p)
{
    if (p != NULL) g_live--;
    free(p);
}
void *ds_calloc(size_t n, size_t sz)
{
    return (sz != 0 && n > SIZE_MAX / sz) || refuse(n * sz)
         ? NULL : counted(calloc(n, sz));
}
void *ds_realloc(void *p, size_t n)
{
    if (refuse(n)) return NULL;
    void *q = realloc(p, n);
    /* A move keeps the count; only a realloc of NULL makes a new one. */
    return p == NULL ? counted(q) : q;
}
char *ds_strdup(const char *s)
{
    return refuse(strlen(s) + 1) ? NULL : counted(strdup(s));
}
char *ds_strndup(const char *s, size_t n)
{
    return refuse(n + 1) ? NULL : counted(strndup(s, n));
}

/* ---- the control: an engine made and freed leaves nothing ------------- */

static void test_an_engine_made_and_freed_leaves_nothing(void)
{
    const long before = g_live;
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(&cfg, &e);
    CHECK(r.status == DS_OK && e != NULL, "premise: ds_engine_new succeeds");
    if (e != NULL) ds_engine_free(e);
    printf("  control: %ld live before, %ld after\n", before, g_live);
    CHECK(g_live == before, "a made and freed engine leaves nothing live");
}

/* ---- the rete engine refused ------------------------------------------ */

static void test_rete_create_refused_frees_what_was_made(void)
{
    const long before = g_live;
    const long made_before = g_made;

    g_refused = 0;
    g_refuse_size = sizeof(ds_rete_engine_t);
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = (ds_engine_t *)(uintptr_t)1;
    ds_result_t r = ds_engine_new(&cfg, &e);
    g_refuse_size = 0;

    const long made = g_made - made_before;
    printf("  refused: status=%d detail=%s refused=%d; %ld made, "
           "%ld live before, %ld after\n",
           r.status, r.detail ? r.detail : "(null)", g_refused, made,
           before, g_live);

    CHECK(g_refused == 1, "premise: exactly one request was refused");
    CHECK(r.status == DS_ERR_OOM && r.detail != NULL
              && strcmp(r.detail, "engine_create: engine") == 0,
          "premise: the refusal is ds_rete_engine_create's engine allocation");
    CHECK(e == NULL, "*out is NULL on the error path");
    CHECK(made >= 2,
          "premise: the path allocated before the refusal (the engine and the "
          "schema registry at least), so the count below is not over nothing");
    CHECK(g_live == before,
          "every allocation made before the refusal is freed ([IARC.3.2.5])");
}

int main(void)
{
    /* Warm-up: whatever libds allocates once per process lands in the
       baseline the two cases measure from. */
    {
        ds_engine_config_t cfg = {0};
        ds_engine_t *e = NULL;
        if (ds_engine_new(&cfg, &e).status == DS_OK && e != NULL)
            ds_engine_free(e);
    }
    test_an_engine_made_and_freed_leaves_nothing();
    test_rete_create_refused_frees_what_was_made();
    if (failures) {
        fprintf(stderr, "test_iarc_3_2_5_rete_create_cleanup: %d failure(s)\n",
                failures);
        return 1;
    }
    printf("test_iarc_3_2_5_rete_create_cleanup: OK\n");
    return 0;
}

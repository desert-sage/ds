/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The intern table's two assertions fire on a violation and not on legal
 * operations, and the ds.intern.* gauges match its accounting.
 *
 * The death cases fork a child that must die by SIGABRT. An aborting forked
 * child does not compose with valgrind, so this file is out of the valgrind
 * lanes (libds.build's ImplTest `vg` and `leak` columns). Under NDEBUG the
 * death cases are skipped.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>

#include "libds.h"
#include "engine.h"
#include "rete/engine.h"
#include "rete/intern.h"

static int g_fails;
#define CHECK(cond, msg)                                                     \
    do { if (!(cond)) {                                                      \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
        g_fails++;                                                           \
    } } while (0)

/* True iff body(), run in a forked child with stderr silenced, dies by
   SIGABRT. */
static bool aborts_via_assert(void (*body)(void))
{
    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        if (freopen("/dev/null", "w", stderr) == NULL) _exit(3);
        body();
        _exit(0);   /* reached only if NO assertion fired */
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return false;
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

/* A counted entry is born with no refs, so releasing it underflows. */
static void body_release_underflow(void)
{
    ds_rete_engine_t *e = NULL;
    if (ds_rete_engine_create(&e).status != DS_OK) _exit(4);
    const char *p = NULL;
    if (ds_rete_intern_value(e->intern, "orphan", 6, &p).status != DS_OK) _exit(5);
    ds_rete_intern_release(e->intern, p, 6);
    ds_rete_engine_destroy(e);
}

/* A new pinned insert after the table is frozen. */
static void body_pinned_insert_after_freeze(void)
{
    ds_rete_engine_t *e = NULL;
    if (ds_rete_engine_create(&e).status != DS_OK) _exit(4);
    ds_rete_intern_freeze(e->intern);
    const char *p = NULL;
    ds_rete_intern_cstr(e->intern, "pin_after_freeze", &p);
    ds_rete_engine_destroy(e);
}

static void test_release_underflow_aborts(void)
{
    CHECK(aborts_via_assert(body_release_underflow),
          "release underflow must trip the refcount assertion");
}

static void test_pinned_insert_after_freeze_aborts(void)
{
    CHECK(aborts_via_assert(body_pinned_insert_after_freeze),
          "pinned insert after freeze must trip the freeze assertion");
}

/* After the freeze, re-pinning a known string and a counted insert are legal. */
static void test_freeze_allows_legal_ops(void)
{
    ds_rete_engine_t *e = NULL;
    CHECK(ds_rete_engine_create(&e).status == DS_OK, "create engine");
    if (e == NULL) return;
    const char *a = NULL, *b = NULL, *c = NULL;
    CHECK(ds_rete_intern_cstr(e->intern, "known", &a).status == DS_OK, "pin known pre-freeze");
    ds_rete_intern_freeze(e->intern);
    CHECK(ds_rete_intern_cstr(e->intern, "known", &b).status == DS_OK, "re-pin known post-freeze ok");
    CHECK(a == b, "existing pinned string returns same pointer (no new insert)");
    CHECK(ds_rete_intern_value(e->intern, "counted", 7, &c).status == DS_OK,
          "counted insert post-freeze is legal");
    ds_rete_engine_destroy(e);
}

/* The first pump arms the freeze; a second pump interning a new counted value
   does not trip it. */
static void test_second_pump_after_freeze_arm_ok(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;
    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_STRING,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *sc = NULL;
    CHECK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &sd, 1, &sc).status == DS_OK, "reg S");
    ds_slot_value_t v1 = { .kind = DS_SLOT_STRING, .v.s = "one" };
    CHECK(ds_engine_assert(e, sc, &v1, 1, NULL).status == DS_OK, "assert one");
    CHECK(ds_engine_pump(e).status == DS_OK, "first pump (arms freeze)");
    ds_slot_value_t v2 = { .kind = DS_SLOT_STRING, .v.s = "two" };
    CHECK(ds_engine_assert(e, sc, &v2, 1, NULL).status == DS_OK, "assert two post-arm");
    CHECK(ds_engine_pump(e).status == DS_OK, "second pump post-arm does not trip");
    ds_engine_free(e);
}

struct si3_capture {
    double entries, bytes, pinned, arena;
    bool got_entries, got_bytes, got_pinned, got_arena;
};

static ds_result_t si3_cb(ds_engine_t *engine, const ds_metric_t *m, void *user)
{
    (void)engine;
    struct si3_capture *c = user;
    if      (strcmp(m->name, "ds.intern.entries") == 0)        { c->entries = m->value; c->got_entries = true; }
    else if (strcmp(m->name, "ds.intern.bytes") == 0)          { c->bytes   = m->value; c->got_bytes   = true; }
    else if (strcmp(m->name, "ds.intern.pinned_entries") == 0) { c->pinned  = m->value; c->got_pinned  = true; }
    else if (strcmp(m->name, "ds.intern.arena_high_water_bytes") == 0) { c->arena = m->value; c->got_arena = true; }
    return DS_OK_R;
}

/* The ds.intern.* gauges ([RMET.4]) equal the table's accounting. With no
   rule, the pump-entry snapshot equals the post-pump accessors. */
static void test_si3_gauge_accuracy(void)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK(ds_engine_new(&cfg, &e).status == DS_OK, "engine_new");
    if (e == NULL) return;

    struct si3_capture cap = {0};
    CHECK(ds_engine_set_metric_callback(e, si3_cb, &cap).status == DS_OK, "set metric cb");

    ds_slot_desc_t sd = { .name = "v", .type = DS_SLOT_TYPE_STRING,
                          .identity_role = DS_IDENTITY_KEY };
    const ds_schema_t *sc = NULL;
    CHECK(ds_engine_register_schema(e, "S", DS_SCHEMA_LIFECYCLE_LOGICAL,
                                    0, &sd, 1, &sc).status == DS_OK, "reg S");
    ds_slot_value_t v1 = { .kind = DS_SLOT_STRING, .v.s = "alpha" };
    ds_slot_value_t v2 = { .kind = DS_SLOT_STRING, .v.s = "beta" };
    ds_engine_assert(e, sc, &v1, 1, NULL);
    ds_engine_assert(e, sc, &v2, 1, NULL);
    CHECK(ds_engine_pump(e).status == DS_OK, "pump emits gauges");

    CHECK(cap.got_entries && cap.got_bytes && cap.got_pinned && cap.got_arena,
          "all four ds.intern.* gauges emitted");

    size_t ic = 0, ib = 0;
    ds_rete_intern_mem(e->rete_engine->intern, &ic, &ib, NULL);
    size_t pin = ds_rete_intern_pinned_count(e->rete_engine->intern);
    uint64_t hw = e->rete_engine->comp_arena.high_water;

    CHECK(cap.entries == (double)ic,  "entries gauge matches ds_rete_intern_mem count");
    CHECK(cap.bytes   == (double)ib,  "bytes gauge matches string_bytes");
    CHECK(cap.pinned  == (double)pin, "pinned gauge matches pinned_count");
    CHECK(cap.arena   == (double)hw,  "arena gauge matches comp_arena.high_water");

    ds_engine_free(e);
}

int main(void)
{
    g_fails = 0;

#ifdef NDEBUG
    printf("  skip: death-tests need an asserts-on build (NDEBUG set)\n");
#else
    test_release_underflow_aborts();
    test_pinned_insert_after_freeze_aborts();
#endif
    test_freeze_allows_legal_ops();
    test_second_pump_after_freeze_arm_ok();
    test_si3_gauge_accuracy();

    if (g_fails) { printf("test_intern_enforcement: %d FAILURES\n", g_fails); return 1; }
    printf("test_intern_enforcement: ALL PASSED\n");
    return 0;
}

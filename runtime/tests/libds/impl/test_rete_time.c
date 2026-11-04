/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The ns-native Time path, DS_RETE_VAL_TIME end-to-end through
 * ds_rete_eval():
 *   (a) now() returns a TIME (utc_ns = engine clock, tz offset 0) per
 *       [LTIM.2.1.1]/[LTIM.2.1.2]; Time ordering/equality operate on
 *       utc_ns and interoperate with Int ([LTIM.1.1.2]/[LTIM.5.2]) so
 *       now()-vs-Int rules keep firing; Time arithmetic ([LTIM.4.1]):
 *       Time +/- Duration -> Time (offset preserved), Time - Time ->
 *       Duration; Time+Time / Time*Int are type errors.
 *   (b) utc(t) zeroes the offset ([LTIM.3.1]); local(t, tz) resolves the
 *       offset through the zone's `TimeZoneOffset` facts at the instant
 *       ([LTIM.3.2]/[LTIM.10.7]), "UTC" through none ([LTIM.10.8]); a zone
 *       no fact answers is a hard error, never a silent UTC fallback
 *       ([LTIM.10.5]). The zone index itself, and the host door's refusal
 *       of a malformed row ([LTIM.10.9]).
 *   (c) monotonic_ns() returns a ns Duration from the MONOTONIC clock — the
 *       per-fire snapshot, else the clock_fn ([LTIM.2.2.1]); now() reads the
 *       WALL clock and only it ([LTIM.2.8.3]), and faults while the wall
 *       clock has no value.
 *   (d) to_string over the v1 format-ids — iso8601 (offset + ns fraction)
 *       and epoch_{s,ms,us,ns} (floor toward -inf) ([LTIM.8]); an unknown
 *       format faults. DS reads no temporal text: calendar.time and
 *       calendar.date build a value from its fields ([LTIM.14]).
 *   (e) an out-of-range Time is never wrapped (LTIM.1.1.5): a calendar call
 *       or a shift producing one is NOT_REPRESENTABLE.
 *
 * Both clocks are pinned -- the monotonic via ctx.fire_now_ns, the wall via
 * a fixed wall_fn -- so every assertion is exact.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "builtin_fn.h"
#include "builtins.h"
#include "engine.h"
#include "rete/adapters.h"
#include "rete/engine.h"
#include "rete/eval.h"
#include "rete/expr.h"
#include "rete/intern.h"
#include "rete/schema_reg.h"
#include "rete/val.h"
#include "rete/wm_rete.h"

static int fail(const char *msg) { fprintf(stderr, "FAIL: %s\n", msg); return 1; }

/* [LTIM.10.6]-[LTIM.10.8]: a zone resolves through the live facts of
   the built-in `TimeZoneOffset`, which the loader registers in every artefact.
   A bare rete engine gets the schema by hand, with the slots and markers
   [LIMP.12.2] declares, and its rows go in as the host's door puts them, as
   ds_rete_wm_assert. Returns the schema id, or UINT16_MAX. */
static uint16_t tzo_register(ds_rete_engine_t *e)
{
    ds_rete_slot_desc_t s[4] = {
        { .name = "zone",        .type = DS_RETE_VAL_STR, .is_key = true,
          .is_marked = true },
        { .name = "valid_from",  .type = DS_RETE_VAL_INT, .is_key = true,
          .is_marked = true, .time = true },
        { .name = "valid_until", .type = DS_RETE_VAL_INT, .is_marked = true,
          .time = true },
        { .name = "offset_s",    .type = DS_RETE_VAL_INT, .is_marked = true },
    };
    ds_rete_schema_t *out = NULL;
    if (ds_rete_schema_register(e, "TimeZoneOffset", DS_RETE_SCOPE_AMBIENT, 0,
                                s, 4, &out).status != DS_OK || out == NULL)
        return UINT16_MAX;
    return out->id;
}

/* Assert one row; the fact, or NULL. */
static ds_rete_fact_t *tzo_row(ds_rete_engine_t *e, uint16_t sid,
                               const char *zone, int64_t from, int64_t until,
                               int64_t off_s)
{
    const char *z = NULL;
    if (ds_rete_intern_value_cstr(e->intern, zone, &z).status != DS_OK)
        return NULL;
    ds_rete_val_t v[4] = {
        ds_rete_val_str(z, (uint32_t)strlen(zone)),
        ds_rete_val_int(from), ds_rete_val_int(until), ds_rete_val_int(off_s),
    };
    ds_rete_fact_t *f = NULL;
    if (ds_rete_wm_assert(e, sid, v, &f).status != DS_OK) return NULL;
    return f;
}

/* The two zones most tests read, each one offset over the longest period a
   row can state, [INT64_MIN, INT64_MAX). "UTC" takes no row ([LTIM.10.8]).
   Nonzero if a row was refused. */
static int install_zones(ds_rete_engine_t *e)
{
    uint16_t sid = tzo_register(e);
    if (sid == UINT16_MAX
        || !tzo_row(e, sid, "America/Los_Angeles", INT64_MIN, INT64_MAX,
                    -8 * 3600)
        || !tzo_row(e, sid, "Asia/Tokyo", INT64_MIN, INT64_MAX, 9 * 3600)) {
        fprintf(stderr, "FAIL: install_zones\n");
        return 1;
    }
    return 0;
}

/* ds_rete_tz_resolve over a C string; the offset, or INT32_MIN for none. */
static int32_t resolve(const ds_rete_engine_t *e, const char *zone, int64_t t)
{
    int32_t off = 0;
    return ds_rete_tz_resolve(e, zone, (uint32_t)strlen(zone), t, &off)
         ? off : INT32_MIN;
}

static ds_rete_expr_t *lit_int(int64_t i)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_INT);
    e->lit_int = i;
    return e;
}
static ds_rete_expr_t *now_expr(void)
{
    return ds_rete_expr_alloc(DS_RETE_EXPR_NOW);
}
static ds_rete_expr_t *binop(ds_rete_binop_t op,
                             ds_rete_expr_t *l, ds_rete_expr_t *r)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_BINOP);
    e->binop.op = op; e->binop.left = l; e->binop.right = r;
    return e;
}

static const char *istr(ds_rete_engine_t *e, const char *s)
{
    const char *p = NULL; ds_rete_intern_cstr(e->intern, s, &p); return p;
}
static ds_rete_expr_t *lit_str(ds_rete_engine_t *e, const char *s)
{
    ds_rete_expr_t *x = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_STR);
    x->lit_str = istr(e, s);
    return x;
}
static ds_rete_expr_t *call_n(ds_rete_engine_t *e, ds_builtin_fn_t op,
                              ds_rete_expr_t *a0, ds_rete_expr_t *a1)
{
    (void) e;
    ds_rete_expr_t *c = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    c->call.op        = op;
    c->call.arg_count = a1 ? 2 : 1;
    c->call.args      = calloc(c->call.arg_count, sizeof(ds_rete_expr_t *));
    c->call.args[0]   = a0;
    if (a1) c->call.args[1] = a1;
    return c;
}
static ds_rete_expr_t *call0(ds_rete_engine_t *e, ds_builtin_fn_t op)
{
    (void) e;
    ds_rete_expr_t *c = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    c->call.op        = op;
    c->call.arg_count = 0;
    c->call.args      = NULL;
    return c;
}

/* Stub engine clock for the monotonic test. */
static int64_t g_fixed_clock_ns;
static int64_t fixed_clock_fn(void *ctx) { (void)ctx; return g_fixed_clock_ns; }

/* Stub WALL clock ([LTIM.2.8.3]): now() reads this, and only this. */
static int64_t g_fixed_wall_ns;
static bool fixed_wall_fn(void *ctx, int64_t *out)
{
    (void)ctx; *out = g_fixed_wall_ns; return true;
}
/* A wall clock with no value: a mock clock before wall_clock_set. */
static bool unset_wall_fn(void *ctx, int64_t *out)
{
    (void)ctx; (void)out; return false;
}

typedef struct { ds_rete_engine_t *engine; } Ctx;

static Ctx make_ctx(void)
{
    Ctx c = {0};
    ds_rete_engine_create(&c.engine);
    return c;
}
static void destroy_ctx(Ctx *c) { ds_rete_engine_destroy(c->engine); }

/* Eval context with a pinned now() instant. Both clocks read now_ns: the
   wall clock, which now() reads, and the monotonic per-fire snapshot, which
   monotonic_ns() reads -- so a test of either reads exactly now_ns. */
static ds_rete_eval_ctx_t pinned_ctx(Ctx *c, int64_t now_ns)
{
    ds_rete_eval_ctx_t ctx = {0};
    ctx.engine         = c->engine;
    ctx.fire_now_ns    = now_ns;
    ctx.fire_now_valid = true;  /* occupancy is the FLAG — any now_ns, incl. 0 */
    c->engine->wall_fn = fixed_wall_fn;
    g_fixed_wall_ns    = now_ns;
    return ctx;
}

/* A clock that ADVANCES on every call. The per-fire snapshot is read once,
   so two now() reads inside one fire must agree no matter what this does —
   which is the only way to tell a working cache from a broken one. A fixed
   clock cannot: it returns the same value whether or not the cache is used. */
static int64_t g_advancing_ns;
static int64_t advancing_clock_fn(void *ctx) { (void)ctx; return g_advancing_ns++; }

/* Evaluate `e`, free the tree, return the value. */
static ds_rete_val_t eval1(ds_rete_eval_ctx_t *ctx, ds_rete_expr_t *e)
{
    /* Each eval1 answers for itself: `ctx->faulted` is sticky, and these
       tests reuse one ctx across several evaluations. */
    ctx->faulted = false;
    ds_rete_val_t v = ds_rete_eval(ctx, e);
    ds_rete_expr_free_tree(e);
    return v;
}

/* now() is a zoned Time: utc_ns = clock, offset 0 (UTC). */
static int test_now_is_time(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1700000000000000000LL);
    ds_rete_val_t v = eval1(&ctx, now_expr());
    int rc = 0;
    if (v.kind != DS_RETE_VAL_TIME)             rc = fail("now() kind != TIME");
    else if (v.time.utc_ns != 1700000000000000000LL)
                                                rc = fail("now() utc_ns");
    else if (v.time.tz_offset_s != 0)           rc = fail("now() offset != 0");
    destroy_ctx(&c);
    return rc;
}

/* [IRET.25.4.1]: the per-fire snapshot is read once, and a snapshot of 0 is
   a snapshot (`dstest` starts every relative-mode case at 0). An advancing
   clock makes two reads disagree if the snapshot is bypassed; a fixed clock
   could not.

   The snapshot is the MONOTONIC clock's, so it is monotonic_ns() that reads
   it ([LTIM.2.8.2]); now() reads the wall clock ([LTIM.2.8.3]). */
static int test_fire_snapshot_at_epoch_is_a_snapshot(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    c.engine->clock_fn = advancing_clock_fn;
    g_advancing_ns     = 0;      /* the first clock read is 0 */

    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 0);
    ds_rete_val_t a = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));
    ds_rete_val_t b = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));

    int rc = 0;
    if (a.kind != DS_RETE_VAL_INT || b.kind != DS_RETE_VAL_INT)
        rc = fail("monotonic_ns() should be a Duration (Int) on both reads");
    else if (a.i != 0)
        rc = fail("monotonic_ns() should return the pinned snapshot 0, not a clock read");
    else if (a.i != b.i)
        rc = fail("two monotonic_ns() reads in one fire disagree — the snapshot was bypassed");

    destroy_ctx(&c);
    return rc;
}

/* The same distinction on the engine's RT per-cycle cache: a cached reading of
   0 is a reading. Occupancy is `cached_clock_valid`, not `cached_clock_ns`. */
static int test_rt_clock_cache_at_epoch_is_populated(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    c.engine->clock_fn = advancing_clock_fn;
    g_advancing_ns     = 0;
    c.engine->rt_mode  = true;

    ds_rete_refresh_clock_cache(c.engine);   /* caches 0, marks it valid */

    ds_rete_eval_ctx_t ctx = {0};
    ctx.engine = c.engine;                   /* no per-fire snapshot */
    ds_rete_val_t v = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));

    int rc = 0;
    if (v.kind != DS_RETE_VAL_INT)
        rc = fail("monotonic_ns() kind != Int off the RT cache");
    else if (v.i != 0)
        rc = fail("RT clock cache holding 0 read as empty — clock was re-read");

    destroy_ctx(&c);
    return rc;
}

/* [LTIM.2.8.3]: now() reads the WALL clock and nothing else, and
   monotonic_ns() the MONOTONIC clock and nothing else. The two are pinned
   to DIFFERENT values, so a read wired to the wrong clock goes red -- with
   one value for both, a swap would pass. */
static int test_now_reads_wall_not_monotonic(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    ds_register_builtins(c.engine);              /* FN_NOW lives in builtins.c */
    c.engine->clock_fn = fixed_clock_fn;
    g_fixed_clock_ns   = 5000LL;                      /* monotonic */
    c.engine->wall_fn  = fixed_wall_fn;
    g_fixed_wall_ns    = 1700000000000000000LL;       /* wall, 2023-11-14 */

    ds_rete_eval_ctx_t ctx = {0};
    ctx.engine = c.engine;                            /* no snapshot */
    ds_rete_val_t n = eval1(&ctx, now_expr());
    ds_rete_val_t m = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));
    ds_rete_val_t f = eval1(&ctx, call0(c.engine, DS_FN_NOW));

    int rc = 0;
    if (n.kind != DS_RETE_VAL_TIME || n.time.utc_ns != 1700000000000000000LL)
        rc = fail("now() should read the wall clock");
    else if (m.kind != DS_RETE_VAL_INT || m.i != 5000LL)
        rc = fail("monotonic_ns() should read the monotonic clock");
    else if (f.kind != DS_RETE_VAL_TIME || f.time.utc_ns != 1700000000000000000LL)
        rc = fail("FN_NOW should read the wall clock, as the NOW node does");
    destroy_ctx(&c);
    return rc;
}

/* A wall clock with no value (a mock clock before wall_clock_set) has no
   now() to give: both spellings fault, and monotonic_ns() is unaffected. */
static int test_now_faults_while_wall_unset(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    ds_register_builtins(c.engine);              /* FN_NOW lives in builtins.c */
    c.engine->clock_fn = fixed_clock_fn;
    g_fixed_clock_ns   = 7LL;
    c.engine->wall_fn  = unset_wall_fn;

    ds_rete_eval_ctx_t ctx = {0};
    ctx.engine = c.engine;
    int rc = 0;
    (void)eval1(&ctx, now_expr());
    if (!ctx.faulted) rc = fail("now() with no wall value should fault");
    if (!rc) {
        (void)eval1(&ctx, call0(c.engine, DS_FN_NOW));
        if (!ctx.faulted) rc = fail("FN_NOW with no wall value should fault");
    }
    if (!rc) {
        ds_rete_val_t m = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));
        if (ctx.faulted || m.kind != DS_RETE_VAL_INT || m.i != 7LL)
            rc = fail("monotonic_ns() should not depend on the wall clock");
    }
    destroy_ctx(&c);
    return rc;
}

/* Time vs Int compares on utc_ns (the now()-vs-Int conformance pattern). */
static int test_time_int_compare(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 6000000000LL); /* 6_s */
    int rc = 0;
    ds_rete_val_t v;

    v = eval1(&ctx, binop(DS_RETE_BINOP_GT, now_expr(), lit_int(5000000000LL)));
    if (v.kind != DS_RETE_VAL_BOOL || !v.b) rc = fail("now() > 5s should be true");

    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_LT, now_expr(),
                              lit_int(5000000000LL)));
        if (v.kind != DS_RETE_VAL_BOOL || v.b) rc = fail("now() < 5s should be false");
    }
    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_EQ, now_expr(),
                              lit_int(6000000000LL)));
        if (v.kind != DS_RETE_VAL_BOOL || !v.b) rc = fail("now() == 6s");
    }
    destroy_ctx(&c);
    return rc;
}

/* Time vs Time compares on utc_ns. */
static int test_time_time_compare(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 100LL);
    /* now() == now() within one pinned context. */
    ds_rete_val_t v = eval1(&ctx, binop(DS_RETE_BINOP_EQ,
                                        now_expr(), now_expr()));
    int rc = (v.kind == DS_RETE_VAL_BOOL && v.b) ? 0 : fail("now() == now()");
    destroy_ctx(&c);
    return rc;
}

/* Time +/- Duration -> Time (offset preserved); Time - Time -> Duration. */
static int test_time_arith(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1000LL);
    int rc = 0;
    ds_rete_val_t v;

    /* Time + Duration -> Time */
    v = eval1(&ctx, binop(DS_RETE_BINOP_ADD, now_expr(), lit_int(500)));
    if (v.kind != DS_RETE_VAL_TIME || v.time.utc_ns != 1500 ||
        v.time.tz_offset_s != 0)
        rc = fail("Time + Duration -> Time(1500,0)");

    /* Duration + Time -> Time (commutative) */
    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_ADD, lit_int(500), now_expr()));
        if (v.kind != DS_RETE_VAL_TIME || v.time.utc_ns != 1500)
            rc = fail("Duration + Time -> Time(1500)");
    }
    /* Time - Duration -> Time */
    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_SUB, now_expr(), lit_int(300)));
        if (v.kind != DS_RETE_VAL_TIME || v.time.utc_ns != 700)
            rc = fail("Time - Duration -> Time(700)");
    }
    /* Time - Time -> Duration (Int) */
    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_SUB, now_expr(), now_expr()));
        if (v.kind != DS_RETE_VAL_INT || v.i != 0)
            rc = fail("Time - Time -> Duration(0)");
    }
    destroy_ctx(&c);
    return rc;
}

/* Time arithmetic with no meaning faults. */
static int test_time_arith_errors(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1000LL);
    int rc = 0;
    ds_rete_val_t v;

    /* Time + Time: can't add two instants. */
    v = eval1(&ctx, binop(DS_RETE_BINOP_ADD, now_expr(), now_expr()));
    if (!ctx.faulted) rc = fail("Time + Time should be ERR");

    /* Time * Int: nonsensical. */
    if (!rc) {
        v = eval1(&ctx, binop(DS_RETE_BINOP_MUL, now_expr(), lit_int(2)));
        if (!ctx.faulted) rc = fail("Time * Int should be ERR");
    }
    destroy_ctx(&c);
    return rc;
}

/* utc(t) zeroes the offset; the instant is unchanged ([LTIM.3.1]). */
static int test_utc(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1234567890LL);
    ds_rete_val_t v = eval1(&ctx, call_n(c.engine, DS_FN_UTC, now_expr(), NULL));
    int rc = 0;
    if (v.kind != DS_RETE_VAL_TIME || v.time.utc_ns != 1234567890LL ||
        v.time.tz_offset_s != 0)
        rc = fail("utc(now()) -> Time(n,0)");
    destroy_ctx(&c);
    return rc;
}

/* local(t, tz) resolves the offset through the zone's facts; the instant is
   unchanged and the offset is fixed ([LTIM.3.2]/[LTIM.10.7]). Which fact
   answers at which instant is test_ltim_10_7__resolution's. */
static int test_local_resolves(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1000000000LL);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c.engine, DS_FN_LOCAL, now_expr(),
               lit_str(c.engine, "America/Los_Angeles")));
    if (v.kind != DS_RETE_VAL_TIME)             rc = fail("local() -> Time");
    else if (v.time.utc_ns != 1000000000LL)     rc = fail("local() utc_ns unchanged");
    else if (v.time.tz_offset_s != -8 * 3600)   rc = fail("local() offset = -28800");
    destroy_ctx(&c);
    return rc;
}

/* @spec [LTIM.10.7] -- the fact with the greatest valid_from not after t
   answers while its valid_until is after t; otherwise, and with none, the
   zone has no answer. Arrival order does not matter, the facts of a zone may
   overlap, and the resolution is the index's alone: rete/wm_rete.c's AVL
   tree per zone, kept by wm_insert and wm_remove. Driven straight through
   ds_rete_tz_resolve, which every zone-reading builtin calls. */
static int test_ltim_10_7__resolution(void)
{
    int rc = 0;
    const char *Z = "Europe/Berlin";

    /* Two engines, the same rows in opposite orders. */
    for (int order = 0; order < 2; order++) {
        Ctx c = make_ctx();
        uint16_t sid = tzo_register(c.engine);
        ds_rete_fact_t *wide = NULL, *narrow = NULL;
        if (order == 0) {
            wide   = tzo_row(c.engine, sid, Z, 0, 1000, 60);
            narrow = tzo_row(c.engine, sid, Z, 500, 600, 120);
        } else {
            narrow = tzo_row(c.engine, sid, Z, 500, 600, 120);
            wide   = tzo_row(c.engine, sid, Z, 0, 1000, 60);
        }
        if (!wide || !narrow) { rc |= fail("assert the two rows"); }
        if (resolve(c.engine, Z, -1) != INT32_MIN)
            rc |= fail("before every valid_from: no answer");
        if (resolve(c.engine, Z, 0) != 60)
            rc |= fail("valid_from is inclusive");
        if (resolve(c.engine, Z, 499) != 60)
            rc |= fail("499: the wide row");
        if (resolve(c.engine, Z, 550) != 120)
            rc |= fail("550: the greatest valid_from not after t answers");
        if (resolve(c.engine, Z, 599) != 120)
            rc |= fail("599: still the narrow row");
        /* The floor is the narrow row, whose period has ended: no answer,
           though the wide row covers 700 ([LTIM.10.7]'s "otherwise"). */
        if (resolve(c.engine, Z, 700) != INT32_MIN)
            rc |= fail("700: the floor's period ended, so no answer");
        if (resolve(c.engine, Z, 1000) != INT32_MIN)
            rc |= fail("valid_until is exclusive");
        /* Byte for byte: no case folding, no normalisation ([LTIM.10.6]). */
        if (resolve(c.engine, "europe/berlin", 550) != INT32_MIN)
            rc |= fail("the zone compares byte for byte");
        /* Retract the narrow row: the wide one answers across it again. */
        if (narrow && ds_rete_wm_retract(c.engine, narrow).status != DS_OK)
            rc |= fail("retract the narrow row");
        if (resolve(c.engine, Z, 550) != 60 || resolve(c.engine, Z, 700) != 60)
            rc |= fail("a retracted row leaves the index");
        /* An upsert of the identity (zone, valid_from) replaces the row. */
        ds_rete_fact_t *up = tzo_row(c.engine, sid, Z, 0, 2000, 90);
        if (!up) rc |= fail("upsert (zone, 0)");
        if (resolve(c.engine, Z, 1500) != 90 || resolve(c.engine, Z, 100) != 90)
            rc |= fail("the upserted row answers with its own values");
        if (ds_rete_tz_zone_count(c.engine) != 1)
            rc |= fail("the index holds the one zone");
        /* Its last row gone, the zone has no answer, and leaves the map. */
        if (up && ds_rete_wm_retract(c.engine, up).status != DS_OK)
            rc |= fail("retract the last row");
        if (resolve(c.engine, Z, 100) != INT32_MIN)
            rc |= fail("a zone with no row has no answer");
        if (ds_rete_tz_zone_count(c.engine) != 0)
            rc |= fail("a zone leaves the index with its last row");
        destroy_ctx(&c);
    }

    /* 1024 rows of one zone, asserted in a scrambled order (7919 is prime,
       so i -> 7919 i mod 1024 is a permutation): row k covers [10k, 10k+10)
       with offset k. Then every other row is retracted. Each instant must
       read its own row, or none once that row is gone, whatever rotations
       the inserts and deletes made. */
    {
        enum { N = 1024 };
        static ds_rete_fact_t *rows[N];
        Ctx c = make_ctx();
        uint16_t sid = tzo_register(c.engine);
        for (int i = 0; i < N; i++) {
            int k = (int)(((int64_t)i * 7919) % N);
            rows[k] = tzo_row(c.engine, sid, Z, 10LL * k, 10LL * k + 10, k);
            if (!rows[k]) { rc |= fail("assert a row of 1024"); break; }
        }
        for (int k = 0; k < N; k++)
            if (resolve(c.engine, Z, 10LL * k + 5) != k) {
                rc |= fail("each of 1024 rows answers its own period");
                break;
            }
        for (int k = 0; k < N; k += 2)
            if (rows[k] && ds_rete_wm_retract(c.engine, rows[k]).status != DS_OK)
                rc |= fail("retract a row of 1024");
        for (int k = 0; k < N; k++) {
            int32_t want = (k % 2) ? k : INT32_MIN;
            if (resolve(c.engine, Z, 10LL * k + 5) != want) {
                rc |= fail("after half are retracted, each instant reads its "
                           "own row or none");
                break;
            }
        }
        destroy_ctx(&c);
    }
    return rc;
}

/* @spec [LTIM.10.8] -- exactly "UTC" is offset 0 with no fact consulted, on
   an engine with no `TimeZoneOffset` schema at all; any other zone, "utc"
   included, faults there. */
static int test_ltim_10_8__utc_needs_no_row(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1000LL);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c.engine, DS_FN_LOCAL, now_expr(), lit_str(c.engine, "UTC")));
    if (ctx.faulted || v.kind != DS_RETE_VAL_TIME || v.time.utc_ns != 1000LL
        || v.time.tz_offset_s != 0)
        rc = fail("local(t, \"UTC\") is offset 0 with no row");
    const char *others[] = { "utc", "UTC ", "Asia/Tokyo" };
    for (unsigned i = 0; i < sizeof others / sizeof others[0]; i++) {
        (void)eval1(&ctx, call_n(c.engine, DS_FN_LOCAL, now_expr(),
                                 lit_str(c.engine, others[i])));
        if (!ctx.faulted) {
            fprintf(stderr, "  zone \"%s\"\n", others[i]);
            rc = fail("only exactly \"UTC\" answers with no row");
        }
    }
    destroy_ctx(&c);
    return rc;
}

/* @spec [LTIM.10.9] -- the host's door refuses a malformed row with
   DS_ERR_INVAL and asserts nothing; a well-formed one at each bound, an
   overlapping one and the zone "utc" are admitted. Then the index across
   ds_engine_clone ([NLFC.8.1]): the clone resolves from its own facts, which
   ds_rete_wm_clone indexes again under the clone's own interned zone, so it
   still answers once the source is freed, and a row retracted on one engine
   leaves the other's answer alone. */
static ds_rete_val_t eval_local_on(ds_engine_t *pub, int64_t now_ns,
                                   const char *tz, bool *faulted)
{
    Ctx c = { .engine = pub->rete_engine };
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, now_ns);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c.engine, DS_FN_LOCAL, now_expr(), lit_str(c.engine, tz)));
    *faulted = ctx.faulted;
    return v;
}

static const ds_schema_t *pub_tzo(ds_engine_t *e)
{
    const ds_slot_desc_t sd[4] = {
        { .name = "zone",        .type = DS_SLOT_TYPE_STRING,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "valid_from",  .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_KEY },
        { .name = "valid_until", .type = DS_SLOT_TYPE_TIME,
          .identity_role = DS_IDENTITY_MUTABLE },
        { .name = "offset_s",    .type = DS_SLOT_TYPE_INT,
          .identity_role = DS_IDENTITY_MUTABLE },
    };
    const ds_schema_t *s = NULL;
    if (ds_engine_register_schema(e, "TimeZoneOffset",
                                  DS_SCHEMA_LIFECYCLE_LOGICAL, 0, sd, 4,
                                  &s).status != DS_OK)
        return NULL;
    return s;
}

static ds_status_t pub_row(ds_engine_t *e, const ds_schema_t *s,
                           const char *zone, int64_t from, int64_t until,
                           int64_t off_s, ds_fact_t **out)
{
    ds_slot_value_t v[4] = {
        { .kind = DS_SLOT_STRING, .v.s = zone },
        { .kind = DS_SLOT_INT,    .v.i = from },
        { .kind = DS_SLOT_INT,    .v.i = until },
        { .kind = DS_SLOT_INT,    .v.i = off_s },
    };
    return ds_engine_assert(e, s, v, 4, out).status;
}

static int test_ltim_10_9__host_door_and_clone(void)
{
    ds_engine_t *src = NULL, *clone = NULL;
    ds_engine_config_t cfg = {0};
    if (ds_engine_new(&cfg, &src).status != DS_OK || src == NULL)
        return fail("ds_engine_new");
    int rc = 0;
    bool faulted = false;
    const ds_schema_t *s = pub_tzo(src);
    if (s == NULL) { ds_engine_free(src); return fail("register TimeZoneOffset"); }

    const int64_t H18 = 64800;
    struct { const char *zone; int64_t from, until, off; const char *why; }
    refused[] = {
        { "Asia/Tokyo", 100, 100, 0,       "valid_from == valid_until" },
        { "Asia/Tokyo", 200, 100, 0,       "valid_from after valid_until" },
        { "Asia/Tokyo", 0,   100, H18 + 1, "offset_s 64801" },
        { "Asia/Tokyo", 0,   100, -H18 - 1, "offset_s -64801" },
        { "UTC",        0,   100, 0,       "the zone \"UTC\"" },
    };
    for (unsigned i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        size_t before = 0, after = 0;
        ds_engine_fact_count(src, &before);
        if (pub_row(src, s, refused[i].zone, refused[i].from, refused[i].until,
                    refused[i].off, NULL) != DS_ERR_INVAL) {
            fprintf(stderr, "  %s\n", refused[i].why);
            rc = fail("a malformed TimeZoneOffset row is DS_ERR_INVAL");
        }
        ds_engine_fact_count(src, &after);
        if (after != before) rc = fail("and asserts nothing");
    }
    /* The overlapping row is [10000, 20000): before it, at 5000, the wide row
       is the floor and answers; inside it, at 15000, it answers. */
    ds_fact_t *tokyo = NULL;
    if (pub_row(src, s, "Asia/Tokyo", 0, INT64_MAX, 9 * 3600, &tokyo) != DS_OK
        || pub_row(src, s, "Asia/Tokyo", 10000, 20000, H18, NULL) != DS_OK
        || pub_row(src, s, "utc", 0, 1, -H18, NULL) != DS_OK)
        rc = fail("rows at each bound, overlapping and \"utc\" are admitted");

    ds_rete_val_t v = eval_local_on(src, 5000LL, "Asia/Tokyo", &faulted);
    if (faulted || v.kind != DS_RETE_VAL_TIME || v.time.tz_offset_s != 9 * 3600)
        rc = fail("a host-asserted row resolves");

    if (ds_engine_clone(src, &clone).status != DS_OK || clone == NULL) {
        ds_engine_free(src);
        return fail("clone");
    }
    v = eval_local_on(clone, 15000LL, "Asia/Tokyo", &faulted);
    if (faulted || v.kind != DS_RETE_VAL_TIME || v.time.tz_offset_s != H18)
        rc = fail("the clone resolves from its own facts");

    /* A row retracted on the source leaves the clone's answer alone. */
    if (ds_engine_retract(src, tokyo).status != DS_OK)
        rc = fail("retract on the source");
    (void)eval_local_on(src, 5000LL, "Asia/Tokyo", &faulted);
    if (!faulted) rc = fail("the source's retracted row no longer answers");
    v = eval_local_on(clone, 5000LL, "Asia/Tokyo", &faulted);
    if (faulted || v.kind != DS_RETE_VAL_TIME || v.time.tz_offset_s != 9 * 3600)
        rc = fail("the clone's row stands when the source's is retracted");
    ds_engine_free(src);
    v = eval_local_on(clone, 5000LL, "Asia/Tokyo", &faulted);
    if (faulted || v.kind != DS_RETE_VAL_TIME || v.time.tz_offset_s != 9 * 3600)
        rc = fail("the clone still resolves, the source retracted and freed");
    ds_engine_free(clone);
    return rc;
}

/* [LTIM.10.5.3]: a zone no fact answers is a ComputationError of kind
   DOMAIN, whatever supplied the zone -- and the engine continues.

   The path: ds_rete_tz_resolve's false, in each of the three call sites in
   rete/adapters.c -- adapter_ds_local (FN_LOCAL), adapter_ds_time_date
   (FN_TIME_DATE) and time_component (FN_HOUR) -- each with a literal zone,
   and each again with the CALL node marked json_tainted, which is the zone
   read from data; with rows for another zone, and with no `TimeZoneOffset`
   schema at all. Two observations per case:
     - the cause, read by evaluating under ds_rete_eval_holding, which keeps
       the fault the builtin raised instead of recording it: DOMAIN;
     - the recorded fault, from a plain evaluation on the public engine: the
       engine is not halted afterwards ([NCBK.2.9]'s latch, read through
       ds_engine_halted), which is what "the engine continues" means here.
   The rule-level pin is the conformance fixture
   logical/LTIM.10.7_miss_is_domain. */
static int refused_zone_case(ds_builtin_fn_t op, const char *label,
                             bool tainted, bool rows)
{
    ds_engine_t *pub = NULL;
    ds_engine_config_t cfg = {0};
    int rc = 0;
    char msg[160];
    if (ds_engine_new(&cfg, &pub).status != DS_OK || pub == NULL)
        return fail("ds_engine_new (refused zone)");
    if (rows) {
        const ds_schema_t *s = pub_tzo(pub);
        if (s == NULL || pub_row(pub, s, "Asia/Tokyo", INT64_MIN, INT64_MAX,
                                 9 * 3600, NULL) != DS_OK) {
            ds_engine_free(pub);
            return fail("rows for Asia/Tokyo (refused zone)");
        }
    }
    Ctx c = { .engine = pub->rete_engine };

    /* 2026-01-02T03:00:00Z, as an Int instant, which every one of the three
       accepts. */
    const int64_t at = 1767322800000000000LL;
    ds_rete_expr_t *call = call_n(c.engine, op, lit_int(at),
                                  lit_str(c.engine, "Nowhere/Land"));
    call->json_tainted = tainted;

    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 5000LL);
    ds_rete_held_t held;
    (void)ds_rete_eval_holding(&ctx, call, &held);
    if (!held.held || held.cause != DS_FAULT_DOMAIN) {
        snprintf(msg, sizeof msg, "%s of a refused zone%s is DOMAIN",
                 label, tainted ? ", from data," : "");
        rc = fail(msg);
    }

    ctx = pinned_ctx(&c, 5000LL);
    (void)ds_rete_eval(&ctx, call);
    bool halted = true;
    if (!ctx.faulted) {
        snprintf(msg, sizeof msg, "%s of a refused zone faults", label);
        rc = fail(msg);
    }
    if (ds_engine_halted(pub, &halted, NULL).status != DS_OK || halted) {
        snprintf(msg, sizeof msg,
                 "%s of a refused zone%s leaves the engine running",
                 label, tainted ? ", from data," : "");
        rc = fail(msg);
    }

    ds_rete_expr_free_tree(call);
    ds_engine_free(pub);
    return rc;
}

static int test_ltim_10_5_3__refused_zone_is_domain(void)
{
    int rc = 0;
    rc |= refused_zone_case(DS_FN_LOCAL,     "local()", false, true);
    rc |= refused_zone_case(DS_FN_LOCAL,     "local()", true,  true);
    rc |= refused_zone_case(DS_FN_TIME_DATE, "date()",  false, true);
    rc |= refused_zone_case(DS_FN_TIME_DATE, "date()",  true,  true);
    rc |= refused_zone_case(DS_FN_HOUR,      "hour()",  false, true);
    rc |= refused_zone_case(DS_FN_HOUR,      "hour()",  true,  true);
    /* No `TimeZoneOffset` schema at all: the same DOMAIN from each site.
       The rule-level pin is the fixture
       LTIM.10.5.3.no_row_is_a_domain_error. */
    rc |= refused_zone_case(DS_FN_LOCAL,     "local() with no rows", false, false);
    rc |= refused_zone_case(DS_FN_TIME_DATE, "date() with no rows",  false, false);
    rc |= refused_zone_case(DS_FN_HOUR,      "hour() with no rows",  false, false);
    return rc;
}

/* A zone no fact answers faults, never falling back to UTC
   ([LTIM.10.5.3]/[LTIM.10.5.4]). */
static int test_local_unknown_zone_errs(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 1000LL);
    (void)eval1(&ctx,
        call_n(c.engine, DS_FN_LOCAL, now_expr(),
               lit_str(c.engine, "Nowhere/Land")));
    if (!ctx.faulted) rc = fail("unknown zone should be ERR, not a UTC fallback");
    destroy_ctx(&c);
    return rc;
}

/* t.date(tz) is the date in the NAMED zone ([LTIM.3.3.1]), as days
   since 1970-01-01: the zone's offset at the instant moves the day. Each case
   is one where the UTC date is a different answer. */
static int64_t date_at(Ctx *c, int64_t instant_ns, const char *tz, bool *faulted)
{
    ds_rete_eval_ctx_t ctx = pinned_ctx(c, 0);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c->engine, DS_FN_TIME_DATE, lit_int(instant_ns),
               lit_str(c->engine, tz)));
    *faulted = ctx.faulted;
    return (v.kind == DS_RETE_VAL_INT) ? v.i : INT64_MIN;
}

static int test_date_resolves(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    bool f = false;
    /* 2026-01-02T03:00:00Z is day 20455 in UTC and 2026-01-01T19:00 -- day
       20454 -- in Los Angeles. */
    const int64_t jan2_0300z = 1767322800000000000LL;
    if (date_at(&c, jan2_0300z, "UTC", &f) != 20455 || f)
        rc = fail("date(UTC) = 20455");
    if (date_at(&c, jan2_0300z, "America/Los_Angeles", &f) != 20454 || f)
        rc = fail("date(America/Los_Angeles) = 20454, not the UTC date");
    /* One nanosecond before the epoch: day -1 in UTC, and 08:59:59 on day 0
       in Tokyo -- the floor has to hold across zero in both directions. */
    if (date_at(&c, -1, "UTC", &f) != -1 || f)
        rc = fail("date(-1ns, UTC) = -1");
    if (date_at(&c, -1, "Asia/Tokyo", &f) != 0 || f)
        rc = fail("date(-1ns, Asia/Tokyo) = 0");
    /* The date range ([LTIM.1.2.2]). The last instant a row can cover,
       INT64_MAX - 1 (valid_until is exclusive, so INT64_MAX itself has no
       answer outside "UTC": [LTIM.10.7]), is 23:47 on
       day 106751 UTC and 08:47 on day 106752 in Tokyo: past the last Date, so
       NOT_REPRESENTABLE, and found through the split (adding the offset to
       the instant first overflows). Fifteen hours after the first instant,
       1677-09-21T15:12:43Z is on day -106752 in UTC, before the first Date,
       and on day -106751 in Tokyo, the first Date. */
    {
        ds_rete_eval_ctx_t hctx = pinned_ctx(&c, 0);
        ds_rete_expr_t *late = call_n(c.engine, DS_FN_TIME_DATE,
                                      lit_int(INT64_MAX - 1),
                                      lit_str(c.engine, "Asia/Tokyo"));
        ds_rete_held_t held;
        (void)ds_rete_eval_holding(&hctx, late, &held);
        ds_rete_expr_free_tree(late);
        if (!held.held || held.cause != DS_FAULT_NOT_REPRESENTABLE)
            rc = fail("date(INT64_MAX - 1, Asia/Tokyo) is day 106752, not a "
                      "Date: NOT_REPRESENTABLE");
    }
    if (date_at(&c, INT64_MAX, "UTC", &f) != 106751 || f)
        rc = fail("date(INT64_MAX, UTC) = 106751, the last Date");
    const int64_t early = INT64_MIN + INT64_C(15) * 3600 * 1000000000;
    (void)date_at(&c, early, "UTC", &f);
    if (!f)
        rc = fail("date(1677-09-21T15:12:43Z, UTC) is day -106752, not a Date");
    if (date_at(&c, early, "Asia/Tokyo", &f) != -106751 || f)
        rc = fail("date(1677-09-21T15:12:43Z, Asia/Tokyo) = -106751, the first Date");
    destroy_ctx(&c);
    return rc;
}

/* A zone no row answers is a hard error: a fault, never the UTC date
   ([LTIM.10.5.3]/[LTIM.10.5.4]); "UTC" answers with no row at all
   ([LTIM.10.8]). */
static int test_date_unresolved_errs(void)
{
    bool f = false;
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    (void)date_at(&c, 1767322800000000000LL, "Nowhere/Land", &f);
    if (!f) rc = fail("date() of an unknown zone should fault, not answer UTC");
    /* Covered up to INT64_MAX - 1, never at INT64_MAX ([LTIM.10.7]). */
    (void)date_at(&c, INT64_MAX, "Asia/Tokyo", &f);
    if (!f) rc = fail("date(INT64_MAX, Asia/Tokyo) has no row ([LTIM.10.7])");
    destroy_ctx(&c);

    c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);   /* and no rows */
    if (date_at(&c, 1767322800000000000LL, "UTC", &f) != 20455 || f)
        rc = fail("date(UTC) needs no row");
    (void)date_at(&c, 1767322800000000000LL, "Asia/Tokyo", &f);
    if (!f) rc = fail("date(Asia/Tokyo) with no rows should fault");
    destroy_ctx(&c);
    return rc;
}

/* [LTIM.6.5]: a component of (instant, zone), FN_HOUR .. FN_DAY_OF_WEEK.
   The zone moves the day, and with it every calendar component; "UTC" needs
   no row ([LTIM.10.8]). Drives rete/adapters.c's time_component. */
static int64_t component_at(Ctx *c, ds_builtin_fn_t fn, int64_t instant_ns,
                            const char *tz, bool *faulted)
{
    ds_rete_eval_ctx_t ctx = pinned_ctx(c, 0);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c->engine, fn, lit_int(instant_ns), lit_str(c->engine, tz)));
    *faulted = ctx.faulted;
    return (v.kind == DS_RETE_VAL_INT) ? v.i : INT64_MIN;
}

static int test_components_in_a_zone(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    bool f = false;
    /* 2026-01-02T03:00:00Z, a Friday, is 2026-01-01T19:00 in Los Angeles, a
       Thursday: the offset changes the day. */
    const int64_t jan2_0300z = 1767322800000000000LL;
    if (component_at(&c, DS_FN_DAY, jan2_0300z, "UTC", &f) != 2 || f)
        rc = fail("day(UTC) = 2");
    if (component_at(&c, DS_FN_HOUR, jan2_0300z, "UTC", &f) != 3 || f)
        rc = fail("hour(UTC) = 3");
    if (component_at(&c, DS_FN_DAY_OF_WEEK, jan2_0300z, "UTC", &f) != 4 || f)
        rc = fail("day_of_week(UTC) = 4, a Friday");
    if (component_at(&c, DS_FN_DAY, jan2_0300z, "America/Los_Angeles", &f) != 1 || f)
        rc = fail("day(Los Angeles) = 1");
    if (component_at(&c, DS_FN_HOUR, jan2_0300z, "America/Los_Angeles", &f) != 19 || f)
        rc = fail("hour(Los Angeles) = 19");
    if (component_at(&c, DS_FN_DAY_OF_WEEK, jan2_0300z, "America/Los_Angeles", &f) != 3 || f)
        rc = fail("day_of_week(Los Angeles) = 3, a Thursday");
    /* 2025-12-31T20:00:00Z is 2026-01-01T05:00 in Tokyo: the year moves. */
    const int64_t dec31_2000z = 1767211200000000000LL;
    if (component_at(&c, DS_FN_YEAR, dec31_2000z, "UTC", &f) != 2025 || f)
        rc = fail("year(UTC) = 2025");
    if (component_at(&c, DS_FN_YEAR, dec31_2000z, "Asia/Tokyo", &f) != 2026 || f)
        rc = fail("year(Tokyo) = 2026");
    if (component_at(&c, DS_FN_MONTH, dec31_2000z, "Asia/Tokyo", &f) != 1 || f)
        rc = fail("month(Tokyo) = 1");
    if (component_at(&c, DS_FN_MINUTE, dec31_2000z + 61000000000LL, "Asia/Tokyo", &f) != 1 || f)
        rc = fail("minute(Tokyo, +61 s) = 1");
    if (component_at(&c, DS_FN_SECOND, dec31_2000z + 61000000000LL, "Asia/Tokyo", &f) != 1 || f)
        rc = fail("second(Tokyo, +61 s) = 1");
    /* The last instant a row covers, INT64_MAX - 1 ([LTIM.10.7]),
       2262-04-11T23:47:16Z, is 08:47 on the 12th in Tokyo. Adding the offset
       to the instant first would overflow. */
    if (component_at(&c, DS_FN_DAY, INT64_MAX - 1, "Asia/Tokyo", &f) != 12 || f)
        rc = fail("day(INT64_MAX - 1, Tokyo) = 12, no overflow");
    if (component_at(&c, DS_FN_HOUR, INT64_MAX - 1, "Asia/Tokyo", &f) != 8 || f)
        rc = fail("hour(INT64_MAX - 1, Tokyo) = 8");
    if (component_at(&c, DS_FN_HOUR, INT64_MAX, "UTC", &f) != 23 || f)
        rc = fail("hour(INT64_MAX, UTC) = 23: UTC takes no row");
    /* A zone no row answers faults; it never answers UTC ([LTIM.10.5.3]). */
    (void)component_at(&c, DS_FN_HOUR, jan2_0300z, "Nowhere/Land", &f);
    if (!f) rc = fail("hour() of an unknown zone should fault");
    destroy_ctx(&c);

    /* No rows: "UTC" still answers, as utc(t) does ([LTIM.10.8]); any other
       zone faults, as local() does. */
    c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    if (component_at(&c, DS_FN_HOUR, jan2_0300z, "UTC", &f) != 3 || f)
        rc = fail("hour(UTC) needs no row");
    (void)component_at(&c, DS_FN_HOUR, jan2_0300z, "Asia/Tokyo", &f);
    if (!f) rc = fail("hour(Tokyo) with no rows should fault");
    destroy_ctx(&c);
    return rc;
}

/* monotonic() returns a Duration (Int ns) from the engine clock — the
   per-fire snapshot when set, else the live engine clock_fn ([LTIM.2.2]). */
static int test_monotonic(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;

    /* (1) rides the per-fire snapshot. */
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 42424242LL);
    ds_rete_val_t v = eval1(&ctx, call0(c.engine, DS_FN_MONOTONIC_NS));
    if (v.kind != DS_RETE_VAL_INT || v.i != 42424242LL)
        rc = fail("monotonic() should ride the fire snapshot (Duration)");

    /* (2) rides the engine clock_fn when there is no snapshot. */
    if (!rc) {
        c.engine->clock_fn = fixed_clock_fn;
        g_fixed_clock_ns   = 99999LL;
        ds_rete_eval_ctx_t ctx2 = {0};
        ctx2.engine = c.engine;            /* fire_now_ns = 0 */
        v = eval1(&ctx2, call0(c.engine, DS_FN_MONOTONIC_NS));
        if (v.kind != DS_RETE_VAL_INT || v.i != 99999LL)
            rc = fail("monotonic() should ride the engine clock");
    }
    destroy_ctx(&c);
    return rc;
}

/* An eval ctx whose two clocks read exactly `ns` (0 and negative included),
   with no per-fire snapshot. */
static ds_rete_eval_ctx_t clock_ctx(Ctx *c, int64_t ns)
{
    c->engine->clock_fn = fixed_clock_fn;
    g_fixed_clock_ns    = ns;
    c->engine->wall_fn  = fixed_wall_fn;   /* now() reads the wall clock */
    g_fixed_wall_ns     = ns;
    ds_rete_eval_ctx_t ctx = {0};
    ctx.engine = c->engine;
    return ctx;
}
static int expect_str(ds_rete_val_t v, const char *want, const char *label)
{
    if (v.kind != DS_RETE_VAL_STR || !v.s.ptr || strcmp(v.s.ptr, want) != 0)
        return fail(label);
    return 0;
}

/* to_string(t, "iso8601") — epoch instant, UTC, formats canonically. */
static int test_to_string_iso8601(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    ds_rete_eval_ctx_t ctx = clock_ctx(&c, 0);
    ds_rete_val_t v = eval1(&ctx,
        call_n(c.engine, DS_FN_TO_STRING, now_expr(),
               lit_str(c.engine, "iso8601")));
    int rc = expect_str(v, "1970-01-01T00:00:00Z", "to_string iso8601 @epoch");
    destroy_ctx(&c);
    return rc;
}

/* to_string epoch_* — floor toward -inf (LTIM.8.2.1a). */
static int test_to_string_epoch(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    struct { int64_t ns; const char *fmt; const char *want; } cases[] = {
        { 5000000000LL,  "epoch_seconds", "5" },
        { 5000000000LL,  "epoch_millis",  "5000" },
        { 5000000000LL,  "epoch_micros",  "5000000" },
        { 5000000000LL,  "epoch_nanos",   "5000000000" },
        { -1500LL,       "epoch_micros",  "-2" }, /* floor, not trunc */
    };
    for (unsigned i = 0; i < sizeof(cases)/sizeof(cases[0]) && !rc; i++) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, cases[i].ns);
        ds_rete_val_t v = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING, now_expr(),
                   lit_str(c.engine, cases[i].fmt)));
        rc = expect_str(v, cases[i].want, cases[i].fmt);
    }
    destroy_ctx(&c);
    return rc;
}

/* A call of `op` over `n` Int literals. */
static ds_rete_expr_t *call_ints(ds_builtin_fn_t op, const int64_t *v,
                                 uint32_t n)
{
    ds_rete_expr_t *c = ds_rete_expr_alloc(DS_RETE_EXPR_CALL);
    c->call.op        = op;
    c->call.arg_count = n;
    c->call.args      = calloc(n, sizeof(ds_rete_expr_t *));
    for (uint32_t i = 0; i < n; i++) c->call.args[i] = lit_int(v[i]);
    return c;
}

/* A calendar call's answer: its value, or the cause it raised. */
typedef struct { bool raised; ds_rete_fault_cause_t cause; ds_rete_val_t v; }
    calendar_answer_t;

static calendar_answer_t calendar_call(Ctx *c, ds_builtin_fn_t op,
                                       const int64_t *v, uint32_t n)
{
    ds_rete_eval_ctx_t ctx = clock_ctx(c, 1);
    ds_rete_held_t held = { .held = false };
    ds_rete_expr_t *e = call_ints(op, v, n);
    calendar_answer_t a = { .v = ds_rete_eval_holding(&ctx, e, &held) };
    ds_rete_expr_free_tree(e);
    a.raised = held.held;
    a.cause  = held.cause;
    return a;
}

/* [LTIM.14.1]: calendar.time and calendar.date build a value from its
   fields. The compiler fills `calendar.time`'s omitted fields with 0, so
   FN_CALENDAR_TIME always takes seven. The Time is at offset 0, and its
   nanoseconds are written whole by to_string ([LTIM.8.2.4]). The path:
   adapter_ds_calendar_time / adapter_ds_calendar_date. */
static int test_ltim_14_1__calendar_builds(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;

    const int64_t t[7] = { 2024, 1, 15, 16, 0, 0, 123456789 };
    calendar_answer_t a = calendar_call(&c, DS_FN_CALENDAR_TIME, t, 7);
    if (a.raised || a.v.kind != DS_RETE_VAL_TIME ||
        a.v.time.utc_ns != INT64_C(1705334400123456789) ||
        a.v.time.tz_offset_s != 0)
        rc = fail("calendar.time(2024, 1, 15, 16, 0, 0, 123456789)");
    {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING,
                   call_ints(DS_FN_CALENDAR_TIME, t, 7), NULL));
        rc |= expect_str(s, "2024-01-15T16:00:00.123456789Z",
                         "to_string(calendar.time(...))");
    }

    const int64_t epoch[7] = { 1970, 1, 1, 0, 0, 5, 0 };
    a = calendar_call(&c, DS_FN_CALENDAR_TIME, epoch, 7);
    if (a.raised || a.v.kind != DS_RETE_VAL_TIME ||
        a.v.time.utc_ns != INT64_C(5000000000))
        rc = fail("calendar.time(1970, 1, 1, 0, 0, 5)");

    /* Before the epoch: 1969-12-31T23:59:59Z is -1 s. */
    const int64_t before[7] = { 1969, 12, 31, 23, 59, 59, 0 };
    a = calendar_call(&c, DS_FN_CALENDAR_TIME, before, 7);
    if (a.raised || a.v.kind != DS_RETE_VAL_TIME ||
        a.v.time.utc_ns != INT64_C(-1000000000))
        rc = fail("calendar.time(1969, 12, 31, 23, 59, 59)");

    const int64_t leap[3] = { 2024, 2, 29 };
    a = calendar_call(&c, DS_FN_CALENDAR_DATE, leap, 3);
    if (a.raised || a.v.kind != DS_RETE_VAL_INT || a.v.i != 19782)
        rc = fail("calendar.date(2024, 2, 29) is day 19782");
    {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING, lit_int(-1), NULL));
        rc |= expect_str(s, "1969-12-31", "Date -1 to_string");
    }
    destroy_ctx(&c);
    return rc;
}

/* [LTIM.14.2]: a field outside its range is DOMAIN, checked before the
   value's range, so a year past either type's range with a bad month is
   DOMAIN too. A null field is null and raises nothing; a field that is not
   an Int is a type mismatch. */
static int test_ltim_14_2__calendar_domain(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    char msg[160];

    struct { const char *what; int64_t f[7]; uint32_t n; } bad[] = {
        { "month 13",           { 2024, 13, 1 }, 3 },
        { "month 0",            { 2024, 0, 1 }, 3 },
        { "2023-02-29",         { 2023, 2, 29 }, 3 },
        { "day 0",              { 2024, 1, 0 }, 3 },
        { "2024-04-31",         { 2024, 4, 31 }, 3 },
        { "hour 24",            { 2024, 1, 1, 24, 0, 0, 0 }, 7 },
        { "minute 60",          { 2024, 1, 1, 0, 60, 0, 0 }, 7 },
        { "second 60",          { 2024, 1, 1, 0, 0, 60, 0 }, 7 },
        { "nanosecond 10^9",    { 2024, 1, 1, 0, 0, 0, 1000000000 }, 7 },
        { "nanosecond -1",      { 2024, 1, 1, 0, 0, 0, -1 }, 7 },
        { "hour -1",            { 2024, 1, 1, -1, 0, 0, 0 }, 7 },
        { "month 13, year 2^63-1", { INT64_MAX, 13, 1 }, 3 },
    };
    for (unsigned i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        ds_builtin_fn_t op = bad[i].n == 7 ? DS_FN_CALENDAR_TIME
                                           : DS_FN_CALENDAR_DATE;
        calendar_answer_t a = calendar_call(&c, op, bad[i].f, bad[i].n);
        if (!a.raised || a.cause != DS_FAULT_DOMAIN) {
            snprintf(msg, sizeof msg, "calendar %s is DOMAIN", bad[i].what);
            rc = fail(msg);
        }
        if (bad[i].n == 3) {           /* and as a Time's date, at midnight */
            int64_t f[7] = { bad[i].f[0], bad[i].f[1], bad[i].f[2] };
            a = calendar_call(&c, DS_FN_CALENDAR_TIME, f, 7);
            if (!a.raised || a.cause != DS_FAULT_DOMAIN) {
                snprintf(msg, sizeof msg, "calendar.time %s is DOMAIN",
                         bad[i].what);
                rc = fail(msg);
            }
        }
    }

    /* 2024-02-29 is a day: the leap year the 2023 case is not. */
    const int64_t leap[7] = { 2024, 2, 29, 23, 59, 59, 999999999 };
    calendar_answer_t a = calendar_call(&c, DS_FN_CALENDAR_TIME, leap, 7);
    if (a.raised || a.v.kind != DS_RETE_VAL_TIME)
        rc = fail("calendar.time(2024, 2, 29, 23, 59, 59, 999999999)");

    /* A null field is null; a String field is a type mismatch. */
    {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_held_t held = { .held = false };
        const int64_t f[3] = { 2024, 1, 1 };
        ds_rete_expr_t *e = call_ints(DS_FN_CALENDAR_DATE, f, 3);
        ds_rete_expr_free_tree(e->call.args[1]);
        e->call.args[1] = ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL);
        ds_rete_val_t v = ds_rete_eval_holding(&ctx, e, &held);
        ds_rete_expr_free_tree(e);
        if (held.held || v.kind != DS_RETE_VAL_NULL)
            rc = fail("calendar.date with a null month is null");

        ctx = clock_ctx(&c, 1);
        held = (ds_rete_held_t){ .held = false };
        e = call_ints(DS_FN_CALENDAR_DATE, f, 3);
        ds_rete_expr_free_tree(e->call.args[0]);
        e->call.args[0] = lit_str(c.engine, "2024");
        (void)ds_rete_eval_holding(&ctx, e, &held);
        ds_rete_expr_free_tree(e);
        if (!held.held || held.cause != DS_FAULT_TYPE_MISMATCH)
            rc = fail("calendar.date with a String year is a type mismatch");
    }
    destroy_ctx(&c);
    return rc;
}

/* [LTIM.14.2] with [LTIM.1.1.5] and [LTIM.1.2.2]: a value outside its type's
   range is NOT_REPRESENTABLE, never a wrap, and no step overflows where the
   value is in range. 1677-09-21's midnight is below INT64_MIN while its
   instants from 00:12:43.145224192Z are not; INT64_MAX is
   2262-04-11T23:47:16.854775807Z. A year with no int64 day count is
   NOT_REPRESENTABLE too, and no UB (ubsan holds that). */
static int test_ltim_14_2__calendar_not_representable(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    char msg[160];

    struct { const char *what; int64_t f[7]; bool ok; int64_t want; } times[] = {
        { "1677-09-21",                    { 1677, 9, 21, 0, 0, 0, 0 },
          false, 0 },
        { "1677-09-21T00:12:43.145224191Z", { 1677, 9, 21, 0, 12, 43, 145224191 },
          false, 0 },
        { "1677-09-21T00:12:43.145224192Z", { 1677, 9, 21, 0, 12, 43, 145224192 },
          true, INT64_MIN },
        { "1677-09-21T00:12:44Z",          { 1677, 9, 21, 0, 12, 44, 0 },
          true, INT64_C(-9223372036000000000) },
        { "2262-04-11T23:47:16.854775807Z", { 2262, 4, 11, 23, 47, 16, 854775807 },
          true, INT64_MAX },
        { "2262-04-11T23:47:16.854775808Z", { 2262, 4, 11, 23, 47, 16, 854775808 },
          false, 0 },
        { "2262-04-12",                    { 2262, 4, 12, 0, 0, 0, 0 },
          false, 0 },
        { "year 2^63-1",                   { INT64_MAX, 1, 1, 0, 0, 0, 0 },
          false, 0 },
        { "year -2^63",                    { INT64_MIN, 12, 31, 23, 59, 59, 0 },
          false, 0 },
    };
    for (unsigned i = 0; i < sizeof times / sizeof times[0]; i++) {
        calendar_answer_t a = calendar_call(&c, DS_FN_CALENDAR_TIME,
                                            times[i].f, 7);
        bool ok = times[i].ok
            ? (!a.raised && a.v.kind == DS_RETE_VAL_TIME &&
               a.v.time.utc_ns == times[i].want)
            : (a.raised && a.cause == DS_FAULT_NOT_REPRESENTABLE);
        if (!ok) {
            snprintf(msg, sizeof msg, "calendar.time %s %s", times[i].what,
                     times[i].ok ? "is its instant" : "is NOT_REPRESENTABLE");
            rc = fail(msg);
        }
    }

    struct { const char *what; int64_t f[3]; bool ok; int64_t want; } dates[] = {
        { "1677-09-21", { 1677, 9, 21 }, false, 0 },
        { "1677-09-22", { 1677, 9, 22 }, true, -106751 },
        { "2262-04-11", { 2262, 4, 11 }, true, 106751 },
        { "2262-04-12", { 2262, 4, 12 }, false, 0 },
        { "year 2^63-1", { INT64_MAX, 1, 1 }, false, 0 },
    };
    for (unsigned i = 0; i < sizeof dates / sizeof dates[0]; i++) {
        calendar_answer_t a = calendar_call(&c, DS_FN_CALENDAR_DATE,
                                            dates[i].f, 3);
        bool ok = dates[i].ok
            ? (!a.raised && a.v.kind == DS_RETE_VAL_INT &&
               a.v.i == dates[i].want)
            : (a.raised && a.cause == DS_FAULT_NOT_REPRESENTABLE);
        if (!ok) {
            snprintf(msg, sizeof msg, "calendar.date %s %s", dates[i].what,
                     dates[i].ok ? "is its day" : "is NOT_REPRESENTABLE");
            rc = fail(msg);
        }
    }
    destroy_ctx(&c);
    return rc;
}

/* An unknown format identifier, computed, is NOT_REPRESENTABLE
   ([LTIM.8.3.2]). */
static int test_to_string_unknown_format(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
    int rc = 0;
    (void)eval1(&ctx,
        call_n(c.engine, DS_FN_TO_STRING, now_expr(),
               lit_str(c.engine, "bogus")));
    if (!ctx.faulted) rc = fail("to_string unknown should be ERR");
    destroy_ctx(&c);
    return rc;
}

/* [LTIM.8.2.4], [LGRA.2.9.6.4]: the wall clock at the value's offset is
   written from the local split, never from `utc_ns + offset`, which leaves
   int64 within |offset| of either end of the range.
   1677-09-21T03:00:00Z at -08:00 is 1677-09-20T19:00:00-08:00, and
   2262-04-11T20:00:00Z at +09:00 is 2262-04-12T05:00:00+09:00: both sums pass
   int64, by about 2.9 * 10^13 ns. The path: fmt_iso8601 through
   ds_rete_local_split. eval.c's render_time, the timestamp primitives, is
   test_rete_expr_eval.c's. */
static int test_ltim_8_2_4__render_at_the_range_ends(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    struct { int64_t ns; const char *tz; const char *want; } cases[] = {
        { INT64_C(-9223362000000000000), "America/Los_Angeles",
          "1677-09-20T19:00:00-08:00" },
        { INT64_C(9223358400000000000),  "Asia/Tokyo",
          "2262-04-12T05:00:00+09:00" },
        { INT64_MIN,                     "America/Los_Angeles",
          "1677-09-20T16:12:43.145224192-08:00" },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, cases[i].ns);
        ds_rete_val_t v = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING,
                   call_n(c.engine, DS_FN_LOCAL, now_expr(),
                          lit_str(c.engine, cases[i].tz)),
                   lit_str(c.engine, "iso8601")));
        rc |= expect_str(v, cases[i].want, cases[i].want);
    }
    destroy_ctx(&c);
    return rc;
}

/* The date range ([LTIM.1.2.2]): days -106751
   (1677-09-22) through 106751 (2262-04-11). Each place adapters.c makes or
   reads a Date holds it:
     - calendar.date: a real calendar day outside the range is
       NOT_REPRESENTABLE, the end days are Dates (adapter_ds_calendar_date,
       test_ltim_14_2__calendar_not_representable);
     - to_string: a Date outside it is NOT_REPRESENTABLE, an end day renders
       (adapter_ds_to_string);
     - add_months on a Date: a result outside it is NOT_REPRESENTABLE, read
       for the cause under ds_rete_eval_holding (calendar_shift);
     - add_months on a Time is NOT held to it: a Time on 1677-09-21, whose UTC
       day is -106752, still shifts. */
static int test_ltim_1_2_2__date_range(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    char msg[160];

    {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING, lit_int(106751), NULL));
        rc |= expect_str(s, "2262-04-11", "to_string of the last Date");
        ctx = clock_ctx(&c, 1);
        s = eval1(&ctx, call_n(c.engine, DS_FN_TO_STRING, lit_int(-106751), NULL));
        rc |= expect_str(s, "1677-09-22", "to_string of the first Date");
        ctx = clock_ctx(&c, 1);
        (void)eval1(&ctx, call_n(c.engine, DS_FN_TO_STRING, lit_int(106752), NULL));
        if (!ctx.faulted) rc = fail("to_string of day 106752 is NOT_REPRESENTABLE");
    }

    struct { int64_t days, months; bool date; int64_t want; } shifts[] = {
        { 106751,   1, false, 0 },        /* 2262-05-11 */
        { -106751, -1, false, 0 },        /* 1677-08-22 */
        { 106751,  -1, true,  106720 },   /* 2262-03-11 */
        { -106751,  1, true,  -106721 },  /* 1677-10-22 */
    };
    for (unsigned i = 0; i < sizeof shifts / sizeof shifts[0]; i++) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_expr_t *e = call_n(c.engine, DS_FN_ADD_MONTHS,
                                   lit_int(shifts[i].days),
                                   lit_int(shifts[i].months));
        ds_rete_held_t held;
        ds_rete_val_t v = ds_rete_eval_holding(&ctx, e, &held);
        ds_rete_expr_free_tree(e);
        bool ok = shifts[i].date
            ? (!held.held && v.kind == DS_RETE_VAL_INT && v.i == shifts[i].want)
            : (held.held && held.cause == DS_FAULT_NOT_REPRESENTABLE);
        if (!ok) {
            snprintf(msg, sizeof msg, "add_months(%lld, %lld) %s",
                     (long long)shifts[i].days, (long long)shifts[i].months,
                     shifts[i].date ? "is a Date" : "is NOT_REPRESENTABLE");
            rc = fail(msg);
        }
    }

    {
        /* 1677-09-21T15:12:43Z + 1 month = 1677-10-21T15:12:43Z, 30 days on. */
        const int64_t day = INT64_C(86400) * 1000000000;
        const int64_t early = INT64_MIN + INT64_C(15) * 3600 * 1000000000;
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t t = eval1(&ctx,
            call_n(c.engine, DS_FN_ADD_MONTHS,
                   call_n(c.engine, DS_FN_UTC, lit_int(early), NULL),
                   lit_int(1)));
        if (ctx.faulted || t.kind != DS_RETE_VAL_TIME ||
            t.time.utc_ns != early + 30 * day)
            rc = fail("add_months on a Time of 1677-09-21 is not held to the "
                      "Date range");
    }
    {
        /* [LTIM.4.3.3], [LTIM.1.1.5]: only the RESULT instant can be
           NOT_REPRESENTABLE. The shift lands back on 1677-09-21, day -106752,
           whose midnight is below INT64_MIN:
             - by 0 months, the instant is unchanged;
             - from 1677-10-21T15:12:43Z by -1, it is 1677-09-21T15:12:43Z;
             - from INT64_MIN + 30 days by -1, it is INT64_MIN itself, the
               first instant;
             - from one nanosecond earlier by -1, it is before INT64_MIN. */
        const int64_t day = INT64_C(86400) * 1000000000;
        const int64_t early = INT64_MIN + INT64_C(15) * 3600 * 1000000000;
        const struct { const char *what; int64_t from, months, want; bool ok; }
        lands[] = {
            { "add_months(1677-09-21T15:12:43Z, 0)", early, 0, early, true },
            { "add_months(1677-10-21T15:12:43Z, -1)", early + 30 * day, -1,
              early, true },
            { "add_months(INT64_MIN + 30 days, -1)", INT64_MIN + 30 * day, -1,
              INT64_MIN, true },
            { "add_months(INT64_MIN + 30 days - 1 ns, -1)",
              INT64_MIN + 30 * day - 1, -1, 0, false },
        };
        for (size_t i = 0; i < sizeof lands / sizeof lands[0]; i++) {
            ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
            ds_rete_held_t held = { .held = false };
            ds_rete_expr_t *call =
                call_n(c.engine, DS_FN_ADD_MONTHS,
                       call_n(c.engine, DS_FN_UTC, lit_int(lands[i].from), NULL),
                       lit_int(lands[i].months));
            ds_rete_val_t t = ds_rete_eval_holding(&ctx, call, &held);
            ds_rete_expr_free_tree(call);
            bool ok = lands[i].ok
                ? (!held.held && t.kind == DS_RETE_VAL_TIME
                   && t.time.utc_ns == lands[i].want)
                : (held.held && held.cause == DS_FAULT_NOT_REPRESENTABLE);
            if (!ok) rc = fail(lands[i].what);
        }
    }
    destroy_ctx(&c);
    return rc;
}

/* The first partial day and second. INT64_MIN is
   1677-09-21T00:12:43.145224192Z, and no multiple of a day or of a second: the
   floored day -106752 times a day, and the floored second -9223372037 times
   1e9, are both below INT64_MIN. Each place that splits a Time into a whole
   count and a remainder takes the remainder as a floored modulus, never as
   `ns - floor * unit`, and is driven here at INT64_MIN:
     - time_component: utc(t).hour, .minute, .second, .day, .month, .year;
     - fmt_iso8601: to_string(t);
     - calendar_shift: add_months(t, 1), here and fifteen hours later in
       test_ltim_1_2_2__date_range.
   eval.c's render_time is test_rete_expr_eval.c's test_interp_time.
   The values pin the split's arithmetic, and the ubsan lane its
   definedness. */
static int test_first_partial_day_splits_without_overflow(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);   /* "UTC" needs no row */
    int rc = 0;
    bool f = false;
    char msg[96];

    struct { ds_builtin_fn_t fn; const char *name; int64_t want; } parts[] = {
        { DS_FN_HOUR,   "hour",   0 },
        { DS_FN_MINUTE, "minute", 12 },
        { DS_FN_SECOND, "second", 43 },
        { DS_FN_DAY,    "day",    21 },
        { DS_FN_MONTH,  "month",  9 },
        { DS_FN_YEAR,   "year",   1677 },
    };
    for (unsigned i = 0; i < sizeof parts / sizeof parts[0]; i++) {
        if (component_at(&c, parts[i].fn, INT64_MIN, "UTC", &f) != parts[i].want
            || f) {
            snprintf(msg, sizeof msg, "%s(INT64_MIN, UTC) = %lld", parts[i].name,
                     (long long)parts[i].want);
            rc = fail(msg);
        }
    }

    {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING,
                   call_n(c.engine, DS_FN_UTC, lit_int(INT64_MIN), NULL), NULL));
        rc |= expect_str(s, "1677-09-21T00:12:43.145224192Z",
                         "to_string of INT64_MIN");
    }

    {
        const int64_t day = INT64_C(86400) * 1000000000;
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t t = eval1(&ctx,
            call_n(c.engine, DS_FN_ADD_MONTHS,
                   call_n(c.engine, DS_FN_UTC, lit_int(INT64_MIN), NULL),
                   lit_int(1)));
        if (ctx.faulted || t.kind != DS_RETE_VAL_TIME ||
            t.time.utc_ns != INT64_MIN + 30 * day)
            rc = fail("add_months(INT64_MIN, 1) = 1677-10-21T00:12:43.145224192Z");
    }
    destroy_ctx(&c);
    return rc;
}

/* A Time at a nonzero offset needs local() and a zone's rows. ::String
   writes the wall clock at the value's offset, then `+hh:mm` or `-hh:mm`, and
   a fraction only when it is not zero, trailing zeros removed
   ([LTIM.8.2.4]). The path: fmt_iso8601's offset arm. */
static int test_iso8601_render_at_an_offset(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    struct { int64_t ns; const char *tz; const char *want; } cases[] = {
        { 1700000000000000000LL, "America/Los_Angeles", "2023-11-14T14:13:20-08:00" },
        { 1700000000000000000LL, "Asia/Tokyo",          "2023-11-15T07:13:20+09:00" },
        { 1700000000500000000LL, "Asia/Tokyo",          "2023-11-15T07:13:20.5+09:00" },
        { 1700000000000000000LL, "UTC",                 "2023-11-14T22:13:20Z" },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, cases[i].ns);
        ds_rete_val_t v = eval1(&ctx,
            call_n(c.engine, DS_FN_TO_STRING,
                   call_n(c.engine, DS_FN_LOCAL, now_expr(),
                          lit_str(c.engine, cases[i].tz)),
                   lit_str(c.engine, "iso8601")));
        rc |= expect_str(v, cases[i].want, cases[i].want);
    }
    destroy_ctx(&c);
    return rc;
}

/* The compact Duration form ([LTIM.8.4]): the nonzero components, largest
   unit first, and no sign ([LTIM.8.4.2]). DS writes it and reads
   none ([LTIM.14]). */
static int test_duration_compact_form(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    struct { int64_t ns; const char *out; } cases[] = {
        { INT64_C(5400000000000), "1h30m" },
        { INT64_C(500000000),     "500ms" },
        { INT64_C(7215000000000), "2h15s" },
        { INT64_C(3600000000000), "1h" },
        { 0,                      "0s" },
        { 1001,                   "1us1ns" },
        { INT64_MAX,              "2562047h47m16s854ms775us807ns" },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0] && !rc; i++) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_DURATION_TO_STRING, lit_int(cases[i].ns),
                   NULL));
        rc = expect_str(s, cases[i].out, cases[i].out);
    }
    /* A negative count writes `0s`, never a `-` ([LTIM.8.4.2]): it is the 0_s
       the saturation rule makes it ([LTIM.1.3.1]). */
    if (!rc) {
        ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
        ds_rete_val_t s = eval1(&ctx,
            call_n(c.engine, DS_FN_DURATION_TO_STRING, lit_int(-5), NULL));
        rc = expect_str(s, "0s", "-5ns");
    }
    destroy_ctx(&c);
    return rc;
}

/* add_months / add_years: the Date arm clamps ([LTIM.4.3.2]); the Time arm
   (a TIME-tagged value) shifts the UTC date and keeps the time of day
   ([LTIM.4.3.3]). */
static int test_calendar_shift(void)
{
    Ctx c = make_ctx();
    ds_rete_register_adapters(c.engine, NULL);
    int rc = 0;
    ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
    /* 2024-03-31 + 1 month = 2024-04-30 (day 19843). */
    ds_rete_val_t d = eval1(&ctx,
        call_n(c.engine, DS_FN_ADD_MONTHS, lit_int(19813), lit_int(1)));
    if (d.kind != DS_RETE_VAL_INT || d.i != 19843) rc = fail("add_months clamp");
    /* 2024-02-29 + 1 year = 2025-02-28 (day 20147). */
    if (!rc) {
        d = eval1(&ctx,
            call_n(c.engine, DS_FN_ADD_YEARS, lit_int(19782), lit_int(1)));
        if (d.kind != DS_RETE_VAL_INT || d.i != 20147) rc = fail("add_years leap");
    }
    /* 2024-01-31 - 1 month = 2023-12-31 (day 19722): a negative count. */
    if (!rc) {
        d = eval1(&ctx,
            call_n(c.engine, DS_FN_ADD_MONTHS, lit_int(19753), lit_int(-1)));
        if (d.kind != DS_RETE_VAL_INT || d.i != 19722) rc = fail("add_months back");
    }
    /* 2024-03-31T10:20:30Z + 1 month = 2024-04-30T10:20:30Z. */
    if (!rc) {
        ds_rete_val_t t = eval1(&ctx,
            call_n(c.engine, DS_FN_ADD_MONTHS,
                   call_n(c.engine, DS_FN_UTC, lit_int(1711880430000000000LL), NULL),
                   lit_int(1)));
        if (t.kind != DS_RETE_VAL_TIME ||
            t.time.utc_ns != 1714472430000000000LL)
            rc = fail("add_months on a Time keeps the UTC time of day");
    }
    /* A shift past the Time range is a ComputationError NOT_REPRESENTABLE
       ([LTIM.4.3.3]), never a wrap and not an EngineError. The path:
       calendar_shift's int64-ns overflow arm, read under ds_rete_eval_holding
       for the cause. */
    if (!rc) {
        ds_rete_eval_ctx_t ctx2 = clock_ctx(&c, 1);
        ds_rete_expr_t *shift = call_n(c.engine, DS_FN_ADD_YEARS,
            call_n(c.engine, DS_FN_UTC, lit_int(1711880430000000000LL), NULL),
            lit_int(1000));
        ds_rete_held_t held;
        (void)ds_rete_eval_holding(&ctx2, shift, &held);
        ds_rete_expr_free_tree(shift);
        if (!held.held || held.cause != DS_FAULT_NOT_REPRESENTABLE)
            rc = fail("add_years past 2262 is NOT_REPRESENTABLE");
    }
    destroy_ctx(&c);
    return rc;
}

/* FN_INT_DIV_EXACT ([RLOW.7.3.9]): a Duration on a `minute` kwarg is
   divided by the unit's 60e9 ns, and only exactly. The four answers the clause
   gives, through `builtin_int_div_exact`: a quotient when the divisor divides,
   NOT_REPRESENTABLE when it does not (never truncated), DIVIDE_BY_ZERO for a
   zero divisor, and null for a null operand; and INT64_MIN / -1, which has no
   int64 quotient, NOT_REPRESENTABLE rather than C's trap. The causes are read
   under ds_rete_eval_holding. */
static int int_div_exact_cause(Ctx *c, ds_rete_expr_t *n, ds_rete_expr_t *d,
                               ds_rete_fault_cause_t want, const char *what)
{
    ds_rete_eval_ctx_t ctx = clock_ctx(c, 1);
    ds_rete_expr_t *e = call_n(c->engine, DS_FN_INT_DIV_EXACT, n, d);
    ds_rete_held_t held;
    (void)ds_rete_eval_holding(&ctx, e, &held);
    ds_rete_expr_free_tree(e);
    return (!held.held || held.cause != want) ? fail(what) : 0;
}

/* @spec [RLOW.7.3.9] */
static int test_int_div_exact(void)
{
    Ctx c = make_ctx();
    ds_register_builtins(c.engine);
    int rc = 0;
    ds_rete_eval_ctx_t ctx = clock_ctx(&c, 1);
    const int64_t minute = 60000000000LL;
    ds_rete_val_t v = eval1(&ctx, call_n(c.engine, DS_FN_INT_DIV_EXACT,
        lit_int(2 * minute), lit_int(minute)));
    if (ctx.faulted || v.kind != DS_RETE_VAL_INT || v.i != 2)
        rc = fail("120 s in minutes is 2");
    if (!rc) {
        v = eval1(&ctx, call_n(c.engine, DS_FN_INT_DIV_EXACT,
            lit_int(-2 * minute), lit_int(minute)));
        if (ctx.faulted || v.kind != DS_RETE_VAL_INT || v.i != -2)
            rc = fail("-120 s in minutes is -2");
    }
    if (!rc)
        rc = int_div_exact_cause(&c, lit_int(90000000000LL), lit_int(minute),
            DS_FAULT_NOT_REPRESENTABLE, "90 s in minutes is NOT_REPRESENTABLE");
    if (!rc)
        rc = int_div_exact_cause(&c, lit_int(minute), lit_int(0),
            DS_FAULT_DIVIDE_BY_ZERO, "a zero divisor is DIVIDE_BY_ZERO");
    if (!rc)
        rc = int_div_exact_cause(&c, lit_int(INT64_MIN), lit_int(-1),
            DS_FAULT_NOT_REPRESENTABLE, "INT64_MIN / -1 is NOT_REPRESENTABLE");
    if (!rc) {
        v = eval1(&ctx, call_n(c.engine, DS_FN_INT_DIV_EXACT,
            ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL), lit_int(minute)));
        if (ctx.faulted || v.kind != DS_RETE_VAL_NULL)
            rc = fail("a null numerator is null");
    }
    if (!rc) {
        v = eval1(&ctx, call_n(c.engine, DS_FN_INT_DIV_EXACT,
            lit_int(minute), ds_rete_expr_alloc(DS_RETE_EXPR_LIT_NULL)));
        if (ctx.faulted || v.kind != DS_RETE_VAL_NULL)
            rc = fail("a null divisor is null");
    }
    destroy_ctx(&c);
    return rc;
}

/* `t.floor(d)` ([LTIM.7.1], [LTIM.7.2]): the boundary of `d` at or
   before `t`, in the offset `t` carries, keeping that offset. The half the
   conformance harness cannot reach is a zoned receiver, which needs local()
   and a resolver: Tokyo (+9 h) and Los Angeles (-8 h) floor the same instant
   to their own midnights. An untagged Int, a Time slot read, floors in UTC and
   stays an Int. The path: builtin_floor_time, under ds_rete_eval_holding for
   the causes. */
static int floor_time_cause(Ctx *c, ds_rete_expr_t *t, ds_rete_expr_t *d,
                            ds_rete_fault_cause_t want, const char *what)
{
    ds_rete_eval_ctx_t ctx = pinned_ctx(c, 1);
    ds_rete_expr_t *e = call_n(c->engine, DS_FN_FLOOR_TIME, t, d);
    ds_rete_held_t held;
    (void)ds_rete_eval_holding(&ctx, e, &held);
    ds_rete_expr_free_tree(e);
    return (!held.held || held.cause != want) ? fail(what) : 0;
}

/* @spec [LTIM.7.1] */
static int test_ltim_7_1__floor_time(void)
{
    Ctx c = make_ctx();
    ds_register_builtins(c.engine);
    ds_rete_register_adapters(c.engine, NULL);
    int rc = install_zones(c.engine);
    const int64_t s = 1000000000LL, hour = 3600 * s, day = 86400 * s;
    const int64_t t = 1711880430500000000LL;   /* 2024-03-31T10:20:30.5Z */
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, t);

    /* An Int: a Time slot reads untagged, and floors in UTC. */
    ds_rete_val_t v = eval1(&ctx,
        call_n(c.engine, DS_FN_FLOOR_TIME, lit_int(t), lit_int(hour)));
    if (ctx.faulted || v.kind != DS_RETE_VAL_INT || v.i != 1711879200 * s)
        rc |= fail("an Int floors to 10:00:00Z and stays an Int");
    v = eval1(&ctx,
        call_n(c.engine, DS_FN_FLOOR_TIME, lit_int(-1), lit_int(hour)));
    if (ctx.faulted || v.kind != DS_RETE_VAL_INT || v.i != -hour)
        rc |= fail("-1 ns floors to 1969-12-31T23:00:00Z, toward -inf");

    struct { const char *tz; int32_t off_s; int64_t want; } zoned[] = {
        { "UTC",                 0,         1711843200 * s },
        { "Asia/Tokyo",          9 * 3600,  1711810800 * s },
        { "America/Los_Angeles", -8 * 3600, 1711872000 * s },
    };
    for (unsigned i = 0; i < sizeof zoned / sizeof zoned[0]; i++) {
        ctx = pinned_ctx(&c, t);
        v = eval1(&ctx,
            call_n(c.engine, DS_FN_FLOOR_TIME,
                   call_n(c.engine, DS_FN_LOCAL, now_expr(),
                          lit_str(c.engine, zoned[i].tz)),
                   lit_int(day)));
        if (ctx.faulted || v.kind != DS_RETE_VAL_TIME ||
            v.time.utc_ns != zoned[i].want ||
            v.time.tz_offset_s != zoned[i].off_s) {
            fprintf(stderr, "  zone %s\n", zoned[i].tz);
            rc |= fail("a zoned Time floors to its own midnight, offset kept");
        }
    }
    ctx = pinned_ctx(&c, t);
    v = eval1(&ctx, call_n(c.engine, DS_FN_FLOOR_TIME, now_expr(), lit_int(hour)));
    if (ctx.faulted || v.kind != DS_RETE_VAL_TIME ||
        v.time.utc_ns != 1711879200 * s || v.time.tz_offset_s != 0)
        rc |= fail("now() floors to 10:00:00Z and stays a Time");

    /* A zero Duration is DIVIDE_BY_ZERO; a negative one is a zero one
       ([LTIM.1.3.1]). A result before the first int64 ns is NOT_REPRESENTABLE
       ([LTIM.1.1.5]), never a wrap. */
    rc |= floor_time_cause(&c, lit_int(t), lit_int(0),
        DS_FAULT_DIVIDE_BY_ZERO, "floor to 0_s is DIVIDE_BY_ZERO");
    rc |= floor_time_cause(&c, lit_int(t), lit_int(-hour),
        DS_FAULT_DIVIDE_BY_ZERO, "floor to a negative Duration is 0_s's");
    rc |= floor_time_cause(&c, lit_int(INT64_MIN + 1), lit_int(hour),
        DS_FAULT_NOT_REPRESENTABLE, "a floor before 1677 is NOT_REPRESENTABLE");
    destroy_ctx(&c);
    return rc;
}

/* An interpolated segment is a ValuePrim in an INTERP, and one over a CALL
 * renders a String. The primitive over CALL(to_string, now) is built by hand,
 * apart from the compiler, the loader and the rule path. */
static ds_rete_expr_t *interp_of(ds_rete_expr_t *value)
{
    ds_rete_expr_t *e = ds_rete_expr_alloc(DS_RETE_EXPR_INTERP);
    e->interp.prim_count = 1;
    e->interp.prims = calloc(1, sizeof(ds_rete_fprim_t));
    e->interp.prims[0].kind  = DS_RETE_FPRIM_VALUE;   /* no spec: canonical */
    e->interp.prims[0].value = value;
    return e;
}

static int test_interp_wrapping_a_call(void)
{
    Ctx c = make_ctx();
    ds_rete_eval_ctx_t ctx = pinned_ctx(&c, 0);
    int rc = 0;

    /* Control: a primitive over a literal renders. */
    ds_rete_val_t v1 = eval1(&ctx, interp_of(lit_int(42)));
    if (v1.kind != DS_RETE_VAL_STR)
        rc = fail("INTERP(lit_int) should render a STR");
    else if (strcmp(v1.s.ptr, "42") != 0)
        rc = fail("INTERP(lit_int) rendered the wrong text");

    /* A primitive over a CALL. */
    ds_rete_val_t v2 = eval1(&ctx, interp_of(call_n(c.engine, DS_FN_TO_STRING,
                                                     now_expr(), NULL)));
    if (v2.kind != DS_RETE_VAL_STR) {
        fprintf(stderr, "  INTERP(CALL) kind=%d (STR=%d BOOL=%d NULL=%d)\n",
                (int)v2.kind, (int)DS_RETE_VAL_STR, (int)DS_RETE_VAL_BOOL,
                (int)DS_RETE_VAL_NULL);
        rc = fail("INTERP(CALL(to_string, now)) should render a STR");
    }

    destroy_ctx(&c);
    return rc;
}

int main(void)
{
    int fail_count = 0;
#define RUN(t) do { \
    int _r = (t)(); \
    if (_r) { fprintf(stderr, "  FAIL: " #t "\n"); fail_count++; } \
    else    { printf("  pass: " #t "\n"); } \
} while (0)

    printf("=== test_rete_time ===\n");
    RUN(test_now_is_time);
    RUN(test_fire_snapshot_at_epoch_is_a_snapshot);
    RUN(test_rt_clock_cache_at_epoch_is_populated);
    RUN(test_time_int_compare);
    RUN(test_time_time_compare);
    RUN(test_time_arith);
    RUN(test_time_arith_errors);
    RUN(test_utc);
    RUN(test_local_resolves);
    RUN(test_ltim_10_7__resolution);
    RUN(test_ltim_10_8__utc_needs_no_row);
    RUN(test_ltim_10_9__host_door_and_clone);
    RUN(test_ltim_10_5_3__refused_zone_is_domain);
    RUN(test_local_unknown_zone_errs);
    RUN(test_date_resolves);
    RUN(test_date_unresolved_errs);
    RUN(test_components_in_a_zone);
    RUN(test_monotonic);
    RUN(test_now_reads_wall_not_monotonic);
    RUN(test_now_faults_while_wall_unset);
    RUN(test_to_string_iso8601);
    RUN(test_to_string_epoch);
    RUN(test_ltim_14_1__calendar_builds);
    RUN(test_ltim_14_2__calendar_domain);
    RUN(test_ltim_14_2__calendar_not_representable);
    RUN(test_to_string_unknown_format);
    RUN(test_ltim_1_2_2__date_range);
    RUN(test_first_partial_day_splits_without_overflow);
    RUN(test_iso8601_render_at_an_offset);
    RUN(test_ltim_8_2_4__render_at_the_range_ends);
    RUN(test_duration_compact_form);
    RUN(test_calendar_shift);
    RUN(test_int_div_exact);
    RUN(test_ltim_7_1__floor_time);
    RUN(test_interp_wrapping_a_call);
#undef RUN

    if (fail_count == 0) {
        printf("=== test_rete_time: ALL PASSED ===\n");
        return 0;
    }
    fprintf(stderr, "=== test_rete_time: %d FAILED ===\n", fail_count);
    return 1;
}

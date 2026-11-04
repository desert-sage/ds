/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [LECC.1.5]
 * [NMET.4.1] rows, each driven by the event its "Emitted when" column names,
 * and asserted in name, kind, labels, value and count.
 *
 *   ds.errors.code_invariant_total{schema}  -- a CallError asserted with a
 *       malformed `code` (wm.c, LECC.1.2's rewrite).
 *   ds.clock.advance_total                  -- ds_engine_clock_advance, and
 *       NOT ds_engine_clock_set (clock.c).
 *   ds.recorder.events_emitted_total{kind}  -- a fact assert with no stream
 *       callback registered (recorder.c).
 *   ds.clock.tick_total                    -- the engine records an observed
 *       clock value: an input or a pump samples, and the sample is the first
 *       or either clock moved since the previous one (clock.c,
 *       ds_engine_clock_step). The setters count nothing.
 *
 * Not here: the two `ds.samples.*` rows, which libds does not emit while the
 * samples plane (NSTG.5) is deferred.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"

#include "engine.h"

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

/* Every metric named `watch` -- and, when `match_v0` is set, whose first
   label's value is `match_v0` -- as it arrived. Up to three labels kept,
   more than any row tested here carries. */
#define SEEN_LABELS 3
typedef struct {
    const char *watch;
    const char *match_v0;
    int         n;
    ds_metric_kind_t kind;
    double      value;
    size_t      n_labels;
    char        k[SEEN_LABELS][32];
    char        v[SEEN_LABELS][32];
} seen_t;

static ds_result_t on_metric(ds_engine_t *e, const ds_metric_t *m, void *user)
{
    (void)e;
    seen_t *s = user;
    if (strcmp(m->name, s->watch) != 0) return DS_OK_R;
    if (s->match_v0 != NULL
        && (m->n_labels < 1 || m->labels[0].value == NULL
            || strcmp(m->labels[0].value, s->match_v0) != 0))
        return DS_OK_R;
    s->n++;
    s->kind     = m->kind;
    s->value    = m->value;
    s->n_labels = m->n_labels;
    for (size_t i = 0; i < SEEN_LABELS; i++) { s->k[i][0] = '\0'; s->v[i][0] = '\0'; }
    for (size_t i = 0; i < m->n_labels && i < SEEN_LABELS; i++) {
        strncpy(s->k[i], m->labels[i].key ? m->labels[i].key : "", 31);
        strncpy(s->v[i], m->labels[i].value ? m->labels[i].value : "", 31);
    }
    return DS_OK_R;
}

static void expect_counter(const seen_t *s, int n, size_t n_labels)
{
    if (s->n != n)
        fprintf(stderr, "  %s: %d observation(s), want %d\n", s->watch, s->n, n);
    CHECK(s->n == n, "the expected number of emits");
    if (n == 0) return;
    CHECK(s->kind == DS_METRIC_COUNTER, "a counter");
    CHECK(s->value == 1.0, "delta 1.0");
    CHECK(s->n_labels == n_labels, "the row's label count");
}

static ds_engine_t *new_engine(seen_t *s)
{
    ds_engine_config_t cfg = {0};
    ds_engine_t *e = NULL;
    CHECK_OK(ds_engine_new(&cfg, &e), "engine_new");
    if (e) CHECK_OK(ds_engine_set_metric_callback(e, on_metric, s), "metric cb");
    return e;
}

static const ds_slot_desc_t CALL_ERROR_SLOTS[2] = {
    { .name = "corr", .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
    { .name = "code", .type = DS_SLOT_TYPE_STRING,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static void test_code_invariant(void)
{
    seen_t s = { .watch = "ds.errors.code_invariant_total" };
    ds_engine_t *e = new_engine(&s);
    if (!e) return;
    const ds_schema_t *ce = NULL;
    CHECK_OK(ds_engine_register_schema(e, "CallError", DS_SCHEMA_LIFECYCLE_TTL,
                                       1000000000ull, CALL_ERROR_SLOTS, 2, &ce),
             "register CallError");
    ds_slot_value_t v[2];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_STRING; v[0].v.s = "c1";
    v[1].kind = DS_SLOT_STRING; v[1].v.s = "Not A Code!";
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, ce, v, 2, &f), "assert a malformed code");
    v[1].v.s = "timeout.upstream";
    CHECK_OK(ds_engine_assert(e, ce, v, 2, &f), "assert a well-formed code");
    expect_counter(&s, 1, 1);
    CHECK(strcmp(s.k[0], "schema") == 0, "label key `schema`");
    CHECK(strcmp(s.v[0], "CallError") == 0, "label value `CallError`");
    ds_engine_free(e);
}

static void test_clock_advance(void)
{
    seen_t s = { .watch = "ds.clock.advance_total" };
    ds_engine_t *e = new_engine(&s);
    if (!e) return;
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock_set");
    CHECK(s.n == 0, "clock_set does not count as an advance");
    CHECK_OK(ds_engine_clock_advance(e, 500), "clock_advance");
    expect_counter(&s, 1, 0);
    ds_engine_free(e);
}

static const ds_slot_desc_t LEVEL_SLOTS[1] = {
    { .name = "level", .type = DS_SLOT_TYPE_INT,
      .identity_role = DS_IDENTITY_UNSPECIFIED },
};

static void test_recorder_events_emitted(void)
{
    seen_t s = { .watch = "ds.recorder.events_emitted_total",
                 .match_v0 = "fact_assert" };
    ds_engine_t *e = new_engine(&s);
    if (!e) return;
    const ds_schema_t *r = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       1000000000ull, LEVEL_SLOTS, 1, &r),
             "register Reading");
    /* No stream callback is registered: the row says it counts anyway. */
    ds_slot_value_t v[1];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 3;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, r, v, 1, &f), "assert Reading");
    expect_counter(&s, 1, 1);
    CHECK(strcmp(s.k[0], "kind") == 0, "label key `kind`");
    CHECK(strcmp(s.v[0], "fact_assert") == 0, "label value `fact_assert`");
    ds_engine_free(e);
}

/* [NMET.4.1]'s ds.clock.tick_total row. The running count is checked after
   every step, so an emit in the wrong place shows one step early or late:

     the setters move the source and count nothing ([NTST.3.3]);
     the first sample counts;
     a sample with neither clock moved counts nothing;
     a sample after the monotonic clock moved counts once, however many
       setter calls moved it;
     a sample after only the WALL clock moved counts too ("either clock");
     an input samples as a pump does ([LTIM.2.8.4]). */
static void test_clock_tick(void)
{
    seen_t s = { .watch = "ds.clock.tick_total" };
    ds_engine_t *e = new_engine(&s);
    if (!e) return;
    /* Registered before the first pump: the structural intern set freezes
       there, and a later register_schema is refused. */
    const ds_schema_t *r = NULL;
    CHECK_OK(ds_engine_register_schema(e, "Reading", DS_SCHEMA_LIFECYCLE_TTL,
                                       1000000000ull, LEVEL_SLOTS, 1, &r),
             "register Reading");
    CHECK_OK(ds_engine_clock_set_mode(e, DS_CLOCK_MOCK), "mock clock");
    CHECK_OK(ds_engine_clock_set(e, 1000), "clock_set");
    CHECK_OK(ds_engine_clock_advance(e, 500), "clock_advance");
    CHECK(s.n == 0, "registering, clock_set and clock_advance count nothing");

    CHECK_OK(ds_engine_pump(e), "pump: the first sample");
    CHECK(s.n == 1, "the first sample counts");

    CHECK_OK(ds_engine_pump(e), "pump: nothing moved");
    CHECK(s.n == 1, "a sample with neither clock moved counts nothing");

    CHECK_OK(ds_engine_clock_advance(e, 10), "advance");
    CHECK_OK(ds_engine_clock_advance(e, 10), "advance again");
    CHECK(s.n == 1, "advances between samples count nothing yet");
    CHECK_OK(ds_engine_pump(e), "pump: the monotonic clock moved");
    CHECK(s.n == 2, "two advances, one sample: one tick");

    CHECK_OK(ds_engine_wall_clock_set(e, 1700000000000000000ll),
             "set the wall clock only");
    CHECK_OK(ds_engine_pump(e), "pump: only the wall clock moved");
    CHECK(s.n == 3, "a moved wall clock counts as either clock moving");

    int before_input = s.n;
    CHECK_OK(ds_engine_clock_advance(e, 10), "advance before an input");
    ds_slot_value_t v[1];
    memset(v, 0, sizeof v);
    v[0].kind = DS_SLOT_INT; v[0].v.i = 7;
    ds_fact_t *f = NULL;
    CHECK_OK(ds_engine_assert(e, r, v, 1, &f), "assert: an input samples");
    CHECK(s.n == before_input + 1, "an input's sample counts as a pump's does");

    expect_counter(&s, s.n, 0);
    CHECK(s.n == 4, "four ticks in all");
    ds_engine_free(e);
}

int main(void)
{
    test_code_invariant();
    test_clock_advance();
    test_recorder_events_emitted();
    test_clock_tick();

    if (failures == 0) {
        printf("OK  test_nmet_4_1_inventory\n");
        return 0;
    }
    fprintf(stderr, "FAILED: %d check(s)\n", failures);
    return 1;
}

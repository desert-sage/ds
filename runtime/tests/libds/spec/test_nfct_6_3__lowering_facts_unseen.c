/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [NFCT.6.3]: the fact API sees only the program's facts. A fact the
 * lowering creates for its own use -- an `after` clause's timer fact and its
 * capture fact ([RFCS.6a.5]) -- is neither counted by ds_engine_fact_count nor
 * visited by ds_engine_for_each_fact, unfiltered or by schema.
 *
 * The program: `wait` matches a Go and arms `after 5_s`, whose body reads
 * `g.v`, so the firing leaves one timer fact and one capture fact live inside
 * the engine. After the assert and one pump:
 *   1. ds_engine_fact_count is 1, the Go;
 *   2. ds_engine_for_each_fact(e, NULL, ...) visits the Go and nothing else;
 *   3. no schema the engine registers is the timer's or the capture's: libds
 *      does not register them, so a caller cannot name them, and a walk of
 *      ds_engine_for_each_fact over every registered schema visits the Go
 *      alone. A synthetic name is `$`-led ([LLEX.10.6.1]); the `__X__` form
 *      is checked too.
 * Then the clock passes the deadline and one pump runs the follow-up, which
 * emits a Fired: the timer was live, so the checks above were not vacuous.
 *
 * Path: dsc/loader.c's dsc_apply, which keeps synthetic schemas out of the
 * working-memory registry and registers them with the Rete schema registry
 * only, so their facts never reach the store the fact API reads.
 */
#include "spec_common.h"

#define T0      ((uint64_t) 1000000000)     /* 1 s: the assert's instant */
#define DELAY   ((uint64_t) 5000000000)     /* `after 5_s` */

static int is_synthetic_name(const char *nm)
{
    return nm != NULL && (nm[0] == '$' || (nm[0] == '_' && nm[1] == '_'));
}

typedef struct {
    const ds_schema_t *go;
    const ds_schema_t *fired;
    int go_seen;
    int fired_seen;
    int other_seen;
} tally_t;

static ds_result_t tally(const ds_fact_t *fact, void *user)
{
    tally_t *t = (tally_t *) user;
    const ds_schema_t *s = NULL;
    ds_result_t r = ds_fact_get_schema(fact, &s);
    if (r.status != DS_OK) return r;
    if (s == t->go)         t->go_seen++;
    else if (s == t->fired) t->fired_seen++;
    else                    t->other_seen++;
    return DS_OK_R;
}

/* Every registered schema: none synthetic, and the facts visited through all
   of them together. */
static int walk_registered(ds_engine_t *e, tally_t *t)
{
    size_t n = 0;
    ds_result_t r = ds_engine_schema_count(e, &n);
    EXPECT_OK("schema_count", r);
    for (size_t i = 0; i < n; i++) {
        const ds_schema_t *s = NULL;
        r = ds_engine_schema_at(e, i, &s);
        EXPECT_OK("schema_at", r);
        const char *nm = NULL;
        r = ds_schema_get_name(s, &nm);
        EXPECT_OK("schema_get_name", r);
        if (is_synthetic_name(nm)) {
            fprintf(stderr, "FAIL: the engine registers the synthetic schema "
                            "%s, so the fact API can name it\n", nm);
            return 1;
        }
        r = ds_engine_for_each_fact(e, s, tally, t);
        EXPECT_OK("for_each_fact by schema", r);
    }
    return 0;
}

/* @spec [NFCT.6.3] */
int main(void)
{
    ds_engine_t *e = NULL;
    ds_result_t r = ds_engine_new(NULL, &e);
    EXPECT_OK("engine_new", r);
    r = ds_engine_clock_set_mode(e, DS_CLOCK_MOCK);
    EXPECT_OK("clock_set_mode", r);
    r = ds_engine_clock_set(e, T0);
    EXPECT_OK("clock_set T0", r);
    r = spec_load_ds(e,
        "schema Go scope logical:\n"
        "    v: Int key\n"
        "\n"
        "schema Fired scope ttl 1_h:\n"
        "    v: Int\n"
        "\n"
        "rule wait:\n"
        "    Go g\n"
        "->\n"
        "    after 5_s:\n"
        "        emit Fired v: g.v\n");
    EXPECT_OK("load the program", r);

    tally_t t = {0};
    r = ds_engine_schema_find(e, "Go", &t.go);
    if (r.status != DS_OK || t.go == NULL) return spec_fail("schema_find Go", r);
    r = ds_engine_schema_find(e, "Fired", &t.fired);
    if (r.status != DS_OK || t.fired == NULL) return spec_fail("schema_find Fired", r);

    ds_slot_value_t go[] = { { .kind = DS_SLOT_INT, .v.i = 7 } };
    r = ds_engine_assert(e, t.go, go, 1, NULL);
    EXPECT_OK("assert Go", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump: `wait` fires and arms the timer", r);

    /* 1. The count. */
    size_t live = 99;
    r = ds_engine_fact_count(e, &live);
    EXPECT_OK("fact_count with the timer armed", r);
    if (live != 1) {
        fprintf(stderr, "FAIL: fact_count is %zu with the timer armed; want 1, "
                        "the Go alone\n", live);
        return 1;
    }

    /* 2. The unfiltered walk. */
    r = ds_engine_for_each_fact(e, NULL, tally, &t);
    EXPECT_OK("for_each_fact unfiltered", r);
    if (t.go_seen != 1 || t.fired_seen != 0 || t.other_seen != 0) {
        fprintf(stderr, "FAIL: the unfiltered walk saw Go %d, Fired %d, other %d; "
                        "want 1, 0, 0\n", t.go_seen, t.fired_seen, t.other_seen);
        return 1;
    }

    /* 3. Every registered schema, by schema. */
    tally_t by = { t.go, t.fired, 0, 0, 0 };
    if (walk_registered(e, &by)) return 1;
    if (by.go_seen != 1 || by.fired_seen != 0 || by.other_seen != 0) {
        fprintf(stderr, "FAIL: the walk by schema saw Go %d, Fired %d, other %d; "
                        "want 1, 0, 0\n", by.go_seen, by.fired_seen, by.other_seen);
        return 1;
    }

    /* 4. The timer was live: past its deadline, the follow-up emits a Fired. */
    r = ds_engine_clock_set(e, T0 + DELAY + 1000000000);
    EXPECT_OK("clock past the deadline", r);
    r = ds_engine_pump(e);
    EXPECT_OK("pump: the follow-up runs", r);
    r = ds_engine_fact_count(e, &live);
    EXPECT_OK("fact_count after the follow-up", r);
    tally_t after = { t.go, t.fired, 0, 0, 0 };
    r = ds_engine_for_each_fact(e, NULL, tally, &after);
    EXPECT_OK("for_each_fact after the follow-up", r);
    if (live != 2 || after.go_seen != 1 || after.fired_seen != 1
            || after.other_seen != 0) {
        fprintf(stderr, "FAIL: after the follow-up, fact_count %zu, Go %d, "
                        "Fired %d, other %d; want 2, 1, 1, 0 -- the timer did "
                        "not fire, so nothing above was checked against a live "
                        "one\n", live, after.go_seen, after.fired_seen,
                        after.other_seen);
        return 1;
    }

    ds_engine_free(e);
    printf("test_nfct_6_3__lowering_facts_unseen: OK\n");
    return 0;
}

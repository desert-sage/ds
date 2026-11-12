/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * spec_deadline.h — the program and helpers the test_nlfc_2_5__* tests share.
 *
 * Public API only, as spec_common.h. Each instant is the mock clock's: the
 * cache entry's TTL is 10 s, the `Lease` fact's 20 s and the `after` timer's
 * 30 s, so armed together at one instant the three kinds fall due in that
 * order ([NLFC.2.5]'s three deadlines).
 */
#ifndef LIBDS2_SPEC_DEADLINE_H
#define LIBDS2_SPEC_DEADLINE_H

#include <stdbool.h>

#include "spec_common.h"

#define DL_SEC 1000000000ull

/* `Arm` arms an `after` timer, `Lease` is a `ttl` fact, `Write` writes a cache
   entry with a TTL and `Drop` deletes it. A function, so that a test that does
   not load it carries no unused definition. */
static inline const char *dl_program(void)
{
    return
    "schema Arm scope logical:\n"
    "    id: Int key\n"
    "\n"
    "schema Lease scope ttl 20_s:\n"
    "    id: Int\n"
    "\n"
    "schema Write scope logical:\n"
    "    id: Int key\n"
    "\n"
    "schema Drop scope logical:\n"
    "    id: Int key\n"
    "\n"
    "rule arm_timer:\n"
    "    Arm\n"
    "->\n"
    "    after 30_s:\n"
    "        log critical \"fired\"\n"
    "\n"
    "rule write_cache:\n"
    "    Write\n"
    "->\n"
    "    cache key: \"k\" value: 1 ttl: 10_s\n"
    "\n"
    "rule drop_cache:\n"
    "    Drop\n"
    "->\n"
    "    cache_delete key: \"k\"\n";
}

static inline int dl_fail(const char *what, const char *why)
{
    fprintf(stderr, "FAIL: %s: %s\n", what, why);
    return 1;
}

/* A fresh engine on the mock clock at 0, with `src` loaded. */
static inline int dl_engine(ds_engine_t **e, const char *src)
{
    *e = NULL;
    EXPECT_OK("engine", ds_engine_new(NULL, e));
    EXPECT_OK("mock clock", ds_engine_clock_set_mode(*e, DS_CLOCK_MOCK));
    EXPECT_OK("clock_set 0", ds_engine_clock_set(*e, 0));
    EXPECT_OK("load", spec_load_ds(*e, src));
    return 0;
}

/* Assert one fact of `schema`, whose one slot is the Int `id`. */
static inline int dl_assert(ds_engine_t *e, const char *schema, int64_t id,
                            ds_fact_t **out)
{
    const ds_schema_t *s = NULL;
    EXPECT_OK(schema, ds_engine_schema_find(e, schema, &s));
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i  = id;
    EXPECT_OK(schema, ds_engine_assert(e, s, &v, 1, out));
    return 0;
}

/* The call answers DS_OK with `want_has` and, when it is true, `want_ns`;
   with it false, *out_ns is 0. */
static inline int dl_expect(const char *what, ds_engine_t *e, bool want_has,
                            uint64_t want_ns)
{
    uint64_t ns  = 12345u;
    bool     has = !want_has;
    EXPECT_OK(what, ds_engine_next_deadline_ns(e, &ns, &has));
    if (has != want_has || ns != (want_has ? want_ns : 0u)) {
        fprintf(stderr, "FAIL: %s: has=%d ns=%llu, want has=%d ns=%llu\n",
                what, (int) has, (unsigned long long) ns, (int) want_has,
                (unsigned long long) (want_has ? want_ns : 0u));
        return 1;
    }
    return 0;
}

/* Arm all three kinds at the current clock: a cache write, a timer and a
   `Lease` fact, pumped. */
static inline int dl_all_three(ds_engine_t *e, ds_fact_t **lease)
{
    if (dl_assert(e, "Write", 1, NULL)) return 1;
    if (dl_assert(e, "Arm", 1, NULL)) return 1;
    if (dl_assert(e, "Lease", 1, lease)) return 1;
    EXPECT_OK("pump", ds_engine_pump(e));
    return 0;
}

#endif /* LIBDS2_SPEC_DEADLINE_H */

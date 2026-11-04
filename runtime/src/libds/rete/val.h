/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rete/val.h — the value system (IRET.3.1).
 *
 * DS_RETE_VAL_UNBOUND is bind-slot occupancy, not failure: `eval_actions` pre-fills
 * a terminal's bind frame with it, and `BIND_REF` tests for it to raise
 * ENGINE_FAULT_BINDING_ORDER ([RARC.5.6.11]). It never becomes an operand. It is
 * not `null`, which a `let` may legitimately bind.
 */
#ifndef LIBDS2_INTERNAL_RETE_VAL_H
#define LIBDS2_INTERNAL_RETE_VAL_H

#include <stdbool.h>
#include <stdint.h>

/* ds_json_t is the public JSON tree type from libds.h.
 * Forward-declared here so val.h doesn't need to include libds.h. */
struct ds_json;
struct ds_rete_fact;

typedef enum {
    DS_RETE_VAL_INT      = 0,  /* int64_t                              */
    DS_RETE_VAL_FLOAT    = 1,  /* double                               */
    DS_RETE_VAL_STR      = 2,  /* interned: const char * + uint32_t len*/
    DS_RETE_VAL_BOOL     = 3,  /* bool                                 */
    DS_RETE_VAL_JSON     = 4,  /* heap-allocated ds_json_t *           */
    DS_RETE_VAL_UNBOUND  = 5,  /* bind-slot occupancy; not a wire type */
    DS_RETE_VAL_BYTES    = 6,  /* interned, as STR; the intern tracks length,
                                  so NULs survive */
    DS_RETE_VAL_FACT_REF = 7,  /* the target's rete id, never a pointer: a
                                  target can leave WM while the referrer stays.
                                  Ids are never reused, so a stale reference
                                  matches nothing. 0 is no target. */
    DS_RETE_VAL_JSON_BORROW = 8, /* a borrowed JSON pointer, not freed on
                                    retract, and otherwise read as JSON */
    DS_RETE_VAL_NULL     = 10, /* [LNUL.9.1] the canonical `null`, a real data
                                  value ([LNUL.8.1], [LNUL.8.8]) */
    DS_RETE_VAL_TIME     = 9,  /* zoned instant ([LTIM.1.1.1]): utc_ns, and the
                                  offset in whole seconds. Ordering, equality
                                  and arithmetic use utc_ns only ([LTIM.1.1.2],
                                  [LTIM.5.2]). */
    DS_RETE_VAL_RATIO    = 11, /* [LUNI.13.5] an exact fractional-currency
                                  intermediate, num/den, den > 0, between
                                  FN_CURRENCY_CONVERT and FN_CURRENCY_ROUND /
                                  _ROUND_TO. A rational because `half_even`
                                  decides ties, which a double cannot represent
                                  (2.675 is not a double). Never reaches a slot
                                  or the wire ([LUNI.13.5.2]). */
} ds_rete_val_kind_t;

/* Tagged because dispatcher.h forward-declares `struct ds_rete_val`. */
typedef struct ds_rete_val {
    ds_rete_val_kind_t kind;
    union {
        int64_t  i;
        double   f;
        bool     b;
        struct { const char *ptr; uint32_t len; } s; /* interned —
                                                        STR or BYTES */
        struct ds_json *json;                         /* heap      */
        uint32_t fact_ref_id;                         /* FACT_REF:
                                                        the target's
                                                        rete id, 0 =
                                                        no target */
        struct { int64_t utc_ns; int32_t tz_offset_s; } time; /* TIME */
        struct { int64_t num; int64_t den; } ratio;           /* RATIO */
    };
} ds_rete_val_t;

/* Convenience constructors */
static inline ds_rete_val_t ds_rete_val_int(int64_t v)
{
    ds_rete_val_t r; r.kind = DS_RETE_VAL_INT;   r.i = v; return r;
}
static inline ds_rete_val_t ds_rete_val_float(double v)
{
    ds_rete_val_t r; r.kind = DS_RETE_VAL_FLOAT;  r.f = v; return r;
}
static inline ds_rete_val_t ds_rete_val_bool(bool v)
{
    ds_rete_val_t r; r.kind = DS_RETE_VAL_BOOL;   r.b = v; return r;
}
/* A String value is its `len` bytes from `p`, and every reader inside libds takes
   `len`. Every producer also writes a NUL at p[len], for strings handed out
   through libds.h as C strings; a view with no terminator must not reach that
   boundary. */
static inline ds_rete_val_t ds_rete_val_str(const char *p, uint32_t len)
{
    ds_rete_val_t r;
    r.kind   = DS_RETE_VAL_STR;
    r.s.ptr  = p;
    r.s.len  = len;
    return r;
}
static inline ds_rete_val_t ds_rete_val_bytes(const char *p, uint32_t len)
{
    ds_rete_val_t r;
    r.kind   = DS_RETE_VAL_BYTES;
    r.s.ptr  = p;
    r.s.len  = len;
    return r;
}
static inline ds_rete_val_t ds_rete_val_unbound(void)
{
    ds_rete_val_t r; r.kind = DS_RETE_VAL_UNBOUND; r.i = 0; return r;
}
/* A Json tree someone else owns -- a fact's slot, or a tree the engine keeps
   until the next pump -- read and never freed through this value. */
static inline ds_rete_val_t ds_rete_val_json_borrow(const struct ds_json *j)
{
    ds_rete_val_t r;
    r.kind = DS_RETE_VAL_JSON_BORROW;
    r.json = (struct ds_json *)j;
    return r;
}
static inline ds_rete_val_t ds_rete_val_null(void)
{
    ds_rete_val_t r; r.kind = DS_RETE_VAL_NULL; r.i = 0; return r;
}
/* tz_offset_s is whole seconds east of UTC. */
static inline ds_rete_val_t ds_rete_val_time(int64_t utc_ns,
                                             int32_t tz_offset_s)
{
    ds_rete_val_t r;
    r.kind             = DS_RETE_VAL_TIME;
    r.time.utc_ns      = utc_ns;
    r.time.tz_offset_s = tz_offset_s;
    return r;
}
/* The caller normalises the sign onto `num`, so `den > 0`. */
static inline ds_rete_val_t ds_rete_val_ratio(int64_t num, int64_t den)
{
    ds_rete_val_t r;
    r.kind      = DS_RETE_VAL_RATIO;
    r.ratio.num = num;
    r.ratio.den = den;
    return r;
}

#endif /* LIBDS2_INTERNAL_RETE_VAL_H */

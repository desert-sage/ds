/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * `libds.h` names no series type and no series read. The series-backend
 * vtable, its decl, ABI version, magics and decl-only enums are libds's own
 * shape ([NSBK.2.3], [ISBK.1]); no public function reads a series
 * ([NSBK.6.3]); the aggregation kind, its bit macro and the element type are
 * `series/backend.h`'s ([ISBK.1.1], [ISBK.2.1]).
 *
 * Only `libds.h` is included, and the test is that this file compiles: each
 * name below is declared as something else, so a `libds.h` that declares it
 * is a conflicting redeclaration, and each macro is an `#error` if `libds.h`
 * defines it.
 */
#include <stdio.h>

#include "libds.h"

/* ---- the backend's shape ---- */
#if defined(DS_SERIES_BACKEND_ABI_VERSION)
#error "libds.h defines DS_SERIES_BACKEND_ABI_VERSION"
#endif
#if defined(DS_SERIES_MAKE_MAGIC)
#error "libds.h defines DS_SERIES_MAKE_MAGIC"
#endif
#if defined(DS_SERIES_MAGIC_SBWE) || defined(DS_SERIES_MAGIC_SBRB) \
    || defined(DS_SERIES_MAGIC_SBMD) || defined(DS_SERIES_MAGIC_SBFD) \
    || defined(DS_SERIES_MAGIC_SBRS) || defined(DS_SERIES_MAGIC_SBIP) \
    || defined(DS_SERIES_MAGIC_SBNI)
#error "libds.h defines a DS_SERIES_MAGIC_SB*"
#endif

typedef struct { char c; } ds_series_backend_vtable_t;
typedef struct { char c; } ds_series_decl_t;
typedef struct { char c; } ds_series_time_model_t;
typedef struct { char c; } ds_series_gap_policy_t;
enum { DS_SERIES_TIME_MODEL_SLIDING = 101, DS_SERIES_GAP_POLICY_HOLD = 102 };

/* ---- the series reads' and the samples plane's types ---- */
#if defined(DS_SERIES_AGG_BIT)
#error "libds.h defines DS_SERIES_AGG_BIT"
#endif

typedef struct { char c; } ds_series_agg_kind_t;
typedef struct { char c; } ds_series_element_type_t;
typedef struct { char c; } ds_series_storage_mode_t;
typedef struct { char c; } ds_series_declaration_t;
typedef struct { char c; } ds_sample_t;
typedef struct { char c; } ds_sample_cb_t;
typedef struct { char c; } ds_series_declared_cb_t;
enum {
    DS_SERIES_AGG_MIN         = 201,
    DS_SERIES_AGG_PERCENTILE  = 202,
    DS_SERIES_ELEMENT_FLOAT   = 203,
    DS_SERIES_ACCUMULATOR     = 204,
    DS_SERIES_RING_BUFFER     = 205,
};

/* ---- the series reads: an object of a function's name conflicts with the
   function's declaration ---- */
static int ds_engine_series_read_at = 301;
static int ds_engine_series_read_value_at = 302;
static int ds_engine_set_sample_callback = 303;
static int ds_engine_set_series_declared_callback = 304;

int main(void)
{
    ds_series_backend_vtable_t v = { 'v' };
    ds_series_decl_t d = { 'd' };
    ds_series_time_model_t tm = { 't' };
    ds_series_gap_policy_t gp = { 'g' };
    ds_series_agg_kind_t agg = { 'a' };
    ds_series_element_type_t el = { 'e' };
    ds_series_storage_mode_t sm = { 's' };
    ds_series_declaration_t decl = { 'D' };
    ds_sample_t smp = { 'S' };
    ds_sample_cb_t scb = { 'c' };
    ds_series_declared_cb_t dcb = { 'C' };
    if (v.c != 'v' || d.c != 'd' || tm.c != 't' || gp.c != 'g'
        || agg.c != 'a' || el.c != 'e' || sm.c != 's' || decl.c != 'D'
        || smp.c != 'S' || scb.c != 'c' || dcb.c != 'C'
        || DS_SERIES_TIME_MODEL_SLIDING != 101
        || DS_SERIES_AGG_MIN != 201 || DS_SERIES_RING_BUFFER != 205
        || ds_engine_series_read_at != 301
        || ds_engine_series_read_value_at != 302
        || ds_engine_set_sample_callback != 303
        || ds_engine_set_series_declared_callback != 304) {
        fprintf(stderr, "FAIL: test_series_backend_internal\n");
        return 1;
    }
    printf("OK  test_series_backend_internal\n");
    return 0;
}

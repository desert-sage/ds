/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * series/backend.h — the series-backend vtable and the declaration it is
 * handed ([ISBK.1], [ISBK.2]). Internal: an integrator supplies no vtable
 * ([NSBK.2.3]).
 *
 * A backing is named by its atom's field number, the generated `DS_ATOM_*` of
 * `rfcs/atoms.h` ([RDSC.7.1]).
 */
#ifndef LIBDS2_INTERNAL_SERIES_BACKEND_H
#define LIBDS2_INTERNAL_SERIES_BACKEND_H

#include <stdint.h>

#include "libds.h"
#include "../rfcs/atoms.h"

/* [ISBK.1.7] The vtable's `abi_version` must equal this; libds refuses a
   mismatch at registration with DS_ERR_BACKEND_ABI_VERSION. Fields are added
   at the tail only, and each addition bumps it. */
#define DS_SERIES_BACKEND_ABI_VERSION 5u

/* [ISBK.2.1]. The C mirror of
   proto/series_backend_ring_buffer.proto#SeriesElementType; the spec gate's
   styl_5_9_2_fault_enums holds the two together. */
typedef enum ds_series_element_type {
    DS_SERIES_ELEMENT_UNSPECIFIED = 0,
    DS_SERIES_ELEMENT_FLOAT       = 1,
    DS_SERIES_ELEMENT_INT         = 2,
    DS_SERIES_ELEMENT_STRING      = 3,
    DS_SERIES_ELEMENT_BOOL        = 4,
} ds_series_element_type_t;

/* [ISBK.1.1]. Values are bit positions in a backend's `supported_aggs`. The C
   mirror of specs/registry/series_agg.ebnf; the spec gate's
   styl_5_9_2_ebnf_c_mirror holds the two together. */
typedef enum ds_series_agg_kind {
    DS_SERIES_AGG_AVG            = 0,
    DS_SERIES_AGG_MEDIAN         = 1,
    DS_SERIES_AGG_STDEV          = 2,
    DS_SERIES_AGG_PSTDEV         = 3,
    DS_SERIES_AGG_VARIANCE       = 4,
    DS_SERIES_AGG_PVARIANCE      = 5,
    DS_SERIES_AGG_MIN            = 6,
    DS_SERIES_AGG_MAX            = 7,
    DS_SERIES_AGG_RATE           = 8,
    DS_SERIES_AGG_DIRECTION      = 9,
    /* 10-14 are retired and never reissued ([STYL.2.8.7]). */
    DS_SERIES_AGG_COUNT          = 15,
    DS_SERIES_AGG_SUM            = 16,
    DS_SERIES_AGG_FIRST          = 17,
    DS_SERIES_AGG_LAST           = 18,
    DS_SERIES_AGG_BOOL_AND       = 19,
    DS_SERIES_AGG_BOOL_OR        = 20,
    DS_SERIES_AGG_COUNT_DISTINCT = 21,
    /* The lookup value rides the query_with_value hook. */
    DS_SERIES_AGG_COUNT_OF       = 22,
    DS_SERIES_AGG_CONTAINS       = 23,
    DS_SERIES_AGG_ACTIVE_FRACTION = 24,   /* SeriesBackendIntervalPulse — time-true fraction */
    DS_SERIES_AGG_ONSET_RATE      = 25,   /* SeriesBackendRingBuffer — rising edges / sec */
    DS_SERIES_AGG_INTEGRAL        = 26,   /* SeriesBackendNumericIntegral — time-weighted integral */
    /* LSER.17.6: the percentile N (1..99) rides the query_with_value hook. */
    DS_SERIES_AGG_PERCENTILE      = 27,   /* SeriesBackendRingBuffer — exact Nth percentile */
} ds_series_agg_kind_t;

#define DS_SERIES_AGG_BIT(k) (1ULL << ((unsigned)(k)))

/* LSIG.2.3.6: the numeric integral's time model and gap policy. Mirror the
   SeriesTimeModel and SeriesGapPolicy proto enums. */
typedef enum ds_series_time_model {
    DS_SERIES_TIME_MODEL_UNSPECIFIED = 0,
    DS_SERIES_TIME_MODEL_SLIDING     = 1,
    DS_SERIES_TIME_MODEL_ALL_TIME    = 2,
    DS_SERIES_TIME_MODEL_TUMBLING    = 3,
} ds_series_time_model_t;

typedef enum ds_series_gap_policy {
    DS_SERIES_GAP_POLICY_UNSPECIFIED = 0,   /* treated as HOLD (LSIG.3.1) */
    DS_SERIES_GAP_POLICY_HOLD        = 1,
    DS_SERIES_GAP_POLICY_ZERO        = 2,
    DS_SERIES_GAP_POLICY_SKIP        = 3,
} ds_series_gap_policy_t;

/* [ISBK.2.1] The series declaration handed to instance_new. Strings are borrowed
   for the call. */
typedef struct ds_series_decl {
    const char *schema_name;
    const char *slot_name;
    const char *identity_slot_name;  /* "" for `by: none` */

    uint64_t window_ns;               /* 0 = unwindowed */
    uint64_t persist_ns;              /* 0 = live-only */

    /* Mode-specific extras. The backend dispatches on its own
       atom_field, so it knows which fields are meaningful:
         element_type — SeriesBackendRingBuffer, SeriesBackendFifoDeque,
         SeriesBackendMonotonicDeque
         max_samples  — SeriesBackendRingBuffer (window cap),
         SeriesBackendReservoir (reservoir k) */
    uint32_t atom_field;              /* the backing atom's DS_ATOM_SERIES_BACKEND_* */
    ds_series_element_type_t element_type;  /* 0 = unspecified */
    uint32_t max_samples;             /* 0 = backend default */
    /* SeriesBackendNumericIntegral only; 0 for every other backing. */
    uint32_t time_model;              /* ds_series_time_model_t */
    uint32_t gap_policy;              /* ds_series_gap_policy_t */
} ds_series_decl_t;

/* [ISBK.1] The contract between the engine and one of libds's seven backends. */
typedef struct ds_series_backend_vtable {
    /* Header — REQUIRED. */
    uint32_t    abi_version;          /* must equal DS_SERIES_BACKEND_ABI_VERSION */
    const char *backend_name;          /* "welford-ewma", "ring-buffer", etc. */
    const char *backend_version;       /* impl-defined; part of replay platform sig */
    uint32_t    atom_field;            /* the backing atom's DS_ATOM_SERIES_BACKEND_* ([ISBK.1.1]) */
    uint64_t    supported_aggs;        /* bitmask of DS_SERIES_AGG_* ordinals */

    /* Per-instance lifecycle — REQUIRED. */
    ds_result_t (*instance_new)(const ds_series_decl_t *decl,
                                void **out_state);
    void        (*instance_free)(void *state);

    /* Sample absorption — REQUIRED. A kind the backend does not support is
       DS_ERR_INVAL. */
    ds_result_t (*update)(void                  *state,
                          const ds_slot_value_t *value,
                          uint64_t               ts_ns);

    /* Query — REQUIRED. The backend sets out_value's `kind`. */
    ds_result_t (*query)(void               *state,
                         ds_series_agg_kind_t agg_kind,
                         uint64_t             window_ns,
                         ds_slot_value_t     *out_value);

    /* Eviction sweep — OPTIONAL (NULL ok), with the engine clock (LSER.9.3.1). */
    void (*evict_stale)(void *state, uint64_t now_ns);

    /* Value-arg query — OPTIONAL (NULL ok), for aggs that take a lookup value.
       k_param 0 is the backend's default. NULL falls back to the zero/false
       default in the dispatch trampoline. */
    ds_result_t (*query_with_value)(void                   *state,
                                    ds_series_agg_kind_t    agg_kind,
                                    uint64_t                window_ns,
                                    const ds_slot_value_t  *lookup_value,
                                    uint32_t                k_param,
                                    ds_slot_value_t        *out_value);

    /* Deep copy — OPTIONAL (NULL ok): verbatim, PRNG state included, so a cloned
       engine's series are exact ([IARC.11.2], [LDET.2.2b]). Released via
       instance_free. With NULL, ds_engine_clone refuses (DS_ERR_STATE) an engine
       holding a live row on this backend. */
    ds_result_t (*instance_clone)(const void *state, void **out_state);

    /* Query as of a monotonic time — OPTIONAL (NULL ok) (LSIG.2.5). `now_ns` is
       the step's held sample ([ISBK.1.8]), raised to the last absorb time where
       it is behind it. Read-only. With NULL, the trampoline falls back to
       `query`, as of the last absorb. */
    ds_result_t (*query_at)(void                 *state,
                            ds_series_agg_kind_t  agg_kind,
                            uint64_t              window_ns,
                            uint64_t              now_ns,
                            ds_slot_value_t      *out_value);
} ds_series_backend_vtable_t;

#endif  /* LIBDS2_INTERNAL_SERIES_BACKEND_H */

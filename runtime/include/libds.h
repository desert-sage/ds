/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * libds — DS reference runtime; public API.
 *
 * The dependency floor for every integrator, and the whole of the
 * stable surface: there is no wire or protocol surface, and no other
 * public header (IARC.1.4, IARC.9.3). The release tarball also stages
 * four internal headers under include/internal/ (sha256.h, rfcs/rfcs.h,
 * rfcs/atoms.h, ds_re2.h) for callers reusing libds's hashing,
 * fact-stream primitives or RE2 seam; those carry NO API-stability
 * guarantee.
 *
 * Design and conventions — clause IDs below cite these directly:
 *   specs/impl/ARCHITECTURE/  IARC — module graph and commitments
 *   specs/impl/DATA_MODEL/    IDAT — opaque types, struct layouts
 *   specs/impl/ERRORS/        IERR — status taxonomy, detail-string rules
 */
#ifndef LIBDS2_H
#define LIBDS2_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/*  Version, at compile time                                          */
/* ------------------------------------------------------------------ */

/* The release this header belongs to, from VERSION, in its clean form
 * ([NDET.2.4]). In a libds a release ships, ds_platform_signature_t's
 * libds_version and a recording header's ds_version ([LFST.4.3]) are
 * DS_VERSION_STRING, a `+`, and the build. */
/* -- The version, generated from VERSION by scripts/build/ds-version.py --write-header. Edit VERSION, never these lines. -- */
#define DS_VERSION_MAJOR  1
#define DS_VERSION_MINOR  1
#define DS_VERSION_PATCH  0
#define DS_VERSION_STRING "1.1.0"
/* -- End of the generated version. -- */

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/*  Status codes (see IERR.2 for the full taxonomy)                   */
/* ------------------------------------------------------------------ */

typedef int ds_status_t;

#define DS_OK                          0

/* Generic errors (-1 .. -99) */
#define DS_ERR_INVAL                  -1
#define DS_ERR_OOM                    -2
#define DS_ERR_NOT_FOUND              -3
#define DS_ERR_STATE                  -4
#define DS_ERR_OVERFLOW               -5
/* -6 retired; never reused. */
#define DS_ERR_UNSUPPORTED            -7
#define DS_ERR_INTERNAL               -8
#define DS_ERR_IO                     -9
/* An EngineError halted the tier, during this call or before it ([NCBK.2.9],
   [NERR.4]). The call during which the engine raised it returns this, ahead of
   any other status it would have returned: a pump whose firing faulted, an
   assert or retract whose propagation did. The halt is a latch and never
   clears. Every later ds_engine_* call on that engine is refused with this
   and does nothing: a pump, an assert or retract, a load or registration, a
   setter, ds_engine_clone, and every read of working memory, a schema or the
   introspection surface. A read through a fact or schema handle is answered
   only until the EngineError is delivered or the call that raised it
   returns, so the records that call delivers first can be read; it is
   refused from then on. Four calls stay valid,
   because none reads that state: ds_engine_halted,
   ds_engine_get_platform_signature, ds_engine_get_session_header and
   ds_engine_free. The code is the same whatever caused the halt; the cause is
   the EngineError's payload. */
#define DS_ERR_ENGINE_HALTED         -10

/* Input errors (-100 .. -199) */
#define DS_ERR_PARSE                -100
#define DS_ERR_SCHEMA_UNKNOWN       -101
/* -102 retired; never reused. */
#define DS_ERR_SLOT_UNKNOWN         -103
#define DS_ERR_SLOT_TYPE_MISMATCH   -104
/* -105 .. -108 retired; never reused. */

/* Runtime errors (-200 .. -299) */
#define DS_ERR_FACT_INVALID         -200
/* -201 retired; never reused. */
#define DS_ERR_ACTION_FAILED        -202
/* -203 .. -204 retired; never reused. */
#define DS_ERR_TIME_RANGE           -205  /* Time outside the representable
                                             nanosecond range (≈1678–2262);
                                             hard error, not a silent wrap
                                             (LTIM.1.1.5) */
/* -206 .. -215 retired; never reused. */
#define DS_ERR_NAN_REJECTED         -216  /* a NaN Float refused at
                                             ds_engine_assert, or as a call
                                             argument, which refuses the call
                                             ([LEXP.4.2]): NaN must not enter
                                             working memory or a payload. Inf
                                             is a valid value. Increments
                                             ds.facts.nan_rejected_total
                                             ([NERR.6]). */
#define DS_ERR_JSON_NONFINITE       -217  /* a non-finite Float (±Inf, or a
                                             NaN an expression computed,
                                             [LDET.3.2.7]) going into a Json
                                             value, such as ds_json_new_float
                                             or ds_json_serialize: the host
                                             call is refused and changes
                                             nothing; it holds no engine, so no
                                             metric moves ([LGRA.5.8.10]). A
                                             rule's path does not return this
                                             code: there, a non-finite Float
                                             forced into a cache value or a
                                             Json call argument is a
                                             NOT_REPRESENTABLE trap at the
                                             verb. The activation is abandoned,
                                             the verb does not run, and
                                             ds.json.nonfinite_total{verb}
                                             increments ([LDET.3.2.7],
                                             [NERR.6]). */
#define DS_ERR_SERIES_NO_BACKING    -218  /* a series aggregation read that no
                                             declared backing can answer, or
                                             whose backing query failed. The
                                             rule still receives the
                                             aggregation's cold value
                                             ([LSER.19.8]), and this status
                                             surfaces from ds_engine_pump, not
                                             from the read ([NERR.6]). "No
                                             samples yet" is a different case
                                             and stays silent: backend
                                             instances allocate lazily
                                             ([LSER.9.1.1]). */
#define DS_ERR_SCHEMA_HASH_MISMATCH -219  /* ds_engine_assert_external met a
                                             FactExternal whose schema_hash
                                             differs from this program's schema
                                             of that name; nothing asserted
                                             ([NERR.6], NCBK.10.4) */
#define DS_ERR_FACT_REF_CONFLICT    -220  /* ds_engine_assert_external met a
                                             nested fact reference whose key a
                                             live fact holds with different
                                             values; nothing asserted
                                             ([NERR.6], NCBK.10.4) */
#define DS_ERR_JSON_LIMIT           -221  /* a Json value over one of the four
                                             limits below (DS_JSON_MAX_*):
                                             refused, never truncated, and the
                                             call changes nothing. The status
                                             is the whole refusal: nothing is
                                             recorded on the stream. */
#define DS_ERR_ENCODING             -222  /* host text that is not well-formed
                                             UTF-8 (RFC 3629): a String slot,
                                             JSON text, a Json string or key, a
                                             cache seed. Refused, never
                                             repaired, and the call changes
                                             nothing; nothing is recorded on
                                             the stream ([NERR.6], LSTR.8.5) */
#define DS_ERR_NOT_REPRESENTABLE    -223  /* a slot's unit conversion has no
                                             result for the number it was
                                             handed; the call changes nothing
                                             ([NERR.6], NFCT.1.4.6) */

/* -300 .. -399 retired; never reused (IERR.2.6). */

/* Storage-peer errors (-400 .. -499) */
#define DS_ERR_STORAGE_UNAVAILABLE  -400
#define DS_ERR_STORAGE_QUERY_FAILED -401
#define DS_ERR_STORAGE_NOT_FOUND    -402

/* DSC loader errors (-500 .. -599) per RDSC.11.1 */
#define DS_ERR_DSC_TRUNCATED        -500
#define DS_ERR_DSC_BAD_MAGIC        -501
#define DS_ERR_DSC_VERSION          -502
#define DS_ERR_DSC_DECODE           -503
#define DS_ERR_DSC_SEMANTIC         -504
/* -505 retired; never reused. */
#define DS_ERR_DSC_DANGLING         -506
#define DS_ERR_DSC_DECOMPRESS       -507
#define DS_ERR_DSC_CAPABILITY_ABSENT -514  /* the build lacks a capability the
                                              artefact requires (RDSC.16.2.7) */

/* -508 .. -513 retired; never reused. */
/* -520 .. -527 retired; never reused. */
/* -550 .. -553 retired; never reused (IERR.2.8b). */

/* Native Rete engine error codes (IRET.21 / RDSC.4a). */
/* -600 retired; never reused. */
#define DS_ERR_RETP_INVALID        -601  /* a network node with node_id 0, a repeated node_id, or a left_parent_id cycle (RDSC.11.1, IRET.21) */
#define DS_ERR_RETP_INDEX_OOB       -602  /* cross-reference index out of bounds */
/* -603 retired; never reused. */
/* A call expression names an op with no builtin. ds_engine_load_dsc returns
   it, never evaluation: a miss means a bad or forward-versioned artefact. The
   load has begun reading, so it spends the engine ([RDSC.9.8], [NERR.8.2]). */
#define DS_ERR_FN_NOT_FOUND        -604
#define DS_ERR_BUDGET_EXCEEDED      -605  /* a bounded run reached its max_fires */
#define DS_ERR_WM_FULL              -606  /* assert rejected; N_max reached */
#define DS_ERR_TOKEN_BUDGET         -607  /* a join fan-out cap exceeded */
#define DS_ERR_RT_UNSAFE            -608  /* RT mode but a required bound unset */
#define DS_ERR_RT_LIVE              -609  /* an operation forbidden in LIVE mode (NERR.18) */
#define DS_ERR_RT_PRECOND           -610  /* a go-live pre-condition unmet (NERR.18) */

/* Series backend ABI errors (-620 .. -625) per NERR.10.2. v1 accepts no
   integrator-supplied backend ([NSBK.2.3]), so of these only
   DS_ERR_BACKEND_NOT_REGISTERED reaches an integrator through a series
   backend, and DS_ERR_BACKEND_ABI_VERSION also reaches one through
   ds_engine_cache_callbacks; the rest validate libds's own registration. */
#define DS_ERR_BACKEND_ABI_VERSION       -620  /* abi_version mismatch: a series
                                                  backend's vtable, or the cache
                                                  callbacks handed to
                                                  ds_engine_cache_callbacks */
#define DS_ERR_BACKEND_BAD_MAGIC         -621  /* vtable's backing atom outside the closed set */
#define DS_ERR_BACKEND_BAD_AGGS          -622  /* supported_aggs claims outside the backing's static set */
#define DS_ERR_BACKEND_NOT_REGISTERED    -623  /* DSC atom requires a backing with no registered backend */
/* -624 .. -625 retired; never reused. */

/* Dialect-binding errors (RBND.7). */
#define DS_ERR_BND_DSC_MISMATCH          -700  /* dsc_sha256 disagrees between artifacts */
#define DS_ERR_BND_DIALECT_MISMATCH      -701  /* capabilities/def_sha256 disagree, or the
                                                  admission policy refuses a setting */
/* -702 retired; never reused. */
#define DS_ERR_BND_INCOMPLETE            -703  /* required tuple field missing/zero-length */
#define DS_ERR_BND_RT_CONFIG_MISMATCH    -704  /* rt_mode or rt_config_sha256 disagrees (RBND.5.1b) */

/* Realtime contract errors (RTCT.9.2). */
#define DS_ERR_CONTRACT_BREACH           -710  /* runtime cap exceeded; operation refused */
#define DS_ERR_CONTRACT_MISSING          -711  /* +realtime DSC has no RealtimeContract atom */
#define DS_ERR_CONTRACT_INVALID          -712  /* RealtimeContract atom malformed or hash mismatch */
#define DS_ERR_RTCT_PROFILE_REFUSES_DSRT -713  /* profile binary asked to write to .dsrt */
#define DS_ERR_CONTRACT_WCET_HALT        -714  /* RTCT.7.3: pump exceeded pump_wcet_ns.
                                                  Returned by the pump that breached and
                                                  by no other call; the tier halts, and
                                                  from then on it is the ordinary halt
                                                  ([NCBK.2.9]): DS_ERR_ENGINE_HALTED. */

/* Event-trace errors (-720 .. -730) per NERR.13. */
#define DS_ERR_FS_VERSION                -720  /* a session header's ds_version outside
                                                  the reader's <major>.<minor>. series
                                                  (LDET.1.10) */

/* -721 .. -724 retired; never reused. */
#define DS_ERR_FS_DIVERGENCE             -725  /* verify-mode replay: a re-derived compare atom
                                                  (RuleFireAnnotation/CallIssued) differs
                                                  byte-for-byte from the recorded atom at that seq,
                                                  or is missing/extra/reordered — a determinism
                                                  failure ([LFST.9.3.1]/.9.3.6). */
/* -726 retired; never reused. */
/* [LTIM.2.8.5] / [LFST.5.3] — a stream's first event has seq 0. A recording
   whose first event has another seq was attached after the engine's first
   input or sample, so it lacks what came before, and a replayer refuses it. */
#define DS_ERR_FS_RECORDING_INCOMPLETE   -729  /* first event's seq is not 0: attached late */
/* [RFCS.7.3]: a replay meets a FactRetract
   whose fact_id names no fact an earlier FactAssert, FactEmit or
   ExternalAssert left in working memory, or one an earlier FactRetract
   already named, and stops there, wherever in the stream it is. */
#define DS_ERR_FS_UNKNOWN_FACT_ID        -730  /* FactRetract names an unknown fact_id */

/* ------------------------------------------------------------------ */
/*  Result type (see IDAT.2.3)                                        */
/* ------------------------------------------------------------------ */

typedef struct ds_result {
    ds_status_t  status;
    const char  *detail;  /* valid until the next libds call on the same engine */
} ds_result_t;

/* ISO C++ has no compound literals; the same aggregate, brace-initialised,
   is the C++ spelling of the same value. */
#ifdef __cplusplus
#define DS_OK_R           (ds_result_t{ DS_OK, NULL })
#define DS_ERR_R(s, d)    (ds_result_t{ (s),   (d)  })
#else
#define DS_OK_R           ((ds_result_t){ DS_OK, NULL })
#define DS_ERR_R(s, d)    ((ds_result_t){ (s),   (d)  })
#endif

/* ------------------------------------------------------------------ */
/*  Opaque types (see IDAT.3)                                         */
/* ------------------------------------------------------------------ */

typedef struct ds_engine     ds_engine_t;
typedef struct ds_fact       ds_fact_t;
typedef struct ds_schema     ds_schema_t;
typedef struct ds_json       ds_json_t;
/* ds_stream_ev_t is not opaque ([IDAT.1.2], [IARC.1.8]): it is declared with
   its public layout, struct ds_stream_ev, below. */

/* ------------------------------------------------------------------ */
/*  Slot values (see IDAT.4.6)                                        */
/* ------------------------------------------------------------------ */

/* [LNUL.8.8]: the canonical `null`'s hash, the same on every platform
   ([LNUL.6.3]): ASCII "NULLNULL". A hash only distributes; equality is always
   decided on the values. */
#define DS_NULL_HASH64  UINT64_C(0x4E554C4C4E554C4C)

/* Bytes view — non-owning pointer + length. Its lifetime is the value's: see
   ds_slot_value_t. */
typedef struct ds_bytes_view {
    const uint8_t *data;
    size_t         len;
} ds_bytes_view_t;

/* A fact passed as a call argument (NCBK.6.10): its FactExternal encoding
   (RFCS.23.1) as bytes, and beside them the two things an integrator routes
   on without decoding it -- the schema's name and the instant the fact
   entered working memory (RFCS.23.5). Nothing else is lifted out. Every
   pointer is valid for the duration of the callback that receives it. */
typedef struct ds_encoded_fact {
    ds_bytes_view_t bytes;        /* the FactExternal message */
    const char     *schema;       /* the fact's schema name */
    int64_t         asserted_at;  /* UTC ns since the Unix epoch; 0 when unset */
    bool            asserted_at_set; /* false when the wall clock had no value
                                        at assertion (RFCS.23.5) */
} ds_encoded_fact_t;

/* Value kinds and values. A slot's kind is what its storage tag reports
   after the value has been resolved -- not the schema-declared type
   (ds_slot_type_t, see the schema API). A Time, Date or Duration slot carries
   DS_SLOT_INT, and a Json slot carries DS_SLOT_JSON whatever its tree holds
   (IDAT.4.6.2, NFCT.2.3). DS_SLOT_NULL is valid only in a slot the schema
   declared nullable (`T?`); the compiler gates this ([LNUL.5.1]). */
/* >>> generated by scripts/private/gen/gen_kind_registry.py from proto/fact_external.proto#Kind -- do not edit by hand >>> */
/* NFCT.2.7 -- one kind number space. A common kind has the same number
   in all three enumerations, so converting between them is the identity;
   a number one subtype owns is reserved in the other. The members of
   the three value unions follow the kinds: a common member has one
   name everywhere. */
/* the value kinds a slot and a call argument share */
typedef enum {
    DS_KIND_INT    = 0,
    DS_KIND_FLOAT  = 1,
    DS_KIND_STRING = 2,
    DS_KIND_BOOL   = 3,
    DS_KIND_JSON   = 4,
    DS_KIND_BYTES  = 6,
    DS_KIND_NULL   = 7,
} ds_kind_t;

/* a slot value's kind: the common kinds and the fact reference */
typedef enum {
    DS_SLOT_INT      = 0,
    DS_SLOT_FLOAT    = 1,
    DS_SLOT_STRING   = 2,
    DS_SLOT_BOOL     = 3,
    DS_SLOT_JSON     = 4,
    DS_SLOT_FACT_REF = 5,
    DS_SLOT_BYTES    = 6,
    DS_SLOT_NULL     = 7,
} ds_slot_kind_t;

/* a call argument's kind (NCBK.6.10): the common kinds and the encoded fact */
typedef enum {
    DS_ARG_INT          = 0,
    DS_ARG_FLOAT        = 1,
    DS_ARG_STRING       = 2,
    DS_ARG_BOOL         = 3,
    DS_ARG_JSON         = 4,
    DS_ARG_BYTES        = 6,
    DS_ARG_NULL         = 7,
    DS_ARG_ENCODED_FACT = 8,
} ds_arg_kind_t;

/* a value of a common kind */
typedef struct ds_value {
    ds_kind_t kind;
    union {
        int64_t          i;
        double           f;
        const char      *s;         /* engine-interned; engine-lifetime */
        bool             b;
        ds_json_t       *json;      /* a parsed tree */
        ds_bytes_view_t  bytes;     /* engine-lifetime view of binary */
    } v;
} ds_value_t;

/* a slot value (IDAT.4.6). String and bytes members point into libds's intern
   table, and how long they stay valid depends on where the value came from:
     - read from a fact (ds_fact_get_slot): until that fact is retracted
       ([NFCT.6.2]). The fact holds a counted reference, released with it;
     - libds's own pinned strings (schema, slot and rule names):
       engine-lifetime.
   Copy a string the host needs to keep past either. A v.json read from a fact
   is the fact's own tree, a borrow until that fact is retracted: never free or
   change it ([NFCT.6.2], [IDAT.3.3.8]). */
typedef struct ds_slot_value {
    ds_slot_kind_t kind;
    union {
        int64_t          i;
        double           f;
        const char      *s;         /* engine-interned; lifetime above */
        bool             b;
        ds_json_t       *json;      /* a parsed tree */
        ds_fact_t       *ref;       /* non-owning; on read, the live target or NULL once it has left WM */
        ds_bytes_view_t  bytes;     /* view of binary; lifetime above */
    } v;
} ds_slot_value_t;

/* a call argument's value */
typedef struct ds_arg_value {
    ds_arg_kind_t kind;
    union {
        int64_t          i;
        double           f;
        const char      *s;         /* borrowed for the callback */
        bool             b;
        ds_json_t       *json;      /* a parsed tree */
        ds_bytes_view_t  bytes;     /* view of binary, borrowed for the callback */
        ds_encoded_fact_t fact;     /* a fact argument's FactExternal bytes, valid for the callback */
    } v;
} ds_arg_value_t;
/* <<< generated by scripts/private/gen/gen_kind_registry.py <<< */

/* One call argument (NCBK.6.10): the kwarg's name and its typed value. A
   call's arguments arrive sorted by name, one per kwarg the call supplies; an
   optional kwarg the call omits is absent ([NCBK.6.2]). A Json value is a
   parsed tree, as a Json slot value is. Everything is engine-owned and
   borrowed for the duration of the callback that receives it. */
typedef struct ds_arg {
    const char     *name;   /* the kwarg's name */
    ds_arg_value_t  value;
} ds_arg_t;

/* ------------------------------------------------------------------ */
/*  Engine lifecycle                                                  */
/* ------------------------------------------------------------------ */

/*
 * An integrator initialises the config to zero, as `{0}` or with memset,
 * and sets the fields it means to; every other field then takes its default,
 * so a field added later leaves the caller's source correct. A zeroed config,
 * or NULL, is the default engine. Rete is libds's only rule-evaluation
 * substrate, and no field chooses it ([IRET.15.1]).
 */
typedef struct ds_engine_config {
    /*
     * The engine's identity, the integrator's to give. The engine derives
     * every fact's event_id from (run_id, tier_id, seq); what the ids mean,
     * and whether they are unique, is the integrator's business. Either may be NULL --
     * absent -- and an empty string is the same as NULL ([NLFC.1.2]); with
     * both absent `seq` alone distinguishes facts. Each given must be
     * well-formed UTF-8 ([LSTR.8.5]); ds_engine_new refuses one that is not.
     * The strings are COPIED at
     * ds_engine_new; the caller's may go. The fact-stream session header
     * records them as `session_id` and `tier_id` ([RFCS.4.3], [RFCS.4.4]).
     * The engine mints no identity of its own.
     */
    const char *run_id;
    const char *tier_id;
} ds_engine_config_t;

/* The engine's run id and tier id as given at ds_engine_new, each NULL when
   absent or given as "". The pointers are the engine's own and live as long
   as it does. */
ds_result_t ds_engine_get_run_id(const ds_engine_t *engine, const char **out);
ds_result_t ds_engine_get_tier_id(const ds_engine_t *engine, const char **out);

/*
 * ds_engine_new — create a new engine instance.
 *
 * Initialises libds's per-engine state,
 * and stores the opaque handle in *out.
 *
 *   config  may be NULL; defaults apply.
 *   out     must be non-NULL; set to the new engine on success, NULL
 *           on failure.
 *
 * `*out` is caller-owned: release it with ds_engine_free ([IDAT.10.2]).
 *
 * Returns DS_OK on success, or:
 *   DS_ERR_INVAL     out is NULL;
 *   DS_ERR_ENCODING  config's run_id or tier_id is not well-formed UTF-8
 *                    ([NLFC.1.2], [LSTR.8.5]); no engine is created;
 *   DS_ERR_OOM       an allocation failed.
 * On failure, *out is NULL (when out is not) and the caller should
 * propagate the result. A failure's detail is static, valid for the life
 * of the process, since no engine is left to hold it ([IERR.4.1.1]).
 * Multiple engines may coexist in the same process per IARC.1.11.
 */
ds_result_t ds_engine_new(const ds_engine_config_t *config,
                          ds_engine_t             **out);

/*
 * ds_engine_free — destroy an engine instance.
 *
 * Tears down all libds-owned state. After
 * return, the engine pointer is invalid. Teardown fires no callback
 * ([NLFC.6.4]).
 */
ds_result_t ds_engine_free(ds_engine_t *engine);

/*
 * ds_engine_clone — produce an independent engine identical to `src` at call
 * time ([NLFC.8] / [IARC.11] / [LDET.2.2b]).
 *
 * The clone is behaviourally equivalent and fully independent: for any input
 * sequence applied identically to `src` and the clone, the two produce
 * byte-identical observable output ([LDET.2.2b]); they share no mutable state,
 * and either may be freed first. It is NOT rollback — a discarded clone's
 * events never enter the source's stream (speculation is off-stream). Clone is
 * a runtime API over in-memory state: no wire format, no atom, no version gate.
 *
 * Preconditions ([NLFC.8.2]):
 *   src or out_dst NULL                 -> DS_ERR_INVAL
 *   called mid-pump / mid-callback      -> DS_ERR_STATE (every call on that
 *                                          engine is, [RARC.13.16])
 *   src has halted                      -> DS_ERR_ENGINE_HALTED
 *   allocation fails                    -> DS_ERR_OOM (source unchanged)
 *
 * `*out_dst` is caller-owned; free it (or `src`) in any order. The clone
 * starts with NO callbacks and no `user` pointer of the source's — stream,
 * call, log, metric and both cache hooks are all cleared ([NLFC.8.3]). The
 * integrator registers what the clone needs before pumping it; an essential
 * verb with no handler fails as on a new engine (DS_ERR_STORAGE_UNAVAILABLE).
 * The byte-identical guarantee above holds once the clone's callbacks behave
 * as the source's do ([NLFC.8.1]).
 */
ds_result_t ds_engine_clone(const ds_engine_t *src, ds_engine_t **out_dst);

/* ------------------------------------------------------------------ */
/*  Clock source (see IARC.3.11)                                      */
/* ------------------------------------------------------------------ */

/*
 * The engine holds two clocks (LTIM.2.8): a MONOTONIC clock, which never
 * decreases and drives every relative-time mechanism (TTL, after,
 * cooldown, within, dwell, series windows), and a WALL clock, UTC
 * nanoseconds since the Unix epoch, which drives now() alone. The engine
 * samples both together when it consumes an input (ds_engine_assert,
 * _retract) and when a pump begins, and every read in
 * between returns that sample (LTIM.2.8.4). A sample that changes either
 * clock is recorded as a DS_EV_TICK carrying both (LTIM.2.8.5).
 *
 * Clock mode. Engines start in DS_CLOCK_LIVE. Switching to DS_CLOCK_MOCK
 * starts the mock monotonic clock at 0, whatever the live clock read, so a
 * mocked run does not depend on when it was started (NLFC.5.4), and leaves
 * the mock wall clock UNSET until ds_engine_wall_clock_set gives it a
 * value. The switch returns DS_ERR_STATE once the engine has sampled its
 * clock, for an input or a pump: the monotonic clock would go backward.
 * Switching back to live
 * continues the monotonic clock from the current mock time.
 *
 * On a DS_MICRO build the live wall clock comes from the board's optional
 * ds_platform_wall_ns(); a board without one leaves it unset.
 */
typedef enum {
    DS_CLOCK_LIVE = 0,   /* platform monotonic and wall clocks */
    DS_CLOCK_MOCK = 1,   /* integrator drives time via the ds_engine_*clock_* APIs */
} ds_clock_mode_t;

/* Query the current clock mode. */
ds_result_t ds_engine_clock_mode(ds_engine_t     *engine,
                                 ds_clock_mode_t *out_mode);

/* Switch clock mode. No-op if the engine is already in the requested
   mode. See above for what each switch does to the two clocks. */
ds_result_t ds_engine_clock_set_mode(ds_engine_t    *engine,
                                     ds_clock_mode_t mode);

/* Read the monotonic clock's current value, in nanoseconds. Works in both
   modes. This is the integrator's own read: it is not a sample, records
   nothing, and does not change what the engine's next read returns. */
ds_result_t ds_engine_clock_now(ds_engine_t *engine, uint64_t *out_ns);

/* Report the earliest deadline later than the monotonic clock's current value
   (NLFC.2.5): the fire_at of a live timer fact, the expiry of a live fact with a
   TTL, or the expiry of a cache entry. *out_has is false when the engine holds
   none, and *out_ns is then 0. A read, on a live or a mock clock: it is not a
   sample, records nothing, and changes nothing a later call or pump does. An
   instant at which a time-dependent condition changes is not a deadline, and
   neither is the end of a cooldown. Linear in the live facts and cache
   entries. */
ds_result_t ds_engine_next_deadline_ns(ds_engine_t *engine, uint64_t *out_ns,
                                       bool *out_has);

/* Set the mock monotonic clock to an absolute value. Not a sample: the
   next input or pump observes it (NTST.3.3). DS_ERR_STATE in live mode,
   and below the current value once the engine has sampled its clock, for
   an input or a pump (NTST.3.1). DS_ERR_TIME_RANGE, with the clock as it
   was, above 2^63 - 1, the top of the clock's range (LTIM.2.8.2). */
ds_result_t ds_engine_clock_set(ds_engine_t *engine, uint64_t now_ns);

/* Advance the mock monotonic clock by delta nanoseconds, and the mock wall
   clock by the same amount when it is set. Not a sample. DS_ERR_STATE in
   live mode. DS_ERR_TIME_RANGE, with both clocks as they were, for a
   monotonic clock or a wall clock that would pass 2^63 - 1 (NTST.3.1). */
ds_result_t ds_engine_clock_advance(ds_engine_t *engine, uint64_t delta_ns);

/* Set the mock wall clock to utc_ns, nanoseconds since the Unix epoch:
   any instant, earlier or later (NTST.3.1), the way a test reproduces a
   host clock being stepped. Not a sample. DS_ERR_STATE in live mode. */
ds_result_t ds_engine_wall_clock_set(ds_engine_t *engine, int64_t utc_ns);

/* ------------------------------------------------------------------ */
/*  Schema registry (see IDAT.5)                                      */
/* ------------------------------------------------------------------ */

/* Schema lifecycle. LOGICAL facts retract via the engine's truth-
   maintenance machinery (rule-driven). TTL facts auto-retract when
   their per-fact deadline passes. INTERNAL is a schema the engine
   owns and asserts itself -- the built-in fault schemas
   `ComputationError` and `TypeError` ([LERR.9.4], [LSCP.2.6.2]) --
   which enumerates with the program's own ([NDBG.2.2]): an integrator
   tells the two apart by this value, never by name, and does not write
   an INTERNAL schema into source. ds_schema_get_lifecycle reports it.

   A schema reaches the engine from a compiled artefact and in no other way
   ([NFCT.1.1]): ds_engine_load_dsc registers it, and these types, with
   ds_slot_desc_t below, are how it is read back. */
typedef enum {
    DS_SCHEMA_LIFECYCLE_LOGICAL  = 0,
    DS_SCHEMA_LIFECYCLE_TTL      = 1,
    DS_SCHEMA_LIFECYCLE_INTERNAL = 2,
} ds_schema_lifecycle_t;

/* Schema-declared slot type. Distinct from ds_slot_kind_t (the
   runtime tag on a slot value): NFCT.2.3's table pairs the two, and a
   Json slot carries DS_SLOT_JSON (IDAT.4.6.2). */
typedef enum {
    DS_SLOT_TYPE_INT     = 0,
    DS_SLOT_TYPE_FLOAT   = 1,
    DS_SLOT_TYPE_STRING  = 2,
    DS_SLOT_TYPE_BOOL    = 3,
    DS_SLOT_TYPE_JSON    = 4,
    DS_SLOT_TYPE_SCHEMA  = 5,  /* fact-pointer slot; schema_ref non-NULL */
    DS_SLOT_TYPE_BYTES   = 6,
    /* The temporal types (RDSC.5.5.8). Each is REPRESENTED as an Int: a value
       is a DS_SLOT_INT, stored and compared exactly as an Int slot's. The type
       is what lets a reader tell a timestamp from a count.
         TIME:     the instant's nanoseconds since the epoch, UTC; no zone.
         DATE:     days since the epoch.
         DURATION: nanoseconds. */
    DS_SLOT_TYPE_TIME     = 7,
    DS_SLOT_TYPE_DATE     = 8,
    DS_SLOT_TYPE_DURATION = 9,
} ds_slot_type_t;

/* LFAC.1.7 — per-slot identity role. On a `logical` schema every slot is
   KEY or MUTABLE (require-all), except `ts`, which is ENGINE: outside the
   identity key and outside the no-op comparison (LFAC.9.1). The schema's
   identity key is the set of KEY slots (∅ ⇒ singleton, all ⇒ relation).
   Non-`logical` slots are UNSPECIFIED. Mirrors the DSC IdentityRole enum
   (RDSC.5.5.7). */
typedef enum {
    DS_IDENTITY_UNSPECIFIED = 0,
    DS_IDENTITY_KEY         = 1,
    DS_IDENTITY_MUTABLE     = 2,
    DS_IDENTITY_ENGINE      = 3,
} ds_identity_role_t;

/* One slot of a loaded schema, as ds_schema_get_slot reads it back
   ([NFCT.1.4.1]). */
typedef struct ds_slot_desc {
    /* The engine's own string, valid for the engine's life. */
    const char           *name;
    ds_slot_type_t        type;
    /* Non-NULL iff type == DS_SLOT_TYPE_SCHEMA. Borrow. */
    const ds_schema_t    *schema_ref;
    /* Per-slot markers the author declared. */
    bool                  sampled;
    bool                  retained;
    bool                  has_tolerance;
    double                tolerance;     /* normalized to double */
    /* Optional human-readable docstring; may be NULL. Engine-owned like
       `name`. */
    const char           *docstring;
    /* Hydration eligibility: true when a Hydration atom in the artefact
       names the slot; false otherwise. */
    bool                  hydration_eligible;
    /* LFAC.1.7 identity role. On a `logical` schema, KEY slots form the
       identity key (same KEY tuple ⇒ supersede; ∅ ⇒ singleton; all ⇒
       relation) and MUTABLE slots are payload. UNSPECIFIED on non-logical
       slots. Carried on the DSC Slot atom as `identity_role` (RDSC.5.5.7). */
    ds_identity_role_t    identity_role;
    /* [LNUL.3.1] the slot was declared nullable (`T?`). A DS_SLOT_NULL value is
       admitted only in a nullable slot; ds_engine_assert refuses a null in a
       non-nullable slot. Carried on the Slot atom
       as `nullable` ([RDSC.7.1]); default false. */
    bool                  nullable;
} ds_slot_desc_t;

/* Number of schemas currently registered on this engine. */
ds_result_t ds_engine_schema_count(ds_engine_t *engine, size_t *out);

/* Look up a schema by its own name ([LIMP.13.1]), the name
   ds_schema_get_name gives. A schema declared in the program has its NAME;
   one a library declares has the library's dotted import path, a `.` and its
   NAME: `plant.sensors.Reading` for `Reading` in `plant.sensors`. An `as`
   alias is never an own name. On success *out holds a borrowed pointer to the
   registered schema, or NULL when no schema has that own name, which is what
   the bare `Reading` finds for that library's schema. Status is DS_OK in both
   cases, so a miss is told by *out. */
ds_result_t ds_engine_schema_find(ds_engine_t       *engine,
                                  const char         *type_name,
                                  const ds_schema_t **out);

/* Iterate over registered schemas. Index is 0..count-1; out-of-range
   returns DS_ERR_NOT_FOUND. *out is a borrowed pointer valid for
   engine lifetime. */
ds_result_t ds_engine_schema_at(ds_engine_t       *engine,
                                size_t              index,
                                const ds_schema_t **out);

/* ------------------------------------------------------------------ */
/*  Schema introspection (DSC-loaded metadata + base attributes)      */
/* ------------------------------------------------------------------ */
/*
 * Accessors over an opaque ds_schema_t. All return DS_OK with the
 * out-pointer set on success. Strings are engine-owned and stable
 * for the engine's lifetime. Used by debugger / inspector / replayer
 * tooling that wants to read what ds_engine_load_dsc put on the
 * schema, plus the base shape (lifecycle, slots) authors declared.
 *
 * After an EngineError each returns DS_ERR_ENGINE_HALTED, whenever the
 * handle was taken ([NCBK.2.9]). The one window is the call that raised
 * it: a read is answered until that call has delivered the EngineError
 * (DS_EV_ENGINE_ERROR) or returned, so the records it delivers ahead of
 * the EngineError can be read ([RFCS.6.7]).
 */

ds_result_t ds_schema_get_name(const ds_schema_t  *schema,
                                const char        **out);

ds_result_t ds_schema_get_lifecycle(const ds_schema_t      *schema,
                                     ds_schema_lifecycle_t *out);

ds_result_t ds_schema_get_ttl_ns(const ds_schema_t *schema,
                                  uint64_t          *out);

ds_result_t ds_schema_get_slot_count(const ds_schema_t *schema,
                                      uint32_t          *out);

/* Copies the i-th slot's descriptor into *out. Strings inside (name,
   docstring) are engine-owned borrows valid for engine lifetime. */
ds_result_t ds_schema_get_slot(const ds_schema_t *schema,
                                uint32_t           index,
                                ds_slot_desc_t    *out);

/* Source-location metadata loaded from the SchemaSource atom (RDSC.5.7). All
   three out-pointers may be NULL. *file is NULL when no SchemaSource was
   present in the artefact. */
ds_result_t ds_schema_get_source(const ds_schema_t  *schema,
                                  const char        **out_file,
                                  uint32_t           *out_line,
                                  uint32_t           *out_col);

/* Generated .proto definition loaded from the SchemaDef atom (RDSC.5.8 /
   LFAC.8). *out_text is NULL when no SchemaDef was present. *out_len, if
   non-NULL, receives the byte length excluding the NUL terminator. */
ds_result_t ds_schema_get_proto_source(const ds_schema_t  *schema,
                                        const char        **out_text,
                                        size_t             *out_len);

/* [NFCT.1.4.6]: a number through the conversion of a slot that names a unit,
   the slot whose declared type is a unit symbol ([LUNI.7.1], [RDSC.5.5.9]).
   `in` and `*out` are of the kind [NFCT.2.3] pairs with the slot's type.

   ds_schema_slot_to_stored writes the stored number ([LUNI.7.6]) of a number
   in the unit the slot names: what `x::<unit>` computes ([LUNI.8.5]).
   ds_schema_slot_from_stored writes a stored number in the unit the slot
   names: what a kwarg of that unit receives ([LADP.8.5.3]).

   Neither changes the engine, records an event or asserts a fault fact, save
   for an EngineError the conversion raises: the artefact has then lied, and
   the call halts the engine and reports it as any public call that raises one
   does ([NCBK.2.8], [NCBK.2.9]). Neither is a ds_engine_* call, so a callback
   may make it ([RARC.13.16]). Each returns the first of these that holds, and
   writes *out only on DS_OK:
     DS_ERR_INVAL              a NULL pointer
     DS_ERR_ENGINE_HALTED      an EngineError halted the engine ([NCBK.2.9])
     DS_ERR_NOT_FOUND          `index` names no slot of the schema
     DS_ERR_INVAL              the slot names no unit
     DS_ERR_SLOT_TYPE_MISMATCH `in`'s kind is not the slot's
     DS_ERR_NAN_REJECTED       `in` is a NaN
     DS_ERR_ENGINE_HALTED      the conversion raises an EngineError
                               ([LERR.1.4.7])
     DS_ERR_NOT_REPRESENTABLE  the conversion raises any other fault where a
                               rule's evaluation would ([LERR.1.4]), or its
                               result is NaN */
ds_result_t ds_schema_slot_to_stored(const ds_schema_t      *schema,
                                     uint32_t                index,
                                     const ds_slot_value_t  *in,
                                     ds_slot_value_t        *out);

ds_result_t ds_schema_slot_from_stored(const ds_schema_t      *schema,
                                       uint32_t                index,
                                       const ds_slot_value_t  *in,
                                       ds_slot_value_t        *out);

/* ------------------------------------------------------------------ */
/*  Per-rule metadata (DSC-loaded per RDSC.6)                         */
/* ------------------------------------------------------------------ */

typedef struct ds_rule_meta_view {
    const char *rule_name;       /* engine-owned; engine-lifetime */
    bool        has_cool;
    uint64_t    cool_window_ns;
    bool        has_srcr;
    const char *src_file;
    uint32_t    src_line;
    uint32_t    src_col;
    bool        has_dnam;
    const char *debug_name_template;  /* RuleDebugName atom template (RDSC.6.8) */
} ds_rule_meta_view_t;

ds_result_t ds_engine_rule_meta_count(ds_engine_t *engine, size_t *out);

ds_result_t ds_engine_rule_meta_at(ds_engine_t          *engine,
                                    size_t                index,
                                    ds_rule_meta_view_t  *out);

/* Look up by rule name. Sets *out_found to indicate hit. */
ds_result_t ds_engine_rule_meta_find(ds_engine_t          *engine,
                                      const char           *rule_name,
                                      ds_rule_meta_view_t  *out,
                                      bool                 *out_found);

/* ------------------------------------------------------------------ */
/*  Services (DSC-loaded from ServiceDef atoms, NDBG.2.4)             */
/* ------------------------------------------------------------------ */

/* One kwarg of a service, as its ServiceKwarg carries it. Every string is
   engine-owned and lives as long as the engine. */
typedef struct ds_service_kwarg_view {
    const char *name;
    const char *ds_type;       /* the declared type (ServiceKwarg.ds_type): a
                                  schema's own name, or as declared a builtin
                                  type, a unit symbol, a dimension, `Schema`
                                  or an opaque type ([RDSC.6a.2.7]) */
    bool        required;
    bool        is_literal;    /* `literal` ([LADP.8.5.1]) */
    bool        has_default;
    const char *default_text;  /* the default's canonical text ([RDSC.6a.2.4]);
                                  "" when !has_default */
} ds_service_kwarg_view_t;

/* One service the loaded program declares: one per ServiceDef atom. */
typedef struct ds_service_view {
    const char *name;          /* "domain.method" */
    const char *response;      /* the response schema's name; "" for a service
                                  that declares `no response` ([LADP.8.4.2]) */
    bool        no_response;   /* set exactly when it declares `no response` */
    uint32_t    kwarg_count;
    const ds_service_kwarg_view_t *kwargs;  /* engine-owned, in the artefact's
                                               order, which is by name */
} ds_service_view_t;

ds_result_t ds_engine_service_count(ds_engine_t *engine, size_t *out);

/* In the artefact's order. DS_ERR_NOT_FOUND for an index past the count. */
ds_result_t ds_engine_service_at(ds_engine_t        *engine,
                                  size_t              index,
                                  ds_service_view_t  *out);

/* Look up by service name. DS_OK either way; *out_found says whether it hit. */
ds_result_t ds_engine_service_find(ds_engine_t        *engine,
                                    const char         *name,
                                    ds_service_view_t  *out,
                                    bool               *out_found);

/*
 * ds_engine_get_justifiers — list all activation timetags that
 * logically support fact_id, along with their rule names ([NDBG.5.1]).
 *
 * On success, *out_timetags and *out_rule_names each point to
 * caller-owned arrays of *out_count elements (free with ds_free()).
 * out_rule_names[i] is a copy of the rule name string (also
 * caller-owned; free each with ds_free(), IALC.4.3).
 * Returns DS_OK with count=0 for non-logical facts or an unknown fact_id.
 * Only meaningful while the engine is paused, between pumps ([NDBG.1.2]);
 * from inside a callback it returns DS_ERR_STATE ([RARC.13.16]).
 *
 * Errors: DS_ERR_INVAL (engine or an out-pointer is NULL, [NDBG.7.1]);
 * DS_ERR_STATE (re-entered); DS_ERR_ENGINE_HALTED; DS_ERR_OOM. On every
 * error, each out-pointer given holds NULL or 0.
 */
ds_result_t ds_engine_get_justifiers(ds_engine_t   *engine,
                                      uint64_t       fact_id,
                                      int64_t      **out_timetags,
                                      char        ***out_rule_names,
                                      uint32_t      *out_count);

/* ------------------------------------------------------------------ */
/*  Rete network introspection (NDBG.4)                               */
/* ------------------------------------------------------------------ */

/*
 * ds_engine_rete_network — enumerate Rete nodes and edges.
 *
 * Calls node_cb once per node and edge_cb once per directed edge. Every node
 * comes before any edge: the alphas, then the betas, then the terminals. A
 * NULL edge_cb enumerates the nodes alone. All string arguments are valid only for the
 * callback's duration; copy if needed. Inside either callback, as inside
 * those of ds_engine_rete_match_trace and ds_engine_refracted_activations
 * below, every ds_engine_* call on this engine returns DS_ERR_STATE
 * (RARC.13.17); a call on another engine is unaffected.
 *
 * rule_filter: if non-NULL, only nodes reachable from that rule's terminal
 *   (NDBG.4.1): the terminal, and every alpha and join upstream of it, with
 *   only the edges between two of those. A name no rule has gives nothing.
 * include_occupancy: populate occupancy, each node's live fact/token count (a
 *   terminal's: its activations not yet fired); UINT32_MAX on every node when
 *   false. The count is always the paused one NDBG.1.2 asks for: from inside a
 *   pump's callback this call returns DS_ERR_STATE (RARC.13.16), so it is only
 *   ever answered between pumps.
 *
 * Errors: DS_ERR_INVAL (NULL engine or node_cb, NDBG.7.1); DS_ERR_STATE
 * (re-entered); DS_ERR_OOM (rule_filter's working set).
 *
 * node_cb args: id, kind ("alpha"|"beta"|"terminal"), label (an alpha's schema
 *   name, a terminal's rule name, or a beta's "join"), filter (an alpha's
 *   formatted test; a beta's "join" where it carries join tests; "" if none),
 *   occupancy, is_negative (NOT-beta only).
 * edge_cb args: from_id, to_id.
 *
 * Returns DS_OK with no callbacks when the engine has no Rete network.
 */
typedef void (*ds_rete_node_cb_t)(
    const char *id, const char *kind, const char *label,
    const char *filter, uint32_t occupancy, bool is_negative,
    void *user);

typedef void (*ds_rete_edge_cb_t)(
    const char *from_id, const char *to_id, void *user);

ds_result_t ds_engine_rete_network(
    ds_engine_t       *engine,
    const char        *rule_filter,
    bool               include_occupancy,
    ds_rete_node_cb_t  node_cb,  void *node_user,
    ds_rete_edge_cb_t  edge_cb,  void *edge_user);

/*
 * ds_engine_rete_match_trace — trace fact_id through alpha nodes.
 *
 * Calls cb once per alpha node that participates in the fact's schema
 * dispatch, with result the string "passed" or "filtered" (NDBG.4.2) and a
 * human-readable detail string explaining it.
 *
 * Returns DS_OK with no callbacks for an unknown fact_id, and DS_ERR_INVAL for
 * a NULL engine or cb (NDBG.7.1).
 */
typedef void (*ds_rete_trace_cb_t)(
    const char *node_id, const char *node_kind,
    const char *result,  const char *detail,
    void *user);

ds_result_t ds_engine_rete_match_trace(
    ds_engine_t       *engine,
    uint64_t           fact_id,
    ds_rete_trace_cb_t cb, void *user);

/*
 * ds_engine_refracted_activations — list every activation refraction
 * blocks: each entry of the terminals' refraction sets ([NDBG.4.3]).
 *
 * Calls cb once per entry. An entry stays listed until its activation is
 * re-created ([IRET.11.3.2]); an unrelated assert or retract, or a pump
 * boundary, removes nothing, so every fact an entry names is live.
 * Entries come terminal by terminal in ordinal order ([LDET.5.4]), and
 * within one terminal by their fact ids compared as a tuple, ascending.
 * fact_ids/fact_count carry the fact_ids of the facts the author's
 * patterns bound -- the same ids ds_fact_get_id, ds_engine_get_justifiers
 * and the stream report -- in pattern order. A compiler-synthesised fact
 * (the clock tick, an `after` timer) is not one of them, so an entry whose
 * match holds only synthesised facts has fact_count 0. reason is always
 * "refraction" in v1; detail is "fired, and not re-created since".
 * fact_ids is valid only for the callback's duration ([NDBG.1.3]).
 *
 * Returns DS_OK with no callbacks when the engine has no Rete network, and
 * DS_ERR_INVAL for a NULL engine or cb (NDBG.7.1).
 */
typedef void (*ds_rete_refract_cb_t)(
    const char *rule_name, const char *reason, const char *detail,
    const uint64_t *fact_ids, uint32_t fact_count,
    void *user);

ds_result_t ds_engine_refracted_activations(
    ds_engine_t          *engine,
    const char           *rule_filter,
    ds_rete_refract_cb_t  cb,  void *user);

/* ------------------------------------------------------------------ */
/*  Per-file DS source preservation (RDSC.14.2)                       */
/* ------------------------------------------------------------------ */

typedef struct ds_ds_source_view {
    uint32_t    module_id;   /* per-module identity; join atoms by this */
    const char *file;        /* display path; runtime joins by module_id */
    const char *text;
    size_t      text_len;
} ds_ds_source_view_t;

ds_result_t ds_engine_ds_source_count(ds_engine_t *engine, size_t *out);

ds_result_t ds_engine_ds_source_at(ds_engine_t          *engine,
                                    size_t                index,
                                    ds_ds_source_view_t  *out);

/* ------------------------------------------------------------------ */
/*  Rete-node ↔ DS-source span mapping (RDSC.14.3)                    */
/* ------------------------------------------------------------------ */

typedef struct ds_line_span_view {
    uint32_t    node_id;        /* AlphaNode/BetaNode/TerminalNode node index (bundle-global) */
    uint32_t    ds_line;        /* 1-based DS source line */
    uint32_t    ds_col;         /* 1-based DS source column */
    const char *ds_file;        /* display path; equals DsSource[module_id].file */
    uint32_t    module_id;      /* per-module identity (span → DsSource) */
} ds_line_span_view_t;

ds_result_t ds_engine_line_span_count(ds_engine_t *engine, size_t *out);

ds_result_t ds_engine_line_span_at(ds_engine_t         *engine,
                                    size_t               index,
                                    ds_line_span_view_t *out);

/* Resolve the DS source span for a Rete node by its bundle-global
 * node_id (the AlphaNode/BetaNode/TerminalNode index a diagnostic surfaces
 * at). Returns DS_ERR_NOT_FOUND when no LineSpan atom mapped the node. */
ds_result_t ds_engine_line_span_find(ds_engine_t         *engine,
                                     uint32_t             node_id,
                                     ds_line_span_view_t *out);

/*
 * Load a compiled DS rule artefact into the engine.
 *
 * Spec: specs/runtime/DSC_FORMAT/ (prefix RDSC). The compiler emits
 * one .dsc file per .ds source; this is the integrator-facing entry
 * point that loads it into a fresh ds_engine_t at startup.
 *
 * The bytes pointed at by `data` are the .dsc stream — atom framing
 * (magic + length + body) per RDSC.2 with body protobuf-encoded per
 * the atom registry at RDSC.7. The loader walks the stream in a
 * single forward pass per RDSC.9.3.
 *
 *   data  full .dsc byte stream; not retained after this call
 *   len   bytes available at data
 *
 * A failed load spends the engine ([RDSC.9.8]). A load that fails once it
 * has begun reading the artefact returns the error that stopped it and sets
 * the halt latch: every later call on the engine but ds_engine_halted,
 * ds_engine_get_platform_signature, ds_engine_get_session_header and
 * ds_engine_free is refused with DS_ERR_ENGINE_HALTED ([NCBK.2.9]), and
 * ds_engine_halted reports halted true with DS_ENGINE_FAULT_UNSPECIFIED
 * ([NCBK.2.11]). It raises no EngineError and records no stream event.
 * Another load takes a new engine ([NERR.8.2]).
 *
 * A load refused before it reads the artefact changes nothing: DS_ERR_INVAL,
 * DS_ERR_STATE, and DS_ERR_ENGINE_HALTED on an engine already halted.
 * An engine holds one artefact ([NFCT.1.1]): a load after a successful one
 * is DS_ERR_STATE, as a load after the engine's first stream event is.
 *
 * Errors, the first three before the read:
 *   DS_ERR_INVAL           engine is NULL, or data is NULL with len > 0
 *   DS_ERR_ENGINE_HALTED   the engine has halted, or a failed load spent it
 *   DS_ERR_STATE           the engine already holds an artefact, or has
 *                          emitted a stream event ([NFCT.1.1])
 * and after it, each spending the engine, by the groups of [NERR.8.2], which
 * says what another load of each would need:
 * the artefact's own, [NERR.8.1]'s and [RDSC.11.1]'s:
 *   DS_ERR_DSC_TRUNCATED   stream too short for declared atom length
 *   DS_ERR_DSC_BAD_MAGIC   first atom is not a DscHeader
 *   DS_ERR_DSC_VERSION     artefact version outside this runtime's series
 *   DS_ERR_DSC_DECODE      atom body fails protobuf decode
 *   DS_ERR_DSC_SEMANTIC    decoded body violates a per-atom rule
 *   DS_ERR_DSC_DANGLING    a reference to an entity absent from the artefact
 *   DS_ERR_DSC_DECOMPRESS  atom body declared a non-NONE compression codec;
 *                          COMPRESSION_ZLIB is retired and the runtime carries
 *                          no decompressor (RDSC.4.5.1)
 *   DS_ERR_DSC_CAPABILITY_ABSENT
 *                          the artefact requires a capability this build has no
 *                          code for, or one it does not know; the detail names
 *                          the lowest (RDSC.16.2.7, ds_build_capabilities)
 *   DS_ERR_RETP_INVALID    a network node with node_id 0, a repeated node_id, or
 *                          BetaNode left_parent_id references forming a cycle
 *   DS_ERR_RETP_INDEX_OOB  a cross-reference index out of bounds
 *   DS_ERR_BND_INCOMPLETE  a dialect_def_sha256 that is not 32 bytes ([RDSC.3.7])
 *   DS_ERR_FN_NOT_FOUND    a call naming an op this runtime has no handler for
 *                          where it stands ([RDSC.4a.9.3])
 * the engine's policy:
 *   DS_ERR_BND_DIALECT_MISMATCH
 *                          the admission policy does not admit one of the
 *                          artefact's settings ([NLFC.10.2])
 * and neither:
 *   DS_ERR_OOM             an allocation the load needed failed
 */
ds_result_t ds_engine_load_dsc(ds_engine_t   *engine,
                               const uint8_t *data,
                               size_t         len);

/* ----------------------------------------------------------------- */
/*  Capabilities (NLFC.10)                                            */
/* ----------------------------------------------------------------- */

/* The capability registry (LCAP.1). A mirror of
 * proto/capabilities.proto#Capability, which is the source: the same members
 * with the same numbers (STYL.5.9.7). An artefact's CapabilityInfo atom
 * records its program's settings and requirements in these values
 * (RDSC.16.2). */
typedef enum ds_capability {
    DS_CAPABILITY_UNSPECIFIED             = 0,
    DS_CAPABILITY_REALTIME                = 1,
    DS_CAPABILITY_CONSTSPACE              = 2,
    DS_CAPABILITY_LINEAR_SCAN             = 3,
    DS_CAPABILITY_LOGICAL                 = 4,
    DS_CAPABILITY_DYNAMIC_TTL             = 5,
    DS_CAPABILITY_REGEX                   = 6,
    DS_CAPABILITY_FLOAT                   = 7,
    DS_CAPABILITY_CALL                    = 8,
    DS_CAPABILITY_PUBLISH                 = 9,
    DS_CAPABILITY_CACHE                   = 10,
    DS_CAPABILITY_CACHE_DELETE            = 11,
    /* 12 retired; never reissued. */
    DS_CAPABILITY_NOCOOLDOWN              = 13,
    DS_CAPABILITY_SERIES                  = 14,
    DS_CAPABILITY_SAMPLED_SLOTS           = 15,
    DS_CAPABILITY_PERSIST_ON_SERIES       = 16,
    /* 17, 18 and 19 retired; never reissued. */
    DS_CAPABILITY_STORAGE_HYDRATE_FACTS   = 20,
    DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES = 21
} ds_capability_t;

/*
 * ds_build_capabilities — the capabilities this build of libds has code for
 * (NLFC.10.1), in ascending order. Needs no engine.
 *
 * Writes up to `out_cap` of them to `out` and returns how many there are in
 * all, so a caller may pass `out_cap` 0 to size its array first. `out` may be
 * NULL when `out_cap` is 0.
 *
 * A load of an artefact whose CapabilityInfo `requires` names a capability
 * missing from this list fails with DS_ERR_DSC_CAPABILITY_ABSENT
 * (RDSC.16.2.7). The one capability a build can lack is `regex`, on a build
 * that links the RE2 stub instead of RE2.
 */
size_t ds_build_capabilities(ds_capability_t *out, size_t out_cap);

/* Which settings of one capability an integration admits (NLFC.10.2). */
typedef enum ds_admission {
    DS_ADMIT_EITHER     = 0,   /* the default: `true` and `false` both load */
    DS_ADMIT_TRUE_ONLY  = 1,   /* only an artefact with the capability `true` */
    DS_ADMIT_FALSE_ONLY = 2    /* only an artefact with the capability `false` */
} ds_admission_t;

/*
 * ds_engine_set_admission — the admission policy for one capability, given
 * before an artefact is loaded into `engine` (NLFC.10.2). An engine nobody
 * configures admits every setting.
 *
 * A later ds_engine_load_dsc whose resolved setting for `cap` the policy does
 * not admit fails with DS_ERR_BND_DIALECT_MISMATCH, naming the capability. The
 * policy is checked after the build's capabilities (DS_ERR_DSC_CAPABILITY_
 * ABSENT) and before binding (RDSC.16.2.9).
 *
 * This is policy, where DS_ERR_DSC_CAPABILITY_ABSENT is physical: an
 * integration that cannot support a setting refuses it here whether or not the
 * build has the code, for instance an integration with no adapter behind
 * `call` admitting `call` false only.
 *
 * Errors: DS_ERR_INVAL for a NULL engine, a `cap` outside the registry, or an
 * `admit` outside ds_admission_t. DS_ERR_STATE once ds_engine_load_dsc has
 * succeeded, the policy left as it was: an engine takes one load, which its
 * policy has judged (NLFC.10.2). DS_ERR_ENGINE_HALTED on a halted engine,
 * which a failed load leaves ([NCBK.2.9]).
 */
ds_result_t ds_engine_set_admission(ds_engine_t     *engine,
                                    ds_capability_t  cap,
                                    ds_admission_t   admit);

/* ----------------------------------------------------------------- */
/*  Engine-owned cache bounds                                         */
/* ----------------------------------------------------------------- */

/*
 * ds_engine_set_cache_cap — set the engine-owned cache bounds.
 *
 * Sets [LSTO.4.7.5]'s two bounds ([NSTG.2.6.1]): cap_keys on the live keys,
 * cap_bytes on the total value bytes. 0 leaves that bound unset. Call it
 * before the artefact is loaded, and before any ds_engine_cache_seed the
 * bound is to count. A later call is accepted: it binds the writes and seeds
 * that follow and evicts nothing. A write or seed that would breach a bound
 * fails with DS_ERR_CONTRACT_BREACH and leaves the cache unchanged.
 */
ds_result_t ds_engine_set_cache_cap(ds_engine_t *engine,
                                    uint32_t cap_keys, uint64_t cap_bytes);

/* ------------------------------------------------------------------ */
/*  Working-memory queries                                            */
/* ------------------------------------------------------------------ */

/* Number of facts currently asserted in the engine's working memory. */
ds_result_t ds_engine_fact_count(ds_engine_t *engine, size_t *out);

/*
 * ds_engine_fact_find — the live fact whose id (ds_fact_get_id) is
 * `fact_id` (NFCT.6.4).
 *
 * DS_OK with *out set to it, a pointer valid until the fact is retracted;
 * or DS_ERR_NOT_FOUND with *out set to NULL when no live fact has the id:
 * it was retracted, expired or superseded, or was never assigned. An id
 * is never reassigned, so a caller holding only an id looks the fact up
 * and retracts the pointer this returns. O(1).
 *
 * A read, refused on a halted engine with DS_ERR_ENGINE_HALTED ([NCBK.2.9]),
 * whose working memory is undefined. DS_ERR_STATE from inside a callback on
 * this engine, as ds_engine_fact_count.
 */
ds_result_t ds_engine_fact_find(ds_engine_t *engine, uint64_t fact_id,
                                ds_fact_t **out);

/*
 * ds_engine_mem_t — byte-level RAM accounting for the Rete engine's
 * major in-memory structures.
 *
 * Every *_bytes field is the size of objects currently in use (live).
 * Facts, tokens and activations are allocated on demand, so the live byte
 * fields are the heap they occupy, and pool_reserved_bytes is 0: this
 * edition has no pre-allocated pools ([NRTM.9.1]).
 *
 * Interned string content and JSON slot payloads are NOT counted in
 * wm_fact_bytes — interned bytes are reported under intern_string_bytes
 * (shared, not per-fact); JSON trees are separate allocations and out
 * of scope here. Alpha/beta memories hold borrowed fact/token pointers,
 * so their *_index_bytes cover only the owning hash tables, never the
 * pointed-to facts (which belong to WM).
 */
/* The tag is `ds_engine_mem_s`, not `ds_engine_mem`: in C++ a struct and a
   function of one name (ds_engine_mem, below) trip -Wshadow inside this
   header. Use the typedef. */
typedef struct ds_engine_mem_s {
    /* Working memory: live fact records + the WM hash/occupancy index. */
    size_t wm_fact_count;       /* live facts in working memory */
    size_t wm_fact_bytes;       /* fact headers + inline slot arrays */
    size_t wm_index_bytes;      /* WM hash buckets + occupancy arrays */

    /* Alpha network: per-node fact-pointer memories. */
    size_t alpha_node_count;
    size_t alpha_match_count;   /* total fact entries across alpha memories */
    size_t alpha_index_bytes;   /* alpha-memory hash tables */

    /* Beta network: partial-match tokens + join indices. */
    size_t beta_node_count;
    size_t beta_token_count;    /* tokens held across all left memories */
    size_t beta_token_bytes;    /* token headers + facts[] pointer arrays */
    size_t beta_index_bytes;    /* lmem/right/ralpha/ltok/block tables + child arrays */

    /* Interned string/bytes table. */
    size_t intern_count;        /* live interned strings */
    size_t intern_string_bytes; /* summed byte length of interned content */
    size_t intern_index_bytes;  /* intern hash table (bucket + length arrays) */

    /* Pre-allocated pool arenas: 0 in this edition (above). */
    size_t pool_reserved_bytes;

    size_t total_bytes;         /* sum of all live *_bytes fields above */
} ds_engine_mem_t;

/*
 * Populate `out` with a byte-level memory breakdown of the engine's
 * RETE structures. Returns DS_ERR_UNSUPPORTED if the engine has no RETE
 * network to introspect.
 */
ds_result_t ds_engine_mem(ds_engine_t *engine, ds_engine_mem_t *out);

/*
 * ds_engine_assert — assert a DS fact into the engine's working memory.
 *
 * Builds a Rete fact from the (schema, values) pair, asserts it, and
 * returns the resulting ds_fact_t wrapper via out_fact. The wrapper is
 * owned by the engine and invalidated on retraction.
 *
 *   schema    one this engine handed out: ds_engine_schema_find,
 *             ds_engine_schema_at, ds_fact_get_schema on one of its facts,
 *             or a slot's schema_ref, read with ds_schema_get_slot from one
 *             of its schemas. Any other, a schema of another engine included, is
 *             undefined behaviour ([IDAT.1.6]), whatever schemas this
 *             engine holds
 *   values    array of length n_values; one ds_slot_value_t per slot
 *             in schema declaration order; kinds must match the
 *             declared slot types per IDAT.4.6
 *   n_values  must equal the schema's slot count (ds_schema_get_slot_count)
 *   out_fact  may be NULL; non-NULL on success is the wrapper
 *
 * Errors:
 *   DS_ERR_INVAL             — NULL args, n_values mismatch, or NULL string/Json/Schema
 *                              value
 *   DS_ERR_SLOT_TYPE_MISMATCH— a value's kind doesn't match the slot's declared type;
 *                              also: SCHEMA-slot value's ref->schema does not match
 *                              the slot's declared schema_ref
 *   DS_ERR_SCHEMA_UNKNOWN    — schema is not one this engine holds. No schema this
 *                              engine handed out meets this ([NFCT.2.11])
 *   DS_ERR_ENCODING          — a String slot that is not well-formed UTF-8
 *                              ([LSTR.8.5]); nothing is asserted and nothing
 *                              recorded. A Json tree's text is refused when the
 *                              tree is built, so a caller of this header does
 *                              not meet this for a Json slot ([NFCT.2.11])
 *   DS_ERR_TIME_RANGE        — a DS_SLOT_TYPE_DATE value outside the Date range,
 *                              days -106751 (1677-09-22) through 106751
 *                              (2262-04-11) from 1970-01-01, a Time's range
 *                              ([LTIM.1.2.2]); nothing is asserted
 *   DS_ERR_INVAL             — also: a `TimeZoneOffset` fact whose valid_from
 *                              is not before its valid_until, whose offset_s is
 *                              outside [-64800, 64800], or whose zone is "UTC"
 *                              ([LTIM.10.9]); nothing is asserted
 */
ds_result_t ds_engine_assert(ds_engine_t           *engine,
                             const ds_schema_t     *schema,
                             const ds_slot_value_t *values,
                             uint32_t               n_values,
                             ds_fact_t            **out_fact);

/* A fact's deadline is its schema's TTL. */

/*
 * ds_engine_assert_external — assert a published fact from another tier
 * (NCBK.10.4). `bytes`/`len` are a FactExternal (RFCS.23.1): what
 * DS_EV_ACTION_PUBLISH carried on the sending engine, or what a call
 * argument of kind DS_ARG_ENCODED_FACT carried to the integrator. The
 * engine checks its schema_hash, decodes it and resolves its fact
 * references (RFCS.23.7): a reference equal to a live fact is that fact, and
 * KIND_NULL in a fact-reference slot is a reference with no target, nullable
 * or not. Each fact it asserts gets this engine's own event_id ([NCBK.10.3])
 * and takes its lifetime from the receiving schema (RFCS.23.6).
 *
 * It refuses the whole FactExternal, asserting nothing, with:
 *   DS_ERR_PARSE                 — the bytes are not a FactExternal, a text
 *                                  field at any depth holds U+0000 ([LSTR.1.5])
 *                                  or is not well-formed UTF-8, a Json field's
 *                                  text does not parse, or its references nest
 *                                  deeper than 16 (RFCS.23.4)
 *   DS_ERR_SCHEMA_UNKNOWN        — a schema this program does not declare
 *   DS_ERR_SCHEMA_HASH_MISMATCH  — its schema_hash differs from this
 *                                  program's schema of that name
 *   DS_ERR_FACT_REF_CONFLICT     — a nested reference meets a live fact
 *                                  with the same key and different values
 *   DS_ERR_SLOT_TYPE_MISMATCH    — a field's kind is not its slot's, a
 *                                  reference names another schema than its
 *                                  slot's, KIND_NULL is in a slot not declared
 *                                  T? that holds no fact reference, or a Json
 *                                  field's document is null at its root
 *   DS_ERR_NAN_REJECTED          — a Float field is a NaN ([LEXP.4.2])
 *   DS_ERR_JSON_LIMIT            — a Json field is over one of its limits
 *                                  ([LGRA.5.8.6])
 *   DS_ERR_TIME_RANGE            — a Date field outside the Date range
 *                                  ([LTIM.1.2.2]), a fact's TTL deadline
 *                                  outside the Time range ([RFCS.6.7]), or a
 *                                  held seed's deadline ([NLFC.9.5])
 *   DS_ERR_INVAL                 — a TimeZoneOffset fact it holds is malformed
 *                                  ([LTIM.10.9])
 *   DS_ERR_CONTRACT_BREACH       — a field's value is longer than its slot's
 *                                  capacity ([LSTR.11.3]); no BoundsError
 * Each holds at any depth, and is judged before the first assert and the
 * call's sample, so the call is no step and records nothing.
 *
 * Between its first assert and its last, only DS_ERR_OOM or
 * DS_ERR_ENGINE_HALTED, from a halt an assert raises, can stop a delivery. The
 * engine asserts nothing more and takes back nothing it has asserted.
 */
ds_result_t ds_engine_assert_external(ds_engine_t   *engine,
                                      const uint8_t *bytes,
                                      size_t         len);

/* ------------------------------------------------------------------ */
/*  Per-fact accessors (see IDAT.4)                                   */
/* ------------------------------------------------------------------ */
/*
 * Read-only accessors over an opaque ds_fact_t. The wrapper is
 * engine-owned; pointers returned are valid until the fact is
 * retracted (TTL sweep, explicit retract, logical-justifier-end).
 * Holding a ds_fact_t* across pumps risks use-after-free unless
 * the caller has subscribed to FACT_RETRACT events and clears
 * its reference on retraction.
 *
 * All accessors return DS_OK with the out-pointer populated on
 * success; DS_ERR_INVAL on NULL fact / NULL out;
 * DS_ERR_NOT_FOUND on out-of-range index.
 *
 * After an EngineError each returns DS_ERR_ENGINE_HALTED, whenever the
 * handle was taken ([NCBK.2.9]). The one window is the call that raised
 * it: a read is answered until that call has delivered the EngineError
 * (DS_EV_ENGINE_ERROR) or returned, so the records it delivers ahead of
 * the EngineError -- a halted upsert's FactAssert and its old fact's
 * FactRetract -- can be read ([RFCS.6.7]).
 */

/* Engine-assigned monotonic id; survives retract -> reassert as
 * a new id (no identity-preservation across retraction). */
ds_result_t ds_fact_get_id(const ds_fact_t *fact, uint64_t *out);

/* Borrowed pointer to the schema this fact instantiates; valid
 * for engine lifetime. */
ds_result_t ds_fact_get_schema(const ds_fact_t   *fact,
                                const ds_schema_t **out);

/* Engine clock at the moment the fact was asserted. */
ds_result_t ds_fact_get_asserted_ns(const ds_fact_t *fact,
                                     uint64_t        *out);

/* TTL-sweep deadline. 0 for LOGICAL-lifecycle facts and for
 * facts the engine isn't tracking under TTL. Non-zero values
 * are clock timestamps: the engine clock at assert plus the
 * fact's TTL window. */
ds_result_t ds_fact_get_ttl_deadline_ns(const ds_fact_t *fact,
                                         uint64_t        *out);

/* Number of slots on the fact: its schema's slot count
 * (ds_schema_get_slot_count). */
ds_result_t ds_fact_get_slot_count(const ds_fact_t *fact,
                                    uint32_t        *out);

/* Read the i-th slot. *out_name is set to the schema-declared
 * slot name (engine-owned borrow, valid for engine lifetime);
 * *out_value is set to the slot's tagged-union value. Either
 * out-pointer may be NULL if the caller only wants one half, and
 * both being NULL is DS_ERR_INVAL ([NFCT.6.2]).
 * Index 0..count-1; out-of-range returns DS_ERR_NOT_FOUND.
 *
 * A DS_SLOT_FACT_REF slot is resolved when it is read: v.ref is
 * the referenced fact while it is in working memory, and NULL
 * once it has left (retracted, expired, superseded, or withdrawn
 * by truth maintenance). The kind stays DS_SLOT_FACT_REF; a null
 * slot is DS_SLOT_NULL. ds_fact_get_slot_ref_id gives the
 * target's id either way. */
ds_result_t ds_fact_get_slot(const ds_fact_t *fact,
                              uint32_t          index,
                              const char      **out_name,
                              ds_slot_value_t  *out_value);

/* The fact id (ds_fact_get_id) of the fact the i-th slot refers
 * to, whether or not that fact is still in working memory. Ids
 * are never reused, so the id identifies the target after it has
 * gone. DS_ERR_NOT_FOUND on an out-of-range index; DS_ERR_INVAL
 * on NULL fact / NULL out, or when the slot does not hold a
 * fact-ref (including a null slot). 0 when the slot refers to
 * no fact. */
ds_result_t ds_fact_get_slot_ref_id(const ds_fact_t *fact,
                                    uint32_t         index,
                                    uint64_t        *out);

/* Visit every live fact in the engine's working memory, optionally
 * filtered by schema. The visitor is called once per matching fact
 * with a borrowed, read-only fact pointer; iteration stops as soon
 * as the visitor returns a non-OK result, and that result is
 * propagated as the call's return value.
 *
 *   schema   when non-NULL, only facts whose schema pointer equals
 *            this argument are visited. When NULL, every live fact
 *            is visited regardless of schema.
 *   visitor  must be non-NULL. Receives the borrowed fact pointer
 *            and the caller's `user` cookie. Return DS_OK_R to
 *            continue, any non-OK result to abort iteration with
 *            that result. The visitor may read the fact via the
 *            ds_fact_get_* accessors above. Every ds_engine_* call on
 *            this engine from inside it, read or mutation, returns
 *            DS_ERR_STATE: the walk is in progress, and a mutation
 *            would invalidate it while a read would see it
 *            half-visited (RARC.13.17). A call on another engine is
 *            unaffected. Capture data into `user` and act on it
 *            after the iteration returns.
 *   user     opaque cookie passed through to every visitor call.
 *
 * Iteration order is unspecified ([NFCT.6.3]). Callers needing a
 * stable order should sort the captured results.
 *
 * Returns DS_OK_R after a complete walk with no early-abort, or
 * the visitor's non-OK result on abort. DS_ERR_INVAL on NULL
 * engine / NULL visitor. */
typedef ds_result_t (*ds_fact_visitor_fn)(const ds_fact_t *fact,
                                           void            *user);

ds_result_t ds_engine_for_each_fact(ds_engine_t        *engine,
                                     const ds_schema_t  *schema,
                                     ds_fact_visitor_fn  visitor,
                                     void               *user);

/* ------------------------------------------------------------------ */
/*  JSON values (see specs/language/EXPRESSIONS/, LEXP)               */
/* ------------------------------------------------------------------ */

/*
 * DS Json values. Used for opaque adapter payloads whose shape can't
 * be statically committed to.
 *
 * `ds_json_t` is an OPAQUE handle ([IDAT.1.2]): the tree layout is private.
 * Inspect a tree through the accessor
 * API — ds_json_get_kind + the typed getters + array/object iteration, or
 * ds_json_get_path for dotted lookups — and construct one either by parsing
 * text (ds_json_parse) or with the ds_json_new_* / append / set builders. The
 * `ds_json_kind_t` discriminant below is public so callers can dispatch on
 * ds_json_get_kind's result.
 */

typedef enum {
    DS_JSON_NULL    = 0,
    DS_JSON_BOOL    = 1,
    DS_JSON_INT     = 2,
    DS_JSON_FLOAT   = 3,
    DS_JSON_STRING  = 4,
    DS_JSON_ARRAY   = 5,
    DS_JSON_OBJECT  = 6,
} ds_json_kind_t;

/*
 * The four limits on a Json value. ds_json_parse refuses a document over any of
 * them and the builders refuse to make a tree over any of them, with
 * DS_ERR_JSON_LIMIT, so no tree libds holds exceeds them.
 *
 *   DEPTH         a scalar, or an empty array or object, is one level; each
 *                 enclosing array or object adds one, so "[[1]]" is three.
 *   NODES         every scalar, array and object in the tree, the root included.
 *   STRING_BYTES  the bytes of every string value and every object key, summed.
 *   TEXT_BYTES    the length of text handed to ds_json_parse, refused unread.
 *
 * FX_TEXT_BYTES is the text limit of a received FactExternal's Json field
 * (LGRA.5.8.6): the most text LGRA.5.8.7a writes for a value within the
 * other three, 6 x STRING_BYTES + 32 x NODES, so a value one engine holds can
 * always reach another. Every other text keeps TEXT_BYTES.
 */
#define DS_JSON_MAX_DEPTH         16
#define DS_JSON_MAX_NODES         256
#define DS_JSON_MAX_STRING_BYTES  16384
#define DS_JSON_MAX_TEXT_BYTES    24576
#define DS_JSON_MAX_FX_TEXT_BYTES 106496

/*
 * Parse a JSON document into a tree. text need not be NUL-terminated;
 * len bounds it. On success, *out is the root node and the caller
 * owns it; release with ds_json_free.
 *
 * A Float literal (one with '.' or an exponent) is correctly rounded to a
 * double, ties to even, however many digits it has. A Json value holds no
 * non-finite float ([LGRA.5.8.10]), so a literal whose value rounds to +Inf or
 * -Inf ("1e400", "1.7976931348623159e308") is malformed and refused, never
 * saturated to the largest finite double. One below the smallest subnormal
 * reads as zero, which a Json value holds as +0.0 ([LGRA.5.8.8]).
 *
 * Errors: DS_ERR_INVAL for a NULL out, or a NULL text with len > 0;
 * DS_ERR_JSON_LIMIT for a document over a DS_JSON_MAX_* limit --
 * text longer than DS_JSON_MAX_TEXT_BYTES is refused before any of it is read,
 * and the other three refuse at the first value that crosses one;
 * DS_ERR_ENCODING for text that is not well-formed UTF-8 anywhere in it
 * ([LSTR.8.5]), after the text limit and before any value is read;
 * DS_ERR_PARSE for malformed input, for an integer literal (no '.', no
 * exponent) outside int64 -- refused, never saturated and never read as a
 * Float -- and for a Float literal that rounds to an infinity
 * ([LGRA.5.8.10]); DS_ERR_OOM for allocation failure mid-parse. *out is NULL
 * on error.
 */
ds_result_t ds_json_parse(const char *text, size_t len, ds_json_t **out);

/*
 * Free a tree the caller owns: one from ds_json_parse, ds_json_clone or a
 * builder. Recursively releases child nodes, owned strings, arrays, and
 * key/value tables. Safe on NULL.
 */
ds_result_t ds_json_free(ds_json_t *tree);

/*
 * Deep-copy a tree. *out is a fresh tree, caller-owned: release it with
 * ds_json_free ([IDAT.10.2]). NULL src is allowed and yields NULL out.
 *
 * Errors: DS_ERR_OOM on allocation failure mid-clone (any partial
 * tree is freed before return; *out is NULL).
 */
ds_result_t ds_json_clone(const ds_json_t *src, ds_json_t **out);

/*
 * Serialize a tree back to a JSON-conformant text string. *out is
 * a NUL-terminated, caller-owned heap allocation; release with
 * ds_free() (IALC.4.3). *out_len, if non-NULL, receives the length
 * excluding the NUL.
 *
 * Output is canonical: object keys are emitted in byte-wise order regardless
 * of insertion or parse order, so two structurally equal trees serialize to
 * identical bytes.
 *
 * Errors: DS_ERR_INVAL for a NULL tree or a NULL out;
 * DS_ERR_JSON_NONFINITE for a tree holding a non-finite Float anywhere in it,
 * which JSON has no text for ([LDET.3.2.7]); no public call makes such a tree
 * ([LGRA.5.8.10]), and libds's own writers rely on the check; DS_ERR_OOM on
 * allocation failure. Past the two NULL checks, *out is NULL on error.
 */
ds_result_t ds_json_serialize(const ds_json_t *tree,
                              char           **out,
                              size_t          *out_len);

/*
 * ds_free — release a raw buffer libds returned with ownership transfer.
 *
 * libds exports exactly one public free entry point for the small, closed
 * set of owned raw buffers an integrator frees directly (IALC.4.2 / 4.3):
 *   - the ds_json_serialize() *out string;
 *   - ds_engine_get_justifiers()'s *out_timetags array, *out_rule_names
 *     array, and each *out_rule_names[i] string.
 * Using ds_free (not libc free) keeps release consistent with libds's
 * allocator under a custom-allocator build. ds_free(NULL) is a no-op.
 *
 * The four typed handles (ds_engine_t, ds_fact_t, ds_schema_t, ds_json_t;
 * IDAT.3.1) are never released by ds_free: ds_engine_free and ds_json_free
 * release the two a caller owns, and an engine's facts and schemas go with
 * the engine.
 */
void ds_free(void *p);

/*
 * Look up a value by dotted path. Path syntax ([IDAT.3.3.10]): object keys
 * separated by '.', array indices in '[N]', N being digits alone. Examples:
 *
 *   "body.temperature"           object body, then key temperature
 *   "body.forecast[0].max"       array index 0 then object key max
 *
 * The whole path is judged before the tree is read, so malformed syntax is
 * DS_ERR_INVAL on every tree: the empty path, an empty key, a leading '.', an
 * index with a sign or white space, and "a[0]b". A member whose key is empty,
 * or holds '.' or '[', has no path: ds_json_object_get reads it.
 *
 * For a well-formed path, returns DS_OK whether or not it resolves; *out is
 * set to a borrowed pointer into the tree on hit, or NULL on miss
 * (key not found, index out of range, wrong kind mid-traversal).
 *
 * Errors: DS_ERR_INVAL for NULL args or malformed path syntax.
 */
ds_result_t ds_json_get_path(const ds_json_t  *root,
                             const char       *path,
                             const ds_json_t **out);

/*
 * Fine-grained read + build API. Lets integrators inspect and construct Json
 * trees without reaching into `struct ds_json`. Conventions: results via
 * out-params on every call;
 * reads take `const` and return BORROWS valid for the source tree's lifetime
 * (never freed by the caller); typed getters are STRICT — the node must be
 * exactly the requested kind (JSON's distinct INT/FLOAT are not coerced), else
 * DS_ERR_INVAL with a detail naming the actual and requested kinds. A NULL
 * argument is DS_ERR_INVAL with a detail naming the argument ([IDAT.3.3.5]).
 * Call ds_json_get_kind first, then the matching typed getter.
 *
 * A read writes its out-parameters on success and on the misses of
 * ds_json_array_at and ds_json_object_get, each *out = NULL. After any other
 * error, ds_json_object_at's miss among them, an out-parameter is not written
 * and must not be read ([IDAT.3.3.6]).
 */

/* Discriminant. DS_ERR_INVAL on NULL node/out. */
ds_result_t ds_json_get_kind(const ds_json_t *node, ds_json_kind_t *out);

/* Strict scalar getters — node MUST be the named kind, else DS_ERR_INVAL. */
ds_result_t ds_json_get_bool (const ds_json_t *node, bool    *out);
ds_result_t ds_json_get_int  (const ds_json_t *node, int64_t *out);
ds_result_t ds_json_get_float(const ds_json_t *node, double  *out);
/*
 * Borrowed, tree-lifetime string pointer; *out_len (may be NULL) is the byte
 * length. A string holds no NUL ([LSTR.1.1]) and is NUL-terminated, so
 * *out_len equals strlen(*out_s).
 */
ds_result_t ds_json_get_string(const ds_json_t *node, const char **out_s,
                               size_t *out_len);

/* Array. array_at yields a borrowed child; DS_ERR_NOT_FOUND if index >= len. */
ds_result_t ds_json_array_len(const ds_json_t *node, size_t *out);
ds_result_t ds_json_array_at (const ds_json_t *node, size_t index,
                              const ds_json_t **out);

/*
 * Object. object_get is the by-key common case (borrowed value; an object holds
 * one value per key, [IDAT.3.3.4]; DS_ERR_NOT_FOUND if the key is absent).
 * object_at is positional iteration (0..len-1): any out-ptr may be NULL;
 * out_key/out_value are borrows and *out_key_len (may be NULL) is the key byte
 * length; DS_ERR_NOT_FOUND if index >= len. Its order is the order members
 * entered the object ([IDAT.3.3.11]): text order for a parsed object, first
 * insertion for a built one. object_set on a present key keeps its position,
 * ds_json_clone keeps every position, and ds_json_serialize sorts by key instead.
 *
 * object_get and array_at return DS_ERR_NOT_FOUND on a miss, where
 * ds_json_get_path returns DS_OK with *out = NULL.
 */
ds_result_t ds_json_object_len(const ds_json_t *node, size_t *out);
ds_result_t ds_json_object_get(const ds_json_t *node, const char *key,
                               const ds_json_t **out);
ds_result_t ds_json_object_at (const ds_json_t *node, size_t index,
                               const char **out_key, size_t *out_key_len,
                               const ds_json_t **out_value);

/*
 * Builders. Each new_* yields a fresh node (*out), caller-owned ([IDAT.10.2]);
 * dispose of it exactly
 * once — ds_json_free it, transfer it into a parent via array_append/object_set
 * (the parent then owns it), or hand it to the engine as a DS_SLOT_JSON slot
 * value (the engine deep-clones on assert per [NFCT.2.4], so you still own and
 * free your built tree afterward). new_string copies `len` bytes and
 * NUL-terminates; a NUL among the `len` bytes is refused, because a String
 * holds no U+0000 ([LSTR.1.1]). new_float folds -0.0 to +0.0 ([LGRA.5.8.8]).
 * Errors: DS_ERR_INVAL (NULL out; s NULL with len>0; a NUL in s),
 * DS_ERR_JSON_NONFINITE (new_float of +Inf, -Inf or NaN, which a Json value
 * does not hold, [LGRA.5.8.10]), DS_ERR_JSON_LIMIT (new_string longer than
 * DS_JSON_MAX_STRING_BYTES, checked before the NUL), DS_ERR_ENCODING (s is
 * not well-formed UTF-8, [LSTR.8.5]; checked after the NUL), DS_ERR_OOM.
 */
ds_result_t ds_json_new_null (ds_json_t **out);
ds_result_t ds_json_new_bool (bool    v, ds_json_t **out);
ds_result_t ds_json_new_int  (int64_t v, ds_json_t **out);
ds_result_t ds_json_new_float(double  v, ds_json_t **out);
ds_result_t ds_json_new_string(const char *s, size_t len, ds_json_t **out);
ds_result_t ds_json_new_array (ds_json_t **out);
ds_result_t ds_json_new_object(ds_json_t **out);

/*
 * Mutators. On SUCCESS the container TAKES OWNERSHIP of `child` (freeing the
 * container frees it — do not free `child` again). On ERROR ownership does NOT
 * move: `child` is not consumed and the caller must free it, and the container
 * is left unchanged. object_set copies `key` (key_len bytes); if `key` is
 * already present it REPLACES the value (freeing the old) — one value per key, as
 * ds_json_parse holds by refusing text that repeats a key (DS_ERR_PARSE).
 * Errors: DS_ERR_INVAL (NULL/ wrong-kind container; NULL child; a NUL among
 * object_set's key_len bytes, [LSTR.1.1]; a child that already belongs to a
 * container; a child that contains the container), DS_ERR_ENCODING
 * (object_set's key is not well-formed UTF-8, [LSTR.8.5]), DS_ERR_JSON_LIMIT
 * (the whole tree, measured from the container's root, would be over
 * DS_JSON_MAX_DEPTH, DS_JSON_MAX_NODES or DS_JSON_MAX_STRING_BYTES; and
 * object_set's key_len over DS_JSON_MAX_STRING_BYTES, checked before the key
 * is read, so before the NUL and the UTF-8), DS_ERR_OOM.
 */
ds_result_t ds_json_array_append(ds_json_t *array, ds_json_t *child);
ds_result_t ds_json_object_set  (ds_json_t *object, const char *key,
                                 size_t key_len, ds_json_t *child);

/* ------------------------------------------------------------------ */
/*  Log level enum                                                    */
/* ------------------------------------------------------------------ */

/* The C mirror of proto/log_level.proto#LogSeverity, the log level's one
   definition [STYL.5.9.7]: the same five members with the same values, held
   together by the spec gate's styl_5_9_2_fault_enums. The level keywords
   follow Python's `logging` module per LGRA.10.1. */
typedef enum {
    DS_LOG_DEBUG    = 0,
    DS_LOG_INFO     = 1,
    DS_LOG_WARNING  = 2,
    DS_LOG_ERROR    = 3,
    DS_LOG_CRITICAL = 4,
} ds_log_level_t;


/* ------------------------------------------------------------------ */
/*  Stream events (see IDAT.7)                                        */
/* ------------------------------------------------------------------ */

/*
 * Observable events that pass through the recorder. Every state
 * change libds produces — fact assert / retract, rule fire, action
 * dispatch, clock tick — surfaces here in seq order.
 *
 * Stream events are runtime-observable; integrators register a
 * stream-sink callback per IARC.1.14 and decide where the data goes
 * (stderr, durable file, debug protocol, replay store, /dev/null).
 *
 * Some kinds are reserved and never emitted ([NCBK.2.4]), and a retired
 * value is never reissued. Handle the `default` case: adding a producer
 * later is ABI-additive.
 *
 * The C mirror of proto/stream_event_kind.proto#StreamEventKind, the event
 * kind's one definition [STYL.5.9.7]: DS_EV_<X> is STREAM_EVENT_KIND_<X>,
 * with the same value, and a number the proto reserves is a hole here too.
 * The spec gate's styl_5_9_2_fault_enums holds the two together.
 */
typedef enum {
    DS_EV_FACT_ASSERT       = 0,
    DS_EV_FACT_RETRACT      = 1,
    DS_EV_FACT_MODIFY       = 2,    /* reserved, never emitted ([NCBK.2.4]): an
                                       upsert is a FACT_ASSERT and a FACT_RETRACT */
    DS_EV_RULE_FIRE_BEGIN   = 3,
    DS_EV_RULE_FIRE_END     = 4,
    DS_EV_ACTION_CALL       = 5,
    DS_EV_ACTION_EMIT       = 6,
    DS_EV_ACTION_PUBLISH    = 7,
    DS_EV_ACTION_CACHE_SET  = 8,
    DS_EV_ACTION_CACHE_GET  = 9,    /* reserved, never emitted ([NCBK.2.4]): a
                                       cached() read is an internal engine read
                                       and dispatches no callback */
    /* 10 and 11 retired; never reissued. */
    DS_EV_ACTION_LOG        = 12,
    /* 13 and 14 retired; never reissued. */
    DS_EV_TICK              = 15,
    DS_EV_ACTION_CACHE_DELETE = 16,
    /* 17 retired; never reissued. */

    /* Matched LHS facts for the activation that is about to fire.
       Emitted immediately before DS_EV_RULE_FIRE_BEGIN on the same
       activation, and carries that firing's timetag ([NCBK.2.12]).
       facts[] is a borrowed array of ds_fact_t* valid only for the
       callback's duration. */
    DS_EV_RULE_LHS_FACTS   = 18,

    /* Cooldown timer armed — emitted when a rule with `cooldown:` fires
       and starts a new suppression window.  fire_at_ns is the earliest
       clock_ns at which the rule may fire again; timetag is the firing
       that armed it ([NCBK.2.12]). */
    DS_EV_TIMER_ARMED      = 19,

    /* RESERVED, NEVER EMITTED ([NCBK.2.4]). A cooldown-gated rule's later
       firing is seen through its ordinary firing events, joined to the
       DS_EV_TIMER_ARMED that preceded it by timetag. The value stays
       declared and is never reissued ([STYL.2.8.7]). */
    DS_EV_TIMER_FIRED      = 20,

    /* ── The four fault classes ([NCBK.2.8]) ─────────────────────────────
       Every fault is a stream event, in `seq` order; there is no separate
       fault callback. Each kind is one recorded atom (ComputationError 325,
       TypeError 328, BoundsError 329, EngineError 330).

       The disposition is the kind, so none carries a disposition field: a
       TypeError and a ComputationError abandon the activation, a BoundsError
       leaves the engine intact, an EngineError halts.

       ⚠ A fault reaching the callback does NOT mean it was persisted. The
       engine emits; whether the event reaches durable storage is the
       integrator's, and for a recorder failure it by definition does not —
       libds writes nothing itself ([IARC.1.14]). */

    /* A value is present and the operation is invalid at that site; the
       activation is abandoned and the engine is intact. */
    DS_EV_TYPE_ERROR       = 21,

    /* A DECLARED cap was reached ([LERR.1.5]); the operation is
       rejected and the engine is intact. */
    DS_EV_BOUNDS_ERROR     = 22,

    /* Engine state is no longer trustworthy; the tier halts.

       THIS IS THE LAST GASP ([NCBK.2.9]): after it the engine refuses every
       ds_engine_* call but four with DS_ERR_ENGINE_HALTED, and acts on none
       of them — a pump, an assert or retract, a load or registration, a
       configuration or callback setter, ds_engine_clone, and every read of
       working memory, a schema or the introspection surface. The halt is a
       latch and never clears. The call during which the engine raised it
       returns DS_ERR_ENGINE_HALTED too, ahead of any other status:
       so the integrator that reads only statuses learns of the halt from the
       call that caused it. It stops at the EngineError, even inside a fact
       change under way ([LERR.1.4.7]), so the engine's state afterwards is
       undefined; that is why a read is refused.

       The four that stay valid read nothing that state holds:
       ds_engine_halted, ds_engine_get_platform_signature,
       ds_engine_get_session_header, and ds_engine_free.

       The callback may still finish its own work (log it, flush its sink,
       signal a supervisor) and return. It may not re-enter ([RARC.13.16]);
       the four above are valid once the callback has returned.
       `ds_engine_free` remains the integrator's responsibility — freeing is
       disposal, not resumption. */
    DS_EV_ENGINE_ERROR     = 23,

    /* A well-typed operation has no answer — divide by zero, `sqrt` of a
       negative, a total `Float :: Int` that is not representable. The
       activation is abandoned and the engine is intact, as for a TypeError;
       the two differ in why. Recorded as `ComputationError` (325), whose
       kind is a ds_trap_kind_t. */
    DS_EV_COMPUTATION_ERROR = 24,

    /* One pump of the engine to quiescence begins ([RFCS.22]). Emitted once
       per host pump, INCLUDING a pump that
       fires nothing -- the pump no other event records -- after the pump's
       clock sample and its TICK ([LTIM.2.8.5]) and before anything the pump
       does. The recorder writes it as the PumpBoundary atom, and a replayer
       pumps on meeting one. No payload: what the pump fired is the events that
       follow it, and `clock_ns` is the pump's one sample. */
    DS_EV_PUMP              = 25,
} ds_stream_ev_kind_t;

/* ── fault cause enums ──────────────────────────────────────────────────────
 *
 * C mirrors of the proto enums the fault payloads carry as their first field:
 * each has its proto's members with the same values, and is a registry under
 * [STYL.2.8.7]: a value is never reissued. */

/* ComputationError.kind — proto/engine_error.proto#TrapKind.
 *
 * A CLOSED SET ([LERR.1.4.9]): a fourth kind is a breaking change, not an
 * append. 4, 5 and 6 are retired; never reissued. */
typedef enum {
    DS_TRAP_UNSPECIFIED       = 0,  /* refused at load */
    DS_TRAP_DIVIDE_BY_ZERO    = 1,
    DS_TRAP_DOMAIN            = 2,  /* `sqrt` of a negative; cosine of a
                                       zero vector — mathematically
                                       undefined at that input */
    DS_TRAP_NOT_REPRESENTABLE = 3,  /* a total `Float :: Int` that is not */
} ds_trap_kind_t;

/* EngineError.fault — proto/engine_fault.proto#EngineFault.
 *
 * APPEND-ONLY, unlike TrapKind: each condition has a clause, and a new
 * condition with a clause is an append. */
typedef enum {
    DS_ENGINE_FAULT_UNSPECIFIED   = 0,  /* refused at load */
    DS_ENGINE_FAULT_ARTEFACT_LIED = 1,  /* ill-typed op on a non-Json-sourced
                                           value — the load-time shape said one
                                           thing and the value is another — or
                                           a call whose operand count or shape
                                           its op does not admit
                                           ([RDSC.4a.9.3]), or a slot index,
                                           read by an AlphaTest or a VarExpr or
                                           written by a SlotAssign, that names
                                           no slot of the fact's schema
                                           ([RDSC.4a.9.1]) */
    DS_ENGINE_FAULT_PATTERN_INDEX = 2,  /* [RARC.5.3.3] */
    DS_ENGINE_FAULT_BINDING_ORDER = 3,  /* [RARC.5.6.11] */
    DS_ENGINE_FAULT_ORDER_KEY     = 4,  /* [RARC.5.4.9] */
    /* 5 retired; never reissued. */
    DS_ENGINE_FAULT_ALLOCATION    = 6,  /* no declared cap was the limit */
    DS_ENGINE_FAULT_PUMP_WCET     = 7,  /* [RTCT.7.3] — the pump overran
                                           pump_wcet_ns. Known only at pump
                                           completion and the engine cannot
                                           interrupt a pump, so the deadline is
                                           already missed: that pump returns
                                           DS_ERR_CONTRACT_WCET_HALT, the tier
                                           halts, and later calls get the
                                           ordinary DS_ERR_ENGINE_HALTED */
    DS_ENGINE_FAULT_INTERNAL      = 8,  /* [IERR.1.7] — libds found its own
                                           invariant broken */
} ds_engine_fault_t;

/*
 * ds_engine_halted — read the halt latch (NCBK.2.11).
 *
 * *out_halted is true once an EngineError has halted the engine (NCBK.2.9),
 * and *out_fault is the ds_engine_fault_t its DS_EV_ENGINE_ERROR carried.
 * On an engine a failed load spent, which raised no EngineError, they are true
 * and DS_ENGINE_FAULT_UNSPECIFIED ([RDSC.9.8]).
 * Before a halt they are false and DS_ENGINE_FAULT_UNSPECIFIED. Either
 * out-pointer may be NULL if the caller wants only the other.
 *
 * A read: it answers on a halted engine, so an integrator that missed the
 * event, or learned of the halt only from DS_ERR_ENGINE_HALTED, can still
 * learn the cause. DS_ERR_STATE from inside a callback on this engine, as
 * every entry point.
 */
ds_result_t ds_engine_halted(const ds_engine_t *engine, bool *out_halted,
                             ds_engine_fault_t *out_fault);

/* BoundsError.cap — proto/bounds_error.proto#CapName.
 *
 * The set is [RTCT.7.1]'s cap table, not one the language fixes: a cap that
 * table gains is appended here.
 *
 * 10, 11 and 12 are PER-INSTANCE where 1..9 are per-engine: the cap alone does
 * not say which node, series or slot. `rule_name` on the arm carries the
 * activation context. */
typedef enum {
    DS_CAP_UNSPECIFIED        = 0,   /* refused at load */
    DS_CAP_WM_MAX             = 1,
    DS_CAP_AGENDA             = 2,
    DS_CAP_MAX_FIRES_PER_PUMP = 3,
    DS_CAP_TOKEN_POOL         = 4,
    DS_CAP_INTERN             = 5,
    DS_CAP_INTERN_BYTES       = 6,
    DS_CAP_PUMP_WCET_NS       = 7,
    DS_CAP_CACHE              = 8,
    DS_CAP_CACHE_BYTES        = 9,
    DS_CAP_NODE_CAPACITY      = 10,  /* nodes[i].capacity */
    DS_CAP_SERIES_CAPACITY    = 11,  /* series[i].capacity */
    DS_CAP_VALUE_CAPACITY     = 12,  /* a slot's declared `capacity` ([LSTR.11.3]) */
} ds_cap_name_t;

/* A stream event: a transparent, library-owned callback payload, read field
   by field and borrowed for the callback's duration ([IDAT.1.2], [IDAT.7.1]).
   Not one of the opaque handles above. */
typedef struct ds_stream_ev ds_stream_ev_t;

struct ds_stream_ev {
    uint64_t            seq;       /* per-engine monotonic */
    uint64_t            clock_ns;  /* engine clock at emit */
    ds_stream_ev_kind_t kind;
    union {
        struct { ds_fact_t *fact; } fact_assert;
        struct { ds_fact_t *fact; } fact_retract;
        struct { ds_fact_t *fact; } fact_modify;    /* unused: never emitted */
        /* Rule-firing events. rule_name is engine-interned and valid for
           the callback's duration ([NCBK.2.5]).
           timetag is the firing activation's identity — recorded into
           the RuleFireAnnotation atom so (timetag, rule_name) is
           byte-identical to the bracketed CallIssued's join key (RFCS.11.2 /
           RFCS.15.2). */
        struct { const char *rule_name; int64_t timetag; } rule_fire_begin;
        struct { const char *rule_name; int64_t timetag; } rule_fire_end;
        /* Per-verb action events. Emitted from the dispatcher AFTER
           the verb's primary effect succeeds. Pointers borrowed for
           the callback's duration only, except action_emit.fact: a
           working-memory handle, valid until its DS_EV_FACT_RETRACT
           ([NCBK.2.5]).
           ACTION_PUBLISH carries the published fact as a VIEW, valid
           for the callback only: a `publish` puts nothing in working
           memory ([LTIE.4.3]), so the view has no id, and no lookup
           finds it ([NCBK.2.5]). It also carries the fact's
           FactExternal encoding (RFCS.23.1), the bytes another tier
           hands to ds_engine_assert_external; copy them before the
           callback returns ([NCBK.10.1]). `external` is NULL and
           `external_len` 0 when an allocation failed to build them.
           ACTION_EMIT carries the emitted fact (a local assert);
           ACTION_LOG carries the verb's payload by
           value so the integrator can mirror to a stream sink
           independently of the per-verb typed callbacks. */
        struct { ds_fact_t     *fact;
                 const uint8_t *external;
                 size_t         external_len; }  action_publish;
        struct { ds_fact_t *fact; }              action_emit;
        struct { ds_log_level_t level;
                 const char *category;
                 const char *message; }          action_log;

        /* Cache-op payloads. key is engine-interned (engine-lifetime
           safe). For ACTION_CACHE_SET value is the tree being stored,
           borrowed for the callback's duration. DS_EV_ACTION_CACHE_GET
           is never emitted ([NCBK.2.4]): a cached() read is an internal
           engine read with no get callback ([NCBK.7]), so its arm is
           unused. */
        struct { const char *key;
                 const ds_json_t *value; }      action_cache_get;
        struct { const char *key;
                 const ds_json_t *value;
                 uint64_t ttl_ns; }              action_cache_set;
        struct { const char *key; }              action_cache_delete;
        /* ds-call payload, the same { service, correlation, args,
           arg_count } the call callback receives ([NCBK.6.9]).
           service is the "domain.method" string the rule supplied;
           correlation is the author's `as` value per LCRS.3.1, or the
           generated `$<outer_rule_name>_c<N>_g<k>` for a call with no
           `as` or whose computed `as` renders "" ([LCCO.3.4], [LRST.1.2])
           — opaque either way. Every call carries one, never NULL and
           never empty ([LCRS.3.1]). args are the typed arguments,
           sorted by name (ds_arg_t). It fires once the arguments
           evaluate, before the callback, whatever the callback returns
           ([IDSP.6.5]). timetag + rule_name are the firing
           activation's identity — the recording-only
           CallIssued↔RuleFireAnnotation join key ([RFCS.15]); the
           encoder records them into the CallIssued atom, the live wire
           leaves them absent. timetag is never 0 and rule_name never
           NULL ([NCBK.6.2]), as in ds_call_request_t. All string members
           are engine-interned, borrowed for the callback's duration. */
        struct { const char     *service;
                 const char     *correlation;
                 const ds_arg_t *args;
                 uint32_t        arg_count;
                 int64_t         timetag;
                 const char     *rule_name; }     action_call;

        /* DS_EV_RULE_LHS_FACTS — matched facts, one per LHS pattern
           in declaration order.  facts[] is a borrowed array, valid only
           for the callback's duration. timetag is the firing's
           ([NCBK.2.12]): the value its RULE_FIRE_BEGIN carries, so a
           consumer joins the two by key, not by position. */
        struct { const char *rule_name;
                 ds_fact_t **facts;        /* borrowed; callback duration */
                 uint32_t    fact_count;
                 int64_t     timetag; }  rule_lhs_facts;

        /* DS_EV_TIMER_ARMED — the cooldown timer a firing armed.
           rule_name is interned (engine lifetime). kind is "cooldown"
           for v1. window_ns is the configured suppression window;
           fire_at_ns is clock_ns + window_ns. timetag is the arming
           firing's ([NCBK.2.12]). */
        struct { const char *rule_name;
                 const char *kind;
                 uint64_t    window_ns;
                 uint64_t    fire_at_ns;
                 int64_t     timetag; }          timer_armed;
        /* DS_EV_TIMER_FIRED is reserved and never emitted ([NCBK.2.4]);
           the arm stays so the union's shape does not change. */
        struct { const char *rule_name;
                 const char *kind; }             timer_fired;

        /* ── fault payloads ───────────────────────────────────────────────
         *
         * The disposition is the kind, so no arm carries one.
         *
         * All string members are engine-interned and borrowed for the
         * callback's duration, as everywhere else in this union.
         *
         * Each of the four kinds 21–24 has an arm. A `switch` over
         * `ds_stream_ev_kind_t` must still handle its `default`, for the
         * retired values and for kinds added later. */

        /* DS_EV_TYPE_ERROR — proto/type_error.proto#TypeError. A value is
           present and the operation is invalid at that site; the activation is
           abandoned and the engine is intact.
           There is no `expected` field: a consumer holding the artefact
           derives it from `node_id`.
           `rule_name` is the fault's rule name ([LERR.9.11]): the activation's
           rule, `$alpha_<id>` / `$beta_<id>` for a fault raised at a node
           during matching, `$engine` with no node site. Never NULL or "".
           A `$` name is synthetic ([LLEX.10.6.1]): no rule is called that. */
        struct { uint32_t    node_id;
                 const char *schema_name;
                 const char *slot_name;
                 const char *actual;
                 const char *rule_name; }        type_error;

        /* DS_EV_ENGINE_ERROR — proto/engine_fault.proto#EngineError.
           ⚠ THE LAST GASP ([NCBK.2.9]). After this event every ds_engine_*
           call on this engine but ds_engine_halted, the platform signature,
           the session header and `ds_engine_free` returns
           DS_ERR_ENGINE_HALTED, reads included; `ds_engine_free` remains the
           integrator's responsibility. See DS_EV_ENGINE_ERROR for the
           boundary. `node_id` is 0 for a fault with no node site.
           `rule_name` is named as `type_error`'s is ([LERR.9.11]); a fault with
           no node site carries `$engine`. Never NULL or "". */
        struct { ds_engine_fault_t fault;
                 uint32_t          node_id;
                 const char       *rule_name; }  engine_error;

        /* DS_EV_COMPUTATION_ERROR — proto/engine_error.proto#ComputationError.
           A well-typed operation with no answer. Abandons the activation and
           leaves the engine intact, as a type_error does; the two differ in
           why. `rule_name` + `timetag` are the activation identity
           ([RFCS.15]'s CallIssued/RuleFireAnnotation join key); `node_id` is
           the in-ruleset locator LineSpan maps to a line ([RDSC.14.3]).

           The proto's `recoverable` (field 8) is not mirrored: it is the same
           for every TrapKind, and the disposition is the kind. */
        struct { ds_trap_kind_t kind;
                 const char    *rule_name;
                 int64_t        timetag;
                 const char    *schema_name;
                 const char    *slot_name;
                 uint64_t       fact_id;
                 uint32_t       node_id; }       computation_error;

        /* DS_EV_BOUNDS_ERROR — proto/bounds_error.proto#BoundsError. A
           declared limit was reached. The operation is rejected and the engine
           is intact; an allocation that failed against no declared cap is an
           `engine_error`.

           ⚠ The test is whether the engine is intact, not whether a cap was
           the limit: an allocation refused against `wm_max` mid-propagation
           leaves it untrustworthy, so it is an `engine_error` ([LERR.1.4.9]).

           `rule_name` + `timetag` are the activation identity where one
           exists — a `max_fires_per_pump` trip has one, an `intern_cap` breach
           during load does not. ABSENCE IS MEANINGFUL and readable: `NULL` and
           a zero timetag, which is not a valid timetag. */
        struct { ds_cap_name_t  cap;
                 uint64_t       limit;
                 uint64_t       observed;
                 const char    *rule_name;
                 int64_t        timetag; }      bounds_error;

        /* DS_EV_TICK: an observed clock sample ([LTIM.2.8.5]). The
           event's clock_ns is the monotonic sample; this is the wall
           sample, UTC nanoseconds since the Unix epoch ([LTIM.2.8.3]).
           wall_set is false while the wall clock has no value (a mock
           clock before ds_engine_wall_clock_set, a board with no wall
           source), and wall_ns is then 0 and means nothing. */
        struct { bool    wall_set;
                 int64_t wall_ns; }             tick;

        /* A consumer switches on .kind and reads only the matching
           member. */
    } p;
};

/*
 * Stream-sink callback. Receives every observable event in seq order.
 * Pointers in the payload (e.g. fact, rule, activation) are valid
 * only during the callback unless documented otherwise.
 */
typedef ds_result_t (*ds_stream_cb_t)(ds_engine_t          *engine,
                                       const ds_stream_ev_t *event,
                                       void                 *user);

/* Register the stream-sink callback. Pass cb=NULL to remove. */
ds_result_t ds_engine_set_stream_callback(ds_engine_t    *engine,
                                          ds_stream_cb_t  cb,
                                          void           *user);

/* ------------------------------------------------------------------ */
/*  Telemetry callbacks (see IARC.1.14)                               */
/* ------------------------------------------------------------------ */

/*
 * libds emits metrics and operational logs through integrator-
 * provided callbacks. The integrator decides where the data goes
 * (Prometheus, StatsD, stderr, Loki, nowhere — their choice).
 * Callbacks run on the pump thread, return ds_result_t, and must
 * not block. Unregistered (NULL) callbacks silently drop.
 */

/* The C mirror of specs/registry/metric_kind.ebnf, the metric kind's one
   definition [STYL.5.9.7]: name for name and value for value, held together
   by the spec gate's styl_5_9_2_ebnf_c_mirror. */
typedef enum {
    DS_METRIC_COUNTER   = 0,  /* monotonically non-decreasing */
    DS_METRIC_GAUGE     = 1,  /* any change, may go up or down */
    DS_METRIC_HISTOGRAM = 2,  /* per-observation value; integrator buckets */
} ds_metric_kind_t;

typedef struct ds_metric_label {
    const char *key;    /* caller-owned; valid for the callback's duration */
    const char *value;  /* caller-owned; valid for the callback's duration */
} ds_metric_label_t;

typedef struct ds_metric {
    const char              *name;       /* e.g. "ds.wm.fact_count"; dot-separated; caller-owned */
    ds_metric_kind_t         kind;
    double                   value;      /* counters pass integers via double (exact < 2^53) */
    const ds_metric_label_t *labels;     /* NULL when n_labels == 0 ([NMET.3.1]) */
    uint32_t                 n_labels;
} ds_metric_t;

typedef struct ds_log_event {
    ds_log_level_t  level;
    const char     *category;  /* e.g. "schema", "dsc-load", "samples"; caller-owned */
    const char     *message;   /* human-readable; caller-owned */
} ds_log_event_t;

typedef ds_result_t (*ds_metric_cb_t)(ds_engine_t       *engine,
                                      const ds_metric_t *metric,
                                      void              *user);

typedef ds_result_t (*ds_log_cb_t)(ds_engine_t          *engine,
                                   const ds_log_event_t *event,
                                   void                 *user);

/*
 * Register the metric-emission callback for this engine. Passing cb=NULL
 * removes any previously-registered callback (subsequent emits are
 * silently dropped).
 */
ds_result_t ds_engine_set_metric_callback(ds_engine_t    *engine,
                                          ds_metric_cb_t  cb,
                                          void           *user);

/*
 * Register the log-emission callback for this engine. Passing cb=NULL
 * removes any previously-registered callback.
 */
ds_result_t ds_engine_set_log_callback(ds_engine_t *engine,
                                       ds_log_cb_t  cb,
                                       void        *user);

/* ------------------------------------------------------------------ */
/*  Timezones ([LTIM.10.6]–[LTIM.10.10])                              */
/* ------------------------------------------------------------------ */

/*
 * libds carries no tzdata ([LTIM.10.1]), and has no timezone callback. The
 * integrator asserts facts of the built-in schema `TimeZoneOffset`
 * ([LTIM.10.6]: zone, valid_from, valid_until, offset_s), and local(),
 * date() and the zone-bearing casts resolve through them ([LTIM.10.7]):
 * among the live facts whose `zone` is the designation byte for byte, the
 * one with the greatest `valid_from` not after the instant answers while its
 * `valid_until` is after it. Exactly "UTC" is 0 with no fact ([LTIM.10.8]).
 * A miss is a ComputationError of kind DOMAIN ([LTIM.10.5.3]); never UTC
 * ([LTIM.10.5.4]). ds_engine_assert refuses a malformed row with
 * DS_ERR_INVAL ([LTIM.10.9]). The facts are on the stream, so a replay
 * resolves as the run did.
 */

/* ------------------------------------------------------------------ */
/*  Call callback (action verb `call`, see IDSP.6)                    */
/* ------------------------------------------------------------------ */

/*
 * The DS `call` action issues an async request to an external service
 * (an adapter target, an in-process call target, a remote service —
 * the integrator routes per their stack). The rule's RHS does not
 * wait. A service declares `response T` or `no response`; a response
 * is a fact of the service's own `ttl` schema T, carrying the call's
 * correlation in its `corr` slot, which the integrator asserts later
 * via ds_engine_assert. A failure is a CallError fact.
 *
 * Per LCRS.3.1 an author-authored correlation is the `as` kwarg: a
 * string the rule writer picks, which flows verbatim to the response
 * fact's `corr` slot.
 *
 * A call with NO `as`, or whose computed `as` renders "" ([LRST.1.2]),
 * gets a **generated** correlation instead, `$<outer_rule_name>_c<N>_g<k>`
 * per [LCCO.3.4], unique per activation and reproduced on replay, whether or
 * not it has continuations and whatever its service (LCRS.3.1). Either
 * way the string is opaque and echoed verbatim ([NCBK.6.3]); it is never
 * NULL and never empty. Before a call
 * reaches this callback the engine retracts the prior response and
 * CallError for its correlation itself (LCRS.6.2.1); the integrator
 * must not.
 *
 * Timeouts are adapter-side (LCRS.7.3): the engine tracks no per-call
 * deadline and never synthesises a response or a CallError.
 *
 * The arguments are typed (NCBK.6.10) and sorted by name. A fact
 * argument is DS_ARG_ENCODED_FACT: its FactExternal bytes, schema
 * name and asserted_at (ds_encoded_fact_t); forward the bytes to
 * another tier's ds_engine_assert_external without decoding them. A
 * Float argument that evaluates to NaN refuses the call with
 * DS_ERR_NAN_REJECTED and nothing is issued.
 */

typedef struct ds_call_request {
    const char     *service;      /* "domain.method"; engine-interned, valid for cb duration */
    const char     *correlation;  /* the call's `as` value, or the generated one when it has none (LCRS.3.1); valid for cb duration */
    const ds_arg_t *args;         /* one per kwarg the call supplies, sorted by name; valid for cb duration */
    uint32_t        arg_count;
    int64_t         timetag;       /* firing activation's creation timetag; the CallIssued↔RuleFireAnnotation join key ([RFCS.15]). Never 0 ([NCBK.2.12]). */
    const char *rule_name;     /* firing rule (interned) — with timetag, the activation identity. Never NULL ([NCBK.6.2]). */
} ds_call_request_t;

typedef ds_result_t (*ds_call_cb_t)(ds_engine_t             *engine,
                                     const ds_call_request_t *request,
                                     void                    *user);

/*
 * Register the call callback for this engine. Pass cb=NULL to remove;
 * subsequent ds-call invocations then return DS_ERR_STORAGE_UNAVAILABLE
 * (essential per IDSP.6.4 — a calling rule expects a response).
 */
ds_result_t ds_engine_set_call_callback(ds_engine_t  *engine,
                                        ds_call_cb_t  cb,
                                        void         *user);

/* ------------------------------------------------------------------ */
/*  Cache persistence callbacks (the `cache` / `cache_delete` writes) */
/* ------------------------------------------------------------------ */

/*
 * The cache is engine-owned ([NCBK.7] / [IDSP.7]). `cached()` reads the
 * authoritative in-engine map directly — there is NO get callback.
 * The two callbacks below are an OPTIONAL outbound persistence surface
 * (engine → external store): they mirror `cache` / `cache_delete` writes so an
 * integrator can back the cache with durable storage. NULL set/delete ⇒ a
 * volatile in-engine cache (not an error: the cache verbs are not essential,
 * so DS_ERR_STORAGE_UNAVAILABLE is not returned). The persistence
 * hook is never a second writer: the engine mutates its cache first and does
 * not roll back on a hook failure ([LSTO.4.7.2]).
 *
 * Lifetime: the JSON tree handed to set_cb is dispatcher-owned and borrowed
 * for the callback's duration only.
 */

/* The cache ttl_ns that sets no expiry: what ds_engine_cache_seed
   takes, and what the cache-set callback and its stream event carry, for an
   entry that never expires. A computed 0 is "forever", not "already
   expired", so spell it. Cache TTLs only. */
#define DS_CACHE_TTL_NONE  UINT64_C(0)

/*
 * A write, handed to the set callback as a const payload pointer, the shape
 * every registered callback has ([NCBK.1.1], [NSTG.2.3]).
 *
 * The struct and the tree it points to are borrowed for the callback's duration
 * only ([NCBK.7.4]); copy what you keep.
 */
typedef struct ds_cache_write {
    const char      *key;
    const ds_json_t *value;   /* borrowed for the callback's duration */
    uint64_t         ttl_ns;  /* DS_CACHE_TTL_NONE = no expiry */
} ds_cache_write_t;

typedef ds_result_t (*ds_cache_set_cb_t)(ds_engine_t            *engine,
                                          const ds_cache_write_t *write,
                                          void                   *user);

/*
 * Why an entry left the cache. Every removal notifies, and says which: an
 * author's `cache_delete`, or a deadline passing.
 *
 * TWO exits, and NO capacity-eviction reason ([NSTG.2.4]). A write that would
 * breach cap_keys or cap_bytes FAILS with DS_ERR_CONTRACT_BREACH and leaves
 * the cache unchanged ([LSTO.4.7.5]); the engine never makes room by dropping
 * something else, so a run does not depend on memory pressure ([LDET.2.1]).
 *
 * A persisting store drops the row for either reason ([NSTG.2.4]'s table);
 * the reason is there for a store to log why an entry went.
 *
 * The C mirror of specs/registry/cache_removal_reason.ebnf, the reason's one
 * definition [STYL.5.9.7]: name for name and value for value, held together
 * by the spec gate's styl_5_9_2_ebnf_c_mirror. A later reason is allocated
 * there first.
 */
typedef enum ds_cache_removal_reason {
    DS_CACHE_REMOVED_DELETE = 0,   /* explicit `cache_delete` verb */
    DS_CACHE_REMOVED_TTL    = 1,   /* ttl deadline passed */
} ds_cache_removal_reason_t;

/*
 * A removal, handed to the delete callback as a const payload pointer, the
 * shape the metric and log callbacks use ([NCBK.1.1]).
 *
 * `key` is borrowed for the callback's duration only.
 */
typedef struct ds_cache_removal {
    const char               *key;
    ds_cache_removal_reason_t reason;
} ds_cache_removal_t;

typedef ds_result_t (*ds_cache_delete_cb_t)(ds_engine_t              *engine,
                                             const ds_cache_removal_t *removal,
                                             void                     *user);

/*
 * Cache-callback ABI version. The registrant passes ds_engine_cache_callbacks
 * the version it compiled against, DS_CACHE_CB_ABI_VERSION; a mismatch is
 * refused at registration with DS_ERR_BACKEND_ABI_VERSION, and nothing is
 * registered.
 */
#define DS_CACHE_CB_ABI_VERSION 3u

/*
 * Register the OPTIONAL cache persistence callbacks for this engine
 * ([NCBK.7]). Both ops share one user pointer (typical: the same store handle
 * backs both). Either cb may be NULL; the engine's cache is still fully
 * functional (volatile). Calling this setter again replaces the previous
 * registration; pass both NULL to detach persistence.
 */
ds_result_t ds_engine_cache_callbacks(ds_engine_t          *engine,
                                       uint32_t              abi_version,
                                       ds_cache_set_cb_t    set_cb,
                                       ds_cache_delete_cb_t delete_cb,
                                       void                *user);

/*
 * ds_engine_cache_seed — seed the engine-owned cache before the run
 * ([IARC.12] / [RARC.5.7.10] / [LSTO.4.7.2] / [LSTO.4.5.2]).
 *
 * A DIRECT cache-store upsert of `key` → `value`, distinct from a rule `cache`
 * write: it emits NO ACTION_CACHE_SET stream event and does NOT invoke the
 * write-through set callback — it is arrange / restore (seeding FROM a durable
 * snapshot or a test's `initial:` block, not a rule action). The engine
 * serialize-and-copies `value` with the canonical ds_json_serialize — the same
 * serializer the rule `cache`-write path uses — so a seeded value and a
 * rule-written value with the same logical JSON store byte-identically; the
 * caller retains ownership of the tree. Upsert (an existing key is overwritten);
 * ttl_ns = DS_CACHE_TTL_NONE (0) = no expiry, non-zero = a lifetime counted
 * from the engine's first sample, its first input or pump ([NLFC.9.4]): the
 * entry then expires at that sample plus ttl_ns, as a `cache … ttl:` write
 * does. A clone made before that sample counts from its own.
 * Counted against the bounds ds_engine_set_cache_cap sets ([LSTO.4.7.5]).
 *
 * Setup-phase only, in the window a load is ([NLFC.9.1], [NFCT.1.1]): call it
 * before the engine's first stream event, which a host assert emits as a pump
 * does. After that it returns DS_ERR_STATE, and the cache is unchanged: a
 * recording announces the host's seeds in its prelude, which it writes at that
 * event.
 *
 * Errors: DS_ERR_INVAL for a NULL engine, key or value, before any of these.
 * Then the first of these that refuses decides, and leaves the cache as it was
 * ([NLFC.9.6]):
 *   1. DS_ERR_ENGINE_HALTED: the engine is halted ([NCBK.2.9]).
 *   2. DS_ERR_STATE: the engine has emitted a stream event ([NLFC.9.2]).
 *   3. DS_ERR_TIME_RANGE: ttl_ns is greater than INT64_MAX, which no `Time`
 *      deadline can hold ([NLFC.9.5]).
 *   4. DS_ERR_JSON_LIMIT: the value is over one of its limits ([LGRA.5.8.6]).
 *   5. DS_ERR_ENCODING: the key, or a string or key in the value, is not
 *      well-formed UTF-8 ([LSTR.8.5]).
 *   6. DS_ERR_CONTRACT_BREACH: storing it would breach a bound
 *      ds_engine_set_cache_cap set ([LSTO.4.7.5]).
 * An allocation that fails is DS_ERR_OOM at whichever step needs it, and leaves
 * the cache as it was.
 *
 * Where the engine's first sample would put a seed's deadline outside the
 * `Time` range, the call that would take that sample (the first assert,
 * external delivery or pump) returns DS_ERR_TIME_RANGE and changes nothing:
 * no sample, no record, the seeds still held and the window still open
 * ([NLFC.9.5]).
 */
ds_result_t ds_engine_cache_seed(ds_engine_t     *engine,
                                 const char      *key,
                                 const ds_json_t *value,
                                 uint64_t         ttl_ns);

/* ------------------------------------------------------------------ */
/*  Series ([NSBK.2]).                                                */
/* ------------------------------------------------------------------ */

/* No public function reads a series ([NSBK.6.3]): a series' values reach an
   integrator only through what rules do with them. Nothing here names a
   series type either; the backend vtable and the types it uses are libds's
   own ([ISBK.1], [ISBK.2.1]). */

/*
 * [NSBK.2.3]: the backend set is closed, and so are its implementations. The
 * seven backings are fixed ([NSBK.6.1]); there is no registration entry point,
 * and an engine from `ds_engine_new` or `ds_engine_clone` arrives with all seven
 * registered. A failure to register them is a construction failure.
 *
 * A backing is serialised nowhere ([LSER.9.2]) and feeds rule conditions, so a
 * second implementation that disagreed in the last place would fire different
 * rules with nothing on a replay to show it ([LDET.2.2a]).
 *
 * Of the series-backend codes (-620 .. -625) only DS_ERR_BACKEND_NOT_REGISTERED
 * is a status the series paths return, and with the closed set registered a
 * series on any of the seven backings always has its backend
 * ([NERR.10.2]).
 */

/* ------------------------------------------------------------------ */
/*  Platform signature (LDET.2.3) — provenance                        */
/* ------------------------------------------------------------------ */

/* The platform signature (LDET.2.3) is a tuple of environment
   properties plus the identities of the registered series backends.
   It is provenance, not a scope on the determinism guarantee
   (NDET.2.1): a recorded session replays bit-for-bit on any
   conforming platform whether or not two runs' signatures match
   (LDET.3.4.1), and across every release of the recording's minor
   series (NSBK.7.1, LDET.1.10). The first four fields below are
   LDET.2.3.2-5; libds_version and the backend identities complete it.

   Strings are static-storage compile-time constants populated by
   libds from preprocessor macros at build time; the tuple is
   stable for the engine's lifetime. The integrator copies before
   retaining beyond a single ds_engine_get_platform_signature call.

   `backends` lists `<atom>:<backend_name>:<backend_version>` per
   registered series-backend slot, in slot-id order, `<atom>` being the
   backing atom's body message (NDET.2.2):
   `SeriesBackendRingBuffer:ds-ring-buffer:1.0.0`. Each string is
   engine-owned; freed with the engine. ds_engine_new registers all seven
   backends ([NSBK.2.3]), so the list is exactly NDET.2.5's seven entries,
   in its order, never empty.

   This accessor is purely informational. */
typedef struct ds_platform_signature {
    const char *os_family;        /* "linux" / "bsd" / "unknown" */
    const char *cpu_arch;         /* "x86_64" / "aarch64" / "arm" / "x86" / "unknown" */
    const char *libc;             /* "glibc-X.Y" / "bsd-libc" / "unknown" */
    const char *compiler;         /* "gcc-X.Y" / "clang-X.Y" / "unknown" */
    const char *libds_version;   /* libds version string */

    const char * const *backends; /* per-slot identity strings */
    size_t              n_backends;
} ds_platform_signature_t;

/*
 * Snapshot the engine's current platform signature into *out. The
 * static-storage strings (os_family / cpu_arch / libc / compiler /
 * libds_version) live for the program's lifetime; the `backends`
 * array of strings is engine-lifetime (freed when the engine is
 * freed). Integrators copy before retaining across engine
 * teardown.
 *
 * Errors:
 *   DS_ERR_INVAL — NULL engine or NULL out
 *   DS_ERR_OOM   — backend identity list construction failed
 */
ds_result_t ds_engine_get_platform_signature(
    ds_engine_t              *engine,
    ds_platform_signature_t  *out);

/* ------------------------------------------------------------------ */
/*  Fact-stream session header (LFST.4 / RFCS.4)                      */
/* ------------------------------------------------------------------ */

/* The session-header fields that prefix a DS fact stream (the StreamHeader
   atom, see proto/ds/stream_header.proto and RFCS.4). This accessor exposes
   the engine-captured subset so tooling — the conformance harness, forensic
   dumps — can read them without a stream file.

   The fields: ds_version, session_id, tier_id, and the whole dialect-binding
   tuple ([RBND.1.3]) — dsc_hash, capabilities, dialect_def_sha256 — which a
   stream header carries ([RBND.2]). Not reported: rt_config_sha256,
   rt_config ([NRTM.9.1]) and wall_start_iso8601.

   Lifetime: the string / byte pointers point into engine-owned
   storage that is stable for the engine's lifetime; copy before
   retaining across ds_engine_free. */
typedef struct ds_session_header {
    /* [LDET.1.10] — the DS version that wrote the stream, and the ONLY version
       a stream carries. Points into storage stable for the engine's
       lifetime, like `session_id`. */
    const char *ds_version;
    const char *session_id;    /* the run id given at ds_engine_new, or "" if
                                  none was given ([RFCS.4.3]). The engine
                                  mints none and reads no entropy. */
    const char *tier_id;       /* the tier id given at ds_engine_new, or ""
                                  if none was given ([RFCS.4.4]). */
    const uint8_t *dsc_hash;   /* the loaded DSC's own header `dsc_sha256`,
                                  copied (RFCS.4.5, RBND.3.1), or NULL if no
                                  DSC has been loaded yet. */
    size_t dsc_hash_len;       /* 32 when dsc_hash != NULL, else 0. */
    /* The rest of the dialect-binding tuple ([RBND.1.3]), copied from the
       loaded DSC's own header as `dsc_hash` is ([RBND.3.1]) and written into
       the stream header beside it ([RBND.2]). Both NULL with a 0
       length until a DSC has been loaded. */
    const uint32_t *capabilities;  /* `Capability` numbers, in the order the
                                      DSC header carries them (ascending,
                                      [RBND.1.3]); may be empty when loaded. */
    size_t n_capabilities;
    const uint8_t *dialect_def_sha256;  /* the DSC header's, 32 bytes. */
    size_t dialect_def_sha256_len;      /* 32 when non-NULL, else 0. */
} ds_session_header_t;

/*
 * ds_engine_get_session_header — snapshot the engine's session-header
 * fields per LFST.4 / RFCS.4.
 *
 * Every pointer points into engine-owned storage that is stable for the
 * engine's lifetime; copy before retaining across ds_engine_free.
 * `ds_version` is this build's DS version ([LDET.1.10]). `session_id` and
 * `tier_id` are the run id and tier id given at ds_engine_new, "" for one not
 * given. `dsc_hash`, `capabilities` and `dialect_def_sha256` are NULL, with
 * their lengths 0, until a DSC has been successfully loaded.
 *
 * Errors:
 *   DS_ERR_INVAL — NULL engine or NULL out
 */
ds_result_t ds_engine_get_session_header(
    ds_engine_t          *engine,
    ds_session_header_t  *out);

/*
 * ds_engine_retract — retract a previously-asserted fact.
 *
 * The fact pointer is one this engine handed out and is still live (not
 * yet retracted, expired or superseded): from ds_engine_assert's out_fact,
 * ds_engine_fact_find, a ds_engine_for_each_fact visitor, a stream event's
 * payload, or a fact-ref slot read with ds_fact_get_slot. On success, the
 * fact is removed from working memory and the pointer is invalid for any
 * further use.
 *
 * Retracting a pointer that is no longer live, such as one already
 * retracted, is undefined behaviour: the first retraction freed what it
 * points to. Callers who might retract optimistically should use a
 * pointer-to-pointer pattern and NULL it after.
 *
 * Errors:
 *   DS_ERR_INVAL          — NULL engine or NULL fact
 *   DS_ERR_STATE          — called from inside a callback on this engine
 *                           ([RARC.13.16])
 *   DS_ERR_ENGINE_HALTED  — the engine had halted before this call, or the
 *                           retraction's propagation raised an EngineError
 *                           ([NCBK.2.9])
 *   DS_ERR_FACT_INVALID   — the handle holds no fact. Every handle the engine
 *                           hands out holds one, so a caller obeying [NFCT.3.2]
 *                           does not meet this ([NERR.6])
 *   a stream callback's non-OK status — the first one the callback returned
 *                           during the call, which the engine does not act on
 *                           ([NCBK.1.5])
 */
ds_result_t ds_engine_retract(ds_engine_t *engine, ds_fact_t *fact);

/* ------------------------------------------------------------------ */
/*  Pump (see IARC.1.10 / IARC.3.2)                                   */
/* ------------------------------------------------------------------ */

/*
 * ds_engine_pump — drain pending consumption-loop work and return.
 *
 * The only writer on this engine; the integrator must never call pump
 * concurrently on the same engine.
 *
 * The pump takes the engine and nothing else, and runs the agenda to
 * exhaustion ([NLFC.2.2]). No argument bounds one pump's work, and nothing
 * outside the call can stop it part-way: it is an in-process call.
 *
 * Errors. A firing's failure does not stop the pump: the agenda still runs
 * to exhaustion, and the failure is the pump's status. The pump's own
 * failure takes precedence, and an EngineError's halt over everything:
 *   DS_ERR_INVAL         — NULL engine
 *   DS_ERR_STATE         — called from inside a callback on this engine
 *                          ([RARC.13.16])
 *   DS_ERR_ENGINE_HALTED — a firing raised an EngineError during this pump,
 *                          or one had halted the engine before it ([NCBK.2.9])
 *   DS_ERR_TIME_RANGE    — this is the engine's first sample, and it would put
 *                          a seeded cache entry's deadline outside the `Time`
 *                          range; nothing is sampled or recorded ([NLFC.9.5])
 *   DS_ERR_CONTRACT_BREACH — a cache write in a firing would exceed a cache
 *                          cap: the write is refused and a DS_EV_BOUNDS_ERROR
 *                          recorded ([LSTO.4.7.5]); or, on the engine's first
 *                          step, the program's `initial` cache items would,
 *                          and the pump is refused before firing anything
 *                          ([LGRA.24.3])
 *   DS_ERR_STORAGE_UNAVAILABLE — a firing's `call` met no call callback
 *                          ([IDSP.6.4])
 *   DS_ERR_NAN_REJECTED  — a firing's `call` had a NaN Float argument, which
 *                          refuses the call ([NERR.6])
 *   DS_ERR_SERIES_NO_BACKING — a series read no declared backing could answer
 *                          ([NERR.6])
 *   a callback's non-OK status — the call callback's, or the cache
 *                          persistence callbacks', with the meaning its verb
 *                          gives it; or the first the stream callback returned,
 *                          which the engine does not act on ([NCBK.1.5])
 *   DS_ERR_OOM           — allocation failed
 */
ds_result_t ds_engine_pump(ds_engine_t *engine);

#ifdef __cplusplus
}
#endif
#endif /* LIBDS2_H */

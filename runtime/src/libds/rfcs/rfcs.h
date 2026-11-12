/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rfcs/rfcs.h — the RFCS fact-stream codec: plain C structs and byte buffers, never
 * the generated *.pb-c types.
 *
 * Every atom is two nested length-delimited protobuf frames ([RFCS.19.1]):
 *
 *     [0x0A][varint outer_len][varint tag][varint body_len][protobuf body]
 *
 * An atom's identity is its oneof field number ([RFCS.16.1]), which this API takes and
 * returns; `atoms.h` names every allocated one.
 */
#ifndef DS_LIBDS_RFCS_H
#define DS_LIBDS_RFCS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "libds.h"
#include "atoms.h"

/*
 * A view into the atom body it was decoded from, valid while that body is. Not
 * NUL-terminated, and never NULL: an absent field is "" with `len` 0. No clause bounds
 * these strings ([RFCS.4.3], [RFCS.4.4]).
 */
typedef struct ds_rfcs_str {
    const char *ptr;
    size_t      len;
} ds_rfcs_str_t;

/* Whether `v` holds exactly the C string `s`. */
static inline bool ds_rfcs_str_eq(ds_rfcs_str_t v, const char *s)
{
    size_t n = strlen(s);
    return n == v.len && (n == 0 || memcmp(v.ptr, s, n) == 0);
}

/*
 * The widest a frame prefix can be: outer tag (1) + outer length varint (<=5) + inner
 * tag varint (<=2, field <= 2047) + inner length varint (<=5).
 */
#define DS_RFCS_ATOM_PREFIX_MAX 13u

/*
 * Bytes the frame prefix occupies, which varies with the field number and the body
 * length: a caller packing a body in place asks before it packs. 0 if `atom` is not an
 * allocated field number.
 */
size_t ds_rfcs_atom_prefix_size(uint32_t atom, size_t body_len);

/* prefix + body. 0 if `atom` is not an allocated field number. */
size_t ds_rfcs_atom_framed_size(uint32_t atom, size_t body_len);

/*
 * If out is NULL, or out_cap is smaller than the framed size, *out_len is set to the
 * required size, DS_ERR_INVAL is returned and no bytes are written. DS_ERR_INVAL too for
 * NULL out_len, an unallocated field number, or a body_len that overflows u32.
 */
ds_result_t ds_rfcs_pack_atom(uint32_t atom,
                              const uint8_t *body, size_t body_len,
                              uint8_t *out, size_t out_cap, size_t *out_len);

/* Each encoder frames one complete atom, with ds_rfcs_pack_atom's size-query contract. */

/* [RFCS.4], [RBND.2]. */
ds_result_t ds_rfcs_encode_header(const ds_session_header_t *hdr,
                                  uint8_t *out, size_t out_cap, size_t *out_len);

/* ClockAdvance ([RFCS.10]): wall_ns is written only when wall_set is. */
ds_result_t ds_rfcs_encode_clka(uint64_t seq, int64_t clock_ns,
                                bool wall_set, int64_t wall_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* PumpBoundary ([RFCS.22]). */
ds_result_t ds_rfcs_encode_pump(uint64_t seq, int64_t clock_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* RuleFireAnnotation ([RFCS.11]). (timetag, rule_name) is the CallIssued↔RuleFireAnnotation
   join key. */
ds_result_t ds_rfcs_encode_rfra(uint64_t seq, int64_t clock_ns,
                                const char *rule_name, int64_t timetag,
                                bool end,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* CallIssued ([RFCS.15]): the recording view; the wire-only `call_id` is left 0. `args`
 * are sorted by name; a Json argument is canonical JSON text ([LDET.3.2.7]). */
ds_result_t ds_rfcs_encode_call(uint64_t seq, int64_t clock_ns,
                                int64_t timetag, const char *rule_name,
                                const char *service, const char *correlation,
                                const ds_arg_t *args, uint32_t arg_count,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* The four fault atoms, compare-class and stream-only. Each payload carries what its class
 * can know, so the class picks the encoder: TypeError and EngineError carry no activation
 * identity. */

/* ComputationError ([LERR.1.4.9]). No `recoverable` parameter: the encoder writes the
 * constant, the same across every TrapKind. */
ds_result_t ds_rfcs_encode_eerr(uint64_t seq, uint64_t clock_ns,
                                uint32_t trap_kind, const char *rule_name,
                                int64_t timetag, const char *schema_name,
                                const char *slot_name, uint64_t fact_id,
                                uint32_t node_id,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* TypeError. `actual` is the tag the value had; `expected` derives from `node_id`.
 * `rule_name` is the fault's rule name ([LERR.9.11]). */
ds_result_t ds_rfcs_encode_type(uint64_t seq, uint64_t clock_ns,
                                uint32_t node_id, const char *schema_name,
                                const char *slot_name, const char *actual,
                                const char *rule_name,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* BoundsError. `rule_name` and `timetag` are the activation context where one exists: an
 * `intern_cap` breach during load has none, and zero is not a valid timetag. */
ds_result_t ds_rfcs_encode_bnds(uint64_t seq, uint64_t clock_ns,
                                uint32_t cap, uint64_t limit, uint64_t observed,
                                const char *rule_name, int64_t timetag,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* EngineError. `node_id` is 0 for a fault with no node site, whose `rule_name` is `$engine`
 * ([LERR.9.11]). */
ds_result_t ds_rfcs_encode_engf(uint64_t seq, uint64_t clock_ns,
                                uint32_t fault, uint32_t node_id,
                                const char *rule_name,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* Decoders parse one atom body, the bytes after the frame header. DS_ERR_PARSE on a
 * malformed body. */

typedef struct ds_rfcs_header {
    /* [LDET.1.10]: a reader accepts iff this begins with its own `<major>.<minor>.`
       (../version_series.h). */
    char     ds_version[64];
    /* [RFCS.4.3]: as recorded, so a replay reproduces every `event_id`. */
    ds_rfcs_str_t session_id;
    ds_rfcs_str_t tier_id;
    uint8_t  dsc_hash[32];
    size_t   dsc_hash_len; /* 0 or 32 */
    /* [RBND.1.3]: capabilities that are not strictly ascending over Capability's members,
       or more than DS_BINDING_CAPABILITIES_MAX of them, are DS_ERR_PARSE. */
    uint32_t capabilities[64];
    size_t   n_capabilities;
    uint8_t  dialect_def_sha256[32];
    size_t   dialect_def_sha256_len; /* as written; only the first 32 kept */
} ds_rfcs_header_t;
ds_result_t ds_rfcs_decode_header(const uint8_t *body, size_t body_len,
                                  ds_rfcs_header_t *out);

typedef struct ds_rfcs_clka {
    uint64_t seq;
    int64_t  clock_ns;   /* the monotonic sample ([LTIM.2.8.2]) */
    bool     has_wall;   /* the wall clock had a value ([RFCS.10.1]) */
    int64_t  wall_ns;    /* the wall sample, UTC ns ([LTIM.2.8.3]); 0 when
                            !has_wall */
} ds_rfcs_clka_t;
ds_result_t ds_rfcs_decode_clka(const uint8_t *body, size_t body_len,
                                ds_rfcs_clka_t *out);

typedef struct ds_rfcs_rfra {
    uint64_t seq;
    int64_t  clock_ns;
    char     rule_name[128];
    int64_t  timetag;      /* fire identity; (timetag, rule_name) joins to CallIssued */
    bool     end;
} ds_rfcs_rfra_t;
ds_result_t ds_rfcs_decode_rfra(const uint8_t *body, size_t body_len,
                                ds_rfcs_rfra_t *out);

/* The fact body ([RFCS.6.3]): a proto3 message typed per the schema, slot field numbers 1..N
 * in declaration order. Json travels as canonical ds_json_serialize text. A fact-ref slot
 * is a `uint64` handle that means nothing outside its stream ([RFCS.4]). */

ds_result_t ds_rfcs_encode_fact_body(const ds_fact_t *fact,
                                     uint8_t *out, size_t out_cap, size_t *out_len);

/* Into per-slot values in declaration order; *out_n is the slot count. A schema with a
   fact-ref slot is DS_ERR_INVAL: this call has no handle map. An absent field takes its
   proto3 default. String values are copied NUL-terminated into `scratch`, sized at least
   body_len + slot count; Bytes values are views into `body`. Text that is not well-formed
   UTF-8 is DS_ERR_PARSE.

   Json values are owned trees, each for the caller to ds_json_free. An absent non-nullable
   Json field is DS_ERR_PARSE; a document `null` at its root is DS_SLOT_NULL in a nullable
   slot and DS_ERR_PARSE otherwise ([RFCS.6.3]). A failed decode leaks nothing. */
ds_result_t ds_rfcs_decode_fact_body(const ds_schema_t *schema,
                                     const uint8_t *body, size_t body_len,
                                     ds_slot_value_t *values, uint32_t values_cap,
                                     char *scratch, size_t scratch_cap,
                                     uint32_t *out_n);

/* A reader's map from a recorded handle to the fact it names (RFCS.6.3): sets
   *out to that fact, or returns DS_ERR_PARSE when no earlier record of the
   stream gave a fact that handle. *out may be NULL with DS_OK when the fact
   was recorded and has since left working memory. */
typedef ds_result_t (*ds_rfcs_handle_fn)(void *user, uint64_t handle,
                                         ds_fact_t **out);

/* ds_rfcs_decode_fact_body, with a fact-ref slot's handle resolved through
   `resolve` to the DS_SLOT_FACT_REF value ds_engine_assert takes (`v.ref`).
   An absent nullable fact-ref field is `null`; a handle `resolve` refuses
   fails the decode with its status, freeing any Json already decoded. With
   `resolve` NULL this is ds_rfcs_decode_fact_body. */
ds_result_t ds_rfcs_decode_fact_body_resolving(const ds_schema_t *schema,
                                               const uint8_t *body,
                                               size_t body_len,
                                               ds_slot_value_t *values,
                                               uint32_t values_cap,
                                               char *scratch, size_t scratch_cap,
                                               ds_rfcs_handle_fn resolve,
                                               void *resolve_user,
                                               uint32_t *out_n);

/* A `Slot` atom's fields ([RFCS.5.1]). `kind` is a `SlotKind` number as written. `nullable`
   decides whether an absent field is `null` or the type's zero ([RFCS.6.3]). */
typedef struct {
    const char *name;
    uint32_t    kind;
    bool        nullable;
    const char *schema_ref;
} ds_rfcs_announced_slot_t;

/* ds_rfcs_decode_fact_body, typed by the stream's own `Slot` atoms ([RFCS.5.1]), for a reader
   that holds no program. A fact-ref slot, or a `kind` that is SLOT_KIND_UNSPECIFIED or no
   `SlotKind` member, is DS_ERR_INVAL. */
ds_result_t ds_rfcs_decode_announced_fact_body(
    const ds_rfcs_announced_slot_t *slots, uint32_t n_slots,
    const uint8_t *body, size_t body_len,
    ds_slot_value_t *values, uint32_t values_cap,
    char *scratch, size_t scratch_cap, uint32_t *out_n);

/* ds_rfcs_decode_announced_fact_body, with a fact-ref slot decoded to its handle as
   recorded, for a reader with no working memory.

   `handles` has `values_cap` entries. On success, for each slot i:
   - a fact-ref slot whose field is present: values[i].kind is
     DS_SLOT_FACT_REF with v.ref NULL (no fact is resolved), and handles[i] is
     the recorded handle, never 0. [RFCS.6.3]: the handle is the `fact_id` of
     the earlier record in the same stream that carries the referenced fact
     (a FactAssert or FactEmit), or one an ExternalAssert's `fact_ids` lists.
     It names nothing outside that stream ([RFCS.4]).
   - a nullable fact-ref slot whose field is absent: values[i].kind is
     DS_SLOT_NULL and handles[i] is 0.
   - any other slot: values[i] is as ds_rfcs_decode_announced_fact_body gives
     it, and handles[i] is 0.

   The refusals are the resolving decode's: a handle of 0, or an absent
   non-nullable fact-ref field, is DS_ERR_PARSE. Whether an earlier record
   gave the handle is not checked here: the call holds no stream, and the
   caller's own index of records answers it. On an error return `values` and
   `handles` are unspecified, and no Json is left allocated. */
ds_result_t ds_rfcs_decode_announced_fact_body_handles(
    const ds_rfcs_announced_slot_t *slots, uint32_t n_slots,
    const uint8_t *body, size_t body_len,
    ds_slot_value_t *values, uint64_t *handles, uint32_t values_cap,
    char *scratch, size_t scratch_cap, uint32_t *out_n);

/* [LFST.5.6], [RARC.5.8.8]: a UUID-shaped derivation of (run_id, tier_id, seq), over SHA-256,
 * so it reproduces on replay. NULL and "" derive alike. A downstream tier echoes it
 * ([NCBK.10]). */
#define DS_RFCS_EVENT_ID_LEN 37   /* 36 hex/dashes + NUL */
void ds_rfcs_gen_event_id(const char *run_id, const char *tier_id,
                          uint64_t seq, char out[DS_RFCS_EVENT_ID_LEN]);

/* FactAssert, around an already-encoded fact body. `event_id` "" or NULL leaves it absent.
   `ttl_ns` is the fact's window, not its deadline ([RFCS.7.4]); 0 means the schema's
   default. */
ds_result_t ds_rfcs_encode_fcem(uint64_t fact_id, const char *schema_name,
                                const uint8_t *fact_body, size_t fact_body_len,
                                uint64_t ttl_ns,
                                uint64_t clock_ns, uint64_t seq,
                                const char *event_id,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* FactRetract, the integrator's retraction ([RFCS.7.1]). */
ds_result_t ds_rfcs_encode_fcrt(uint64_t fact_id, uint64_t seq,
                                uint64_t clock_ns,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* SchemaDef ([RFCS.5.1]), with no `proto_source`. A replay refuses a FactAssert no SchemaDef
   announced ([RFCS.5.4]), so a stream built by hand announces with this. DS_ERR_INVAL for a
   NULL or empty name. */
ds_result_t ds_rfcs_encode_schema_def(const char *schema_name,
                                      uint8_t *out, size_t out_cap,
                                      size_t *out_len);

/* FactEmit, a fact a rule's `emit` produced ([RFCS.6a]). `rule_name` is never "". A `publish`
   is FactPublish's (ds_rfcs_encode_fpub). Compare-class ([RFCS.3.4]): never delivered to the
   engine as an input. */
ds_result_t ds_rfcs_encode_femt(uint64_t fact_id, const char *schema_name,
                                const uint8_t *fact_body, size_t fact_body_len,
                                uint64_t ttl_ns,
                                const char *rule_name,
                                uint64_t clock_ns, uint64_t seq,
                                const char *event_id,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* Frame a complete FactPublish atom ([RFCS.27.1]): a rule's `publish` ran. The
   schema it named, the rule (NEVER ""), the action's clock and seq, and the
   firing's timetag. No slot value and no fact handle: the fact entered no
   working memory ([LTIE.4.3]).

   COMPARE-CLASS ([RFCS.27.2]): re-derived by firing the same rule and compared,
   never delivered to the engine. */
ds_result_t ds_rfcs_encode_fpub(const char *schema_name, const char *rule_name,
                                uint64_t clock_ns, uint64_t seq,
                                int64_t timetag,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* `fact`, `schema_name` and `event_id` are views into the decoded `body`. */
typedef struct ds_rfcs_fcem {
    uint64_t       fact_id;
    ds_rfcs_str_t  schema_name;
    const uint8_t *fact;
    size_t         fact_len;
    uint64_t       ttl_ns;  /* TTL window; 0 = schema default (and LOGICAL) */
    uint64_t       clock_ns;
    uint64_t       seq;
    ds_rfcs_str_t  event_id; /* "" if absent */
} ds_rfcs_fcem_t;
ds_result_t ds_rfcs_decode_fcem(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcem_t *out);
/* The two messages share their envelope fields at the same numbers. */
ds_result_t ds_rfcs_decode_femt(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcem_t *out);
typedef struct ds_rfcs_fcrt {
    uint64_t fact_id;
    uint64_t seq;
    uint64_t clock_ns;
} ds_rfcs_fcrt_t;
ds_result_t ds_rfcs_decode_fcrt(const uint8_t *body, size_t body_len,
                                ds_rfcs_fcrt_t *out);

/* FactWithdraw.Cause ([RFCS.7a.2]), as plain integers so working memory can carry one without
   the generated protobuf header. 4 is reserved. */
#define DS_FWTH_CAUSE_UNSPECIFIED      0u
#define DS_FWTH_CAUSE_JUSTIFIER_ENDED  1u
#define DS_FWTH_CAUSE_TTL_EXPIRED      2u
#define DS_FWTH_CAUSE_SUPERSEDED       3u
#define DS_FWTH_CAUSE_SYNTHETIC_DISCHARGED 5u
#define DS_FWTH_CAUSE_AUTHOR_WITHDRAWN 6u
#define DS_FWTH_CAUSE_ACTIVATION_COMPLETED 7u

/* FactWithdraw, the engine taking back a fact. `cause` must not be UNSPECIFIED. Compare-class
   ([RFCS.3.4]). */
ds_result_t ds_rfcs_encode_fwth(uint64_t fact_id, uint32_t cause,
                                uint64_t clock_ns, uint64_t seq,
                                uint8_t *out, size_t out_cap, size_t *out_len);

/* `cause` is the number on the wire, whether the enum holds it or not ([RFCS.7a.2]). */
typedef struct ds_rfcs_fwth {
    uint64_t fact_id;
    uint32_t cause;
    uint64_t clock_ns;
    uint64_t seq;
} ds_rfcs_fwth_t;
ds_result_t ds_rfcs_decode_fwth(const uint8_t *body, size_t body_len,
                                ds_rfcs_fwth_t *out);

/* Byte sink: receives each framed RFCS atom (or the header). Return non-OK to
   signal the recorder to remember the failure. */
typedef ds_result_t (*ds_rfcs_sink_fn)(const uint8_t *bytes, size_t len,
                                       void *user);

/* Caller-owned, and must outlive recording. `buf` is the scratch each atom is assembled in.
   `last` holds the first error from an encode or sink call. Each failure is also the status
   of the libds call that fired the event ([NCBK.1.5]), and recording continues: the lost
   event is a `seq` gap ([RFCS.21.1]). */
typedef struct ds_rfcs_recorder {
    ds_rfcs_sink_fn sink;
    void           *sink_user;
    uint8_t        *buf;
    size_t          buf_cap;
    ds_result_t     last;
    /* [RFCS.24]: the delivery this recorder holds atoms for, during one event of it. */
    void           *hold;
    /* [RFCS.5.1]: the header and the schema prelude wait for the first event, when the
       schema set is final ([NFCT.1.1]). */
    bool            prelude_pending;
} ds_rfcs_recorder_t;

/*
 * Registers a stream callback that frames every later event to `sink`. Call
 * ds_engine_set_stream_callback(engine, NULL, NULL) to stop. `rec` and `buf` must stay
 * valid until then.
 *
 * FactAssert and FactEmit partition the facts: a rule-emitted fact fires FACT_ASSERT and then
 * ACTION_EMIT, and only the second is recorded. A host input whose fact holds a reference is
 * one ExternalAssert ([RFCS.24]).
 */
ds_result_t ds_rfcs_record_to(ds_engine_t *engine, ds_rfcs_recorder_t *rec,
                              ds_rfcs_sink_fn sink, void *sink_user,
                              uint8_t *buf, size_t buf_cap);

/*
 * Recording beside a stream callback of the caller's own: ds_rfcs_record_to is exactly
 * ds_rfcs_record_begin, which installs nothing, followed by installing a callback that
 * calls ds_rfcs_recorder_on_event.
 *
 * Call ds_rfcs_recorder_on_event from inside the stream callback, with the `engine` and `ev`
 * it received: the recorder reads engine state only current during dispatch. Return its
 * result from the callback, after the caller's own work, so the engine reports a lost atom.
 */
ds_result_t ds_rfcs_record_begin(ds_engine_t *engine, ds_rfcs_recorder_t *rec,
                                 ds_rfcs_sink_fn sink, void *sink_user,
                                 uint8_t *buf, size_t buf_cap);
ds_result_t ds_rfcs_recorder_on_event(ds_engine_t *engine,
                                      const ds_stream_ev_t *ev,
                                      ds_rfcs_recorder_t *rec);

/* The one replay operation ([LFST.9.6]): deliver each inject-class atom, pump to quiescence
 * after it, and byte-compare each re-derived compare-class atom ([LFST.9.3.1]).
 *
 *   StreamHeader  verify the stream header against the engine's session header:
 *         the version, and, when both sides carry a DSC hash, the whole
 *         dialect-binding tuple through ds_binding_compare_dialect
 *         ([RBND.5.1]).
 *   FactAssert  ds_engine_schema_find(schema_name) + decode the typed fact body +
 *         ds_engine_assert, then pump. The recorded fact_id is remapped to
 *         the new engine-assigned fact so a later FactRetract resolves.
 *   ExternalAssert  deliver the FactExternal as ds_engine_assert_external does, as one
 *         input, with `ttl_ns` on the received fact, and bind each recorded
 *         handle in `fact_ids` to the fact the delivery asserted in its
 *         place. A refused delivery, or another number of facts, is
 *         DS_ERR_FS_DIVERGENCE ([RFCS.24.2]).
 *   FactRetract  ds_engine_retract the fact the matching FactAssert asserted, then pump.
 *   ClockAdvance  switch to mock clock (once), ds_engine_clock_set, then pump.
 *   RuleFireAnnotation / CallIssued / FactEmit  never injected — re-derived by the pumps and
 *         byte-compared against the recorded atom; a mismatch, or a
 *         re-derived atom with no recorded twin, is DS_ERR_FS_DIVERGENCE.
 *   SchemaDef / Slot are skipped (counted in `skipped`).
 *   A field number with no registry entry is DS_ERR_PARSE ([RFCS.19.3]).
 *
 * Neither `stream` nor `strbuf` needs to outlive the call: the engine keeps interned copies.
 *
 * `strbuf` is the arena decoded String slots are bump-allocated into across the whole stream;
 * size it to at least 2*len. A fact over DS_RFCS_REPLAY_MAX_SLOTS slots, or exhausting
 * `strbuf`, yields DS_ERR_INVAL.
 */

#define DS_RFCS_REPLAY_MAX_SLOTS 256u

typedef struct ds_rfcs_replay_result {
    uint64_t asserts;        /* FactAssert atoms delivered, one a bound refused
                                again included, FactEmit atoms matched, and each
                                fact an ExternalAssert asserted */
    uint64_t retracts;       /* FactRetract atoms applied */
    uint64_t clocks;         /* ClockAdvance atoms applied */
    uint64_t rule_fires;     /* RuleFireAnnotation atoms matched (compare atom; not applied — [LFST.9.3.1]) */
    uint64_t calls;          /* CallIssued atoms matched (compare atom; not applied — [RFCS.15.4]) */
    uint64_t withdrawals;    /* FactWithdraw atoms matched (compare atom; not applied — [RFCS.7a.3]) */
    uint64_t publishes;      /* FactPublish atoms matched (compare atom; not applied — [RFCS.27.2]) */
    uint64_t skipped;        /* atoms carrying nothing to apply or compare:
                                announcements and a BoundsError
                                on pump_wcet_ns ([LFST.9.2.1]) */
    bool     header_verified; /* a StreamHeader header matched the engine session header */
    uint64_t tail_bytes;     /* bytes of a partial trailing atom left unapplied:
                                the stream is in progress or was cut off
                                ([RFCS.19.2]); 0 when it ended on an atom
                                boundary. Only ds_rfcs_replay_finish reports a
                                nonzero value; the whole-buffer forms refuse a
                                partial tail instead. */
} ds_rfcs_replay_result_t;

/*
 * `out` may be NULL. A StreamHeader that disagrees with the loaded DSC is
 * DS_ERR_BND_DSC_MISMATCH or DS_ERR_BND_DIALECT_MISMATCH ([RBND.5.2]), and one carrying only
 * one of dsc_hash and dialect_def_sha256 is DS_ERR_BND_INCOMPLETE ([RBND.2.1]); each applies
 * nothing past the header. Other errors abort mid-stream, a stream ending mid-atom among them
 * as DS_ERR_PARSE ([RFCS.19.2]); atoms applied before the failure are reflected in *out.
 */
ds_result_t ds_rfcs_replay(ds_engine_t *engine,
                           const uint8_t *stream, size_t len,
                           uint8_t *strbuf, size_t strbuf_cap,
                           ds_rfcs_replay_result_t *out);

/* Chunked replay: applies each atom as it completes, with a reader's resident set of
 * O(max_atom_bytes). Working memory is not bounded by this.
 *
 * Errors are sticky: once a feed fails, the ctx refuses further work and returns the same
 * result. Atoms applied before the failure stay applied. */

typedef struct ds_rfcs_replay_opts {
    /* Largest single atom accepted; 0 selects the default. An atom declaring more is
     * DS_ERR_PARSE before anything is allocated for it. */
    uint32_t max_atom_bytes;
} ds_rfcs_replay_opts_t;

typedef struct ds_rfcs_replay_ctx ds_rfcs_replay_ctx_t;

/* `opts` may be NULL. Until ds_rfcs_replay_finish the engine invokes no effect callback
 * ([NDET.8.2]), and a call with none registered is not DS_ERR_STORAGE_UNAVAILABLE
 * ([IDSP.6.4]). */
ds_result_t ds_rfcs_replay_begin(ds_engine_t *engine,
                                 const ds_rfcs_replay_opts_t *opts,
                                 ds_rfcs_replay_ctx_t **out_ctx);

/* Boundaries are arbitrary. */
ds_result_t ds_rfcs_replay_feed(ds_rfcs_replay_ctx_t *ctx,
                                const uint8_t *chunk, size_t len);

/* Always destroys the ctx. `out` may be NULL. A trailing partial atom is end of stream, not an
 * error ([RFCS.19.2], [RFCS.19.8]); its length is reported in `tail_bytes`. */
ds_result_t ds_rfcs_replay_finish(ds_rfcs_replay_ctx_t *ctx,
                                  ds_rfcs_replay_result_t *out);

/*
 * One recorded ExternalAssert, as ds_rfcs_replay applies it ([RFCS.24.2]), for a reader that
 * steps through a recording one record at a time. It samples the clocks as a host's call does,
 * so the caller sets them from the ClockAdvance before it. It does not pump. Effect callbacks
 * are the caller's.
 *
 * On DS_OK, `*out_n` facts were asserted, and for each i < *out_n
 * `out_fact_ids[i]` is this engine's id for the fact (ds_fact_get_id,
 * ds_engine_fact_find) the recording names `out_recorded_ids[i]`, in [RFCS.24.3]'s order.
 *
 * DS_ERR_FS_DIVERGENCE  the delivery was refused, or asserted a different
 *                       number of facts than `fact_ids` lists ([RFCS.24.2]):
 *                       the run is not reproduced. A halt the delivery itself
 *                       raises is the recorded run's own, and is DS_OK, as in
 *                       ds_rfcs_replay. *out_n is 0.
 * DS_ERR_PARSE          `body` is not an ExternalAssert. Nothing is applied.
 * DS_ERR_INVAL          NULL engine, out_n, or body with len > 0; NULL id
 *                       arrays with cap > 0; or `fact_ids` longer than `cap`,
 *                       in which case *out_n is the length needed. Nothing is
 *                       applied.
 * DS_ERR_STATE / DS_ERR_ENGINE_HALTED  called from a callback on `engine`, or
 *                       on a halted engine ([RARC.13.16], [NCBK.2.9]).
 *                       Nothing is applied.
 */
ds_result_t ds_rfcs_apply_external_assert(ds_engine_t   *engine,
                                          const uint8_t *body, size_t len,
                                          uint64_t      *out_fact_ids,
                                          uint64_t      *out_recorded_ids,
                                          size_t         cap,
                                          size_t        *out_n);

typedef struct ds_rfcs_reader {
    const uint8_t *stream; /* not owned */
    size_t         len;
    size_t         pos;
} ds_rfcs_reader_t;

void ds_rfcs_reader_init(ds_rfcs_reader_t *r, const uint8_t *stream, size_t len);

/*
 * On a successful read: *out_done = false, *out_atom is the atom's field
 * number, always an allocated one, *out_body points INTO the stream (not owned,
 * valid while the stream is), *out_body_len is the body length.
 *
 * At end of stream: *out_done = true (the other out-params are untouched).
 *
 * Errors: DS_ERR_PARSE on a truncated atom header or body, or on a field
 * number with no registry entry ([RFCS.19.3]); DS_ERR_INVAL on NULL args.
 */
ds_result_t ds_rfcs_next(ds_rfcs_reader_t *r,
                         uint32_t *out_atom,
                         const uint8_t **out_body, size_t *out_body_len,
                         bool *out_done);

/*
 * For a stream that may still be growing: a partial trailing atom is
 * DS_RFCS_STEP_INCOMPLETE, and `r->pos` is where it starts, for ds_rfcs_reader_extend.
 *
 * Only bytes no append can repair are an error: a complete frame that is not a valid atom, or a
 * field number with no registry entry. `r->pos` is then the offending atom's first byte.
 *
 * On DS_RFCS_STEP_ATOM the out-params are as for ds_rfcs_next; otherwise they are untouched.
 */
typedef enum {
    DS_RFCS_STEP_ATOM       = 0,   /* an atom was produced */
    DS_RFCS_STEP_END        = 1,   /* the buffer ends on an atom boundary */
    DS_RFCS_STEP_INCOMPLETE = 2    /* a partial atom starts at r->pos */
} ds_rfcs_step_t;

ds_result_t ds_rfcs_next_incremental(ds_rfcs_reader_t *r,
                                     uint32_t *out_atom,
                                     const uint8_t **out_body,
                                     size_t *out_body_len,
                                     ds_rfcs_step_t *out_step);

/*
 * Point the reader at a longer copy of the same stream, keeping its position.
 * `stream[0..len)` must begin with the bytes already read
 * (it may live at a new address, as after a realloc). DS_ERR_INVAL if `len`
 * is shorter than the position already reached.
 */
ds_result_t ds_rfcs_reader_extend(ds_rfcs_reader_t *r,
                                  const uint8_t *stream, size_t len);

/* The proto message an atom's body parses as: "FactAssert" for DS_ATOM_FACT_ASSERT. NULL for a
 * field number with no entry; the string is static. */
const char *ds_rfcs_message_name(uint32_t atom);

/* The generic atom reader: every registered atom's body, decoded field by field.
 *
 * The visitor is called once per field in declaration order, wrapped in ENTER and LEAVE for each
 * message; a repeated field calls it once per element. Every scalar, string and bytes field is
 * visited, proto3 defaults included; a message field only when present; of a oneof, only the
 * member that is set.
 *
 * Strings and bytes are borrowed for the visitor call. A fact body is visited as bytes:
 * `ds_rfcs_decode_fact_body` decodes it. */

typedef enum {
    DS_RFCS_FIELD_INT    = 0,   /* int32 sint32 sfixed32 int64 sint64 sfixed64 -> v.i */
    DS_RFCS_FIELD_UINT   = 1,   /* uint32 fixed32 uint64 fixed64 -> v.u */
    DS_RFCS_FIELD_DOUBLE = 2,   /* float double -> v.d */
    DS_RFCS_FIELD_BOOL   = 3,   /* -> v.b */
    DS_RFCS_FIELD_ENUM   = 4,   /* -> v.e.number, v.e.name (NULL: no name) */
    DS_RFCS_FIELD_STRING = 5,   /* -> v.s, UTF-8, borrowed */
    DS_RFCS_FIELD_BYTES  = 6,   /* -> v.s, borrowed */
    DS_RFCS_FIELD_ENTER  = 7,   /* a message begins; `message` names its type */
    DS_RFCS_FIELD_LEAVE  = 8    /* the message ENTERed last ends */
} ds_rfcs_field_kind_t;

typedef struct ds_rfcs_field {
    ds_rfcs_field_kind_t kind;
    const char *name;      /* the field's name; NULL for the atom's own ENTER/LEAVE */
    uint32_t    number;    /* the field's number; 0 for the atom's own ENTER/LEAVE */
    int32_t     index;     /* element index in a repeated field, else -1 */
    uint32_t    depth;     /* 0 for the atom's own message, +1 per nesting */
    const char *message;   /* ENTER / LEAVE: the message type's name */
    union {
        int64_t  i;
        uint64_t u;
        double   d;
        bool     b;
        struct { int32_t number; const char *name; } e;
        struct { const uint8_t *p; size_t len; } s;
    } v;
} ds_rfcs_field_t;

/* Return false to stop the walk; ds_rfcs_visit_atom then returns DS_OK. */
typedef bool (*ds_rfcs_field_fn)(void *ctx, const ds_rfcs_field_t *field);

/*
 * Visit `body[0..len)` as the message field number `atom` carries.
 *
 * DS_ERR_NOT_FOUND  the field number has no registry entry
 * DS_ERR_PARSE      the body does not unpack as that message, or nests deeper than
 *                   DS_RFCS_VISIT_MAX_DEPTH ([RDSC.9.9])
 * DS_ERR_INVAL      NULL fn, or NULL body with len > 0
 *
 * The bound admits every artefact [RDSC.11.3] admits. A SlotAssign's `Expr` is at
 * depth 3 in its TerminalNode, each of the 48 levels below it can cost four
 * messages (Expr, InterpExpr, FormatPrim, ValuePrim), and the deepest `Expr` can
 * hold four more (InterpExpr, FormatPrim, TimePrim, TimeItem): 3 + 4 * 48 + 4.
 */
#define DS_RFCS_VISIT_MAX_DEPTH 199u

ds_result_t ds_rfcs_visit_atom(uint32_t atom,
                               const uint8_t *body, size_t len,
                               ds_rfcs_field_fn fn, void *ctx);

/*
 * A field the message's descriptor does not name: a field number this build
 * has no field for, which protobuf-c keeps as unknown bytes. `depth` and
 * `message` are those of the message it is in, as its ENTER gave them; `wire`
 * is its wire type, and `p`/`len` the bytes after its tag as protobuf-c keeps
 * them (a length-delimited field's include its length prefix), BORROWED for
 * the call only.
 */
typedef struct ds_rfcs_unknown_field {
    uint32_t       number;
    uint32_t       wire;
    uint32_t       depth;
    const char    *message;
    const uint8_t *p;
    size_t         len;
} ds_rfcs_unknown_field_t;

/* Return false to stop the walk, as for ds_rfcs_field_fn. */
typedef bool (*ds_rfcs_unknown_fn)(void *ctx, const ds_rfcs_unknown_field_t *field);

/*
 * ds_rfcs_visit_atom, with an arm for the fields the descriptors do not name ([RTIM.14.9]).
 * `on_unknown` is called once per such field, after its message's last known field and before
 * its LEAVE, at every depth; NULL reports none.
 */
ds_result_t ds_rfcs_visit_atom_with_unknown(uint32_t atom,
                                            const uint8_t *body, size_t len,
                                            ds_rfcs_field_fn fn,
                                            ds_rfcs_unknown_fn on_unknown,
                                            void *ctx);

#endif /* DS_LIBDS_RFCS_H */

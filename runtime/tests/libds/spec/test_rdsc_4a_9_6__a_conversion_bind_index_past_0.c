/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * @spec [RDSC.4a.9.6]
 * @spec [NFCT.1.4.6]
 * A slot's conversion has a frame of one slot, so a `bind_ref` past 0 in it
 * names nothing. The artefact loads ([RDSC.4a.9.6]: a loader must not refuse
 * it), and the conversion that reads it raises ENGINE_FAULT_ARTEFACT_LIED.
 * The host's conversion raises that EngineError as any public call raises
 * one ([NFCT.1.4.6]): one DS_EV_ENGINE_ERROR, the engine halted, and
 * DS_ERR_ENGINE_HALTED, with *out unwritten. A second call meets the halt.
 *
 * THE NEGATIVE FIXTURE, built on every run: `Reading.span`, a `millisecond`
 * slot, compiled, then each `bind_ref` 0 in its Slot atom's `to_stored` and
 * `from_stored` (proto/slot.proto fields 13 and 14) set to 1, and the
 * artefact resealed (spec_tamper.h's `reseal`, [RDSC.3.6]). A `bind_ref` is
 * `Expr` field 14, a varint (proto/rete_expr.proto), which the compiler
 * writes even at 0: bytes 0x70 0x00, made 0x70 0x01, so no length moves. The
 * conversions are integer arithmetic on literals, with no string, bytes or
 * fixed-width field in which those two bytes could stand for anything else.
 *
 * THE PATH ([STYL.5.10.8]): dsc/loader.c handle_slot and rete_loader.c
 * ds_dsc_slot_conversion keep the index; engine_rete_adapters.c
 * nfct_1_4_6_convert evaluates the conversion with a frame of one, eval.c's
 * BIND_REF arm faults DS_FAULT_ARTEFACT, held, and the call raises it.
 *
 *   unedited. The same program, not edited: each conversion answers DS_OK,
 *      so the halt below is the edit's.
 *   (a) to_stored on the edited slot: the load is DS_OK; the call returns
 *       DS_ERR_ENGINE_HALTED; exactly one DS_EV_ENGINE_ERROR, its fault
 *       ARTEFACT_LIED, node 0 and rule `$engine` ([LERR.9.11]); *out
 *       unwritten; ds_engine_halted reports ARTEFACT_LIED. Again: the
 *       halt's DS_ERR_ENGINE_HALTED, and no second event.
 *   (b) from_stored, on a fresh engine from the same fixture: the same.
 *
 * The Mercury runtime's test_ds `test_rdsc_4a_9_6_conversion` asks the same
 * of ds.engine.nfct_1_4_6_convert.
 */
#include "spec_common.h"
#include "spec_tamper.h"

#include <stdbool.h>

static const char *PROGRAM =
    "schema Reading scope logical:\n"
    "    id: String key\n"
    "    span: millisecond mutable\n";

enum { S_ID, S_SPAN };

/* A protobuf body's length-delimited field `field`: its start and length.
   false when it is absent or the body does not walk. */
static bool field_bytes(const uint8_t *b, size_t n, uint64_t field,
                        size_t *at, size_t *len)
{
    size_t pos = 0;
    while (pos < n) {
        uint64_t key = 0, v = 0;
        if (!varint(b, n, &pos, &key)) return false;
        const uint64_t wire = key & 7u;
        if (wire == 0) {
            if (!varint(b, n, &pos, &v)) return false;
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 5) {
            pos += 4;
        } else if (wire == 2) {
            if (!varint(b, n, &pos, &v) || v > n - pos) return false;
            if ((key >> 3) == field) {
                *at = pos;
                *len = (size_t) v;
                return true;
            }
            pos += (size_t) v;
        } else {
            return false;
        }
    }
    return false;
}

static bool field_is(const uint8_t *b, size_t n, uint64_t field,
                     const char *want)
{
    size_t at = 0, len = 0;
    return field_bytes(b, n, field, &at, &len) && len == strlen(want)
        && memcmp(b + at, want, len) == 0;
}

/* Every `bind_ref` 0 in b[at..at+len) made 1; how many. */
static int past_the_frame(uint8_t *b, size_t at, size_t len)
{
    int made = 0;
    for (size_t i = at; i + 1 < at + len; i++)
        if (b[i] == 0x70u && b[i + 1] == 0x00u) {
            b[i + 1] = 0x01u;
            made++;
        }
    return made;
}

/* The negative fixture: `dsc` with `Reading.span`'s conversions reading
   `bind_ref` 1, resealed. 0; 1 when the Slot atom is not found exactly once
   or either conversion reads no `bind_ref` 0. */
static int read_past_the_frame(uint8_t *dsc, size_t n)
{
    int found = 0, to = 0, from = 0;
    size_t pos = 0;
    while (pos < n) {
        uint64_t v = 0;
        if (dsc[pos++] != 0x0au || !varint(dsc, n, &pos, &v) || v > n - pos)
            break;
        const size_t end = pos + (size_t) v;
        size_t in = pos;
        uint64_t tag = 0, body_len = 0;
        if (varint(dsc, end, &in, &tag) && (tag & 7u) == 2u
            && varint(dsc, end, &in, &body_len) && body_len <= end - in) {
            uint8_t *body = dsc + in;
            const size_t blen = (size_t) body_len;
            size_t to_at = 0, to_len = 0, from_at = 0, from_len = 0;
            if (field_is(body, blen, 1, "Reading")
                && field_is(body, blen, 2, "span")
                && field_bytes(body, blen, 13, &to_at, &to_len)
                && field_bytes(body, blen, 14, &from_at, &from_len)) {
                found++;
                to += past_the_frame(body, to_at, to_len);
                from += past_the_frame(body, from_at, from_len);
            }
        }
        pos = end;
    }
    if (found != 1 || to < 1 || from < 1) {
        fprintf(stderr, "FAIL: the fixture: Reading.span's Slot atom found %d "
                "times, want 1; bind_ref 0 made 1 %d times in to_stored and %d "
                "in from_stored, want at least one each\n", found, to, from);
        return 1;
    }
    return reseal(dsc, n);
}

typedef struct {
    int               errors;
    ds_engine_fault_t fault;
    uint32_t          node_id;
    bool              engine_rule;
} seen_t;

static ds_result_t on_event(ds_engine_t *e, const ds_stream_ev_t *ev, void *user)
{
    (void) e;
    seen_t *s = (seen_t *) user;
    if (ev->kind == DS_EV_ENGINE_ERROR) {
        s->errors++;
        s->fault = ev->p.engine_error.fault;
        s->node_id = ev->p.engine_error.node_id;
        s->engine_rule = ev->p.engine_error.rule_name != NULL
            && strcmp(ev->p.engine_error.rule_name, "$engine") == 0;
    }
    return DS_OK_R;
}

/* An engine loaded from the program, edited when `lying`, with `seen` on its
   stream. */
static int load(bool lying, seen_t *seen, ds_engine_t **e,
                const ds_schema_t **reading)
{
    *e = NULL;
    uint8_t *dsc = NULL;
    size_t   len = 0;
    ds_result_t r = spec_compile_ds(PROGRAM, &dsc, &len);
    if (r.status != DS_OK) return spec_fail("compile", r);
    if (lying && read_past_the_frame(dsc, len)) { free(dsc); return 1; }
    r = ds_engine_new(NULL, e);
    if (r.status != DS_OK) { free(dsc); return spec_fail("engine_new", r); }
    r = ds_engine_set_stream_callback(*e, on_event, seen);
    if (r.status != DS_OK) { free(dsc); return spec_fail("stream", r); }
    r = ds_engine_load_dsc(*e, dsc, len);
    free(dsc);
    if (r.status != DS_OK)
        return spec_fail("[RDSC.4a.9.6] a bind index past the conversion's "
                         "frame is not a load refusal", r);
    r = ds_engine_schema_find(*e, "Reading", reading);
    if (r.status != DS_OK || *reading == NULL)
        return spec_fail("find Reading", r);
    return 0;
}

typedef ds_result_t (*convert_fn)(const ds_schema_t *, uint32_t,
                                  const ds_slot_value_t *, ds_slot_value_t *);

static ds_slot_value_t ival(int64_t i)
{
    ds_slot_value_t v;
    memset(&v, 0, sizeof v);
    v.kind = DS_SLOT_INT;
    v.v.i = i;
    return v;
}

static int unedited(void)
{
    seen_t seen;
    memset(&seen, 0, sizeof seen);
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(false, &seen, &e, &s)) return 1;
    ds_slot_value_t in = ival(2), out;
    EXPECT_OK("unedited: to_stored(2) on millisecond",
              ds_schema_slot_to_stored(s, S_SPAN, &in, &out));
    if (out.kind != DS_SLOT_INT || out.v.i != 2000000) {
        fprintf(stderr, "FAIL: unedited: to_stored(2) is %lld, want 2000000\n",
                (long long) out.v.i);
        return 1;
    }
    in = ival(2000000);
    EXPECT_OK("unedited: from_stored(2000000) on millisecond",
              ds_schema_slot_from_stored(s, S_SPAN, &in, &out));
    if (seen.errors != 0) {
        fprintf(stderr, "FAIL: unedited: %d EngineErrors, want none\n",
                seen.errors);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

static int halts(const char *what, convert_fn convert)
{
    seen_t seen;
    memset(&seen, 0, sizeof seen);
    ds_engine_t *e = NULL;
    const ds_schema_t *s = NULL;
    if (load(true, &seen, &e, &s)) return 1;
    ds_slot_value_t in = ival(2), out = ival(-7);
    ds_result_t r = convert(s, S_SPAN, &in, &out);
    EXPECT_STATUS(what, r, DS_ERR_ENGINE_HALTED);
    if (seen.errors != 1 || seen.fault != DS_ENGINE_FAULT_ARTEFACT_LIED
        || seen.node_id != 0 || !seen.engine_rule) {
        fprintf(stderr, "FAIL: %s: %d EngineErrors, the last fault %d node %u "
                "rule %s; want one, ARTEFACT_LIED, node 0, `$engine`\n", what,
                seen.errors, (int) seen.fault, (unsigned) seen.node_id,
                seen.engine_rule ? "$engine" : "other");
        return 1;
    }
    if (out.kind != DS_SLOT_INT || out.v.i != -7) {
        fprintf(stderr, "FAIL: %s wrote *out\n", what);
        return 1;
    }
    bool halted = false;
    ds_engine_fault_t fault = DS_ENGINE_FAULT_UNSPECIFIED;
    EXPECT_OK("ds_engine_halted", ds_engine_halted(e, &halted, &fault));
    if (!halted || fault != DS_ENGINE_FAULT_ARTEFACT_LIED) {
        fprintf(stderr, "FAIL: %s: ds_engine_halted reports %s, fault %d; "
                "want halted, ARTEFACT_LIED\n", what,
                halted ? "halted" : "not halted", (int) fault);
        return 1;
    }
    r = convert(s, S_SPAN, &in, &out);
    EXPECT_STATUS("the call again, on the halted engine", r,
                  DS_ERR_ENGINE_HALTED);
    if (seen.errors != 1) {
        fprintf(stderr, "FAIL: %s again: %d EngineErrors, want still one\n",
                what, seen.errors);
        return 1;
    }
    EXPECT_OK("free", ds_engine_free(e));
    return 0;
}

int main(void)
{
    if (unedited()) return 1;
    if (halts("to_stored reading bind_ref 1", ds_schema_slot_to_stored))
        return 1;
    if (halts("from_stored reading bind_ref 1", ds_schema_slot_from_stored))
        return 1;
    printf("test_rdsc_4a_9_6__a_conversion_bind_index_past_0: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The protobuf-native atom reader (pbf_reader.c), through which loader.c and
 * the RFCS codec read artefacts and streams.
 *
 * `frame()` below builds frames with the reader's own varint logic, so the
 * byte goldens come from specs/conformance/PBF_FRAMING_VECTORS.json, through
 * the generated `pbf_vectors.h`. The `test_vectors_*` group asks what any
 * implementation must do; the rest is this reader's own unit coverage.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pbf_reader.h"
#include "pbf_vectors.h"

static int fails = 0;
static int checks = 0;
/* Set only by `selftest`, which must make the comparators fail on purpose
   without printing a FAIL line that would read as a real one. */
static int quiet = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (!cond) {
        fails++;
        if (!quiet) fprintf(stderr, "FAIL: %s\n", what);
    }
}

static void eq_u(unsigned long got, unsigned long want, const char *what)
{
    checks++;
    if (got != want) {
        fails++;
        if (!quiet) fprintf(stderr, "FAIL: %s — got %lu, want %lu\n",
                            what, got, want);
    }
}

static size_t put_varint(uint8_t *b, size_t i, uint64_t v)
{
    do {
        uint8_t byte = (uint8_t)(v & 0x7Fu);
        v >>= 7;
        b[i++] = (uint8_t)(byte | (v ? 0x80u : 0u));
    } while (v);
    return i;
}

/* One framed atom appended at `i`: outer 0x0A, len, inner tag, len, body. */
static size_t frame(uint8_t *b, size_t i, uint32_t field,
                    const uint8_t *body, size_t n)
{
    uint8_t inner[64];
    size_t  m = put_varint(inner, 0, ((uint64_t)field << 3) | 2u);
    m = put_varint(inner, m, (uint64_t)n);
    /* Empty bodies are framed as `frame(..., NULL, 0)`, and memcpy(dst, NULL,
       0) is undefined (C11 7.24.1p2). */
    if (n) {
        memcpy(inner + m, body, n);
    }
    m += n;

    b[i++] = 0x0A;
    i = put_varint(b, i, (uint64_t)m);
    memcpy(b + i, inner, m);
    return i + m;
}

/*
 * Table-driven over `pbf_vectors.h`, generated from the corpus that the Python
 * harness and any other implementation also read. The corpus is refused at
 * generation time if a row contradicts the clauses or the atom registry, and
 * nothing here builds a frame with `frame()`.
 */

static void test_vectors_encode(void)
{
    size_t i;

    for (i = 0; i < DS_PBF_VEC_ENCODE_COUNT; i++) {
        const ds_pbf_vec_encode_t *v = &ds_pbf_vec_encode[i];
        size_t        total = v->prefix_len + v->body_len;
        uint8_t      *buf   = malloc(total);
        ds_pbf_atom_t a;
        char          what[96];

        snprintf(what, sizeof what, "vec encode/%s", v->name);
        if (buf == NULL) {
            ok(0, what);
            continue;
        }
        memcpy(buf, v->prefix, v->prefix_len);
        if (v->is_fill) {
            memset(buf + v->prefix_len, v->fill, v->body_len);
        } else if (v->body_len > 0) {
            memcpy(buf + v->prefix_len, v->body, v->body_len);
        }

        /* The direction that ships: the reader takes the corpus's own bytes
           apart and gets the row back. */
        ok(ds_pbf_next_atom(buf, total, 0, &a) == DS_PBF_OK, what);
        eq_u(a.field, v->field, what);
        eq_u(a.body_len, v->body_len, what);
        eq_u(a.next, total, what);

        /* The body is handed back IN PLACE — a reader that copied it would
           still pass every length check above. */
        checks++;
        if (a.body_len != v->body_len ||
            (v->body_len > 0 && a.body != buf + v->prefix_len)) {
            fails++;
            if (!quiet) fprintf(stderr, "FAIL: %s — body is not in place\n", what);
        }

        /* [RFCS.16.1] — the row's number is an allocated atom, and it is the
           atom the row names: the registry's message for it is the row's.
           Checked on every row rather than two hand-picked ones. */
        {
            const ds_atom_reg_entry_t *e = ds_pbf_lookup(v->field);
            ok(e != NULL, what);
            ok(e != NULL && strcmp(e->message, v->atom) == 0, what);
        }
        free(buf);
    }
}

static void test_vectors_decode(void)
{
    size_t i;

    for (i = 0; i < DS_PBF_VEC_DECODE_COUNT; i++) {
        const ds_pbf_vec_decode_t *v = &ds_pbf_vec_decode[i];
        size_t        pos = 0, k;
        ds_pbf_atom_t a;
        char          what[96];

        snprintf(what, sizeof what, "vec decode/%s", v->name);

        eq_u((unsigned long)ds_pbf_container_of(v->data, v->len),
             (unsigned long)v->container, what);

        for (k = 0; k < v->atom_count; k++) {
            char step[128];
            snprintf(step, sizeof step, "%s atom %lu", what, (unsigned long)k);
            if (ds_pbf_next_atom(v->data, v->len, pos, &a) != DS_PBF_OK) {
                ok(0, step);
                break;
            }
            checks++;
            eq_u(a.field, v->atoms[k].field, step);
            eq_u(a.body_len, v->atoms[k].body_len, step);
            eq_u(a.next, v->atoms[k].next, step);
            pos = a.next;
        }
        if (k != v->atom_count) {
            continue;                  /* already reported */
        }

        /* The step AFTER the last atom — the whole of [RFCS.19.2]. A reader
           that collapsed truncation into malformed passes every assertion
           above and fails exactly here. */
        {
            char tail[128];
            snprintf(tail, sizeof tail, "%s terminal", what);
            eq_u((unsigned long)ds_pbf_next_atom(v->data, v->len, pos, &a),
                 (unsigned long)v->terminal, tail);
        }
    }
}

static void test_vectors_band(void)
{
    size_t i;

    for (i = 0; i < DS_PBF_VEC_BAND_COUNT; i++) {
        const ds_pbf_vec_band_t *v = &ds_pbf_vec_band[i];
        char what[96];

        snprintf(what, sizeof what, "vec band/%lu", (unsigned long)v->field);
        eq_u((unsigned long)ds_pbf_band(v->field), (unsigned long)v->band, what);
        ok((ds_pbf_lookup(v->field) != NULL) == (v->known != 0), what);
        eq_u((unsigned long)ds_pbf_disposition(v->field),
             (unsigned long)v->disposition, what);
    }
}

static void test_rfcs_19_1__two_level_framing(void)
{
    uint8_t buf[64];
    static const uint8_t body[] = { 0x08, 0x2A };
    size_t n = frame(buf, 0, DS_ATOM_DSC_HEADER, body, sizeof body);
    size_t total;
    ds_pbf_atom_t a;

    total = frame(buf, n, DS_ATOM_SCHEMA_DEF, NULL, 0);

    ok(ds_pbf_next_atom(buf, total, 0, &a) == DS_PBF_OK, "first atom");
    eq_u(a.field, DS_ATOM_DSC_HEADER, "first atom is DscHeader");
    eq_u(a.body_len, sizeof body, "first body length");
    ok(a.body != NULL && a.body[1] == 0x2A, "first body content");
    eq_u(a.next, n, "first atom's next");

    ok(ds_pbf_next_atom(buf, total, a.next, &a) == DS_PBF_OK, "second atom");
    eq_u(a.field, DS_ATOM_SCHEMA_DEF, "second atom is SchemaDef");
    eq_u(a.body_len, 0, "second body is empty");
    eq_u(a.next, total, "second atom's next");

    ok(ds_pbf_next_atom(buf, total, a.next, &a) == DS_PBF_EOF, "clean EOF");
}

static void test_rfcs_19_2__truncation_is_eof(void)
{
    /*
     * [RFCS.19.2] — a partial trailing atom is EOF, not an error; the reader
     * ends the container at the last COMPLETE atom.
     *
     * Checked at every possible cut rather than at one or two, because the
     * interesting cuts are the ones nobody picks by hand: mid-length-varint,
     * between the two bytes of a two-byte tag, one byte short of a body. A
     * reader that returned MALFORMED at any of them would fail on a recording
     * that is simply still being written — which is every live recording — and
     * [RFCS.19.8]'s crash-recovery would have nothing to stand on.
     */
    uint8_t buf[64];
    size_t  n1 = frame(buf, 0, DS_ATOM_STREAM_HEADER, NULL, 0);
    size_t  n2 = frame(buf, n1, DS_ATOM_FACT_ASSERT, (const uint8_t *)"abcd", 4);
    size_t  total = frame(buf, n2, DS_ATOM_CLOCK_ADVANCE, NULL, 0);
    size_t  cut;

    for (cut = 0; cut <= total; cut++) {
        size_t pos = 0;
        size_t last_complete = 0;
        int    saw_bad = 0;
        for (;;) {
            ds_pbf_atom_t a;
            ds_pbf_step_t st = ds_pbf_next_atom(buf, cut, pos, &a);
            if (st == DS_PBF_EOF) break;
            if (st != DS_PBF_OK) { saw_bad = 1; break; }
            /* Every atom the scan yields must lie wholly inside the prefix. */
            if (a.next > cut) { saw_bad = 1; break; }
            pos = a.next;
            last_complete = pos;
        }
        checks++;
        if (saw_bad) {
            fails++;
            fprintf(stderr, "FAIL: truncation at %lu was not EOF ([RFCS.19.2])\n",
                    (unsigned long)cut);
        }
        /* And it stopped where the bytes did, not before: the three complete
           prefixes are exactly 0, n1, n2, total. */
        checks++;
        {
            size_t want = (cut >= total) ? total
                        : (cut >= n2)    ? n2
                        : (cut >= n1)    ? n1 : 0;
            if (last_complete != want) {
                fails++;
                fprintf(stderr,
                        "FAIL: cut %lu ended at %lu, want %lu — the scan "
                        "dropped a COMPLETE atom\n",
                        (unsigned long)cut, (unsigned long)last_complete,
                        (unsigned long)want);
            }
        }
    }
}

static void test_rfcs_19_3__malformed_is_not_truncation(void)
{
    ds_pbf_atom_t a;

    /* Outer field is not `atoms` = 1. A container of something else is not a
       container of atoms, and no further bytes make it one. */
    {
        static const uint8_t wrong_outer[] = { 0x12, 0x02, 0x0A, 0x00 }; /* field 2 */
        eq_u(ds_pbf_next_atom(wrong_outer, sizeof wrong_outer, 0, &a),
             DS_PBF_MALFORMED, "outer field != 1");
    }
    /* Outer wire type is varint, not length-delimited. */
    {
        static const uint8_t wrong_wire[] = { 0x08, 0x01 };
        eq_u(ds_pbf_next_atom(wrong_wire, sizeof wrong_wire, 0, &a),
             DS_PBF_MALFORMED, "outer wire != 2");
    }
    /* A group (wire 3): removed in proto3, so it cannot appear and cannot
       become valid. */
    {
        static const uint8_t group[] = { 0x0A, 0x01, 0x0B };
        eq_u(ds_pbf_next_atom(group, sizeof group, 0, &a),
             DS_PBF_MALFORMED, "inner group wire type");
    }
    /* Field number zero — and the zero-fill case with it. A run of 0x00 must
       not scan forever as a sequence of empty fields. */
    {
        static const uint8_t zeros[] = { 0x0A, 0x04, 0x00, 0x00, 0x00, 0x00 };
        eq_u(ds_pbf_next_atom(zeros, sizeof zeros, 0, &a),
             DS_PBF_MALFORMED, "inner field 0");
    }
    /* A complete frame carrying an EMPTY Atom: framed, but with no oneof
       member, so it has no identity to dispatch on. Distinct from truncation —
       the frame's declared length was satisfied. */
    {
        static const uint8_t empty_atom[] = { 0x0A, 0x00 };
        eq_u(ds_pbf_next_atom(empty_atom, sizeof empty_atom, 0, &a),
             DS_PBF_MALFORMED, "empty Atom");
    }
    /* A scalar where a body belongs. */
    {
        static const uint8_t scalar[] = { 0x0A, 0x02, 0x08, 0x01 }; /* field 1, varint */
        eq_u(ds_pbf_next_atom(scalar, sizeof scalar, 0, &a),
             DS_PBF_MALFORMED, "oneof member is not a sub-message");
        ok(!a.short_body, "a scalar oneof member is no short body");
    }
    /* [RDSC.11.1]: the outer tag is the byte 0x0A, judged before any varint,
       so a 0xFF where a frame begins is malformed, not a tag still arriving.
       A stream reader refuses such a tail rather than waiting on it. */
    {
        static const uint8_t erased[] = { 0xFF };
        eq_u(ds_pbf_next_atom(erased, sizeof erased, 0, &a),
             DS_PBF_MALFORMED, "0xFF where a frame begins");
    }
    /* A length varint whose ten bytes all continue: no eleventh byte makes it
       a varint, so it is malformed with or without one. */
    {
        static const uint8_t ten[] = { 0x0A, 0x80, 0x80, 0x80, 0x80, 0x80,
                                       0x80, 0x80, 0x80, 0x80, 0x80 };
        eq_u(ds_pbf_next_atom(ten, sizeof ten, 0, &a),
             DS_PBF_MALFORMED, "a varint past ten bytes");
    }
    /* A body cut short inside a complete frame: MALFORMED to every caller,
       flagged as a short body for a `.dsc` loader, which codes it apart. */
    {
        static const uint8_t short_body[] = { 0x0A, 0x03, 0xBA, 0x10, 0x05 };
        eq_u(ds_pbf_next_atom(short_body, sizeof short_body, 0, &a),
             DS_PBF_MALFORMED, "a body cut short inside its frame");
        ok(a.short_body, "a body cut short inside its frame is flagged");
    }
    /* ... and an empty Atom is malformed and not flagged: it has no field to
       run short. */
    {
        static const uint8_t empty_atom[] = { 0x0A, 0x00 };
        eq_u(ds_pbf_next_atom(empty_atom, sizeof empty_atom, 0, &a),
             DS_PBF_MALFORMED, "empty Atom");
        ok(!a.short_body, "an empty Atom is no short body");
    }
}

static void test_rfcs_19_4__container_type_from_first_field(void)
{
    uint8_t buf[32];
    size_t  n;

    /* [RFCS.19.4] — the container's type is its first atom's field number.
       No magic, no stored discriminator. */
    n = frame(buf, 0, DS_ATOM_STREAM_HEADER, NULL, 0);
    n = frame(buf, n, DS_ATOM_FACT_ASSERT, NULL, 0);
    eq_u(ds_pbf_container_of(buf, n), DS_PBF_CONTAINER_STREAM, "stream container");

    n = frame(buf, 0, DS_ATOM_DSC_HEADER, NULL, 0);
    n = frame(buf, n, DS_ATOM_SCHEMA_DEF, NULL, 0);
    eq_u(ds_pbf_container_of(buf, n), DS_PBF_CONTAINER_DSC, "dsc container");

    /* Neither header first. Not a third container kind — malformed. */
    n = frame(buf, 0, DS_ATOM_SCHEMA_DEF, NULL, 0);
    eq_u(ds_pbf_container_of(buf, n), DS_PBF_CONTAINER_UNKNOWN, "headerless");
    eq_u(ds_pbf_container_of(buf, 0), DS_PBF_CONTAINER_UNKNOWN, "empty");
}

static void test_rfcs_16_2__band_fixes_blind_disposition(void)
{
    struct { uint32_t n; ds_atom_band_t band; } rows[] = {
        { 0,     DS_ATOM_BAND_NONE   },
        { 1,     DS_ATOM_BAND_INJECT },
        { 15,    DS_ATOM_BAND_INJECT },   /* the 1-byte-tag ceiling */
        { 127,   DS_ATOM_BAND_INJECT },
        { 128,   DS_ATOM_BAND_REJECT },
        { 255,   DS_ATOM_BAND_REJECT },
        { 256,   DS_ATOM_BAND_SKIP   },
        { 2047,  DS_ATOM_BAND_SKIP   },   /* max 2-byte field number */
        { 2048,  DS_ATOM_BAND_NONE   },
        { 100000, DS_ATOM_BAND_NONE  },
    };
    size_t i;
    for (i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        char what[48];
        snprintf(what, sizeof what, "band of %lu", (unsigned long)rows[i].n);
        eq_u(ds_pbf_band(rows[i].n), rows[i].band, what);
    }
}

static void test_rfcs_16_3__band_from_the_number_alone(void)
{
    /*
     * [RFCS.16.3] — the disposition for a number this reader has NO entry for.
     * The numbers below are chosen to be unallocated today; the assertion that
     * they still are comes first, so this test cannot rot into a tautology when
     * one of them is later allocated.
     */
    struct { uint32_t n; ds_pbf_disposition_t want; const char *why; } rows[] = {
        { 50,   DS_PBF_DISP_REJECT_INJECT,  "unknown inject -> reject (-726)" },
        { 127,  DS_PBF_DISP_REJECT_INJECT,  "top of the inject band" },
        { 200,  DS_PBF_DISP_REJECT_VERSION, "unknown reject-band -> DSC_VERSION" },
        { 255,  DS_PBF_DISP_REJECT_VERSION, "top of the reject band" },
        { 1000, DS_PBF_DISP_SKIP,           "unknown skip-band -> skip" },
        { 2047, DS_PBF_DISP_SKIP,           "top of the skip band" },
        { 2048, DS_PBF_DISP_MALFORMED,      "past every band ([RFCS.16.5])" },
        { 0,    DS_PBF_DISP_MALFORMED,      "field 0 is not a field" },
    };
    size_t i;
    for (i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        ok(ds_pbf_lookup(rows[i].n) == NULL,
           "fixture: the probe number must be UNallocated");
        eq_u(ds_pbf_disposition(rows[i].n), rows[i].want, rows[i].why);
    }

    /* Every allocated atom is dispatchable, whatever band it sits in — the
       reject bands are for numbers with no entry, not for known atoms. */
    for (i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        eq_u(ds_pbf_disposition(ds_atom_registry[i].number), DS_PBF_DISP_SKIP,
             "a KNOWN atom is never blind-rejected");
    }
}

static void test_rfcs_18_8__unknown_inject_backstop(void)
{
    /*
     * [RFCS.18.8] — the case the version gate cannot see. A writer added an
     * inject atom, emitted it, and forgot to bump StreamHeader.version. The
     * stream passes the version gate; the reader has no handler; and without
     * this walk it would dispatch the first field and silently drop the second.
     * That dropped field is a recorded external input, so the replay is wrong
     * and nothing said so.
     */
    uint8_t atom[32];
    size_t  n;

    /* A well-formed single-member Atom: nothing to refuse. */
    n = put_varint(atom, 0, ((uint64_t)DS_ATOM_FACT_ASSERT << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_SKIP, "single known member");

    /* The same Atom with an UNKNOWN INJECT field appended. Dispatch would see
       only the first; the backstop must see both. */
    n = put_varint(atom, n, ((uint64_t)77 << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_REJECT_INJECT,
         "a trailing unknown INJECT field is refused");

    /* An unknown SKIP-band extra is fine — that is what the band is for. */
    n = put_varint(atom, 0, ((uint64_t)DS_ATOM_DSC_HEADER << 3) | 2u);
    n = put_varint(atom, n, 0);
    n = put_varint(atom, n, ((uint64_t)1500 << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_SKIP,
         "a trailing unknown SKIP field is skipped");

    /* Reject-band extra: the ordinary forward-compat floor. */
    n = put_varint(atom, 0, ((uint64_t)DS_ATOM_DSC_HEADER << 3) | 2u);
    n = put_varint(atom, n, 0);
    n = put_varint(atom, n, ((uint64_t)200 << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_REJECT_VERSION,
         "a trailing unknown REJECT field is a version reject");

    /*
     * Worse-of, not first-of or last-of: an inject-band unknown wins over a
     * reject-band one wherever it sits. The disposition enum's numeric order
     * is not the severity order.
     */
    n = put_varint(atom, 0, ((uint64_t)77 << 3) | 2u);
    n = put_varint(atom, n, 0);
    n = put_varint(atom, n, ((uint64_t)200 << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_REJECT_INJECT,
         "inject-band unknown outranks reject-band unknown (inject first)");

    n = put_varint(atom, 0, ((uint64_t)200 << 3) | 2u);
    n = put_varint(atom, n, 0);
    n = put_varint(atom, n, ((uint64_t)77 << 3) | 2u);
    n = put_varint(atom, n, 0);
    eq_u(ds_pbf_atom_backstop(atom, n), DS_PBF_DISP_REJECT_INJECT,
         "inject-band unknown outranks reject-band unknown (reject first)");

    /* The rest of the ranking, each pair in both orders, through the public
       surface — `severity` is static and this is the observable claim anyway.
       skip < reject-version < reject-inject < malformed. */
    {
        struct { uint32_t a, b; ds_pbf_disposition_t want; const char *why; } pairs[] = {
            { DS_ATOM_DSC_HEADER, 200,  DS_PBF_DISP_REJECT_VERSION, "known < reject-version" },
            { 200, DS_ATOM_DSC_HEADER,  DS_PBF_DISP_REJECT_VERSION, "known < reject-version" },
            { DS_ATOM_DSC_HEADER, 77,   DS_PBF_DISP_REJECT_INJECT,  "known < reject-inject" },
            { 1500, 77,           DS_PBF_DISP_REJECT_INJECT,  "unknown-skip < reject-inject" },
            { 77, 1500,           DS_PBF_DISP_REJECT_INJECT,  "unknown-skip < reject-inject" },
        };
        size_t i;
        for (i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
            size_t k = put_varint(atom, 0, ((uint64_t)pairs[i].a << 3) | 2u);
            k = put_varint(atom, k, 0);
            k = put_varint(atom, k, ((uint64_t)pairs[i].b << 3) | 2u);
            k = put_varint(atom, k, 0);
            eq_u(ds_pbf_atom_backstop(atom, k), pairs[i].want, pairs[i].why);
        }
    }

    /* Garbage inside the Atom. */
    {
        static const uint8_t bad[] = { 0x0B };  /* group wire type */
        eq_u(ds_pbf_atom_backstop(bad, sizeof bad), DS_PBF_DISP_MALFORMED,
             "unparseable Atom");
    }
}

static void test_rfcs_16_1__one_registry_one_number_space(void)
{
    size_t i;

    /* `ds_pbf_lookup` binary-searches, so ascending order is a precondition,
       not a nicety: an out-of-order row makes some atom unfindable and the
       failure is a wrong-handler dispatch rather than an error. */
    for (i = 1; i < DS_ATOM_REGISTRY_COUNT; i++) {
        ok(ds_atom_registry[i - 1].number < ds_atom_registry[i].number,
           "registry is strictly ascending by field number");
    }

    for (i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
        ok(ds_pbf_lookup(e->number) == e, "every entry is findable");
        ok(e->message != NULL && e->message[0] != '\0',
           "every entry names its message");
    }

    /* No sentinel: an unframeable atom has no fallback, so
       the lookup must not offer one. */
    ok(ds_pbf_lookup(999) == NULL, "unallocated number is not found");
    ok(ds_pbf_lookup(0) == NULL, "field number 0 is not found");

    /* The three the whole geometry is arranged around ([RFCS.16.4]). */
    eq_u(DS_ATOM_FACT_ASSERT, 1, "FactAssert = 1");
    eq_u(DS_ATOM_FACT_RETRACT, 2, "FactRetract = 2");
    eq_u(DS_ATOM_CLOCK_ADVANCE, 3, "ClockAdvance = 3");
    /* Field numbers below 16 carry a 1-byte tag — the reason the hot atoms sit
       there. Asserted on the WIRE, since that is the property, not the number. */
    {
        uint8_t buf[16];
        size_t  n = frame(buf, 0, DS_ATOM_FACT_ASSERT, NULL, 0);
        eq_u(n, 4, "an inject atom frames in 4 bytes (1-byte inner tag)");
        n = frame(buf, 0, DS_ATOM_REALTIME_CONTRACT, NULL, 0);
        eq_u(n, 5, "a reject-band atom costs one more (2-byte inner tag)");
    }
}

static void test_legality_and_class(void)
{
    /* [RFCS.17.3] — a known atom in the wrong container is malformed. */
    ok(ds_pbf_legal_in(DS_ATOM_DSC_HEADER, DS_PBF_CONTAINER_DSC), "DscHeader in a .dsc");
    ok(!ds_pbf_legal_in(DS_ATOM_DSC_HEADER, DS_PBF_CONTAINER_STREAM), "DscHeader not in a stream");
    ok(ds_pbf_legal_in(DS_ATOM_FACT_ASSERT, DS_PBF_CONTAINER_STREAM), "FactAssert in a stream");
    ok(!ds_pbf_legal_in(DS_ATOM_FACT_ASSERT, DS_PBF_CONTAINER_DSC), "FactAssert not in a .dsc");
    /* [RFCS.3.2] — SchemaDef/Slot carry the same bodies in both containers, on one
       number each. `both` is a real value of the column, not a gap in it. */
    ok(ds_pbf_legal_in(DS_ATOM_SCHEMA_DEF, DS_PBF_CONTAINER_DSC) &&
       ds_pbf_legal_in(DS_ATOM_SCHEMA_DEF, DS_PBF_CONTAINER_STREAM), "SchemaDef in both");
    ok(ds_pbf_legal_in(DS_ATOM_SLOT, DS_PBF_CONTAINER_DSC) &&
       ds_pbf_legal_in(DS_ATOM_SLOT, DS_PBF_CONTAINER_STREAM), "Slot in both");
    /* An UNKNOWN atom: a reader with no entry cannot make this diagnosis and
       must not pretend to ([RFCS.17.3]). */
    ok(!ds_pbf_legal_in(999, DS_PBF_CONTAINER_DSC), "unknown is not adjudicated here");

    /* [RFCS.3.4] / [RFCS.17.5] — the classification that keeps a `call` out of
       the inject path. Getting CallIssued wrong would deliver an outbound effect to
       the engine as an input and corrupt determinism. */
    eq_u(ds_pbf_stream_class(DS_ATOM_FACT_ASSERT), DS_ATOM_CLASS_INJECT,  "FactAssert inject");
    eq_u(ds_pbf_stream_class(DS_ATOM_FACT_RETRACT), DS_ATOM_CLASS_INJECT,  "FactRetract inject");
    eq_u(ds_pbf_stream_class(DS_ATOM_CLOCK_ADVANCE), DS_ATOM_CLASS_INJECT,  "ClockAdvance inject");
    eq_u(ds_pbf_stream_class(DS_ATOM_CALL_ISSUED), DS_ATOM_CLASS_COMPARE, "CallIssued compare");
    eq_u(ds_pbf_stream_class(DS_ATOM_RULE_FIRE_ANNOTATION), DS_ATOM_CLASS_COMPARE, "RuleFireAnnotation compare");
    eq_u(ds_pbf_stream_class(DS_ATOM_STREAM_HEADER), DS_ATOM_CLASS_STRUCTURAL, "StreamHeader structural");
    /* [RFCS.3.1]: 259 is held for the deferred Checkpoint, not allocated, so
       it reads as any unknown skip-band number: no entry, no class, skipped. */
    ok(ds_pbf_lookup(259) == NULL, "259 (deferred Checkpoint) has no entry");
    eq_u(ds_pbf_stream_class(259), DS_ATOM_CLASS_NONE, "259 has no class");
    eq_u(ds_pbf_disposition(259), DS_PBF_DISP_SKIP, "259 is skipped");
    /* A DSC-only atom has no replay role to have. */
    eq_u(ds_pbf_stream_class(DS_ATOM_DSC_HEADER), DS_ATOM_CLASS_NONE, "DscHeader has no class");
    eq_u(ds_pbf_stream_class(999), DS_ATOM_CLASS_NONE, "unknown has no class");

    /* The invariant behind [RFCS.16.2]: inject-class and inject-band are the same
       set. If they ever came apart, a number would lie about its atom. */
    {
        size_t i;
        for (i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
            const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
            int in_band  = (ds_pbf_band(e->number) == DS_ATOM_BAND_INJECT);
            int in_class = (e->klass == DS_ATOM_CLASS_INJECT);
            ok(in_band == in_class, "inject band == inject class");
        }
    }
}

static void test_rfcs_16_5__number_is_wire_identity(void)
{
    /* [RFCS.16.5] — no promotion mechanism and no frequency ranking: a field
       number IS wire identity, fixed for the life of the format. The
       testable consequence is that the mapping is a bijection and stable, so a
       renumbering to "promote" a hot atom into the one-byte range cannot
       happen quietly. */
    size_t i;
    for (i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        const ds_atom_reg_entry_t *e = &ds_atom_registry[i];
        char  what[64];

        snprintf(what, sizeof what, "%s is found by its number", e->message);
        ok(ds_pbf_lookup(e->number) == e, what);

        /* Ascending and unique — `ds_pbf_lookup` bsearches, so a duplicate or
           an out-of-order row would make some atom unreachable rather than
           produce a wrong answer, which is harder to notice. */
        if (i > 0) {
            snprintf(what, sizeof what, "registry row %lu ascends",
                     (unsigned long)i);
            ok(ds_atom_registry[i - 1].number < e->number, what);
        }
    }
}

/* Complete atoms from `pos` until the step that is not OK; that step's result
   goes to *last. */
static size_t count_atoms(const uint8_t *buf, size_t len, ds_pbf_step_t *last)
{
    size_t        pos = 0, n = 0;
    ds_pbf_atom_t a;
    ds_pbf_step_t st;
    while ((st = ds_pbf_next_atom(buf, len, pos, &a)) == DS_PBF_OK) {
        n++;
        pos = a.next;
    }
    *last = st;
    return n;
}

static void test_rfcs_19_8__a_cut_recording_is_not_corrupt(void)
{
    /* [RFCS.19.8] — a recording that ends at its last complete atom is in
       progress or crash-truncated, not corrupt, and is recovered to that atom.
       Nothing in a recording attests where it ends, so the empty recording and
       one whose last atom is half-written are EOF, with every complete atom
       before the cut recovered. */
    uint8_t       buf[64];
    size_t        n1 = frame(buf, 0, DS_ATOM_STREAM_HEADER, NULL, 0);
    size_t        n2 = frame(buf, n1, DS_ATOM_FACT_ASSERT, NULL, 0);
    size_t        n3 = frame(buf, n2, DS_ATOM_CLOCK_ADVANCE, NULL, 0);
    ds_pbf_step_t last;

    eq_u(count_atoms(buf, 0, &last), 0, "an empty recording holds no atom");
    eq_u(last, DS_PBF_EOF, "and is EOF, not malformed");

    eq_u(count_atoms(buf, n3, &last), 3, "the whole recording: three atoms");
    eq_u(last, DS_PBF_EOF, "then EOF");

    eq_u(count_atoms(buf, n3 - 1, &last), 2,
         "a half-written last atom: the two before it are recovered");
    eq_u(last, DS_PBF_EOF, "and the cut is EOF, not malformed");
}

static void selftest(void)
{
    /*
     * Proves the two comparators can fail. Without this, a bug that made `ok`
     * or `eq_u` count without checking would leave every assertion above green
     * and the reader untested — the failure mode a test suite cannot report on
     * itself.
     */
    int saved_fails = fails, saved_checks = checks;

    quiet = 1;
    ok(0, "selftest: ok(0) must fail");
    eq_u(1, 2, "selftest: eq_u(1,2) must fail");
    ok(1, "selftest: ok(1) must pass");
    eq_u(7, 7, "selftest: eq_u(7,7) must pass");
    quiet = 0;

    if (fails - saved_fails != 2 || checks - saved_checks != 4) {
        fprintf(stderr, "FAIL: selftest — the comparators counted %d failure(s) "
                        "over %d check(s); expected 2 over 4\n",
                fails - saved_fails, checks - saved_checks);
        fails = saved_fails + 1;   /* leave the run red */
    } else {
        fails = saved_fails;
    }
    checks = saved_checks;
}

int main(void)
{
    selftest();

    /* The shared corpus first, so a conformance break leads the log. */
    test_vectors_encode();
    test_vectors_decode();
    test_vectors_band();

    /* This reader's own coverage. */
    test_rfcs_19_1__two_level_framing();
    test_rfcs_19_2__truncation_is_eof();
    test_rfcs_19_3__malformed_is_not_truncation();
    test_rfcs_19_4__container_type_from_first_field();

    test_rfcs_16_2__band_fixes_blind_disposition();
    test_rfcs_16_3__band_from_the_number_alone();
    test_rfcs_18_8__unknown_inject_backstop();

    test_rfcs_16_1__one_registry_one_number_space();
    test_legality_and_class();
    test_rfcs_16_5__number_is_wire_identity();
    test_rfcs_19_8__a_cut_recording_is_not_corrupt();

    if (fails) {
        fprintf(stderr,
                "\ntest_pbf_reader: %d check(s) FAILED of %d.\n",
                fails, checks);
        return 1;
    }
    printf("test_pbf_reader: OK (%d checks)\n", checks);
    return 0;
}

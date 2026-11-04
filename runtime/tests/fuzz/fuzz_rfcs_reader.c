/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * fuzz_rfcs_reader.c -- coverage-guided fuzzing of libds's fact-stream reader.
 * A recorded fact stream ([RFCS]) is untrusted input, and dsdb reads every
 * atom it shows here, through @ds-lang/ds. [RDSC.9.9] holds this reader to
 * the loader's standard: whatever bytes it is handed, it never reads or
 * writes outside what it allocated.
 *
 * WHAT IT DRIVES, by name ([STYL.5.10.8]):
 *
 *   * the whole-buffer reader, ds_rfcs_next, to the end or its first refusal;
 *   * every body it yields through the generic reader, ds_rfcs_visit_atom, and
 *     again with its unknown-field arm, ds_rfcs_visit_atom_with_unknown, which
 *     is what @ds-lang/ds's readAtoms calls, and through the typed decoder
 *     for its atom: ds_rfcs_decode_header, _clka, _rfra, _fcem, _femt, _fcrt
 *     and _fwth;
 *   * the incremental reader, ds_rfcs_next_incremental, fed the same bytes in
 *     growing prefixes through ds_rfcs_reader_extend, the way a reader of a
 *     stream still being written meets them.
 *
 * Typed fact bodies need the schema table a loaded program gives, so they are
 * fuzz_rfcs_replay.c's: the replayer decodes every one it applies.
 *
 * WHAT IT ASSERTS, beyond "did not crash" (ASan and UBSan judge memory):
 *
 *   1. THE TWO READERS AGREE. Each atom both produce is the same atom: same
 *      field number, same body at the same offset. And when the whole-buffer
 *      reader reads the input to its end without a refusal, the incremental
 *      reader reads every one of those atoms and reaches the end too. The two
 *      share framing and differ only in what a short tail means ([RFCS.19.2]),
 *      so any other difference is one of them misreading the bytes.
 *   2. A SECOND READ IS THE FIRST. Read twice, the same bytes give the same
 *      atoms and the same refusal at the same place: the reader is a function
 *      of its input, as the loader is.
 *   3. THE UNKNOWN-FIELD ARM CHANGES NOTHING ELSE. A body visited with it
 *      gives the status and the known fields it gives without it.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "libds.h"
#include "rfcs/rfcs.h"
#include "rfcs/atoms.h"

/* Atoms remembered per read. An input holding more is still read and decoded
   to the end; only the first this many are compared. */
#define MAX_ATOMS 4096u

typedef struct {
    uint32_t atom;
    size_t   offset;    /* of the body, from the start of the input */
    size_t   len;
} seen_t;

typedef struct {
    seen_t   atoms[MAX_ATOMS];
    size_t   n;          /* atoms read, compared or not */
    int      status;     /* the refusal that ended the read; 0 at the end */
    size_t   stop;       /* where the reader stood when it stopped */
} reading_t;

static bool count_field(void *ctx, const ds_rfcs_field_t *field)
{
    (void) field;
    (*(size_t *) ctx)++;
    return true;
}

/* Each unknown field's every byte is read, so a `p`/`len` that runs past what
   protobuf-c kept is ASan's to see. */
static bool count_unknown(void *ctx, const ds_rfcs_unknown_field_t *field)
{
    size_t *n = ctx;
    uint8_t x = 0;
    for (size_t i = 0; i < field->len; i++)
        x ^= field->p[i];
    n[1] += (size_t) x;
    n[0]++;
    return true;
}

/* One context for both arms, size_t[3]: count_unknown counts in words 0 and
   1, and count_field, here, in word 2. */
static bool count_field_pair(void *ctx, const ds_rfcs_field_t *field)
{
    return count_field(&((size_t *) ctx)[2], field);
}

/* Every decoder this reader's callers reach for the atom, on its body. The
   results are not compared: a decoder's job here is to refuse what it cannot
   read without reading past `len`. */
static void decode_body(uint32_t atom, const uint8_t *body, size_t len)
{
    size_t fields = 0;
    ds_result_t plain = ds_rfcs_visit_atom(atom, body, len, count_field, &fields);

    /* 3. THE UNKNOWN-FIELD ARM ([RTIM.14.9]) CHANGES NOTHING ELSE. */
    size_t with[3] = { 0, 0, 0 };   /* unknowns, their bytes' xor, known fields */
    ds_result_t armed = ds_rfcs_visit_atom_with_unknown(atom, body, len,
                                                        count_field_pair,
                                                        count_unknown, with);
    if (armed.status != plain.status || with[2] != fields)
        __builtin_trap();

    switch (atom) {
    case DS_ATOM_STREAM_HEADER: {
        ds_rfcs_header_t h;
        (void) ds_rfcs_decode_header(body, len, &h);
        break;
    }
    case DS_ATOM_CLOCK_ADVANCE: {
        ds_rfcs_clka_t c;
        (void) ds_rfcs_decode_clka(body, len, &c);
        break;
    }
    case DS_ATOM_RULE_FIRE_ANNOTATION: {
        ds_rfcs_rfra_t r;
        (void) ds_rfcs_decode_rfra(body, len, &r);
        break;
    }
    case DS_ATOM_FACT_ASSERT: {
        ds_rfcs_fcem_t f;
        (void) ds_rfcs_decode_fcem(body, len, &f);
        break;
    }
    case DS_ATOM_FACT_EMIT: {
        ds_rfcs_fcem_t f;
        (void) ds_rfcs_decode_femt(body, len, &f);
        break;
    }
    case DS_ATOM_FACT_RETRACT: {
        ds_rfcs_fcrt_t f;
        (void) ds_rfcs_decode_fcrt(body, len, &f);
        break;
    }
    case DS_ATOM_FACT_WITHDRAW: {
        ds_rfcs_fwth_t f;
        (void) ds_rfcs_decode_fwth(body, len, &f);
        break;
    }
    default:
        break;
    }
}

static void remember(reading_t *rd, const uint8_t *data, uint32_t atom,
                     const uint8_t *body, size_t len)
{
    if (rd->n < MAX_ATOMS) {
        rd->atoms[rd->n].atom   = atom;
        rd->atoms[rd->n].offset = (size_t) (body - data);
        rd->atoms[rd->n].len    = len;
    }
    rd->n++;
}

/* The whole-buffer reader: the caller says `data` is the whole stream. */
static void read_whole(const uint8_t *data, size_t size, reading_t *rd,
                       bool decode)
{
    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, data, size);
    rd->n = 0;
    rd->status = 0;
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         len = 0;
        bool           done = false;
        ds_result_t    res = ds_rfcs_next(&r, &atom, &body, &len, &done);
        if (res.status != 0) {
            rd->status = (int) res.status;
            break;
        }
        if (done) break;
        remember(rd, data, atom, body, len);
        if (decode) decode_body(atom, body, len);
    }
    rd->stop = r.pos;
}

/* The incremental reader, shown `data` a prefix at a time. The first prefix
   and the step it grows by come from the input's first two bytes, so the
   search reaches chunk boundaries inside a frame header as well as inside a
   body. Every byte is shown eventually; the read ends at END on the whole
   input, at INCOMPLETE on the whole input (a short tail), or at a refusal. */
static void read_incremental(const uint8_t *data, size_t size, reading_t *rd)
{
    size_t shown = size ? (size_t) data[0] % (size + 1u) : 0u;
    size_t step  = size > 1u ? 1u + (size_t) data[1] % 64u : 1u;

    ds_rfcs_reader_t r;
    ds_rfcs_reader_init(&r, data, shown);
    rd->n = 0;
    rd->status = 0;
    for (;;) {
        uint32_t       atom = 0;
        const uint8_t *body = NULL;
        size_t         len = 0;
        ds_rfcs_step_t st = DS_RFCS_STEP_END;
        ds_result_t    res = ds_rfcs_next_incremental(&r, &atom, &body, &len,
                                                      &st);
        if (res.status != 0) {
            rd->status = (int) res.status;
            break;
        }
        if (st == DS_RFCS_STEP_ATOM) {
            remember(rd, data, atom, body, len);
            continue;
        }
        if (shown == size) break;              /* END or a short tail: done */
        shown = size - shown > step ? shown + step : size;
        res = ds_rfcs_reader_extend(&r, data, shown);
        if (res.status != 0) {
            /* A longer prefix of the same bytes is always a valid extension;
               refusing one is a reader defect, not a finding about input. */
            __builtin_trap();
        }
    }
    rd->stop = r.pos;
}

/* Whether the atoms two readings both remembered are the same atoms: same
   field number, same body at the same offset. */
static bool same_atoms(const reading_t *a, const reading_t *b)
{
    size_t both = a->n < b->n ? a->n : b->n;
    if (both > MAX_ATOMS) both = MAX_ATOMS;
    for (size_t i = 0; i < both; i++) {
        if (a->atoms[i].atom != b->atoms[i].atom
            || a->atoms[i].offset != b->atoms[i].offset
            || a->atoms[i].len != b->atoms[i].len) {
            return false;
        }
    }
    return true;
}

static reading_t first, second, incr;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    read_whole(data, size, &first, true);

    /* 2. A second read is the first: the same atoms, and the same refusal at
       the same place. */
    read_whole(data, size, &second, false);
    if (second.n != first.n || second.status != first.status
        || second.stop != first.stop || !same_atoms(&first, &second)) {
        __builtin_trap();
    }

    /* 1. The two readers agree on every atom both produce. */
    read_incremental(data, size, &incr);
    if (!same_atoms(&first, &incr)) __builtin_trap();
    /* ... and a stream the whole-buffer reader reads to its end, the
       incremental reader reads to its end too, atom for atom. */
    if (first.status == 0 && (incr.status != 0 || incr.n != first.n
                              || incr.stop != size)) {
        __builtin_trap();
    }
    return 0;
}

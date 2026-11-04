/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * The writer-side framing (pbf_writer.c), which rfcs/codec.c frames every
 * atom through. Three independent checks:
 *
 *   1. The conformance vectors: hand-computed bytes from
 *      specs/conformance/PBF_FRAMING_VECTORS.json, through the generated
 *      pbf_vectors.h. test_pbf_reader.c reads the same corpus, and the
 *      conformance harness checks it against `atom_pb2` (runner.py,
 *      _run_pbf_framing).
 *   2. Round-trip through the reader: everything this writes parses back to
 *      the same field number and body.
 *   3. The sizing contract: `ds_pbf_prefix_size` is consulted before the body
 *      is packed and `ds_pbf_write_prefix` writes after; one byte's
 *      disagreement puts the body at the wrong offset. Checked across every
 *      varint boundary.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pbf_writer.h"
#include "pbf_vectors.h"

static int fails = 0;
static int checks = 0;
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

/*
 * Every row of the shared corpus, written by this writer and compared to the
 * corpus's bytes. The generator refuses a row whose prefix does not parse back
 * to the field and lengths it claims. The fill rows run the length arithmetic
 * to 16 KB against a literal prefix, which the round-trip below cannot.
 */

static void test_vectors_encode(void)
{
    size_t i;

    for (i = 0; i < DS_PBF_VEC_ENCODE_COUNT; i++) {
        const ds_pbf_vec_encode_t *v     = &ds_pbf_vec_encode[i];
        size_t                     total = v->prefix_len + v->body_len;
        uint8_t                   *body  = NULL;
        uint8_t                   *buf   = malloc(total + 1);
        size_t                     got   = 0;
        char                       what[96];

        snprintf(what, sizeof what, "vec encode/%s", v->name);
        if (v->is_fill) {
            body = malloc(v->body_len);
            if (body != NULL) memset(body, v->fill, v->body_len);
        }
        if (buf == NULL || (v->is_fill && body == NULL)) {
            ok(0, what);
            free(buf); free(body);
            continue;
        }

        /* The size the caller asks for before it packs: the prefix is
           variable width and the body is packed after it, in place. */
        eq_u(ds_pbf_prefix_size(v->field, v->body_len), v->prefix_len, what);
        eq_u(ds_pbf_framed_size(v->field, v->body_len), total, what);

        ok(ds_pbf_frame_atom(v->field, v->is_fill ? body : v->body,
                             v->body_len, buf, total, &got), what);
        eq_u(got, total, what);

        checks++;
        if (got != total || memcmp(buf, v->prefix, v->prefix_len) != 0) {
            size_t k;
            fails++;
            if (!quiet) {
                fprintf(stderr, "FAIL: %s — prefix got", what);
                for (k = 0; k < (got < v->prefix_len ? got : v->prefix_len); k++)
                    fprintf(stderr, " %02X", buf[k]);
                fprintf(stderr, ", want");
                for (k = 0; k < v->prefix_len; k++)
                    fprintf(stderr, " %02X", v->prefix[k]);
                fprintf(stderr, "\n");
            }
        }
        /* And the body landed after the prefix, unchanged. */
        checks++;
        if (v->body_len > 0 && got == total) {
            const uint8_t *want = v->is_fill ? body : v->body;
            if (memcmp(buf + v->prefix_len, want, v->body_len) != 0) {
                fails++;
                if (!quiet)
                    fprintf(stderr, "FAIL: %s — body not written at the "
                                    "prefix offset\n", what);
            }
        }
        free(buf); free(body);
    }
}

static void test_round_trip(void)
{
    /* Sizes straddle every length-varint boundary: the outer length counts
       the inner frame, so the outer varint grows at a different body size
       than the inner one does. */
    static const size_t sizes[] = {
        0, 1, 2, 121, 122, 123, 124, 125, 126, 127, 128, 129,
        16380, 16381, 16382, 16383, 16384, 16385, 20000
    };
    static const uint32_t fields[] = {
        DS_ATOM_FACT_ASSERT,   /* 1-byte inner tag */
        DS_ATOM_REALTIME_CONTRACT,   /* 2-byte inner tag, reject band */
        DS_ATOM_DSC_HEADER,   /* 2-byte, skip band */
        DS_ATOM_COMPUTATION_ERROR   /* 2-byte, high in the skip band */
    };
    uint8_t *body = malloc(20000);
    uint8_t *buf  = malloc(20064);
    size_t   si, fi, i;

    if (body == NULL || buf == NULL) {
        fprintf(stderr, "FAIL: round-trip fixture allocation\n");
        fails++;
        free(body); free(buf);
        return;
    }
    for (i = 0; i < 20000; i++) {
        body[i] = (uint8_t)(i * 31u + 7u);
    }

    for (fi = 0; fi < sizeof fields / sizeof fields[0]; fi++) {
        for (si = 0; si < sizeof sizes / sizeof sizes[0]; si++) {
            uint32_t      field = fields[fi];
            size_t        n     = sizes[si];
            size_t        total = 0, prefix = 0;
            ds_pbf_atom_t a;
            char          what[80];

            snprintf(what, sizeof what, "round-trip field %lu body %lu",
                     (unsigned long)field, (unsigned long)n);

            if (!ds_pbf_write_prefix(field, n, buf, 20064, &prefix, &total)) {
                ok(0, what);
                continue;
            }
            memcpy(buf + prefix, body, n);

            /* The sizing contract: what the caller was told, and where the
               body actually had to go. */
            eq_u(prefix, ds_pbf_prefix_size(field, n), what);
            eq_u(total, prefix + n, what);

            ok(ds_pbf_next_atom(buf, total, 0, &a) == DS_PBF_OK, what);
            eq_u(a.field, field, what);
            eq_u(a.body_len, n, what);
            eq_u(a.next, total, what);
            ok(n == 0 || memcmp(a.body, body, n) == 0, what);
            /* Nothing after it — a frame that over-declared its length would
               still parse and would swallow the next atom. */
            ok(ds_pbf_next_atom(buf, total, a.next, &a) == DS_PBF_EOF, what);
        }
    }
    free(body);
    free(buf);
}

static void test_two_atoms_concatenate(void)
{
    /* The property that lets a recorder append: a container is the
       concatenation of its framed atoms, with no container-level preamble. */
    uint8_t buf[64];
    size_t  n1 = 0, n2 = 0;
    ds_pbf_atom_t a;

    ok(ds_pbf_frame_atom(DS_ATOM_STREAM_HEADER, NULL, 0, buf, sizeof buf, &n1),
       "first atom");
    ok(ds_pbf_frame_atom(DS_ATOM_FACT_ASSERT, (const uint8_t *)"abcd", 4,
                         buf + n1, sizeof buf - n1, &n2), "second atom");

    ok(ds_pbf_next_atom(buf, n1 + n2, 0, &a) == DS_PBF_OK, "read first");
    eq_u(a.field, DS_ATOM_STREAM_HEADER, "first is StreamHeader");
    eq_u(a.next, n1, "first ends where the second begins");
    ok(ds_pbf_next_atom(buf, n1 + n2, a.next, &a) == DS_PBF_OK, "read second");
    eq_u(a.field, DS_ATOM_FACT_ASSERT, "second is FactAssert");
    eq_u(a.body_len, 4, "second body length");
    eq_u(ds_pbf_container_of(buf, n1 + n2), DS_PBF_CONTAINER_STREAM,
         "StreamHeader first makes it a stream ([RFCS.19.4])");
}

static void test_short_buffer_reports_the_size(void)
{
    /*
     * `ds_rfcs_encode_*` calls the framer to learn the size when the buffer is
     * short: the framer sets the size and returns an error, and every encoder
     * depends on it.
     */
    uint8_t small[3];
    size_t  prefix = 0, total = 0;

    ok(!ds_pbf_write_prefix(DS_ATOM_DSC_HEADER, 100, small, sizeof small,
                            &prefix, &total),
       "a short buffer fails");
    eq_u(total, ds_pbf_framed_size(DS_ATOM_DSC_HEADER, 100),
         "…and still reports the size the caller needs");
    eq_u(prefix, ds_pbf_prefix_size(DS_ATOM_DSC_HEADER, 100),
         "…including the prefix size");

    /* NULL out is the pure sizing call. */
    prefix = total = 0;
    ok(!ds_pbf_write_prefix(DS_ATOM_DSC_HEADER, 100, NULL, 0, &prefix, &total),
       "NULL out fails");
    eq_u(total, ds_pbf_framed_size(DS_ATOM_DSC_HEADER, 100), "sizing via NULL out");

    /*
     * Capacity is tested against prefix + BODY, not the prefix alone. A prefix
     * that fits over a body that does not would leave a truncated trailing
     * atom, which [RFCS.19.2] obliges the reader to treat as EOF — so the atom
     * would be silently dropped instead of the overflow being reported.
     */
    {
        uint8_t buf[8];
        size_t  need = ds_pbf_framed_size(DS_ATOM_DSC_HEADER, 100);
        ok(need > sizeof buf, "fixture: the body must not fit");
        ok(!ds_pbf_write_prefix(DS_ATOM_DSC_HEADER, 100, buf, sizeof buf,
                                &prefix, &total),
           "prefix fits but body does not — still refused");
    }

    /* Exactly enough succeeds: the boundary, from the other side. */
    {
        uint8_t buf[16];
        size_t  need = ds_pbf_framed_size(DS_ATOM_DSC_HEADER, 4);
        ok(need <= sizeof buf, "fixture sanity");
        ok(ds_pbf_write_prefix(DS_ATOM_DSC_HEADER, 4, buf, need, &prefix, &total),
           "exactly enough capacity succeeds");
        ok(!ds_pbf_write_prefix(DS_ATOM_DSC_HEADER, 4, buf, need - 1, &prefix, &total),
           "one byte short does not");
    }
}

static void test_unallocated_field_has_no_size(void)
{
    /* An unframeable atom has no fallback ([RFCS.16.1]). A
       plausible-looking size here would have a caller allocate a buffer for an
       atom it cannot write. */
    size_t prefix = 1, total = 1;
    eq_u(ds_pbf_prefix_size(999, 10), 0, "unallocated: no prefix size");
    eq_u(ds_pbf_framed_size(999, 10), 0, "unallocated: no framed size");
    {
        uint8_t buf[32];
        ok(!ds_pbf_write_prefix(999, 10, buf, sizeof buf, &prefix, &total),
           "unallocated: refused");
        eq_u(prefix, 0, "unallocated: prefix zeroed, not left plausible");
        eq_u(total, 0, "unallocated: total zeroed");
        ok(!ds_pbf_frame_atom(999, (const uint8_t *)"x", 1, buf, sizeof buf,
                              &total), "unallocated: one-shot refused");
    }
}

static void test_every_allocated_atom_frames(void)
{
    /* The registry and the writer must agree about which atoms exist — the
       whole set, not the handful the goldens name. */
    size_t i;
    for (i = 0; i < DS_ATOM_REGISTRY_COUNT; i++) {
        uint8_t  buf[32];
        size_t   total = 0;
        uint32_t field = ds_atom_registry[i].number;
        ds_pbf_atom_t a;

        ok(ds_pbf_prefix_size(field, 0) > 0, "every atom has a prefix size");
        ok(ds_pbf_frame_atom(field, NULL, 0, buf, sizeof buf, &total),
           "every atom frames");
        ok(ds_pbf_next_atom(buf, total, 0, &a) == DS_PBF_OK,
           "every framed atom reads back");
        eq_u(a.field, field, "every atom round-trips its number");
    }
}

static void test_body_null_with_nonzero_length_is_refused(void)
{
    /* Would otherwise memcpy from NULL. Reachable from a caller that computed a
       size and lost the pointer. */
    uint8_t buf[32];
    size_t  total = 0;
    ok(!ds_pbf_frame_atom(DS_ATOM_DSC_HEADER, NULL, 4, buf, sizeof buf, &total),
       "NULL body with a non-zero length is refused");
}

static void selftest(void)
{
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
        fails = saved_fails + 1;
    } else {
        fails = saved_fails;
    }
    checks = saved_checks;
}

int main(void)
{
    selftest();

    test_vectors_encode();
    test_round_trip();
    test_two_atoms_concatenate();
    test_short_buffer_reports_the_size();
    test_unallocated_field_has_no_size();
    test_every_allocated_atom_frames();
    test_body_null_with_nonzero_length_is_refused();

    if (fails) {
        fprintf(stderr,
                "\ntest_pbf_writer: %d check(s) FAILED of %d.\n",
                fails, checks);
        return 1;
    }
    printf("test_pbf_writer: OK (%d checks)\n", checks);
    return 0;
}

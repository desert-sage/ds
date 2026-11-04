/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * rfcs_test_atom.h — take one framed atom apart, in a test.
 *
 * Through `ds_rfcs_next`, the production reader: a test that parsed the frame
 * itself would be a second implementation of the format.
 */
#ifndef DS_RFCS_TEST_ATOM_H
#define DS_RFCS_TEST_ATOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rfcs/rfcs.h"

/*
 * Unpack the FIRST framed atom in buf[0..len): its field number (DS_ATOM_*)
 * and a pointer to its body, which points INTO buf.
 *
 * Returns false if there is no complete atom there — which in a test means the
 * encoder under test produced something the reader cannot read, and the caller
 * should say so rather than carrying on with garbage.
 */
static inline bool ds_rfcs_test_atom1(const uint8_t *buf, size_t len,
                                      uint32_t *atom,
                                      const uint8_t **body, size_t *body_len)
{
    ds_rfcs_reader_t rd;
    bool             done = false;
    ds_result_t      r;

    ds_rfcs_reader_init(&rd, buf, len);
    r = ds_rfcs_next(&rd, atom, body, body_len, &done);
    return r.status == DS_OK && !done;
}

/* The body of the first framed atom, or NULL. For the common case where the
   caller already knows which atom it wrote and only wants to decode it. */
static inline const uint8_t *ds_rfcs_test_body(const uint8_t *buf, size_t len,
                                               size_t *body_len)
{
    uint32_t       atom = 0;
    const uint8_t *body = NULL;

    if (!ds_rfcs_test_atom1(buf, len, &atom, &body, body_len))
        return NULL;
    return body;
}

/* Is the first framed atom in buf[0..len) this one (DS_ATOM_*)? */
static inline bool ds_rfcs_test_is(const uint8_t *buf, size_t len,
                                   uint32_t want)
{
    uint32_t       atom = 0;
    const uint8_t *body = NULL;
    size_t         blen = 0;

    if (!ds_rfcs_test_atom1(buf, len, &atom, &body, &blen))
        return false;
    return atom == want;
}

#endif /* DS_RFCS_TEST_ATOM_H */

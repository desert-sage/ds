/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_engine_basic — smoke test for ds_engine_new / ds_engine_free.
 *
 * The public header and the static library link and run.
 */
#include <stdio.h>
#include <stdlib.h>

#include "libds.h"

static int fail(const char *msg, ds_result_t r)
{
    fprintf(stderr, "FAIL: %s: status=%d detail=%s\n",
            msg, r.status, r.detail ? r.detail : "(null)");
    return 1;
}

int main(void)
{
    ds_engine_t *e = NULL;

    /* Null out-param → DS_ERR_INVAL. */
    ds_result_t r = ds_engine_new(NULL, NULL);
    if (r.status != DS_ERR_INVAL) {
        return fail("ds_engine_new(NULL, NULL) should return DS_ERR_INVAL", r);
    }

    /* Default config. */
    r = ds_engine_new(NULL, &e);
    if (r.status != DS_OK) {
        return fail("ds_engine_new failed", r);
    }
    if (e == NULL) {
        fprintf(stderr, "FAIL: ds_engine_new returned DS_OK but *out is NULL\n");
        return 1;
    }

    /* A pump of an empty engine succeeds. */
    r = ds_engine_pump(e);
    if (r.status != DS_OK) {
        return fail("ds_engine_pump failed", r);
    }

    /* Null engine → DS_ERR_INVAL. */
    r = ds_engine_pump(NULL);
    if (r.status != DS_ERR_INVAL) {
        return fail("ds_engine_pump(NULL) should return DS_ERR_INVAL", r);
    }

    /* Clean up. */
    r = ds_engine_free(e);
    if (r.status != DS_OK) {
        return fail("ds_engine_free failed", r);
    }

    /* Free NULL → DS_ERR_INVAL. */
    r = ds_engine_free(NULL);
    if (r.status != DS_ERR_INVAL) {
        return fail("ds_engine_free(NULL) should return DS_ERR_INVAL", r);
    }

    printf("test_engine_basic: OK\n");
    return 0;
}

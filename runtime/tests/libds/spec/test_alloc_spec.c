/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * test_alloc_spec — spec conformance for the public ds_free entry point
 * and the owned-raw-buffer release contract.
 *
 * Spec: [IALC.4] (the public free symbol and the closed owned-raw-buffer
 * set) and [IALC.7.1] (ds_free(NULL) is a no-op). Public API only.
 */
#include "spec_common.h"

/* IALC.7.1 — ds_free(NULL) is a no-op. */
static int test_ialc_7_1__free_null_is_noop(void)
{
    ds_free(NULL);   /* must not crash */
    return 0;
}

/* IALC.4.3 — the ds_json_serialize *out string is released with ds_free. */
static int test_ialc_4_3__serialize_buffer_round_trip(void)
{
    const char *src = "{\"a\":1,\"b\":[2,3]}";
    ds_json_t  *tree = NULL;
    ds_result_t r = ds_json_parse(src, strlen(src), &tree);
    EXPECT_OK("parse", r);

    char  *out = NULL;
    size_t out_len = 0;
    r = ds_json_serialize(tree, &out, &out_len);
    EXPECT_OK("serialize", r);
    if (out == NULL || out_len == 0) {
        fprintf(stderr, "FAIL: serialize produced an empty buffer\n");
        ds_json_free(tree);
        return 1;
    }

    /* The owned raw buffer is released with ds_free (IALC.4.3), not free(). */
    ds_free(out);
    ds_json_free(tree);
    return 0;
}

int main(void)
{
    int failed = 0;
    failed |= test_ialc_7_1__free_null_is_noop();
    failed |= test_ialc_4_3__serialize_buffer_round_trip();
    if (!failed) printf("test_alloc_spec: OK\n");
    return failed;
}

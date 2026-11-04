/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * ds_re2_group_name answers the group names RE2 knows, which [LREG.3.3] pairs
 * with a capture-let's bindings by position: both named spellings, an unnamed
 * group between them, every out-of-range index, NULL, and the returned string
 * being the compiled pattern's own rather than a fresh copy.
 */
#include <stdio.h>
#include <string.h>

#include "ds_re2.h"

static int fails;

static void expect_name(const ds_re2_t *re, int index, const char *want,
                        const char *label)
{
    const char *got = ds_re2_group_name(re, index);
    int ok = (want == NULL) ? (got == NULL)
                            : (got != NULL && strcmp(got, want) == 0);
    if (!ok) {
        fprintf(stderr, "FAIL: %s — group %d: want %s, got %s\n", label, index,
                want ? want : "NULL", got ? got : "NULL");
        fails++;
    }
}

int main(void)
{
    char err[256];
    ds_re2_t *re = ds_re2_compile("(?<a>x)(y)(?P<b>z)", 0u, err, sizeof err);
    if (re == NULL) {
        fprintf(stderr, "FAIL: pattern did not compile: %s\n", err);
        return 1;
    }
    if (ds_re2_group_count(re) != 3) {
        fprintf(stderr, "FAIL: group count %d, want 3\n", ds_re2_group_count(re));
        fails++;
    }
    expect_name(re, 1, "a", "(?<n>) spelling");
    expect_name(re, 2, NULL, "unnamed group between named ones");
    expect_name(re, 3, "b", "(?P<n>) spelling");
    expect_name(re, 0, NULL, "index 0 is the whole match, never named");
    expect_name(re, 4, NULL, "past the last group");
    expect_name(re, -1, NULL, "negative index");

    if (ds_re2_group_name(re, 1) != ds_re2_group_name(re, 1)) {
        fprintf(stderr, "FAIL: the name is not the pattern's own string — two "
                        "calls returned different pointers\n");
        fails++;
    }
    ds_re2_free(re);

    re = ds_re2_compile("abc", 0u, err, sizeof err);
    if (re == NULL) {
        fprintf(stderr, "FAIL: plain pattern did not compile: %s\n", err);
        return 1;
    }
    expect_name(re, 1, NULL, "a pattern with no groups");
    ds_re2_free(re);

    expect_name(NULL, 1, NULL, "NULL pattern");

    if (fails) {
        fprintf(stderr, "test_re2_group_names: %d failure(s)\n", fails);
        return 1;
    }
    printf("test_re2_group_names: OK\n");
    return 0;
}

/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors */
/* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later */
/*
 * [NDET.2.4]: libds.h names its release at compile time, and the libds it
 * links names the same release at run time. Only `libds.h` is included.
 *
 * Compile time: the three numbers are decimal integer literals a
 * preprocessor `#if` can compare, and DS_VERSION_STRING is them joined by
 * `.`. That the block is VERSION's is the `registries` gate's
 * (scripts/private/tests/compiler/test_libds_version_block.py).
 *
 * Run time: the linked libds's `libds_version`, and the `ds_version` a
 * recording's header carries, are DS_VERSION_STRING, then a `+` and the
 * build or nothing. The release rows check the `+` of each shipped archive
 * (scripts/private/gate/gate.py `_assert_header_version`); the archive this
 * suite links may carry VERSION alone.
 */
#include <stdio.h>
#include <string.h>

#include "libds.h"

#if !defined(DS_VERSION_MAJOR) || !defined(DS_VERSION_MINOR) \
    || !defined(DS_VERSION_PATCH) || !defined(DS_VERSION_STRING)
#  error "libds.h does not define the four DS_VERSION_* macros (NDET.2.4)"
#endif

/* An integrator's comparison, as the clause says one tree uses it to build
   against two releases. A macro that is not an integer literal is a
   preprocessor error here. */
#if DS_VERSION_MAJOR < 0 || DS_VERSION_MINOR < 0 || DS_VERSION_PATCH < 0
#  error "a DS_VERSION_* number is negative (NDET.2.4)"
#endif

#define DS_TEST_STR_(x) #x
#define DS_TEST_STR(x)  DS_TEST_STR_(x)

static int fail(const char *msg)
{
    fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

/* @spec [NDET.2.4] */
static int test_the_string_is_the_three_numbers(void)
{
    static const char joined[] = DS_TEST_STR(DS_VERSION_MAJOR) "."
                                 DS_TEST_STR(DS_VERSION_MINOR) "."
                                 DS_TEST_STR(DS_VERSION_PATCH);
    if (strcmp(joined, DS_VERSION_STRING) != 0) {
        fprintf(stderr, "FAIL: DS_VERSION_STRING is \"%s\", the three numbers "
                "joined are \"%s\" (NDET.2.4)\n", DS_VERSION_STRING, joined);
        return 1;
    }
    return 0;
}

/* `got` is DS_VERSION_STRING, then the end or a `+` with a build after it. */
static int check_extends(const char *got, const char *what)
{
    size_t n = strlen(DS_VERSION_STRING);
    if (got == NULL || strncmp(got, DS_VERSION_STRING, n) != 0
        || (got[n] != '\0' && (got[n] != '+' || got[n + 1] == '\0'))) {
        fprintf(stderr, "FAIL: %s is \"%s\", not DS_VERSION_STRING \"%s\", "
                "alone or with a `+` and the build (NDET.2.4)\n",
                what, got ? got : "(null)", DS_VERSION_STRING);
        return 1;
    }
    return 0;
}

/* @spec [NDET.2.4] */
static int test_the_linked_libds_extends_the_header(void)
{
    ds_engine_t *e = NULL;
    if (ds_engine_new(NULL, &e).status != DS_OK) return fail("engine_new");
    int fails = 0;
    ds_platform_signature_t sig;
    if (ds_engine_get_platform_signature(e, &sig).status != DS_OK)
        fails += fail("platform signature");
    else
        fails += check_extends(sig.libds_version, "the platform signature's "
                               "libds_version");
    ds_session_header_t hdr;
    if (ds_engine_get_session_header(e, &hdr).status != DS_OK)
        fails += fail("session header");
    else
        fails += check_extends(hdr.ds_version, "the session header's ds_version");
    (void)ds_engine_free(e);
    return fails;
}

int main(void)
{
    int fails = 0;
    fails += test_the_string_is_the_three_numbers();
    fails += test_the_linked_libds_extends_the_header();
    if (fails == 0)
        printf("OK  test_version_macros (%d tests)\n", 2);
    else
        fprintf(stderr, "FAILED: %d check(s) failed\n", fails);
    return fails ? 1 : 0;
}

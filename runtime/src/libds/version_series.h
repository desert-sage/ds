/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * [LDET.1.10]: a recorded version is accepted iff it begins with the runtime's own
 * `<major>.<minor>.`, compared as strings.
 */
#ifndef LIBDS2_INTERNAL_VERSION_SERIES_H
#define LIBDS2_INTERNAL_VERSION_SERIES_H

#include <stdbool.h>
#include <string.h>

/* The runtime's own version, defined in version/libds_version.c, the one unit
   compiled with DS_LIBDS_VERSION. */
extern const char ds_libds_version[];

/*
 * Length of `v`'s `<major>.<minor>.` prefix, including the trailing dot, or 0
 * when `v` does not carry two dots.
 */
static inline size_t ds_version_series_len(const char *v)
{
    if (v == NULL) return 0u;
    const char *first = strchr(v, '.');
    if (first == NULL) return 0u;
    const char *second = strchr(first + 1, '.');
    if (second == NULL) return 0u;
    return (size_t)(second - v) + 1u;
}

/*
 * An empty `recorded` is a reject. A `runtime_version` with fewer than two dots falls
 * back to exact equality, so it is no wildcard.
 */
static inline bool ds_version_series_match(const char *recorded,
                                           const char *runtime_version)
{
    if (recorded == NULL || recorded[0] == '\0') return false;
    if (runtime_version == NULL) return false;
    const size_t n = ds_version_series_len(runtime_version);
    if (n == 0u) return strcmp(recorded, runtime_version) == 0;
    return strncmp(recorded, runtime_version, n) == 0;
}

#endif /* LIBDS2_INTERNAL_VERSION_SERIES_H */

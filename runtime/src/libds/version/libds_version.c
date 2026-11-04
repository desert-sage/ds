/* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * The version libds.a states ([LDET.1.10]): the provenance version
 * `<version>+<sha>` in a release, from ds-version.py. This is the one unit
 * compiled with DS_LIBDS_VERSION, so every other object is the same at any
 * commit and a change of commit recompiles this file alone.
 */
#include "version_series.h"

/* For a build system that does not pass it. */
#ifndef DS_LIBDS_VERSION
#  define DS_LIBDS_VERSION "0.0.0+dev"
#endif

const char ds_libds_version[] = DS_LIBDS_VERSION;

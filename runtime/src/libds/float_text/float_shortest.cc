// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// float_shortest.cc — Float -> shortest digits for libds, through Dragonbox's compact
// cache ([LDET.3.2.7], [LDET.3.2.8]). float_fmt.c shapes what this returns.
//
// The library's source file is #included, to keep it in the one object the archive and
// both Mercury trees take. No C++ runtime is referenced.
//
// dragonbox.h declares `template <int N>`: a `-DN=...` reaching this unit is a syntax
// error.

#include "../float_fmt.h"

#include "dragonbox/dragonbox_to_chars.h"
#include "dragonbox/source/dragonbox_to_chars.cpp"

static_assert(jkj::dragonbox::max_output_string_length<jkj::dragonbox::ieee754_binary64>
                  <= DS_FLOAT_SHORTEST_MAX,
              "float_fmt.h's DS_FLOAT_SHORTEST_MAX is shorter than Dragonbox's longest output");

extern "C" int ds_float_shortest(double v, char *buf)
{
    char *end = jkj::dragonbox::to_chars_n(v, buf, jkj::dragonbox::policy::cache::compact);
    return static_cast<int>(end - buf);
}

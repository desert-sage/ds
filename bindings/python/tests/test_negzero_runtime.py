# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Negative-zero identity ([LFAC.2]).

IEEE 754 defines -0.0 == +0.0. The engine's identity comparison
(idkey_equal) and value equality (lmem_idx_val_eq) use IEEE ==, so the
identity *hash* must agree: -0.0 and +0.0 have to hash to the same
bucket, or a logical fact whose key flips between the two zeros dedups as
a spurious duplicate instead of upserting. This pins that agreement.
"""

import pyds

_NEG_ZERO_KEY = """
schema Zero scope logical:
    k: Float key
    n: Int mutable

rule touch:
    Zero
->
    log info "z"
"""


def test_neg_zero_and_pos_zero_are_one_identity():
    """A logical fact keyed on -0.0 then on +0.0 is the SAME identity (IEEE -0.0 == +0.0).

    The second assert upserts rather than creating a second fact. Before the
    hash normalization the two zeros hashed to different buckets and this left
    two facts.
    """
    eng = pyds.from_source(_NEG_ZERO_KEY)

    eng.assert_("Zero", k=-0.0, n=1)
    eng.pump()
    assert len(eng.facts) == 1

    # +0.0 is the same identity key as -0.0 under IEEE ==: upsert, not add.
    eng.assert_("Zero", k=0.0, n=2)
    eng.pump()
    assert len(eng.facts) == 1, "-0.0 and +0.0 must be one identity key"

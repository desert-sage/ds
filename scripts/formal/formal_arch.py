#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/formal_arch.py — IDRISARM1: the formal lanes run on amd64 and nowhere else.

THE RULE: no formal methods on arm. Intel only. Every lane in `formal.build` — alloy, tla, saw, cbmc, k, idris — refuses
on a non-amd64 machine, rather than four of them quietly passing.

WHY THIS IS NOT ALREADY TRUE, which is the part worth writing down.

Two lanes already refused on arm and did it for a TOOL reason rather than an
arch one: K Framework publishes amd64-only binaries and SAW's only Linux asset
is `…-ubuntu-22.04-X64.tar.gz`, so `ds-check:arm64-*` is built without either
and `check_k.py` / `check_saw.py` refuse when the binary is missing. Both
docstrings end with the same sentence — "Run `formal` on an amd64 host" — which
was already the policy, stated twice, enforced nowhere.

The other four had no such story. Alloy and TLC are JVM jars, CBMC packages for
arm64, and `check_idris.py`'s own docstring says Idris 2 "is built from source
in ds-check and is arch-neutral". So on an arm64 host the formal gate would run
six lanes, refuse two, and PASS FOUR — producing a green formal-all built from
four proofs and two refusals, on the architecture the policy excludes.

That is the shape TESTING.md rules out from the other side: not a check
that cannot fail, but a gate whose composition changes with the host it lands
on. A proof stamped on arm64 and a proof stamped on amd64 are different
evidence, and `formal-all.stamp` cannot tell them apart.

REFUSAL, NOT SKIP, for the reason `check_k.py` gives at length: a lane that
returns 0 where it proved nothing is worse than one that fails. The exit is
non-zero and names the machine.

WHY THE ARCH CHECK AND NOT ONLY `require:` PLACEMENT. `formal.build` now carries
`require: "amd64 linux"` on all six steps, which is the right fleet-level
answer — but `Step.require` is "opaque metadata for the handler layer"
(scheduler.ds), the scheduler never reads it, and every one of these recipes is
also runnable by hand as `python3 scripts/formal/check_alloy.py formal/alloy`. A policy that
lives only in the buildfile is a policy that a direct invocation walks around.
Both, therefore: placement so the fleet cannot send it, and this so the script
cannot run.
"""
from __future__ import annotations

import platform
import sys

# `x86_64` is Linux/glibc's spelling, `AMD64` is what Python reports on Windows,
# and `i386`/`i686` are 32-bit Intel. The rule says Intel; the fleet's amd64
# cap token is what it means in practice, so 32-bit is NOT admitted -- no host in
# [caps] advertises it and a lane that suddenly ran there would be as much a
# surprise as one that ran on arm.
AMD64 = frozenset({"x86_64", "amd64", "AMD64"})


def refuse_off_amd64(lane: str) -> int | None:
    """`None` on amd64; a non-zero exit code, having explained itself, elsewhere.

    Returned rather than raised so it composes with each lane's existing
    `_refuse_without_<tool>` — same shape, same call position, one `if` at the
    top of `main`.
    """
    machine = platform.machine()
    if machine in AMD64:
        return None
    print(
        f"== {lane} gate: REFUSED — formal methods are amd64-only (IDRISARM1) ==\n"
        f"   arch: {machine}\n"
        "   The formal lanes do not run on arm.\n"
        "   This is a refusal, NOT a skip: a lane that returns 0 here would put\n"
        "   a proof stamped on an excluded architecture into formal-all.stamp,\n"
        "   and the aggregate cannot tell the two apart.\n"
        "   Run `formal` on an amd64 host.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    # `python3 scripts/formal/formal_arch.py` — does THIS host qualify?
    #
    # Worth having as more than a debug aid: every other way of asking runs a
    # lane, and on an amd64 host without the toolchains that answers a different
    # question (is `saw` installed?) in the same breath. This answers only the
    # arch one, exits with the same code the lanes would, and is the thing to
    # run before wondering why `formal` refused.
    _rc = refuse_off_amd64("formal")
    if _rc is None:
        print(f"== formal gate: amd64 OK ({platform.machine()}) — lanes may run ==")
        _rc = 0
    sys.exit(_rc)

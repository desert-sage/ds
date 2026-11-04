# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""libds carries its own `fma`: a symbol census of the archive ([IARC.7.14]).

[IARC.7.14] makes the `fma` that `math.fma` ([LEXP.3.2.2]) and CORE-MATH's
functions call one correctly rounded implementation compiled into libds,
musl's at the pin, under a name private to libds, on every row. The C
library's `fma` is the integrator's, and not every one rounds once.

`libds.build`'s Libm rows compile `vendor/musl/src/math/fma.c` and the
`scalbn.c` it calls, renamed `ds_libm_fma` and `ds_libm_scalbn` at compile
time; `builtins.c` calls `ds_libm_fma` by name; `core_math_fenv.h` maps
CORE-MATH's `__builtin_fma` to it wherever the target has no fused
multiply-add instruction. What reaches the archive is checked here, on the
`libds.a` the libds-unit lane built (`scripts/private/gate/gate.py`'s LIBDS_ROOT/LIBDS_A), the
same symbol-census shape as [IARC.1.16]'s:

  * no member references `fma` or `scalbn`: nothing in the archive reaches the
    C library's;
  * no member defines them either: the private copy does not answer for the
    public name an integrator's own libm defines;
  * exactly one member defines `ds_libm_fma`, and one `ds_libm_scalbn`;
  * the member built from `builtins.c` references `ds_libm_fma`.

On amd64 every CORE-MATH member references `ds_libm_fma` too; on aarch64 and
rv64gc they execute the instruction and reference nothing, which is the same
correctly rounded value and is not a call to the C library. The census does
not require CORE-MATH's references, because whether one exists is the
target's, not libds's.

The census can fail: the cases after the first feed it listings that break
each rule, and a listing in which it read no symbols at all. Without them a
census that read nothing would pass.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
ARCHIVE = REPO / "runtime" / "src" / "libds" / "libds.a"

PUBLIC = ("fma", "scalbn")
PRIVATE = ("ds_libm_fma", "ds_libm_scalbn")
BUILTINS = "builtins.o"

# `nm -P` types: a definition with external linkage, and a reference.
_DEFINED = set("TDBRVWGSuiC")
_REFERENCED = set("Uwv")
# `nm -A -P` names a member `archive[member]: `.
_MEMBER = re.compile(r"\[([^\]]+)\]$")


def census(listing: str) -> dict[str, tuple[set[str], set[str]]]:
    """Member -> (names it defines, names it references), from `nm -A -P`."""
    out: dict[str, tuple[set[str], set[str]]] = {}
    for line in listing.splitlines():
        head, sep, rest = line.partition(": ")
        parts = rest.split()
        if not sep or len(parts) < 2:
            continue
        m = _MEMBER.search(head)
        member = m.group(1) if m else head
        defined, referenced = out.setdefault(member, (set(), set()))
        if parts[1] in _DEFINED:
            defined.add(parts[0])
        elif parts[1] in _REFERENCED:
            referenced.add(parts[0])
    return out


def violations(listing: str) -> list[str]:
    """Every way `listing` breaks [IARC.7.14]'s census; empty when it holds."""
    members = census(listing)
    if not members:
        return ["the listing names no member: nm read no symbols"]
    bad = []
    for member, (defined, referenced) in sorted(members.items()):
        for name in PUBLIC:
            if name in referenced:
                bad.append(f"{member} references `{name}`, the C library's")
            if name in defined:
                bad.append(f"{member} defines the public `{name}`")
    for name in PRIVATE:
        definers = sorted(m for m, (d, _) in members.items() if name in d)
        if len(definers) != 1:
            bad.append(f"`{name}` is defined by {len(definers)} members, not 1: "
                       f"{definers}")
    if BUILTINS not in members:
        bad.append(f"no member is {BUILTINS}")
    elif "ds_libm_fma" not in members[BUILTINS][1]:
        bad.append(f"{BUILTINS} does not reference `ds_libm_fma`")
    return bad


def _nm(archive: Path) -> str:
    nm = os.environ.get("NM", "nm")
    return subprocess.run([nm, "-A", "-P", str(archive)], capture_output=True,
                          text=True, check=True).stdout


# @spec [IARC.7.14]
def test_libds_carries_its_own_fma():
    assert ARCHIVE.is_file(), (
        f"{ARCHIVE} is not there. libds-unit builds it before this scan runs "
        f"(ci.build's libds-unit.stamp reads it); a run without it measured "
        f"nothing, so it fails rather than skips.")
    bad = violations(_nm(ARCHIVE))
    assert not bad, "[IARC.7.14]:\n  " + "\n  ".join(bad)


# ── the census can fail ──────────────────────────────────────────────────────

_CLEAN = """\
libds.a[builtins.o]: ds_libm_fma U
libds.a[builtins.o]: ds_rete_val_float T 0000000000000000 0000000000000010
libds.a[cm_exp.o]: ds_cm_exp T 0000000000000000 0000000000000400
libds.a[cm_exp.o]: ds_libm_fma U
libds.a[libm_fma.o]: ds_libm_fma T 0000000000000000 0000000000000300
libds.a[libm_fma.o]: ds_libm_scalbn U
libds.a[libm_scalbn.o]: ds_libm_scalbn T 0000000000000000 0000000000000080
"""


def test_the_census_passes_a_clean_listing():
    assert violations(_CLEAN) == []


def test_the_census_refuses_a_reference_to_the_c_librarys_fma():
    planted = _CLEAN + "libds.a[cm_pow.o]: fma U\n"
    assert violations(planted) == ["cm_pow.o references `fma`, the C library's"]


def test_the_census_refuses_a_reference_to_the_c_librarys_scalbn():
    planted = _CLEAN.replace("libds.a[libm_fma.o]: ds_libm_scalbn U",
                             "libds.a[libm_fma.o]: scalbn U")
    assert violations(planted) == ["libm_fma.o references `scalbn`, the C library's"]


def test_the_census_refuses_a_public_definition():
    planted = _CLEAN + "libds.a[libm_round.o]: fma T 0000000000000000 0000000000000300\n"
    assert violations(planted) == ["libm_round.o defines the public `fma`"]


def test_the_census_refuses_a_second_private_copy():
    planted = _CLEAN + "libds.a[mcu_fma.o]: ds_libm_fma T 0000000000000000 0000000000000300\n"
    assert violations(planted) == [
        "`ds_libm_fma` is defined by 2 members, not 1: ['libm_fma.o', 'mcu_fma.o']"]


def test_the_census_refuses_an_archive_without_the_private_copy():
    planted = "\n".join(ln for ln in _CLEAN.splitlines()
                        if not ln.startswith("libds.a[libm_scalbn.o]"))
    assert violations(planted) == [
        "`ds_libm_scalbn` is defined by 0 members, not 1: []"]


def test_the_census_refuses_a_builtins_that_does_not_call_it():
    planted = _CLEAN.replace("libds.a[builtins.o]: ds_libm_fma U\n", "")
    assert violations(planted) == ["builtins.o does not reference `ds_libm_fma`"]


def test_the_census_refuses_a_listing_with_no_symbols():
    assert violations("") == ["the listing names no member: nm read no symbols"]

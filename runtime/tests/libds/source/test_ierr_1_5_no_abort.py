# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""libds references no way to stop the process: a relocation census ([IERR.1.5]).

Run on the `libds.a` the libds-unit lane built, which folds in neither RE2 nor
Abseil. A member named for either is left out, as the clause leaves them out, so
the census reads the same way over an archive that folds them in.

The lane defines `DS_DEBUG`, where the clause allows an assert, so the census
reads which section each reference comes from: `-ffunction-sections` gives every
function its own, and the `ld -r` partial links keep them apart. `__assert_fail`
may come only from the engine's invariant walks, the functions compiled under
`DS_DEBUG` alone. A release archive holds none of those
(`build_libds_tarball.debug_checks_in`), so an archive this census passes holds
no assert once `DS_DEBUG` is off.

The census can fail: the cases after the first feed it a listing holding each
symbol, an assert outside a walk, and a listing in which it read no relocations.
The first case also requires it to have seen the walks' own references, so a
listing whose format it cannot read does not pass.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
ARCHIVE = REPO / "runtime" / "src" / "libds" / "libds.a"

FORBIDDEN = ("abort", "exit", "longjmp", "_longjmp", "siglongjmp", "__longjmp_chk",
             "__assert_fail")
ASSERT = "__assert_fail"
# scripts/private/tests/release/test_debug_checks.py holds this to the names a
# release archive is refused for carrying.
DEBUG_ONLY = ("ds_rete_beta_check", "ds_oa_check", "rete_invariant_check")

_FOLDED = re.compile(r"(^|[/_-])(re2|absl|abseil)", re.IGNORECASE)
_OWN_SEAM = "ds_re2"
_MEMBER = re.compile(r"^(\S+):\s+file format ")
_SECTION = re.compile(r"^RELOCATION RECORDS FOR \[(.+)\]:$")
_OFFSET = re.compile(r"[0-9a-f]+")
_SYMBOL = re.compile(r"[A-Za-z_]\w*")
# A walk's section, hot or cold, and a part the compiler split out of it.
_WALK_SECTION = re.compile(r"\.text(?:\.unlikely)?\.(" + "|".join(DEBUG_ONLY) + r")(?:\.\w+)*")


def _binds(member: str) -> bool:
    """Whether [IERR.1.5] binds `member`: libds's own seam over RE2 is libds's."""
    return _OWN_SEAM in member or not _FOLDED.search(member)


def scan(listing: str) -> tuple[list[str], set[str]]:
    """The forbidden references in an `objdump -r` listing, and the walks seen."""
    bad: list[str] = []
    walks: set[str] = set()
    relocations = 0
    member = section = ""
    for line in listing.splitlines():
        if match := _MEMBER.match(line):
            member = match.group(1)
            continue
        if match := _SECTION.match(line):
            section = match.group(1)
            continue
        parts = line.split()
        if len(parts) != 3 or not _OFFSET.fullmatch(parts[0]):
            continue
        relocations += 1
        symbol = _SYMBOL.match(parts[2])
        if not symbol or symbol.group(0) not in FORBIDDEN or not _binds(member):
            continue
        walk = _WALK_SECTION.fullmatch(section)
        if walk and symbol.group(0) == ASSERT:
            walks.add(walk.group(1))
            continue
        finding = f"{member}: {section} references `{symbol.group(0)}`"
        if finding not in bad:
            bad.append(finding)
    if relocations == 0:
        return ["the listing names no relocation: objdump read nothing"], walks
    return bad, walks


def _objdump(archive: Path) -> str:
    objdump = os.environ.get("OBJDUMP", "objdump")
    return subprocess.run([objdump, "-r", str(archive)], capture_output=True,
                          text=True, check=True).stdout


# @spec [IERR.1.5]
def test_ierr_1_5__no_abort_symbol_in_the_binding_objects():
    assert ARCHIVE.is_file(), (
        f"{ARCHIVE} is not there. libds-unit builds it before this scan runs; a "
        f"run without it measured nothing, so it fails rather than skips.")
    bad, walks = scan(_objdump(ARCHIVE))
    assert not bad, "[IERR.1.5]:\n  " + "\n  ".join(bad)
    assert walks, (
        "the lane builds with DS_DEBUG, so the walks' asserts should be in this "
        "listing and none was read: the census cannot see `__assert_fail` here.")


def _listing(member: str, section: str, symbol: str) -> str:
    return (f"In archive libds.a:\n\n{member}:     file format elf64-x86-64\n\n"
            f"RELOCATION RECORDS FOR [{section}]:\n"
            "OFFSET           TYPE              VALUE\n"
            f"0000000000000010 R_X86_64_PLT32    {symbol}-0x0000000000000004\n\n")


_CLEAN = _listing("engine.o", ".text.ds_engine_pump", "memcpy")


def test_the_census_passes_a_clean_listing():
    assert scan(_CLEAN) == ([], set())


@pytest.mark.parametrize("symbol", FORBIDDEN)
def test_the_census_refuses_each_symbol(symbol):
    planted = _CLEAN + _listing("cache.o", ".text.ds_cache_get", symbol)
    assert scan(planted)[0] == [f"cache.o: .text.ds_cache_get references `{symbol}`"]


@pytest.mark.parametrize("section,walk", [
    (".text.ds_oa_check", "ds_oa_check"),
    (".text.unlikely.ds_oa_check", "ds_oa_check"),
    (".text.ds_rete_beta_check.part.0", "ds_rete_beta_check"),
    (".text.rete_invariant_check", "rete_invariant_check"),
])
def test_the_census_allows_an_assert_in_a_walk(section, walk):
    assert scan(_listing("rete_combined.o", section, ASSERT)) == ([], {walk})


def test_the_census_reads_a_member_it_combined_section_by_section():
    planted = (_listing("rete_combined.o", ".text.ds_oa_check", ASSERT)
               + _listing("rete_combined.o", ".text.ds_rete_join", ASSERT))
    assert scan(planted) == (
        ["rete_combined.o: .text.ds_rete_join references `__assert_fail`"], {"ds_oa_check"})


@pytest.mark.parametrize("section", [
    ".text.ds_oa_check_all",
    ".text.not_ds_oa_check",
    ".text",
])
def test_the_census_refuses_an_assert_outside_a_walk(section):
    assert scan(_listing("oa.o", section, ASSERT))[0] == [
        f"oa.o: {section} references `__assert_fail`"]


def test_a_walk_may_assert_and_may_not_abort():
    assert scan(_listing("oa.o", ".text.ds_oa_check", "abort"))[0] == [
        "oa.o: .text.ds_oa_check references `abort`"]


def test_the_census_reads_libds_seam_over_re2():
    planted = _listing("ds_re2.o", ".text.ds_re2_compile", "abort")
    assert scan(planted)[0] == ["ds_re2.o: .text.ds_re2_compile references `abort`"]


def test_the_census_leaves_out_a_folded_re2_or_abseil_member():
    planted = (_listing("re2_compile.cc.o", ".text.compile", "abort")
               + _listing("absl_log.cc.o", ".text.log", "abort"))
    assert scan(planted)[0] == []


def test_the_census_refuses_a_listing_with_no_relocations():
    assert scan("")[0] == ["the listing names no relocation: objdump read nothing"]

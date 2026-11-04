# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Every global symbol libds.a defines is in the `ds_` namespace.

An integrator links libds.a into a program whose global C names are shared
with it. A libds helper named `oa_put` or `engine_find_rule_meta` collides with
any function of that name the program or another library defines: a duplicate
symbol at link time, or, with static archives, the linker resolving libds's
own call to the other definition with no error at all. Everything libds
exports is therefore spelt `ds_` (or `DS_`, `_ds_`, `__ds_`).

The archive is the one the libds-unit gate tests (`runtime/src/libds/libds.a`,
which `ci.build`'s step reads). `nm --defined-only --extern-only` lists its
global definitions. A C++ name must be in namespace `ds`, judged on its
MANGLED form (`IN_DS`): the demangled text of a function template begins with
its return type (`char* ds::jkj::...`), so it cannot be judged by its start.

NOT JUDGED: weak and GNU-unique definitions (`W`, `w`, `V`, `v`, `u`). Those
are the C++ compiler's inline and template instantiations (the standard
library's among them), which every C++ object carries, the linker folds, and
no prefix can rename. They cannot take a strong definition's place.
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
ARCHIVE = REPO / "runtime/src/libds/libds.a"

PREFIXES = ("ds_", "DS_", "_ds_", "__ds_")
NOT_JUDGED = {"W", "w", "V", "v", "u"}

# A name in namespace `ds`, in the Itanium mangling: a nested name (`N`, after
# any cv- or ref-qualifiers of a member function) whose first component is the
# source name `2ds`, followed by the next component's length. Also the special
# names over such a name: a vtable, VTT, typeinfo or typeinfo name (`_ZT[VTIS]`)
# and a static local's guard variable (`_ZGVZ`).
IN_DS = re.compile(r"^_Z(?:T[VTIS]|GVZ)?N[rVKRO]*2ds\d")


def global_definitions(nm_posix: str) -> list[tuple[str, str]]:
    """(name, type) for each defined symbol in `nm --format=posix` output.
    An archive member's header line (`libds.a[oa.o]:`) is skipped."""
    out = []
    for line in nm_posix.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0].endswith(":"):
            continue
        out.append((parts[0], parts[1]))
    return out


def foreign(defs: list[tuple[str, str]]) -> list[str]:
    """The strong global definitions outside the `ds_` namespace, sorted. A C
    name must carry a prefix; a C++ (`_Z`) one must be in namespace `ds`."""
    bad = set()
    for name, kind in defs:
        if kind in NOT_JUDGED:
            continue
        if name.startswith("_Z"):
            if not IN_DS.match(name):
                bad.add(name)
        elif not name.startswith(PREFIXES):
            bad.add(name)
    return sorted(bad)


def _demangler():
    """For the failure message only. One c++filt call per name is slow; the
    names are few. Without c++filt a name is shown as it is mangled."""
    tool = shutil.which("c++filt")
    if tool is None:
        return lambda n: n
    return lambda n: subprocess.run([tool, n], capture_output=True, text=True,
                                    check=True).stdout.strip()


def test_libds_exports_only_ds_names() -> None:
    assert ARCHIVE.is_file(), f"no {ARCHIVE.relative_to(REPO)}: the libds.a step builds it"
    out = subprocess.run(["nm", "--defined-only", "--extern-only", "--format=posix",
                          str(ARCHIVE)], capture_output=True, text=True, check=True).stdout
    defs = global_definitions(out)
    # The scan read something: libds defines its public API.
    assert any(n == "ds_engine_new" for n, _ in defs), "nm listed no ds_engine_new"
    demangle = _demangler()
    bad = foreign(defs)
    assert not bad, (
        f"libds.a defines {len(bad)} global symbol(s) outside the ds_ namespace"
        f": " + ", ".join(f"{n} ({demangle(n)})" if n.startswith("_Z") else n
                                 for n in bad)
        + ". Give each internal linkage, or the ds_ prefix.")


# The scan, fed what it must refuse and what it must pass, on every run.

_NM = """\
libds.a[oa.o]:
oa_put T 00000000000000f0 0000000000000030
ds_oa_get T 0000000000000120 0000000000000010
libds.a[engine.o]:
ds_engine_new T 0000000000000000 0000000000000200
DS_ENGINE_TABLE R 0000000000000000 0000000000000040
engine_find_rule_meta T 0000000000000300 0000000000000050
libds.a[ds_re2.o]:
_ZN2ds3re24initEv T 0000000000000000 0000000000000010
_ZN3re23RE2C1EPKc T 0000000000000000 0000000000000010
_ZNSt6vectorIiSaIiEE17_M_realloc_insertEv W 0000000000000000 0000000000000010
_ZGVZ1fvE1x u 0000000000000000 0000000000000008
libds.a[float_shortest.o]:
_ZN2ds3jkj9dragonbox15to_chars_detail8to_charsIdNS1_20default_float_traitsIdEEEEPcNT0_12carrier_uintEiS6_ T 0000000000000000 0000000000000010
_ZN3jkj9dragonbox15to_chars_detail8to_charsIfNS0_20default_float_traitsIfEEEEPcNT0_12carrier_uintEiS5_ T 0000000000000000 0000000000000010
_ZNK2ds5Table3getEv T 0000000000000000 0000000000000010
_ZN3dsx4initEv T 0000000000000000 0000000000000010
"""


def test_the_scan_names_every_foreign_strong_definition() -> None:
    """Namespace `ds` passes whatever its return type or qualifiers: a function
    template (whose demangled text starts `char* ds::`) and a const member. A
    name in `jkj`, `re2` or `dsx` (a prefix of the name, not the namespace)
    fails, as do the bare C names; weak and unique definitions are not judged."""
    bad = foreign(global_definitions(_NM))
    assert bad == ["_ZN3dsx4initEv",
                   "_ZN3jkj9dragonbox15to_chars_detail8to_charsIfNS0_20default_float_traitsIfEEEEPcNT0_12carrier_uintEiS5_",
                   "_ZN3re23RE2C1EPKc", "engine_find_rule_meta", "oa_put"], bad


def test_member_headers_are_not_symbols() -> None:
    names = [n for n, _ in global_definitions(_NM)]
    assert not any(n.endswith(":") for n in names)
    assert "ds_engine_new" in names and "oa_put" in names

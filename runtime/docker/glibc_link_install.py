#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""glibc_link_install.py — DS's glibc, as the build images link it.

    python3 glibc_link_install.py configparms TRIPLE
    python3 glibc_link_install.py install DESTDIR TRIPLE MACHINE CFI ID [--dry-run]

ds-base builds the whole of glibc from vendor/deps.lock's `[glibc]` pin (DS
patches no single glibc file). This installs the LINK-TIME half of that build in
place of Debian's `libc6-dev`: the headers, the start files, `libc_nonshared.a`,
the static archives and the `.so` linker scripts and links. Every compile and
every link in every image, gcc's and clang's, reads them.

The RUNTIME half stays Debian's: `libc.so.6`, `ld.so` and the rest of `libc6`
are the same 2.41 ABI, carry Debian's security fixes, and are never shipped.
`install` proves it leaves them byte for byte as it found them.

`configparms` prints the build's `slibdir` and `rtlddir`, read from Debian's
own `libc.so` linker script, so the scripts this build installs name the
runtime files that are actually there.

`install` then fails the image build, naming what is wrong, if:
  * a header or link-time file `libc6-dev` installed has no replacement from
    this build (what else it installed, gdb's pretty-printers, stays);
  * a link or a linker script it installs names a file that does not exist;
  * a file of `libc6` changed;
  * a start file lacks the architecture's control-flow note (`MACHINE`), or a
    one-function shared object linked here lacks it;
  * a program linked here, dynamically or statically, does not run.

ID is written to `/usr/share/ds/glibc.id`, which `scripts/vendor/vendor.py`'s
`platform_identity` folds into every store key.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ID_FILE = Path("/usr/share/ds/glibc.id")

# The start files every link takes from glibc (`gcc -shared` adds crti.o and
# crtn.o; an executable adds a crt1.o), whose note the linker ANDs into the
# output's.
START_FILES = ("crt1.o", "Scrt1.o", "crti.o", "crtn.o")

# What each architecture's start files and links must carry: buildlib.CFI's
# switch for that machine, read back as readelf prints it. riscv64 has none
# (hardening_check.NO_CFI).
NOTE_LINE = {"x86_64": "x86 feature:", "aarch64": "AArch64 feature:"}
NOTE_FEATURES = {"x86_64": ("IBT", "SHSTK"), "aarch64": ("BTI", "PAC")}

_SCRIPT_PATH = re.compile(r"(/[^\s()]+)")


def link_time(name: str) -> bool:
    """A file of `<libdir>` that a link reads: an object, an archive, or an
    unversioned `.so` (a linker script or the link to a runtime library). A
    versioned `.so.N` is the runtime half, which stays Debian's."""
    return name.endswith((".o", ".a")) or name.endswith(".so")


def script_paths(text: str) -> list[str]:
    """The absolute paths a linker script names (`GROUP ( … AS_NEEDED ( … ) )`)."""
    return _SCRIPT_PATH.findall(re.sub(r"/\*.*?\*/", " ", text, flags=re.S))


def configparms(libc_script: str) -> str:
    """`slibdir` and `rtlddir` for the build, from Debian's `libc.so` script:
    the directory of the `libc.so.6` it names and of the `ld` it names."""
    paths = script_paths(libc_script)
    libc = [p for p in paths if p.endswith("/libc.so.6")]
    rtld = [p for p in paths if "/ld-linux" in p]
    if len(libc) != 1 or len(rtld) != 1:
        raise SystemExit(f"glibc: Debian's libc.so names {paths}; expected one "
                         f"libc.so.6 and one ld-linux")
    return (f"slibdir={os.path.dirname(libc[0])}\n"
            f"rtlddir={os.path.dirname(rtld[0])}\n")


def note_ok(readelf_n: str, machine: str) -> bool:
    """Does `readelf -n`'s output carry the machine's control-flow features?"""
    if machine not in NOTE_LINE:
        return True
    for line in readelf_n.splitlines():
        if NOTE_LINE[machine] in line:
            got = {f.strip() for f in line.split(NOTE_LINE[machine], 1)[1].split(",")}
            return set(NOTE_FEATURES[machine]) <= got
    return False


def replaced(path: str, triple: str) -> bool:
    """Is this `libc6-dev` file one the build's link-time half replaces? A
    header, or a link-time file of `<libdir>`. Anything else it installed (gdb's
    pretty-printers, documentation) is Debian's own and stays."""
    if path.startswith("/usr/include/"):
        return True
    return (os.path.dirname(path) == f"/usr/lib/{triple}"
            and link_time(os.path.basename(path)))


def unreplaced(removed: list[str], exists) -> list[str]:
    """Each `libc6-dev` file this build gave no replacement for. A header
    Debian keeps under the multiarch include directory is replaced by the same
    header under /usr/include, where upstream installs every one."""
    out = []
    for path in removed:
        if exists(path):
            continue
        m = re.match(r"^/usr/include/(?:(.+)/)?[^/]+-linux-gnu[^/]*/(.+)$", path)
        if m and exists("/usr/include/" + "/".join(g for g in m.groups() if g)):
            continue
        out.append(path)
    return out


# An `ar` archive with no member: Debian's `libpthread_nonshared.a`, kept so
# old link lines still resolve after glibc 2.34 folded libpthread into libc. It
# carries no code, so keeping Debian's builds nothing a different way.
EMPTY_ARCHIVE = b"!<arch>\n"


def _empty_archive(path: str) -> bool:
    return (path.endswith(".a") and os.path.isfile(path)
            and not os.path.islink(path) and Path(path).read_bytes() == EMPTY_ARCHIVE)


def _sh(*argv: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kw)


def _owned(package: str) -> list[str]:
    """The files and links a Debian package installed, directories left out."""
    listing = _sh("dpkg-query", "-L", package).stdout.splitlines()
    return [p for p in listing if os.path.islink(p) or os.path.isfile(p)]


def _digests(paths: list[str]) -> dict[str, str]:
    out = {}
    for p in paths:
        if os.path.isfile(p) and not os.path.islink(p):
            out[p] = hashlib.sha256(Path(p).read_bytes()).hexdigest()
        elif os.path.islink(p):
            out[p] = "-> " + os.readlink(p)
    return out


def _ours(destdir: Path, triple: str,
          debian: set[str]) -> tuple[list[tuple[Path, str]], list[str]]:
    """(built file, where it goes) from the build's `make install DESTDIR=`:
    every header, and each link-time file of `<libdir>` that `libc6-dev`
    installed too; and the link-time files left out. A library file Debian
    has no counterpart for links to a runtime library Debian does not ship
    (`libnss_db.so`), so it is left out, by name."""
    pairs, skipped = [], []
    include = destdir / "usr" / "include"
    for src in sorted(include.rglob("*")):
        if src.is_file() or src.is_symlink():
            pairs.append((src, "/" + str(src.relative_to(destdir))))
    libdir = destdir / "usr" / "lib" / triple
    for src in sorted(libdir.iterdir()):
        if (src.is_file() or src.is_symlink()) and link_time(src.name):
            dst = f"/usr/lib/{triple}/{src.name}"
            (pairs.append((src, dst)) if dst in debian else skipped.append(dst))
    if not any(dst.endswith("/crti.o") for _, dst in pairs):
        raise SystemExit(f"glibc: {libdir} holds no crti.o: the build installed "
                         f"somewhere else")
    return pairs, skipped


def _probe(triple: str, machine: str, cfi: str) -> list[str]:
    """What the image must carry, judged by building with it."""
    problems = []
    for name in START_FILES:
        path = f"/usr/lib/{triple}/{name}"
        if not note_ok(_sh("readelf", "-n", path).stdout, machine):
            problems.append(f"{path} carries no {'/'.join(NOTE_FEATURES[machine])} note")
    with tempfile.TemporaryDirectory(dir="/var/tmp") as tmp:
        t = Path(tmp)
        (t / "f.c").write_text("int ds_probe(void) { return 1; }\n")
        (t / "m.c").write_text('#include <stdio.h>\n'
                               'int main(void) { puts("ds-glibc"); return 0; }\n')
        flags = cfi.split()
        report = ["-Wl,-z,cet-report=error"] if machine == "x86_64" else []
        _sh("gcc", "-shared", "-fPIC", *flags, *report, str(t / "f.c"),
            "-o", str(t / "f.so"))
        if not note_ok(_sh("readelf", "-n", str(t / "f.so")).stdout, machine):
            problems.append("a one-function shared object linked here carries no "
                            f"{'/'.join(NOTE_FEATURES.get(machine, ()))} note")
        for kind, extra in (("dynamic", []), ("static", ["-static"])):
            exe = t / f"m-{kind}"
            _sh("gcc", *flags, *extra, str(t / "m.c"), "-o", str(exe))
            if _sh(str(exe)).stdout != "ds-glibc\n":
                problems.append(f"a {kind} program linked here printed the wrong thing")
    return problems


def install(destdir: Path, triple: str, machine: str, cfi: str, ident: str,
            dry_run: bool) -> int:
    runtime = _owned("libc6")
    before = _digests(runtime)
    dev = _owned("libc6-dev")
    removed = [p for p in dev if replaced(p, triple)]
    pairs, skipped = _ours(destdir, triple, set(removed))
    built = {dst for _, dst in pairs}
    empty = [p for p in removed if p not in built and _empty_archive(p)]
    removed = [p for p in removed if p not in empty]
    for p in empty:
        print(f"  Debian's empty compatibility archive, kept: {p}")
    print(f"glibc: libc6-dev installed {len(dev)} file(s), {len(removed)} of "
          f"them link-time; this build provides {len(pairs)}", flush=True)
    for p in sorted(set(dev) - set(removed)):
        print(f"  Debian's own, kept: {p}")
    for p in skipped:
        print(f"  no Debian counterpart, not installed: {p}")
    planned = {dst for _, dst in pairs}
    if dry_run:
        gaps = unreplaced(removed, lambda p: p in planned)
        for p in gaps:
            print(f"  unreplaced: {p}")
        return 1 if gaps else 0
    for path in removed:
        os.unlink(path)
    for src, dst in pairs:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.lexists(dst):
            os.unlink(dst)
        shutil.copy2(src, dst, follow_symlinks=False)
    problems = [f"libc6-dev's {p} has no replacement"
                for p in unreplaced(removed, os.path.lexists)]
    for _, dst in pairs:
        if os.path.islink(dst) and not os.path.exists(dst):
            problems.append(f"{dst} links to {os.readlink(dst)}, which does not exist")
        elif dst.endswith(".so") and os.path.isfile(dst) and not os.path.islink(dst):
            head = Path(dst).read_bytes()[:4]
            if head != b"\x7fELF":
                for p in script_paths(Path(dst).read_text(errors="replace")):
                    if not os.path.exists(p):
                        problems.append(f"{dst} names {p}, which does not exist")
    after = _digests(runtime)
    problems += [f"libc6's {p} changed" for p in sorted(before) if before[p] != after.get(p)]
    problems += _probe(triple, machine, cfi)
    for p in problems:
        print(f"glibc: {p}", file=sys.stderr)
    if problems:
        return 1
    ID_FILE.parent.mkdir(parents=True, exist_ok=True)
    ID_FILE.write_text(ident + "\n")
    print(f"glibc: installed; {ID_FILE} = {ident}", flush=True)
    return 0


def main(argv: list[str]) -> int:
    if argv[1:2] == ["configparms"] and len(argv) == 3:
        triple = argv[2]
        sys.stdout.write(configparms(Path(f"/usr/lib/{triple}/libc.so").read_text()))
        return 0
    if argv[1:2] == ["install"] and len(argv) in (7, 8):
        dry = argv[7:] == ["--dry-run"]
        if len(argv) == 8 and not dry:
            raise SystemExit(f"glibc: unknown option {argv[7]!r}")
        return install(Path(argv[2]), argv[3], argv[4], argv[5], argv[6], dry)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

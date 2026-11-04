#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_k.py [k-dir] — the `k` formal lane: run the DS executable operational
semantics (formal/k/*.k) with K Framework in the ds-check image.

The thin recipe behind formal.build's `k.stamp` stamp step (Python port of
k-entrypoint.sh). kompile each definition (LLVM backend — full builtin-hook
support), then krun each of its test programs and check the result. Convention: a
definition <name>.k has programs <name>.<label>.prog, each paired with
<name>.<label>.expected holding the expected value of the definition's
OBSERVABLE cell. The /ds mount is read-only (kompile writes <name>-kompiled/), so
work in a temp dir with the .k + .prog files co-located. Non-zero if any program
mismatches — a stamp step materializes only on exit 0.

WHAT COUNTS AS PASSING, and why it is a cell and not a token. krun prints the
whole final configuration, and a program no rule reduces sits in the `<k>` cell
verbatim — so were a program to pass when its expected token appeared ANYWHERE in
krun's output, every vector whose expected token also occurs in its own source
would pass without a single rewrite:
22 of 96, among them every Kleene boundary row the pilot exists to pin
(`true and null` -> `null`, `"true" :: Bool ?` -> `true`, `key i 1` -> `1`).
That is [STYL.5.10.5]'s check that cannot fail, and TESTING.md's false
green: the input read as the output.

Now a program passes only if

  1. krun exited 0 — a parse error or a crash is a failure, not a token soup
     to search;
  2. the definition's OBSERVABLE cell, whitespace-normalised, with K's trailing
     `~> .` continuation and one pair of enclosing string quotes removed, EQUALS
     the expectation. The cell is `<k>` unless OBSERVABLE says otherwise:
     `lfac` and `rgate` write their lifecycle / verdict trace to `<trace>`,
     `rkey` writes the encoded key to `<key>` and its length to `<len>`;
  3. where the observable is not `<k>`, the `<k>` cell is EMPTY — the program
     ran to completion. A statement K could not reduce leaves it there, and a
     trace built before the stuck statement would otherwise still match.

A stuck `"true" :: Bool ?` is then `"true" :: Bool ?` in `<k>`, which is not
`true`; a stuck `key i 1` leaves `<key>` at `""` and `<k>` non-empty. Neither
passes. The FAIL branch prints the observable cells it read and the head of
the configuration, so a rendering this recipe did not anticipate is diagnosed
from the log rather than guessed at.

K PRINTS A STRING VALUE QUOTED — a trace of `assert:S=5|` appears in the
`<trace>` cell as `"assert:S=5|"`. The quote strip is what the KLANE1 fix
(2026-08) added when a bare `exp in out.split()` reported 68 false FAILURES on
the string-valued definitions; this revision keeps the strip and drops the
anywhere-in-the-output match that fix left behind.

WHAT IS RUN IS WHAT THE FILE NAMES PAIR UP, so the names are checked before
anything is kompiled. The loop below walks definitions and,
under each, the programs named for it. Four shapes fall outside that walk, and
each one passed by not being visited:

  * a definition with NO program — kompiled, never executed, and its file-level
    tie reads as a semantics that was run;
  * a vector named for NO definition (`rgatee.x.prog`) — a typo, or a definition
    that was renamed or deleted from under its cases;
  * an `.expected` with NO `.prog` — an expectation nothing is compared with;
  * a `.prog` with NO `.expected` — this one did fail, as "expected []".

`corpus_defects` reads the directory listing and returns them all; any one fails
the lane before kompile. `_selftest` runs it first on listings written here
([STYL.5.10.5]).
"""
from __future__ import annotations

import glob
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402

# THE OBSERVABLE CELL, PER DEFINITION. A definition absent here is observed in
# `<k>`: it reduces its program to a value and that value is the answer
# (kleene, dsexpr, dscast, rlet, rlow). The three below run a schedule to
# completion and record what happened in a cell of their own; their `<k>` ends
# empty and is checked for that (rule 3 above).
#
# A definition added with its own observable cell must be added here, or its
# vectors will be compared against an empty `<k>` and fail — loudly, which is
# the right direction for an omission to fail in.
OBSERVABLE: dict[str, tuple[str, ...]] = {
    "lfac": ("trace",),
    "rgate": ("trace",),
    "rkey": ("key", "len"),
}

# K renders the empty continuation as `.` (or `.K`) and a value left in `<k>`
# as `<value> ~> .`; both spellings have been seen across K releases, so both
# are normalised away rather than one being assumed.
_TAILS = (" ~> .K", " ~> .")


def _refuse_without_kompile() -> int | None:
    """REFUSE, don't skip, when K is absent (ARM64TEST1).

    K Framework publishes amd64 Linux binaries only — no arm64 .deb in any
    recent release — so ds-check on arm64 carries no `kompile`. The tempting
    behaviour is to notice that and return 0 with a note. That would make this
    lane pass on the one architecture where it has proved nothing, which is the
    "check that cannot fail" TESTING.md rules out.

    So: a named, non-zero refusal. `formal` is an amd64 lane, and an arm64 host
    is told exactly why rather than being handed a green.
    """
    if shutil.which("kompile") is not None:
        return None
    print(
        "== k gate: REFUSED — no `kompile` on this machine ==\n"
        f"   arch: {platform.machine()}\n"
        "   K Framework ships amd64-only binaries (upstream publishes\n"
        "   kframework_<v>_amd64_ubuntu_{jammy,noble}.deb and a source tarball;\n"
        "   no arm64 build), so ds-check:arm64-* is built without it.\n"
        "   This is a refusal, NOT a skip: the lane cannot prove anything here,\n"
        "   so it must not report success. Run `formal` on an amd64 host.",
        file=sys.stderr,
    )
    return 1


_DEFECT = {
    "no-program": "{0}.k has no {0}.<label>.prog — it would be kompiled and never run",
    "orphan": "{0} is named for no definition in this directory — nothing runs it",
    "no-prog": "{0}.expected has no {0}.prog — an expectation nothing is compared with",
    "no-expected": "{0}.prog has no {0}.expected — a program with nothing to show",
}


def corpus_defects(names: list[str]) -> list[tuple[str, str]]:
    """(kind, subject) for every file the definition/program walk would not
    visit, from a directory listing. Empty when every definition has a program
    and every vector is a `<definition>.<label>` pair."""
    defs = {n[:-len(".k")] for n in names if n.endswith(".k")}
    progs = {n[:-len(".prog")] for n in names if n.endswith(".prog")}
    exps = {n[:-len(".expected")] for n in names if n.endswith(".expected")}

    def owned(stem: str) -> bool:
        return any(stem.startswith(d + ".") and len(stem) > len(d) + 1 for d in defs)

    out: list[tuple[str, str]] = []
    for d in sorted(defs):
        if not any(p.startswith(d + ".") and len(p) > len(d) + 1 for p in progs):
            out.append(("no-program", d))
    for stem in sorted(progs):
        if not owned(stem):
            out.append(("orphan", stem + ".prog"))
    for stem in sorted(exps):
        if not owned(stem):
            out.append(("orphan", stem + ".expected"))
    out += [("no-prog", s) for s in sorted(exps - progs) if owned(s)]
    out += [("no-expected", s) for s in sorted(progs - exps) if owned(s)]
    return out


def _selftest() -> list[str]:
    """`corpus_defects` against listings whose answer is known. Returns what it
    got wrong; empty means each of the four shapes is seen and a clean listing
    is left alone."""
    clean = ["a.k", "a.one.prog", "a.one.expected", "ab.k", "ab.x.y.prog",
             "ab.x.y.expected", "README.md"]
    cases: list[tuple[str, list[str], list[tuple[str, str]]]] = [
        ("a clean listing", clean, []),
        ("a definition with no program", clean + ["b.k"], [("no-program", "b")]),
        ("a definition whose name is another's prefix is not served by its programs",
         ["a.k", "ab.k", "ab.one.prog", "ab.one.expected"], [("no-program", "a")]),
        ("a vector named for no definition",
         clean + ["c.one.prog", "c.one.expected"],
         [("orphan", "c.one.prog"), ("orphan", "c.one.expected")]),
        ("a vector with no label", clean + ["a.prog", "a.expected"],
         [("orphan", "a.prog"), ("orphan", "a.expected")]),
        ("an expectation with no program", clean + ["a.two.expected"],
         [("no-prog", "a.two")]),
        ("a program with no expectation", clean + ["a.two.prog"],
         [("no-expected", "a.two")]),
    ]
    return [f"{label}: wanted {want}, read {corpus_defects(listing)}"
            for label, listing, want in cases
            if corpus_defects(listing) != want]


def _normalise(text: str) -> str:
    """One cell's content as a comparable value: whitespace collapsed, the
    trailing continuation removed, one pair of enclosing string quotes removed."""
    t = " ".join(text.split())
    for tail in _TAILS:
        if t.endswith(tail):
            t = t[: -len(tail)]
    if t == ".K":
        t = "."
    if len(t) >= 2 and t[0] == '"' and t[-1] == '"':
        t = t[1:-1]
    return t


def _cell(out: str, cell: str) -> str | None:
    """The normalised content of `<cell>…</cell>` in a krun configuration dump,
    or None when the cell is absent. `<k>` does not match `<key>`: the closing
    `>` is part of the pattern."""
    m = re.search(rf"<{cell}>(.*?)</{cell}>", out, re.S)
    return None if m is None else _normalise(m.group(1))


def _k_is_empty(k: str | None) -> bool:
    return k is not None and k in ("", ".")


def _verdict(name: str, out: str, exp: str) -> tuple[bool, str]:
    """(passed, what was read) for one program's configuration dump."""
    cells = OBSERVABLE.get(name, ("k",))
    values = {c: _cell(out, c) for c in cells}
    k_text = _cell(out, "k")
    hit = exp != "" and any(v == exp for v in values.values())
    settled = "k" in cells or _k_is_empty(k_text)
    read = "; ".join(f"<{c}>={v!r}" for c, v in values.items())
    if "k" not in cells:
        read += f"; <k>={k_text!r}"
    return hit and settled, read


def main(argv: list[str]) -> int:
    # IDRISARM1 BEFORE THE TOOL CHECK. See check_saw.py's note on the ordering:
    # "no `kompile` here" reads as a missing install, and the point is that the
    # lane does not run on this architecture whether one is present or not.
    refused = formal_arch.refuse_off_amd64("k")
    if refused is not None:
        return refused

    refused = _refuse_without_kompile()
    if refused is not None:
        return refused

    wrong = _selftest()
    if wrong:
        print("== k gate: the corpus reader failed its own fixtures, so its "
              "silence on a directory would mean nothing ==", file=sys.stderr)
        for w in wrong:
            print(f"   {w}", file=sys.stderr)
        return 2

    d = Path(argv[1] if len(argv) > 1 else "formal/k")
    defs = sorted(glob.glob(str(d / "*.k")))
    if not defs:
        print(f"== k gate: no *.k definitions in {d} ==", file=sys.stderr)
        return 1

    defects = corpus_defects(sorted(Path(f).name for f in glob.glob(str(d / "*"))
                                    if Path(f).is_file()))
    if defects:
        print(f"== k gate: {len(defects)} file(s) in {d} that no run would visit ==",
              file=sys.stderr)
        for kind, subject in defects:
            print(f"   FAIL: {_DEFECT[kind].format(subject)}", file=sys.stderr)
        return 1

    print("== k gate: toolchain ==")
    subprocess.run(["kompile", "--version"], check=False)

    rc = 0
    with tempfile.TemporaryDirectory(prefix="ds-k.") as work:
        for f in glob.glob(str(d / "*")):
            if Path(f).is_file():
                shutil.copyfile(f, Path(work) / Path(f).name)
        for kf in sorted(glob.glob(str(Path(work) / "*.k"))):
            name = Path(kf).stem
            kfile = Path(kf).name
            # LLVM backend: K's native concrete-execution backend, full builtin-hook
            # support (Haskell backend lacks e.g. FLOAT.int2float). clang-15/llvm-15
            # are in the image (K pulled them).
            print(f"== kompile {kfile} (llvm backend) ==")
            kc = subprocess.run(
                ["kompile", "--backend", "llvm", "--syntax-module", f"{name.upper()}-SYNTAX", kfile],
                cwd=work, capture_output=True, text=True)
            if kc.returncode != 0:
                print("\n".join((kc.stdout + kc.stderr).splitlines()[-4:]))
                print(f"  FAIL: kompile {kfile}")
                rc = 1
                continue
            for prog in sorted(glob.glob(str(Path(work) / f"{name}.*.prog"))):
                exp_file = Path(prog).with_suffix(".expected")
                exp = exp_file.read_text().strip() if exp_file.is_file() else ""
                got = subprocess.run(["krun", "--definition", f"{name}-kompiled", Path(prog).name],
                                     cwd=work, capture_output=True, text=True)
                out = got.stdout + got.stderr
                if got.returncode != 0:
                    print(f"  FAIL: {Path(prog).name} -> krun exited {got.returncode}:")
                    print("\n".join(out.splitlines()[-12:]))
                    rc = 1
                    continue
                ok, read = _verdict(name, out, exp)
                if ok:
                    print(f"  PASS: {Path(prog).name} -> {exp}")
                else:
                    print(f"  FAIL: {Path(prog).name} -> expected [{exp}], read {read}; configuration:")
                    # Enough lines to reach the observable cell. At 6 the dump
                    # stopped inside <exprs>, which is what made the output look
                    # like "nothing evaluated" and sent the diagnosis the wrong way.
                    print("\n".join(out.splitlines()[:30]))
                    rc = 1

    print("== k gate: all programs evaluated as expected ==" if rc == 0
          else f"== k gate: FAILURES (rc={rc}) ==")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

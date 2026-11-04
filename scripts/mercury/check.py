#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""mercury: build and test the Mercury binding.

    python3 scripts/mercury/check.py

Run from the repository root, with `mmc` (grade hlc.gc) and RE2 where the
image DS builds in has them, after mercury.build has installed both libraries.

## The check, in order

1. The canon's mechanical rules (MERCURY_STYLE.md, "What the gate checks"),
   each checker first shown refusing its permanent negative fixture, since a
   checker never seen to fire is indistinguishable from a dead one:
   - every module of the binding halts at a warning: `Mercury.options` has
     its line, and `ci/fixtures/warns.m`, a module with one warning, fails
     under that line and builds without it;
   - layout (MER.12): no line past 79 columns, no tab, no trailing space;
   - purity (MER.6): no purity promise, impure call, foreign procedure or
     mutable.
2. The harness (`examples/harness.m`) calls everything the package exports
   for a host, so it exercises every feature.
3. The binding's fixtures (`test/fixtures/*.ds`) and the harness's program
   (`examples/harness.ds`) are compiled by the Mercury `dsc` the `mdsc-bin`
   step builds (`DS_MERCURY_DSC`, else `.build/mdsc/dsc_cli`). The test
   program's negative fixture, `verbs_short_call.dsc`, is built from the
   compiled `verbs.dsc` by the conformance harness's own
   `dsc_seal.drop_call_operand` and `dsc_seal.seal`: no compiler writes a
   call its op does not admit ([RDSC.4a.9.3]), and the session that runs it
   halts ([NCBK.2.9]).
4. The test program, the harness and `ci/trace_mercury_ds.m` are HOSTS: each
   is built in a directory of its own holding only itself and the binding's
   `Mercury.options`, and reaches the binding and the runtime only as the two
   installed libraries, `--ml mercury_ds --ml mercury_ds_runtime`.
   mercury.build installs both (`mercury-lib-install`,
   `mercury-ds-lib-install`). All three link shared, and the harness links
   statically too, as a host may; `ldd` must show a shared binary resolving
   each library from its prefix, and a static one resolving neither, so no
   run can pass on another copy.
5. The test program runs over the compiled fixtures, and its last line must
   say that checks ran and none failed. The harness runs over its program,
   both linkages, and its last line must be `harness: OK`.

Scratch is under the clone's `.build/`, never /tmp (BUILD-RUNBOOK §4).
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path.cwd()
BINDING = ROOT / "bindings" / "mercury"
SCRATCH = ROOT / ".build" / "mercury_ds"
FIXTURES_OUT = SCRATCH / "fixtures"
HOSTS = SCRATCH / "hosts"
# The two installed libraries, each under the `lib/mercury/` of the prefix
# mercury.build installs it into: what `--mld` names.
LIBRARIES = {
    "mercury_ds": ROOT / ".build" / "mercury_ds" / "prefix" / "lib"
    / "mercury",
    "mercury_ds_runtime": ROOT / ".build" / "mercury" / "prefix" / "lib"
    / "mercury",
}
# How each linkage is asked for: a static
# host names RE2 and libstdc++, which the runtime's archive does not carry.
LINKS = {
    "shared": ["--mercury-linkage", "shared"],
    "static": ["--mercury-linkage", "static", "--library", "re2",
               "--library", "stdc++"],
}
TEST_PROGRAM = "test_mercury_ds"
HARNESS = "harness"
DRIVER = "trace_mercury_ds"
# fuzz-dsc's driver of fuzz_host_values's scripts, linked with `link_hosts`,
# as binding-diff links DRIVER.
FUZZ_DRIVER = "host_values_mercury"
SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed, (\d+) skipped$")
HARNESS_OK = "harness: OK"
EXPORTED = re.compile(r"^:- (?:pred|func) ([a-z][a-z0-9_]*)")
INCLUDED = re.compile(r"^:- include_module ([a-z][a-z0-9_]*)\.")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(argv: list[str], **kw) -> subprocess.CompletedProcess:
    log("+ " + " ".join(argv))
    return subprocess.run(argv, check=True, **kw)


# The canon's mechanical rules (MERCURY_STYLE.md, "What the gate checks").

OPTIONS = "Mercury.options"
CANON_FIXTURES = BINDING / "ci" / "fixtures"
MAX_COLUMNS = 79
PURITY = re.compile(
    r"\b(promise_pure|promise_semipure|promise_equivalent_solutions"
    r"|promise_only_solution|impure|semipure|foreign_proc)\b"
    r"|^\s*:- (pragma promise|mutable)\b")

# Each checker's negative fixture: lines it must refuse, one problem each.
LAYOUT_FIXTURE = ["%" + "-" * MAX_COLUMNS, "\tp :- true.", "p :- true. "]
PURITY_FIXTURE = [":- pragma promise_pure(p/1).", "    impure q(X),",
                  ":- mutable(count, int, 0, ground, [untrailed])."]


def halt_line(module: str) -> str:
    """The `Mercury.options` line that makes a module halt at a warning."""
    return f"MCFLAGS-{module} = --halt-at-warn"


def binding_sources() -> list[Path]:
    """Every Mercury source of the binding: the package, the test program and
    the canon's own fixture."""
    return sorted(BINDING.rglob("*.m"))


def layout_problems(name: str, lines: list[str]) -> list[str]:
    problems = []
    for number, line in enumerate(lines, 1):
        where = f"{name}:{number}"
        if len(line) > MAX_COLUMNS:
            problems.append(f"{where}: past {MAX_COLUMNS} columns")
        if "\t" in line:
            problems.append(f"{where}: a tab")
        if line != line.rstrip(" \t"):
            problems.append(f"{where}: trailing whitespace")
    return problems


def purity_problems(name: str, lines: list[str]) -> list[str]:
    return [f"{name}:{number}: {line.strip()}"
            for number, line in enumerate(lines, 1) if PURITY.search(line)]


def check_refuses(checker, fixture: list[str], what: str) -> None:
    """A checker must report each line of its fixture, once."""
    found = checker("fixture", fixture)
    if len(found) != len(fixture):
        raise SystemExit(f"check: the {what} check found {len(found)} "
                         f"problems in its {len(fixture)}-line fixture: "
                         f"{found}")


def check_halt_at_warn() -> None:
    log("=== mercury: every module halts at a warning ===")
    modules = [p.stem for p in sorted((BINDING / "src").glob("*.m"))]
    modules += [p.stem for p in sorted((BINDING / "test").glob("*.m"))]
    modules += [p.stem for p in sorted((BINDING / "examples").glob("*.m"))]
    modules += [DRIVER, FUZZ_DRIVER]
    lines = (BINDING / OPTIONS).read_text(encoding="utf-8").splitlines()
    missing = [m for m in modules if halt_line(m) not in lines]
    if missing:
        raise SystemExit(f"check: {OPTIONS} has no halt-at-warning line for "
                         + ", ".join(missing))
    # The fixture fails under the line and builds without it, so its
    # failure is the option's and not some other fault in it.
    for halting in (True, False):
        work = SCRATCH / "warns" / ("halting" if halting else "plain")
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        shutil.copy2(CANON_FIXTURES / "warns.m", work / "warns.m")
        if halting:
            (work / OPTIONS).write_text(halt_line("warns") + "\n",
                                        encoding="utf-8")
        argv = ["mmc", "--make", "--cflags", "-ffp-contract=off", "libwarns"]
        log("+ " + " ".join(argv) + f"  (in {work})")
        failed = subprocess.run(argv, cwd=work).returncode != 0
        if failed != halting:
            raise SystemExit(
                "check: ci/fixtures/warns.m "
                + ("built under --halt-at-warn" if halting
                   else "did not build without --halt-at-warn"))
    log(f"mercury: {len(modules)} modules halt at a warning; the "
        "fixture fails under the line and builds without it")


def check_source_rules() -> None:
    log("=== mercury: layout (MER.12) and purity (MER.6) ===")
    check_refuses(layout_problems, LAYOUT_FIXTURE, "layout")
    check_refuses(purity_problems, PURITY_FIXTURE, "purity")
    sources = binding_sources()
    problems = []
    for path in sources:
        name = str(path.relative_to(ROOT))
        lines = path.read_text(encoding="utf-8").splitlines()
        problems += layout_problems(name, lines) + purity_problems(name, lines)
    if problems:
        raise SystemExit("check: the canon's rules are broken:\n  "
                         + "\n  ".join(problems))
    log(f"mercury: {len(sources)} sources keep the layout and the "
        "purity rule; each checker refused its fixture")


def private_modules() -> set[str]:
    """The submodules `mercury_ds.m` includes in its implementation
    section: the package's own, which no host can import."""
    text = (BINDING / "src" / "mercury_ds.m").read_text(encoding="utf-8")
    implementation = text.split(":- implementation.", 1)[-1]
    return {"mercury_ds." + m.group(1)
            for m in map(INCLUDED.match, implementation.splitlines()) if m}


def exported_calls() -> set[str]:
    """Every predicate and function the package exports to a host: its
    public modules' interfaces."""
    names = set()
    private = private_modules()
    for path in sorted((BINDING / "src").glob("*.m")):
        if path.stem in private:
            continue
        text = path.read_text(encoding="utf-8")
        interface = text.split(":- interface.", 1)[-1]
        interface = interface.split(":- implementation.", 1)[0]
        for line in interface.splitlines():
            m = EXPORTED.match(line)
            if m:
                names.add(m.group(1))
    return names


def check_harness_calls() -> None:
    """The harness exercises every feature: it calls everything the package
    exports for a host."""
    log("=== mercury: the harness calls every exported call ===")
    lines = (BINDING / "examples" / "harness.m").read_text(
        encoding="utf-8").splitlines()
    code = "\n".join(line for line in lines
                     if not line.lstrip().startswith("%"))
    exported = exported_calls()
    owed = sorted(name for name in exported
                  if not re.search(rf"\b{name}\b", code))
    if owed:
        raise SystemExit("check: examples/harness.m never calls "
                         + ", ".join(owed))
    log(f"mercury: the harness calls all {len(exported)} calls "
        f"mercury_ds exports for a host")


def compile_fixtures() -> list[str]:
    """Compile every fixture, and name the ones the compiler refused, so one
    run reports them all."""
    dsc = Path(os.environ.get("DS_MERCURY_DSC", ROOT / ".build" / "mdsc" / "dsc_cli"))
    if not dsc.is_file():
        raise SystemExit(f"check: no Mercury dsc at {dsc}")
    shutil.rmtree(FIXTURES_OUT, ignore_errors=True)
    FIXTURES_OUT.mkdir(parents=True)
    sources = sorted((BINDING / "test" / "fixtures").glob("*.ds"))
    sources += sorted((BINDING / "examples").glob("*.ds"))
    refused = []
    for src in sources:
        argv = [str(dsc), "compile", str(src.relative_to(ROOT)),
                "-o", str(FIXTURES_OUT / f"{src.stem}.dsc")]
        log("+ " + " ".join(argv))
        if subprocess.run(argv, cwd=ROOT).returncode != 0:
            refused.append(src.name)
    log(f"=== {len(sources) - len(refused)} of {len(sources)} fixtures "
        f"compiled into {FIXTURES_OUT} ===")
    return refused


# The negative fixture test_mercury_ds halts a session with: `verbs.dsc` whose
# `fire_them_all` opens with a `log` one operand short.
SHORT_CALL = ("verbs", "fire_them_all", "verbs_short_call")


def build_negative_fixtures() -> None:
    """Write the test program's negative fixture beside the compiled ones,
    from them, on every run, with the conformance harness's functions."""
    path = ROOT / "specs" / "conformance" / "harness" / "dsc_seal.py"
    spec = importlib.util.spec_from_file_location("dsc_seal", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"check: cannot load {path}")
    dsc_seal = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dsc_seal)
    source, rule, name = SHORT_CALL
    short = dsc_seal.drop_call_operand(
        (FIXTURES_OUT / f"{source}.dsc").read_bytes(), rule)
    if short is None:
        raise SystemExit(f"check: {source}.dsc has no call in `{rule}` to "
                         f"drop an operand from")
    (FIXTURES_OUT / f"{name}.dsc").write_bytes(dsc_seal.seal(short))
    log(f"=== the negative fixture {name}.dsc: {source}.dsc with `{rule}`'s "
        f"first call one operand short ===")


def link_hosts(linkage: str, programs: list[str],
               hosts: Path = HOSTS) -> list[Path]:
    """Build `programs` as hosts, against the installed libraries alone, in
    a directory holding nothing of the binding's or the runtime's source:
    `<hosts>/<linkage>`. The binding differential links the driver under a
    `hosts` of its own, so it and this gate can run at once in one clone."""
    work = hosts / linkage
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    sources = {p.stem: p for d in ("test", "examples")
               for p in (BINDING / d).glob("*.m")}
    for driver in (DRIVER, FUZZ_DRIVER):
        sources[driver] = BINDING / "ci" / f"{driver}.m"
    for program in programs:
        shutil.copy2(sources[program], work / f"{program}.m")
    shutil.copy2(BINDING / OPTIONS, work / OPTIONS)
    mld = [arg for lib in LIBRARIES.values() for arg in ("--mld", str(lib))]
    # The binding before the runtime it links against, as a static link
    # needs. `--keep-going`, so one run reports every module's errors.
    ml = [arg for name in LIBRARIES for arg in ("--ml", name)]
    run(["mmc", "--make", "--keep-going", "--grade", "hlc.gc",
         "--cflags", "-ffp-contract=off", *mld, *ml, *LINKS[linkage],
         *programs], cwd=work)
    exes = [work / program for program in programs]
    for exe in exes:
        if not exe.is_file():
            raise SystemExit(f"check: mmc wrote no {exe}")
        resolved = run(["ldd", str(exe)], stdout=subprocess.PIPE,
                       text=True).stdout.splitlines()
        for name, lib in LIBRARIES.items():
            found = [ln.strip() for ln in resolved
                     if f"lib{name}.so" in ln]
            home = str(lib / "lib" / "hlc.gc")
            if linkage == "shared" and not (found and home in found[0]):
                raise SystemExit(f"check: {exe} does not resolve lib{name}.so "
                                 f"from {home}: {found or 'not linked'}")
            if linkage == "static" and found:
                raise SystemExit(f"check: the static {exe} resolves a shared "
                                 f"lib{name}.so: {found}")
    log(f"=== {', '.join(programs)} linked {linkage} against the installed "
        f"{' and '.join(LIBRARIES)} ===")
    return exes


def build() -> tuple[Path, Path, Path, Path]:
    for name, lib in LIBRARIES.items():
        archive = lib / "lib" / "hlc.gc" / f"lib{name}.a"
        if not archive.is_file():
            raise SystemExit(f"check: no {archive}: mercury.build installs "
                             f"lib{name}")
    # FUZZ_DRIVER is linked and not run: fuzz-dsc runs it, after a merge, so
    # this is what shows a pull request that the binding still builds it.
    tests, harness, driver, _ = link_hosts(
        "shared", [TEST_PROGRAM, HARNESS, DRIVER, FUZZ_DRIVER])
    (static_harness,) = link_hosts("static", [HARNESS])
    return tests, harness, driver, static_harness


def run_harness(exe: Path) -> None:
    """The harness runs over its own program and ends saying so."""
    out = subprocess.run([str(exe), str(FIXTURES_OUT / "harness.dsc")],
                         capture_output=True, text=True)
    sys.stderr.write(out.stdout)
    sys.stderr.write(out.stderr)
    lines = out.stdout.strip().splitlines()
    if out.returncode != 0 or not lines or lines[-1] != HARNESS_OK:
        raise SystemExit(f"check: {HARNESS} did not end {HARNESS_OK!r} "
                         f"(rc {out.returncode})")


def run_tests(exe: Path) -> None:
    out = subprocess.run([str(exe)], capture_output=True, text=True,
                         env={**os.environ, "MERCURY_DS_FIXTURES": str(FIXTURES_OUT)})
    sys.stderr.write(out.stdout)
    sys.stderr.write(out.stderr)
    lines = out.stdout.strip().splitlines()
    m = SUMMARY.match(lines[-1]) if lines else None
    if m is None:
        raise SystemExit(f"check: {TEST_PROGRAM} printed no summary (rc {out.returncode})")
    passed, failed = int(m.group(1)), int(m.group(2))
    if out.returncode != 0 or failed != 0 or passed == 0:
        raise SystemExit(f"check: {TEST_PROGRAM}: {lines[-1]} (rc {out.returncode})")


def check_binding() -> Path:
    """The check, in order. Returns the linked `trace_mercury_ds`."""
    check_halt_at_warn()
    check_source_rules()
    check_harness_calls()
    refused = compile_fixtures()
    tests, harness, driver, static_harness = build()
    if refused:
        raise SystemExit("check: the compiler refused " + ", ".join(refused))
    build_negative_fixtures()
    run_tests(tests)
    run_harness(harness)
    run_harness(static_harness)
    return driver


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        log(__doc__ or "")
        return 2
    check_binding()
    log("=== mercury: all checks passed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

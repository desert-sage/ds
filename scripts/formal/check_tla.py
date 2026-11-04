#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_tla.py [models-dir] — the `tla` formal lane: model-check the DS
behavioral specs (formal/tla/*.tla) with TLC in the ds-check image.

The thin recipe behind formal.build's `tla.stamp` stamp step (Python port of
tla-entrypoint.sh). Each <name>.tla has a sibling <name>.cfg naming its
SPECIFICATION / INVARIANTs / temporal PROPERTYs; a violation, deadlock, or parse
error fails the lane (TLC prints the trace). The /ds mount is read-only, so TLC's
state metadir is redirected into a temp dir. Non-zero if any model fails — a stamp
materializes only on exit 0.

WHAT TLC CHECKS IS WHAT THE .cfg NAMES, AND NOTHING ELSE. A
property defined in the module and absent from the .cfg is parsed, tagged to its
clause, tied from the clause's `checks` block, and never evaluated: TLC reports
"No error has been found" over the properties it was given. So before TLC runs,
each model is read for two things, and either fails it:

  1. THE .cfg NAMES NO INVARIANT AND NO PROPERTY. TLC then checks deadlock
     freedom alone, and a green says nothing about any clause.
  2. A DEFINITION IS REACHABLE FROM NOTHING THE .cfg NAMES. Reachability starts
     at every identifier in the .cfg and follows each definition's body. An
     operator outside that closure is dead text, whatever its tag says. That is
     the shape a property takes when its line is dropped from the .cfg.

`gap__*` definitions are exempt from (2): a gap is the model saying what it
does not check ([STYL.5.3.6]'s `gap` tag), and is reachable from nothing on
purpose.

WHAT (2) DOES NOT SEE. A definition that is both a building block and a
property — named in an action's guard, say, and also meant as an INVARIANT —
stays reachable when its .cfg line goes. Every property in this lane is a leaf
today, so the case does not arise; it is the residue of a syntactic check.

TEETH THAT ARE RUN. A model's header says which assumption,
dropped, makes a property fail. That is a sentence, and it was measured once.
`<name>.teeth.<label>.cfg` makes it a run: the config sets the constant that
selects the engine the clause rules out, names ONE property, and declares

    MUST VIOLATE: <property>

in a comment line of its own. TLC must end in a violation. A teeth config that
passes fails the lane: the property holds of the engine it exists to exclude, so
it excludes nothing. This is [STYL.5.10.5] for a temporal property — a check
that has never failed is not known to be able to — and it is held on every run
instead of remembered.

WHAT A PASSING TEETH RUN DOES NOT SAY: that the property broke for the reason
the config's comment gives. Any violation of the one property passes. So the
run prints what TLC reported and the step each state of the counterexample was
reached by, and the reason is there to be read against the comment.

PROBES: WHAT THE CLAUSE RULES IS SEEN TO HAPPEN. "Whenever P,
Q" holds of a model in which P never happens, and an equality of two counters
holds where both stay at zero. TLC reports "No error has been found" for both.
`<name>.probe.<label>.cfg` is the teeth mechanism pointed the other way: it
runs THE CLAUSE'S ENGINE, names one `probe__*` property that says the clause's
behaviour never happens, declares `MUST VIOLATE:` on it, and TLC must end in a
violation. The counterexample it prints is the behaviour. It is what Alloy's
`run probe__*` is to a `check`.

  * A probe config carries THE SAME constants and SPECIFICATION as <name>.cfg.
    One that differs in any runs some other engine, and what that engine can
    reach says nothing of the clause's.
  * A teeth config carries DIFFERENT ones, in at least one. With none it is
    the clause's engine, and a violation there is a finding against the model,
    not teeth.
  * A `probe__*` definition is reachable from its probe config and from
    nothing else, so rule (2) above takes the target of each probe config as a
    root beside the identifiers of <name>.cfg. A `probe__*` definition no
    config names is dead text like any other.

SCOPES: THE CLAUSE'S ENGINE IN ANOTHER SCOPE. A
green <name>.cfg says "no counterexample within this scope", and one scope
can leave unrun a case the clause reaches: call_response's two TTLs are
independent and either may be the longer, and <name>.cfg sets one ordering.
`<name>.scope.<label>.cfg` is <name>.cfg's run again under other constants:
the same SPECIFICATION, the same INVARIANTs and PROPERTYs and no other, at
least one constant set differently, and no `MUST VIOLATE:`. TLC must find no
error, exactly as for <name>.cfg. It adds the scope to a tie's verdict, not
the claim: a note that says "in either order" names the scope config that
runs the other order.

  * A scope config that sets every constant as <name>.cfg does is the same
    run twice, and is refused; one that checks less, or more, or another
    SPECIFICATION, is some other model's config, and is refused.
  * Rule (2) is not read against it: its checks are <name>.cfg's, so it
    roots nothing the main config does not.

WHAT A PASSING SCOPE RUN DOES NOT SAY: that its constants select an engine
the clause admits. This reader gives no constant a meaning; the comment
beside the constants says which engine they mean, as a teeth config's
comment says why its property breaks. A scope config whose constants select
an engine the clause rules out, and that passes, is a teeth config missing
its `MUST VIOLATE:`, and only the comment can tell a reader so.

THE READERS ARE PROVEN ABLE TO FIRE before they are trusted with a model:
`_selftest` runs first, on modules and configs written here, and a reader that
gets one wrong stops the lane.
"""
from __future__ import annotations

import glob
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402

# An operator definition at column 0, with or without parameters.
_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:\([^)]*\))?[ \t]*==", re.M)

# The .cfg statements that put a formula under check, and the one name each
# carries in this lane's configs.
_CHECKING = re.compile(r"^[ \t]*(?:INVARIANTS?|PROPERTY|PROPERTIES)\b(.*)$", re.M)

# The teeth declaration, a comment line of its own.
_MUST_VIOLATE = re.compile(
    r"^\\\*[ \t]*MUST VIOLATE:[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*$", re.M)

_TEETH = ".teeth."
_PROBE = ".probe."
_SCOPE = ".scope."
_PROBE_NAME = "probe__"

# The .cfg statements that say WHICH ENGINE a run is of.
_ENGINE = re.compile(r"^[ \t]*(CONSTANTS?|SPECIFICATION)\b(.*)$", re.M)


def _code(text: str, strings: bool = False) -> str:
    """Module or config text with comments blanked, and string literals too
    unless `strings` is set.

    `\\*` runs to the end of its line; `(* ... *)` nests, and a `\\*` inside one
    is ordinary comment text (every header line here is its own block, and
    several quote the tag form). Newlines are kept, so column 0 stays column 0.
    A string is kept where its VALUE is what is being read: a constant set to
    "step" and one set to "read" are two engines.
    """
    out: list[str] = []
    depth = 0
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        ch = text[i]
        if depth:
            if two == "(*":
                depth += 1
                i += 2
                out.append("  ")
            elif two == "*)":
                depth -= 1
                i += 2
                out.append("  ")
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
        elif two == "(*":
            depth = 1
            i += 2
            out.append("  ")
        elif two == "\\*":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif ch == '"':
            start = i
            i += 1
            while i < n and text[i] not in '"\n':
                i += 2 if text[i] == "\\" and i + 1 < n else 1
            if i < n and text[i] == '"':
                i += 1
            i = min(i, n)
            out.append(text[start:i] if strings else " " * (i - start))
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _definitions(code: str) -> dict[str, str]:
    """name -> body, for every operator defined at column 0. A body runs to the
    next definition, so it may take in a declaration that follows it; that adds
    references and removes none."""
    marks = [(m.group(1), m.start(), m.end()) for m in _DEF.finditer(code)]
    bodies: dict[str, str] = {}
    for i, (name, _, end) in enumerate(marks):
        stop = marks[i + 1][1] if i + 1 < len(marks) else len(code)
        bodies[name] = code[end:stop]
    return bodies


def _names_in(text: str, names: set[str]) -> set[str]:
    """The members of `names` that `text` refers to. A subscript is a
    reference: `WF_vars(A)`, `[][Next]_vars` and `<<A>>_vars` all name `vars`,
    and none of them is the identifier a plain tokeniser would read."""
    found: set[str] = set()
    for name in names:
        n = re.escape(name)
        if (re.search(r"(?<![A-Za-z0-9_])(?:(?:WF|SF)_)?" + n + r"(?![A-Za-z0-9_])", text)
                or re.search(r"(?<=[\]>])_" + n + r"(?![A-Za-z0-9_])", text)):
            found.add(name)
    return found


def _checked(cfg_code: str) -> list[str]:
    """Every name a config puts under check, in order."""
    return [w for m in _CHECKING.finditer(cfg_code) for w in m.group(1).split()]


def unchecked(tla: str, cfg: str, probed: tuple[str, ...] = ()) -> list[str]:
    """What is wrong with this model before TLC is asked anything: one line per
    finding, empty when the .cfg checks something and every definition is
    reachable from it. `probed` is the target of each probe config beside the
    .cfg: a root too, if it is a `probe__*` definition and only then."""
    findings: list[str] = []
    cfg_code = _code(cfg)
    if not _checked(cfg_code):
        findings.append("the .cfg names no INVARIANT and no PROPERTY — TLC would "
                        "check deadlock freedom and nothing else")
    bodies = _definitions(_code(tla))
    names = set(bodies)
    live = _names_in(cfg_code, names)
    live |= {p for p in probed if p in names and p.startswith(_PROBE_NAME)}
    frontier = list(live)
    while frontier:
        for ref in _names_in(bodies[frontier.pop()], names) - live:
            live.add(ref)
            frontier.append(ref)
    for name in sorted(names - live):
        if name.startswith("gap__"):
            continue
        findings.append(f"`{name}` is defined and reachable from nothing the .cfg "
                        f"names — if it is a property, TLC never evaluates it")
    return findings


def _engine(cfg: str) -> tuple[frozenset[str], list[str]]:
    """(the engine a config selects, what could not be read of it). The engine
    is every CONSTANT assignment and the SPECIFICATION, one statement a line,
    with no whitespace: two configs select one engine exactly when these sets
    are equal. A keyword with its assignments on the lines below it is refused,
    because read this way it would compare equal to anything."""
    found: set[str] = set()
    problems: list[str] = []
    for m in _ENGINE.finditer(_code(cfg, strings=True)):
        keyword = "SPECIFICATION" if m.group(1) == "SPECIFICATION" else "CONSTANT"
        rest = "".join(m.group(2).split())
        if not rest or (keyword == "CONSTANT" and "=" not in rest
                        and "<-" not in rest):
            problems.append(f"a `{m.group(1)}` line with nothing assigned on the "
                            f"line itself — this reader takes one statement a "
                            f"line and cannot say which engine this is")
        found.add(f"{keyword} {rest}")
    if not any(f.startswith("SPECIFICATION ") for f in found):
        problems.append("no SPECIFICATION line — this reader cannot say which "
                        "engine this is")
    return frozenset(found), problems


def _declared_target(tla: str, cfg: str, kind: str) -> tuple[str | None, list[str]]:
    """What teeth and probes share: one `MUST VIOLATE:` line, that property and
    no other under check, and the property defined. The target is None when
    the config declares none, or more than one."""
    declared = _MUST_VIOLATE.findall(cfg)
    checked = _checked(_code(cfg))
    problems: list[str] = []
    if len(declared) != 1:
        problems.append(f"{len(declared)} `MUST VIOLATE:` line(s), wanted one — a "
                        f"{kind} config says which property its run must break")
        return None, problems
    target = declared[0]
    if checked != [target]:
        problems.append(f"it declares `{target}` and puts {checked} under check — "
                        f"with a second property beside it, a violation would "
                        f"not say whose")
    if target not in _definitions(_code(tla)):
        problems.append(f"`{target}` is not defined in the module")
    return target, problems


def _same_engine(cfg: str, main: str) -> tuple[bool | None, list[str], list[str]]:
    """(whether `cfg` selects the engine `main` runs, the statements the two
    differ in, what could not be read). None when either could not be read."""
    mine, unread = _engine(cfg)
    theirs, unread_main = _engine(main)
    unread = unread + [f"<name>.cfg: {u}" for u in unread_main]
    if unread:
        return None, [], unread
    return mine == theirs, sorted(mine ^ theirs), []


def teeth_target(tla: str, cfg: str, main: str) -> tuple[str | None, list[str]]:
    """(the property a teeth config must see violated, what is wrong with the
    config). The property is None when the config cannot be run as teeth.
    `main` is the text of <name>.cfg, whose engine this one must NOT be."""
    target, problems = _declared_target(tla, cfg, "teeth")
    if target is None:
        return None, problems
    if target.startswith(_PROBE_NAME):
        problems.append(f"`{target}` is a probe: it says the clause's behaviour "
                        f"never happens, and the config that breaks it is a "
                        f"`{_PROBE}` one, in the clause's engine")
    same, _, unread = _same_engine(cfg, main)
    problems += unread
    if same:
        problems.append("it selects the engine <name>.cfg runs — the same "
                        "constants and SPECIFICATION — so a violation here is a "
                        "finding against the model, not teeth")
    return (None if problems else target), problems


def probe_target(tla: str, cfg: str, main: str) -> tuple[str | None, list[str]]:
    """(the `probe__*` property a probe config must see violated, what is wrong
    with the config). The property is None when the config cannot be run as a
    probe. `main` is the text of <name>.cfg, whose engine this one MUST be."""
    target, problems = _declared_target(tla, cfg, "probe")
    if target is None:
        return None, problems
    if not target.startswith(_PROBE_NAME):
        problems.append(f"`{target}` is not a `{_PROBE_NAME}*` definition — a probe "
                        f"breaks a property that says the clause's behaviour never "
                        f"happens, never one the clause states")
    same, differs, unread = _same_engine(cfg, main)
    problems += unread
    if same is False:
        problems.append(f"it does not select the engine <name>.cfg runs; the two "
                        f"differ in {differs} — what another engine reaches says "
                        f"nothing of the clause's")
    return (None if problems else target), problems


def scope_problems(cfg: str, main: str) -> list[str]:
    """What is wrong with a scope config; empty when it is <name>.cfg's run
    under other constants: the same SPECIFICATION, the same checks and no
    other, at least one constant set differently, no `MUST VIOLATE:`. `main`
    is the text of <name>.cfg."""
    problems: list[str] = []
    declared = _MUST_VIOLATE.findall(cfg)
    if declared:
        problems.append(f"it declares `MUST VIOLATE: {declared[0]}` — a scope "
                        f"config runs the clause's engine and must pass; a run "
                        f"that must break a property is a `{_TEETH}` or "
                        f"`{_PROBE}` config")
    checked = _checked(_code(cfg))
    wanted = _checked(_code(main))
    if sorted(checked) != sorted(wanted):
        problems.append(f"it puts {checked} under check where <name>.cfg puts "
                        f"{wanted} — a scope is the same checks under other "
                        f"constants, not another model")
    same, differs, unread = _same_engine(cfg, main)
    problems += unread
    if same:
        problems.append("it sets every constant as <name>.cfg does — the same "
                        "scope run twice adds nothing")
    elif same is False:
        specs = [s for s in differs if s.startswith("SPECIFICATION ")]
        if specs:
            problems.append(f"its SPECIFICATION is not <name>.cfg's ({specs}) — "
                            f"another behaviour spec is another model")
    return problems


_SELFTEST_TLA = """---- MODULE m ----
(* a header that quotes `\\* @spec [ID]` and names p_dead in prose *)
EXTENDS Naturals
\\* @spec [X.1]
VARIABLE x
\\* @spec [X.1]
vars == << x >>
\\* @spec [X.1]
Init == x = 0
\\* @spec [X.1]
Step(n) == x' = x + n
\\* @spec [X.1]
Next == Step(1)
\\* @spec [X.1]
Spec == Init /\\ [][Next]_vars /\\ WF_vars(Next)
\\* @derives [X.1]
p_live == x >= 0
\\* @derives [X.1]  p_live is named here, in a comment, and "p_dead" in a string
p_dead == x # "p_dead"
\\* @gap [X.1]
gap__x_1_not_modelled == TRUE
====
"""


def _selftest() -> list[str]:
    """The readers against modules and configs whose answer is known. Returns
    what they got wrong; empty means a dropped property is told from a checked
    one, and a teeth config that names its target from one that does not."""
    wrong: list[str] = []

    def expect(label: str, cfg: str, want: list[str]) -> None:
        got = sorted(f.split("`")[1] if "`" in f else "NO-PROPERTY"
                     for f in unchecked(_SELFTEST_TLA, cfg))
        if got != sorted(want):
            wrong.append(f"{label}: wanted {sorted(want)}, read {got}")

    expect("a property dropped from the .cfg is reported",
           "SPECIFICATION Spec\nINVARIANT p_live\n", ["p_dead"])
    expect("a property named in the .cfg is not",
           "SPECIFICATION Spec\nINVARIANT p_live\nPROPERTY p_dead\n", [])
    expect("a name in a .cfg comment does not count",
           "SPECIFICATION Spec\nINVARIANT p_live\n\\* PROPERTY p_dead\n", ["p_dead"])
    expect("a .cfg that checks nothing is reported, with everything it leaves dead",
           "SPECIFICATION Spec\n", ["NO-PROPERTY", "p_dead", "p_live"])
    expect("with no SPECIFICATION nothing is reachable",
           "INVARIANT p_live\n",
           ["Init", "Next", "Spec", "Step", "p_dead", "vars"])

    # The clause's engine, and another: K is 1 in <name>.cfg and 2 in teeth.
    main = "CONSTANT K = 1\nSPECIFICATION Spec\nINVARIANT p_live\n"
    other = "CONSTANT K = 2\nSPECIFICATION Spec\n"
    probed = _SELFTEST_TLA.replace(
        "====\n", "\\* @probe\nprobe__x_twice == x < 2\n====\n")

    def teeth(label: str, cfg: str, want: str | None,
              module: str = _SELFTEST_TLA, beside: str = main) -> None:
        got, _ = teeth_target(module, cfg, beside)
        if got != want:
            wrong.append(f"teeth, {label}: wanted {want!r}, read {got!r}")

    teeth("one declaration, one property, the same name, another engine",
          "\\* MUST VIOLATE: p_live\n" + other + "INVARIANT p_live\n", "p_live")
    teeth("no declaration", other + "INVARIANT p_live\n", None)
    teeth("the declaration names one property and the config checks another",
          "\\* MUST VIOLATE: p_dead\n" + other + "INVARIANT p_live\n", None)
    teeth("a second property beside the target",
          "\\* MUST VIOLATE: p_live\n" + other + "INVARIANT p_live\n"
          "PROPERTY p_dead\n", None)
    teeth("a target the module does not define",
          "\\* MUST VIOLATE: p_gone\n" + other + "INVARIANT p_gone\n", None)
    teeth("a declaration inside prose is not one",
          "\\* the run below MUST VIOLATE: p_live\n" + other
          + "INVARIANT p_live\n", None)
    teeth("the engine of <name>.cfg is not teeth",
          "\\* MUST VIOLATE: p_live\n" + main, None)
    teeth("spacing and a comment do not make a second engine",
          "\\* MUST VIOLATE: p_live\nCONSTANT  K=1   \\* K = 2\n"
          "SPECIFICATION   Spec\nINVARIANT p_live\n", None)
    teeth("a string's value does",
          '\\* MUST VIOLATE: p_live\nCONSTANT M = "read"\nSPECIFICATION Spec\n'
          "INVARIANT p_live\n", "p_live",
          beside='CONSTANT M = "step"\nSPECIFICATION Spec\nINVARIANT p_live\n')
    teeth("a constant assigned on the line below cannot be read",
          "\\* MUST VIOLATE: p_live\nCONSTANTS\n  K = 2\nSPECIFICATION Spec\n"
          "INVARIANT p_live\n", None)
    teeth("a probe property is not teeth",
          "\\* MUST VIOLATE: probe__x_twice\n" + other
          + "INVARIANT probe__x_twice\n", None, module=probed)

    def probe(label: str, cfg: str, want: str | None) -> None:
        got, _ = probe_target(probed, cfg, main)
        if got != want:
            wrong.append(f"probe, {label}: wanted {want!r}, read {got!r}")

    probe("the engine of <name>.cfg, one probe property",
          "\\* MUST VIOLATE: probe__x_twice\nCONSTANT K = 1\nSPECIFICATION Spec\n"
          "INVARIANT probe__x_twice\n", "probe__x_twice")
    probe("another engine is not a probe of this one",
          "\\* MUST VIOLATE: probe__x_twice\n" + other
          + "INVARIANT probe__x_twice\n", None)
    probe("a property the clause states is not a probe",
          "\\* MUST VIOLATE: p_live\nCONSTANT K = 1\nSPECIFICATION Spec\n"
          "INVARIANT p_live\n", None)
    probe("no declaration",
          "CONSTANT K = 1\nSPECIFICATION Spec\nINVARIANT probe__x_twice\n", None)

    def rooted(label: str, probes: tuple[str, ...], want: list[str]) -> None:
        got = sorted(f.split("`")[1] for f in unchecked(
            probed, "SPECIFICATION Spec\nINVARIANT p_live\n", probes))
        if got != sorted(want):
            wrong.append(f"roots, {label}: wanted {sorted(want)}, read {got}")

    rooted("a probe no config names is dead text", (),
           ["p_dead", "probe__x_twice"])
    rooted("a probe a config names is a root", ("probe__x_twice",), ["p_dead"])
    rooted("a probe config roots a probe and nothing else",
           ("p_dead", "probe__x_twice"), ["p_dead"])

    # The clause's engine in another scope: K is 1 in <name>.cfg and 2 here.
    def scope(label: str, cfg: str, want_ok: bool) -> None:
        got = not scope_problems(cfg, main)
        if got != want_ok:
            wrong.append(f"scope, {label}: wanted "
                         f"{'ok' if want_ok else 'refused'}, read "
                         f"{'ok' if got else 'refused'}")

    scope("<name>.cfg's checks under one constant changed",
          "CONSTANT K = 2\nSPECIFICATION Spec\nINVARIANT p_live\n", True)
    scope("every constant as <name>.cfg sets it",
          "CONSTANT K = 1\nSPECIFICATION Spec\nINVARIANT p_live\n", False)
    scope("spacing and a comment do not make another scope",
          "CONSTANT  K=1   \\* K = 2\nSPECIFICATION   Spec\nINVARIANT p_live\n",
          False)
    scope("a MUST VIOLATE line",
          "\\* MUST VIOLATE: p_live\nCONSTANT K = 2\nSPECIFICATION Spec\n"
          "INVARIANT p_live\n", False)
    scope("one check fewer",
          "CONSTANT K = 2\nSPECIFICATION Spec\n", False)
    scope("one check more",
          "CONSTANT K = 2\nSPECIFICATION Spec\nINVARIANT p_live\n"
          "PROPERTY p_dead\n", False)
    scope("another SPECIFICATION",
          "CONSTANT K = 2\nSPECIFICATION Init\nINVARIANT p_live\n", False)
    scope("a constant assigned on the line below cannot be read",
          "CONSTANTS\n  K = 2\nSPECIFICATION Spec\nINVARIANT p_live\n", False)
    return wrong


def _tlc(jar: str, metadir: str, cfg: Path, model: str) -> tuple[int, str]:
    # -metadir keeps TLC's states/ off the read-only /ds mount; SANY resolves
    # the module (+ TLA+ std modules) from the jar + the .tla's dir.
    proc = subprocess.run(
        ["java", "-cp", jar, "tlc2.TLC", "-metadir", metadir,
         "-config", str(cfg), model],
        capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def _tail(out: str) -> None:
    for line in out.splitlines()[-30:]:
        print(f"  | {line}")


# What TLC says was violated, and the step each state of its counterexample was
# reached by: `Error: ...`, `State <n>: <action ...>`, and the `Back to state`
# that closes a liveness counterexample's loop.
_VERDICT_LINE = re.compile(r"^(?:Error: |State \d+: |Back to state )")


def _counterexample(out: str) -> None:
    """The violation a teeth run ended in, as TLC reported it. A teeth config
    passes on ANY violation of its one property, and its comment says which
    behaviour it expects; printing the trace's steps is what lets a reader hold
    the one against the other."""
    for line in out.splitlines():
        if _VERDICT_LINE.match(line):
            print(f"  | {line}")


def main(argv: list[str]) -> int:
    # IDRISARM1 — amd64 only.
    refused = formal_arch.refuse_off_amd64("tla")
    if refused is not None:
        return refused

    wrong = _selftest()
    if wrong:
        print("tla: the readers failed their own fixtures, so their silence on a "
              "model would mean nothing:", file=sys.stderr)
        for w in wrong:
            print(f"  {w}", file=sys.stderr)
        return 2

    d = Path(argv[1] if len(argv) > 1 else "formal/tla")
    jar = os.environ.get("TLA_JAR", "/opt/tla/tla2tools.jar")
    models = sorted(glob.glob(str(d / "*.tla")))
    if not models:
        print(f"tla: no .tla models in {d}", file=sys.stderr)
        return 2
    rc = 0
    scopes_run = 0
    teeth_run = 0
    probes_run = 0
    with tempfile.TemporaryDirectory(prefix="ds-tla.") as work:
        for m in models:
            name = Path(m).stem
            cfg = d / f"{name}.cfg"
            text = Path(m).read_text(encoding="utf-8")
            print(f"== {m} ==")
            if not cfg.is_file():
                print(f"  {name}  FAIL — missing {name}.cfg")
                rc = 1
                continue
            main_cfg = cfg.read_text(encoding="utf-8")

            # The probe configs are read before anything runs: the target of a
            # well-formed one is a root of the reachability rule.
            probes: list[tuple[str, str, str]] = []
            for pcfg in sorted(glob.glob(str(d / f"{name}{_PROBE}*.cfg"))):
                label = Path(pcfg).name[len(name) + len(_PROBE):-len(".cfg")]
                target, problems = probe_target(
                    text, Path(pcfg).read_text(encoding="utf-8"), main_cfg)
                if target is None:
                    print(f"  {name}  probe `{label}`  FAIL — {Path(pcfg).name}:")
                    for p in problems:
                        print(f"  | {p}")
                    rc = 1
                    continue
                probes.append((label, pcfg, target))

            # The scope configs are read before anything runs too: a malformed
            # one is some other model's config, not this one run again.
            scopes: list[tuple[str, str]] = []
            for scfg in sorted(glob.glob(str(d / f"{name}{_SCOPE}*.cfg"))):
                label = Path(scfg).name[len(name) + len(_SCOPE):-len(".cfg")]
                problems = scope_problems(
                    Path(scfg).read_text(encoding="utf-8"), main_cfg)
                if problems:
                    print(f"  {name}  scope `{label}`  FAIL — {Path(scfg).name}:")
                    for p in problems:
                        print(f"  | {p}")
                    rc = 1
                    continue
                scopes.append((label, scfg))

            findings = unchecked(text, main_cfg, tuple(t for _, _, t in probes))
            if findings:
                print(f"  {name}  FAIL — {name}.cfg leaves part of the model unchecked:")
                for f in findings:
                    print(f"  | {f}")
                rc = 1
                continue
            code, out = _tlc(jar, os.path.join(work, f"meta.{name}"), cfg, m)
            if code == 0 and "No error has been found" in out:
                for line in out.splitlines():
                    if "states generated" in line or "No error has been found" in line:
                        print(f"  {line}")
                print(f"  {name}  PASS")
            else:
                print(f"  {name}  FAIL")
                _tail(out)
                rc = 1

            for label, scfg in scopes:
                scopes_run += 1
                code, out = _tlc(jar, os.path.join(work, f"meta.{name}.scope.{label}"),
                                 Path(scfg), m)
                if code == 0 and "No error has been found" in out:
                    for line in out.splitlines():
                        if "states generated" in line:
                            print(f"  {line}")
                    print(f"  {name}  scope `{label}`  PASS")
                else:
                    print(f"  {name}  scope `{label}`  FAIL — the checks of "
                          f"{name}.cfg do not hold in this scope:")
                    _tail(out)
                    rc = 1

            for tcfg in sorted(glob.glob(str(d / f"{name}{_TEETH}*.cfg"))):
                label = Path(tcfg).name[len(name) + len(_TEETH):-len(".cfg")]
                target, problems = teeth_target(
                    text, Path(tcfg).read_text(encoding="utf-8"), main_cfg)
                if target is None:
                    print(f"  {name}  teeth `{label}`  FAIL — {Path(tcfg).name}:")
                    for p in problems:
                        print(f"  | {p}")
                    rc = 1
                    continue
                teeth_run += 1
                code, out = _tlc(jar, os.path.join(work, f"meta.{name}.{label}"),
                                 Path(tcfg), m)
                if code != 0 and "violated" in out and "No error has been found" not in out:
                    print(f"  {name}  teeth `{label}`  PASS — `{target}` is "
                          f"violated, as it must be")
                    _counterexample(out)
                elif code == 0:
                    print(f"  {name}  teeth `{label}`  FAIL — `{target}` HOLDS of "
                          f"the engine this config selects, so it excludes nothing")
                    rc = 1
                else:
                    print(f"  {name}  teeth `{label}`  FAIL — TLC ended without "
                          f"reporting a violation of `{target}`:")
                    _tail(out)
                    rc = 1

            for label, pcfg, target in probes:
                probes_run += 1
                code, out = _tlc(jar, os.path.join(work, f"meta.{name}.probe.{label}"),
                                 Path(pcfg), m)
                if code != 0 and "violated" in out and "No error has been found" not in out:
                    print(f"  {name}  probe `{label}`  PASS — `{target}` is "
                          f"violated: the clause's engine does what it says never "
                          f"happens")
                    _counterexample(out)
                elif code == 0:
                    print(f"  {name}  probe `{label}`  FAIL — `{target}` HOLDS: the "
                          f"clause's engine never does what the clause rules, and "
                          f"a property about it holds of nothing")
                    rc = 1
                else:
                    print(f"  {name}  probe `{label}`  FAIL — TLC ended without "
                          f"reporting a violation of `{target}`:")
                    _tail(out)
                    rc = 1

    # A .cfg nothing above ran names properties nothing checks.
    stems = {Path(m).stem for m in models}
    for cfg in sorted(glob.glob(str(d / "*.cfg"))):
        base = Path(cfg).name[:-len(".cfg")]
        kind = next((k for k in (_TEETH, _PROBE, _SCOPE) if k in base), None)
        owner = base.split(kind, 1)[0] if kind else base
        if owner not in stems or (kind is None and "." in base):
            print(f"== {cfg} ==\n  FAIL — not <model>.cfg, <model>.scope.<label>.cfg, "
                  f"<model>.teeth.<label>.cfg or <model>.probe.<label>.cfg for a "
                  f"model in {d}; nothing runs it")
            rc = 1
    print(f"tla: {len(models)} model(s), {scopes_run} scope run(s), "
          f"{teeth_run} teeth run(s), {probes_run} probe run(s)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

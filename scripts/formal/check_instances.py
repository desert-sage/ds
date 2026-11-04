#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_instances.py [tla cfg idr] — the `instances` formal lane:
an instance one model draws and another executes is one instance.

The recipe behind formal.build's `instances.stamp`. formal/tla/tms_cascade.tla
draws two support graphs, chosen by its constant `iret_12__GRAPH`: the clause's
ranked instance (f2 <- {f1}, f2 <- {f4}, f3 <- {f2}; f1 and f4 base), which
tms_cascade.cfg runs, and the unfounded cycle (Q <- {P}, R <- {Q}, Q <- {R};
P base), which tms_cascade.teeth.cycle.cfg runs. formal/idris/Rete/Refcount.idr
carries both again as list literals, `iret_12_3__tla_js` and
`llog_2_5__witness_js`, and EXECUTES them: `iret_12_2__tla_retract_f1` and
`_both` are the ranked instance after one and after both base retractions,
`llog_2_5__witness_before`, `iret_12_2__witness_refcount` and
`llog_2_5__witness_well_founded` the cycle before and after P goes. The
[IRET.12.2] tie on `iret_12_2__no_unsupported_forever` cites that agreement.
Without this check the second copy is a transcription by hand:
edit either side and the two models stop describing one instance while every
gate stays green, the tla lane proving its instance and the idris lane the
other.

THE SAME INSTANCE, under a renaming DECLARED here and not derived -- the
Logician's reading; a renaming that drifts is a mismatch
and not a guess:

  * the justifications are equal as a set of (antecedent set, target) pairs:
    order in the Idris list and in the TLA+ set carries nothing, an antecedent
    list is read as a set, and a justification written twice on either side
    is reported;
  * every fact a justification or a base set names is in the fact set, on
    both sides, and the renaming is exactly the fact set, one natural a name;
  * every Idris theorem that executes the literal -- a column-0 signature that
    applies `iret_12_2__cascade` or `llog_2_5__well_founded` to it -- is a
    `RetractBase` history of the TLA+ module: its `base` argument is a subset
    of `iret_12__Base`, every application in one statement takes the same
    arguments, and its live set is `iret_12__Fact` less the base facts the
    scenario retracted. The witnesses are derived from the module, not listed
    here; a literal no theorem executes is reported, since then nothing runs
    the instance on the Idris side and the agreement the tie cites is of
    nothing.

WHAT IT READS, and nothing else: the `.tla`'s `iret_12__Fact`, `iret_12__Base`
and `iret_12__Justif`, each `IF iret_12__GRAPH = "<graph>" THEN <set> ELSE
<set>` with the ELSE branch the graph the `.cfg` sets; the `.idr`'s two list
literals, and every column-0 signature that applies the two fixpoints to them.
A definition it cannot find, or cannot read in that shape, is a REFUSAL (exit
2), never a pass: the reader is tied to the modules' present shape, and a
module that has moved out from under it says so instead of being passed over.

NOT A FORMAL METHOD, and it proves nothing about the clause: that the ranked
instance's count agrees with the obligation is `iret_12_2__tla_retract_f1` in
the idris lane and `tms_cascade.cfg`'s invariant in the tla lane. This holds
that the two lanes were run on one instance. The Alloy model of the trio,
tms_justification.als, draws no instance, so it has no side here.

PROVEN ABLE TO FIRE FIRST ([STYL.5.10.5]). `_selftest` runs the readers and the
comparison on excerpts written here, with a defect planted on each side -- an
antecedent moved in the module, an antecedent moved in the literal, the two
renamings swapped, a witness whose live set is no retraction history, a
witness whose base is not the module's, a witness reading the literal under
two sets of arguments, a fact outside the fact set on either side, a literal no
theorem executes, a justification written twice, a definition renamed away on
either side, a `.cfg` that selects the graph the IF tests or none -- and on a
permutation of both sides that is the same instance. A reader that gets one
wrong stops the lane.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import check_tla  # noqa: E402 — the one reader of a module's column-0 definitions

TLA = "formal/tla/tms_cascade.tla"
CFG = "formal/tla/tms_cascade.cfg"
IDR = "formal/idris/Rete/Refcount.idr"

GRAPH = "iret_12__GRAPH"
FACT, BASE, JUSTIF = "iret_12__Fact", "iret_12__Base", "iret_12__Justif"
FIXPOINTS = ("iret_12_2__cascade", "llog_2_5__well_founded")

# THE DECLARED HALF: which literal is which graph, and the renaming under which
# the two are one instance -- each TLA+ name's position in the module's own
# listing, from 1 on the ranked graph and from 0 on the cycle, as the literals
# were written. Two tables, not a rule that derives them: a renaming that
# drifts is a mismatch.
INSTANCES: dict[str, tuple[str, dict[str, int]]] = {
    "ranked": ("iret_12_3__tla_js", {"f1": 1, "f2": 2, "f3": 3, "f4": 4}),
    "cycle": ("llog_2_5__witness_js", {"P": 0, "Q": 1, "R": 2}),
}

Justif = tuple[frozenset, object]            # (antecedents, target); names, or naturals once renamed
Witness = tuple[str, list[int], list[int]]   # (theorem, base argument, live argument)
Graph = tuple[set[str], set[str], set[Justif], list[str]]  # (facts, base, justifications, written twice)


class Unreadable(Exception):
    """A module's shape has moved and this reader has not: a refusal."""


def _show(j: Justif) -> str:
    return f"{j[1]} <- {{{', '.join(sorted(map(str, j[0])))}}}"


# ---- the TLA+ side -----------------------------------------------------------

# One token: a string, `|->`, a bracket or a comma, a name. Whitespace is skipped.
_TOKEN = re.compile(r'\s*(?:("(?:[^"\\]|\\.)*")|(\|->)|([{}\[\],])|([A-Za-z_][A-Za-z0-9_]*))')

# `IF <const> = "<graph>" THEN <branch> ELSE <branch>`, and nothing else in the body.
_BRANCHES = re.compile(
    r'^\s*IF\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"\s*THEN\s*(.*?)\s*ELSE\s*(.*?)\s*$', re.S)

# A declaration at column 0 ends a definition's body: check_tla's bodies run to
# the next `==`, so a VARIABLE between two definitions is in the first's text.
_DECLARATION = re.compile(
    r"^(?:VARIABLES?|CONSTANTS?|ASSUME|THEOREM|LOCAL|INSTANCE|EXTENDS|={4,}|-{4,})\b", re.M)

# The .cfg's own graph: `CONSTANT iret_12__GRAPH = "<graph>"`, one statement a line.
_CFG_GRAPH = re.compile(r'^\s*CONSTANTS?\s+' + GRAPH + r'\s*=\s*"([^"]+)"', re.M)


def _tokens(text: str) -> list[str]:
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        m = _TOKEN.match(text, i)
        if m is None:
            if text[i:].strip() == "":
                break
            raise Unreadable(f"cannot read {text[i:i + 24].strip()!r}")
        out.append(next(g for g in m.groups() if g is not None))
        i = m.end()
    return out


def _value(toks: list[str], i: int) -> tuple[object, int]:
    """(value, next index): a string; a set `{ v, ... }` as ("set", [v, ...]);
    a record `[ name |-> v, ... ]` as ("rec", {name: v})."""
    if i >= len(toks):
        raise Unreadable("a set or record ends early")
    t = toks[i]
    if t.startswith('"'):
        return t[1:-1], i + 1
    if t == "{":
        items: list[object] = []
        i += 1
        while i < len(toks) and toks[i] != "}":
            v, i = _value(toks, i)
            items.append(v)
            if i < len(toks) and toks[i] == ",":
                i += 1
        if i >= len(toks):
            raise Unreadable("a `{` with no `}`")
        return ("set", items), i + 1
    if t == "[":
        rec: dict[str, object] = {}
        i += 1
        while i < len(toks) and toks[i] != "]":
            name = toks[i]
            if i + 1 >= len(toks) or toks[i + 1] != "|->":
                raise Unreadable(f"expected `<name> |->` in a record, read {toks[i:i + 2]}")
            v, i = _value(toks, i + 2)
            if name in rec:
                raise Unreadable(f"`{name}` twice in one record")
            rec[name] = v
            if i < len(toks) and toks[i] == ",":
                i += 1
        if i >= len(toks):
            raise Unreadable("a `[` with no `]`")
        return ("rec", rec), i + 1
    raise Unreadable(f"unexpected `{t}`")


def _one_value(text: str) -> object:
    toks = _tokens(text)
    v, i = _value(toks, 0)
    if i != len(toks):
        raise Unreadable(f"text after the set: {' '.join(toks[i:i + 6])!r}")
    return v


def _names(v: object, what: str) -> tuple[set[str], list[str]]:
    """A set of strings, and the names written twice in it."""
    if not (isinstance(v, tuple) and v[0] == "set" and all(isinstance(x, str) for x in v[1])):
        raise Unreadable(f"{what} is not a set of strings")
    seen: set[str] = set()
    twice: list[str] = []
    for x in v[1]:
        if x in seen:
            twice.append(x)
        seen.add(x)
    return seen, twice


def _justifs(v: object) -> tuple[set[Justif], list[str]]:
    """The justifications as (antecedent set, target) pairs, and what is
    written twice: a record, or an antecedent inside one."""
    if not (isinstance(v, tuple) and v[0] == "set"):
        raise Unreadable(f"{JUSTIF} is not a set")
    out: set[Justif] = set()
    twice: list[str] = []
    for item in v[1]:
        if not (isinstance(item, tuple) and item[0] == "rec"
                and set(item[1]) == {"ante", "target"}):
            raise Unreadable(f'{JUSTIF} holds something other than '
                             f'`[ ante |-> {{...}}, target |-> "..." ]`')
        ante, dup = _names(item[1]["ante"], "an `ante`")
        target = item[1]["target"]
        if not isinstance(target, str):
            raise Unreadable("a `target` is not a string")
        twice += [f"{a} in the antecedents of {target}" for a in dup]
        j: Justif = (frozenset(ante), target)
        if j in out:
            twice.append(_show(j))
        out.add(j)
    return out, twice


def cfg_graph(cfg: str) -> str:
    found = _CFG_GRAPH.findall(check_tla._code(cfg, strings=True))
    if len(found) != 1:
        raise Unreadable(f"the .cfg sets {GRAPH} {len(found)} time(s), one statement a "
                         f"line; wanted once")
    return found[0]


def tla_graphs(tla: str, cfg: str) -> dict[str, Graph]:
    """graph -> (facts, base, justifications, what is written twice), for the
    graph the module's IF tests and the graph the .cfg sets, its ELSE branch."""
    main = cfg_graph(cfg)
    bodies = check_tla._definitions(check_tla._code(tla, strings=True))
    branches: dict[str, dict[str, str]] = {}
    for name in (FACT, BASE, JUSTIF):
        if name not in bodies:
            raise Unreadable(f"`{name}` is not defined at column 0 of the module")
        body = bodies[name]
        cut = _DECLARATION.search(body)
        if cut:
            body = body[:cut.start()]
        m = _BRANCHES.match(body)
        if m is None or m.group(1) != GRAPH:
            raise Unreadable(f'`{name}` is not `IF {GRAPH} = "<graph>" THEN <set> ELSE <set>`')
        tested = m.group(2)
        if tested == main:
            raise Unreadable(f'`{name}` tests {GRAPH} = "{tested}", the graph the .cfg '
                             f'sets: no second graph to read')
        branches.setdefault(tested, {})[name] = m.group(3)
        branches.setdefault(main, {})[name] = m.group(4)
    out: dict[str, Graph] = {}
    for graph, defs in branches.items():
        if set(defs) != {FACT, BASE, JUSTIF}:
            raise Unreadable(f'graph "{graph}" is tested by {sorted(defs)} and not by the '
                             f'other definitions; the three do not draw the same graphs')
        facts, twice_f = _names(_one_value(defs[FACT]), FACT)
        base, twice_b = _names(_one_value(defs[BASE]), BASE)
        justif, twice_j = _justifs(_one_value(defs[JUSTIF]))
        twice = ([f"{FACT}: {x}" for x in twice_f] + [f"{BASE}: {x}" for x in twice_b]
                 + [f"{JUSTIF}: {x}" for x in twice_j])
        out[graph] = (facts, base, justif, twice)
    return out


# ---- the Idris side ----------------------------------------------------------

_IDR_BLOCK = re.compile(r"\{-.*?-\}", re.S)
_IDR_DOC = re.compile(r"^[ \t]*\|\|\|.*$", re.M)
_IDR_LINE_COMMENT = re.compile(r"--.*$", re.M)

# A column-0 signature, and a column-0 list literal, each on one logical line.
_SIG = re.compile(r"^([a-z][A-Za-z0-9_']*)\s*:\s*(.*)$")
_LIT = re.compile(r"^([a-z][A-Za-z0-9_']*)\s*=\s*\[(.*)\]\s*$")
_ENTRY = re.compile(r"\s*MkJustif\s*\[([^\[\]]*)\]\s*(\d+)\s*")
# A top-level comma: one not inside a `[...]`.
_TOP_COMMA = re.compile(r",(?![^\[]*\])")


def _idris_code(text: str) -> str:
    """The module without its comments; newlines kept, so column 0 stays
    column 0 and a logical line can be rebuilt."""
    text = _IDR_BLOCK.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    text = _IDR_DOC.sub("", text)
    return _IDR_LINE_COMMENT.sub("", text)


def _logical_lines(code: str) -> list[str]:
    """Top-level statements: a line at column 0 starts one, an indented line
    continues the one before it."""
    out: list[str] = []
    for line in code.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t" and out:
            out[-1] += " " + line.strip()
        else:
            out.append(line.rstrip())
    return out


def _ints(text: str, where: str) -> list[int]:
    items = [x.strip() for x in text.split(",")] if text.strip() else []
    if not all(re.fullmatch(r"\d+", x) for x in items):
        raise Unreadable(f"`{where}`: `[{text.strip()}]` is not a list of naturals")
    return [int(x) for x in items]


def idris_literal(lines: list[str], name: str) -> list[tuple[list[int], int]]:
    """`name = [MkJustif [a, ...] t, ...]`, as (antecedents, target) pairs in
    the order written."""
    hits = [m for ln in lines if (m := _LIT.match(ln)) and m.group(1) == name]
    if len(hits) != 1:
        raise Unreadable(f"`{name} = [...]` is defined {len(hits)} time(s) at column 0; "
                         f"wanted once")
    body = hits[0].group(2).strip()
    out: list[tuple[list[int], int]] = []
    for part in (_TOP_COMMA.split(body) if body else []):
        m = _ENTRY.fullmatch(part)
        if m is None:
            raise Unreadable(f"`{name}`: {part.strip()!r} is not `MkJustif [a, ...] t`")
        out.append((_ints(m.group(1), name), int(m.group(2))))
    return out


def idris_witnesses(lines: list[str], lit: str) -> tuple[list[Witness], list[str]]:
    """Every column-0 signature applying a fixpoint to `Rete.Refcount.<lit>`,
    with the base and live arguments it applies it to; and the statements
    whose applications disagree on them. The literal is matched qualified,
    as a signature must write it (an unqualified lowercase name in a type is
    an implicit)."""
    app = re.compile(r"\b(" + "|".join(map(re.escape, FIXPOINTS)) + r")\s*\[([^\[\]]*)\]\s*"
                     r"Rete\.Refcount\." + re.escape(lit) + r"(?![A-Za-z0-9_'])\s*\[([^\[\]]*)\]")
    found: list[Witness] = []
    problems: list[str] = []
    for ln in lines:
        m = _SIG.match(ln)
        if m is None:
            continue
        name, rest = m.group(1), m.group(2)
        apps = [(_ints(b, name), _ints(l, name)) for _, b, l in app.findall(rest)]
        if not apps:
            continue
        keys = {(frozenset(b), frozenset(l)) for b, l in apps}
        if len(keys) != 1:
            problems.append(f"`{name}` applies a fixpoint to `{lit}` under {len(keys)} sets of "
                            f"arguments: " + "; ".join(f"base {b} live {l}" for b, l in apps))
            continue
        found.append((name, apps[0][0], apps[0][1]))
    return found, problems


# ---- the comparison ----------------------------------------------------------

def compare(graph: str, lit: str, renaming: dict[str, int], tla: Graph,
            idr: list[tuple[list[int], int]], witnesses: list[Witness]) -> list[str]:
    """What keeps the two from being one instance; empty when nothing does."""
    facts, base, justif, twice = tla
    out = [f"{graph}: written twice in the module: {t}" for t in twice]
    named: set[str] = set()
    for ante, target in justif:
        named |= ante | {target}
    stop = [f"{graph}: {JUSTIF} names `{g}`, which is not in {FACT}" for g in sorted(named - facts)]
    stop += [f"{graph}: {BASE} names `{g}`, which is not in {FACT}" for g in sorted(base - facts)]
    if set(renaming) != facts:
        stop.append(f"{graph}: the renaming names {sorted(renaming)} and {FACT} is "
                    f"{sorted(facts)}")
    if len(set(renaming.values())) != len(renaming):
        stop.append(f"{graph}: two names renamed to one natural: {renaming}")
    if stop:
        return out + stop   # nothing below can be read under a renaming that is not one
    rn = renaming
    tla_set = {(frozenset(rn[a] for a in ante), rn[t]) for ante, t in justif}
    rfacts = {rn[f] for f in facts}
    rbase = {rn[f] for f in base}
    idr_set: set[Justif] = set()
    for ante, target in idr:
        if len(set(ante)) != len(ante):
            out.append(f"{graph}: `{lit}` writes an antecedent twice in MkJustif {ante} {target}")
        j: Justif = (frozenset(ante), target)
        if j in idr_set:
            out.append(f"{graph}: `{lit}` writes {_show(j)} twice")
        idr_set.add(j)
        for g in sorted(set(ante) | {target}):
            if g not in rfacts:
                out.append(f"{graph}: `{lit}` names {g}, which under the renaming is no fact "
                           f"of {FACT} ({sorted(rfacts)})")
    only_tla = [_show(j) for j in sorted(tla_set - idr_set, key=_show)]
    only_idr = [_show(j) for j in sorted(idr_set - tla_set, key=_show)]
    if only_tla or only_idr:
        out.append(f"{graph}: the justifications differ under the renaming -- in {JUSTIF} and "
                   f"not in `{lit}`: {only_tla or 'none'}; in `{lit}` and not in {JUSTIF}: "
                   f"{only_idr or 'none'}")
    if not witnesses:
        out.append(f"{graph}: no column-0 signature of the module applies "
                   f"{' or '.join(FIXPOINTS)} to `Rete.Refcount.{lit}`: the literal is "
                   f"executed by nothing")
    for name, wbase, wlive in witnesses:
        if len(set(wbase)) != len(wbase) or len(set(wlive)) != len(wlive):
            out.append(f"{graph}: `{name}` writes a fact twice, in base {wbase} or live {wlive}")
        if not set(wbase) <= rbase:
            out.append(f"{graph}: `{name}` takes base {sorted(wbase)}, not a subset of {BASE} "
                       f"under the renaming ({sorted(rbase)})")
            continue
        retracted = rbase - set(wbase)
        want = rfacts - retracted
        if set(wlive) != want:
            out.append(f"{graph}: `{name}` takes live {sorted(wlive)}; a RetractBase history "
                       f"of the module that retracts {sorted(retracted)} leaves {sorted(want)}")
    return out


def _check(tla: str, cfg: str, idr: str,
           instances: dict[str, tuple[str, dict[str, int]]] = INSTANCES
           ) -> tuple[list[str], list[str]]:
    """(findings, what was read), over the three texts. Raises Unreadable."""
    graphs = tla_graphs(tla, cfg)
    lines = _logical_lines(_idris_code(idr))
    findings: list[str] = []
    report: list[str] = []
    for graph in sorted(set(graphs) - set(instances)):
        findings.append(f"{graph}: the module draws this graph and no literal is declared "
                        f"for it here")
    for graph, (lit, renaming) in instances.items():
        if graph not in graphs:
            raise Unreadable(f'the module draws no graph "{graph}"; it draws {sorted(graphs)}')
        literal = idris_literal(lines, lit)
        witnesses, problems = idris_witnesses(lines, lit)
        facts, base, justif, _ = graphs[graph]
        report.append(f'{graph}: {FACT} {sorted(facts)}, {BASE} {sorted(base)}, {JUSTIF} '
                      f'{[_show(j) for j in sorted(justif, key=_show)]}; `{lit}` '
                      f'{[_show((frozenset(a), t)) for a, t in literal]} under '
                      f'{renaming}; executed by {[w for w, _, _ in witnesses] or "nothing"}')
        for name, wbase, wlive in witnesses:
            report.append(f"   `{name}`: base {wbase}, live {wlive}")
        findings += [f"{graph}: {p}" for p in problems]
        findings += compare(graph, lit, renaming, graphs[graph], literal, witnesses)
    return findings, report


# ---- proven able to fire -----------------------------------------------------

_SELFTEST_TLA = '''---- MODULE m ----
(* a header quoting `IF iret_12__GRAPH = "cycle"` and `MkJustif [9] 9` in prose *)
\\* @spec [IRET.12]
CONSTANT iret_12__GRAPH
\\* @spec [IRET.12]
iret_12__Fact ==
    IF iret_12__GRAPH = "cycle" THEN { "P", "Q", "R" } ELSE { "f1", "f2", "f3", "f4" }
\\* @spec [IRET.12]  base: { "f9" } in a comment is not a base fact
iret_12__Base ==
    IF iret_12__GRAPH = "cycle" THEN { "P" } ELSE { "f1", "f4" }
\\* @spec [IRET.12]
iret_12__Justif ==
    IF iret_12__GRAPH = "cycle"
    THEN { [ ante |-> { "P" }, target |-> "Q" ],
           [ ante |-> { "Q" }, target |-> "R" ],
           [ ante |-> { "R" }, target |-> "Q" ] }
    ELSE { [ ante |-> { "f1" }, target |-> "f2" ],
           [ ante |-> { "f4" }, target |-> "f2" ],
           [ ante |-> { "f2" }, target |-> "f3" ] }
\\* @spec [IRET.12]
VARIABLE iret_12__live
\\* @spec [IRET.12]
iret_12__vars == iret_12__live
====
'''

_SELFTEST_CFG = ('CONSTANT iret_12__ENGINE = "clause"\n'
                 'CONSTANT iret_12__GRAPH = "ranked"\n'
                 'SPECIFICATION iret_12__Spec\n')

_SELFTEST_IDR = '''module Rete.Refcount
%default total
--@spec [LLOG.2.5]
||| Facts: 0 is the base fact P; 1 is Q; 2 is R. `MkJustif [9] 9` in a doc line.
export
llog_2_5__witness_js : List Iret_12_1__justif
llog_2_5__witness_js = [MkJustif [0] 1, MkJustif [1] 2, MkJustif [2] 1]
--@derives [LLOG.2.5]
export
llog_2_5__witness_before : llog_2_5__well_founded [0] Rete.Refcount.llog_2_5__witness_js [0, 1, 2] = [0, 1, 2]
llog_2_5__witness_before = Refl
export
iret_12_2__witness_refcount : iret_12_2__cascade [] Rete.Refcount.llog_2_5__witness_js [1, 2] = [1, 2]
iret_12_2__witness_refcount = Refl
export
llog_2_5__witness_well_founded : llog_2_5__well_founded [] Rete.Refcount.llog_2_5__witness_js [1, 2] = []
llog_2_5__witness_well_founded = Refl
--@spec [IRET.12.3]
export
iret_12_3__tla_js : List Iret_12_1__justif
iret_12_3__tla_js = [MkJustif [1] 2, MkJustif [4] 2, MkJustif [2] 3]
--@derives [IRET.12.2]
export
iret_12_2__tla_retract_f1 : iret_12_2__cascade [4] Rete.Refcount.iret_12_3__tla_js [2, 3, 4] = llog_2_5__well_founded [4] Rete.Refcount.iret_12_3__tla_js [2, 3, 4]
iret_12_2__tla_retract_f1 = Refl
export
iret_12_2__tla_retract_both : iret_12_2__cascade [] Rete.Refcount.iret_12_3__tla_js [2, 3] =
  llog_2_5__well_founded [] Rete.Refcount.iret_12_3__tla_js [2, 3]
iret_12_2__tla_retract_both = Refl
export
iret_12_3__ranked_agree : (base : List Iret_12__fact) -> (js : List Iret_12_1__justif) ->
                          Iret_12__sub (iret_12_2__cascade base js live) (llog_2_5__well_founded base js univ)
iret_12_3__ranked_agree = go
  where
    go : Iret_12__sub (iret_12_2__cascade [9] Rete.Refcount.iret_12_3__tla_js [9]) [9]
'''


def _plant(text: str, old: str, new: str) -> str:
    """`text` with `old` replaced. A plant that finds nothing to replace is
    dead, and stops the self-test rather than pass over nothing."""
    if old not in text:
        raise AssertionError(f"dead plant: {old!r} is not in the fixture")
    return text.replace(old, new)


_F1 = ("iret_12_2__tla_retract_f1 : iret_12_2__cascade [4] Rete.Refcount.iret_12_3__tla_js "
       "[2, 3, 4] = llog_2_5__well_founded [4] Rete.Refcount.iret_12_3__tla_js [2, 3, 4]\n")
_BOTH = ("iret_12_2__tla_retract_both : iret_12_2__cascade [] Rete.Refcount.iret_12_3__tla_js "
         "[2, 3] =\n  llog_2_5__well_founded [] Rete.Refcount.iret_12_3__tla_js [2, 3]\n")
_RANKED_ELSE = ('    ELSE { [ ante |-> { "f1" }, target |-> "f2" ],\n'
                '           [ ante |-> { "f4" }, target |-> "f2" ],\n'
                '           [ ante |-> { "f2" }, target |-> "f3" ] }')


def _selftest() -> list[str]:
    """The readers and the comparison against fixtures whose answer is known.
    Returns what they got wrong; empty means a defective fixture on either
    side is reported and a permutation is not."""
    wrong: list[str] = []

    def expect(label: str, *, tla: str = _SELFTEST_TLA, cfg: str = _SELFTEST_CFG,
               idr: str = _SELFTEST_IDR, instances=INSTANCES,
               marks: tuple[str, ...] = (), refused: bool = False) -> None:
        try:
            got, _ = _check(tla, cfg, idr, instances)
        except Unreadable as e:
            if not refused:
                wrong.append(f"{label}: refused ({e}) where findings {list(marks)} were wanted")
            return
        except AssertionError as e:
            wrong.append(f"{label}: {e}")
            return
        if refused:
            wrong.append(f"{label}: read ({got}) where a refusal was wanted")
            return
        missing = [m for m in marks if not any(m in f for f in got)]
        if missing:
            wrong.append(f"{label}: wanted a finding saying {missing}, read {got}")
        if not marks and got:
            wrong.append(f"{label}: wanted no finding, read {got}")

    expect("the fixtures are one instance on both sides")
    expect("an antecedent moved in the module",
           tla=_plant(_SELFTEST_TLA, '[ ante |-> { "f4" }, target |-> "f2" ]',
                      '[ ante |-> { "f3" }, target |-> "f2" ]'),
           marks=("ranked: the justifications differ",))
    expect("an antecedent moved in the literal",
           idr=_plant(_SELFTEST_IDR, "MkJustif [4] 2", "MkJustif [3] 2"),
           marks=("ranked: the justifications differ",))
    expect("the two renamings swapped",
           instances={"ranked": (INSTANCES["ranked"][0], INSTANCES["cycle"][1]),
                      "cycle": (INSTANCES["cycle"][0], INSTANCES["ranked"][1])},
           marks=("ranked: the renaming names", "cycle: the renaming names"))
    expect("a witness whose live set is no retraction history",
           idr=_plant(_SELFTEST_IDR, _F1, _F1.replace("[2, 3, 4]", "[2, 4]")),
           marks=("`iret_12_2__tla_retract_f1` takes live [2, 4]; a RetractBase history",))
    expect("a witness whose base is not the module's",
           idr=_plant(_SELFTEST_IDR, _F1, _F1.replace("[4]", "[2]")),
           marks=("`iret_12_2__tla_retract_f1` takes base [2], not a subset",))
    expect("a witness reading the literal under two sets of arguments",
           idr=_plant(_SELFTEST_IDR, _F1,
                      _F1.replace("llog_2_5__well_founded [4]", "llog_2_5__well_founded []")),
           marks=("`iret_12_2__tla_retract_f1` applies a fixpoint to `iret_12_3__tla_js` "
                  "under 2 sets of arguments",))
    expect("a fact outside the fact set, in the module",
           tla=_plant(_SELFTEST_TLA, '[ ante |-> { "f1" }, target |-> "f2" ]',
                      '[ ante |-> { "f5" }, target |-> "f2" ]'),
           marks=("ranked: iret_12__Justif names `f5`, which is not in iret_12__Fact",))
    expect("a fact outside the fact set, in the literal",
           idr=_plant(_SELFTEST_IDR, "MkJustif [2] 3]", "MkJustif [2] 5]"),
           marks=("ranked: `iret_12_3__tla_js` names 5, which under the renaming is no fact",))
    expect("a literal no theorem executes",
           idr=_plant(_plant(_SELFTEST_IDR, _F1, ""), _BOTH, ""),
           marks=("ranked: no column-0 signature", "executed by nothing"))
    expect("a justification written twice in the literal",
           idr=_plant(_SELFTEST_IDR, "MkJustif [2] 3]", "MkJustif [2] 3, MkJustif [1] 2]"),
           marks=("ranked: `iret_12_3__tla_js` writes 2 <- {1} twice",))
    expect("a justification written twice in the module",
           tla=_plant(_SELFTEST_TLA, '[ ante |-> { "f2" }, target |-> "f3" ] }',
                      '[ ante |-> { "f2" }, target |-> "f3" ], '
                      '[ ante |-> { "f2" }, target |-> "f3" ] }'),
           marks=("ranked: written twice in the module: iret_12__Justif: f3 <- {f2}",))
    expect("a definition renamed away",
           tla=_plant(_SELFTEST_TLA, "iret_12__Justif ==", "iret_12__Justifs =="), refused=True)
    expect("a literal renamed away",
           idr=_plant(_SELFTEST_IDR, "iret_12_3__tla_js = [", "iret_12_3__tla_js_ = ["),
           refused=True)
    expect("a .cfg that selects the graph the IF tests",
           cfg=_plant(_SELFTEST_CFG, '"ranked"', '"cycle"'), refused=True)
    expect("a .cfg with no graph",
           cfg=_plant(_SELFTEST_CFG, 'CONSTANT iret_12__GRAPH = "ranked"\n', ""), refused=True)
    expect("a permutation of both sides is the same instance",
           tla=_plant(_SELFTEST_TLA, _RANKED_ELSE,
                      '    ELSE { [ target |-> "f3", ante |-> { "f2" } ],\n'
                      '           [ ante |-> { "f4" }, target |-> "f2" ],\n'
                      '           [ ante |-> { "f1" }, target |-> "f2" ] }'),
           idr=_plant(_plant(_SELFTEST_IDR,
                             "[MkJustif [1] 2, MkJustif [4] 2, MkJustif [2] 3]",
                             "[MkJustif [2] 3, MkJustif [4] 2, MkJustif [1] 2]"),
                      _F1, _F1.replace("[2, 3, 4] = ", "[4, 2, 3] = ")
                               .replace("iret_12_3__tla_js [2, 3, 4]\n",
                                        "iret_12_3__tla_js [3, 4, 2]\n")))
    return wrong


def main(argv: list[str]) -> int:
    wrong = _selftest()
    if wrong:
        print("== instances: the readers failed their own fixtures, so their silence on the "
              "models would mean nothing ==", file=sys.stderr)
        for w in wrong:
            print(f"   {w}", file=sys.stderr)
        return 2
    if len(argv) not in (1, 4):
        print("usage: check_instances.py [<tla> <cfg> <idr>]", file=sys.stderr)
        return 2
    paths = [Path(p) for p in (argv[1:4] if len(argv) == 4 else (TLA, CFG, IDR))]
    texts: list[str] = []
    for p in paths:
        if not p.is_file():
            print(f"== instances: REFUSED — {p} is not a file ==", file=sys.stderr)
            return 2
        texts.append(p.read_text(encoding="utf-8"))
    print(f"== instances: {paths[0]} against {paths[2]}, the ELSE graph from {paths[1]} ==")
    try:
        findings, report = _check(*texts)
    except Unreadable as e:
        print(f"== instances: REFUSED — {e} ==\n   The reader is tied to the modules' shape "
              f"(this recipe's docstring); a module that has moved is read again, not passed "
              f"over.", file=sys.stderr)
        return 2
    for line in report:
        print(f"   {line}")
    if findings:
        print(f"== instances: {len(findings)} finding(s) — the two lanes were not run on one "
              f"instance ==", file=sys.stderr)
        for f in findings:
            print(f"   FAIL: {f}", file=sys.stderr)
        return 1
    print(f"== instances: {len(INSTANCES)} graph(s), one instance on both sides ==")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

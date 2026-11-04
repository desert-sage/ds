# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""pytest configuration / hooks for the conformance harness.

`pytest_terminal_summary` lives here (not in test_conformance.py)
because pytest only collects hooks from conftest.py modules. It
emits the per-category summary plus the optional structured JSON
report: the runner's pass-or-fail report per test ([RTIM.7.1.1]).

The verdict comes from pytest's own reports, the only source that knows about
xfail. The corpus and the failure detail come from the `_RESULTS` list
test_conformance.py populates. The summary reconciles the two.
"""

import json
import os
from collections import Counter, defaultdict
from pathlib import Path


# No fixture is marked to fail as expected: a failure is fixed or filed, never
# recorded as expected, and `test_no_xfail.py` in scripts/private/tests/gates
# fails on a mark. The summary still counts an
# xfail or xpass pytest reports, so one could not pass unseen.
#
# `_RESULTS` knows nothing of xfail, and misses a driver that raised. So the
# verdict is pytest's and the category the param id's (`<category>/<id>`), and
# the summary reconciles the two.
_PYTEST_OUTCOME: dict[str, str] = {}
_NON_CORPUS: Counter = Counter()

# Always shown, so the shape of the line is stable run to run.
_CORE_COLUMNS = ("passed", "failed", "xfail", "skipped")
# Shown only when non-zero — both mean someone has to do something.
_RARE_COLUMNS = ("xpass", "error")
# The keys pytest files its own reports under; the source of its footer line.
_PYTEST_STAT_KEYS = ("passed", "failed", "error", "skipped", "xfailed", "xpassed")


def _param_id(nodeid: str) -> str | None:
    """`…/test_conformance.py::test_conformance[runtime/LFAC.2.5]` -> `runtime/LFAC.2.5`.

    None for a test that is not a corpus fixture. Keyed on the test, not on the
    brackets: any parametrised test has a `[...]` id, and the gate runs other
    files in this session."""
    head, sep, rest = nodeid.partition("::test_conformance[")
    if not sep or not head.endswith("test_conformance.py") or not rest.endswith("]"):
        return None
    return rest[:-1]


def pytest_runtest_logreport(report) -> None:
    if hasattr(report, "wasxfail"):
        # skipped => failed as expected. passed => XPASS, and only the
        # non-strict kind gets here: a strict XPASS arrives as a plain failure,
        # which is what we want — the ratchet firing has to be loud.
        outcome = "xfail" if report.skipped else "xpass"
    elif report.when == "call":
        outcome = report.outcome                 # passed / failed / skipped
    elif report.failed:
        outcome = "error"                        # blew up in setup or teardown
    elif report.when == "setup" and report.skipped:
        outcome = "skipped"                      # skipif — never reached the call
    else:
        return                                   # uneventful setup/teardown

    pid = _param_id(report.nodeid)
    if pid is None:
        _NON_CORPUS[outcome] += 1
    else:
        _PYTEST_OUTCOME[pid] = outcome


def pytest_terminal_summary(terminalreporter, exitstatus, config) -> None:
    try:
        from test_conformance import _RESULTS
    except Exception:
        # The reconcile below reports a harness that recorded nothing.
        _RESULTS = []
    if not _PYTEST_OUTCOME:
        return

    by_cat: dict[str, Counter] = defaultdict(Counter)
    for pid, outcome in _PYTEST_OUTCOME.items():
        by_cat[pid.split("/", 1)[0]][outcome] += 1

    total = Counter()
    for c in by_cat.values():
        total.update(c)

    columns = _CORE_COLUMNS + tuple(c for c in _RARE_COLUMNS if total[c])

    def _row(label: str, c: Counter) -> str:
        cells = "  ".join(f"{name}={c[name]:4d}" for name in columns)
        return f"  {label:11s}  {cells}"

    tr = terminalreporter
    tr.write_sep("=", "DS conformance summary")
    for cat in sorted(by_cat):
        tr.write_line(_row(cat, by_cat[cat]))
    tr.write_line(_row("TOTAL", total))

    counted = sum(total.values())
    non_corpus = sum(_NON_CORPUS.values())
    stats = getattr(tr, "stats", {}) or {}
    pytest_items = sum(len(stats.get(k, ())) for k in _PYTEST_STAT_KEYS)
    agree = (counted + non_corpus) == pytest_items
    tr.write_line(
        f"  {'reconcile':11s}  {counted} corpus + {non_corpus} harness self-test"
        f" = {counted + non_corpus}  vs pytest {pytest_items}"
        f"  {'OK' if agree else '** MISMATCH **'}"
    )

    recorded = {f"{t.category}/{t.id}" for t, _ in _RESULTS}
    unrecorded = sorted(set(_PYTEST_OUTCOME) - recorded)
    orphaned = sorted(recorded - set(_PYTEST_OUTCOME))
    if unrecorded:
        tr.write_line(
            f"  {'':11s}  !! {len(unrecorded)} ran but recorded NO harness "
            f"Result — run_test() raised before it could:"
        )
        for pid in unrecorded:
            tr.write_line(f"  {'':11s}       {pid}  [{_PYTEST_OUTCOME[pid]}]")
    if orphaned:
        tr.write_line(
            f"  {'':11s}  !! {len(orphaned)} harness Result(s) with no pytest "
            f"item: {', '.join(orphaned)}"
        )

    # Dead-rule hints ([LTES.9.7]). `_dead_rules_refusal` fails a fixture with a
    # dead rule it does not list, so these belong to fixtures that failed for
    # another reason.
    def _filter_dead(t, dead: list[str]) -> list[str]:
        expected = set(getattr(t, "dead_rules_expected", []) or [])
        return [d for d in dead if d not in expected]

    dead_hints: list[tuple[str, str, list[str]]] = [
        (t.category, t.id, filtered)
        for t, r in _RESULTS
        if r.artefacts and r.artefacts.get("coverage")
        and (filtered := _filter_dead(
            t, r.artefacts["coverage"]["dead"],
        ))
    ]
    if dead_hints:
        tr.write_sep("-", "dead-rule hints (LTES.9.7)")
        for cat, tid, dead in dead_hints:
            tr.write_line(f"  {cat}/{tid}: rules defined-but-never-fired: {dead}")

    out_path = os.environ.get("DS_CONFORMANCE_REPORT")
    if out_path:
        counts = _CORE_COLUMNS + _RARE_COLUMNS
        report = {
            "by_category": {
                cat: {k: c[k] for k in counts}
                for cat, c in by_cat.items()
            },
            "total": {k: total[k] for k in counts},
            # `unrecorded` names fixtures whose driver raised, which `tests`
            # cannot contain.
            "reconcile": {
                "corpus": counted,
                "harness_self_tests": non_corpus,
                "pytest_items": pytest_items,
                "agree": agree,
                "unrecorded": unrecorded,
                "orphaned": orphaned,
            },
            "tests": [
                {
                    "id": t.id,
                    "category": t.category,
                    "status": r.status,
                    # The harness's status, then pytest's verdict on the same
                    # item — they differ exactly where xfail is involved.
                    "outcome": _PYTEST_OUTCOME.get(f"{t.category}/{t.id}"),
                    "detail": r.detail,
                    "platform_dependent": t.platform_dependent,
                    "deprecated": t.deprecated,
                    "coverage": (
                        r.artefacts.get("coverage")
                        if r.artefacts else None
                    ),
                }
                for t, r in _RESULTS
            ],
        }
        Path(out_path).write_text(json.dumps(report, indent=2))
        tr.write_line(f"  → structured report written to {out_path}")

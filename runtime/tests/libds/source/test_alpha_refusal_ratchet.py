# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""No refusal in the alpha test path is causeless.

Inside `ds_rete_alpha_test_fact`, a `return false` is one of two things:

  * AN ANSWER. `cmp_vals` said the values do not satisfy the operator, or the
    regex did not match. The test was evaluated and the fact does not pass,
    and silent is right.
  * A REFUSAL. The test could not be evaluated at all: a slot index past the
    schema, a NULL compiled regex, a regex against a non-string, a NULL string
    pointer. Each is the artefact disagreeing with its own declaration, an
    EngineError ([RARC.5.3.3]), and is raised through `ds_rete_fault` first.

The first kind is recognised by its predicate, from a named set below; the
second is everything else, and must raise. The shape is
`test_soft_fail_sentinel_ratchet.py`'s.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
ALPHA_C = REPO / "runtime/src/libds/rete/alpha.c"

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")

_SIGNATURE = "bool ds_rete_alpha_test_fact("


def _strip(text: str) -> str:
    """Comments out, so prose naming `return false` is not counted."""
    return _LINE.sub(" ", _BLOCK.sub(" ", text))


def _function_body() -> str:
    """The body of `ds_rete_alpha_test_fact`, by brace matching: `cmp_vals`,
    above it, is full of `return false` answers."""
    text = _strip(ALPHA_C.read_text())
    start = text.index(_SIGNATURE)
    open_brace = text.index("{", start)
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace:i + 1]
    raise AssertionError("unbalanced braces in ds_rete_alpha_test_fact")


# A `return false` whose controlling predicate calls one of these is the test
# answering, not the engine refusing. A new entry claims a new call site is an
# answer.
_ANSWER_PREDICATES = ("cmp_vals(", "ds_re2_match_n(")

# Statement boundaries. `:` is in the set for the `case ...:` labels.
_BOUNDARY = ";{}:"


def _statements_before(body: str, at: int) -> tuple[str, str]:
    """The statement containing `at`, and the one before it.

    Statements, not a character window: a window wide enough to span a
    wrapped `if` reaches back into the previous arm of the switch. The
    controlling predicate is in the return's own statement; a raise is the
    statement before it.
    """
    cut = max((body.rfind(c, 0, at) for c in _BOUNDARY), default=-1)
    prev = max((body.rfind(c, 0, cut) for c in _BOUNDARY), default=-1)
    return (" ".join(body[cut + 1:at].split()),
            " ".join(body[prev + 1:cut].split()))


def test_every_alpha_refusal_carries_a_cause() -> None:
    body = _function_body()
    returns = [m.start() for m in re.finditer(r"\breturn\s+false\s*;", body)]
    assert returns, (
        "no `return false` found in ds_rete_alpha_test_fact — the extractor "
        "has stopped matching, which reports clean over nothing "
        "([STYL.5.10.5]). Check the signature constant and the brace walk.")

    answers, caused, causeless = 0, 0, []
    for at in returns:
        stmt, prev = _statements_before(body, at)
        if any(p in stmt for p in _ANSWER_PREDICATES):
            answers += 1
        elif "ds_rete_fault(" in prev:
            caused += 1
        else:
            causeless.append(stmt)

    assert answers, (
        "no `return false` in ds_rete_alpha_test_fact reads as a test ANSWER. "
        "Every arm looking like a refusal means the predicate names in "
        "_ANSWER_PREDICATES have gone stale, and the check is about to demand "
        "a fault for a fact that simply did not match.")

    assert not causeless, (
        f"{len(causeless)} refusal(s) in ds_rete_alpha_test_fact carry no "
        f"cause ({caused} do, {answers} are test answers). A refusal there is "
        f"a condition the test could not be evaluated on, and a malformed "
        f"artefact is an EngineError ([RARC.5.3.3]), not `this fact does not "
        f"match`. Raise through ds_rete_fault(ctx, NULL, DS_FAULT_*) with its "
        f"cause, or, if this is the test answering, add its predicate to "
        f"_ANSWER_PREDICATES:\n  "
        + "\n  ".join("..." + c for c in causeless))

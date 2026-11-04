# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Every declared-cap breach reaches the stream, or is named here.

A breach is a fact about the run, recorded in its fact stream: a
`ds_result_t` returned to the caller dies with the process.

Every site raising `DS_ERR_CONTRACT_BREACH` either emits first —
`ds_rete_emit_breach` on the rete side, `ds_recorder_emit_bounds_error` where
the DS engine is in hand — or appears in `UNWIRED` with the reason it does
not. A new raise site that does neither fails. The shape is
`test_soft_fail_sentinel_ratchet.py`'s.

⚠ Until `UNWIRED` holds only the deliberate entries, the absence of a
`DS_EV_BOUNDS_ERROR` does not mean no cap was breached.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SRC = REPO / "runtime/src"

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")

_RAISE = "DS_ERR_CONTRACT_BREACH"
_EMITTERS = ("ds_rete_emit_breach(", "ds_recorder_emit_bounds_error(")

# How far back a raise may look for its emit. Both sit inside the same `if`
# body, so this spans the emit call and its arguments and nothing further.
_WINDOW = 420

# Sites that cannot reach the recorder from where they stand, with the reason.
# A file leaves this list by being wired, never by being excused.
UNWIRED = {
    # `ds_cache_set(ds_cache_t *c, ...)` — the cache owns no engine pointer, so
    # its two raises have no emit beside them. They are recorded one level up:
    # the cache leaves the cap, limit and count in `breach_*`, and both callers
    # that run inside an engine -- bridge_cache_set (a rule's `cache`) and
    # ds_dispatcher_cache_set -- emit the BoundsError from those. The one
    # caller that does not is engine_cache_seed_store, the pre-run seed, which
    # records nothing. A syntactic check cannot follow that hop, so the count
    # stays; the scenarios 55_cache_capped and 57_cache_bytes_capped show the
    # record is made.
    "runtime/src/libds/cache.c": 2,
    # `intern_insert(ds_intern_t *t, ...)` — same, one level deeper.
    "runtime/src/libds/rete/intern.c": 2,
    # `lmem_add(ds_rete_beta_node_t *node, ...)` — a static helper on the node;
    # its callers have the engine and it does not.
    "runtime/src/libds/rete/beta.c": 1,
    # A pool-exhaustion breach raised from the adapter layer's RT guard.
    "runtime/src/libds/engine_rete_adapters.c": 1,
    # Not a missing emit: `pump_wcet_ns` cannot be checked before the fact, so
    # the status is deferred to the next `ds_rete_run` ([RTCT.7.3]), while the
    # record is emitted at the end of the pump that overran, at the two
    # `last_pump_breached` assignments. The raise site must not grow an emit.
    "runtime/src/libds/rete/engine.c": 1,
    # Not a missing emit either: fx_plan_judge refuses a FactExternal holding a
    # value over its slot's capacity before the first assert, and [NCBK.10.4]
    # and [LSTR.11.3] make the status the whole refusal, with no BoundsError:
    # the delivery was no input ([RFCS.24.1]). test_assert_external.c's
    # test_ncbk_10_4__a_value_over_capacity_refuses_the_record pins the silence.
    "runtime/src/libds/rfcs/codec.c": 1,
}


def _strip(text: str) -> str:
    return _LINE.sub(" ", _BLOCK.sub(" ", text))


def _sources() -> list[Path]:
    return sorted(p for p in SRC.rglob("*")
                  if p.suffix == ".c" and p.is_file())


def _raises() -> tuple[list[str], dict[str, int]]:
    """(wired sites, per-file count of unwired raises).

    The staleness guard is on the raise pattern: if it stops matching, every
    arm reports clean over nothing ([STYL.5.10.5]). A stale emitter name makes
    sites read as unwired, which fails on its own.
    """
    wired, unwired = [], {}
    for path in _sources():
        rel = path.relative_to(REPO).as_posix()
        text = _strip(path.read_text())
        for m in re.finditer(re.escape(_RAISE), text):
            before = text[max(0, m.start() - _WINDOW):m.start()]
            # A comparison is not a raise: the replayer reads a status the
            # engine already raised and recorded
            # (`r.status == DS_ERR_CONTRACT_BREACH`, rfcs/codec.c).
            if before.rstrip().endswith(("==", "!=")):
                continue
            if any(e in before for e in _EMITTERS):
                wired.append(rel)
            else:
                unwired[rel] = unwired.get(rel, 0) + 1
    return wired, unwired


def test_no_unrecorded_breach_site_appears() -> None:
    wired, unwired = _raises()
    assert wired or unwired, (
        "no raise of DS_ERR_CONTRACT_BREACH found anywhere under "
        "runtime/src — the raise pattern has gone stale and every arm below "
        "is a query over nothing ([STYL.5.10.5]).")

    new = {f: n for f, n in unwired.items()
           if n > UNWIRED.get(f, 0)}
    assert not new, (
        "a cap breach is raised without reaching the stream. The breach is a "
        "fact about the run and belongs in its fact stream; a ds_result_t "
        "dies with the process. Emit through "
        "ds_rete_emit_breach (rete side) or ds_recorder_emit_bounds_error "
        "(where the DS engine is in hand) before returning the status:\n  "
        + "\n  ".join(f"{f}: {n} unwired, {UNWIRED.get(f, 0)} allowed"
                      for f, n in sorted(new.items())))


def test_unwired_list_has_no_dead_entries() -> None:
    """A file that got wired leaves the list, so a stale entry cannot cover
    a new unwired site."""
    _, unwired = _raises()
    dead = sorted(f for f, n in UNWIRED.items() if unwired.get(f, 0) < n)
    assert not dead, (
        "UNWIRED over-counts — these files now emit more than the list "
        "allows for. Lower or delete the entry:\n  " + "\n  ".join(dead))

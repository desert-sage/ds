#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""rete_churn_fuzz — differential scale+churn fuzzer for the DS RETE engine.

Finds an incremental index or counter out of sync under assert/retract churn at
scale, losing or leaking a rule activation.

Drive one engine through randomized
interleaved assert / retract / identity-update / pump over a tiny key domain
(forcing joins, hash collisions, grow-boundary crossings and heavy negation
block/unblock churn), and after each settle compare it against a FRESH engine
loaded with only the currently-live input facts and pumped to a real fixpoint.
DS logical rules are confluent, so the two MUST agree; a difference is a lost
or leaked activation, regardless of which internal index broke.

Two references, both checked:
  * len(engine.facts)  — the engine's authoritative live count (hard signal).
  * full WM multiset reconstructed from the fact stream (precise: names the
    diverging facts), guarded by a self-check that the reconstruction total
    matches len(engine.facts) (so it never reports a stream artdefact as a bug).

Fixed rules span the shapes that bite this engine: a 2-pattern positive join,
single negation, the two-negation `run`-rule shape, a 3-pattern join,
positive+negation with the negation LAST, and a rule that consumes a DERIVED
fact (TMS cascade). Inputs include a mutable slot so re-assert exercises the
identity-update retract-replace path.

Run:  python rete_churn_fuzz.py [--seeds N|--seed S] [--ops K] [--keys D]
           [--shapes a,b,..] [--exclude-shapes x,y]   (default: all shapes)
Exit non-zero on any divergence; prints a per-signature summary so distinct
issues are easy to triage into todos.
"""
from __future__ import annotations

import argparse
import sys
import traceback

INPUT_SCHEMA_DS = """\
schema Item scope logical:
    k: Int key
    v: Int mutable
schema Sched scope logical:
    k: Int key
schema Blk scope logical:
    k: Int key
schema Disp scope logical:
    k: Int key
schema Tag scope logical:
    k: Int key
"""

# Derived schemas are ALWAYS declared (an unused one just stays empty), so any
# subset of shapes compiles — even one that excludes a rule another consumes
# (chain consumes Both). Only the RULES are shape-selectable.
DERIVED_SCHEMA_DS = """\
schema Both scope logical:
    k: Int key
schema Free scope logical:
    k: Int key
schema Run scope logical:
    k: Int key
schema Tri scope logical:
    k: Int key
schema Gate scope logical:
    k: Int key
schema Chain scope logical:
    k: Int key
"""

# One rule per shape over the shared inputs. A run may select a subset.
SHAPE_RULES = {
    # 2-pattern positive join.
    "both": """\
rule both_shape:
    Item i
    Sched s where s.k == i.k
->
    emit Both logical k: i.k
""",
    # single negation.
    "free": """\
rule free_shape:
    Item i
    no Disp d where d.k == i.k
->
    emit Free logical k: i.k
""",
    # two-negation join (pos; no A; no B; pos).
    "run": """\
rule run_shape:
    Sched x
    no Blk b where b.k == x.k
    no Disp d where d.k == x.k
    Item i where i.k == x.k
->
    emit Run logical k: x.k
""",
    # 3-pattern positive join (deeper beta chain).
    "tri": """\
rule tri_shape:
    Item i
    Sched s where s.k == i.k
    Tag t where t.k == i.k
->
    emit Tri logical k: i.k
""",
    # positive + positive + negation, with the NEGATION LAST.
    "gate": """\
rule gate_shape:
    Item i
    Sched s where s.k == i.k
    no Blk b where b.k == i.k
->
    emit Gate logical k: i.k
""",
    # consumes a DERIVED fact (Both) — TMS cascade / chained derivation.
    "chain": """\
rule chain_shape:
    Both b
    no Disp d where d.k == b.k
->
    emit Chain logical k: b.k
""",
}

# Declaration order = the canonical run order (determinism).
ALL_SHAPES = ("both", "free", "run", "tri", "gate", "chain")


def _build_program(shapes) -> str:
    """Assemble the .ds program: all schemas + the selected shapes' rules,
    under `use default` -- a source with no `use` line is a library
    ([LDIA.2.10.1]) and `dsc` refuses to build one."""
    return ("use default\n\n" + INPUT_SCHEMA_DS + DERIVED_SCHEMA_DS + "\n"
            + "\n".join(SHAPE_RULES[s] for s in shapes))


# Input (externally churned) schemas. `Item` carries a `mutable` slot so a
# re-assert on the same key exercises the retract-replace path (and the
# tracker reconstructs it from the FACT_ASSERT(new) + FACT_RETRACT(old) stream
# pair, input first per RFCS.6.7 -- keyed by handle, so the order is free); the
# rest are key-only (a same-key re-assert is a no-op). The cascade rules read
# only `.k`, so `Item`'s mutable `v` rides through the joins without changing
# the derived facts — the differential check still pins one-live-fact-per-key.
INPUT_SCHEMAS = ("Item", "Sched", "Blk", "Disp", "Tag")
MUT_SCHEMA = "Item"        # the one input schema with a mutable slot
MUT_VALUE_DOMAIN = 4       # small domain so re-asserts frequently change `v`


def _compile_dsc(shapes) -> bytes:
    # Through pyds.compile, the Mercury dsc.
    import pyds

    return pyds.compile(_build_program(shapes), file="rete_churn_fuzz.ds")


def _canon_slots(slots: dict) -> tuple:
    return tuple(sorted((str(k), v) for k, v in slots.items()))


class WmTracker:
    """Reconstructs an engine's full live fact set from its stream events.

    The event carries only a fact_id; schema+slots come from
    eng.facts[fact_id], which a retracted fact answers only inside its
    own retract callback. Key by fact_id; drop on retract."""

    def __init__(self, eng) -> None:
        self.eng = eng
        self.live: dict[object, tuple] = {}

    def callback(self, ev) -> None:
        kind = ev.kind
        # fact_modify is an in-place identity update (same handle, new slots) —
        # re-inspect, same as assert; otherwise the tracker keeps the stale
        # value and reports a false divergence on the mutable slot.
        if kind in ("fact_assert", "fact_modify"):
            h = ev.fact_id
            info = self.eng.facts[h]
            self.live[h] = (info.schema, _canon_slots(info.slots))
        elif kind == "fact_retract":
            self.live.pop(ev.fact_id, None)

    def multiset(self) -> dict:
        out: dict[tuple, int] = {}
        for v in self.live.values():
            out[v] = out.get(v, 0) + 1
        return out


def _engine_with_tracker(dsc: bytes):
    import pyds
    eng = pyds.Engine()
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    trk = WmTracker(eng)
    eng.on_event = trk.callback
    return eng, trk


def _pump_to_fixpoint(eng) -> None:
    # Settle until fact_count is stable across two consecutive pumps (a real
    # fixpoint), bounded. Both compared engines settle the same way, so a later
    # count difference is two distinct stable states — genuine non-confluence,
    # not under-pumping.
    last, stable = -1, 0
    for _ in range(256):
        eng.pump()
        n = len(eng.facts)
        if n == last:
            stable += 1
            if stable >= 2:
                return
        else:
            stable = 0
        last = n


def _from_scratch(dsc: bytes, model: dict) -> tuple[int, dict]:
    """Fresh engine with exactly the live input facts -> (fact_count, WM)."""
    eng, trk = _engine_with_tracker(dsc)
    try:
        for (schema, key), (_handle, kw) in model.items():
            eng.assert_(schema, k=key, **kw)
        _pump_to_fixpoint(eng)
        return len(eng.facts), trk.multiset()
    finally:
        # eng <-> trk is a reference cycle pyds.Engine's GC cannot reclaim, and
        # one reference engine is built per check, so it must close here.
        eng.close()


def _ms_total(ms: dict) -> int:
    return sum(ms.values())


def _diff(a: dict, b: dict) -> tuple[list, list]:
    only_a = [f for f, n in a.items() for _ in range(max(0, n - b.get(f, 0)))]
    only_b = [f for f, n in b.items() for _ in range(max(0, n - a.get(f, 0)))]
    return only_a, only_b


def _signature(only_churn: list, only_fresh: list) -> frozenset:
    """A compact, seed-independent fingerprint of a divergence: which derived
    schema diverged and on which side (so identical bugs across seeds collapse
    to one entry)."""
    sig = set()
    for (schema, _slots) in only_churn:
        sig.add((schema, "only_incremental"))
    for (schema, _slots) in only_fresh:
        sig.add((schema, "only_batched"))
    return frozenset(sig)


class _Lcg:
    """Deterministic, dependency-free PRNG — a seed fully reproduces a run."""
    def __init__(self, seed: int) -> None:
        self.s = (seed * 2862933555777941757 + 3037000493) & ((1 << 64) - 1)

    def next(self) -> int:
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return (self.s >> 17) & 0x7FFFFFFF


def _run_one_inner(eng, trk, dsc: bytes, seed: int, n_ops: int, n_keys: int,
                   check_every: int) -> tuple[bool, str, frozenset]:
    rng = _Lcg(seed)
    model: dict[tuple, tuple] = {}      # (schema, k) -> (handle, assert_kwargs)
    oplog: list[str] = []

    def check(step: int):
        _pump_to_fixpoint(eng)
        cn = len(eng.facts)
        cms = trk.multiset()
        fn, fms = _from_scratch(dsc, model)
        self_ok = (_ms_total(cms) == cn) and (_ms_total(fms) == fn)
        diverged = (cn != fn) or (self_ok and cms != fms)
        if not diverged:
            return None, frozenset()
        only_c, only_f = _diff(cms, fms) if self_ok else ([], [])
        sig = _signature(only_c, only_f)
        detail = (
            f"DIVERGENCE seed={seed} step={step}\n"
            f"  fact_count incremental={cn} batched={fn} (delta {cn - fn})\n"
            f"  tracker self-check: {'ok' if self_ok else 'UNRELIABLE (stream)'}\n"
            f"  live inputs ({len(model)}): "
            f"{sorted(k for k in model)}\n"
            f"  facts only in incremental: {only_c}\n"
            f"  facts only in batched:     {only_f}\n"
            f"  signature: {sorted(sig)}\n"
            f"  op log (tail):\n    " + "\n    ".join(oplog[-40:])
        )
        return detail, sig

    for step in range(n_ops):
        choice = rng.next() % 5
        if choice <= 1 or not model:                       # assert / update input
            schema = INPUT_SCHEMAS[rng.next() % len(INPUT_SCHEMAS)]
            k = rng.next() % n_keys
            if schema == MUT_SCHEMA:
                # Mutable schema: a re-assert on the same key with a (usually)
                # new `v` is a MEANINGFUL change -> retract-replace (new handle,
                # one live fact). A fresh key is a plain insert. Both go through
                # the same assert; the engine decides replace vs insert vs no-op
                # (same `v`) and returns the live handle.
                v = rng.next() % MUT_VALUE_DOMAIN
                kw = {"v": v}
                existed = (schema, k) in model
                model[(schema, k)] = (eng.assert_(schema, k=k, **kw), kw)
                oplog.append(
                    f"{'update' if existed else 'assert'} {schema}(k={k}, v={v})")
            else:
                if (schema, k) in model:
                    continue                                # key-only: no-op
                model[(schema, k)] = (eng.assert_(schema, k=k), {})
                oplog.append(f"assert {schema}(k={k})")
        elif choice == 2 and model:                         # retract
            keys = list(model.keys())
            victim = keys[rng.next() % len(keys)]
            handle, _kw = model.pop(victim)
            eng.retract(handle)
            oplog.append(f"retract {victim[0]}(k={victim[1]})")
        else:                                               # pump
            eng.pump()
            oplog.append("pump")

        if step % check_every == 0:
            detail, sig = check(step)
            if detail:
                return False, detail, sig

    detail, sig = check(n_ops)
    if detail:
        return False, detail, sig
    return True, f"ok seed={seed}", frozenset()


def run_one(dsc: bytes, seed: int, n_ops: int, n_keys: int,
            check_every: int) -> tuple[bool, str, frozenset]:
    # The same cycle as in `_from_scratch`: close() is the only release.
    eng, trk = _engine_with_tracker(dsc)
    try:
        return _run_one_inner(eng, trk, dsc, seed, n_ops, n_keys, check_every)
    finally:
        eng.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=200)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--ops", type=int, default=400)
    ap.add_argument("--keys", type=int, default=5)
    ap.add_argument("--check-every", type=int, default=9)
    ap.add_argument("--show", type=int, default=3,
                    help="print full detail for the first N diverging seeds")
    ap.add_argument("--shapes", default=None,
                    help="comma-separated shapes to run (default: all). "
                         "choices: " + ",".join(ALL_SHAPES))
    ap.add_argument("--exclude-shapes", default=None,
                    help="comma-separated shapes to exclude (applied after "
                         "--shapes)")
    args = ap.parse_args()

    selected = ([s.strip() for s in args.shapes.split(",")]
                if args.shapes else list(ALL_SHAPES))
    if args.exclude_shapes:
        excluded = {s.strip() for s in args.exclude_shapes.split(",") if s.strip()}
        selected = [s for s in selected if s not in excluded]
    selected = [s for s in selected if s]
    bad = [s for s in selected if s not in SHAPE_RULES]
    if bad:
        print(f"FATAL: unknown shape(s) {bad}; choices: {list(ALL_SHAPES)}")
        return 2
    if not selected:
        print("FATAL: no shapes selected")
        return 2
    print(f"shapes: {selected}")

    try:
        dsc = _compile_dsc(selected)
    except Exception:
        print("FATAL: compile failed:\n" + traceback.format_exc())
        return 2

    seeds = [args.seed] if args.seed is not None else range(1, args.seeds + 1)
    shown = 0
    fail_seeds = 0
    total = 0
    sig_counts: dict[frozenset, int] = {}
    sig_example: dict[frozenset, int] = {}
    for seed in seeds:
        total += 1
        try:
            ok, detail, sig = run_one(
                dsc, seed, args.ops, args.keys, args.check_every)
        except Exception:
            print(f"FATAL: engine/harness error seed={seed}:\n"
                  + traceback.format_exc())
            return 2
        if not ok:
            fail_seeds += 1
            sig_counts[sig] = sig_counts.get(sig, 0) + 1
            sig_example.setdefault(sig, seed)
            if shown < args.show:
                print(detail)
                print("---")
                shown += 1

    if fail_seeds:
        print(f"\nFAIL: {fail_seeds}/{total} seeds diverged.")
        print("distinct divergence signatures (each => a likely distinct issue):")
        for sig, cnt in sorted(sig_counts.items(), key=lambda kv: -kv[1]):
            print(f"  x{cnt:<4} seed={sig_example[sig]:<4} {sorted(sig)}")
        return 1
    print(f"PASS: {total} seed(s) x {args.ops} ops x {args.keys} keys — "
          f"incremental == batched throughout")
    return 0


if __name__ == "__main__":
    sys.exit(main())

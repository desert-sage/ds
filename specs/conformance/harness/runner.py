# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Conformance-suite runner per LTES.8 / RTIM.7.

Walks `specs/conformance/<category>/*.json`, loads each
test, and dispatches to a category-specific driver. Every executing
driver compiles its fixture with the Mercury `dsc`, through
`pyds.compile`, and runs the artefact on libds. The compiler
category has no driver here: the compiler's own suite judges it
(the `compiler` lane).

Public entry points:

- `discover_tests()` — yields every test file as a `ConformanceTest` record.
- `run_test(t)` — runs one test, returns a `Result`.

The pytest integration at `test_conformance.py` parameterises
over `discover_tests()` so each test surfaces as its own pytest
id in the test report.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Iterator


# A `use` line, at column 0 as [LGRA.3.1] places it.
_USE_LINE_RE = re.compile(r"^use\b", re.MULTILINE)


def as_program(source: str) -> str:
    """`source` as a program: unchanged when it has a `use` line, else under
    `use default`.

    A file with no `use` line is a library ([LDIA.2.10.1]) and `dsc` refuses
    one given to build ([LDIA.2.10.8]), so a harness compiles such a test input
    as though it began with `use default`. A library a fixture supplies is never
    passed through it: an import of a file with a `use` line is
    DS_VALIDATE_IMPORT_OF_PROGRAM.

    Positions in a refusal are one line later than the fixture's own.
    """
    if _USE_LINE_RE.search(source):
        return source
    return "use default\n" + source


# The harness dialects (`restricted_v1`): names the corpus uses and the
# language does not define ([LDIA.9]), so the harness registers them on
# every compile as an integrator registers its own, one `-d` per file
# ([NDLC.2.1]). Sorted, so the registration order does not depend on the
# filesystem.
_HARNESS_DIALECTS = sorted((Path(__file__).parent / "dialects").glob("*.yaml"))


class MercuryCompileRefused(AssertionError):
    """The Mercury `dsc` refused a fixture's source.

    An AssertionError so the fixture FAILS with the compiler's own diagnostics
    as its message — a refusal is a divergence to read, not a harness crash.
    """


def _compile_mercury(filename: str, source: str,
                     libraries: "dict[str, str] | None" = None) -> bytes:
    """Compile `source` with the Mercury `dsc`, through `pyds.compile`.

    The fixture's in-memory `libraries`, which pyds does not take, are written
    out as the tree `-L` resolves, `a.b` -> `<root>/a/b.ds` ([LIMP.3.1.4]), and
    passed as `search_path` ([RCTS.1.2.13]).

    The standard library is the compiler's own ([RCTS.1.2.14], [LIMP.3.3.1]).
    Nothing here adds the repository's `stdlib/`: a second copy on the search
    path would make every import of it [LIMP.3.1.3]'s ambiguity.

    `filename` may carry a `#label` (cross-tier engines); the label names the
    fixture in the refusal and is dropped from the file pyds writes.
    """
    import tempfile

    import pyds

    scratch = os.environ.get("DS_MERCURY_SCRATCH")
    if not scratch:
        raise RuntimeError("the conformance harness needs DS_MERCURY_SCRATCH "
                           "(a directory on real disk)")

    Path(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        search_path = []
        if libraries:
            lib_root = Path(work) / "lib"
            for name, text in libraries.items():
                segs = name.split(".")
                p = lib_root.joinpath(*segs[:-1], f"{segs[-1]}.ds")
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            search_path.append(lib_root)
        try:
            return pyds.compile(as_program(source),
                                file=filename.split("#")[0],
                                search_path=search_path,
                                dialect_files=_HARNESS_DIALECTS)
        except pyds.CompileRefusedError as e:
            raise MercuryCompileRefused(
                f"Mercury dsc refused {filename}:\n{e.diagnostics}") from e


def _mock_clocks(eng, *, wall: bool = True) -> None:
    """Put an engine on the mock clocks every fixture runs under.

    The monotonic clock starts at 0 ([NLFC.5.4]). The wall clock is set to the
    Unix epoch, because a mock wall clock is unset until set and `now()` read
    while it is unset faults. A fixture moves it with the `wall_set` step.
    Neither setter is a sample ([NTST.3.3]), so this records nothing.

    `wall=False` leaves the wall clock unset, for a fixture whose subject is
    the unset clock itself (`"wall_clock": "unset"` in a logical fixture's
    `expect`, [RCTS.1.2.32], or in a cross-tier fixture's engine,
    [RCTS.1.2.29]): `now()` is then a DOMAIN computation error
    ([LERR.1.4.10])."""
    eng.clock.mode = "mock"
    eng.clock.set(0)
    if wall:
        eng.clock.set_wall(0)


def _wall_set(eng, step) -> None:
    """The `wall_set` step: `{"op": "wall_set", "utc_ns": N}` sets the mock
    wall clock alone ([NTST.3.1]) -- the step a fixture uses to move `now()`
    without moving any relative time."""
    eng.clock.set_wall(int(step["utc_ns"]))


def _compile_fixture(file: str, source: str, *, test_id: str, rules_ds: str,
                     libraries: "dict[str, str] | None" = None) -> bytes:
    """The compile step every executing driver takes: the Mercury `dsc`,
    against the fixture's `libraries` and then the standard library
    ([RCTS.1.2.13], [RCTS.1.2.14]). `test_id` and `rules_ds` are not read.
    """
    return _compile_mercury(file, source, libraries)


def _engine_from_source(source: str, file: str = "<input>", *,
                        run_id: str | None = None, tier_id: str | None = None):
    """`pyds.from_source`, with a refusal reported as a fixture failure.
    `run_id` and `tier_id` are the engine's identity ([NLFC.1.2]), given at
    creation, which is the only place libds takes them."""
    import pyds

    eng = pyds.Engine(run_id=run_id, tier_id=tier_id)
    eng.load_dsc(_compile_mercury(file, source))
    return eng


# A rule header's name ([LGRA.6.1]), for the coverage record of [LTES.9.7].
_RULE_NAME_RE = re.compile(r"^rule\s+([a-z][A-Za-z0-9_]*)\b", re.MULTILINE)


def _extract_rule_names(rules_ds: str) -> list[str]:
    """Return the rule names declared in a DS source string, in
    declaration order. Empty list if the source has no rules."""
    return _RULE_NAME_RE.findall(rules_ds)


def _coverage_artefact(rules_ds: str, fire_events: list) -> dict | None:
    """Build a per-test rule-coverage record per LTES.9.7. Returns
    None for tests with no rules (no point reporting a tracker for
    schema-only tests). Otherwise returns:

        {"defined": [...], "fired": [...], "dead": [...],
         "firings_total": N}

    `fire_events` is the captured list of `pyds.events`; only
    `RuleFireBegin` entries are counted. The same rule may fire
    many times in one test — `firings_total` is the count;
    `fired` is the dedup'd set of names that fired at least once."""
    defined = _extract_rule_names(rules_ds)
    if not defined:
        return None
    fired_names: list[str] = [
        ev.rule_name for ev in fire_events
        if ev.kind == "rule_fire_begin"
    ]
    fired_set = set(fired_names)
    return {
        "defined":       defined,
        "fired":         sorted(fired_set),
        "dead":          [n for n in defined if n not in fired_set],
        "firings_total": len(fired_names),
    }


CONFORMANCE_ROOT = (
    Path(__file__).resolve().parent.parent
)
# The harness lives inside the corpus it runs (STYL.5.2.8), so it is one of
# CONFORMANCE_ROOT's subdirectories and not a category of vectors.
HARNESS_DIR = Path(__file__).resolve().parent
# [RCTS.1.2.14]: the standard library the repository under test ships. Every
# fixture compiles against it, through the `dsc` it is laid out beside; read
# here only to refuse a `libraries` entry that would shadow one of its modules.
STDLIB_ROOT = CONFORMANCE_ROOT.parent.parent / "stdlib"


# Categories with a driver here.
_ACTIVE_CATEGORIES: frozenset[str] = frozenset(
    {"runtime", "temporal", "logical", "adapter", "cross-tier"}
)

# The one category [RCTS.1.1.4] names that this harness does not drive, and
# who does. Its fixtures are reported as skipped here, with this reason.
_CATEGORY_BLOCK_REASONS: dict[str, str] = {
    "compiler": "judged by the compiler's own suite (the `compiler` lane, "
                "compiler/mercury/test/test_conformance.m)",
}

# [RCTS.1.1.4]'s categories. A fixture in any other directory, or whose
# `category` is not its directory's name, fails ([RCTS.1.2.3]).
_CATEGORIES: frozenset[str] = _ACTIVE_CATEGORIES | frozenset(_CATEGORY_BLOCK_REASONS)


@dataclass(frozen=True)
class ConformanceTest:
    """One loaded conformance test definition."""

    id: str
    category: str
    scenario: str
    rules_ds: str
    expect: dict
    path: Path
    # RCTS.1.2.9: reported in the test record; changes no verdict.
    platform_dependent: bool = False
    # [RCTS.1.2.12]: a deprecated test is not run; it skips with the
    # recorded reason.
    deprecated: str | None = None
    # [RCTS.1.2.13] — optional library map, a dotted name to its DS source.
    # Each entry is the module [LIMP.3.1.4] resolves its name to, and the
    # program's imports resolve against these, then against the standard
    # library ([RCTS.1.2.14]), and against nothing else.
    libraries: dict[str, str] | None = None
    # [RCTS.1.2.14] — whether the fixture carries the retired `stdlib` key,
    # whatever its value: one that does is malformed (`_rcts_1_2_14_malformed`).
    has_stdlib_key: bool = False
    # [RCTS.1.2.35] — whether the fixture carries `files`, which is the
    # `compiler` category's alone: on any fixture this harness judges it is
    # malformed (`_rcts_1_2_35_malformed`).
    has_files_key: bool = False
    # [RCTS.1.2.17] — names of rules the test requires never to fire (a
    # predicate that cannot hold, a trap that abandons the activation, no
    # matching trigger). `run_test` fails the fixture when one of them fires, and
    # when a rule outside the list never fires (`_dead_rules_refusal`).
    dead_rules_expected: tuple[str, ...] | None = None
    # [RCTS.1.2.1] — every member name some object in the file gives more than
    # once, at any depth, in the order met. Python's `json` keeps the last
    # value and says nothing, so `discover_tests` records the repeats as it
    # reads and `_format_refusal` refuses the fixture on them.
    repeated_members: tuple[str, ...] = ()
    # [RCTS.1.2.1] — why the file is not a fixture `discover_tests` could read
    # as written: not one JSON object, a required field absent, or `rules_ds`
    # or `expect` of another type. `_format_refusal` refuses the fixture on it,
    # after the repeats and before anything else. The fields above then hold
    # stand-ins (the file's stem and directory for `id` and `category`, empty
    # values for the rest), so reading one file cannot stop the whole collection.
    malformed: tuple[str, str] | None = None


@dataclass(frozen=True)
class Result:
    """Outcome of running one test."""

    test_id: str
    status: str            # "passed" / "failed" / "skipped"
    detail: str = ""       # diagnostic on failure / skip
    # Failure artefacts: optional structured context
    # the driver can attach when a test fails. Each driver fills
    # in what it has (event stream for logical, fact_count for
    # runtime, etc.). Read by the pytest hook that prints failure
    # details and by the JSON summary report.
    artefacts: dict | None = None


def _expand_repeats(value):
    """A fixture's `{"$repeat": "<text>", "count": N}`, anywhere in `expect`,
    as the text repeated N times.

    For values whose SIZE is the subject -- a String or Json leaf at a byte
    limit ([LGRA.5.8.6]) -- where a literal of that size could not be checked
    by eye, and a pair a few bytes off would not pin the boundary. An object
    with exactly those two keys is the form; nothing else is touched.
    `test_behave.m`'s `expand_repeats` reads the same form for the Mercury
    runtime; a fixture using it passing in both is what holds the two
    together.

    A `Bytes` slot value is written `{"$bytes": "<hex>"}`: an even number of
    hex digits, two per octet, and the value is those octets, which pyds hands
    the engine as a `Bytes` value. JSON has no binary type, and a bare string
    would be a `String`. An object with exactly that one key is the form, and
    `test_behave.m`'s `slot_value` reads the same form for the Mercury runtime
    (LEXP.7.19)."""
    if isinstance(value, dict):
        if (set(value) == {"$repeat", "count"}
                and isinstance(value["$repeat"], str)
                and isinstance(value["count"], int) and value["count"] >= 0):
            return value["$repeat"] * value["count"]
        if set(value) == {"$bytes"} and isinstance(value["$bytes"], str):
            return bytes.fromhex(value["$bytes"])
        return {k: _expand_repeats(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_expand_repeats(v) for v in value]
    return value


def load_fixture_json(text: str) -> tuple[dict, tuple[str, ...]]:
    """A fixture's JSON, and every member name an object in it repeats.

    [RCTS.1.2.1]: no object in a fixture, at any depth, repeats a member name.
    The values are what Python's `json` makes of the text (the last binding of
    a repeated name), but the repeats are kept, so the format check can refuse
    the fixture rather than read one of two meanings silently."""
    repeated: list[str] = []

    def hook(pairs: list[tuple[str, object]]) -> dict:
        seen: set[str] = set()
        for name, _ in pairs:
            if name in seen:
                repeated.append(name)
            seen.add(name)
        return dict(pairs)

    return json.loads(text, object_pairs_hook=hook), tuple(repeated)


def discover_tests() -> Iterator[ConformanceTest]:
    """Yield every JSON test file under the conformance tree.

    Sorted by (category, id) so test order is deterministic across
    machines / filesystems."""
    if not CONFORMANCE_ROOT.is_dir():
        return
    for category_dir in sorted(CONFORMANCE_ROOT.iterdir()):
        if not category_dir.is_dir() or category_dir.resolve() == HARNESS_DIR:
            continue
        for json_path in sorted(category_dir.glob("*.json")):
            yield load_fixture(json_path, json_path.read_text(encoding="utf-8"))


# [RCTS.1.2.1]'s required fields, in the order `test_conformance.m`'s
# `rcts_fixture_format` looks for them, so both harnesses name the same one.
_REQUIRED_FIELDS = ("id", "category", "scenario", "rules_ds", "expect")


def _rcts_1_2_1_shape(data: object) -> str | None:
    """Why `data` is not the one object [RCTS.1.2.1] makes a fixture, or None.
    The texts are `rcts_fixture_format`'s, so a refusal reads alike in the two
    harnesses."""
    if not isinstance(data, dict):
        return "not one JSON object"
    absent = next((f for f in _REQUIRED_FIELDS if f not in data), None)
    if absent is not None:
        return f"no `{absent}`"
    if not isinstance(data["rules_ds"], str):
        return "`rules_ds` is not a string"
    if not isinstance(data["expect"], dict):
        return "`expect` is not an object"
    return None


def load_fixture(path: Path, text: str) -> ConformanceTest:
    """The fixture `text`, read from `path`.

    Never raises on what the file holds. A file that is not one JSON object,
    or lacks a field [RCTS.1.2.1] requires, comes back with `malformed` set and
    stand-ins in the fields it could not read, and `_format_refusal` fails it
    under [RCTS.1.2.1] ([RCTS.1.2.15])."""
    try:
        data, repeated = load_fixture_json(text)
    except ValueError as e:
        data, repeated = None, ()
        why = f"not one JSON object: {e}"
    else:
        why = _rcts_1_2_1_shape(data)
    malformed = None if why is None else ("RCTS.1.2.1", why)
    if not isinstance(data, dict):
        data = {}
    elif malformed is None and not isinstance(data["category"], str):
        # Its stand-in below is the directory's name, which [RCTS.1.2.3]
        # would admit.
        malformed = ("RCTS.1.2.3", "`category` is not a string")

    def _str(name: str, stand_in: str) -> str:
        value = data.get(name)
        return value if isinstance(value, str) else stand_in

    expect = data.get("expect")
    return ConformanceTest(
        id=_str("id", path.stem),
        category=_str("category", path.parent.name),
        scenario=_str("scenario", ""),
        rules_ds=_str("rules_ds", ""),
        expect=_expand_repeats(expect) if isinstance(expect, dict) else {},
        path=path,
        platform_dependent=bool(data.get("platform_dependent", False)),
        deprecated=data.get("deprecated"),
        libraries=data.get("libraries"),
        has_stdlib_key="stdlib" in data,
        has_files_key="files" in data,
        dead_rules_expected=tuple(
            data.get("dead_rules_expected", []) or [],
        ) or None,
        repeated_members=repeated,
        malformed=malformed,
    )


def run_test(t: ConformanceTest) -> Result:
    """Dispatch to the per-category driver.

    A compiler refusal becomes a recorded failure rather than an exception,
    so the summary reports it as a fixture result and not as a driver crash.

    A fixture `load_fixture` could not read, or one repeating a member name,
    goes straight to `_run_test`'s format check: the field checks below would
    read stand-ins or one of two values, and could fail it under another
    clause first ([RCTS.1.2.15]).
    """
    unread = t.malformed is not None or bool(t.repeated_members)
    misplaced = None if unread else (
        _splice_field_misplaced(t) or _tamper_misplaced(t)
        or _timetag_offset_misplaced(t)
        or _replay_cache_cap_misplaced(t)
        or _runtime_error_fields_misplaced(t)
        or _add_schema_ref_misplaced(t)
        or _add_compiled_code_misplaced(t)
        or _recording_fields_misplaced(t)
        or _steps_refusal(t)
        or _refused_step_refusal(t)
        or _pump_statuses_refusal(t)
        or _published_asserted_at_refusal(t)
        or _wall_clock_refusal(t))
    if misplaced is not None:
        return Result(t.id, "failed", misplaced)
    try:
        result = _run_test(t)
    except MercuryCompileRefused as e:
        return Result(t.id, "failed", str(e))
    except Exception as e:
        # [RCTS.1.2.28]: a step the runtime refused, and no driver pinned the
        # refusal. `test_behave.m` fails it alike, on its `run_refused`.
        step = getattr(e, "refused_step", None)
        if step is None:
            raise
        return Result(t.id, "failed",
                      f"the runtime refused the step {json.dumps(step)}: {e} "
                      f"([RCTS.1.2.28])")
    if result.status != "passed":
        return result
    why = _dead_rules_refusal(t, result)
    if why is None:
        return result
    return Result(t.id, "failed", why, result.artefacts)


def _splice_field_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.splice_field` fails before it runs, or
    None ([RCTS.1.2.20]): the field is `rfcs_roundtrip`'s alone, and on any
    other kind nothing would read it."""
    kind = t.expect.get("kind")
    if "splice_field" in t.expect and kind != "rfcs_roundtrip":
        return (f"expect.splice_field is `rfcs_roundtrip`'s alone ([RCTS.1.2.20]); "
                f"this fixture's kind is `{kind}`")
    return None


def _timetag_offset_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.timetag_offset` fails before it runs, or
    None ([RCTS.1.2.24]): the field is `replay_determinism`'s alone."""
    kind = t.expect.get("kind")
    if "timetag_offset" in t.expect and kind != "replay_determinism":
        return (f"expect.timetag_offset is `replay_determinism`'s alone "
                f"([RCTS.1.2.24]); this fixture's kind is `{kind}`")
    return None


def _replay_cache_cap_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.replay_cache_cap` fails before it runs,
    or None ([RCTS.1.2.18]): the field is `replay_refused`'s alone."""
    kind = t.expect.get("kind")
    if "replay_cache_cap" in t.expect and kind != "replay_refused":
        return (f"expect.replay_cache_cap is `replay_refused`'s alone "
                f"([RCTS.1.2.18]); this fixture's kind is `{kind}`")
    return None


def _timetag_offset(expect: dict) -> int | None | str:
    """`replay_determinism`'s `timetag_offset` ([RCTS.1.2.24]): N, None when
    the fixture carries none, or why it is malformed -- an N that is not a
    positive integer. Whether the recording carries a nonzero `timetag` to
    offset is known only once it is recorded (`stream_edit.offset_timetags`)."""
    if "timetag_offset" not in expect:
        return None
    n = expect["timetag_offset"]
    if not isinstance(n, int) or isinstance(n, bool) or n < 1:
        return (f"expect.timetag_offset {n!r} is not a positive integer "
                f"([RCTS.1.2.24])")
    return n


def _tamper_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.tamper` fails before it runs, or None
    ([RCTS.1.2.21]): the field is `runtime_error`'s, `replay_determinism`'s
    and `runtime_fact_count`'s, and on any other kind nothing would read it.
    On `replay_determinism` it is `drop_call_operand` alone, the one edit
    whose artefact loads: the run it halts is what the replay must reproduce.
    On `runtime_fact_count` it is anything but a string, whose artefact is
    refused for its hash, and `drop_call_operand`, whose fault is a step's."""
    kind = t.expect.get("kind")
    if "tamper" not in t.expect or kind == "runtime_error":
        return None
    tamper = t.expect["tamper"]
    drop = isinstance(tamper, dict) and list(tamper) == ["drop_call_operand"]
    if kind == "replay_determinism":
        if drop:
            return None
        return (f"expect.tamper on `replay_determinism` is "
                f"`drop_call_operand` alone ([RCTS.1.2.21]); got {tamper!r}")
    if kind == "runtime_fact_count":
        if not isinstance(tamper, str) and not drop:
            return None
        return (f"expect.tamper on `runtime_fact_count` is an object other "
                f"than `drop_call_operand`, or a list ([RCTS.1.2.21]); got "
                f"{tamper!r}")
    return (f"expect.tamper is `runtime_error`'s, `replay_determinism`'s and "
            f"`runtime_fact_count`'s alone ([RCTS.1.2.21]); this fixture's "
            f"kind is `{kind}`")


# [RCTS.1.2.25]: the fields `runtime_error` alone reads. Its `code`,
# `message_contains` and `cache_seeds` are other kinds' too.
_RUNTIME_ERROR_FIELDS = ("fault_at", "no_fault_events", "fault_events",
                         "cache_cap", "halted_fault", "last_event")


def _runtime_error_fields_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying one of [RCTS.1.2.25]'s `runtime_error` fields on
    another kind fails before it runs, or None: nothing else reads them."""
    kind = t.expect.get("kind")
    if kind == "runtime_error":
        return None
    named = [f for f in _RUNTIME_ERROR_FIELDS if f in t.expect]
    if not named:
        return None
    return (f"expect.{named[0]} is `runtime_error`'s alone ([RCTS.1.2.25]); "
            f"this fixture's kind is `{kind}`")


def _add_schema_ref_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.add_schema_ref` fails before it runs, or
    None ([RCTS.1.2.26]): the field is `introspection_assert`'s alone, and on
    any other kind nothing would read the slot it edits."""
    kind = t.expect.get("kind")
    if "add_schema_ref" in t.expect and kind != "introspection_assert":
        return (f"expect.add_schema_ref is `introspection_assert`'s alone "
                f"([RCTS.1.2.26]); this fixture's kind is `{kind}`")
    return None


# [RCTS.1.2.23]: the fields `rfcs_roundtrip` alone reads, beside
# `expected_atoms`, `splice_field` and the two RCTS.1.2.10 names. Its
# `late_start` is `replay_refused`'s too ([RCTS.1.2.18]), so it is not here.
_RECORDING_FIELDS = ("run_id", "tier_id", "expected_event_ids",
                     "expected_fact_ids", "expected_emits",
                     "expected_publishes",
                     "expected_cache_seeds", "expected_stream_kinds",
                     "expected_slots", "expected_withdraw_causes",
                     "rewrite_withdraw_cause")


def _recording_fields_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying one of [RCTS.1.2.23]'s recording fields on
    another kind fails before it runs, or None: nothing else reads them, but
    `replay_refused` reads `late_start`."""
    kind = t.expect.get("kind")
    if kind == "rfcs_roundtrip":
        return None
    named = [f for f in _RECORDING_FIELDS if f in t.expect]
    if kind != "replay_refused" and "late_start" in t.expect:
        named.append("late_start")
    if not named:
        return None
    whose = ("`rfcs_roundtrip`'s and `replay_refused`'s"
             if named[0] == "late_start" else "`rfcs_roundtrip`'s")
    return (f"expect.{named[0]} is {whose} alone ([RCTS.1.2.23]); this "
            f"fixture's kind is `{kind}`")


def _is_str_list(v) -> bool:
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _is_count(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def _recording_fields_refusal(expect: dict) -> str | None:
    """Why an `rfcs_roundtrip` fixture's recording fields are refused, or
    None ([RCTS.1.2.23]): each must be of the type the clause states.
    `test_behave.m`'s `rcts_1_2_23_refusal` refuses the same values."""
    for f in ("run_id", "tier_id"):
        if f in expect and not isinstance(expect[f], str):
            return f"expect.{f} is not a string: {expect[f]!r} ([RCTS.1.2.23])"
    for f in ("expected_event_ids", "expected_stream_kinds",
              "expected_withdraw_causes"):
        if f in expect and not _is_str_list(expect[f]):
            return (f"expect.{f} is not an array of strings: {expect[f]!r} "
                    f"([RCTS.1.2.23])")
    slots = expect.get("expected_slots")
    if "expected_slots" in expect and not (
            isinstance(slots, list) and all(isinstance(s, dict) for s in slots)):
        return (f"expect.expected_slots is not an array of objects: {slots!r} "
                f"([RCTS.1.2.23])")
    rw = expect.get("rewrite_withdraw_cause")
    if "rewrite_withdraw_cause" in expect and not (
            isinstance(rw, dict) and set(rw) == {"index", "cause"}
            and _is_count(rw["index"]) and _is_count(rw["cause"])):
        return (f"expect.rewrite_withdraw_cause is not "
                f"{{\"index\": I, \"cause\": N}} of two non-negative integers: "
                f"{rw!r} ([RCTS.1.2.23])")
    fids = expect.get("expected_fact_ids")
    if "expected_fact_ids" in expect and not (
            isinstance(fids, list) and all(
                isinstance(e, dict) and set(e) == {"atom", "fact_id"}
                and e["atom"] in _FACT_ID_ATOMS and _is_count(e["fact_id"])
                for e in fids)):
        return (f"expect.expected_fact_ids is not an array of "
                f"{{\"atom\": A, \"fact_id\": N}}, A one of "
                f"{', '.join(_FACT_ID_ATOMS)} and N a non-negative integer: "
                f"{fids!r} ([RCTS.1.2.23])")
    emits = expect.get("expected_emits")
    if "expected_emits" in expect and not (
            isinstance(emits, list) and all(
                isinstance(e, dict) and set(e) == {"rule_name"}
                and isinstance(e["rule_name"], str)
                for e in emits)):
        return (f"expect.expected_emits is not an array of "
                f"{{\"rule_name\": R}}, R a string: {emits!r} "
                f"([RCTS.1.2.23])")
    pubs = expect.get("expected_publishes")
    if "expected_publishes" in expect and not (
            isinstance(pubs, list) and all(
                isinstance(p, dict) and set(p) == {"schema_name", "rule_name"}
                and isinstance(p["schema_name"], str)
                and isinstance(p["rule_name"], str)
                for p in pubs)):
        return (f"expect.expected_publishes is not an array of "
                f"{{\"schema_name\": S, \"rule_name\": R}}, S and R strings: "
                f"{pubs!r} ([RCTS.1.2.23])")
    seeds = expect.get("expected_cache_seeds")
    if "expected_cache_seeds" in expect and not (
            isinstance(seeds, list) and all(
                isinstance(s, dict)
                and set(s) == {"key", "value_json", "deadline_ns"}
                and isinstance(s["key"], str)
                and isinstance(s["value_json"], str)
                and _is_ttl_ns(s["deadline_ns"])
                for s in seeds)):
        return (f"expect.expected_cache_seeds is not an array of "
                f"{{\"key\": K, \"value_json\": V, \"deadline_ns\": N}}, K and "
                f"V strings and N an integer from 0 to 2^63 - 1: {seeds!r} "
                f"([RCTS.1.2.23])")
    if "late_start" in expect:
        n, steps = expect["late_start"], expect.get("steps", [])
        if not (_is_int(n) and isinstance(steps, list)
                and 1 <= n < len(steps)):
            return (f"expect.late_start {n!r} is not an integer from 1 to one "
                    f"less than the number of steps ([RCTS.1.2.23])")
    return None


# [RCTS.1.2.23]'s `expected_fact_ids`: the atoms whose `fact_id` it reads, by
# message name ([RFCS.6.9]).
_FACT_ID_ATOMS = ("FactAssert", "FactEmit", "FactWithdraw")


def _refused_step_refusal(t: ConformanceTest) -> str | None:
    """Why a fixture's `refused` steps fail it before it runs, or None
    ([RCTS.1.2.27]): `refused` is `rfcs_roundtrip`'s alone, on an `assert`
    step, and a string. `test_behave.m`'s `rcts_1_2_27_refusal` refuses the
    same fixtures."""
    steps = t.expect.get("steps")
    if not isinstance(steps, list):
        return None
    for i, step in enumerate(steps):
        if not isinstance(step, dict) or "refused" not in step:
            continue
        if t.expect.get("kind") != "rfcs_roundtrip":
            return (f"steps[{i}].refused is `rfcs_roundtrip`'s alone "
                    f"([RCTS.1.2.27]); this fixture's kind is "
                    f"`{t.expect.get('kind')}`")
        if step.get("op") != "assert":
            return (f"steps[{i}].refused is on a `{step.get('op')}` step; only "
                    f"an `assert` takes it ([RCTS.1.2.27])")
        if not isinstance(step["refused"], str):
            return (f"steps[{i}].refused is not a string: {step['refused']!r} "
                    f"([RCTS.1.2.27])")
    return None


_PUMP_STATUS_KINDS = ("adapter_calls", "replay_determinism",
                      "cross_tier_fact_counts",
                      "cross_tier_per_engine_event_counts")


def _pump_statuses_refusal(t: ConformanceTest) -> str | None:
    """Why a fixture's `expect.expected_pump_statuses` fails it before it
    runs, or None ([RCTS.1.2.30]): the field is `adapter_calls`'s,
    `replay_determinism`'s and the two cross-tier kinds' alone, not beside
    `tamper`, and it is an array of integers each 0 or less, one for each
    `pump` step (a cross-tier fixture's on every engine). `test_behave.m`'s
    `rcts_1_2_30_refusal` refuses the same fixtures."""
    if "expected_pump_statuses" not in t.expect:
        return None
    kind = t.expect.get("kind")
    if kind not in _PUMP_STATUS_KINDS:
        return (f"expect.expected_pump_statuses is `adapter_calls`'s, "
                f"`replay_determinism`'s and the cross-tier kinds' alone "
                f"([RCTS.1.2.30]); this fixture's kind is `{kind}`")
    if kind == "replay_determinism" and "tamper" in t.expect:
        return ("expect.expected_pump_statuses is not for a fixture that "
                "carries `tamper` ([RCTS.1.2.30])")
    want = t.expect["expected_pump_statuses"]
    if not (isinstance(want, list)
            and all(_is_int(s) and s <= 0 for s in want)):
        return (f"expect.expected_pump_statuses is not an array of integers "
                f"each 0 or less: {want!r} ([RCTS.1.2.30])")
    steps = t.expect.get("steps")
    pumps = sum(1 for s in steps if isinstance(s, dict) and s.get("op") == "pump") \
        if isinstance(steps, list) else 0
    if len(want) != pumps:
        return (f"expect.expected_pump_statuses has {len(want)} entries for "
                f"{pumps} `pump` steps ([RCTS.1.2.30])")
    return None


def _published_asserted_at_refusal(t: ConformanceTest) -> str | None:
    """Why a fixture's `expect.expected_published_asserted_at` fails it
    before it runs, or None ([RCTS.1.2.29]): it is a cross-tier fixture's
    alone, an object whose every member names an engine of `engines` and is
    an array of integers and nulls. `test_behave.m`'s `rcts_1_2_29_refusal`
    refuses the same fixtures."""
    if "expected_published_asserted_at" not in t.expect:
        return None
    if t.category != "cross-tier":
        return (f"expect.expected_published_asserted_at is a cross-tier "
                f"fixture's alone ([RCTS.1.2.29]); this fixture is "
                f"`{t.category}`")
    want = t.expect["expected_published_asserted_at"]
    engines = t.expect.get("engines")
    if not (isinstance(want, dict) and all(
            isinstance(v, list) and all(e is None or _is_int(e) for e in v)
            for v in want.values())):
        return (f"expect.expected_published_asserted_at is not an object of "
                f"arrays of integers and nulls: {want!r} ([RCTS.1.2.29])")
    for label in want:
        if not isinstance(engines, dict) or label not in engines:
            return (f"expect.expected_published_asserted_at names no engine "
                    f"of expect.engines: {label!r} ([RCTS.1.2.29])")
    return None


def _published_asserted_at_mismatch(
        want: dict, external: "dict[str, list[bytes]]") -> str | None:
    """[RCTS.1.2.29]'s `expected_published_asserted_at`: for each engine it
    names, the `asserted_at` of the FactExternal each of its publications
    carried ([RFCS.23.1], [RFCS.23.5]), in publication order, `None` where
    `has_asserted_at` is false. Why they differ, or None. A publication that
    carried no record fails. `test_behave.m`'s `published_at_failure` judges
    the Mercury runtime's the same way."""
    from pyds.proto import fact_external_pb2

    for label, want_at in want.items():
        got_at: list = []
        for i, data in enumerate(external.get(label, [])):
            if not data:
                return (f"engine `{label}`'s publication {i} carried no "
                        f"FactExternal ([RCTS.1.2.29])")
            try:
                fe = fact_external_pb2.FactExternal.FromString(data)
            except Exception as e:
                return (f"engine `{label}`'s publication {i}: its FactExternal "
                        f"does not parse: {e!r}")
            got_at.append(fe.asserted_at if fe.has_asserted_at else None)
        if got_at != want_at:
            return (f"engine `{label}` published asserted_at: want "
                    f"{want_at}, got {got_at}")
    return None


def _is_str(v) -> bool:
    return isinstance(v, str)


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _any(v) -> bool:
    return True


def _is_ttl_ns(v) -> bool:
    """`cache_seed`'s `ttl_ns` ([RCTS.1.2.28]): an integer from 0 to
    2^63 - 1, the range `test_behave.m`'s JSON integers hold, so the two
    harnesses refuse the same fixtures. libds would refuse a larger one with
    DS_ERR_TIME_RANGE ([NLFC.9.5]), which no fixture can then pin."""
    return _is_count(v) and v <= 2 ** 63 - 1


# [RCTS.1.2.28]: each step op, and each member it takes, with whether the
# member is required and the type it must have. `refused`'s own rules are
# [RCTS.1.2.27]'s (`_refused_step_refusal`). `test_behave.m`'s `step_ops`
# holds the same table.
_STEP_OPS: dict = {
    "assert": {"schema": (True, _is_str),
               "slots": (False, lambda v: isinstance(v, dict)),
               "as": (False, _is_str),
               "corr_from_call": (False, _is_count),
               "refused": (False, _any)},
    "retract": {"label": (True, _is_str)},
    "pump": {},
    "advance": {"delta_ns": (True, _is_count)},
    "set": {"now_ns": (True, _is_count)},
    "wall_set": {"utc_ns": (True, _is_int)},
    "cache_seed": {"key": (True, _is_str), "value": (True, _any),
                   "ttl_ns": (False, _is_ttl_ns)},
}

# [RCTS.1.2.29]: the two ops a cross-tier fixture's steps take besides.
_CROSS_TIER_OPS: dict = {
    "forward": {"from": (True, _is_str)},
    "forward_external": {"from": (True, _is_str)},
}

# The arrays of steps an `expect` may carry ([RCTS.1.2.28]).
_STEP_ARRAYS = ("steps", "after_clone", "after_free")

_HEX_OCTETS = re.compile(r"(?:[0-9A-Fa-f]{2})*")


def _is_hex_octets(value) -> bool:
    """Two hex digits per octet and nothing else. `bytes.fromhex` alone also
    takes spaces between octets, which `test_behave.m`'s `hex_bytes` does
    not, so a fixture spelling one would pass one harness and fail the
    other."""
    return isinstance(value, str) and _HEX_OCTETS.fullmatch(value) is not None


def _is_bytes_form(value: dict) -> bool:
    """[RCTS.1.2.28]'s `{"$bytes": H}`, H two hex digits per octet."""
    return set(value) == {"$bytes"} and _is_hex_octets(value["$bytes"])


def _is_text_octets(value) -> bool:
    """Text as hex octets ([RCTS.1.2.25]'s `text_bytes`, [RCTS.1.2.28]'s
    `$text_bytes`): two hex digits per octet, none of them `00`. A U+0000 is
    [LSTR.1.5]'s refusal, which pyds makes before the call and a Mercury
    string cannot hold, so no harness could hand it over unchanged."""
    return _is_hex_octets(value) and all(
        value[i:i + 2] != "00" for i in range(0, len(value), 2))


def _is_text_bytes_form(value: dict) -> bool:
    """[RCTS.1.2.28]'s `{"$text_bytes": H}`: a `String` value given as its
    text's octets, which need not be well-formed UTF-8 ([LSTR.8.5])."""
    return set(value) == {"$text_bytes"} and _is_text_octets(value["$text_bytes"])


def _text_bytes_misplaced(eng, schema: str, slots: dict) -> str | None:
    """Why a step gives `{"$text_bytes": H}` to a slot that is not a
    `String`, or None ([RCTS.1.2.28]). pyds takes `bytes` for a `Bytes` slot
    too, so without this the form would pass here as a `Bytes` value where
    `test_behave.m`'s `slot_value` refuses it."""
    import pyds
    given = [k for k, v in slots.items()
             if isinstance(v, dict) and "$text_bytes" in v]
    if not given:
        return None
    kinds = {s.name: s.type for s in eng.schemas[schema].slots}
    for k in given:
        if kinds.get(k) != pyds.SlotType.STRING:
            return (f"slots.{k} gives {{\"$text_bytes\": H}}, a String value, "
                    f"to a slot of type {kinds.get(k)} ([RCTS.1.2.28])")
    return None


def _steps_refusal(t: ConformanceTest) -> str | None:
    """Why a fixture's steps fail it before it runs, or None
    ([RCTS.1.2.28], [RCTS.1.2.29]): every step's `op` is one of the set, with
    exactly the members it takes, each of its type; a cross-tier fixture's
    `engines` is an object of programs, and each of its steps names one of
    them. `test_behave.m`'s `rcts_1_2_28_refusal` refuses the same
    fixtures. A deprecated fixture is not run, so its steps are not judged:
    the hydration vectors keep `deliver`, which is no member."""
    if t.deprecated is not None:
        return None
    cross = t.category == "cross-tier"
    engines = t.expect.get("engines")
    if cross:
        if not (isinstance(engines, dict) and engines and all(
                isinstance(d, dict)
                and set(d) in ({"rules_ds"}, {"rules_ds", "wall_clock"})
                and isinstance(d["rules_ds"], str)
                and d.get("wall_clock", "unset") == "unset"
                for d in engines.values())):
            return ("expect.engines is not an object of "
                    "{\"rules_ds\": <string>}, each with an optional "
                    "\"wall_clock\": \"unset\" ([RCTS.1.2.29])")
    elif "engines" in t.expect:
        return (f"expect.engines is a cross-tier fixture's alone "
                f"([RCTS.1.2.29]); this fixture is `{t.category}`")
    ops = {**_STEP_OPS, **_CROSS_TIER_OPS} if cross else _STEP_OPS
    for name in _STEP_ARRAYS:
        if name not in t.expect:
            continue
        steps = t.expect[name]
        if not (isinstance(steps, list)
                and all(isinstance(s, dict) for s in steps)):
            return f"expect.{name} is not an array of objects ([RCTS.1.2.28])"
        for i, step in enumerate(steps):
            where = f"{name}[{i}]"
            members = dict(step)
            if cross:
                label = members.pop("engine", None)
                if not isinstance(label, str) or label not in engines:
                    return (f"{where}.engine names no engine of "
                            f"expect.engines: {label!r} ([RCTS.1.2.29])")
            elif "engine" in members:
                return (f"{where}.engine is a cross-tier fixture's alone "
                        f"([RCTS.1.2.29])")
            op = members.pop("op", None)
            if op not in ops:
                return (f"{where}.op names no step op: {op!r} "
                        f"([RCTS.1.2.28])")
            takes = ops[op]
            for member, (required, ok) in takes.items():
                if member not in members:
                    if required:
                        return (f"{where} (`{op}`) lacks `{member}` "
                                f"([RCTS.1.2.28])")
                elif not ok(members[member]):
                    return (f"{where}.{member} is not of its type: "
                            f"{members[member]!r} ([RCTS.1.2.28])")
            extra = sorted(set(members) - set(takes))
            if extra:
                return (f"{where} (`{op}`) carries `{extra[0]}`, which it "
                        f"does not take ([RCTS.1.2.28])")
            for slot, value in members.get("slots", {}).items():
                for form, ok, octets in (
                        ("$bytes", _is_bytes_form, "two hex digits per octet"),
                        ("$text_bytes", _is_text_bytes_form,
                         "two hex digits per octet, none of them 00")):
                    if isinstance(value, dict) and form in value and not ok(value):
                        return (f"{where}.slots.{slot} is not {{\"{form}\": H}}, "
                                f"H {octets}: {value!r} ([RCTS.1.2.28])")
            if op in _CROSS_TIER_OPS and members["from"] not in engines:
                return (f"{where}.from names no engine of expect.engines: "
                        f"{members['from']!r} ([RCTS.1.2.29])")
    return None


class _Session:
    """[RCTS.1.2.28]'s steps, given to one pyds engine: the one statement of
    what each op does, which every driver runs, so no kind takes fewer ops
    than another. `test_behave.m`'s `run_step` is the Mercury runtime's.

    `tap` wraps the stream callback a driver registers, so the session sees
    each `action_call` and its correlation, for `corr_from_call`, whatever
    the driver does with the call."""

    def __init__(self, eng, *, handles: dict | None = None,
                 calls: list | None = None) -> None:
        self.eng = eng
        self.handles: dict = dict(handles or {})
        self.calls: list[str] = list(calls or [])
        self.last_assert = None   # the handle the latest `assert` answered

    def tap(self, sink=None):
        def on_event(ev) -> None:
            if ev.kind == "action_call" and ev.correlation:
                self.calls.append(ev.correlation)
            if sink is not None:
                sink(ev)
        return on_event

    def run(self, step: dict) -> str | None:
        """Give the engine one step. Returns why the fixture fails, or None.

        A refusal the runtime raises propagates, as a driver that pins one
        expects ([RCTS.1.2.25]). It carries the step as `refused_step`, so
        `run_test` fails the fixture when no driver caught it
        ([RCTS.1.2.28])."""
        try:
            return self._run(step)
        except Exception as e:
            if hasattr(e, "status"):          # a pyds.Error: libds refused it
                e.refused_step = step
            raise

    def _run(self, step: dict) -> str | None:
        eng = self.eng
        op = step["op"]
        if op == "assert":
            why = _text_bytes_misplaced(eng, step["schema"], step.get("slots", {}))
            if why is not None:
                return why
            slots = {k: _step_slot_value(v)
                     for k, v in step.get("slots", {}).items()}
            if "corr_from_call" in step:
                n = step["corr_from_call"]
                if n >= len(self.calls):
                    return (f"corr_from_call {n}: only {len(self.calls)} "
                            f"call(s) issued so far ([RCTS.1.2.28])")
                slots["corr"] = self.calls[n]
            h = eng.assert_(step["schema"], **slots)
            self.last_assert = h
            if "as" in step:
                self.handles[step["as"]] = h
        elif op == "retract":
            label = step["label"]
            if label not in self.handles:
                return (f"retract: no handle stored under label `{label}` "
                        f"([RCTS.1.2.28])")
            eng.retract(self.handles[label])
        elif op == "pump":
            eng.pump()
        elif op == "advance":
            eng.clock.advance(int(step["delta_ns"]))
        elif op == "set":
            eng.clock.set(int(step["now_ns"]))
        elif op == "wall_set":
            _wall_set(eng, step)
        elif op == "cache_seed":
            # [NLFC.9.1]: a host seed, its value as `_cache_seeds` gives one,
            # and its TTL, 0 for none, counted from the engine's first sample
            # ([NLFC.9.4]).
            eng.cache.seed(step["key"], json.dumps(step["value"]),
                           ttl_ns=step.get("ttl_ns", 0))
        else:
            return f"unknown step op `{op}` ([RCTS.1.2.28])"
        return None


def _is_object_list(v) -> bool:
    return isinstance(v, list) and all(isinstance(x, dict) for x in v)


_NEGATIVE_CODE = re.compile(r"-[1-9][0-9]*")


def _is_message_contains(value) -> bool:
    """[RCTS.1.2.25]'s `message_contains`: a string, or a non-empty array of
    strings, each of which the refusal's text must contain."""
    if isinstance(value, str):
        return True
    return (isinstance(value, list) and len(value) > 0
            and all(isinstance(s, str) for s in value))


def _message_lacks(want, msg: str) -> str | None:
    """The first of `message_contains`'s strings the refusal's text `msg`
    does not contain, or None when it contains them all."""
    for s in [want] if isinstance(want, str) else want:
        if s not in msg:
            return s
    return None


def _runtime_error_refusal(expect: dict) -> str | None:
    """Why a `runtime_error` fixture's fields are refused, or None
    ([RCTS.1.2.25]): `code` is required, `steps` excludes `asserts` and
    `pump`, and each field must be of the type the clause states.
    `test_behave.m`'s `rcts_1_2_25_refusal` refuses the same values."""
    def refused(field: str, want: str) -> str:
        return (f"expect.{field} is not {want}: {expect[field]!r} "
                f"([RCTS.1.2.25])")
    code = expect.get("code")
    if not (isinstance(code, str) and _NEGATIVE_CODE.fullmatch(code)):
        return (f"expect.code is not a negative integer in a string: "
                f"{code!r} ([RCTS.1.2.25])")
    if "message_contains" in expect and not _is_message_contains(
            expect["message_contains"]):
        return refused("message_contains",
                       "a string or a non-empty array of strings")
    if "steps" in expect and ("asserts" in expect or "pump" in expect):
        return ("expect.steps is given with expect.asserts or expect.pump "
                "([RCTS.1.2.25])")
    for f in ("steps", "asserts"):
        if f in expect and not _is_object_list(expect[f]):
            return refused(f, "an array of objects")
    for f in ("pump", "no_fault_events"):
        if f in expect and not isinstance(expect[f], bool):
            return refused(f, "a boolean")
    if "cache_seeds" in expect and not _cache_seeds_shape(expect["cache_seeds"]):
        return refused("cache_seeds", _CACHE_SEEDS_SHAPE)
    cap = expect.get("cache_cap")
    if "cache_cap" in expect and not (
            isinstance(cap, dict) and set(cap) <= {"keys", "bytes"}
            and all(_is_count(v) for v in cap.values())):
        return refused("cache_cap",
                       "an object of `keys` and `bytes`, non-negative integers")
    for f in ("fault_at", "fact_count_after"):
        if f in expect and not _is_count(expect[f]):
            return refused(f, "a non-negative integer")
    if "fault_events" in expect and not (
            _is_str_list(expect["fault_events"])
            and set(expect["fault_events"]) <= _FAULT_EVENT_KINDS):
        return refused("fault_events",
                       "an array of " + ", ".join(sorted(_FAULT_EVENT_KINDS)))
    if "halted_fault" in expect and not isinstance(expect["halted_fault"], str):
        return refused("halted_fault", "a string")
    if "last_event" in expect and not (
            isinstance(expect["last_event"], str)
            and expect["last_event"] in _FAULT_EVENT_KINDS):
        return refused("last_event",
                       "one of " + ", ".join(sorted(_FAULT_EVENT_KINDS)))
    # Working memory is undefined and unreadable on a halted engine
    # ([LERR.1.4.7], [NCBK.2.9]), so a fixture that pins a halt cannot
    # also count facts.
    if "halted_fault" in expect and "fact_count_after" in expect:
        return ("expect.fact_count_after reads working memory, which a halted "
                "engine does not have, and the fixture pins a halt with "
                "expect.halted_fault ([RCTS.1.2.25])")
    return None


# [RCTS.1.2.10]: the kinds whose category is `logical`.
LOGICAL_KINDS: frozenset[str] = frozenset({
    "event_sequence", "event_sequence_strict", "event_seq_monotonic",
    "event_kinds_forbidden", "rule_fire_order", "log_message_sequence",
    "header_field_eq", "introspection_assert",
})

# [RCTS.1.2.32]: each event-list kind and the one array of strings it compares
# with the run. `test_behave.m`'s `event_list_field` holds the same table.
EVENT_LIST_FIELDS: dict[str, str] = {
    "rule_fire_order": "expected_rule_names",
    "log_message_sequence": "expected_messages",
    "event_sequence": "expected_kinds",
    "event_sequence_strict": "expected_kinds",
    "event_kinds_forbidden": "forbidden_kinds",
}


def _event_list_refusal(expect: dict) -> str | None:
    """Why an event-list fixture's array is refused, or None ([RCTS.1.2.32]):
    it is required, and an array of strings. `test_behave.m`'s
    `rcts_1_2_32_refusal` refuses the same."""
    field = EVENT_LIST_FIELDS.get(expect.get("kind"))
    if field is None or _is_str_list(expect.get(field)):
        return None
    return (f"expect.{field} is not an array of strings: "
            f"{expect.get(field)!r} ([RCTS.1.2.32])")


# [RCTS.1.2.33]: the session header fields a `header_field_eq` check may name,
# the ones every runtime's header reports. `dsc_hash` is bytes, the rest text.
# `test_behave.m`'s `header_field_name` holds the same set.
HEADER_FIELDS: tuple[str, ...] = ("ds_version", "session_id", "tier_id",
                                  "dsc_hash")


def _header_check_ok(chk) -> bool:
    """[RCTS.1.2.33]: `field` and exactly one assertion, of its type, on a
    field it applies to."""
    if not (isinstance(chk, dict) and chk.get("field") in HEADER_FIELDS):
        return False
    rest = set(chk) - {"field"}
    if len(rest) != 1:
        return False
    member = rest.pop()
    value, field = chk[member], chk["field"]
    if member == "equals":
        return isinstance(value, str) and field != "dsc_hash"
    if member == "present":
        return isinstance(value, bool)
    if member == "byte_len":
        return _is_count(value) and field == "dsc_hash"
    return False


def _logical_fields_refusal(expect: dict) -> str | None:
    """Why an `event_seq_monotonic` or `header_field_eq` fixture's fields are
    refused, or None ([RCTS.1.2.33]). `test_behave.m`'s
    `rcts_1_2_33_refusal` refuses the same."""
    kind = expect.get("kind")

    def refused(field: str, want: str) -> str:
        return (f"expect.{field} is not {want}: {expect.get(field)!r} "
                f"([RCTS.1.2.33])")
    if kind == "event_seq_monotonic":
        if "filter_kind" in expect and not isinstance(expect["filter_kind"], str):
            return refused("filter_kind", "a string")
        if "min_events" in expect and not _is_count(expect["min_events"]):
            return refused("min_events", "a non-negative integer")
        step = expect.get("expected_seq_step")
        if "expected_seq_step" in expect and not (_is_count(step) and step > 0):
            return refused("expected_seq_step", "a positive integer")
        clocks = expect.get("expected_clocks")
        if "expected_clocks" in expect and not (
                isinstance(clocks, list) and all(_is_count(c) for c in clocks)):
            return refused("expected_clocks",
                           "an array of non-negative integers")
    elif kind == "header_field_eq":
        checks = expect.get("checks")
        if not (isinstance(checks, list) and checks
                and all(_header_check_ok(c) for c in checks)):
            return refused("checks",
                           "a non-empty array of header checks, each `field`, "
                           "one of " + ", ".join(HEADER_FIELDS) + ", and "
                           "exactly one of `equals`, a string, on a text "
                           "field, `present`, a boolean, and `byte_len`, a "
                           "non-negative integer, on dsc_hash")
    return None


def _wall_clock_refusal(t: ConformanceTest) -> str | None:
    """Why a fixture's `expect.wall_clock` fails it before it runs, or None
    ([RCTS.1.2.32]): it is the string `"unset"`, on a `logical` kind alone."""
    if "wall_clock" not in t.expect:
        return None
    kind = t.expect.get("kind")
    if kind not in LOGICAL_KINDS:
        return (f"expect.wall_clock is a `logical` kind's alone "
                f"([RCTS.1.2.32]); this fixture's kind is `{kind}`")
    if t.expect["wall_clock"] != "unset":
        return (f"expect.wall_clock is not \"unset\": "
                f"{t.expect['wall_clock']!r} ([RCTS.1.2.32])")
    return None


def _fact_count_refusal(expect: dict) -> str | None:
    """Why a `runtime_fact_count` or `temporal_sequence` fixture's fields are
    refused, or None ([RCTS.1.2.31]): `fact_count_after` is required, and each
    field is of the type the clause states. `test_behave.m`'s
    `rcts_1_2_31_refusal` refuses the same values."""
    def refused(field: str, want: str) -> str:
        return (f"expect.{field} is not {want}: {expect.get(field)!r} "
                f"([RCTS.1.2.31])")
    if not _is_count(expect.get("fact_count_after")):
        return refused("fact_count_after", "a non-negative integer")
    if expect.get("kind") != "runtime_fact_count":
        return None
    if "cache_seeds" in expect and not _cache_seeds_shape(expect["cache_seeds"]):
        return refused("cache_seeds", _CACHE_SEEDS_SHAPE)
    if "asserts" in expect and not (
            _is_object_list(expect["asserts"])
            and all(isinstance(a.get("schema"), str)
                    and isinstance(a.get("slots", {}), dict)
                    for a in expect["asserts"])):
        return refused("asserts", "an array of objects of `schema`, a string, "
                                  "and an optional `slots`, an object")
    if "generate_asserts" in expect and not (
            _is_object_list(expect["generate_asserts"])
            and all(isinstance(g.get("schema"), str)
                    and isinstance(g.get("slot_name"), str)
                    and _is_count(g.get("count"))
                    and _is_int(g.get("start", 0))
                    for g in expect["generate_asserts"])):
        return refused("generate_asserts",
                       "an array of objects of `schema` and `slot_name`, "
                       "strings, `count`, a non-negative integer, and an "
                       "optional `start`, an integer")
    if "pump" in expect and not isinstance(expect["pump"], bool):
        return refused("pump", "a boolean")
    if "add_compiled_code" in expect and not _add_compiled_code_shape(
            expect["add_compiled_code"]):
        return refused("add_compiled_code", "an object of one member, `node`, "
                                            "an integer of at least 1")
    return None


def _add_compiled_code_shape(edit) -> bool:
    """[RCTS.1.2.31]'s `add_compiled_code`: `{"node": N}`, N an integer of at
    least 1."""
    return (isinstance(edit, dict) and set(edit) == {"node"}
            and _is_count(edit["node"]) and edit["node"] >= 1)


def _add_compiled_code_misplaced(t: ConformanceTest) -> str | None:
    """Why a fixture carrying `expect.add_compiled_code` fails before it runs,
    or None ([RCTS.1.2.31]): the field is `runtime_fact_count`'s alone, and
    on any other kind nothing would make the edit."""
    kind = t.expect.get("kind")
    if "add_compiled_code" in t.expect and kind != "runtime_fact_count":
        return (f"expect.add_compiled_code is `runtime_fact_count`'s alone "
                f"([RCTS.1.2.31]); this fixture's kind is `{kind}`")
    return None


# [RCTS.1.2.26]: each introspection surface and the members a check of it
# takes, with their types. A check carries `surface` and exactly these.
def _is_positive(v) -> bool:
    return _is_count(v) and v > 0


_SURFACES = {
    "fact_count": {"equals": _is_count},
    "justifiers": {"fact_id": _is_positive, "expect_rules": _is_str_list},
    "justifier_count": {"fact_id": _is_positive, "count": _is_count},
    "rete_network": {"min_nodes": _is_count, "min_edges": _is_count},
    "slot_schema_ref": {"schema": lambda v: isinstance(v, str),
                        "slot": lambda v: isinstance(v, str),
                        "equals": lambda v: v is None or isinstance(v, str)},
}


def _introspection_refusal(expect: dict) -> str | None:
    """Why an `introspection_assert` fixture is refused, or None
    ([RCTS.1.2.26]): `checks` is a non-empty array, each check's `surface` is
    a member of the set, and it carries exactly that surface's members, each
    of its type. `test_behave.m`'s `rcts_1_2_26_refusal` refuses the same."""
    checks = expect.get("checks")
    if not (_is_object_list(checks) and checks):
        return (f"expect.checks is not a non-empty array of objects: "
                f"{checks!r} ([RCTS.1.2.26])")
    for chk in checks:
        takes = _SURFACES.get(chk.get("surface"))
        if takes is None:
            return (f"introspection check names no surface of the set: "
                    f"{chk!r} ([RCTS.1.2.26])")
        if set(chk) != {"surface", *takes} or not all(
                ok(chk[m]) for m, ok in takes.items()):
            return (f"introspection check `{chk['surface']}` takes exactly "
                    f"{', '.join(sorted(takes))}, of their types: {chk!r} "
                    f"([RCTS.1.2.26])")
    add_ref = expect.get("add_schema_ref")
    if "add_schema_ref" in expect and not (
            isinstance(add_ref, dict)
            and set(add_ref) == {"schema", "slot", "ref"}
            and all(isinstance(v, str) for v in add_ref.values())):
        return (f"expect.add_schema_ref is not {{\"schema\", \"slot\", "
                f"\"ref\"}} of three strings: {add_ref!r} ([RCTS.1.2.26])")
    return None


def _splice_field(expect: dict) -> tuple[int | None, str | None]:
    """The field number `rfcs_roundtrip` splices its unknown atom at, or why
    the fixture's `expect.splice_field` is refused ([RCTS.1.2.20]).

    Absent, it is `UNKNOWN_SKIP_FIELD`. Given, it must be an
    integer in the skip band, 256 through 2047 ([RFCS.16.2]), that the
    registry does not name: `AtomKind`, libds's registry, holds every field
    of `Atom`'s `oneof body` and none of its `reserved` numbers, which are the
    case the field exists for. A known number would be decoded as that atom
    and not skipped, so the vector would test something other than
    [RFCS.16.3]."""
    from pyds import AtomKind

    from future_atom import UNKNOWN_SKIP_FIELD
    field = expect.get("splice_field", UNKNOWN_SKIP_FIELD)
    if type(field) is not int:
        return None, f"expect.splice_field is not an integer: {field!r} ([RCTS.1.2.20])"
    if not 256 <= field <= 2047:
        return None, (f"expect.splice_field {field} is outside the skip band, "
                      f"256-2047 ([RCTS.1.2.20], [RFCS.16.2])")
    if field in AtomKind:
        return None, (f"expect.splice_field {field} is an atom the registry names, "
                      f"which a reader decodes rather than skips ([RCTS.1.2.20])")
    return field, None


# [RCTS.1.2.17]: the kinds that observe every rule that fires, so whose
# firings are judged: the clause's own list, and every kind its table
# ([RCTS.1.2.10]) files under `logical`. `test_behave.m`'s `records_firings`
# holds the same set for the Mercury runtime, and
# `test_rcts_1_2_17__records_firings_is_the_clause_s_list` holds the two to
# the clause.
RECORDS_FIRINGS: frozenset[str] = frozenset({
    "runtime_fact_count", "temporal_sequence",
    "adapter_calls", "adapter_cache_sets", "adapter_cache_deletes",
    "adapter_mock",
    "event_sequence", "event_sequence_strict", "event_seq_monotonic",
    "event_kinds_forbidden", "rule_fire_order", "log_message_sequence",
    "header_field_eq", "introspection_assert",
})


def _dead_rules_refusal(t: ConformanceTest, result: Result) -> str | None:
    """Why a run that otherwise passed fails on its rule firings, or None
    ([RCTS.1.2.17]).

    Every rule of a fixture either fires or is listed in
    `dead_rules_expected`, which says it must not:
      * a listed rule that fired fails the fixture;
      * a rule that never fired and is not listed fails it too. A rule
        nothing exercises tests nothing, and the vector says nothing about
        whether that is its point;
      * a listed name that is no rule of the fixture fails, since a typo
        would otherwise assert that a rule nobody wrote never fires.
    Which kinds are judged is [RCTS.1.2.17]'s list, `RECORDS_FIRINGS`, not
    whichever drivers happen to keep a coverage record: a declaration on any
    other kind cannot be checked, and fails rather than pass unread; with no
    declaration, such a kind is not judged here. A judged kind's driver must
    keep the record (`_coverage_artefact`) whenever `rules_ds` declares a
    rule, and a run that kept none fails, so a driver that stops recording
    cannot leave its fixtures unjudged and green."""
    kind = t.expect.get("kind")
    expected = set(t.dead_rules_expected or ())
    defined = set(_extract_rule_names(t.rules_ds))
    unknown = sorted(expected - defined)
    if unknown:
        return (f"dead_rules_expected names no rule of this fixture: "
                f"{', '.join(unknown)}")
    if kind not in RECORDS_FIRINGS:
        if expected:
            return (f"dead_rules_expected is declared, and the `{kind}` "
                    f"driver records no rule firings, so it cannot be "
                    f"checked")
        return None
    coverage = (result.artefacts or {}).get("coverage")
    if coverage is None:
        if defined:
            return (f"the `{kind}` driver kept no record of rule firings, "
                    f"and [RCTS.1.2.17] judges this kind's: the rules "
                    f"{', '.join(sorted(defined))} went unjudged")
        return None
    fired = sorted(expected & set(coverage["fired"]))
    if fired:
        return (f"dead_rules_expected: {', '.join(fired)} fired "
                f"({coverage['firings_total']} firing(s) in the run)")
    undeclared = [n for n in coverage["dead"] if n not in expected]
    if undeclared:
        return (f"rule(s) never fired and not in dead_rules_expected: "
                f"{', '.join(undeclared)}. List a rule there if the vector "
                f"requires it not to fire; otherwise the steps never "
                f"exercise it")
    return None


def _run_test(t: ConformanceTest) -> Result:
    # [RCTS.1.2.12]: a deprecated test skips with the recorded reason.
    if t.deprecated is not None:
        return Result(t.id, "skipped", f"deprecated: {t.deprecated}")
    # [RCTS.1.2.15]: the format is checked before anything is compiled or
    # driven, in every category, and a `malformed_fixture` is judged on that
    # check alone -- its subject is this harness, not a runtime.
    refusal = _format_refusal(t)
    if t.expect.get("kind") == "malformed_fixture":
        return _judge_malformed_fixture(t, refusal)
    if refusal is not None:
        clause, why = refusal
        return Result(t.id, "failed", f"malformed fixture: [{clause}] {why}")
    if t.category not in _ACTIVE_CATEGORIES:
        reason = _CATEGORY_BLOCK_REASONS.get(t.category)
        if reason is None:
            # `_format_refusal` fails a fixture of any other category
            # ([RCTS.1.2.3]), so none reaches here; one that did would fail,
            # never skip.
            return Result(t.id, "failed",
                          f"no driver for category `{t.category}` ([RCTS.1.2.3])")
        return Result(t.id, "skipped", reason)
    if t.category == "runtime":
        return _run_runtime_test(t)
    if t.category == "temporal":
        return _run_temporal_test(t)
    if t.category == "logical":
        return _run_logical_test(t)
    if t.category == "adapter":
        return _run_adapter_test(t)
    if t.category == "cross-tier":
        return _run_cross_tier_test(t)
    return Result(
        t.id, "failed",
        f"category `{t.category}` is in the active set but has no driver",
    )


def _format_refusal(t: ConformanceTest) -> tuple[str, str] | None:
    """The clause `t` breaks and why, or None when it is well formed.

    [RCTS.1.2.15]: a harness names the clause in each refusal.

    A repeated member name is checked first: until it is refused, every other
    field read below is one of two values the text gave it. Then what
    `load_fixture` could not read: a file that is not one object, or lacks a
    field [RCTS.1.2.1] requires, has stand-ins in those fields, and nothing
    below may read them as the fixture's."""
    if t.repeated_members:
        names = ", ".join(f"`{n}`" for n in sorted(set(t.repeated_members)))
        return ("RCTS.1.2.1",
                f"an object in the fixture repeats the member name(s) {names}")
    if t.malformed is not None:
        return t.malformed
    why = _rcts_1_2_3_malformed(t)
    if why is not None:
        return ("RCTS.1.2.3", why)
    if not isinstance(t.expect.get("kind"), str):
        return ("RCTS.1.2.7", "`expect.kind` is not a string")
    if (t.expect["kind"] == "malformed_fixture"
            and not isinstance(t.expect.get("reason"), str)):
        return ("RCTS.1.2.15",
                "a `malformed_fixture` with no `expect.reason` string")
    why = _rcts_1_2_35_malformed(t)
    if why is not None:
        return ("RCTS.1.2.35", why)
    why = _rcts_1_2_14_malformed(t)
    return None if why is None else ("RCTS.1.2.14", why)


def _rcts_1_2_3_malformed(t: ConformanceTest) -> str | None:
    """Why [RCTS.1.2.3] makes `t` malformed, or None: its directory is not a
    category of [RCTS.1.1.4], or its `category` is not that directory's name.
    The texts are `rcts_1_2_3_refusal`'s in `test_behave.m` and
    `test_conformance.m`, so a refusal reads alike in the harnesses."""
    where = t.path.parent.name
    if where not in _CATEGORIES:
        return (f"the fixture is in `{where}/`, which is no category of "
                f"[RCTS.1.1.4]")
    if t.category != where:
        return f"`category` is `{t.category}`, and the fixture is in `{where}/`"
    return None


def _rcts_1_2_35_malformed(t: ConformanceTest) -> str | None:
    """Why [RCTS.1.2.35] makes `t` malformed, or None.

    `files` places `.dstest` files beside a program compiled from disk, which
    only the `compiler` category does, so on a fixture of any other category
    it is malformed. Every fixture this harness judges is of another category
    (the `compiler` category's are `test_conformance.m`'s, which checks the
    field's form), so the category is all there is to check here. The text is
    `rcts_1_2_35_files`'s, so a refusal reads alike in the two harnesses."""
    if t.has_files_key and t.category != "compiler":
        return (f"`files` is the `compiler` category's alone; this fixture's "
                f"category is `{t.category}`")
    return None


def _judge_malformed_fixture(t: ConformanceTest,
                             refusal: tuple[str, str] | None) -> Result:
    """[RCTS.1.2.15]: passed only when the format check refused `t` under the
    clause `expect.reason` names; accepted, or refused under another, fails.
    No program is compiled and no runtime is driven."""
    reason = t.expect.get("reason")
    if refusal is None:
        return Result(t.id, "failed",
                      f"want a refusal under [{reason}]; the fixture was "
                      f"accepted")
    clause, why = refusal
    if clause != reason:
        return Result(t.id, "failed",
                      f"want a refusal under [{reason}]; refused under "
                      f"[{clause}]: {why}")
    return Result(t.id, "passed")


def _rcts_1_2_14_malformed(t: ConformanceTest) -> str | None:
    """Why [RCTS.1.2.14] makes `t` malformed, or None.

    The `stdlib` key is retired: the standard library is on every fixture's
    search path, so a fixture that carries the key, whatever
    its value, is malformed. A library name that both `libraries` and the
    standard library supply makes the fixture malformed, and the harness fails
    it rather than choose between them -- [LIMP.3.1.4]'s first-match order
    would otherwise pick one silently.

    No `stdlib/` to read is the RUN's failure, not the fixture's
    ([RCTS.1.2.14]): it raises, so no fixture is judged against a library
    that is not there."""
    if t.has_stdlib_key:
        return ("the fixture carries `stdlib`, which is retired: the standard "
                "library is on every fixture's search path")
    if not STDLIB_ROOT.is_dir():
        raise RuntimeError(f"[RCTS.1.2.14]: there is no {STDLIB_ROOT} to read")
    both = sorted(name for name in (t.libraries or {})
                  if _stdlib_module(name).is_file())
    if both:
        return ("`libraries` and the standard library both supply "
                + ", ".join(both) + "; the fixture fails rather than choose")
    return None


def _stdlib_module(name: str) -> Path:
    """Where the standard library would hold library `name`: `a.b` is
    `stdlib/a/b.ds`, the tree `-L` resolves ([LIMP.3.1.4])."""
    segs = name.split(".")
    return STDLIB_ROOT.joinpath(*segs[:-1], f"{segs[-1]}.ds")


def _raised_status(ex: BaseException, want_code: str) -> bool:
    """Did `ex` come from a libds call that failed with `want_code`?

    A `ds_status_t` is a number, not a `DS_*` name ([LERR.8.1]): a runtime
    fixture's `expect.code` is the negative integer as a string (`"-216"`). It
    is read from the exception's `status`, never from its text.
    """
    status = getattr(ex, "status", None)
    return (isinstance(status, int) and not isinstance(status, bool)
            and str(int(status)) == want_code)


def _run_runtime_test(t: ConformanceTest) -> Result:
    """Drive a runtime-category test through pyds.

    `expect.kind` honoured here:
    - `runtime_fact_count` — compile + load + (optional) assert N
      facts + (optional) pump + assert engine fact_count matches
      `fact_count_after`.

    Test JSON shape:
    ```
    {
      "expect": {
        "kind": "runtime_fact_count",
        "asserts": [ { "schema": "Trig", "slots": { "v": 42 } }, ... ],
        "pump": true,
        "fact_count_after": 1
      }
    }
    ```

    `asserts` defaults to []; `pump` defaults to false."""
    import pyds

    expect = t.expect
    kind = expect.get("kind")
    if kind == "replay_determinism":
        return _run_replay_determinism(t)
    if kind == "replay_refused":
        return _run_replay_refused(t)
    if kind == "field_order":
        return _run_field_order(t)
    if kind == "clone_determinism":
        return _run_clone_determinism(t)
    if kind == "pbf_framing":
        return _run_pbf_framing(t)
    if kind == "rfcs_roundtrip":
        return _run_rfcs_roundtrip(t)
    if kind == "rfcs_artefact_strip":
        return _run_rfcs_artefact_strip(t)
    if kind == "hash_order_independence":
        return _run_hash_order_independence(t)
    if kind == "runtime_error":
        return _run_runtime_error(t)
    if kind != "runtime_fact_count":
        return Result(
            t.id, "failed", f"unknown runtime expect.kind `{kind}`",
        )
    why = _fact_count_refusal(expect)
    if why is not None:
        return Result(t.id, "failed", f"malformed fixture: {why}")

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)
    # `tamper` ([RCTS.1.2.21]): the same structural edits as
    # `runtime_error`'s, made first, so a run on an edited artefact that must
    # raise nothing has a kind to carry it. `_tamper_misplaced` has already
    # refused a string and `drop_call_operand` here.
    if "tamper" in expect:
        edited = _tampered(dsc_bytes, expect["tamper"])
        if edited is None:
            return Result(
                t.id, "failed",
                f"runtime_fact_count: cannot find the tamper site "
                f"`{expect['tamper']}` ([RCTS.1.2.21])")
        dsc_bytes = edited
    # `add_compiled_code` ([RCTS.1.2.31], [RDSC.4c.3]): `{"node": N}` appends
    # a `CompiledCode` atom per well-known `arch`, each an RHS for terminal N,
    # and re-seals (`dsc_seal.add_compiled_code`), so the runtime is handed
    # one for the architecture it runs on and must skip it.
    if "add_compiled_code" in expect:
        from dsc_seal import add_compiled_code
        node = expect["add_compiled_code"]["node"]
        dsc_bytes = add_compiled_code(dsc_bytes, node)
        if dsc_bytes is None:
            return Result(
                t.id, "failed",
                f"add_compiled_code: no one TerminalNode has node_id {node} in "
                f"this artefact ([RCTS.1.2.31])")

    eng = pyds.Engine()
    try:
        eng.load_dsc(dsc_bytes)
    except pyds.Error as e:
        # [RCTS.1.2.21]: a refused load fails the fixture, the edited
        # artefact's included, as `test_behave.m`'s `judge_loaded` fails it.
        return Result(t.id, "failed",
                      f"runtime_fact_count: the load was refused: {e}")
    # [RCTS.1.2.31]: on the harness's mock clocks, as `test_behave.m`'s
    # `fixture_engine` runs this kind.
    _mock_clocks(eng)

    fire_events: list = []
    eng.on_event = fire_events.append

    _cache_seeds(eng, expect)
    for a in expect.get("asserts", []):
        schema = a["schema"]
        slots = a.get("slots", {})
        eng.assert_(schema, **slots)

    # Generated asserts: a compact way to assert N facts without
    # spelling out N JSON entries. Each generator is
    # `{schema, slot_name, start, count}` and produces
    # range(start, start+count) asserts of `schema(slot_name=i)`.
    # Used for fact-count-at-scale tests (N >> 20).
    for gen in expect.get("generate_asserts", []):
        schema = gen["schema"]
        slot_name = gen["slot_name"]
        start = gen.get("start", 0)
        for i in range(start, start + gen["count"]):
            eng.assert_(schema, **{slot_name: i})

    if expect.get("pump") is True:
        eng.pump()

    coverage = _coverage_artefact(t.rules_ds, fire_events)
    artefacts = {"coverage": coverage} if coverage else None

    want = expect["fact_count_after"]
    got = len(eng.facts)
    if got != want:
        return Result(
            t.id, "failed",
            f"fact_count_after: want {want}, got {got}",
            artefacts=artefacts,
        )
    return Result(t.id, "passed", artefacts=artefacts)


_CACHE_SEEDS_SHAPE = ("an array of {\"key\": K, \"value\": V}, "
                      "{\"key\": K, \"text\": T} or {\"key\": K, \"text_bytes\": H}, "
                      "K and T strings, H two hex digits per octet, none of "
                      "them 00")


def _cache_seeds_shape(seeds) -> bool:
    """[RCTS.1.2.25]'s `cache_seeds`: each entry a `key` string and exactly one
    of `value`, any JSON value; `text`, a string; and `text_bytes`, octets as
    two hex digits each, none of them `00` (`_is_text_octets`)."""
    return _is_object_list(seeds) and all(
        isinstance(s.get("key"), str)
        and (set(s) == {"key", "value"}
             or (set(s) == {"key", "text"} and isinstance(s["text"], str))
             or (set(s) == {"key", "text_bytes"} and _is_text_octets(s["text_bytes"])))
        for s in seeds)


def _seed_text(seed: dict) -> str | bytes:
    """One `cache_seeds` entry's JSON text: `text` exactly as written, its
    octets for `text_bytes`, or `value` as [RCTS.1.2.25] writes it, which
    `json.dumps`'s defaults are. `text` is how a fixture states a text no JSON
    value reads back as: an integer literal outside int64 ([LGRA.5.8.9]) is one
    this reader keeps and `test_behave.m`'s does not. `text_bytes` is how it
    states one no JSON string holds, text [LSTR.8.5] refuses; pyds's
    `cache.seed` hands `bytes` to `ds_json_parse` unchanged."""
    if "text_bytes" in seed:
        return bytes.fromhex(seed["text_bytes"])
    return seed["text"] if "text" in seed else json.dumps(seed["value"])


def _cache_seeds(eng, expect: dict) -> None:
    """`expect.cache_seeds`, `[{key, value}]` or `[{key, text}]`: each seeded
    before the asserts, as an integrator restores its cache ([NSTG.9.1]). The
    seed is handed its text (`_seed_text`), which is what
    `ds_engine_cache_seed`'s pyds wrapper takes. `test_behave.m` runs the same
    list on the Mercury runtime through `ds.engine.seed_cache_text`."""
    for s in expect.get("cache_seeds", []):
        eng.cache.seed(s["key"], _seed_text(s))


def _cache_cap(eng, expect: dict) -> None:
    """`expect.cache_cap`, `{"keys": K, "bytes": B}`: the engine's cache bounds
    (LSTO.4.7.5, NSTG.2.6.1), either one 0 or absent for no bound.
    Set before the load, as pyds's `cache.set_cap` documents. Without the
    member the cache is unbounded. `test_behave.m`'s `with_cache_cap` gives
    the Mercury runtime the same bounds through `ds.engine.set_cache_cap`."""
    cap = expect.get("cache_cap")
    if cap is not None:
        eng.cache.set_cap(keys=int(cap.get("keys", 0)),
                          bytes=int(cap.get("bytes", 0)))


# The four fault kinds a stream event can carry ([NCBK.2.8]), as pyds names
# them (runtime/src/bindings/ds_names.h).
_FAULT_EVENT_KINDS = frozenset(
    {"type_error", "bounds_error", "engine_error", "computation_error"})


def _tamper_offset(dsc: bytes, site: str) -> int | None:
    """The byte `runtime_error`'s `tamper` names, or None if there is none.
    `dsc_sha256` is located by `dsc_seal`, which walks the header."""
    from dsc_seal import sha256_offset
    if site == "last_byte":
        return len(dsc) - 1 if dsc else None
    if site == "dsc_sha256":
        return sha256_offset(dsc)
    return None


def _is_field_path(path) -> bool:
    """[RCTS.1.2.21]'s `set_field` path: a field number of at least 1, then
    any number of (occurrence index of at least 0, field number) pairs."""
    return (isinstance(path, list) and len(path) % 2 == 1
            and all(type(x) is int for x in path)
            and all(x >= 1 for x in path[0::2])
            and all(x >= 0 for x in path[1::2]))


_NO_VALUE = object()


def _set_field_site(arg: dict):
    """[RCTS.1.2.21]'s `set_field` selector and path: (`node`, None) for a
    network node by its `node_id`, (None, (F, I)) for occurrence I of the
    atoms numbered F, or None when the object is not exactly one selector,
    `path` and `value`, or a member is of another type."""
    if not _is_field_path(arg.get("path")):
        return None
    if set(arg) == {"node", "path", "value"}:
        node = arg["node"]
        return (node, None) if type(node) is int and node >= 1 else None
    if set(arg) == {"atom", "path", "value"}:
        atom = arg["atom"]
        if (isinstance(atom, list) and len(atom) == 2
                and all(type(x) is int for x in atom)
                and atom[0] >= 1 and atom[1] >= 0):
            return None, (atom[0], atom[1])
    return None


def _set_field_value(value):
    """A `set_field` value as `dsc_seal.set_field` writes it: None (remove),
    a str, an int of at least 0, or `{"f64": H}`, H 16 lowercase hexadecimal
    digits, as `dsc_seal.F64`. `_NO_VALUE` for anything else."""
    from dsc_seal import F64
    if value is None or isinstance(value, str):
        return value
    if type(value) is int:
        return value if value >= 0 else _NO_VALUE
    if (isinstance(value, dict) and list(value) == ["f64"]
            and isinstance(value["f64"], str)
            and re.fullmatch(r"[0-9a-f]{16}", value["f64"])):
        return F64(int(value["f64"], 16))
    return _NO_VALUE


def _tampered(dsc: bytes, tamper) -> bytes | None:
    """`dsc` edited as `runtime_error`'s `tamper` says ([RCTS.1.2.21]), or
    None when the edit is no member of that clause's set, its argument is of
    another type, or it has no site in `dsc`.

    A string flips one byte and leaves the stored hash as it was, so the load
    is refused for the hash ([RDSC.3.6]). An object makes one structural edit
    and RE-SEALS, so the hash matches the edited bytes and the refusal is the
    edit's own:
      - `{"truncate_tail": N}`: the last N bytes cut off. With N smaller than
        the last atom, that atom is left partial ([RDSC.9.7]).
      - `{"bad_wire_type": F}`: the first byte of the body of the first atom
        whose field number is F, a field tag, given wire type 7, which no
        protobuf field has, so the body cannot decode ([RDSC.9.5]). The atom's
        frame is untouched.
      - `{"drop_schema_group": S}`: schema S's group, its lifecycle atom
        through its `SchemaDef`, is removed, so an `AlphaNode` naming S names
        a schema the artefact does not declare ([RDSC.8.7]).
      - `{"drop_terminal_parent": R}`: the `BetaNode` that rule R's
        `TerminalNode` names as its parent is removed, so that `node_id` names
        no node ([RDSC.11.1]).
      - `{"drop_call_operand": R}`: the first action of rule R's
        `TerminalNode` that is a call loses its last operand, so the call has
        operands its op does not admit. The artefact still loads, and the
        call raises when it is evaluated ([RDSC.4a.9.3]).
      - [RDSC.11.3]'s four load refusals, each in rule R's
        `TerminalNode`: `{"drop_action_expr": R}` (its first `ACTION_CALL`
        has no `expr`), `{"clear_action_expr": R}` (that `expr` sets no
        `kind`), `{"drop_assign_expr": R}` (its first assert's first
        `SlotAssign` has no `expr`), and
        `{"nest_action_expr": {"rule": R, "levels": N}}` (that `expr`
        wrapped N times in `not`).
      - [RDSC.4a.9.3]'s op-handler refusal, each in rule R's
        `TerminalNode`: `{"set_action_op": {"rule": R, "op": N}}` (its first
        call action's call takes op N) and `{"set_assign_op": {...}}` (the
        call that is its first assert's first assignment takes op N).
      - [RBND.1.3]'s malformed `capabilities` list in the `DscHeader`:
        `{"duplicate_capability": I}` (entry I + 1 takes entry I's
        value) and `{"swap_capabilities": I}` (entries I and I + 1 swap),
        each in place, so no length moves.
      - `{"set_field": {"node": N, "path": P, "value": V}}`: in the
        one RETE node atom whose `node_id` is N, the field P names is set to
        V, an integer (a varint), a string (length-delimited, so `""` is
        also an empty message), `{"f64": H}` (a `double`'s 64 bits, 16
        lowercase hex digits) or null (removed). P is field numbers and
        occurrence indices in turn, ending on a field number
        (`dsc_seal.set_field`). `"atom": [F, I]` in place of `node` selects
        occurrence I of the atoms numbered F. It reaches the body
        refusals no compiler writes: [RDSC.4a.3], [RDSC.4a.6], [RDSC.4a.6.1],
        [RDSC.4a.9.1], [RDSC.9.10].
      - [RDSC.11.1]'s whole-frame rows: `{"truncate_to": N}` (the
        first N bytes kept, 0 for an empty artefact), `{"drop_atom": K}`
        (atom K's frame removed, 0 for the header) and
        `{"insert_bytes": {"at": K, "hex": H}}` (H's octets before atom K,
        or after the last).

    Every object re-seals the first DscHeader the frames reach; with none,
    there is no hash to seal (`dsc_seal.seal`). A list of two or more of
    those objects, none `drop_call_operand`, makes each edit in order on the
    artefact the ones before it left, so one artefact carries two
    defects. Each edit re-seals, and a seal overwrites the hash before it,
    so the result is sealed once, over the last edit's bytes."""
    if isinstance(tamper, list):
        if len(tamper) < 2:
            return None
        for edit in tamper:
            if not isinstance(edit, dict) or "drop_call_operand" in edit:
                return None
            dsc = _tampered(dsc, edit)
            if dsc is None:
                return None
        return dsc
    from dsc_seal import (atom_body_offset, capabilities_edited,
                          clear_action_expr, drop_action_expr,
                          drop_assign_expr, drop_atom,
                          drop_call_operand, drop_schema_group,
                          drop_terminal_parent, insert_bytes,
                          nest_action_expr, seal,
                          set_action_op, set_assign_op, set_field)
    if isinstance(tamper, str):
        at = _tamper_offset(dsc, tamper)
        if at is None:
            return None
        edited = bytearray(dsc)
        edited[at] ^= 0x01
        return bytes(edited)
    if not isinstance(tamper, dict) or len(tamper) != 1:
        return None
    (op, arg), = tamper.items()
    if isinstance(arg, dict):
        if op == "set_field":
            where = _set_field_site(arg)
            value = _set_field_value(arg.get("value", 0))
            if where is None or value is _NO_VALUE:
                return None
            node, atom = where
            edited = set_field(dsc, node, arg["path"], value, atom=atom)
            return None if edited is None else seal(edited)
        if (op == "insert_bytes" and set(arg) == {"at", "hex"}
                and type(arg["at"]) is int and arg["at"] >= 0
                and isinstance(arg["hex"], str)
                and re.fullmatch(r"(?:[0-9a-f]{2})+", arg["hex"])):
            edited = insert_bytes(dsc, arg["at"], bytes.fromhex(arg["hex"]))
            return None if edited is None else seal(edited)
        if (op == "nest_action_expr" and set(arg) == {"rule", "levels"}
                and isinstance(arg["rule"], str)
                and type(arg["levels"]) is int):
            nested = nest_action_expr(dsc, arg["rule"], arg["levels"])
            return None if nested is None else seal(nested)
        setter = {"set_action_op": set_action_op,
                  "set_assign_op": set_assign_op}.get(op)
        if (setter is not None and set(arg) == {"rule", "op"}
                and isinstance(arg["rule"], str)
                and type(arg["op"]) is int and arg["op"] >= 0):
            edited = setter(dsc, arg["rule"], arg["op"])
            return None if edited is None else seal(edited)
        return None
    if isinstance(arg, str):
        drop = {"drop_schema_group": drop_schema_group,
                "drop_terminal_parent": drop_terminal_parent,
                "drop_call_operand": drop_call_operand,
                "drop_action_expr": drop_action_expr,
                "clear_action_expr": clear_action_expr,
                "drop_assign_expr": drop_assign_expr}.get(op)
        dropped = drop(dsc, arg) if drop else None
        return None if dropped is None else seal(dropped)
    if not isinstance(arg, int) or isinstance(arg, bool):
        return None
    if op == "truncate_tail" and 0 < arg < len(dsc):
        return seal(dsc[:-arg])
    if op == "truncate_to" and 0 <= arg < len(dsc):
        return seal(dsc[:arg])
    if op == "drop_atom":
        edited = drop_atom(dsc, arg)
        return None if edited is None else seal(edited)
    if op in ("duplicate_capability", "swap_capabilities"):
        edited = capabilities_edited(dsc, op, arg)
        return None if edited is None else seal(edited)
    if op == "bad_wire_type":
        at = atom_body_offset(dsc, arg)
        if at is None:
            return None
        edited = bytearray(dsc)
        edited[at] = (edited[at] & 0xF8) | 0x07
        return seal(bytes(edited))
    return None


def _run_runtime_error(t: ConformanceTest) -> Result:
    """Drive a runtime-category test that must fault at load or during the pump.

    [RCTS.1.2.25] states every field below, and `_runtime_error_refusal`
    holds each to its type before anything is compiled.

    `expect.kind` == "runtime_error". Required field `code` (string): the
    DS_ERR integer code (the negative code string, e.g. "-206") the raised
    `pyds.Error` must carry as its `status`. Optional `message_contains`
    (string): a substring its message must contain. The shape mirrors `runtime_fact_count` (optional `asserts`,
    `pump`); the fault may surface from `load_dsc`, `assert_`, or `pump`.
    Pins loud-fault contracts that have no fallback path (e.g. a malformed
    bundle rejected at load).

    Optional `steps`, in place of `asserts` and `pump`: the
    `log_message_sequence` step list (`assert`, `pump`, `advance`), on the
    mock clocks, for a refusal that depends on time passing between inputs
    (`runtime/LSER.13.14_carry_not_counted`).

    Optional `fault_at`: the 0-based
    index of the input that must raise the fault -- into `steps`, or into
    `asserts` when there are no steps, the pump then counting as the input
    after the last assert. Every input before it must succeed. Without it, a
    fault from ANY input passes, which cannot tell a refusal at the right
    sample from one a sample early; the Mercury driver
    (`test_behave.m`'s `run_runtime_error`) reads it the same way.

    Optional `no_fault_events` (bool): the refusal must also leave no fault
    event on the stream -- none of the four kinds ([NCBK.2.8]). It is the
    [LGRA.5.8.6] host refusal's contract: the status is the whole refusal, so
    a runtime that still recorded a
    BoundsError fails here. `test_behave.m` honours it on the Mercury runtime.

    Optional `fault_events` (list of strings): its complement. The fault
    events the refusal leaves on the stream, of the four kinds and in stream
    order, must be EXACTLY this list -- so one vector pins both halves of a
    classification, the kind that appears and the neighbours that do not
    ([LERR.1.5]). A refusal is the one
    outcome the logical runner cannot drive, since its steps stop on the
    exception; this is where a BoundsError, which is a refusal, is pinned.

    Optional `fact_count_after` (int): the live fact count once the refusal
    has happened, so a vector pins what a refused RHS left behind: the actions
    before the refused one stand, and the ones after it never ran ([LERR.1.5]).
    `test_behave.m` reads it the same way.
    Not on a halted engine, whose working memory is undefined and refused
    ([LERR.1.4.7], [NCBK.2.9]): a fixture with `halted_fault` may not
    carry it, and a refusal that halts fails one that does.

    Optional `last_event` (string, one of the four fault kinds): the last
    event on the stream once the refusal has happened. `engine_error` pins
    that the EngineError is the tier's last record ([LERR.1.4.7]), which is
    what a halting fixture can observe in place of `fact_count_after`.

    Optional `cache_cap` (`{"keys": K, "bytes": B}`): the engine's cache
    bounds, set before the load (`_cache_cap`).

    Optional `tamper` ([RCTS.1.2.21]): edit the compiled artefact before it
    is loaded. A
    string changes ONE byte, by XOR with 0x01, at a named place:
      - `dsc_sha256`: the first byte of the header's `dsc_sha256` field;
      - `last_byte`: the artefact's final byte, inside its last atom.
    An object makes one structural edit and re-seals (`_tampered`):
    `{"truncate_tail": N}`, `{"bad_wire_type": F}`,
    `{"drop_schema_group": S}`, `{"drop_terminal_parent": R}`,
    `{"drop_call_operand": R}`, or one of [RDSC.11.3]'s four,
    `{"drop_action_expr": R}`, `{"clear_action_expr": R}`,
    `{"drop_assign_expr": R}` and
    `{"nest_action_expr": {"rule": R, "levels": N}}`, or one of
    [RBND.1.3]'s two, `{"duplicate_capability": I}` and
    `{"swap_capabilities": I}`, or `{"set_field": ...}`, or one of the
    three whole-frame edits, `{"truncate_to": N}`, `{"drop_atom": K}` and
    `{"insert_bytes": {"at": K, "hex": H}}`. A list of two or more of those objects makes
    each in order and seals once, so a vector can pin which of two defects
    the load refuses first.
    The artefact is otherwise exactly what the compiler wrote, so a fault at
    load names what the edit broke and nothing else ([RDSC.3.6]). The last
    member's artefact loads, and its fault comes from a step.

    Optional `halted_fault` (string): once the fault has happened the engine
    must be halted ([NCBK.2.9]) by an EngineError carrying this
    `pyds.EngineFault` member, e.g. `ARTEFACT_LIED`, read from the halt latch
    (`Engine.halted`, [NCBK.2.11]). That separates one halting fault from
    another, which `fault_events` cannot: it compares kinds only. A name that
    is not a member fails the fixture. `test_behave.m` reads the Mercury
    runtime's latch the same way."""
    import pyds

    expect = t.expect
    why = _runtime_error_refusal(expect)
    if why is not None:
        return Result(t.id, "failed", f"malformed fixture: {why}")
    want_code = expect.get("code")
    want_msg = expect.get("message_contains")
    fault_at = expect.get("fault_at")

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)
    tamper = expect.get("tamper")
    if tamper is not None:
        edited = _tampered(dsc_bytes, tamper)
        if edited is None:
            return Result(t.id, "failed",
                f"runtime_error: cannot find the tamper site `{tamper}`")
        dsc_bytes = edited

    steps = expect.get("steps")
    if steps is None:
        steps = [dict(a, op="assert") for a in expect.get("asserts", [])]
        if expect.get("pump", False):
            steps.append({"op": "pump"})
        mock = False
    else:
        mock = True

    events: list = []
    at = -1                                   # -1: the load, or a cache seed
    try:
        eng = pyds.Engine()
        _cache_cap(eng, expect)
        eng.load_dsc(dsc_bytes)
        # A call callback that takes every call, as every other driver of
        # [RCTS.1.2.28]'s steps registers one. A call is essential, so with
        # none libds refuses the pump that issues it (-400, [IDSP.6.4]), where
        # `test_behave.m`'s runtime hands its calls to a host and goes on. A
        # fixture that pins that refusal is an `adapter` kind's (IDSP.6.4).
        eng.set_call_callback(lambda req: None)
        session = _Session(eng)
        eng.on_event = session.tap(events.append)
        if mock:
            _mock_clocks(eng)
        _cache_seeds(eng, expect)
        for at, step in enumerate(steps):
            why = session.run(step)
            if why is not None:
                return Result(t.id, "failed", why)
    except Exception as ex:  # noqa: BLE001 — the harness asserts on the fault
        msg = str(ex)
        if fault_at is not None and at != fault_at:
            where = "the load" if at < 0 else f"input {at}"
            return Result(
                t.id, "failed",
                f"runtime_error: want the fault at input {fault_at}, "
                f"it came at {where}: {msg!r}",
            )
        if want_code is not None and not _raised_status(ex, want_code):
            return Result(
                t.id, "failed",
                f"runtime_error: want status {want_code!r}, got "
                f"{type(ex).__name__} {msg!r}",
            )
        lacks = None if want_msg is None else _message_lacks(want_msg, msg)
        if lacks is not None:
            return Result(
                t.id, "failed",
                f"runtime_error: want message containing {lacks!r}, got {msg!r}",
            )
        if expect.get("no_fault_events", False):
            faults = [e for e in events if e.kind in _FAULT_EVENT_KINDS]
            if faults:
                return Result(
                    t.id, "failed",
                    f"runtime_error: refused as expected, but the stream "
                    f"carries a fault: {faults[0]!r}",
                )
        if "fault_events" in expect:
            want_faults = list(expect["fault_events"])
            got_faults = [str(e.kind) for e in events
                          if e.kind in _FAULT_EVENT_KINDS]
            if got_faults != want_faults:
                return Result(
                    t.id, "failed",
                    f"runtime_error: refused as expected, but the stream's "
                    f"faults are {got_faults!r}, want {want_faults!r}",
                )
        if "last_event" in expect:
            want_last = expect["last_event"]
            got_last = str(events[-1].kind) if events else None
            if got_last != want_last:
                return Result(
                    t.id, "failed",
                    f"runtime_error: refused as expected, but the stream's "
                    f"last event is {got_last!r}, want {want_last!r}",
                )
        if "fact_count_after" in expect:
            # [RCTS.1.2.25]: working memory is undefined and
            # unreadable on a halted engine ([LERR.1.4.7], [NCBK.2.9]). The
            # latch is the one thing a halted engine still answers.
            if eng.halted is not None:
                return Result(
                    t.id, "failed",
                    f"runtime_error: fact_count_after, but the refusal left "
                    f"the engine halted ({eng.halted!r}), whose working "
                    f"memory is not read ([RCTS.1.2.25])",
                )
            want_fc = expect["fact_count_after"]
            got_fc = len(eng.facts)
            if got_fc != want_fc:
                return Result(
                    t.id, "failed",
                    f"runtime_error: refused as expected, but "
                    f"fact_count_after: want {want_fc}, got {got_fc}",
                )
        if "halted_fault" in expect:
            want_hf = expect["halted_fault"]
            if (not isinstance(want_hf, str)
                    or want_hf not in pyds.EngineFault.__members__):
                return Result(
                    t.id, "failed",
                    f"runtime_error: halted_fault {want_hf!r} names no "
                    f"pyds.EngineFault member",
                )
            got_hf = eng.halted
            if got_hf != pyds.EngineFault[want_hf]:
                return Result(
                    t.id, "failed",
                    f"runtime_error: refused as expected, but the halt "
                    f"latch holds {got_hf!r}, want {want_hf}",
                )
        return Result(t.id, "passed")
    return Result(
        t.id, "failed",
        f"runtime_error: expected a fault (code {want_code!r}), none raised",
    )


def _run_replay_determinism(t: ConformanceTest) -> Result:
    """Record a session with libds's own recorder, replay it into a
    fresh engine with libds's own replayer, and require the replay to
    reproduce the run (LFST.9 strict replay / LCON.2.2.1 byte-for-byte
    replay). `_replay_through_libds_rfcs` does the work; the Mercury
    runtime's `test_behave.m` takes the same path through `ds.rfcs` and
    `ds.replay`.

    Step ops: set / advance / wall_set / assert / pump.

    `min_events` (optional) is how many stream events the recorded run must
    produce, and `min_rule_fires` (optional) how many rule fires the replay
    must re-derive and byte-compare: a vector names them so a replay that
    compared nothing cannot pass.

    Test JSON shape:
    ```
    {
      "expect": {
        "kind": "replay_determinism",
        "steps": [
          { "op": "set", "now_ns": 0 },
          { "op": "assert", "schema": "Trig", "slots": { "v": 1 } },
          { "op": "pump" }
        ],
        "min_events": 1,
        "min_rule_fires": 1
      }
    }
    ```
    """
    return _replay_through_libds_rfcs(t)


def _run_clone_determinism(t: ConformanceTest) -> Result:
    """The clone-diverge-compare check ([LDET.2.2b], [NLFC.8.1]): clone an
    engine mid-run, drive the source and the clone with the same inputs, and
    require the same observable stream from both; then free one, and require
    the other to go on working.

    Fields of `expect`:
      - `steps`: run on the source alone, before the clone;
      - `after_clone`: run on the source and on the clone, each with a fresh
        stream callback registered right after `clone()`, so each captures
        only its own post-clone events ([NLFC.8.3]: a clone starts with no
        callbacks);
      - `free`: `"source"` (the default) or `"clone"`, the engine closed once
        `after_clone` has been compared;
      - `after_free`: run on the survivor alone;
      - `min_events` (default 1), `min_rule_fires` (default 1): what the
        post-clone stream must carry, so a vector cannot pass by comparing
        nothing;
      - `min_rule_fires_after_free` (default 1): rule fires the survivor must
        make after the other is freed -- the "fully functional" half.

    WHAT IS COMPARED is every post-clone event the stream callback delivers,
    field for field, in order: `seq`, both clocks, kinds, rule names, fact ids
    and slots. A clone keeps every fact id and continues every counter
    ([IARC.11]), so nothing is normalised. It is the stream as libds delivers
    it to an integrator, decoded by pyds, not RFCS bytes: a recorder on each
    engine would also compare two session headers, which [NLFC.8] does not
    require to agree.

    Every array of steps takes [RCTS.1.2.28]'s ops (`_Session`). A clone
    keeps its source's fact ids ([IARC.11]), so its session starts with the
    source's handles and the calls it has seen. The Mercury runtime runs the
    same fields in `test_behave.m`, where the engine is a value and a clone is
    the same value used twice.
    """
    import pyds

    expect = t.expect
    free = expect.get("free", "source")
    if free not in ("source", "clone"):
        return Result(t.id, "failed",
            f"clone_determinism: `free` must be \"source\" or \"clone\", "
            f"got {free!r}")

    def drive(session: _Session, steps) -> str | None:
        for step in steps:
            why = session.run(step)
            if why is not None:
                return f"clone_determinism: {why}"
        return None

    def fires(events: list) -> int:
        return sum(1 for ev in events if ev.kind == "rule_fire_begin")

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)
    src = pyds.Engine()
    src.load_dsc(dsc_bytes)
    _mock_clocks(src)
    before: list = []
    src_session = _Session(src)
    src.on_event = src_session.tap(before.append)
    err = drive(src_session, expect.get("steps", []))
    if err:
        return Result(t.id, "failed", err)

    dup = src.clone()
    dup_session = _Session(dup, handles=src_session.handles,
                           calls=src_session.calls)
    src_events: list = []
    dup_events: list = []
    src.on_event = src_session.tap(src_events.append)
    dup.on_event = dup_session.tap(dup_events.append)
    after_clone = expect.get("after_clone", [])
    for session in (src_session, dup_session):
        err = drive(session, after_clone)
        if err:
            return Result(t.id, "failed", err)

    artefacts = {"source": [str(e.kind) for e in src_events],
                 "clone": [str(e.kind) for e in dup_events]}
    min_events = int(expect.get("min_events", 1))
    if len(src_events) < min_events:
        return Result(t.id, "failed",
            f"clone_determinism: the source's post-clone stream has "
            f"{len(src_events)} event(s), fewer than {min_events}",
            artefacts=artefacts)
    min_fires = int(expect.get("min_rule_fires", 1))
    if fires(src_events) < min_fires:
        return Result(t.id, "failed",
            f"clone_determinism: the source's post-clone stream has "
            f"{fires(src_events)} rule fire(s), fewer than {min_fires}",
            artefacts=artefacts)
    if len(src_events) != len(dup_events):
        return Result(t.id, "failed",
            f"clone_determinism: event-count divergence -- source "
            f"{len(src_events)}, clone {len(dup_events)}",
            artefacts=artefacts)
    for i, (a, b) in enumerate(zip(src_events, dup_events)):
        if a != b:
            return Result(t.id, "failed",
                f"clone_determinism: divergence at post-clone event {i} "
                f"(seq {a.seq}): source {a} != clone {b}",
                artefacts={"source": a, "clone": b})

    freed, survivor = (src, dup) if free == "source" else (dup, src)
    survivor_session = dup_session if free == "source" else src_session
    freed.close()
    tail: list = []
    survivor.on_event = survivor_session.tap(tail.append)
    err = drive(survivor_session, expect.get("after_free", []))
    if err:
        return Result(t.id, "failed", err)
    min_tail = int(expect.get("min_rule_fires_after_free", 1))
    if fires(tail) < min_tail:
        return Result(t.id, "failed",
            f"clone_determinism: after the {free} was freed the survivor "
            f"made {fires(tail)} rule fire(s), fewer than {min_tail}",
            artefacts={"after_free": [str(e.kind) for e in tail]})
    survivor.close()
    return Result(t.id, "passed",
        artefacts={"events_compared": len(src_events),
                   "rule_fires_compared": fires(src_events)})


def _replay_through_libds_rfcs(t: ConformanceTest) -> Result:
    """`replay_determinism`'s check: the run is recorded by libds's own
    recorder (`Engine.record`, `ds_rfcs_record_to`) and replayed by libds's own
    replayer (`Engine.replay`, `ds_rfcs_replay_*`) into a fresh engine that is
    given nothing but the stream ([LFST.9.1], [LFST.9.6]).

    The replayer delivers each recorded input, sets both clocks from each
    `ClockAdvance` ([RFCS.10.5]), pumps at each `PumpBoundary` ([RFCS.22]), and
    byte-compares every rule fire, call and emitted fact it re-derives against
    the recorded one, raising `DS_ERR_FS_DIVERGENCE` at the first that differs
    ([LFST.9.3.1]). That raise is the main check. Three more go with it:

    - the recorded run produced at least `min_events` stream events, counted
      by a stream callback beside the recorder;
    - the two engines end holding the same facts, compared by schema and slot
      values (fact ids are each engine's own);
    - the replay compared at least `min_rule_fires` rule fires.

    `timetag_offset` N (optional, [RCTS.1.2.24]): before the replay,
    every nonzero `timetag` the recording carries is offset by N
    (`stream_edit.offset_timetags`). A `timetag` is stream-local and compared
    by its pairing ([LFST.9.3.6]), so the replay must still reproduce the run.

    The reading engine is NOT put on the mock clocks: a recording carries its
    first clock sample ([LTIM.2.8.5]), and supplying the clocks here would hide
    a recording that did not.

    A halted run (`tamper`, [RCTS.1.2.21]). `drop_call_operand` edits
    the artefact both engines load, so a step's firing raises an EngineError
    and the engine halts ([NCBK.2.9]). The step during which it halts returns
    DS_ERR_ENGINE_HALTED (-10), which is the run's outcome, not a refusal, and
    it must be the last step: a halted engine refuses everything after it
    ([RCTS.1.2.28]). A run that does not halt fails, or the tamper tested
    nothing. The replay must go past the halting input to the recording's end,
    comparing the EngineError it re-derives with the recorded one
    ([RFCS.6.7]), and leave the reading engine halted by the same fault.
    Working memory is not compared: it is undefined and unreadable on a halted
    engine ([LERR.1.4.7]), and the latch is the one thing it still answers."""
    import tempfile

    import pyds
    from stream_edit import offset_timetags

    expect = t.expect
    offset = _timetag_offset(expect)
    if isinstance(offset, str):
        return Result(t.id, "failed", f"replay_determinism: {offset}")
    dsc = _compile_mercury(f"{t.id}.ds", t.rules_ds, t.libraries)
    tamper = expect.get("tamper")
    if tamper is not None:
        edited = _tampered(dsc, tamper)
        if edited is None:
            return Result(t.id, "failed",
                f"replay_determinism: cannot find the tamper site `{tamper}`")
        dsc = edited
    scratch = os.environ["DS_MERCURY_SCRATCH"]
    Path(scratch).mkdir(parents=True, exist_ok=True)

    writer = pyds.Engine()
    writer.load_dsc(dsc)
    _mock_clocks(writer)
    # Every call accepted, as `_record_steps` accepts them.
    writer.set_call_callback(lambda req: None)
    events: list = []
    want_statuses = expect.get("expected_pump_statuses")
    got_statuses: list[int] = []
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        path = Path(work) / f"{t.id}.dstrace"
        with writer.record(path):
            # The recorder writes each event's atom, then this callback runs.
            session = _Session(writer)
            writer.on_event = session.tap(events.append)
            steps = expect.get("steps", [])
            for i, step in enumerate(steps):
                try:
                    why = session.run(step)
                    if step["op"] == "pump":
                        got_statuses.append(0)
                except Exception as e:
                    # [RCTS.1.2.30]: with the field, a pump's status is compared
                    # below, and the steps go on.
                    if (want_statuses is not None and step["op"] == "pump"
                            and isinstance(e, pyds.Error)
                            and e.status is not None):
                        got_statuses.append(int(e.status))
                        continue
                    # The halt `tamper` asks for is the run's outcome. Any
                    # other refusal propagates, and `run_test` fails it.
                    if (tamper is None or writer.halted is None
                            or not _raised_status(e, "-10")):
                        raise
                    if i != len(steps) - 1:
                        return Result(t.id, "failed",
                            f"replay_determinism: step {i} halted the engine "
                            f"({writer.halted!r}) and {len(steps) - 1 - i} "
                            f"step(s) follow it; the halting step must be the "
                            f"last ([RCTS.1.2.28])")
                    break
                if why is not None:
                    return Result(t.id, "failed", f"replay_determinism: {why}")
        stream = path.read_bytes()

    if want_statuses is not None and got_statuses != want_statuses:
        return Result(t.id, "failed",
            f"replay_determinism: pump statuses: want {want_statuses}, got "
            f"{got_statuses} ([RCTS.1.2.30])")

    halted = writer.halted
    if tamper is not None and halted is None:
        return Result(t.id, "failed",
            "replay_determinism: expect.tamper, but the run did not halt the "
            "engine, so there is no halted run to replay ([RCTS.1.2.21])")

    min_events = expect.get("min_events", 0)
    if len(events) < min_events:
        return Result(t.id, "failed",
            f"replay_determinism: the run produced too few events: "
            f"{len(events)} < {min_events}",
            artefacts={"recorded": [str(e.kind) for e in events]})

    if offset is not None:
        renamed = offset_timetags(stream, offset)
        if renamed is None:
            return Result(t.id, "failed",
                "replay_determinism: expect.timetag_offset, but the recording "
                "carries no nonzero timetag to offset ([RCTS.1.2.24])")
        stream = renamed

    # No effect callback on the reader: a replay hands no re-derived call or
    # cache write to the integrator ([NDET.8.2]).
    reader = pyds.Engine()
    reader.load_dsc(dsc)
    try:
        res = reader.replay(stream)
    except pyds.LoadError as e:
        return Result(t.id, "failed",
            f"replay_determinism (libds RFCS): the replay of libds's own "
            f"recording was refused: {e}")

    if not res.header_verified:
        return Result(t.id, "failed",
            "replay_determinism (libds RFCS): the stream header was not "
            "verified against the loaded artefact")

    def _facts(eng):
        return sorted(json.dumps([f.schema, dict(f.slots)], sort_keys=True,
                                 default=str)
                      for f in eng.facts.values())

    if halted is not None:
        # [RFCS.6.7]: the replay reproduced the halt and went on to the end,
        # so the reading engine holds the run's EngineError. Its working
        # memory is not read ([LERR.1.4.7]).
        if reader.halted != halted:
            return Result(t.id, "failed",
                f"replay_determinism (libds RFCS): the run halted with "
                f"{halted!r}, and the replay ended with the latch holding "
                f"{reader.halted!r} ([RFCS.6.7])")
    else:
        wrote, replayed = _facts(writer), _facts(reader)
        if wrote != replayed:
            return Result(t.id, "failed",
                "replay_determinism (libds RFCS): the replay ends holding "
                "different facts from the run",
                artefacts={"run": wrote, "replay": replayed})

    min_fires = expect.get("min_rule_fires", 0)
    if res.rule_fires < min_fires:
        return Result(t.id, "failed",
            f"replay_determinism (libds RFCS): the replay compared "
            f"{res.rule_fires} rule fire(s), fewer than {min_fires}")

    return Result(t.id, "passed",
        artefacts={"events_recorded": len(events),
                   "rfcs": {k: getattr(res, k)
                            for k in ("asserts", "retracts", "clocks",
                                      "rule_fires", "calls")}})


def _run_replay_refused(t: ConformanceTest) -> Result:
    """[RCTS.1.2.18]: a recording the replayer must refuse.

    The session `steps` make is recorded by libds's own recorder
    (`Engine.record`), altered by `mutation` (`stream_edit.mutate`, the closed
    set the clause names) or by `late_start`, and replayed by libds's own
    replayer (`Engine.replay`) into a fresh engine. It passes when the
    unaltered recording replays without refusal and the altered one is
    refused with `code`, the negative status as a string, read from the
    error's `status` (`_raised_status`). The first half is what makes the
    refusal the alteration's: a recording that could not be replayed anyway
    would pass any `code` the reader happened to give.

    `late_start: N` (`_late_start` checks it) runs the first N steps before
    the recorder is attached, so the altered recording begins part-way
    through the run ([LTIM.2.8.5]); the unaltered one is the same session
    recorded from its first step.

    `replay_cache_cap` alters the reading engine instead: its cache
    bounds, which neither the writer nor the control has, so a recorded
    `CacheSeed` can be one it refuses ([RFCS.26.2]).

    Step ops: set / advance / wall_set / assert (with an optional `as`
    label) / retract (by `label`) / pump. `test_behave.m` runs the same
    fields on the Mercury runtime through `ds.rfcs` and `ds.replay`."""
    import pyds
    from stream_edit import mutate

    expect = t.expect
    want_code = expect.get("code")
    if not isinstance(want_code, str):
        return Result(t.id, "failed", "replay_refused: no string `code`")
    late = _late_start(expect)
    if isinstance(late, str):
        return Result(t.id, "failed", f"replay_refused: {late}")
    dsc = _compile_mercury(f"{t.id}.ds", t.rules_ds, t.libraries)
    stream = _record_steps(t, dsc, "replay_refused")
    if isinstance(stream, Result):
        return stream

    if late is not None:
        altered = _record_steps(t, dsc, "replay_refused", late_start=late)
        if isinstance(altered, Result):
            return altered
    elif "replay_cache_cap" in expect:
        # The recording is the run's; the engine it is replayed into is what
        # differs ([RFCS.26.2]).
        altered = stream
    else:
        altered = mutate(stream, expect.get("mutation"))
        if altered is None:
            return Result(t.id, "failed",
                f"replay_refused: the mutation {expect.get('mutation')!r} "
                f"names no member of [RCTS.1.2.18]'s set or has no site in "
                f"the recording")

    # Neither replaying engine registers an effect callback ([NDET.8.2]).
    control = pyds.Engine()
    control.load_dsc(dsc)
    try:
        control.replay(stream)
    except pyds.Error as e:
        return Result(t.id, "failed",
            f"replay_refused: the UNALTERED recording was refused too, so the "
            f"refusal cannot be the alteration's: {e}")

    reader = pyds.Engine()
    # `replay_cache_cap` ([RCTS.1.2.18]): this engine's bounds, set before the
    # load as `_cache_cap` sets `runtime_error`'s; the control has none.
    _cache_cap(reader, {"cache_cap": expect.get("replay_cache_cap")})
    reader.load_dsc(dsc)
    try:
        reader.replay(altered)
    except pyds.Error as e:
        if _raised_status(e, want_code):
            return Result(t.id, "passed")
        return Result(t.id, "failed",
            f"replay_refused: want status {want_code}, got "
            f"{getattr(e, 'status', None)}: {e}")
    return Result(t.id, "failed",
        "replay_refused: the altered recording replayed without refusal")


# [RCTS.1.2.18]: what alters a `replay_refused` run; a fixture carries
# exactly one.
_REPLAY_ALTERATIONS = ("mutation", "late_start", "replay_cache_cap")


def _late_start(expect: dict) -> int | None | str:
    """`replay_refused`'s `late_start` ([RCTS.1.2.18]): the number of steps
    run before the recorder is attached, None for a fixture that carries a
    `mutation` or a `replay_cache_cap` instead, or the reason the fixture is
    malformed -- more or fewer than one of the three, a count that is not an
    integer from 1 to one less than the number of `steps`, or a
    `replay_cache_cap` that is not `cache_cap`'s shape. Whether those first
    steps put an event on the stream is known only once they run
    (`_record_steps`)."""
    given = [f for f in _REPLAY_ALTERATIONS if f in expect]
    if len(given) != 1:
        return ("not exactly one of `mutation`, `late_start` and "
                f"`replay_cache_cap`: {given or 'none'}")
    if given == ["replay_cache_cap"]:
        cap = expect["replay_cache_cap"]
        if not (isinstance(cap, dict) and set(cap) <= {"keys", "bytes"}
                and all(_is_count(v) for v in cap.values())):
            return (f"`replay_cache_cap` {cap!r} is not an object of `keys` "
                    f"and `bytes`, non-negative integers")
        return None
    if given == ["mutation"]:
        return None
    n = expect["late_start"]
    steps = expect.get("steps", [])
    if (not isinstance(n, int) or isinstance(n, bool)
            or not 1 <= n < len(steps)):
        return (f"`late_start` {n!r} is not an integer from 1 to "
                f"{len(steps) - 1}, one less than the number of steps")
    return n


def _record_steps(t: ConformanceTest, dsc: bytes, kind: str,
                  late_start: int = 0) -> bytes | Result:
    """The fact stream libds's own recorder (`Engine.record`) writes while
    `expect.steps` drive a fresh engine loaded with `dsc`, or the Result that
    fails `t` when a step cannot run. The steps take [RCTS.1.2.28]'s ops
    (`_Session`).

    With `late_start` N, the first N steps run before the recorder is
    attached ([RCTS.1.2.18]). They must put at least one event on the stream,
    counted by a stream callback, or the recording would begin at `seq` 0 and
    be complete after all ([LTIM.2.8.5])."""
    import tempfile

    import pyds

    scratch = os.environ["DS_MERCURY_SCRATCH"]
    Path(scratch).mkdir(parents=True, exist_ok=True)
    writer = pyds.Engine()
    writer.load_dsc(dsc)
    _mock_clocks(writer)
    # libds refuses a pump whose firing calls with no call callback registered
    # (DS_ERR_STORAGE_UNAVAILABLE).
    writer.set_call_callback(lambda req: None)
    session = _Session(writer)

    def run(step: dict) -> Result | None:
        why = session.run(step)
        if why is not None:
            return Result(t.id, "failed", f"{kind}: {why}")
        return None

    steps = t.expect.get("steps", [])
    if late_start:
        early: list = []
        writer.on_event = session.tap(early.append)
        for step in steps[:late_start]:
            failed = run(step)
            if failed:
                return failed
        if not early:
            return Result(t.id, "failed",
                f"{kind}: the {late_start} step(s) before `late_start` put no "
                f"event on the stream, so the recording would begin at seq 0")
    # The session hears every call either side of the recorder's start.
    writer.on_event = session.tap()
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        path = Path(work) / f"{t.id}.dstrace"
        with writer.record(path):
            for step in steps[late_start:]:
                failed = run(step)
                if failed:
                    return failed
        return path.read_bytes()


def _run_field_order(t: ConformanceTest) -> Result:
    """[RCTS.1.2.19]: the session `steps` make, recorded by libds's own
    recorder, writes every message's fields in ascending field-number order
    and no field that is not repeated twice ([RFCS.19.5]). `field_order.py`
    walks the recording by the types `proto/` declares.

    Before it judges the recording, the walk is shown to fire: the same
    recording with the first two fields of one atom body swapped must be
    refused. A walk that read nothing would otherwise pass every writer.
    `test_behave.m` runs the same fields on the Mercury runtime's writer."""
    from field_order import atom_names, problems, swapped, table

    want = t.expect.get("atoms")
    if not isinstance(want, list) or not all(isinstance(a, str) for a in want):
        return Result(t.id, "failed", "field_order: no `atoms` list of names")
    dsc = _compile_mercury(f"{t.id}.ds", t.rules_ds, t.libraries)
    stream = _record_steps(t, dsc, "field_order")
    if isinstance(stream, Result):
        return stream
    tab = table()
    absent = sorted(set(want) - atom_names(stream, tab))
    if absent:
        return Result(t.id, "failed",
            f"field_order: the recording holds no {', '.join(absent)} atom, "
            f"so the walk is not shown to reach it")
    probe = swapped(stream)
    if probe is None or not problems(probe, tab):
        return Result(t.id, "failed",
            "field_order: the walk did not refuse the recording with two "
            "fields of one atom body swapped, so it is not shown to fire")
    found = problems(stream, tab)
    if found:
        return Result(t.id, "failed",
            f"field_order: {len(found)} place(s) out of [RFCS.19.5]'s order, "
            f"first: {'; '.join(found[:5])}")
    return Result(t.id, "passed", artefacts={"stream_bytes": len(stream)})


# The framing vector corpus. A top-level file, so `discover_tests`, which walks
# subdirectories, does not load it as a fixture.
PBF_VECTORS = CONFORMANCE_ROOT / "PBF_FRAMING_VECTORS.json"

# The groups the corpus may contain. `_run_pbf_framing` fails on any other.
_PBF_PY_GROUPS = frozenset({"encode", "decode", "band"})


def _run_pbf_framing(t: ConformanceTest) -> Result:
    """The `format_major` 3 framing vectors, `PBF_FRAMING_VECTORS.json`, against
    libds's reader and writer (`pyds.atoms`) and protobuf's own parser
    (`atom_pb2`). `runtime/tests/libds/impl/pbf_vectors.h` is generated from the
    same file.

    Each `decode` vector records protobuf's verdict, and where it differs from
    DS's the difference is asserted:

      - truncation: protobuf refuses; DS returns the atoms that arrived
        ([RFCS.19.2]).
      - an Atom with no oneof member: protobuf accepts; DS refuses.

    `expect` shape:
    ```
    { "kind": "pbf_framing", "groups": ["encode"] }
    ```
    """
    from pyds.proto import atom_pb2 as _atom

    from pyds import AtomKind, atoms
    from pyds._atom_registry import FIELD_BY_MESSAGE

    try:
        corpus = json.loads(PBF_VECTORS.read_text())
    except (OSError, ValueError) as e:
        return Result(t.id, "failed", f"cannot read {PBF_VECTORS.name}: {e!r}")

    if corpus.get("format_major") != 3:
        return Result(
            t.id, "failed",
            f"corpus declares format_major "
            f"{corpus.get('format_major')!r}, not 3")

    groups_present = {k for k, v in corpus.items() if isinstance(v, dict)}
    unclaimed = groups_present - _PBF_PY_GROUPS
    if unclaimed:
        return Result(
            t.id, "failed",
            f"corpus group(s) {sorted(unclaimed)} have no driver — add one "
            f"here or to test_pbf_reader.c, or the vectors are decoration",
        )

    want = t.expect.get("groups") or []
    if not want:
        return Result(t.id, "failed", "pbf_framing: `groups` is empty")
    for g in want:
        if g not in _PBF_PY_GROUPS:
            return Result(
                t.id, "failed",
                f"pbf_framing: no driver for `{g}`. Claiming a group this "
                f"runner cannot execute would report an unearned pass",
            )

    checked = 0

    if "encode" in want:
        for v in corpus["encode"]["vectors"]:
            name, atom = v["name"], v["atom"]
            prefix = bytes.fromhex(v["prefix_hex"])
            if "body_fill" in v:
                body = bytes.fromhex(v["body_fill"]["byte"]) * v["body_fill"]["len"]
            else:
                body = bytes.fromhex(v.get("body_hex", ""))

            got = atoms.frame(v["field"], body)
            if got != prefix + body:
                return Result(
                    t.id, "failed",
                    f"encode/{name}: libds framed {got[:16].hex()}…, "
                    f"vector says {(prefix + body)[:16].hex()}…",
                    artefacts={"vector": name, "field": v["field"]})
            if FIELD_BY_MESSAGE.get(atom) != v["field"]:
                return Result(
                    t.id, "failed",
                    f"encode/{name}: pyds's registry puts {atom} at "
                    f"{FIELD_BY_MESSAGE.get(atom)}, the vector says "
                    f"{v['field']} — two renderings of one source disagree")
            checked += 2

            # Protobuf serializes the same atom, where the body is a valid
            # encoding of that message; a fill is opaque bytes.
            if not v.get("protobuf_checked"):
                continue
            a = _atom.Atom()
            field_name = _pbf_field_name(_atom, v["field"])
            if field_name is None:
                return Result(
                    t.id, "failed",
                    f"encode/{name}: no Atom field numbered {v['field']} — "
                    f"the corpus and proto/atom.proto disagree")
            getattr(a, field_name).ParseFromString(body)
            if _atom.Dsc(atoms=[a]).SerializeToString() != prefix + body:
                return Result(
                    t.id, "failed",
                    f"encode/{name}: protobuf's own serializer disagrees with "
                    f"the vector — the field number moved, or the vector is "
                    f"wrong",
                    artefacts={"vector": name})
            checked += 1

    divergences: dict[str, list[str]] = {
        "ds_weaker_truncation": [],   # protobuf refuses, DS reads on
        "ds_stricter": [],            # protobuf accepts, DS refuses
        "unnameable_atom": [],        # protobuf keeps it, the band decides
    }
    if "decode" in want:
        for v in corpus["decode"]["vectors"]:
            name = v["name"]
            raw = bytes.fromhex(v["hex"])
            want_fields = [a["field"] for a in v["atoms"]]

            err = _pbf_check_reader(atoms, v, raw, want_fields)
            if err is not None:
                return Result(t.id, "failed", f"decode/{name}: {err}",
                              artefacts={"vector": name})
            checked += 3

            try:
                parsed = _atom.Dsc.FromString(raw)
                refused = None
            except Exception as e:                       # noqa: BLE001
                parsed, refused = None, repr(e)

            if v["protobuf"] == "refuses":
                if refused is None:
                    return Result(
                        t.id, "failed",
                        f"decode/{name}: the vector says protobuf refuses "
                        f"these bytes and it parsed them. Either the bytes "
                        f"changed or the divergence the row records is gone")
                # A malformed row protobuf also refuses is agreement.
                if v["terminal"] == "eof":
                    divergences["ds_weaker_truncation"].append(name)
                checked += 1
                continue

            if refused is not None:
                return Result(
                    t.id, "failed",
                    f"decode/{name}: the vector says protobuf accepts these "
                    f"bytes; it raised {refused}")
            checked += 1

            if v["terminal"] == "malformed":
                divergences["ds_stricter"].append(name)
                continue

            # An atom whose number is not in the `Atom` oneof lands in protobuf's
            # unknown-field set, where `WhichOneof` cannot name it; DS decides
            # by the number's band ([RFCS.18.8]). A number for the atoms
            # protobuf knows, `None` for the rest: a row where those disagree
            # means the framing desynchronised.
            got_fields = [
                a.DESCRIPTOR.fields_by_name[w].number
                if (w := a.WhichOneof("body")) else None
                for a in parsed.atoms
            ]
            protobuf_can_name = [
                f if _pbf_field_name(_atom, f) is not None else None
                for f in want_fields
            ]
            if got_fields != protobuf_can_name:
                return Result(
                    t.id, "failed",
                    f"decode/{name}: protobuf reads atoms {got_fields}, "
                    f"the vector says {want_fields} "
                    f"(as far as protobuf can name them, "
                    f"{protobuf_can_name})",
                    artefacts={"vector": name})
            if None in protobuf_can_name:
                divergences["unnameable_atom"].append(name)
            checked += 1

    if "band" in want:
        for v in corpus["band"]["vectors"]:
            field = v["field"]
            if atoms.band(field) != v["band"]:
                return Result(
                    t.id, "failed",
                    f"band/{field}: libds says {str(atoms.band(field))!r}, "
                    f"the vector says {v['band']!r}")
            in_registry = field in AtomKind
            if in_registry != bool(v["known"]):
                return Result(
                    t.id, "failed",
                    f"band/{field}: pyds's registry says known={in_registry}, "
                    f"the vector says known={bool(v['known'])}")
            if atoms.disposition(field) != v["disposition"]:
                return Result(
                    t.id, "failed",
                    f"band/{field}: libds dispositions it "
                    f"{str(atoms.disposition(field))!r}, the vector says "
                    f"{v['disposition']!r}")
            checked += 3

    if not checked:
        return Result(t.id, "failed",
                      f"pbf_framing: groups {want} ran nothing")

    # Every assertion above is conditional on the row's own recorded verdict,
    # so each class of divergence is required by name.
    if "decode" in want:
        empty = [k for k, v in divergences.items() if not v]
        if empty:
            return Result(
                t.id, "failed",
                f"no vector exercises {empty} any more. The corpus pins "
                f"three ways DS and protobuf differ, and a reader built "
                f"against only the agreeing rows is wrong in each of them",
                artefacts={"divergences": divergences})

    return Result(t.id, "passed",
                  artefacts={"groups": want, "checks": checked,
                             "protobuf_divergences": divergences})


def _pbf_check_reader(atoms, v: dict, raw: bytes, want_fields: list) -> str | None:
    """One decode vector through libds's reader (`pyds.atoms`). None if it
    conforms.

    These are verdicts protobuf cannot give: the container type, taken from the
    first atom's number, and whether the bytes after the last complete atom are
    EOF or malformed ([RFCS.19.2]).
    """
    import pyds

    if atoms.container_of(raw) != v["container"]:
        return (f"container is {str(atoms.container_of(raw))!r}, vector says "
                f"{v['container']!r}")

    # [RFCS.19.2]'s reading, where a partial tail is EOF. A malformed vector
    # raises only after yielding the atoms the vector lists.
    got, raised = [], None
    try:
        for atom in atoms.iter_atoms(raw, partial=True):
            got.append((int(atom.kind), len(atom.body), atom.end))
    except pyds.Error as e:
        raised = str(e)

    want = [(a["field"], a["body_len"], a["next"]) for a in v["atoms"]]
    if got != want:
        return f"atoms {got}, vector says {want}"

    if v["terminal"] == "malformed" and raised is None:
        return ("iter_atoms accepted a container the vector calls "
                "malformed — truncation and corruption have been collapsed")
    if v["terminal"] == "eof" and raised is not None:
        return (f"iter_atoms raised {raised!r} on a container the vector "
                f"ends at EOF. [RFCS.19.2]: a half-written tail is EOF, and "
                f"every recording still being written has one")

    # The strict reading refuses a truncated vector.
    if v["terminal"] == "eof" and v["protobuf"] == "refuses":
        try:
            list(atoms.iter_atoms(raw))
        except pyds.Error:
            pass
        else:
            return ("iter_atoms(partial=False) accepted a truncated "
                    "container; the strict reading is the whole reason "
                    "`partial` exists")
    return None


def _pbf_field_name(atom_module, number: int) -> str | None:
    """The `Atom.body` field with this number."""
    for f in atom_module.Atom.DESCRIPTOR.oneofs_by_name["body"].fields:
        if f.number == number:
            return f.name
    return None


def _run_rfcs_roundtrip(t: ConformanceTest) -> Result:
    """Record a live session with libds's own recorder
    (`Engine.record`, `ds_rfcs_record_to`), splice an unknown atom into the
    stream, read it back with libds's reader and replay it with libds's
    replayer, and assert the stream-level invariants. This pins the
    fact-stream FILE format (LFST/RFCS) as libds writes it;
    `compiler/mercury/test/test_behave.m` checks the same vector against the
    Mercury runtime's writer.

    Invariants checked: StreamHeader is the first atom [RFCS.4.1]; framing
    is parseable end-to-end by libds's reader [RFCS.19.1]; an unknown
    skip-band atom spliced into the stream is skipped by libds's replayer
    without breaking the atoms after it [RFCS.16.3]; the header's `session_id`
    and `ds_version` round-trip [LDET.1.10]; and the atoms the registry names,
    `Slot` included, in stream order, equal `expected_atoms`, each named by its
    body message. `test_behave` lists the same atoms.

    `expected_first_seq` (optional, [RCTS.1.2.10]) is the `seq` of the
    stream's first event atom: the first atom that is neither the
    `StreamHeader` nor a schema announcement (`SchemaDef` or `Slot`). A live
    stream callback is registered after load and cannot see seq 0, so this is
    how [LFST.7.1.3]'s "starting at 0" gets a vector. Only the first is pinned:
    a recording carries a subset of the stream's events.

    `expected_call_correlations` (optional, [RFCS.15.2]) is the
    `correlation` of each `CallIssued` atom the recording holds, in stream order,
    read straight off each atom's message through libds's reader. An absent
    correlation reads as "".

    `splice_field` (optional, [RCTS.1.2.20]) is the field number of the
    spliced unknown atom, 2000 when absent: a skip-band number the registry
    does not name, such as a retired or deferred atom's (`_splice_field`).

    `expected_withdraw_causes` (optional, [RFCS.7a.2]) is the cause of
    every `FactWithdraw` in stream order, by its name in the proto's
    `FactWithdraw.Cause` (`_withdraw_cause_name`). The stream callback's
    kinds carry no cause.

    `rewrite_withdraw_cause` (optional, [RFCS.7a.2]) is `{"index": I,
    "cause": N}`: the recording's I-th `FactWithdraw`, in stream order, is
    re-encoded with cause N before anything decodes it
    (`_rewrite_withdraw_cause`). No engine writes a cause the enum does not
    name, so this is how a vector puts one in a recording; a reader must carry
    it, and `expected_withdraw_causes` reads it back as `CAUSE_<n>`.
    `test_behave.m` honours the same key in the Mercury runtime. A fixture
    naming a withdrawal the run does not have fails.

    `expected_slots` (optional, [RFCS.5.1]) is every `Slot` atom of the
    schemas it names, in stream order, each as the fields present on it, by
    their `proto/slot.proto` names (`_announced_slots`). `test_behave.m` honours
    the same key.

    `run_id` and `tier_id` (optional, [RCTS.1.2.23]) are given to the
    engine at creation, the one place libds takes them ([NLFC.1.2]).
    `expected_event_ids` is the `event_id` of every `FactAssert` in
    the recording, in stream order, read off the decoded atoms ([RFCS.6.8]).
    `expected_stream_kinds` is the stream callback's events while the
    steps run, cut down to the kinds it names, as `event_sequence`'s
    projection cuts them ([RCTS.1.2.10]): with `expected_atoms`, both channels
    of one run ([RFCS.3.6]). `test_behave.m` honours all four. Every field of
    [RCTS.1.2.23] is type-checked first (`_recording_fields_refusal`).

    `expected_fact_ids` is every `FactAssert`, `FactEmit` and
    `FactWithdraw`, in stream order, as `{"atom": <message name>, "fact_id":
    N}`, read off the atoms with each one's decoder ([RFCS.6.9]). An `assert`
    step carrying `refused` ([RCTS.1.2.27]) must raise that status, and the
    steps go on after it, so a recording can hold a refused host assert and
    what follows it. `test_behave.m` honours both.

    `expected_emits` is every `FactEmit`, in stream order, as
    `{"rule_name": R}`, read off each atom's message through libds's reader
    ([RFCS.6a.2]). `expected_publishes` is every `FactPublish` the same way,
    as `{"schema_name": S, "rule_name": R}` ([RFCS.27.1]): a `publish` writes
    that atom and no `FactEmit`. `test_behave.m` honours both.

    `expected_cache_seeds` is every `CacheSeed`, in stream order, as
    `{"key": K, "value_json": V, "deadline_ns": N}` (`_recorded_cache_seeds`,
    [RFCS.26.1]). `late_start` N runs the first N steps before the recorder
    is attached, as `replay_refused`'s does ([RCTS.1.2.18]): how a vector
    holds a late recorder to writing no `CacheSeed`. `test_behave.m` honours
    both.

    `expect` shape:
    ```
    {
      "kind": "rfcs_roundtrip",
      "steps": [ {op: set/advance/wall_set/assert/retract/pump} ],
      "expected_atoms": ["StreamHeader", "SchemaDef", "Slot",
                         "ClockAdvance", "FactAssert"],
      "expected_first_seq": 0,
      "expected_call_correlations": ["$r_c0_g0"],
      "splice_field": 260
    }
    ```"""
    import tempfile

    import pyds
    from pyds import AtomKind, atoms

    expect = t.expect
    splice_field, refused = _splice_field(expect)
    if refused is not None or splice_field is None:
        return Result(t.id, "failed", refused or "expect.splice_field refused")
    refused = _recording_fields_refusal(expect)
    if refused is not None:
        return Result(t.id, "failed", refused)
    dsc = _compile_mercury(t.path.name, t.rules_ds)
    run_id, tier_id = expect.get("run_id"), expect.get("tier_id")
    eng = pyds.Engine(run_id=run_id, tier_id=tier_id)
    eng.load_dsc(dsc)
    _mock_clocks(eng)
    eng.set_call_callback(lambda req: None)
    eng.on_cache_set = lambda k, v, ttl: None
    eng.on_cache_delete = lambda k, reason: None
    # Registered after load and the clock setup, so it hears the steps and
    # nothing before them, as `test_behave.m`'s effect list does.
    stream_kinds: list[str] = []
    session = _Session(eng)
    eng.on_event = session.tap(lambda ev: stream_kinds.append(str(ev.kind)))

    def run_step(step: dict) -> Result | None:
        if not (step["op"] == "assert" and "refused" in step):
            why = session.run(step)
            return None if why is None else Result(t.id, "failed", why)
        # [RCTS.1.2.27]: this assert must be refused with that status, and
        # the steps go on after it. Its FactAssert and BoundsError stay in the
        # recording ([RFCS.6.7]).
        want = step["refused"]
        why = _text_bytes_misplaced(eng, step["schema"], step.get("slots", {}))
        if why is not None:
            return Result(t.id, "failed", why)
        try:
            eng.assert_(step["schema"], **{
                k: _step_slot_value(v)
                for k, v in step.get("slots", {}).items()})
        except Exception as e:
            if _raised_status(e, want):
                return None
            # The number, as a fixture writes it: pyds's status is an
            # IntEnum, whose repr is its name.
            status = getattr(e, "status", None)
            got = int(status) if isinstance(status, int) else status
            return Result(t.id, "failed",
                f"assert of `{step['schema']}` refused with {got} ({e}); the "
                f"step wants {want} ([RCTS.1.2.27])")
        return Result(t.id, "failed",
            f"assert of `{step['schema']}` was admitted; the step wants it "
            f"refused with {want} ([RCTS.1.2.27])")

    # `late_start` N ([RCTS.1.2.23]): the first N steps run before the recorder
    # is attached.
    steps = expect.get("steps", [])
    late = expect.get("late_start", 0)
    for step in steps[:late]:
        failed = run_step(step)
        if failed:
            return failed
    if late and not stream_kinds:
        return Result(t.id, "failed",
            f"the {late} step(s) before `late_start` put no event on the "
            f"stream, so the recording would begin at its first event "
            f"([RCTS.1.2.23])")
    scratch = os.environ["DS_MERCURY_SCRATCH"]
    Path(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        path = Path(work) / f"{t.id}.dstrace"
        with eng.record(path):
            for step in steps[late:]:
                failed = run_step(step)
                if failed:
                    return failed
        stream = path.read_bytes()

    # libds's recording as written, which the replayer below is handed: a
    # rewritten cause is not what the program derives, so replaying it would
    # diverge by design ([LFST.9.3.1]). The rewrite is the readers' alone.
    as_recorded = stream
    rewrite = expect.get("rewrite_withdraw_cause")
    if rewrite is not None:
        stream, why = _rewrite_withdraw_cause(stream, rewrite)
        if why is not None:
            return Result(t.id, "failed", why)

    header = eng.session_header

    # libds's reader, strictly: the recording is complete, so a partial tail
    # is a defect, not EOF ([RFCS.19.2]).
    try:
        recorded = list(atoms.iter_atoms(stream))
    except pyds.Error as e:
        return Result(t.id, "failed",
            f"libds's reader refused libds's own recording: {e}")
    if not recorded:
        return Result(t.id, "failed", "libds recorded an empty stream")
    if recorded[0].kind is not AtomKind.STREAM_HEADER:
        return Result(t.id, "failed",
            f"[RFCS.4.1]: the first atom is {recorded[0].kind!r}, not a "
            f"StreamHeader")

    # [RFCS.6.5]: each FactAssert's schema is announced before it.
    announced: set[str] = set()
    for a in recorded:
        if a.kind is AtomKind.SCHEMA_DEF:
            announced.add(a.message().schema_name)
        elif a.kind is AtomKind.FACT_ASSERT:
            name = a.message().schema_name
            if name not in announced:
                return Result(t.id, "failed",
                    f"[RFCS.6.5]: a FactAssert of {name!r} at byte "
                    f"{a.offset} precedes its SchemaDef")

    # Splice an unknown skip-band atom (`splice_field`, [RCTS.1.2.20]) into
    # libds's own bytes, right after the StreamHeader, to exercise
    # skip-unknown [RFCS.16.3] without disturbing the rest of the stream. The
    # bytes either side are libds's, not re-framed.
    from future_atom import frame_future_atom
    cut = next(atoms.iter_atoms(as_recorded)).end
    spliced = (as_recorded[:cut]
               + frame_future_atom(splice_field, b"future-atom-body")
               + as_recorded[cut:])
    fields = [int(a.kind) for a in atoms.iter_atoms(spliced)]
    if fields[1:2] != [splice_field]:
        return Result(t.id, "failed",
            f"the spliced atom is not the second atom libds reads: {fields}")

    # libds's replayer must skip the unknown atom and reproduce the run. Not on
    # the mock clocks: the recording carries its first clock sample
    # ([LTIM.2.8.5]). No effect callback ([NDET.8.2]). Not after a `late_start`:
    # that recording begins part-way through the run, which a replayer refuses
    # ([LTIM.2.8.5]).
    reader = pyds.Engine(run_id=run_id, tier_id=tier_id)
    reader.load_dsc(dsc)
    if not late:
        try:
            res = reader.replay(spliced)
        except pyds.Error as e:
            return Result(t.id, "failed",
                f"[RFCS.16.3]: libds's replayer refused the stream with the "
                f"unknown atom field {splice_field} "
                f"({atoms.band(splice_field)} band) spliced in: {e}")
        if not res.header_verified:
            return Result(t.id, "failed",
                "libds's replayer did not verify the stream header against "
                "the loaded artefact")

    # Every atom the registry names, by its body message; the spliced future
    # atom is a plain field number, which no AtomKind names, so it drops out
    # here exactly as a reader skips it ([RFCS.16.3]).
    got_atoms = [a.kind.message for a in atoms.iter_atoms(spliced)
                 if isinstance(a.kind, AtomKind)]
    want_atoms = expect.get("expected_atoms")
    if want_atoms is not None and got_atoms != want_atoms:
        return Result(t.id, "failed",
            f"rfcs atom sequence: want {want_atoms}, got {got_atoms}",
            artefacts={"atoms": got_atoms})

    recorded_header = recorded[0].message()
    if recorded_header.session_id != header.session_id:
        return Result(t.id, "failed",
            f"rfcs header session_id mismatch: "
            f"{recorded_header.session_id} != {header.session_id}")
    # [LDET.1.10]: the writer stamps the DS version.
    if recorded_header.ds_version != header.ds_version:
        return Result(t.id, "failed",
            f"rfcs header ds_version: want {header.ds_version!r}, "
            f"got {recorded_header.ds_version!r}")

    want_first = expect.get("expected_first_seq")
    if want_first is not None:
        events = [a for a in recorded
                  if a.kind not in (AtomKind.STREAM_HEADER,
                                    AtomKind.SCHEMA_DEF, AtomKind.SLOT)]
        if not events:
            return Result(t.id, "failed",
                "rfcs_roundtrip: expected_first_seq given, but the recording "
                "has no event atom", artefacts={"atoms": got_atoms})
        first = events[0]
        if not isinstance(first.kind, AtomKind):
            return Result(t.id, "failed",
                f"rfcs_roundtrip: the first event atom is field {first.kind}, "
                f"which this build has no message for",
                artefacts={"atoms": got_atoms})
        body = first.message()
        if "seq" not in body.DESCRIPTOR.fields_by_name:
            return Result(t.id, "failed",
                f"rfcs_roundtrip: the first event atom ({first.kind.message}) "
                f"has no seq", artefacts={"atoms": got_atoms})
        if body.seq != want_first:
            seqs = [getattr(a.message(), "seq", None) for a in events
                    if isinstance(a.kind, AtomKind)]
            return Result(t.id, "failed",
                f"rfcs first event seq: want {want_first}, got "
                f"{body.seq} ({first.kind.message})",
                artefacts={"atoms": [a.kind.message for a in events
                                     if isinstance(a.kind, AtomKind)],
                           "seqs": seqs})

    want_corrs = expect.get("expected_call_correlations")
    if want_corrs is not None:
        got_corrs = [a.message().correlation for a in recorded
                     if a.kind is AtomKind.CALL_ISSUED]
        if got_corrs != want_corrs:
            return Result(t.id, "failed",
                f"rfcs recorded call correlations: want {want_corrs}, "
                f"got {got_corrs}", artefacts={"atoms": got_atoms})

    want_causes = expect.get("expected_withdraw_causes")
    if want_causes is not None:
        causes = [_withdraw_cause_name(a.message()) for a in recorded
                  if a.kind is AtomKind.FACT_WITHDRAW]
        if causes != want_causes:
            return Result(t.id, "failed",
                f"rfcs withdrawal causes: want {want_causes}, got {causes}",
                artefacts={"atoms": got_atoms, "causes": causes})

    want_slots = expect.get("expected_slots")
    if want_slots is not None:
        got_slots, why = _announced_slots(
            recorded, {s.get("schema_name") for s in want_slots})
        if why is not None:
            return Result(t.id, "failed", why, artefacts={"atoms": got_atoms})
        if got_slots != want_slots:
            return Result(t.id, "failed",
                f"rfcs Slot announcements: want {want_slots}, got {got_slots}",
                artefacts={"atoms": got_atoms, "slots": got_slots})

    want_ids = expect.get("expected_event_ids")
    if want_ids is not None:
        got_ids = [a.message().event_id for a in recorded
                   if a.kind is AtomKind.FACT_ASSERT]
        if got_ids != want_ids:
            return Result(t.id, "failed",
                f"rfcs FactAssert event_ids: want {want_ids}, got {got_ids}",
                artefacts={"atoms": got_atoms, "event_ids": got_ids})

    want_fids = expect.get("expected_fact_ids")
    if want_fids is not None:
        fact_atoms = (AtomKind.FACT_ASSERT, AtomKind.FACT_EMIT,
                      AtomKind.FACT_WITHDRAW)
        got_fids = [{"atom": a.kind.message, "fact_id": a.message().fact_id}
                    for a in recorded if a.kind in fact_atoms]
        if got_fids != want_fids:
            return Result(t.id, "failed",
                f"rfcs fact_ids: want {want_fids}, got {got_fids}",
                artefacts={"atoms": got_atoms, "fact_ids": got_fids})

    want_emits = expect.get("expected_emits")
    if want_emits is not None:
        # [RFCS.6a.2]: what libds's recorder wrote on each FactEmit, read
        # off the atom through libds's reader; the message gives proto3's
        # default for an absent field, "".
        got_emits = [{"rule_name": m.rule_name}
                     for m in (a.message() for a in recorded
                               if a.kind is AtomKind.FACT_EMIT)]
        if got_emits != want_emits:
            return Result(t.id, "failed",
                f"rfcs FactEmits: want {want_emits}, got {got_emits}",
                artefacts={"atoms": got_atoms, "emits": got_emits})

    want_pubs = expect.get("expected_publishes")
    if want_pubs is not None:
        got_pubs, why = _recorded_publishes(recorded)
        if why is not None:
            return Result(t.id, "failed", why, artefacts={"atoms": got_atoms})
        if got_pubs != want_pubs:
            return Result(t.id, "failed",
                f"rfcs FactPublishes: want {want_pubs}, got {got_pubs}",
                artefacts={"atoms": got_atoms, "publishes": got_pubs})

    want_seeds = expect.get("expected_cache_seeds")
    if want_seeds is not None:
        got_seeds, why = _recorded_cache_seeds(recorded)
        if why is not None:
            return Result(t.id, "failed", why, artefacts={"atoms": got_atoms})
        if got_seeds != want_seeds:
            return Result(t.id, "failed",
                f"rfcs CacheSeeds: want {want_seeds}, got {got_seeds}",
                artefacts={"atoms": got_atoms, "cache_seeds": got_seeds})

    want_kinds = expect.get("expected_stream_kinds")
    if want_kinds is not None:
        projected = _event_sequence_projection(want_kinds, stream_kinds)
        if projected != want_kinds:
            return Result(t.id, "failed",
                f"the stream's events of the stated kinds are {projected}, "
                f"want {want_kinds}; whole stream {stream_kinds}",
                artefacts={"atoms": got_atoms})

    return Result(t.id, "passed",
        artefacts={"atoms": got_atoms,
                   "stream_bytes": len(stream),
                   "replay": None if late else {
                       k: getattr(res, k)
                       for k in ("asserts", "clocks", "rule_fires")}})


def _withdraw_cause_name(withdraw) -> str:
    """A decoded `FactWithdraw`'s cause by its name in the proto's
    `FactWithdraw.Cause` (`TTL_EXPIRED` for 2), or `CAUSE_<n>` for a number
    this build's enum does not hold ([RFCS.7a.2]): a reader carries such a
    number, so the name has to be one it can always give."""
    enum = withdraw.DESCRIPTOR.fields_by_name["cause"].enum_type
    value = enum.values_by_number.get(withdraw.cause)
    return value.name if value is not None else f"CAUSE_{withdraw.cause}"


def _announced_slots(recorded: list,
                     schemas: set) -> "tuple[list, str | None]":
    """`rfcs_roundtrip`'s `expected_slots` ([RFCS.5.1]): every `Slot`
    atom of the named schemas, in stream order, as the fields it carries.

    `recorded` is libds's reading of the stream (`pyds.atoms.iter_atoms`).
    Each `Slot` is its generated message, whose `ListFields` reports only the
    fields PRESENT: proto3 omits a zero, so a field the writer left at its
    default is absent here and absent from the fixture. An enum reads as its
    number, as the fixture writes it. `test_behave.m`'s `announced_slots`
    reads the Mercury runtime's recording the same way."""
    from pyds import AtomKind

    out = []
    for a in recorded:
        if a.kind is not AtomKind.SLOT:
            continue
        try:
            msg = a.message()
        except Exception as e:
            return [], f"rfcs Slot atom does not parse: {e!r}"
        fields = {d.name: (int(v) if d.enum_type is not None else v)
                  for d, v in msg.ListFields()}
        if fields.get("schema_name") in schemas:
            out.append(fields)
    return out, None


def _recorded_publishes(recorded: list) -> "tuple[list, str | None]":
    """`rfcs_roundtrip`'s `expected_publishes` ([RFCS.27.1]): every
    `FactPublish` atom, in stream order, as `{"schema_name", "rule_name"}`.
    `recorded` is libds's reading of the stream (`pyds.atoms.iter_atoms`);
    each atom's generated message reads an absent field as proto3's default.
    `test_behave.m`'s `recorded_publishes` reads the Mercury runtime's
    recording the same way."""
    from pyds import AtomKind

    out = []
    for a in recorded:
        if a.kind is not AtomKind.FACT_PUBLISH:
            continue
        try:
            msg = a.message()
        except Exception as e:
            return [], f"rfcs FactPublish atom does not parse: {e!r}"
        out.append({"schema_name": msg.schema_name,
                    "rule_name": msg.rule_name})
    return out, None


def _recorded_cache_seeds(recorded: list) -> "tuple[list, str | None]":
    """`rfcs_roundtrip`'s `expected_cache_seeds` ([RFCS.26.1]): every
    `CacheSeed` atom, in stream order, as `{"key", "value_json",
    "deadline_ns"}`. `recorded` is libds's reading of the stream
    (`pyds.atoms.iter_atoms`); each atom's generated message reads an absent
    field as proto3's default. `test_behave.m`'s `recorded_cache_seeds` reads
    the Mercury runtime's recording the same way."""
    from pyds import AtomKind

    out = []
    for a in recorded:
        if a.kind is not AtomKind.CACHE_SEED:
            continue
        try:
            msg = a.message()
        except Exception as e:
            return [], f"rfcs CacheSeed atom does not parse: {e!r}"
        out.append({"key": msg.key, "value_json": msg.value_json,
                    "deadline_ns": msg.deadline_ns})
    return out, None


def _rewrite_withdraw_cause(stream: bytes,
                            rewrite: dict) -> "tuple[bytes, str | None]":
    """`rfcs_roundtrip`'s `rewrite_withdraw_cause` ([RFCS.7a.2]): the
    recording with its `index`-th `FactWithdraw` re-encoded with `cause`,
    keeping every other field. That one atom is re-framed by libds
    (`pyds.atoms.frame`); the bytes either side are libds's own, untouched.
    Returns the stream and None, or the stream unchanged and why the rewrite
    could not be made."""
    from pyds import AtomKind, atoms

    try:
        index, cause = int(rewrite["index"]), int(rewrite["cause"])
    except (KeyError, TypeError, ValueError):
        return stream, ("rewrite_withdraw_cause: want "
                        "{\"index\": <int>, \"cause\": <uint32>}")
    withdrawals = [a for a in atoms.iter_atoms(stream)
                   if a.kind is AtomKind.FACT_WITHDRAW]
    if not 0 <= index < len(withdrawals):
        return stream, (f"rewrite_withdraw_cause: the run has no "
                        f"withdrawal {index}")
    target = withdrawals[index]
    msg = target.message()
    msg.cause = cause
    framed = atoms.frame(AtomKind.FACT_WITHDRAW, msg.SerializeToString())
    return stream[:target.offset] + framed + stream[target.end:], None


def _run_rfcs_artefact_strip(t: ConformanceTest) -> Result:
    """Inspection without the rule artefact [LFST.8].

    Record a session containing a typed fact with libds's own recorder
    (`Engine.record`), read it with libds's reader (`pyds.atoms`), and
    assert:

      - LFST.8.2: the envelope reads with no artefact, by value: each
        FactAssert's schema_name is the one asserted, its clock_ns the mock
        clock at that assert, the fact_ids non-zero and distinct, the seqs
        strictly ascending;
      - LFST.8.3: the opaque payload bytes are there;
      - LFST.8.10: libds types the body against the loaded artefact
        (`Engine.decode_fact_body`), and the slots are the values asserted.

    The announcement's half of LFST.8.10 (a body typed by the stream's own Slot
    atoms, [RFCS.5.1]) is libds's `ds_rfcs_decode_announced_fact_body`, pinned
    in C (test_rfcs_announced_body.c).
    """
    import tempfile

    import pyds
    from pyds import AtomKind, atoms

    expect = t.expect
    eng = _engine_from_source(t.rules_ds, file=t.path.name)
    _mock_clocks(eng)

    # (schema, slots, clock_ns) per host assert, in order: the fact as the
    # engine holds it, and the mock clock it was asserted at.
    asserted: list = []
    scratch = os.environ["DS_MERCURY_SCRATCH"]
    Path(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        path = Path(work) / f"{t.id}.dstrace"
        # [RCTS.1.2.28]'s steps, as every driver runs them (`_Session`).
        session = _Session(eng)
        eng.on_event = session.tap()
        with eng.record(path):
            for step in expect.get("steps", []):
                why = session.run(step)
                if why is not None:
                    return Result(t.id, "failed", why)
                if step["op"] == "assert":
                    info = eng.facts[session.last_assert]
                    asserted.append((info.schema, dict(info.slots),
                                     eng.clock.now_ns))
        stream = path.read_bytes()

    try:
        recorded = list(atoms.iter_atoms(stream))
    except pyds.Error as e:
        return Result(t.id, "failed",
            f"libds's reader refused libds's own recording: {e}")
    facts = [a.message() for a in recorded if a.kind is AtomKind.FACT_ASSERT]
    if not facts:
        return Result(t.id, "failed",
            "rfcs_artefact_strip: no FactAssert atom recorded (need an assert "
            "step)")
    if len(facts) != len(asserted):
        return Result(t.id, "failed",
            f"rfcs_artefact_strip: {len(facts)} FactAssert atom(s) recorded "
            f"for {len(asserted)} host assert(s)")

    # LFST.8.2: the envelope, read with no artefact.
    fact_ids = [f.fact_id for f in facts]
    if 0 in fact_ids or len(set(fact_ids)) != len(fact_ids):
        return Result(t.id, "failed",
            f"rfcs_artefact_strip: envelope fact_ids {fact_ids} are not "
            f"non-zero and distinct (LFST.8.2)")
    seqs = [f.seq for f in facts]
    if any(b <= a for a, b in zip(seqs, seqs[1:])):
        return Result(t.id, "failed",
            f"rfcs_artefact_strip: envelope seqs {seqs} do not strictly "
            f"ascend (LFST.8.2)")

    for fact, (schema, values, clock_ns) in zip(facts, asserted):
        if fact.schema_name != schema:
            return Result(t.id, "failed",
                f"rfcs_artefact_strip: envelope schema_name {fact.schema_name!r}, "
                f"the host asserted {schema!r}")
        if fact.clock_ns != clock_ns:
            return Result(t.id, "failed",
                f"rfcs_artefact_strip: envelope clock_ns {fact.clock_ns} for "
                f"{schema!r}, asserted at {clock_ns} (LFST.8.2)")
        # LFST.8.3: the opaque payload bytes, held by the decode below.
        body = fact.fact
        try:
            full = eng.decode_fact_body(schema, body)
        except (KeyError, ValueError, pyds.Error) as e:
            return Result(t.id, "failed",
                f"rfcs_artefact_strip: artefacted decode refused: {e!r}")
        if full != values:
            return Result(t.id, "failed",
                "rfcs_artefact_strip: the decoded slots are not the values "
                f"asserted — decoded={full!r} asserted={values!r}")

    return Result(t.id, "passed",
        artefacts={"fact_asserts": len(facts)})


def _run_hash_order_independence(t: ConformanceTest) -> Result:
    """Hash-order independence [LCON.2.4].

    LCON.2.4.1 requires bit-identical output when hash iteration order
    is perturbed. DS's hashing is deterministic, with no hash-reversal knob, so
    the observable proxy for internal hash-table layout is fact insertion order.

    `expect`:
    ```
    {
      "kind": "hash_order_independence",
      "schema": "A", "slot": "id",
      "orders": [[1,2,3], [3,2,1], [2,3,1]],
      "pump": true
    }
    ```
    Each order asserts `schema(slot=v)` for v in the list, pumps, and
    captures rule-fire order + fact_count; all orders must match.
    """
    import pyds

    expect = t.expect
    schema = expect["schema"]
    slot = expect["slot"]
    orders = expect.get("orders", [])
    if len(orders) < 2:
        return Result(t.id, "failed",
            "hash_order_independence needs >=2 insertion orders to compare")

    def run_order(values):
        eng = _engine_from_source(t.rules_ds, file=t.path.name)
        _mock_clocks(eng)
        eng.set_call_callback(lambda req: None)
        eng.on_cache_set = lambda k, v, ttl: None
        eng.on_cache_delete = lambda k, reason: None
        fires: list[str] = []
        eng.on_event = (
            lambda ev: fires.append(ev.rule_name)
            if ev.kind == "rule_fire_begin" else None)
        for v in values:
            eng.assert_(schema, **{slot: v})
        if expect.get("pump", True):
            eng.pump()
        return {"fires": fires, "fact_count": len(eng.facts)}

    baseline = run_order(orders[0])
    for other in orders[1:]:
        got = run_order(other)
        if got["fires"] != baseline["fires"]:
            return Result(t.id, "failed",
                f"hash_order_independence: rule-fire order differs between "
                f"insertion order {orders[0]} -> {baseline['fires']} and "
                f"{other} -> {got['fires']}",
                artefacts={"baseline": baseline, "other": got})
        if got["fact_count"] != baseline["fact_count"]:
            return Result(t.id, "failed",
                f"hash_order_independence: fact_count differs between "
                f"{orders[0]} ({baseline['fact_count']}) and "
                f"{other} ({got['fact_count']})")

    want_fires = expect.get("expected_fire_order")
    if want_fires is not None and baseline["fires"] != want_fires:
        return Result(t.id, "failed",
            f"hash_order_independence: fire order {baseline['fires']} "
            f"!= expected {want_fires}")

    return Result(t.id, "passed",
        artefacts={"orders_compared": len(orders),
                   "fires": baseline["fires"],
                   "fact_count": baseline["fact_count"]})


def _step_slot_value(value):
    """A step's slot value as pyds takes it. JSON has no bytes, so a `Bytes`
    slot is written `{"$bytes": "<hex>"}` and given to pyds as `bytes`; and a
    `String` slot whose text is not well-formed UTF-8 ([LSTR.8.5]) is written
    `{"$text_bytes": "<hex>"}` and given to pyds as `bytes`, which pyds hands
    libds as the text unchanged (`_text_bytes_misplaced` holds the form to
    `String` slots). `test_behave.m`'s `slot_value` reads both forms. Any
    other value is passed as written."""
    if isinstance(value, dict) and set(value) == {"$bytes"}:
        return bytes.fromhex(value["$bytes"])
    if isinstance(value, dict) and set(value) == {"$text_bytes"}:
        return bytes.fromhex(value["$text_bytes"])
    return value


def _run_logical_test(t: ConformanceTest) -> Result:
    """Drive a logical-category test through pyds with a stream
    subscription and assert against the resulting event sequence.

    `expect.kind` honoured here:
    - `event_sequence` — compile + load + register stream cb +
      run an ordered sequence of `steps` (assert / pump / advance /
      set) + check that the captured event stream, cut down to the
      kinds `expected_kinds` names, is `expected_kinds` (other kinds
      interleave freely; every event of a named kind is stated).

    Step shape matches `temporal_sequence`. `expected_kinds` is a
    list of strings (the `kind` of each `pyds.events` value).
    """
    import pyds

    expect = t.expect
    kind = expect.get("kind")
    if kind not in ("event_sequence", "event_sequence_strict",
                    "event_seq_monotonic", "event_kinds_forbidden",
                    "rule_fire_order", "log_message_sequence",
                    "header_field_eq", "introspection_assert"):
        return Result(
            t.id, "failed", f"unknown logical expect.kind `{kind}`",
        )
    if kind == "introspection_assert":
        why = _introspection_refusal(expect)
        if why is not None:
            return Result(t.id, "failed", f"malformed fixture: {why}")
    why = _event_list_refusal(expect) or _logical_fields_refusal(expect)
    if why is not None:
        return Result(t.id, "failed", f"malformed fixture: {why}")

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)

    # `add_schema_ref` (optional, [RCTS.1.2.26], [RDSC.5.5.5]): `{"schema": S, "slot":
    # N, "ref": R}` gives the compiled artefact's Slot atom for S.N the
    # `schema_ref` R and re-seals it (`dsc_seal.add_slot_schema_ref`).
    # `test_behave.m`'s `schema_ref_added` makes the same edit.
    add_ref = expect.get("add_schema_ref")
    if add_ref is not None:
        from dsc_seal import add_slot_schema_ref
        edited = None
        if (isinstance(add_ref, dict)
                and set(add_ref) == {"schema", "slot", "ref"}
                and all(isinstance(v, str) for v in add_ref.values())):
            edited = add_slot_schema_ref(dsc_bytes, add_ref["schema"],
                                         add_ref["slot"], add_ref["ref"])
        if edited is None:
            return Result(t.id, "failed",
                f"add_schema_ref {add_ref!r} has no site in this artefact")
        dsc_bytes = edited

    eng = pyds.Engine()
    eng.load_dsc(dsc_bytes)
    _mock_clocks(eng, wall="wall_clock" not in expect)

    # A pump fails on a call, cache or cache_delete with no callback
    # (IDSP.6/7/8).
    eng.set_call_callback(lambda req: None)
    eng.on_cache_set = lambda key, value_json, ttl_ns: None
    eng.on_cache_delete = lambda key, reason: None

    events: list = []
    session = _Session(eng)
    eng.on_event = session.tap(events.append)

    for step in expect.get("steps", []):
        why = session.run(step)
        if why is not None:
            return Result(t.id, "failed", why)

    observed_kinds = [str(ev.kind) for ev in events]
    coverage = _coverage_artefact(t.rules_ds, events)
    artefacts = {"coverage": coverage} if coverage else None

    if kind == "header_field_eq":
        # The fact-stream session header (LFST.4, RFCS.4). Each entry in
        # `checks` names a header `field` and one assertion mode:
        #   {"field": "version", "equals": 2}        — exact value
        #   {"field": "session_id", "present": true} — non-empty (true)
        #                                              / empty (false)
        #   {"field": "dsc_hash", "byte_len": 32}    — len() of a bytes
        #                                              field
        session = eng.session_header
        hdr = {f.name: getattr(session, f.name) for f in fields(session)}
        for chk in expect.get("checks", []):
            field = chk["field"]
            if field not in hdr:
                return Result(t.id, "failed",
                    f"header field `{field}` absent from session header "
                    f"(have: {sorted(hdr)})", artefacts=artefacts)
            got = hdr[field]
            if "equals" in chk:
                if got != chk["equals"]:
                    return Result(t.id, "failed",
                        f"header `{field}`: want {chk['equals']!r}, got {got!r}",
                        artefacts=artefacts)
            elif "present" in chk:
                is_present = bool(got)
                if is_present != bool(chk["present"]):
                    return Result(t.id, "failed",
                        f"header `{field}` present={is_present}, "
                        f"want present={bool(chk['present'])} (value {got!r})",
                        artefacts=artefacts)
            elif "byte_len" in chk:
                if not isinstance(got, (bytes, bytearray)):
                    return Result(t.id, "failed",
                        f"header `{field}` byte_len check needs bytes, "
                        f"got {type(got).__name__} ({got!r})",
                        artefacts=artefacts)
                if len(got) != chk["byte_len"]:
                    return Result(t.id, "failed",
                        f"header `{field}` byte_len: want {chk['byte_len']}, "
                        f"got {len(got)}", artefacts=artefacts)
            else:
                return Result(t.id, "failed",
                    f"header check for `{field}` has no assertion "
                    f"(need equals / present / byte_len): {chk!r}",
                    artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    if kind == "introspection_assert":
        # The runtime introspection surface (LCON.4.5.1) after the steps. Each
        # entry in `checks` selects a surface and one assertion, from
        # [RCTS.1.2.26]'s closed set (`_SURFACES`, held by
        # `_introspection_refusal`):
        #
        #   {"surface": "fact_count", "equals": 2}
        #       — total live facts in working memory.
        #   {"surface": "justifiers", "fact_id": 2,
        #    "expect_rules": ["derive"]}
        #       — debug.justifiers(fact_id) rule_names equal this set
        #         (order-independent).
        #   {"surface": "justifier_count", "fact_id": 2, "count": 1}
        #       — number of justifiers for fact_id.
        #   {"surface": "rete_network", "min_nodes": 3, "min_edges": 2}
        #       — Rete node/edge counts are at least these (NATIVE_RETE).
        #   {"surface": "slot_schema_ref", "schema": "S", "slot": "n",
        #    "equals": null}
        #       — the schema the loaded slot S.n names as its reference, or
        #         null for none ([RDSC.5.5.5], [NFCT.1.4.1]).
        for chk in expect.get("checks", []):
            surface = chk.get("surface")
            if surface == "fact_count":
                got = len(eng.facts)
                if got != chk["equals"]:
                    return Result(t.id, "failed",
                        f"introspection fact_count: want {chk['equals']}, "
                        f"got {got}", artefacts=artefacts)
            elif surface == "justifiers":
                got = eng.debug.justifiers(int(chk["fact_id"]))
                got_rules = sorted(j.rule_name for j in got)
                want_rules = sorted(chk["expect_rules"])
                if got_rules != want_rules:
                    return Result(t.id, "failed",
                        f"justifiers(fact_id={chk['fact_id']}): want rules "
                        f"{want_rules}, got {got_rules} (raw {got})",
                        artefacts=artefacts)
            elif surface == "justifier_count":
                got = eng.debug.justifiers(int(chk["fact_id"]))
                if len(got) != chk["count"]:
                    return Result(t.id, "failed",
                        f"justifier_count(fact_id={chk['fact_id']}): want "
                        f"{chk['count']}, got {len(got)} ({got})",
                        artefacts=artefacts)
            elif surface == "rete_network":
                net = eng.debug.network()
                n_nodes = len(net.nodes)
                n_edges = len(net.edges)
                if "min_nodes" in chk and n_nodes < chk["min_nodes"]:
                    return Result(t.id, "failed",
                        f"rete_network nodes: want >= {chk['min_nodes']}, "
                        f"got {n_nodes}", artefacts=artefacts)
                if "min_edges" in chk and n_edges < chk["min_edges"]:
                    return Result(t.id, "failed",
                        f"rete_network edges: want >= {chk['min_edges']}, "
                        f"got {n_edges}", artefacts=artefacts)
            elif surface == "slot_schema_ref" and "equals" in chk:
                schema = eng.schemas.get(chk.get("schema"))
                slot = None if schema is None else next(
                    (s for s in schema.slots if s.name == chk.get("slot")), None)
                if slot is None:
                    return Result(t.id, "failed",
                        f"slot_schema_ref: no slot {chk.get('schema')}."
                        f"{chk.get('slot')}", artefacts=artefacts)
                if slot.schema_ref != chk["equals"]:
                    return Result(t.id, "failed",
                        f"slot_schema_ref {chk['schema']}.{chk['slot']}: want "
                        f"{chk['equals']!r}, got {slot.schema_ref!r}",
                        artefacts=artefacts)
            else:
                return Result(t.id, "failed",
                    f"introspection check has unknown/missing surface: {chk!r}",
                    artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    if kind == "event_seq_monotonic":
        # Optional `filter_kind`: the seq and clock checks operate on the
        # sub-stream of that kind.
        filter_kind = expect.get("filter_kind")
        events_view = (
            [ev for ev in events if ev.kind == filter_kind]
            if filter_kind else events
        )
        seqs = [ev.seq for ev in events_view]
        for i in range(1, len(seqs)):
            if seqs[i] <= seqs[i-1]:
                return Result(t.id, "failed",
                    f"seq not strictly increasing: ...{seqs[i-1]}, {seqs[i]}...",
                    artefacts=artefacts)
        if len(seqs) < expect.get("min_events", 1):
            return Result(t.id, "failed",
                f"too few events captured: {len(seqs)} < {expect.get('min_events', 1)}",
                artefacts=artefacts)
        # Optional `expected_seq_step`: each consecutive pair of seqs differs
        # by exactly this value.
        want_step = expect.get("expected_seq_step")
        if want_step is not None:
            for i in range(1, len(seqs)):
                if seqs[i] - seqs[i-1] != want_step:
                    return Result(t.id, "failed",
                        f"seq step at index {i}: want +{want_step}, "
                        f"got +{seqs[i] - seqs[i-1]} ({seqs[i-1]}→{seqs[i]})",
                        artefacts=artefacts)
        # Optional `expected_clocks`: clock_ns values per event index.
        want_clocks = expect.get("expected_clocks")
        if want_clocks is not None:
            got = [ev.clock_ns for ev in events_view[:len(want_clocks)]]
            if got != want_clocks:
                return Result(t.id, "failed",
                    f"expected_clocks prefix mismatch: want {want_clocks}, got {got}",
                    artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    if kind == "rule_fire_order":
        fired = [ev.rule_name for ev in events
                 if ev.kind == "rule_fire_begin"]
        expected_names = expect["expected_rule_names"]
        if fired != expected_names:
            return Result(t.id, "failed",
                f"rule fire order: want {expected_names}, got {fired}",
                artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    if kind == "log_message_sequence":
        messages = [ev.message for ev in events
                    if ev.kind == "action_log"]
        expected_messages = expect["expected_messages"]
        if messages != expected_messages:
            return Result(t.id, "failed",
                f"log message sequence: want {expected_messages}, got {messages}",
                artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    if kind == "event_kinds_forbidden":
        forbidden = set(expect["forbidden_kinds"])
        seen = forbidden & set(observed_kinds)
        if seen:
            return Result(t.id, "failed",
                f"forbidden kinds appeared in stream: {sorted(seen)}",
                artefacts=artefacts)
        return Result(t.id, "passed", artefacts=artefacts)

    expected = list(expect["expected_kinds"])

    if kind == "event_sequence_strict":
        if observed_kinds != expected:
            return Result(
                t.id, "failed",
                f"strict mismatch: want {expected}, got {observed_kinds}",
                artefacts=artefacts,
            )
        return Result(t.id, "passed", artefacts=artefacts)

    # Default: the projection match ([RCTS.1.2.10]).
    projected = _event_sequence_projection(expected, observed_kinds)
    if projected != expected:
        return Result(
            t.id, "failed",
            f"the stream's events of the stated kinds are {projected}, "
            f"want {expected}; whole stream {observed_kinds}",
            artefacts=artefacts,
        )
    return Result(t.id, "passed", artefacts=artefacts)


def _event_sequence_projection(expected: list[str],
                               observed: list[str]) -> list[str]:
    """`observed` cut down to the kinds `expected` names, in stream order.

    [RCTS.1.2.10]: an `event_sequence` passes when this is `expected`.
    Kinds the vector does not name interleave freely; every event of a
    kind it names is stated. `test_behave.m`'s `projection/2` is the same
    function."""
    named = set(expected)
    return [k for k in observed if k in named]


def _run_cross_tier_test(t: ConformanceTest) -> Result:
    """Drive a cross-tier-category test against multiple pyds engines.

    Test JSON:
    ```
    {
      "engines": { "a": { "rules_ds": "..." },
                   "b": { "rules_ds": "..." } },
      "steps":   [ { "engine": "a", "op": "assert", "schema": "X", ... },
                   { "engine": "b", "op": "pump" }, ... ],
      "expect":  { "kind": "cross_tier_fact_counts",
                   "engine_fact_counts_after": { "a": 1, "b": 0 } }
    }
    ```

    Each engine is a fresh `pyds.Engine` per IARC.1.11 (multiple
    engines coexist with no shared state). The steps thread an
    `engine` field that picks which one each op targets. All
    engines run in mock-clock mode at t=0 by default — `advance`
    / `set` ops are independent per-engine.

    `{"engine": "b", "op": "forward", "from": "a"}` is the integrator's
    cross-tier bridge, exactly as [NCBK.10.1] describes it: what `a`
    published is asserted into `b` by schema name and slot values.

    `{"engine": "b", "op": "forward_external", "from": "a"}` carries the
    same publications as the FactExternal records each publish event holds
    ([RFCS.23.1]), into `b`'s `assert_external` ([NCBK.10.4]), so a vector
    can reach RFCS.23's receiving side.

    `expect.kind` honoured here:
    - `cross_tier_fact_counts` — assert each engine's
      fact_count after all steps complete.
    - `cross_tier_per_engine_event_counts` — assert each
      engine's stream captured a specific count of a specific
      event kind.

    Either kind may carry `expected_pump_statuses` ([RCTS.1.2.30]): every
    `pump` step's status, on whichever engine it names, in step order, so a
    refused pump is the step's outcome and the steps go on. And
    `expected_published_asserted_at` ([RCTS.1.2.29]): per engine, the
    `asserted_at` each publication's FactExternal carried. Both are judged
    before the kind's own expectation.
    """
    import pyds

    expect = t.expect
    kind = expect.get("kind")
    if kind not in ("cross_tier_fact_counts",
                    "cross_tier_per_engine_event_counts"):
        return Result(
            t.id, "failed", f"unknown cross-tier expect.kind `{kind}`",
        )

    engines_decl = expect.get("engines")
    if not engines_decl:
        return Result(
            t.id, "failed",
            "cross-tier test missing `expect.engines` mapping",
        )

    engines: dict[str, pyds.Engine] = {}
    engine_events: dict[str, list] = {label: [] for label in engines_decl}
    # What each engine PUBLISHED, as [NCBK.10.1] bridges it: on
    # DS_EV_ACTION_PUBLISH, the schema name and the slot values the event
    # carries, copied while the callback runs ([RCTS.1.2.29], [NCBK.2.5]: the
    # fact is a view for the callback only, and in no working memory of the
    # engine that published it, [LTIE.4.3]). An `emit` is never captured:
    # [NCBK.10.2] gates on PUBLISH.
    published: dict[str, list[tuple[str, dict]]] = {
        label: [] for label in engines_decl}
    # The same publications as the FactExternal each event carried
    # ([RFCS.23.1]: `action_publish.external`), for `forward_external`.
    published_external: dict[str, list[bytes]] = {
        label: [] for label in engines_decl}
    # How far each (from, to) pair has been forwarded, so a second `forward`
    # carries only what was published since the first; and the same for
    # `forward_external`, apart.
    forwarded: dict[tuple[str, str], int] = {}
    forwarded_external: dict[tuple[str, str], int] = {}

    def _stream_cb(label: str):
        def cb(ev) -> None:
            engine_events[label].append(ev)
            if ev.kind == "action_publish":
                published[label].append((ev.schema, dict(ev.slots)))
                published_external[label].append(bytes(ev.external))
        return cb

    sessions: dict[str, _Session] = {}
    for label, decl in engines_decl.items():
        src = decl["rules_ds"]
        dsc_bytes = _compile_fixture(f"{t.path.name}#{label}", src,
                                     test_id=t.id, rules_ds=t.rules_ds,
                                     libraries=t.libraries)
        eng = pyds.Engine()
        eng.load_dsc(dsc_bytes)
        # [RCTS.1.2.29]: an engine declared with `"wall_clock": "unset"`
        # keeps its mock wall clock unset until a `wall_set` step gives it one.
        _mock_clocks(eng, wall=decl.get("wall_clock") != "unset")
        eng.set_call_callback(lambda req: None)
        eng.on_cache_set = lambda key, value_json, ttl_ns: None
        eng.on_cache_delete = lambda key, reason: None
        sessions[label] = _Session(eng)
        eng.on_event = sessions[label].tap(_stream_cb(label))
        engines[label] = eng

    want_statuses = expect.get("expected_pump_statuses")
    got_statuses: list[int] = []
    for step in expect.get("steps", []):
        label = step["engine"]
        eng = engines.get(label)
        if eng is None:
            return Result(
                t.id, "failed",
                f"step targets unknown engine `{label}`",
            )
        op = step["op"]
        if op == "pump":
            # [RCTS.1.2.30]: with the field, a refused pump is its status and
            # the steps go on; without it, `run_test` fails the fixture
            # ([RCTS.1.2.28]).
            try:
                eng.pump()
                got_statuses.append(0)
            except pyds.Error as e:
                if want_statuses is None or e.status is None:
                    e.refused_step = step
                    raise
                got_statuses.append(int(e.status))
        elif op == "forward":
            # Every fact `a` published since the last forward to `b`, in
            # publication order. Nothing else crosses ([NCBK.10.3]).
            src = step.get("from")
            if src not in engines:
                return Result(t.id, "failed",
                    f"forward: unknown source engine `{src}`")
            start = forwarded.get((src, label), 0)
            for schema, slots in published[src][start:]:
                eng.assert_(schema, **slots)
            forwarded[(src, label)] = len(published[src])
        elif op == "forward_external":
            # `test_behave.m` drives `ds.fact_receive.assert_external` the same
            # way.
            src = step.get("from")
            if src not in engines:
                return Result(t.id, "failed",
                    f"forward_external: unknown source engine `{src}`")
            start = forwarded_external.get((src, label), 0)
            for data in published_external[src][start:]:
                eng.assert_external(data)
            forwarded_external[(src, label)] = len(published_external[src])
        else:
            why = sessions[label].run(step)
            if why is not None:
                return Result(t.id, "failed", f"engine `{label}`: {why}")

    if want_statuses is not None and got_statuses != want_statuses:
        return Result(t.id, "failed",
            f"pump statuses: want {want_statuses}, got {got_statuses}")
    want_at = expect.get("expected_published_asserted_at")
    if want_at is not None:
        why = _published_asserted_at_mismatch(want_at, published_external)
        if why is not None:
            return Result(t.id, "failed", why)

    if kind == "cross_tier_per_engine_event_counts":
        # Test JSON shape:
        # "expected_event_counts": { "<engine>": { "<event_kind>": N } }
        want = expect["expected_event_counts"]
        for label, want_kinds in want.items():
            evs = engine_events.get(label, [])
            for want_kind, want_n in want_kinds.items():
                got_n = sum(1 for e in evs if e.kind == want_kind)
                if got_n != want_n:
                    return Result(
                        t.id, "failed",
                        f"engine `{label}` event `{want_kind}` count: "
                        f"want {want_n}, got {got_n}",
                        artefacts={
                            "engine_events": {
                                k: [str(e.kind) for e in v]
                                for k, v in engine_events.items()
                            },
                        },
                    )
        return Result(t.id, "passed")

    want_counts = expect["engine_fact_counts_after"]
    for label, want in want_counts.items():
        eng = engines.get(label)
        if eng is None:
            return Result(
                t.id, "failed",
                f"engine_fact_counts_after references unknown engine `{label}`",
            )
        got = len(eng.facts)
        if got != want:
            return Result(
                t.id, "failed",
                f"engine `{label}` fact_count: want {want}, got {got}",
            )
    return Result(t.id, "passed")


def _run_adapter_mock(t: ConformanceTest) -> Result:
    """Adapter-mock catalogue (LCON.4.3.1).

    When a rule's `call` to a mocked service fires, the harness asserts the
    declared response fact back into the engine, keyed on the call's correlation
    (LCRS.3.1), and re-pumps so the `on response:` continuation runs. The mock
    is the only responder (LCON.4.3.2).

    `expect` shape:
    ```
    {
      "kind": "adapter_mock",
      "mocks": [
        { "service": "svc.read",
          "respond_schema": "SvcReadReply",
          "respond_slots": { "ok": true } }
      ],
      "steps": [ { "op": "assert", "schema": "Trig", "slots": {...} },
                 { "op": "pump" } ],
      "expected_logs": ["got response"]
    }
    ```

    Each mock matches a `service` and names its `respond_schema`, the
    service's declared response schema (LCRS.4.3.1): there is no default,
    because no built-in response schema exists. `respond_slots` supplies
    every slot of `respond_schema` except `corr`, which the harness fills with the
    firing call's correlation. After the scripted steps, the harness
    keeps delivering responses + pumping until no new un-answered call
    appears (a fixed point), so multi-hop call→response→call chains
    resolve. `expected_logs` asserts the continuation outputs in order.
    """
    import pyds

    expect = t.expect
    mocks_by_service = {m["service"]: m for m in expect.get("mocks", [])}

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)
    eng = pyds.Engine()
    eng.load_dsc(dsc_bytes)
    _mock_clocks(eng)

    # The pump is mid-flight in the call callback, so responses are delivered
    # between pumps.
    pending_calls: list[dict] = []
    eng.set_call_callback(lambda req: pending_calls.append(dict(req)))
    eng.on_cache_set = lambda key, value_json, ttl_ns: None
    eng.on_cache_delete = lambda key, reason: None

    events: list = []
    session = _Session(eng)
    eng.on_event = session.tap(events.append)

    answered: set[str] = set()

    def _deliver_pending() -> int:
        """Assert a mocked response fact for each captured call to a
        mocked service that hasn't been answered yet. Returns the
        number of responses delivered this round."""
        delivered = 0
        for req in list(pending_calls):
            corr = req["correlation"]
            if corr in answered:
                continue
            mock = mocks_by_service.get(req["service"])
            if mock is None:
                continue  # un-mocked service: no response (tests absence)
            slots = dict(mock.get("respond_slots", {}))
            slots["corr"] = corr
            eng.assert_(mock["respond_schema"], **slots)
            answered.add(corr)
            delivered += 1
        return delivered

    for step in expect.get("steps", []):
        why = session.run(step)
        if why is not None:
            return Result(t.id, "failed", why)

    # Drive the call→response→(maybe call) chain to a fixed point:
    # deliver any mocked responses, pump, repeat until nothing new.
    # Bounded to avoid a runaway loop on a misdesigned fixture.
    for _ in range(64):
        if _deliver_pending() == 0:
            break
        eng.pump()

    coverage = _coverage_artefact(t.rules_ds, events)
    artefacts = {"coverage": coverage} if coverage else None

    expected_logs = expect.get("expected_logs")
    if expected_logs is not None:
        got_logs = [e.message for e in events
                    if e.kind == "action_log"]
        if got_logs != expected_logs:
            return Result(t.id, "failed",
                f"continuation logs: want {expected_logs}, got {got_logs}",
                artefacts=artefacts)

    want_calls = expect.get("expected_call_count")
    if want_calls is not None and len(pending_calls) != want_calls:
        return Result(t.id, "failed",
            f"call count: want {want_calls}, got {len(pending_calls)} "
            f"({[c['service'] for c in pending_calls]})",
            artefacts=artefacts)

    want_fc = expect.get("fact_count_after")
    if want_fc is not None:
        got_fc = len(eng.facts)
        if got_fc != want_fc:
            return Result(t.id, "failed",
                f"fact_count_after: want {want_fc}, got {got_fc}",
                artefacts=artefacts)

    return Result(t.id, "passed", artefacts=artefacts)


def _run_hydration_runtime(t: ConformanceTest) -> Result:
    """Hydration runtime fixtures (LHYD.4 / 6 / 7).

    Extends the adapter_mock pattern with an integrator that replies to a
    `call storage.hydrate_*`: it reads the request (correlation + args
    carrying schema / window / retain), asserts the requested hydrated facts,
    each tagged hydrated_corr=<correlation>, then a HydrationComplete. A request
    carrying `retain` is refused: no public entry point sets a per-fact TTL.

    `expect` shape:
    ```
    {
      "kind": "hydration_runtime",
      "hydrate_mocks": [
        { "service": "storage.hydrate_events",
          "facts": [ {"zone": "z1"}, {"zone": "z2"} ],
          "complete": true } ],
      "budget": 2,                       # refused: no setter
      "steps": [ {"op":"assert","schema":"Trig","slots":{...}},
                 {"op":"pump"}, {"op":"deliver"},
                 {"op":"advance","delta_ns": 660000000000} ],
      "expected_logs": [...],            # optional, exact ordered match
      "expected_call_count": K,          # optional: hydrate dispatches captured
      "fact_count_after": N              # optional
    }
    ```
    A `deliver` step plays the integrator for every captured-but-unanswered
    hydrate call (tracked by position, so a repeat same-corr call is
    delivered again and exercises the supersede sweep) and pumps once. The
    budget gate asserts CallError instead of dispatching, so a rejected call
    never reaches the integrator (no delivery) -- observe it via a rule on
    CallError. `facts` lists each hydrated fact's author slots; the harness
    fills hydrated_corr from the firing call's correlation.
    """
    import pyds

    expect = t.expect
    hydrate_mocks = {m["service"]: m for m in expect.get("hydrate_mocks", [])}

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)
    eng = pyds.Engine()
    eng.load_dsc(dsc_bytes)
    _mock_clocks(eng)

    if expect.get("budget") is not None:
        # Running on the default would pass a vector that tests the budget.
        raise RuntimeError(
            "hydration_runtime: `budget` needs a hydration-budget setter, "
            "which no public entry point offers")

    pending_calls: list[dict] = []
    eng.set_call_callback(lambda req: pending_calls.append(dict(req)))
    eng.on_cache_set = lambda key, value_json, ttl_ns: None
    eng.on_cache_delete = lambda key, reason: None

    events: list = []
    session = _Session(eng)
    eng.on_event = session.tap(events.append)

    delivered_idx: set[int] = set()

    def _deliver() -> int:
        """Play the integrator for each captured hydrate call not yet
        answered (tracked by position, so a repeat same-corr call is
        delivered again and drives the supersede sweep)."""
        n = 0
        for i, req in enumerate(pending_calls):
            if i in delivered_idx:
                continue
            mock = hydrate_mocks.get(req["service"])
            if mock is None:
                continue
            delivered_idx.add(i)
            corr = req["correlation"]
            args = req.get("args") or {}
            schema = args.get("schema") or mock.get("schema")
            retain = args.get("retain")
            facts = mock.get("facts", [])
            if retain:
                # Asserting the rows plainly would let them outlive `retain`
                # and pass a vector that tests it.
                raise RuntimeError(
                    "hydration_runtime: `retain` needs a per-fact TTL, which "
                    "no public entry point sets")
            for f in facts:
                slots = dict(f)
                slots["hydrated_corr"] = corr
                eng.assert_(schema, **slots)
            if mock.get("complete", True):
                # The queried schema's slot is `schema_name`: `schema` is a
                # reserved word ([LLEX.9.6]).
                eng.assert_("HydrationComplete", corr=corr,
                            schema_name=schema,
                            count=len(facts), truncated=False,
                            t_start=0.0, t_end=0.0)
            n += 1
        return n

    for step in expect.get("steps", []):
        why = session.run(step)
        if why is not None:
            return Result(t.id, "failed", why)

    # After the steps, deliver any outstanding hydrate calls and pump to a
    # fixed point.
    for _ in range(64):
        if _deliver() == 0:
            break
        eng.pump()

    expected_logs = expect.get("expected_logs")
    if expected_logs is not None:
        got_logs = [e.message for e in events
                    if e.kind == "action_log"]
        if got_logs != expected_logs:
            return Result(t.id, "failed",
                f"continuation logs: want {expected_logs}, got {got_logs}")

    want_calls = expect.get("expected_call_count")
    if want_calls is not None and len(pending_calls) != want_calls:
        return Result(t.id, "failed",
            f"hydrate call count: want {want_calls}, got "
            f"{len(pending_calls)} ({[c['service'] for c in pending_calls]})")

    want_fc = expect.get("fact_count_after")
    if want_fc is not None:
        got_fc = len(eng.facts)
        if got_fc != want_fc:
            return Result(t.id, "failed",
                f"fact_count_after: want {want_fc}, got {got_fc}")

    return Result(t.id, "passed")


def _run_adapter_test(t: ConformanceTest) -> Result:
    """Drive an adapter-category test through pyds with mock
    integrator-side callbacks.

    `expect.kind` honoured here:
    - `adapter_calls` — register a call cb that captures requests;
      run `steps`; assert `expected_calls` (list of dicts with
      `service` / `correlation` / `body` keys; `body` is compared with
      the call's typed arguments, pyds's `args` dict).
    - `adapter_cache_sets` — register cache set cb; assert
      `expected_sets` (list of dicts with `key` / `value` /
      optional `ttl_ns`).

    `adapter_calls` may also carry `expected_pump_statuses`
    ([RCTS.1.2.30]): one status per `pump` step, in order, 0 for a pump
    that returns. libds reports a refused action as the status of the pump
    that ran it, with no rollback, so the pump's other work stands and the
    steps after it still run. Without the key, a pump that raises fails the
    test ([RCTS.1.2.28]). `_pump_statuses_refusal` has already checked its
    placement, type and length.

    No callback here fails: the Mercury runtime runs its host's callbacks after
    the pump returns, so libds-spec holds that claim (`test_call_spec.c`,
    [IDSP.1.4]).

    Any kind may carry `expected_stream_kind_counts`, `{kind: n}`: how many
    stream events of each named kind the run produced, whatever the pumps
    returned ([IDSP.1.4]).
    """
    import json as _json

    import pyds

    expect = t.expect
    kind = expect.get("kind")
    if kind == "adapter_mock":
        return _run_adapter_mock(t)
    if kind == "hydration_runtime":
        return _run_hydration_runtime(t)
    if kind not in ("adapter_calls",
                    "adapter_cache_sets", "adapter_cache_deletes",
                    "adapter_essential_null_cb_error",
                    "adapter_cache_volatile_no_cb"):
        return Result(
            t.id, "failed", f"unknown adapter expect.kind `{kind}`",
        )

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)

    eng = pyds.Engine()
    eng.load_dsc(dsc_bytes)
    _mock_clocks(eng)

    captured: list = []
    if kind not in ("adapter_essential_null_cb_error",
                    "adapter_cache_volatile_no_cb"):
        eng.set_call_callback(lambda req: None)
        eng.on_cache_set = lambda key, value_json, ttl_ns: None
        eng.on_cache_delete = lambda key, reason: None
    if kind == "adapter_calls":
        eng.set_call_callback(captured.append)
    elif kind == "adapter_cache_sets":
        eng.on_cache_set = lambda key, value_json, ttl_ns: captured.append(
            {"key": key, "value_json": value_json, "ttl_ns": ttl_ns}
        )
    elif kind == "adapter_cache_deletes":
        # These vectors pin the key (IDSP.8b, IDSP.11.2). The reason is
        # test_cache_spec.c's.
        eng.on_cache_delete = lambda key, reason: captured.append(key)

    fire_events: list = []
    session = _Session(eng)
    eng.on_event = session.tap(fire_events.append)

    pump_error: Exception | None = None
    want_statuses = expect.get("expected_pump_statuses")
    got_statuses: list[int] = []
    # `_Session`'s steps, but for `pump`: this driver reads each pump's status.
    for step in expect.get("steps", []):
        op = step["op"]
        if op == "pump":
            try:
                eng.pump()
                got_statuses.append(0)
            except pyds.Error as e:
                if kind == "adapter_calls" and want_statuses is not None \
                        and e.status is not None:
                    got_statuses.append(int(e.status))
                    continue
                if kind in ("adapter_essential_null_cb_error",
                            "adapter_cache_volatile_no_cb"):
                    pump_error = e
                    break
                e.refused_step = step         # [RCTS.1.2.28]: `run_test`'s
                raise
            except Exception as e:
                if kind in ("adapter_essential_null_cb_error",
                            "adapter_cache_volatile_no_cb"):
                    pump_error = e
                    break
                raise
        else:
            why = session.run(step)
            if why is not None:
                return Result(t.id, "failed", why)

    if want_statuses is not None and got_statuses != want_statuses:
        return Result(t.id, "failed",
            f"pump statuses: want {want_statuses}, got {got_statuses}")

    want_counts = expect.get("expected_stream_kind_counts")
    if want_counts is not None:
        got_counts = {k: sum(1 for ev in fire_events if ev.kind == k)
                      for k in want_counts}
        if got_counts != want_counts:
            return Result(t.id, "failed",
                f"stream kind counts: want {want_counts}, got {got_counts} "
                f"(kinds seen: {[str(ev.kind) for ev in fire_events]})")

    if kind == "adapter_essential_null_cb_error":
        if pump_error is None:
            return Result(t.id, "failed",
                "expected pump to fail with essential-NULL-cb error, but it succeeded")
        want_substr = expect.get("message_contains", "")
        if want_substr and want_substr not in str(pump_error):
            return Result(t.id, "failed",
                f"want pump error message containing `{want_substr}`; got `{pump_error}`")
        return Result(t.id, "passed")

    if kind == "adapter_cache_volatile_no_cb":
        if pump_error is not None:
            return Result(t.id, "failed",
                "cache verb with no persistence callback must succeed "
                f"(volatile), but pump raised: {pump_error}")
        want_kind = expect.get("expected_stream_kind")
        if want_kind and not any(
                ev.kind == want_kind for ev in fire_events):
            return Result(t.id, "failed",
                f"expected stream event `{want_kind}`; got "
                f"{[str(ev.kind) for ev in fire_events]}")
        return Result(t.id, "passed")

    # Every adapter kind compares in order (RCTS.1.2.10).
    coverage = _coverage_artefact(t.rules_ds, fire_events)

    def _af(**extra) -> dict:
        """Build an artefacts dict including the coverage record
        (if present) plus any extras the caller wants to attach."""
        d: dict = {}
        if coverage:
            d["coverage"] = coverage
        d.update(extra)
        return d

    if kind == "adapter_calls":
        want = expect["expected_calls"]
        if len(captured) != len(want):
            return Result(
                t.id, "failed",
                f"call count: want {len(want)}, got {len(captured)} ({captured})",
                artefacts=_af(captured=captured, expected=want),
            )
        for i, (w, g) in enumerate(zip(want, captured)):
            if g["service"] != w["service"]:
                return Result(t.id, "failed",
                    f"call[{i}] service: want {w['service']!r}, got {g['service']!r}",
                    artefacts=_af(captured=captured, expected=want))
            if g["correlation"] != w.get("correlation", "auto"):
                return Result(t.id, "failed",
                    f"call[{i}] correlation: want {w.get('correlation', 'auto')!r}, "
                    f"got {g['correlation']!r}",
                    artefacts=_af(captured=captured, expected=want))
            if g["args"] != w.get("body", {}):
                return Result(t.id, "failed",
                    f"call[{i}] body: want {w.get('body', {})}, got {g['args']}",
                    artefacts=_af(captured=captured, expected=want))
    elif kind == "adapter_cache_sets":
        want = expect["expected_sets"]
        if len(captured) != len(want):
            return Result(
                t.id, "failed",
                f"cache_set count: want {len(want)}, got {len(captured)}",
                artefacts=_af(captured=captured, expected=want),
            )
        for i, (w, g) in enumerate(zip(want, captured)):
            if g["key"] != w["key"]:
                return Result(t.id, "failed",
                    f"cache_set[{i}] key: want {w['key']!r}, got {g['key']!r}",
                    artefacts=_af(captured=captured, expected=want))
            # [LDET.3.2.7]: the serialized string, exactly. The parsed compare
            # below cannot tell "42" from "42.0".
            if "value_json" in w and g["value_json"] != w["value_json"]:
                return Result(t.id, "failed",
                    f"cache_set[{i}] value_json: want {w['value_json']!r}, "
                    f"got {g['value_json']!r}",
                    artefacts=_af(captured=captured, expected=want))
            if "value" in w:
                got_value = _json.loads(g["value_json"])
                if got_value != w["value"]:
                    return Result(t.id, "failed",
                        f"cache_set[{i}] value: want {w['value']}, got {got_value}",
                        artefacts=_af(captured=captured, expected=want))
            if "ttl_ns" in w and g["ttl_ns"] != w["ttl_ns"]:
                return Result(t.id, "failed",
                    f"cache_set[{i}] ttl_ns: want {w['ttl_ns']}, got {g['ttl_ns']}",
                    artefacts=_af(captured=captured, expected=want))
    elif kind == "adapter_cache_deletes":
        want = expect["expected_keys"]
        if list(captured) != list(want):
            return Result(t.id, "failed",
                f"cache_delete keys: want {list(want)}, got {list(captured)}",
                artefacts=_af(captured=list(captured), expected=list(want)))

    artefacts = _af() or None
    return Result(t.id, "passed", artefacts=artefacts)


def _run_temporal_test(t: ConformanceTest) -> Result:
    """Drive a temporal-category test through pyds with mock-clock
    control. Tests describe a sequence of `steps` (assert / pump /
    advance / set) and a final `fact_count_after` assertion.

    `expect.kind` honoured here:
    - `temporal_sequence` — compile + load + switch to mock clock
      + run each step in order + assert final fact_count.

    Step shape (the `op` field discriminates):
    ```
    {"op": "assert", "schema": "X", "slots": { ... }}
    {"op": "advance", "delta_ns": 1_000_000_000}
    {"op": "set", "now_ns": 0}
    {"op": "pump"}
    ```
    """
    import pyds

    expect = t.expect
    kind = expect.get("kind")
    if kind != "temporal_sequence":
        return Result(
            t.id, "failed", f"unknown temporal expect.kind `{kind}`",
        )
    why = _fact_count_refusal(expect)
    if why is not None:
        return Result(t.id, "failed", f"malformed fixture: {why}")

    dsc_bytes = _compile_fixture(t.path.name, t.rules_ds,
                                 test_id=t.id, rules_ds=t.rules_ds,
                                 libraries=t.libraries)

    eng = pyds.Engine()
    eng.load_dsc(dsc_bytes)
    _mock_clocks(eng)
    eng.set_call_callback(lambda req: None)
    eng.on_cache_set = lambda key, value_json, ttl_ns: None
    eng.on_cache_delete = lambda key, reason: None
    fire_events: list = []
    session = _Session(eng)
    eng.on_event = session.tap(fire_events.append)

    for step in expect.get("steps", []):
        why = session.run(step)
        if why is not None:
            return Result(t.id, "failed", why)

    coverage = _coverage_artefact(t.rules_ds, fire_events)
    artefacts = {"coverage": coverage} if coverage else None

    want = expect["fact_count_after"]
    got = len(eng.facts)
    if got != want:
        return Result(
            t.id, "failed",
            f"fact_count_after: want {want}, got {got}",
            artefacts=artefacts,
        )
    return Result(t.id, "passed", artefacts=artefacts)

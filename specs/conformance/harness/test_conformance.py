# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""pytest integration for the conformance suite.

Each conformance test surfaces as its own pytest id so failures
in the test report cite the conformance test ID directly. Skipped
categories show as pytest skips with the blocker reason.

The runner reports pass or fail per test ([RTIM.7.1.1]), and produces:
- Failure artefacts (event stream, captured cb data) printed
  alongside the pytest assertion text.
- A per-category summary (pass / fail / skip) at session finish,
  reconciled against pytest's own item count. No fixture is marked to fail
  as expected: a failure is fixed or filed.
- An optional structured JSON report when DS_CONFORMANCE_REPORT
  env var points at a writable path.

Per LTES.9.7 a coverage tracker counts which conformance tests
each rule (by ds-source location) participated in.
"""

import json
from dataclasses import replace
from pathlib import Path

import pytest

from runner import (
    _CATEGORIES,
    ConformanceTest,
    Result,
    _dead_rules_refusal,
    _event_sequence_projection,
    _extract_rule_names,
    _event_list_refusal,
    _fact_count_refusal,
    _logical_fields_refusal,
    _wall_clock_refusal,
    _add_compiled_code_misplaced,
    _add_schema_ref_misplaced,
    _format_refusal,
    _introspection_refusal,
    _pump_statuses_refusal,
    _published_asserted_at_mismatch,
    _published_asserted_at_refusal,
    _recording_fields_misplaced,
    _recording_fields_refusal,
    _refused_step_refusal,
    _runtime_error_fields_misplaced,
    _steps_refusal,
    _runtime_error_refusal,
    _tamper_misplaced,
    discover_tests,
    load_fixture,
    load_fixture_json,
    run_test,
)


_ALL_TESTS = list(discover_tests())
_RESULTS: list[tuple[ConformanceTest, Result]] = []


def _id_for(t: ConformanceTest) -> str:
    return f"{t.category}/{t.id}"


def _params() -> list:
    """One pytest param per executing fixture.

    The `compiler` category is not a param at all. Its fixtures pin what the
    compiler accepts, refuses and emits, and the compiler's own suite judges
    them (the `compiler` lane, `compiler/mercury/test/test_conformance.m`). Left out
    rather than skipped, so the summary does not count them as anything.

    Except a `malformed_fixture` ([RCTS.1.2.15]): its subject is the harness,
    not the compiler, so this harness judges it too. And except a file this
    harness could not read as a fixture ([RCTS.1.2.1]): with no `expect` to
    read a kind from, leaving it out would drop it without a word.
    """
    return [pytest.param(t, id=_id_for(t)) for t in _ALL_TESTS
            if not (t.category == "compiler"
                    and t.expect.get("kind") != "malformed_fixture"
                    and t.malformed is None)]


@pytest.mark.parametrize("test", _params())
def test_conformance(test: ConformanceTest) -> None:
    result = run_test(test)
    _RESULTS.append((test, result))
    if result.status == "skipped":
        pytest.skip(result.detail)
    if result.status != "passed":
        # Format failure artefacts compactly — one block per
        # populated artefact key, truncated to keep the diff
        # readable in the pytest output, so that each failure is
        # enough for a bug report.
        msg = result.detail
        if result.artefacts:
            for k, v in result.artefacts.items():
                rendered = repr(v)
                if len(rendered) > 400:
                    rendered = rendered[:400] + "...(truncated)"
                msg += f"\n  artefact[{k}]: {rendered}"
        raise AssertionError(msg)


def test_conformance_suite_non_empty() -> None:
    """Sanity guard against an empty conformance discovery —
    catches a regression where the suite directory disappears
    or the discovery glob breaks."""
    tests = list(discover_tests())
    assert len(tests) > 0, "no conformance tests discovered"


def _where(t: ConformanceTest) -> str:
    return f"{t.path.parent.name}/{t.path.stem}"


def test_every_fixture_id_is_its_file_name() -> None:
    """[RCTS.1.2.2]: a fixture's `id` is its file name without `.json`. Over
    every category, `compiler` and retired fixtures included, since the rule
    is about the file and not about whether this harness runs it."""
    bad = sorted(f"{_where(t)}: id {t.id!r}" for t in _ALL_TESTS
                 if t.id != t.path.stem)
    assert not bad, f"{len(bad)} fixture(s) whose id is not the file name: {bad}"


def test_every_fixture_category_is_its_directory() -> None:
    """[RCTS.1.2.3]: `category` is the name of the fixture's directory, and
    that directory is a category of [RCTS.1.1.4]. The harness refuses a
    fixture it runs that breaks either (`_format_refusal`); this holds the
    whole committed corpus, `compiler` and retired fixtures included."""
    bad = sorted(f"{_where(t)}: category {t.category!r}" for t in _ALL_TESTS
                 if t.category != t.path.parent.name
                 or t.path.parent.name not in _CATEGORIES)
    assert not bad, f"{len(bad)} fixture(s) filed under another category: {bad}"


def _pins_an_rcts_1_2_1_refusal(t: ConformanceTest) -> bool:
    """A `malformed_fixture` whose subject is an [RCTS.1.2.1] refusal: it
    repeats a name, or leaves out a required field, on purpose, and the
    harness must refuse it for that."""
    return (t.expect.get("kind") == "malformed_fixture"
            and t.expect.get("reason") == "RCTS.1.2.1")


def test_every_fixture_names_each_member_once() -> None:
    """A fixture is one JSON object ([RCTS.1.2.1]), and one that repeats a
    member name means whatever its reader makes of it. Python's `json` keeps
    the last value and drops the others without a word; another harness's
    parser may keep the first or refuse the file, so two harnesses can read one
    fixture two ways.

    The harness refuses such a fixture too (`_format_refusal`), but only one it
    runs: a retired fixture is skipped before its format is checked. This
    holds the whole committed corpus, `compiler` and retired fixtures
    included, like the two tests above. A `malformed_fixture` pinning the
    refusal itself is the one exception."""
    bad = sorted(f"{_where(t)}: {', '.join(sorted(set(t.repeated_members)))}"
                 for t in _ALL_TESTS
                 if t.repeated_members and not _pins_an_rcts_1_2_1_refusal(t))
    assert not bad, f"{len(bad)} fixture(s) repeating a member name: {bad}"


def test_every_fixture_is_one_object_with_the_fields_it_must_carry() -> None:
    """[RCTS.1.2.1]: a fixture is one JSON object carrying `id`, `category`,
    `scenario`, `rules_ds` (a string) and `expect` (an object). The harness
    refuses one that is not (`load_fixture`, `_format_refusal`), but only one
    it runs, so this holds the whole committed corpus, `compiler` and retired
    fixtures included, as the repeat test above does. A `malformed_fixture`
    pinning the refusal is the one exception."""
    bad = sorted(f"{_where(t)}: {t.malformed[1]}" for t in _ALL_TESTS
                 if t.malformed is not None
                 and not _pins_an_rcts_1_2_1_refusal(t))
    assert not bad, f"{len(bad)} file(s) that are not a fixture as written: {bad}"


_WELL_FORMED = {"id": "X", "category": "logical", "scenario": "s",
                "rules_ds": "", "expect": {"kind": "rule_fire_order"}}


def _loaded(text: str) -> ConformanceTest:
    return load_fixture(Path("logical/X.json"), text)


def _without(field: str) -> str:
    return json.dumps({k: v for k, v in _WELL_FORMED.items() if k != field})


def test_rcts_1_2_1__a_well_formed_fixture_loads_unrefused() -> None:
    t = _loaded(json.dumps(_WELL_FORMED))
    assert t.malformed is None
    assert _format_refusal(t) is None


@pytest.mark.parametrize("field", ["id", "category", "scenario", "rules_ds",
                                   "expect"])
def test_rcts_1_2_1__a_missing_required_field_is_refused(field) -> None:
    """The fixture alone fails, under [RCTS.1.2.1], with the field named as
    `test_conformance.m`'s `rcts_fixture_format` names it."""
    t = _loaded(_without(field))
    assert _format_refusal(t) == ("RCTS.1.2.1", f"no `{field}`")
    result = run_test(t)
    assert result.status == "failed"
    assert f"[RCTS.1.2.1] no `{field}`" in result.detail


@pytest.mark.parametrize("text, says", [
    ("[1, 2]", "not one JSON object"),
    ('"fixture"', "not one JSON object"),
    ('{"id": "X"', "not one JSON object: "),
    ('{"id": "X", "category": "logical", "scenario": "s", "rules_ds": 3, '
     '"expect": {"kind": "rule_fire_order"}}', "`rules_ds` is not a string"),
    ('{"id": "X", "category": "logical", "scenario": "s", "rules_ds": "", '
     '"expect": ["rule_fire_order"]}', "`expect` is not an object"),
])
def test_rcts_1_2_1__a_file_of_another_shape_is_refused(text, says) -> None:
    t = _loaded(text)
    clause, why = _format_refusal(t)
    assert clause == "RCTS.1.2.1"
    assert why.startswith(says)
    assert run_test(t).status == "failed"


def test_rcts_1_2_1__an_unread_file_keeps_its_path_as_its_name() -> None:
    """The stand-ins are the path's, so the refusal is reported against the
    file, and the id and category checks above do not report it a second
    time."""
    t = load_fixture(Path("adapter/LECC.9.json"), "{")
    assert (t.id, t.category) == ("LECC.9", "adapter")


@pytest.mark.parametrize("where", sorted(_CATEGORIES))
def test_rcts_1_2_3__a_fixture_whose_category_is_its_directory_is_admitted(
        where) -> None:
    t = load_fixture(Path(f"{where}/X.json"),
                     json.dumps({**_WELL_FORMED, "category": where}))
    assert _format_refusal(t) is None


def test_rcts_1_2_3__the_categories_are_rcts_1_1_4s_six() -> None:
    assert _CATEGORIES == {"adapter", "compiler", "cross-tier", "logical",
                           "runtime", "temporal"}


def test_rcts_1_2_3__a_category_that_is_not_its_directory_is_refused() -> None:
    t = load_fixture(Path("runtime/X.json"), json.dumps(_WELL_FORMED))
    assert _format_refusal(t) == (
        "RCTS.1.2.3", "`category` is `logical`, and the fixture is in `runtime/`")
    assert run_test(t).status == "failed"


def test_rcts_1_2_3__a_directory_that_is_no_category_fails_not_skips() -> None:
    # `category` agrees with the directory, so only the directory is wrong.
    t = load_fixture(Path("logicl/X.json"),
                     json.dumps({**_WELL_FORMED, "category": "logicl"}))
    assert _format_refusal(t) == (
        "RCTS.1.2.3", "the fixture is in `logicl/`, which is no category of "
        "[RCTS.1.1.4]")
    result = run_test(t)
    assert result.status == "failed"
    assert "[RCTS.1.2.3]" in result.detail


def test_rcts_1_2_3__a_category_that_is_not_a_string_is_refused() -> None:
    t = _loaded(json.dumps({**_WELL_FORMED, "category": 7}))
    assert _format_refusal(t) == ("RCTS.1.2.3", "`category` is not a string")
    assert run_test(t).status == "failed"


def test_rcts_1_2_15__a_malformed_fixture_naming_a_missing_field_passes() -> None:
    fixture = {k: v for k, v in _WELL_FORMED.items() if k != "rules_ds"}
    fixture["expect"] = {"kind": "malformed_fixture", "reason": "RCTS.1.2.1"}
    assert run_test(_loaded(json.dumps(fixture))).status == "passed"
    fixture["expect"]["reason"] = "RCTS.1.2.14"
    assert run_test(_loaded(json.dumps(fixture))).status == "failed"


def test_the_reader_keeps_every_repeat_at_any_depth() -> None:
    """[RCTS.1.2.1] binds every object, not only the top one."""
    text = ('{"id": "X", "id": "X", "expect": {"kind": "k", '
            '"inner": {"a": 1, "b": 2, "a": 3}}, "list": [{"c": 1, "c": 1}]}')
    data, repeated = load_fixture_json(text)
    assert sorted(repeated) == ["a", "c", "id"]
    assert data["expect"]["inner"]["a"] == 3   # the values are Python's reading
    assert load_fixture_json('{"a": {"a": 1}, "b": [{"a": 2}]}')[1] == ()


def _repeat_case(repeated: tuple[str, ...]) -> ConformanceTest:
    return ConformanceTest(id="X", category="logical", scenario="", rules_ds="",
                           expect={"kind": "rule_fire_order"},
                           path=Path("logical/X.json"),
                           repeated_members=repeated)


def test_a_repeated_member_is_refused_under_rcts_1_2_1() -> None:
    """[RCTS.1.2.15]: the refusal names the clause the fixture breaks, and it
    comes before any other check, which would read one of two values."""
    clause, why = _format_refusal(_repeat_case(("expect", "expect")))
    assert clause == "RCTS.1.2.1"
    assert "`expect`" in why
    assert _format_refusal(_repeat_case(())) is None


_TWO_RULES = ("schema T scope logical:\n    v: Int key\n\n"
              "rule fires:\n    T\n->\n    log info \"a\"\n\n"
              "rule quiet:\n    T t where t.v > 9\n->\n    log info \"b\"\n")


def _dead_rules_case(dead, fired, kind="rule_fire_order"):
    """A fixture declaring `dead`, and a passed run whose coverage record
    says `fired` fired (None: the driver kept no record)."""
    t = ConformanceTest(id="X", category="logical", scenario="", rules_ds=_TWO_RULES,
                        expect={"kind": kind}, path=Path("logical/X.json"),
                        dead_rules_expected=tuple(dead) or None)
    artefacts = None if fired is None else {"coverage": {
        "defined": ["fires", "quiet"], "fired": sorted(fired),
        "dead": [n for n in ("fires", "quiet") if n not in fired],
        "firings_total": len(fired)}}
    return t, Result("X", "passed", artefacts=artefacts)


def test_rcts_1_2_17__a_listed_rule_that_stays_dead_passes() -> None:
    assert _dead_rules_refusal(*_dead_rules_case(["quiet"], {"fires"})) is None


def test_rcts_1_2_17__a_listed_rule_that_fires_fails() -> None:
    why = _dead_rules_refusal(*_dead_rules_case(["quiet"], {"fires", "quiet"}))
    assert why is not None and "quiet fired" in why


def test_rcts_1_2_17__a_listed_name_that_is_no_rule_fails() -> None:
    why = _dead_rules_refusal(*_dead_rules_case(["quiett"], {"fires"}))
    assert why is not None and "names no rule" in why and "quiett" in why


def test_rcts_1_2_17__a_list_on_a_kind_that_observes_no_firings_fails() -> None:
    why = _dead_rules_refusal(*_dead_rules_case(["quiet"], None, kind="pbf_framing"))
    assert why is not None and "records no rule firings" in why


def test_rcts_1_2_17__an_unlisted_rule_that_never_fires_fails() -> None:
    why = _dead_rules_refusal(*_dead_rules_case([], {"fires"}))
    assert why is not None
    assert "never fired and not in dead_rules_expected: quiet." in why


def test_rcts_1_2_17__every_rule_firing_needs_no_list() -> None:
    assert _dead_rules_refusal(*_dead_rules_case([], {"fires", "quiet"})) is None


def test_rcts_1_2_17__no_list_on_a_kind_that_observes_no_firings_is_not_judged() -> None:
    assert _dead_rules_refusal(*_dead_rules_case([], None, kind="pbf_framing")) is None


def test_rcts_1_2_17__a_judged_kind_whose_driver_kept_no_record_fails() -> None:
    """Whether a kind is judged is the clause's list, not whether its driver
    happened to keep a coverage record: one that stops keeping it would
    otherwise leave every fixture of its kind unjudged, and green."""
    why = _dead_rules_refusal(*_dead_rules_case([], None))
    assert why is not None and "kept no record of rule firings" in why
    why = _dead_rules_refusal(*_dead_rules_case(["quiet"], None))
    assert why is not None and "kept no record of rule firings" in why


def test_rcts_1_2_17__a_judged_kind_with_no_rule_needs_no_record() -> None:
    t, result = _dead_rules_case([], None)
    t = replace(t, rules_ds="schema T scope logical:\n    v: Int key\n")
    assert _dead_rules_refusal(t, result) is None


def test_rcts_1_2_17__a_list_on_another_kind_fails_even_with_a_record() -> None:
    """[RCTS.1.2.17]: "A harness must fail a fixture of any other kind whose
    array is not empty". A record some driver keeps for its own reasons does
    not make the kind one the clause judges."""
    why = _dead_rules_refusal(*_dead_rules_case(["quiet"], {"fires"},
                                                kind="rfcs_roundtrip"))
    assert why is not None and "records no rule firings" in why
    assert _dead_rules_refusal(*_dead_rules_case([], {"fires"},
                                                 kind="rfcs_roundtrip")) is None


_REPO = Path(__file__).resolve().parents[3]


def _clause(clause_id: str) -> dict:
    return json.loads((_REPO / "specs/runtime/CONFORMANCE_TESTS"
                       / f"{clause_id}.json").read_text(encoding="utf-8"))


def test_rcts_1_2_17__records_firings_is_the_clause_s_list() -> None:
    """`RECORDS_FIRINGS` is [RCTS.1.2.17]'s list: the kinds it names, and every
    kind [RCTS.1.2.10] files under `logical`. `test_behave.m`'s
    `records_firings` is the same set, so the two runtimes' harnesses judge
    the same fixtures' firings."""
    import re

    from runner import RECORDS_FIRINGS
    rows = _clause("RCTS.1.2.10")["data"]["rows"]
    kinds = {row[0].strip("`"): row[1] for row in rows}
    named = set(re.findall(r"`([a-z_]+)`", _clause("RCTS.1.2.17")["text"]))
    want = ({k for k in named if k in kinds}
            | {k for k, category in kinds.items() if category == "logical"})
    assert len(want) > len({k for k, c in kinds.items() if c == "logical"}), (
        "found none of the kinds RCTS.1.2.17 names; the scan reads nothing")
    assert RECORDS_FIRINGS == want
    behave = (_REPO / "compiler/mercury/test/test_behave.m").read_text(
        encoding="utf-8")
    mercury = set(re.findall(r'^records_firings\("([a-z_]+)"\)\.$', behave,
                             re.MULTILINE))
    assert mercury == want


def test_rcts_1_2_21__the_tamper_on_another_kind_fails() -> None:
    t = ConformanceTest(id="X", category="runtime", scenario="", rules_ds=_TWO_RULES,
                        expect={"kind": "temporal_sequence", "steps": [],
                                "fact_count_after": 0,
                                "tamper": {"truncate_tail": 1}},
                        path=Path("runtime/X.json"))
    why = _tamper_misplaced(t)
    assert why is not None and "temporal_sequence" in why
    assert run_test(t).status == "failed"
    t.expect["kind"] = "runtime_error"
    assert _tamper_misplaced(t) is None


def test_rcts_1_2_21__runtime_fact_count_takes_the_structural_edits() -> None:
    """An object other than `drop_call_operand`, or a list, stands on
    `runtime_fact_count`. A string's artefact is refused for its hash, and
    `drop_call_operand`'s fault is a step's, which the kind does not observe:
    each is refused before the run."""
    t = _kind_case("runtime_fact_count", fact_count_after=0)
    for ok in ({"truncate_tail": 1}, {"set_field": {"node": 1, "path": [3],
                                                     "value": None}},
               [{"drop_atom": 1}, {"truncate_tail": 1}]):
        t.expect["tamper"] = ok
        assert _tamper_misplaced(t) is None, ok
    for bad in ("last_byte", "dsc_sha256", {"drop_call_operand": "fires"}):
        t.expect["tamper"] = bad
        why = _tamper_misplaced(t)
        assert why is not None and "runtime_fact_count" in why, bad
        assert run_test(t).status == "failed", bad


# One rule, whose `where` puts one test on `T`'s alpha node, node 1, as the
# RDSC.4a.9.1 vectors' `on_t` does. `_UNTESTED` removes that node's tests
# (field 3), so `quiet` sees every `T`: the edit decides whether it fires.
_ONE_TEST = ("schema T scope logical:\n    v: Int key\n\n"
             "rule quiet:\n    T t where t.v > 9\n->\n    log info \"b\"\n")
_UNTESTED = {"set_field": {"node": 1, "path": [3], "value": None}}


def _fact_count_case(**expect) -> ConformanceTest:
    """`_ONE_TEST` with one `T`, `v` 1, and a pump, `quiet` listed dead.
    Unedited, `quiet` does not fire."""
    return ConformanceTest(id="X", category="runtime", scenario="",
                           rules_ds=_ONE_TEST,
                           expect={"kind": "runtime_fact_count",
                                   "asserts": [{"schema": "T", "slots": {"v": 1}}],
                                   "pump": True, "fact_count_after": 1, **expect},
                           path=Path("runtime/X.json"),
                           dead_rules_expected=("quiet",))


def test_rcts_1_2_21__runtime_fact_count_runs_the_edited_artefact() -> None:
    """Through libds: the edit reaches the run. Without it `quiet`
    never fires and the fixture passes; with it `quiet` fires, which
    `dead_rules_expected` refuses. A harness that dropped the edit would pass
    both."""
    assert run_test(_fact_count_case()).status == "passed"
    result = run_test(_fact_count_case(tamper=_UNTESTED))
    assert result.status == "failed" and "quiet" in result.detail, result.detail


def test_rcts_1_2_21__runtime_fact_count_fails_without_a_site_or_a_load() -> None:
    """An edit with no site fails the fixture, and so does an edited
    artefact the runtime refuses at load: removing the header (atom 0) is
    -501 ([RDSC.11.1])."""
    no_site = run_test(_fact_count_case(tamper={"drop_atom": 99}))
    assert no_site.status == "failed" and "tamper site" in no_site.detail, \
        no_site.detail
    refused = run_test(_fact_count_case(tamper={"drop_atom": 0}))
    assert refused.status == "failed" and "load was refused" in refused.detail, \
        refused.detail


def test_rcts_1_2_21__replay_determinism_takes_drop_call_operand_alone() -> None:
    """On `replay_determinism` the field is `drop_call_operand`, the
    one edit whose artefact loads; any other member is refused before the run,
    since an artefact refused at load has no run to replay."""
    t = ConformanceTest(id="X", category="runtime", scenario="", rules_ds=_TWO_RULES,
                        expect={"kind": "replay_determinism",
                                "tamper": {"drop_call_operand": "a"}},
                        path=Path("runtime/X.json"))
    assert _tamper_misplaced(t) is None
    for other in ("last_byte", {"truncate_tail": 1},
                  [{"drop_call_operand": "a"}, {"truncate_tail": 1}],
                  {"drop_call_operand": "a", "truncate_tail": 1}):
        t.expect["tamper"] = other
        why = _tamper_misplaced(t)
        assert why is not None and "drop_call_operand" in why, other
        assert run_test(t).status == "failed", other


# One rule whose `log` loses an operand to `drop_call_operand`, so its firing
# raises an EngineError and halts the engine (LERR.1.4.7's program, cut down).
_HALTS = ("schema Trig scope logical:\n    k: Int key\n\n"
          "rule bad:\n    Trig\n->\n    log info \"fired\"\n")


def _halted_replay_case(steps: list) -> ConformanceTest:
    return ConformanceTest(id="X", category="runtime", scenario="", rules_ds=_HALTS,
                           expect={"kind": "replay_determinism",
                                   "tamper": {"drop_call_operand": "bad"},
                                   "steps": steps},
                           path=Path("runtime/X.json"))


_HALTING_STEPS = [{"op": "set", "now_ns": 0},
                  {"op": "assert", "schema": "Trig", "slots": {"k": 1}},
                  {"op": "pump"}]


def test_rcts_1_2_21__a_halted_run_replays_to_its_end() -> None:
    """[RFCS.6.7]: the pump that halts is the run's outcome, and the
    replay goes past it, leaving the reader halted by the same fault. Run
    through libds, so the path the vector names is seen to pass."""
    result = run_test(_halted_replay_case(_HALTING_STEPS))
    assert result.status == "passed", result.detail


def test_rcts_1_2_21__a_tampered_run_that_does_not_halt_fails() -> None:
    """No pump, so nothing fires and nothing halts: the tamper tested
    nothing, and the fixture fails for that and not for another reason."""
    result = run_test(_halted_replay_case(_HALTING_STEPS[:2]))
    assert result.status == "failed" and "did not halt" in result.detail, \
        result.detail


def test_rcts_1_2_21__a_step_after_the_halt_fails() -> None:
    """[RCTS.1.2.28]: the halting step must be the last; a halted engine
    refuses whatever follows it."""
    result = run_test(_halted_replay_case([*_HALTING_STEPS, {"op": "pump"}]))
    assert result.status == "failed" and "follow it" in result.detail, \
        result.detail


@pytest.mark.parametrize("field, value", [
    ("fault_at", 0), ("no_fault_events", True), ("fault_events", []),
    ("cache_cap", {"keys": 1}), ("halted_fault", "ARTEFACT_LIED"),
    ("last_event", "engine_error"),
])
def test_rcts_1_2_25__a_runtime_error_field_on_another_kind_fails(field, value) -> None:
    t = _kind_case("runtime_fact_count", **{field: value})
    why = _runtime_error_fields_misplaced(t)
    assert why is not None and field in why and "RCTS.1.2.25" in why
    assert run_test(t).status == "failed"
    assert _runtime_error_fields_misplaced(_kind_case("runtime_error", **{field: value})) is None


def test_rcts_1_2_25__a_shared_field_on_another_kind_is_not_judged() -> None:
    """`code`, `message_contains` and `cache_seeds` are other kinds' too."""
    t = _kind_case("runtime_fact_count", code="-1", message_contains="x",
                   cache_seeds=[])
    assert _runtime_error_fields_misplaced(t) is None


_GOOD_ERROR = {"kind": "runtime_error", "code": "-710"}


@pytest.mark.parametrize("fields", [
    {"code": None}, {"code": -710}, {"code": "710"}, {"code": "-0"},
    {"code": "-7a"}, {"message_contains": 1},
    # An array holds strings, at least one.
    {"message_contains": []}, {"message_contains": ["a", 1]},
    {"steps": [], "asserts": []}, {"steps": [], "pump": True},
    {"steps": "pump"}, {"asserts": [1]}, {"pump": "yes"},
    {"cache_seeds": [{"key": "k"}]}, {"cache_seeds": [{"key": 1, "value": 1}]},
    {"cache_seeds": [{"key": "k", "value": 1, "ttl": 1}]},
    # `text` is a string, and it is that or `value`, never both.
    {"cache_seeds": [{"key": "k", "text": 1}]},
    {"cache_seeds": [{"key": "k", "text": "1", "value": 1}]},
    # `text_bytes` is two hex digits per octet, and never beside `text`
    # ([LSTR.8.5]).
    {"cache_seeds": [{"key": "k", "text_bytes": "c0 af"}]},
    {"cache_seeds": [{"key": "k", "text_bytes": "c"}]},
    {"cache_seeds": [{"key": "k", "text_bytes": "zz"}]},
    {"cache_seeds": [{"key": "k", "text_bytes": 5}]},
    {"cache_seeds": [{"key": "k", "text_bytes": "22", "text": "1"}]},
    # ... and holds no `00` octet, [LSTR.1.5]'s refusal, which no harness
    # can hand over unchanged.
    {"cache_seeds": [{"key": "k", "text_bytes": "00"}]},
    {"cache_seeds": [{"key": "k", "text_bytes": "c000"}]},
    {"cache_cap": {"keys": -1}}, {"cache_cap": {"rows": 1}}, {"cache_cap": 1},
    {"fault_at": -1}, {"fault_at": True}, {"fault_at": "0"},
    {"fact_count_after": 1.0}, {"no_fault_events": 1},
    {"fault_events": "bounds_error"}, {"fault_events": ["bounds"]},
    {"halted_fault": 1},
    {"last_event": "rule_fire_begin"}, {"last_event": 1}, {"last_event": []},
    {"halted_fault": "ARTEFACT_LIED", "fact_count_after": 0},
])
def test_rcts_1_2_25__a_value_of_another_type_is_refused(fields) -> None:
    expect = {**_GOOD_ERROR, **fields}
    if fields.get("code", "-710") is None:
        del expect["code"]
    why = _runtime_error_refusal(expect)
    assert why is not None and "RCTS.1.2.25" in why, fields


def test_rcts_1_2_25__a_seed_text_is_handed_over_exactly_as_written() -> None:
    """`text` reaches the runtime byte for byte, which is what lets a fixture
    state an integer literal outside int64 ([LGRA.5.8.9]): a `value`
    holding the same digits is re-written by `json.dumps`, and in
    `test_behave.m` read as a Float."""
    from runner import _seed_text
    assert _seed_text({"key": "k", "text": "9223372036854775808"}) \
        == "9223372036854775808"
    assert _seed_text({"key": "k", "text": "{ \"a\" :1}"}) == "{ \"a\" :1}"
    assert _seed_text({"key": "k", "value": {"a": 1}}) == "{\"a\": 1}"


def test_rcts_1_2_25__a_seed_text_bytes_is_handed_over_as_its_octets() -> None:
    """`text_bytes` reaches the runtime as those octets, which no JSON string
    can hold when they are not well-formed UTF-8 ([LSTR.8.5]): a JSON escape
    of a lone surrogate is a Python `str` pyds refuses before libds sees it,
    so the vector would test pyds."""
    from runner import _seed_text
    assert _seed_text({"key": "k", "text_bytes": "22c0af22"}) == b'"\xc0\xaf"'
    assert _seed_text({"key": "k", "text_bytes": ""}) == b""


def test_rcts_1_2_25__a_fixture_with_no_code_fails_rather_than_passing_any_fault() -> None:
    t = _kind_case("runtime_error", asserts=[], pump=True)
    result = run_test(t)
    assert result.status == "failed" and "expect.code" in result.detail


def test_rcts_1_2_25__well_typed_values_are_admitted() -> None:
    assert _runtime_error_refusal({
        **_GOOD_ERROR, "message_contains": "capacity", "steps": [{"op": "pump"}],
        "cache_seeds": [{"key": "k", "value": [1, "a"]},
                        {"key": "j", "text": "9223372036854775808"},
                        {"key": "b", "text_bytes": "22EDa08022"},
                        {"key": "c", "text_bytes": "c0af"},
                        {"key": "d", "text_bytes": "a00b"}],
        "cache_cap": {"keys": 1, "bytes": 0}, "fault_at": 0,
        "no_fault_events": False, "fault_events": ["bounds_error", "engine_error"],
        "fact_count_after": 0, "last_event": "bounds_error",
    }) is None
    assert _runtime_error_refusal({
        **_GOOD_ERROR, "halted_fault": "ARTEFACT_LIED",
        "last_event": "engine_error",
    }) is None
    assert _runtime_error_refusal({**_GOOD_ERROR, "asserts": [{}], "pump": False}) is None
    assert _runtime_error_refusal({
        **_GOOD_ERROR, "message_contains": ["Slot", " at offset "]}) is None


def test_rcts_1_2_25__message_contains_asks_for_every_string_it_holds() -> None:
    """The array form: the refusal's text contains each string, and the first
    it lacks is named. `test_behave.m`'s `contains_all` holds the same."""
    from runner import _message_lacks
    want = ["Slot", " at offset "]
    assert _message_lacks(want, "dsc: Slot body failed at offset 7") is None
    assert _message_lacks(want, "dsc: Slot body failed") == " at offset "
    assert _message_lacks(want, "at offset 7") == "Slot"
    assert _message_lacks("x", "axb") is None
    assert _message_lacks("x", "ab") == "x"


def test_rcts_1_2_25__a_call_in_the_steps_is_taken_not_refused() -> None:
    """A `runtime_error` fixture's pump that issues a call passes, as in every
    other driver of [RCTS.1.2.28]'s steps and in `test_behave.m`: the harness
    registers a call callback, so libds does not refuse the pump for want of
    one (-400). The refusal pinned comes after it, at input 2."""
    t = ConformanceTest(
        id="X", category="runtime", scenario="",
        rules_ds=("schema Reply scope ttl 1_h:\n    corr: String\n    text: String\n\n"
                  "service svc.read:\n    kwarg n: Int\n    response Reply\n\n"
                  "schema Job scope explicit:\n    id: Int\n\n"
                  "rule r:\n    Job j\n->\n    call svc.read n: j.id nocooldown\n"),
        expect={"kind": "runtime_error", "code": "-222", "fault_at": 2, "steps": [
            {"op": "assert", "schema": "Job", "slots": {"id": 1}},
            {"op": "pump"},
            {"op": "assert", "schema": "Reply", "corr_from_call": 0,
             "slots": {"text": {"$text_bytes": "80"}}}]},
        path=Path("runtime/X.json"))
    result = run_test(t)
    assert result.status == "passed", result.detail


def test_rcts_1_2_25__every_runtime_error_in_the_corpus_is_well_typed() -> None:
    """Over the whole corpus, deprecated fixtures included."""
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS
           if t.expect.get("kind") == "runtime_error"
           and (why := _runtime_error_refusal(t.expect)) is not None]
    assert not bad, bad


_GOOD_FACT_COUNT = {"kind": "runtime_fact_count", "fact_count_after": 1}


@pytest.mark.parametrize("fields", [
    {"fact_count_after": None}, {"fact_count_after": -1},
    {"fact_count_after": 1.0}, {"fact_count_after": "1"},
    {"fact_count_after": True},
    {"asserts": "T"}, {"asserts": [1]}, {"asserts": [{}]},
    {"asserts": [{"schema": 1}]}, {"asserts": [{"schema": "T", "slots": []}]},
    {"generate_asserts": [{"schema": "T", "slot_name": "v"}]},
    {"generate_asserts": [{"schema": "T", "slot_name": "v", "count": -1}]},
    {"generate_asserts": [{"schema": "T", "slot_name": "v", "count": "3"}]},
    {"generate_asserts": [{"schema": "T", "slot_name": 1, "count": 3}]},
    {"generate_asserts": [{"schema": "T", "slot_name": "v", "count": 3,
                           "start": "1"}]},
    {"generate_asserts": [{"schema": "T", "slot_name": "v", "count": 3,
                           "start": 1.5}]},
    {"pump": "yes"}, {"pump": 1},
    {"cache_seeds": [{"key": "k"}]},
    {"cache_seeds": [{"key": "k", "text": "1", "value": 1}]},
    {"add_compiled_code": 3}, {"add_compiled_code": {}},
    {"add_compiled_code": {"node": 0}}, {"add_compiled_code": {"node": "3"}},
    {"add_compiled_code": {"node": True}},
    {"add_compiled_code": {"node": 3, "arch": "amd64"}},
])
def test_rcts_1_2_31__a_value_of_another_type_is_refused(fields) -> None:
    expect = {**_GOOD_FACT_COUNT, **fields}
    if "fact_count_after" in fields and fields["fact_count_after"] is None:
        del expect["fact_count_after"]
    why = _fact_count_refusal(expect)
    assert why is not None and "RCTS.1.2.31" in why, fields


def test_rcts_1_2_31__well_typed_values_are_admitted() -> None:
    assert _fact_count_refusal({
        **_GOOD_FACT_COUNT, "cache_seeds": [{"key": "k", "value": 1}],
        "asserts": [{"schema": "T"}, {"schema": "T", "slots": {"v": 1}}],
        "generate_asserts": [{"schema": "T", "slot_name": "v", "count": 3},
                             {"schema": "T", "slot_name": "v", "count": 0,
                              "start": -2}],
        "pump": False, "add_compiled_code": {"node": 3}}) is None
    assert _fact_count_refusal(
        {"kind": "temporal_sequence", "fact_count_after": 0,
         "steps": [{"op": "pump"}]}) is None


def test_rcts_1_2_31__add_compiled_code_on_another_kind_fails() -> None:
    """`add_compiled_code` is `runtime_fact_count`'s alone; on another kind
    nothing makes the edit. `test_behave.m`'s `kind_fields_placed` fails it
    alike."""
    t = ConformanceTest(id="X", category="temporal", scenario="",
                        rules_ds=_TWO_RULES,
                        expect={"kind": "temporal_sequence", "fact_count_after": 0,
                                "steps": [], "add_compiled_code": {"node": 3}},
                        path=Path("temporal/X.json"))
    why = _add_compiled_code_misplaced(t)
    assert why is not None and "temporal_sequence" in why and "RCTS.1.2.31" in why
    assert run_test(t).status == "failed"
    t.expect["kind"] = "runtime_fact_count"
    assert _add_compiled_code_misplaced(t) is None


def test_rcts_1_2_31__temporal_sequence_needs_its_count_and_no_more() -> None:
    """`fact_count_after` is both kinds'; the four input fields are
    `runtime_fact_count`'s, and on `temporal_sequence` nothing reads them."""
    why = _fact_count_refusal({"kind": "temporal_sequence", "steps": []})
    assert why is not None and "fact_count_after" in why
    assert _fact_count_refusal({"kind": "temporal_sequence",
                                "fact_count_after": 0, "pump": "yes"}) is None


@pytest.mark.parametrize("kind", ["runtime_fact_count", "temporal_sequence"])
def test_rcts_1_2_31__a_fixture_with_no_count_fails_before_it_runs(kind) -> None:
    category = "runtime" if kind == "runtime_fact_count" else "temporal"
    t = ConformanceTest(id="X", category=category, scenario="",
                        rules_ds=_TWO_RULES, expect={"kind": kind},
                        path=Path(f"{category}/X.json"))
    result = run_test(t)
    assert result.status == "failed"
    assert "malformed fixture" in result.detail
    assert "RCTS.1.2.31" in result.detail


def test_rcts_1_2_31__every_live_fact_count_fixture_is_well_typed() -> None:
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS
           if t.deprecated is None
           and t.expect.get("kind") in ("runtime_fact_count", "temporal_sequence")
           and (why := _fact_count_refusal(t.expect)) is not None]
    assert not bad, bad


def test_rcts_1_2_32__the_tables_are_the_clause_s() -> None:
    """`LOGICAL_KINDS` is [RCTS.1.2.10]'s `logical` rows; `EVENT_LIST_FIELDS`
    names the kinds and arrays [RCTS.1.2.32] names; `test_behave.m`'s
    `logical_kind` and `event_list_field` hold the same."""
    import re

    from runner import EVENT_LIST_FIELDS, LOGICAL_KINDS
    rows = _clause("RCTS.1.2.10")["data"]["rows"]
    assert LOGICAL_KINDS == {r[0].strip("`") for r in rows if r[1] == "logical"}
    text = _clause("RCTS.1.2.32")["text"]
    for kind, field in EVENT_LIST_FIELDS.items():
        assert f"`{kind}`" in text and f"`{field}`" in text, (kind, field)
    behave = (_REPO / "compiler/mercury/test/test_behave.m").read_text(
        encoding="utf-8")
    assert set(re.findall(r'^logical_kind\("([a-z_]+)"\)\.$', behave,
                          re.MULTILINE)) == LOGICAL_KINDS
    assert dict(re.findall(r'^event_list_field\("([a-z_]+)", "([a-z_]+)"\)\.$',
                           behave, re.MULTILINE)) == EVENT_LIST_FIELDS


@pytest.mark.parametrize("kind, field", [
    ("rule_fire_order", "expected_rule_names"),
    ("log_message_sequence", "expected_messages"),
    ("event_sequence", "expected_kinds"),
    ("event_sequence_strict", "expected_kinds"),
    ("event_kinds_forbidden", "forbidden_kinds"),
])
def test_rcts_1_2_32__the_array_is_required_and_strings(kind, field) -> None:
    for bad in ({}, {field: None}, {field: "a"}, {field: ["a", 1]},
                {field: [["a"]]}):
        why = _event_list_refusal({"kind": kind, **bad})
        assert why is not None and field in why and "RCTS.1.2.32" in why, bad
    assert _event_list_refusal({"kind": kind, field: []}) is None
    assert _event_list_refusal({"kind": kind, field: ["a", "b"]}) is None


def test_rcts_1_2_32__a_missing_array_fails_before_it_runs() -> None:
    t = ConformanceTest(id="X", category="logical", scenario="",
                        rules_ds=_TWO_RULES, expect={"kind": "rule_fire_order"},
                        path=Path("logical/X.json"))
    result = run_test(t)
    assert result.status == "failed"
    assert "expected_rule_names" in result.detail and "RCTS.1.2.32" in result.detail


def test_rcts_1_2_32__wall_clock_is_unset_on_a_logical_kind_alone() -> None:
    def case(kind, value):
        return replace(_kind_case(kind), expect={"kind": kind, "wall_clock": value})
    assert _wall_clock_refusal(case("log_message_sequence", "unset")) is None
    assert _wall_clock_refusal(case("introspection_assert", "unset")) is None
    for kind in ("temporal_sequence", "runtime_fact_count", "adapter_calls"):
        why = _wall_clock_refusal(case(kind, "unset"))
        assert why is not None and "logical" in why, kind
        assert run_test(case(kind, "unset")).status == "failed"
    for value in ("set", "", None, False, 0):
        why = _wall_clock_refusal(case("rule_fire_order", value))
        assert why is not None and "RCTS.1.2.32" in why, value
    assert _wall_clock_refusal(_kind_case("temporal_sequence")) is None


def test_rcts_1_2_32__every_live_fixture_keeps_the_clause() -> None:
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS if t.deprecated is None
           and (why := (_event_list_refusal(t.expect)
                        or _wall_clock_refusal(t))) is not None]
    assert not bad, bad


_MONOTONIC = {"kind": "event_seq_monotonic"}


@pytest.mark.parametrize("fields", [
    {"filter_kind": 1}, {"min_events": -1}, {"min_events": "3"},
    {"min_events": True}, {"expected_seq_step": 0},
    {"expected_seq_step": 1.0}, {"expected_clocks": 5},
    {"expected_clocks": [5, "6"]}, {"expected_clocks": [-1]},
])
def test_rcts_1_2_33__an_event_seq_monotonic_value_of_another_type_is_refused(
        fields) -> None:
    why = _logical_fields_refusal({**_MONOTONIC, **fields})
    assert why is not None and "RCTS.1.2.33" in why, fields


def test_rcts_1_2_33__event_seq_monotonic_well_typed_is_admitted() -> None:
    assert _logical_fields_refusal(_MONOTONIC) is None
    assert _logical_fields_refusal({
        **_MONOTONIC, "filter_kind": "fact_assert", "min_events": 0,
        "expected_seq_step": 1, "expected_clocks": [0, 5000000000]}) is None


@pytest.mark.parametrize("checks", [
    None, [], [1], [{"field": "session_id"}],
    [{"field": "capabilities", "present": True}],
    [{"field": "dialect_def_sha256", "present": True}],
    [{"field": "session_id", "equals": "", "present": False}],
    [{"field": "session_id", "equals": 2}],
    [{"field": "dsc_hash", "equals": ""}],
    [{"field": "dsc_hash", "present": 1}],
    [{"field": "session_id", "byte_len": 0}],
    [{"field": "dsc_hash", "byte_len": -1}],
    [{"field": "dsc_hash", "length": 32}],
])
def test_rcts_1_2_33__a_malformed_header_check_is_refused(checks) -> None:
    expect = {"kind": "header_field_eq"}
    if checks is not None:
        expect["checks"] = checks
    why = _logical_fields_refusal(expect)
    assert why is not None and "RCTS.1.2.33" in why, checks


def test_rcts_1_2_33__well_formed_header_checks_are_admitted() -> None:
    assert _logical_fields_refusal({"kind": "header_field_eq", "checks": [
        {"field": "session_id", "equals": ""},
        {"field": "ds_version", "present": True},
        {"field": "tier_id", "equals": "edge"},
        {"field": "dsc_hash", "present": True},
        {"field": "dsc_hash", "byte_len": 32}]}) is None


def test_rcts_1_2_33__header_fields_are_the_clause_s_and_the_mercury_harness_s(
        ) -> None:
    import re

    from runner import HEADER_FIELDS
    text = _clause("RCTS.1.2.33")["text"]
    assert all(f"`{f}`" in text for f in HEADER_FIELDS)
    behave = (_REPO / "compiler/mercury/test/test_behave.m").read_text(
        encoding="utf-8")
    assert set(re.findall(r'^header_field_name\("([a-z_]+)"\)\.$', behave,
                          re.MULTILINE)) == set(HEADER_FIELDS)


def test_rcts_1_2_33__an_empty_checks_fails_before_it_runs() -> None:
    t = ConformanceTest(id="X", category="logical", scenario="",
                        rules_ds=_TWO_RULES,
                        expect={"kind": "header_field_eq", "checks": []},
                        path=Path("logical/X.json"))
    result = run_test(t)
    assert result.status == "failed" and "RCTS.1.2.33" in result.detail


def test_rcts_1_2_33__every_live_fixture_keeps_the_clause() -> None:
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS if t.deprecated is None
           and (why := _logical_fields_refusal(t.expect)) is not None]
    assert not bad, bad


_GOOD_INTROSPECTION = {"kind": "introspection_assert",
                       "checks": [{"surface": "fact_count", "equals": 1}]}


@pytest.mark.parametrize("checks", [
    None, [], {"surface": "fact_count", "equals": 1}, [1],
    [{"surface": "agenda"}], [{"equals": 1}],
    [{"surface": "fact_count"}],
    [{"surface": "fact_count", "equals": -1}],
    [{"surface": "fact_count", "equals": 1, "min": 0}],
    [{"surface": "justifiers", "fact_id": 0, "expect_rules": []}],
    [{"surface": "justifiers", "fact_id": 1, "expect_rules": "derive"}],
    [{"surface": "justifier_count", "fact_id": 1}],
    [{"surface": "rete_network", "min_nodes": 1}],
    [{"surface": "slot_schema_ref", "schema": "S", "slot": "n"}],
    [{"surface": "slot_schema_ref", "schema": "S", "slot": "n", "equals": 1}],
    [{"surface": "slot_conversion", "schema": "S", "slot": "t",
      "direction": "to_stored", "in": 1.0}],
    [{"surface": "slot_conversion", "schema": "S", "slot": "t",
      "direction": "sideways", "in": 1.0, "equals": None}],
    [{"surface": "slot_conversion", "schema": "S", "slot": "t",
      "direction": "to_stored", "in": "1", "equals": None}],
    [{"surface": "slot_conversion", "schema": "S", "slot": "t",
      "direction": "to_stored", "in": True, "equals": None}],
    [{"surface": "slot_conversion", "schema": "S", "slot": "t",
      "direction": "from_stored", "in": 1, "equals": "1"}],
])
def test_rcts_1_2_26__a_malformed_check_is_refused(checks) -> None:
    expect = {**_GOOD_INTROSPECTION, "checks": checks}
    if checks is None:
        del expect["checks"]
    why = _introspection_refusal(expect)
    assert why is not None and "RCTS.1.2.26" in why, checks


@pytest.mark.parametrize("add_ref", [
    {"schema": "S", "slot": "n"}, {"schema": "S", "slot": "n", "ref": 1},
    {"schema": "S", "slot": "n", "ref": "S", "kind": 1}, "S.n",
])
def test_rcts_1_2_26__an_add_schema_ref_of_another_shape_is_refused(add_ref) -> None:
    why = _introspection_refusal({**_GOOD_INTROSPECTION, "add_schema_ref": add_ref})
    assert why is not None and "add_schema_ref" in why


def test_rcts_1_2_26__well_formed_checks_are_admitted() -> None:
    assert _introspection_refusal({
        "kind": "introspection_assert",
        "add_schema_ref": {"schema": "S", "slot": "n", "ref": "S"},
        "checks": [
            {"surface": "fact_count", "equals": 0},
            {"surface": "justifiers", "fact_id": 1, "expect_rules": ["r", "r"]},
            {"surface": "justifier_count", "fact_id": 1, "count": 0},
            {"surface": "rete_network", "min_nodes": 0, "min_edges": 0},
            {"surface": "slot_schema_ref", "schema": "S", "slot": "n", "equals": None},
            {"surface": "slot_schema_ref", "schema": "S", "slot": "n", "equals": "S"},
            {"surface": "slot_conversion", "schema": "S", "slot": "t",
             "direction": "to_stored", "in": 21.5, "equals": 294.65},
            {"surface": "slot_conversion", "schema": "S", "slot": "t",
             "direction": "from_stored", "in": 12, "equals": None},
        ]}) is None


def test_rcts_1_2_26__the_surface_set_is_the_clauses_in_both_harnesses() -> None:
    """[RCTS.1.2.26]'s closed set: each surface the clause names as a list
    item, `runner.py`'s `_SURFACES` and `test_behave.m`'s `surface_members`
    name the same surfaces."""
    import re

    from runner import _SURFACES
    text = _clause("RCTS.1.2.26")["text"]
    named = set(re.findall(r"^  - `([a-z_]+)`, with ", text, re.MULTILINE))
    behave = (_REPO / "compiler/mercury/test/test_behave.m").read_text(
        encoding="utf-8")
    in_behave = set(re.findall(r'^surface_members\("([a-z_]+)"', behave,
                               re.MULTILINE))
    assert "slot_conversion" in named and "fact_count" in named
    assert named == set(_SURFACES) == in_behave, (named, set(_SURFACES), in_behave)


def test_rcts_1_2_26__a_number_keeps_its_kind_and_bits() -> None:
    from runner import _same_number
    assert _same_number(5, 5) and _same_number(0.5, 0.5)
    assert not _same_number(5, 5.0) and not _same_number(5.0, 5)
    assert not _same_number(-0.0, 0.0) and not _same_number(0.5, 0.25)


_CELSIUS = ("unit celsius: temperature = x + 273.15\n\n"
            "schema S scope logical:\n    id: Int key\n    t: celsius mutable\n"
            "    n: Float mutable\n")


def _conversion(direction: str, value, equals) -> ConformanceTest:
    return ConformanceTest(id="X", category="logical", scenario="",
                           rules_ds=_CELSIUS,
                           expect={"kind": "introspection_assert", "steps": [],
                                   "checks": [{"surface": "slot_conversion",
                                               "schema": "S", "slot": "t",
                                               "direction": direction,
                                               "in": value, "equals": equals}]},
                           path=Path("logical/X.json"))


@pytest.mark.parametrize("direction, value, equals", [
    ("to_stored", 21.5, 21.5),       # the number unconverted
    ("to_stored", 21.5, None),       # a result where none is wanted
    ("to_stored", 21, 294.15),       # an Int where the slot pairs a Float
    ("from_stored", 300.0, 26.85),   # not the result's bits
])
def test_rcts_1_2_26__a_slot_conversion_that_does_not_hold_fails(
        direction, value, equals) -> None:
    """The negative fixtures: each check is wrong about libds's conversion
    of a `celsius` slot, so the fixture fails."""
    assert run_test(_conversion(direction, value, equals)).status == "failed"


def test_rcts_1_2_26__a_slot_conversion_that_holds_passes() -> None:
    """The control for the fixtures above, on the same program."""
    assert run_test(_conversion("to_stored", 21.5, 294.65)).status == "passed"


def test_rcts_1_2_26__a_slot_conversion_of_a_slot_with_no_unit_fails() -> None:
    t = _conversion("to_stored", 1.0, None)
    t.expect["checks"][0]["slot"] = "n"
    assert run_test(t).status == "failed"


def test_rcts_1_2_26__add_schema_ref_on_another_kind_fails() -> None:
    t = ConformanceTest(id="X", category="logical", scenario="", rules_ds=_TWO_RULES,
                        expect={"kind": "event_sequence", "expected_kinds": [],
                                "add_schema_ref": {"schema": "T", "slot": "v",
                                                   "ref": "T"}},
                        path=Path("logical/X.json"))
    why = _add_schema_ref_misplaced(t)
    assert why is not None and "event_sequence" in why and "RCTS.1.2.26" in why
    assert run_test(t).status == "failed"
    t.expect["kind"] = "introspection_assert"
    assert _add_schema_ref_misplaced(t) is None


def test_rcts_1_2_26__every_introspection_assert_in_the_corpus_is_well_formed() -> None:
    """Over the whole corpus, deprecated fixtures included."""
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS
           if t.expect.get("kind") == "introspection_assert"
           and (why := _introspection_refusal(t.expect)) is not None]
    assert not bad, bad


def test_rcts_1_2_21__every_tamper_in_the_corpus_is_a_member_of_the_set() -> None:
    """Over the whole corpus: each `tamper` is one of the clause's forms,
    with an argument of its type, on a `runtime_error` fixture: a string, an
    object of one member, or a list of two or more such objects, none
    `drop_call_operand`. On a `replay_determinism` fixture it is
    `drop_call_operand` alone; on a `runtime_fact_count` fixture, an
    object other than `drop_call_operand`, or a list. A site is
    judged when the fixture runs."""
    strings = {"dsc_sha256", "last_byte"}
    objects = {"truncate_tail": int, "bad_wire_type": int,
               "drop_schema_group": str, "drop_terminal_parent": str,
               "drop_call_operand": str, "drop_action_expr": str,
               "clear_action_expr": str, "drop_assign_expr": str,
               "nest_action_expr": dict,
               "set_action_op": dict, "set_assign_op": dict,
               "duplicate_capability": int, "swap_capabilities": int,
               "set_field": dict, "truncate_to": int, "drop_atom": int,
               "insert_bytes": dict}
    def one(edit) -> bool:
        return (isinstance(edit, dict) and len(edit) == 1
                and all(op in objects and type(arg) is objects[op]
                        for op, arg in edit.items()))

    bad = []
    for t in _ALL_TESTS:
        tamper = t.expect.get("tamper")
        if tamper is None:
            continue
        if isinstance(tamper, str):
            ok = tamper in strings
        elif isinstance(tamper, list):
            ok = (len(tamper) >= 2
                  and all(one(e) and "drop_call_operand" not in e
                          for e in tamper))
        else:
            ok = one(tamper)
        kind = t.expect.get("kind")
        drop = isinstance(tamper, dict) and list(tamper) == ["drop_call_operand"]
        if kind == "replay_determinism":
            ok = ok and drop
        elif kind == "runtime_fact_count":
            ok = ok and not isinstance(tamper, str) and not drop
        elif kind != "runtime_error":
            ok = False
        if not ok:
            bad.append(f"{t.id}: {tamper!r}")
    assert not bad, bad


def _kind_case(kind: str, **expect) -> ConformanceTest:
    return ConformanceTest(id="X", category="runtime", scenario="", rules_ds=_TWO_RULES,
                           expect={"kind": kind, **expect},
                           path=Path("runtime/X.json"))


@pytest.mark.parametrize("field, value", [
    ("run_id", "r"), ("tier_id", "t"), ("expected_event_ids", []),
    ("expected_fact_ids", []), ("expected_emits", []),
    ("expected_publishes", []), ("expected_cache_seeds", []),
    ("expected_stream_kinds", []), ("expected_slots", []),
    ("expected_withdraw_causes", []),
    ("rewrite_withdraw_cause", {"index": 0, "cause": 4}),
    ("late_start", 1),
])
def test_rcts_1_2_23__a_recording_field_on_another_kind_fails(field, value) -> None:
    why = _recording_fields_misplaced(_kind_case("replay_determinism", **{field: value}))
    assert why is not None and field in why and "RCTS.1.2.23" in why
    assert _recording_fields_misplaced(_kind_case("rfcs_roundtrip", **{field: value})) is None


def test_rcts_1_2_23__late_start_is_replay_refused_s_too() -> None:
    """[RCTS.1.2.18] reads `late_start` on `replay_refused`; every other
    recording field is still refused there."""
    assert _recording_fields_misplaced(_kind_case("replay_refused", late_start=1)) is None
    why = _recording_fields_misplaced(
        _kind_case("replay_refused", late_start=1, expected_cache_seeds=[]))
    assert why is not None and "expected_cache_seeds" in why


def test_rcts_1_2_23__a_fixture_with_none_of_them_is_not_judged() -> None:
    assert _recording_fields_misplaced(_kind_case("replay_determinism")) is None


_THREE_STEPS = [{"op": "set", "now_ns": 0}, {"op": "pump"}, {"op": "pump"}]


@pytest.mark.parametrize("n", [0, 3, -1, True, 1.0, "1", None])
def test_rcts_1_2_23__a_late_start_outside_the_steps_is_refused(n) -> None:
    why = _recording_fields_refusal(
        {"kind": "rfcs_roundtrip", "steps": _THREE_STEPS, "late_start": n})
    assert why is not None and "late_start" in why and "RCTS.1.2.23" in why


@pytest.mark.parametrize("n", [1, 2])
def test_rcts_1_2_23__a_late_start_inside_the_steps_is_admitted(n) -> None:
    assert _recording_fields_refusal(
        {"kind": "rfcs_roundtrip", "steps": _THREE_STEPS, "late_start": n}) is None


@pytest.mark.parametrize("field, value", [
    ("run_id", 7), ("tier_id", None), ("expected_event_ids", "a-b"),
    ("expected_event_ids", [1]), ("expected_stream_kinds", ["tick", 2]),
    ("expected_slots", ["Slot"]), ("expected_withdraw_causes", "SUPERSEDED"),
    ("rewrite_withdraw_cause", {"index": 0}),
    ("rewrite_withdraw_cause", {"index": -1, "cause": 4}),
    ("rewrite_withdraw_cause", {"index": True, "cause": 4}),
    ("rewrite_withdraw_cause", {"index": 0, "cause": 4, "extra": 1}),
    ("expected_fact_ids", [1]),
    ("expected_fact_ids", {"atom": "FactAssert", "fact_id": 1}),
    ("expected_fact_ids", [{"atom": "FactRetract", "fact_id": 1}]),
    ("expected_fact_ids", [{"atom": "FactAssert", "fact_id": -1}]),
    ("expected_fact_ids", [{"atom": "FactAssert", "fact_id": True}]),
    ("expected_fact_ids", [{"atom": "FactAssert"}]),
    ("expected_fact_ids", [{"atom": "FactAssert", "fact_id": 1, "seq": 0}]),
    ("expected_emits", {"rule_name": "r"}),
    ("expected_emits", ["r"]),
    ("expected_emits", [{}]),
    ("expected_emits", [{"rule_name": 1}]),
    ("expected_emits", [{"rule_name": "r", "published": False}]),
    ("expected_publishes", {"schema_name": "S", "rule_name": "r"}),
    ("expected_publishes", ["S"]),
    ("expected_publishes", [{"rule_name": "r"}]),
    ("expected_publishes", [{"schema_name": "S"}]),
    ("expected_publishes", [{"schema_name": 1, "rule_name": "r"}]),
    ("expected_publishes", [{"schema_name": "S", "rule_name": None}]),
    ("expected_publishes", [{"schema_name": "S", "rule_name": "r", "seq": 0}]),
    ("expected_cache_seeds", {"key": "k", "value_json": "1", "deadline_ns": 0}),
    ("expected_cache_seeds", ["k"]),
    ("expected_cache_seeds", [{"key": "k", "value_json": "1"}]),
    ("expected_cache_seeds", [{"key": 1, "value_json": "1", "deadline_ns": 0}]),
    ("expected_cache_seeds", [{"key": "k", "value_json": 1, "deadline_ns": 0}]),
    ("expected_cache_seeds", [{"key": "k", "value_json": "1", "deadline_ns": -1}]),
    ("expected_cache_seeds", [{"key": "k", "value_json": "1",
                               "deadline_ns": 2 ** 63}]),
    ("expected_cache_seeds", [{"key": "k", "value_json": "1",
                               "deadline_ns": True}]),
    ("expected_cache_seeds", [{"key": "k", "value_json": "1", "deadline_ns": 0,
                               "ttl_ns": 0}]),
])
def test_rcts_1_2_23__a_value_of_another_type_is_refused(field, value) -> None:
    why = _recording_fields_refusal({"kind": "rfcs_roundtrip", field: value})
    assert why is not None and field in why and "RCTS.1.2.23" in why


def test_rcts_1_2_23__well_typed_values_are_admitted() -> None:
    assert _recording_fields_refusal({
        "kind": "rfcs_roundtrip", "run_id": "", "tier_id": "t",
        "expected_event_ids": ["00000000-0000-8000-8000-000000000000"],
        "expected_stream_kinds": ["fact_assert"], "expected_slots": [{}],
        "expected_withdraw_causes": ["CAUSE_4"],
        "rewrite_withdraw_cause": {"index": 0, "cause": 4},
        "expected_fact_ids": [{"atom": "FactAssert", "fact_id": 1},
                              {"atom": "FactEmit", "fact_id": 2},
                              {"atom": "FactWithdraw", "fact_id": 0}],
        "expected_emits": [{"rule_name": "r"}, {"rule_name": ""}],
        "expected_publishes": [{"schema_name": "S", "rule_name": "r"},
                               {"schema_name": "", "rule_name": ""}],
        "expected_cache_seeds": [
            {"key": "k", "value_json": "1", "deadline_ns": 0},
            {"key": "", "value_json": "", "deadline_ns": 2 ** 63 - 1}],
    }) is None


_CAPPED = ("schema Line scope logical:\n    k: Int key\n"
           "    text: String capacity 8 mutable\n")


def _refused_case(kind: str, step: dict) -> ConformanceTest:
    return ConformanceTest(id="X", category="runtime", scenario="", rules_ds=_CAPPED,
                           expect={"kind": kind, "steps": [step]},
                           path=Path("runtime/X.json"))


def test_rcts_1_2_27__refused_on_another_kind_fails() -> None:
    step = {"op": "assert", "schema": "Line", "slots": {"k": 1, "text": "x"},
            "refused": "-710"}
    why = _refused_step_refusal(_refused_case("runtime_error", step))
    assert why is not None and "RCTS.1.2.27" in why and "runtime_error" in why
    assert _refused_step_refusal(_refused_case("rfcs_roundtrip", step)) is None


def test_rcts_1_2_27__refused_on_a_step_that_is_not_an_assert_fails() -> None:
    why = _refused_step_refusal(
        _refused_case("rfcs_roundtrip", {"op": "pump", "refused": "-710"}))
    assert why is not None and "`pump`" in why and "RCTS.1.2.27" in why


def test_rcts_1_2_27__a_refused_that_is_not_a_string_fails() -> None:
    why = _refused_step_refusal(_refused_case("rfcs_roundtrip",
        {"op": "assert", "schema": "Line", "slots": {"k": 1, "text": "x"},
         "refused": -710}))
    assert why is not None and "not a string" in why


def test_rcts_1_2_27__an_assert_the_runtime_admits_fails() -> None:
    """The step names a refusal and the runtime admits the assert: a value
    within capacity. Run through libds, so the check is seen to fire."""
    result = run_test(_refused_case("rfcs_roundtrip",
        {"op": "assert", "schema": "Line", "slots": {"k": 1, "text": "abc"},
         "refused": "-710"}))
    assert result.status == "failed" and "was admitted" in result.detail


def test_rcts_1_2_27__a_refusal_with_another_status_fails() -> None:
    result = run_test(_refused_case("rfcs_roundtrip",
        {"op": "assert", "schema": "Line",
         "slots": {"k": 1, "text": "abcdefghi"}, "refused": "-1"}))
    assert result.status == "failed" and "refused with -710" in result.detail


def test_rcts_1_2_27__the_named_refusal_lets_the_steps_go_on() -> None:
    result = run_test(_refused_case("rfcs_roundtrip",
        {"op": "assert", "schema": "Line",
         "slots": {"k": 1, "text": "abcdefghi"}, "refused": "-710"}))
    assert result.status == "passed", result.detail


def _steps_case(category: str, expect: dict, *, deprecated=None) -> ConformanceTest:
    return ConformanceTest(id="X", category=category, scenario="", rules_ds=_TWO_RULES,
                           expect={"kind": "rule_fire_order", **expect},
                           path=Path(f"{category}/X.json"), deprecated=deprecated)


def test_rcts_1_2_28__every_live_fixture_keeps_the_step_vocabulary() -> None:
    """Over the whole corpus but the retired: each array of steps holds only
    [RCTS.1.2.28]'s ops, as each takes its members."""
    bad = [f"{_where(t)}: {why}" for t in _ALL_TESTS
           if (why := _steps_refusal(t)) is not None]
    assert not bad, bad


def test_rcts_1_2_28__every_op_of_the_set_passes() -> None:
    assert _steps_refusal(_steps_case("logical", {"steps": [
        {"op": "assert", "schema": "T", "slots": {"v": 1}, "as": "a",
         "corr_from_call": 0},
        {"op": "retract", "label": "a"}, {"op": "pump"},
        {"op": "advance", "delta_ns": 1}, {"op": "set", "now_ns": 0},
        {"op": "wall_set", "utc_ns": -1},
        {"op": "cache_seed", "key": "k", "value": None},
        {"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": 0},
        {"op": "cache_seed", "key": "k", "value": 1,
         "ttl_ns": 2 ** 63 - 1}]})) is None


@pytest.mark.parametrize("step, says", [
    ({"op": "deliver"}, "names no step op"),
    ({"schema": "T"}, "names no step op"),
    ({"op": "advance"}, "lacks `delta_ns`"),
    ({"op": "pump", "label": "x"}, "carries `label`"),
    ({"op": "advance", "delta_ns": -1}, "not of its type"),
    ({"op": "set", "now_ns": True}, "not of its type"),
    ({"op": "assert", "schema": 1}, "not of its type"),
    # `cache_seed`'s `ttl_ns`: an integer from 0 to 2^63 - 1, no bool.
    ({"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": -1}, "not of its type"),
    ({"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": True}, "not of its type"),
    ({"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": "5"}, "not of its type"),
    ({"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": 1.5}, "not of its type"),
    ({"op": "cache_seed", "key": "k", "value": 1, "ttl_ns": 2 ** 63}, "not of its type"),
    ({"op": "forward", "from": "a"}, "names no step op"),
    ({"op": "pump", "engine": "a"}, "cross-tier fixture's alone"),
])
def test_rcts_1_2_28__a_step_off_the_vocabulary_fails(step, says) -> None:
    why = _steps_refusal(_steps_case("logical", {"steps": [step]}))
    assert why is not None and says in why, why


def test_rcts_1_2_28__clone_arrays_are_steps_too() -> None:
    why = _steps_refusal(_steps_case("runtime", {"after_free": [{"op": "shake"}]}))
    assert why is not None and why.startswith("after_free[0]")
    assert _steps_refusal(_steps_case("runtime", {"steps": "pump"})) is not None


def test_rcts_1_2_28__a_retired_fixture_is_not_judged() -> None:
    assert _steps_refusal(_steps_case("adapter", {"steps": [{"op": "deliver"}]},
                                      deprecated="retired")) is None


_ENGINES = {"a": {"rules_ds": ""}}


def test_rcts_1_2_29__a_cross_tier_step_names_its_engine_and_may_forward() -> None:
    assert _steps_refusal(_steps_case("cross-tier", {"engines": _ENGINES, "steps": [
        {"engine": "a", "op": "pump"},
        {"engine": "a", "op": "forward", "from": "a"},
        {"engine": "a", "op": "forward_external", "from": "a"}]})) is None


@pytest.mark.parametrize("expect, says", [
    ({"engines": _ENGINES, "steps": [{"engine": "b", "op": "pump"}]}, "engine names no engine"),
    ({"engines": _ENGINES, "steps": [{"op": "pump"}]}, "engine names no engine"),
    ({"engines": _ENGINES, "steps": [{"engine": "a", "op": "forward", "from": "z"}]},
     "from names no engine"),
    ({"engines": {}}, "not an object of"),
    ({"engines": {"a": {"rules_ds": "", "extra": 1}}}, "not an object of"),
])
def test_rcts_1_2_29__a_cross_tier_fixture_off_its_shape_fails(expect, says) -> None:
    why = _steps_refusal(_steps_case("cross-tier", expect))
    assert why is not None and says in why and "RCTS.1.2.29" in why, why


def test_rcts_1_2_29__engines_is_cross_tier_s_alone() -> None:
    why = _steps_refusal(_steps_case("logical", {"engines": _ENGINES}))
    assert why is not None and "cross-tier fixture's alone" in why


def test_rcts_1_2_28__a_corr_from_call_no_call_answers_fails() -> None:
    """Run through libds, so `_Session`'s check is seen to fire: no rule
    calls anything, so there is no 0th call to read a correlation off."""
    result = run_test(_steps_case("logical", {
        "expected_rule_names": [],
        "steps": [{"op": "assert", "schema": "T", "slots": {"v": 1},
                   "corr_from_call": 0}]}))
    assert result.status == "failed" and "corr_from_call 0" in result.detail, \
        result.detail


def test_rcts_1_2_28__a_retract_of_an_unkept_label_fails() -> None:
    result = run_test(_steps_case("logical", {
        "expected_rule_names": [],
        "steps": [{"op": "retract", "label": "nobody"}]}))
    assert result.status == "failed" and "`nobody`" in result.detail, result.detail


@pytest.mark.parametrize("steps, op", [
    ([{"op": "pump"}, {"op": "cache_seed", "key": "k", "value": 1}],
     "cache_seed"),
    ([{"op": "assert", "schema": "T", "slots": {"v": 1}},
      {"op": "cache_seed", "key": "k", "value": 1}], "cache_seed"),
    ([{"op": "set", "now_ns": 5}, {"op": "assert", "schema": "T", "slots": {"v": 1}},
      {"op": "pump"}, {"op": "set", "now_ns": 0}], "set"),
])
def test_rcts_1_2_28__a_step_the_runtime_refuses_fails(steps, op) -> None:
    """Run through libds: a seed after the engine's first stream event, a
    pump's or a host assert's, is refused ([NLFC.9.2]), and so is a set
    below the current instant after an input ([NTST.3.1]). No fixture pins
    the refusal, so each fails, naming the step. `test_behave.m`'s
    `step_vocabulary_checks` runs the same three."""
    result = run_test(_steps_case("logical", {"expected_rule_names": [],
                                              "steps": steps}))
    assert (result.status == "failed" and f'"op": "{op}"' in result.detail
            and "RCTS.1.2.28" in result.detail), result.detail


@pytest.mark.parametrize("value", [
    {"$bytes": "00 ff"}, {"$bytes": "0"}, {"$bytes": "zz"}, {"$bytes": 5},
    {"$bytes": "00", "x": 1},
])
def test_rcts_1_2_28__a_bytes_slot_off_its_form_fails(value) -> None:
    why = _steps_refusal(_steps_case("logical", {"steps": [
        {"op": "assert", "schema": "T", "slots": {"b": value}}]}))
    assert why is not None and "slots.b" in why, why


def test_rcts_1_2_28__the_bytes_form_passes() -> None:
    assert _steps_refusal(_steps_case("logical", {"steps": [
        {"op": "assert", "schema": "T",
         "slots": {"b": {"$bytes": "00fF"}, "e": {"$bytes": ""}}}]})) is None


@pytest.mark.parametrize("value", [
    {"$text_bytes": "c0 af"}, {"$text_bytes": "c"}, {"$text_bytes": "zz"},
    {"$text_bytes": 5}, {"$text_bytes": "c0af", "x": 1},
    {"$text_bytes": "00"}, {"$text_bytes": "c000"},
])
def test_rcts_1_2_28__a_text_bytes_slot_off_its_form_fails(value) -> None:
    """[LSTR.8.5]'s form, held as the `Bytes` form is, and with no `00`
    octet ([LSTR.1.5]); `test_behave.m`'s `step_vocabulary_checks` refuses
    the same seven."""
    why = _steps_refusal(_steps_case("logical", {"steps": [
        {"op": "assert", "schema": "T", "slots": {"s": value}}]}))
    assert why is not None and "slots.s" in why and "$text_bytes" in why, why


def test_rcts_1_2_28__the_text_bytes_form_passes_the_shape_check() -> None:
    assert _steps_refusal(_steps_case("logical", {"steps": [
        {"op": "assert", "schema": "T",
         "slots": {"s": {"$text_bytes": "c0aF"}, "e": {"$text_bytes": ""},
                   "a": {"$text_bytes": "a00b"}}}]})) is None


def test_rcts_1_2_28__text_bytes_on_a_slot_that_is_not_a_string_fails() -> None:
    """Run through libds: pyds takes `bytes` for a `Bytes` slot, so the form
    given to one would pass as a `Bytes` value; the harness refuses it, as
    `test_behave.m`'s `slot_value` does."""
    t = ConformanceTest(
        id="X", category="runtime", scenario="",
        rules_ds="schema B scope logical:\n    k: Int key\n    b: Bytes mutable\n",
        expect={"kind": "runtime_error", "code": "-222", "steps": [
            {"op": "assert", "schema": "B",
             "slots": {"k": 1, "b": {"$text_bytes": "61"}}}]},
        path=Path("runtime/X.json"))
    result = run_test(t)
    assert (result.status == "failed" and "slots.b" in result.detail
            and "RCTS.1.2.28" in result.detail), result.detail


_ONE_PUMP = [{"op": "assert", "schema": "T", "slots": {"v": 1}}, {"op": "pump"}]


@pytest.mark.parametrize("kind", ["adapter_cache_sets", "adapter_mock",
                                  "runtime_error", "event_sequence"])
def test_rcts_1_2_30__expected_pump_statuses_on_another_kind_fails(kind) -> None:
    t = _kind_case(kind, steps=_ONE_PUMP, expected_pump_statuses=[0])
    why = _pump_statuses_refusal(t)
    assert why is not None and kind in why and "RCTS.1.2.30" in why, why
    assert run_test(t).status == "failed"


@pytest.mark.parametrize("value", [
    "0", 0, None, {"0": 0}, ["-216"], [True], [1], [-216.0],
])
def test_rcts_1_2_30__a_value_of_another_type_is_refused(value) -> None:
    why = _pump_statuses_refusal(_kind_case(
        "adapter_calls", steps=_ONE_PUMP, expected_pump_statuses=value))
    assert why is not None and "not an array of integers" in why, why


@pytest.mark.parametrize("statuses", [[], [0, 0]])
def test_rcts_1_2_30__one_entry_for_each_pump_step(statuses) -> None:
    why = _pump_statuses_refusal(_kind_case(
        "adapter_calls", steps=_ONE_PUMP, expected_pump_statuses=statuses))
    assert why is not None and "for 1 `pump` steps" in why, why


def test_rcts_1_2_30__well_formed_statuses_are_admitted() -> None:
    assert _pump_statuses_refusal(_kind_case(
        "adapter_calls", steps=_ONE_PUMP + _ONE_PUMP,
        expected_pump_statuses=[-216, 0])) is None
    assert _pump_statuses_refusal(_kind_case("adapter_calls", steps=_ONE_PUMP)) is None
    assert _pump_statuses_refusal(_kind_case(
        "replay_determinism", steps=_ONE_PUMP, expected_pump_statuses=[-216])) is None


def test_rcts_1_2_30__not_beside_tamper() -> None:
    why = _pump_statuses_refusal(_kind_case(
        "replay_determinism", steps=_ONE_PUMP, expected_pump_statuses=[0],
        tamper={"drop_call_operand": "r"}))
    assert why is not None and "tamper" in why, why


def _pump_status_vector(kind: str) -> ConformanceTest:
    """The live vector of `kind` whose first pump reports a status: so the two
    tests below drive the comparison through libds, not a case built for them."""
    carriers = [t for t in _ALL_TESTS
                if t.expect.get("kind") == kind
                and "expected_pump_statuses" in t.expect and t.deprecated is None
                and any(s != 0 for s in t.expect["expected_pump_statuses"])]
    assert carriers, f"no live {kind} vector states a pump's refusal"
    return carriers[0]


@pytest.mark.parametrize("kind", ["adapter_calls", "replay_determinism"])
def test_rcts_1_2_30__a_status_off_its_entry_fails_the_fixture(kind) -> None:
    t = _pump_status_vector(kind)
    want = t.expect["expected_pump_statuses"]
    off = [0 if s != 0 else -1 for s in want]
    result = run_test(replace(t, expect={**t.expect, "expected_pump_statuses": off}))
    assert result.status == "failed" and "pump statuses" in result.detail, result.detail


def test_rcts_1_2_30__without_the_field_the_refused_pump_fails_the_fixture() -> None:
    """[RCTS.1.2.28]: the field is what makes the refusal the pump's outcome."""
    t = _pump_status_vector("adapter_calls")
    expect = {k: v for k, v in t.expect.items() if k != "expected_pump_statuses"}
    result = run_test(replace(t, expect=expect))
    assert result.status == "failed" and "RCTS.1.2.28" in result.detail, result.detail


def test_rcts_1_2_30__every_carrier_in_the_corpus_is_well_formed() -> None:
    """Over the whole corpus, deprecated fixtures included."""
    carriers = [t for t in _ALL_TESTS if "expected_pump_statuses" in t.expect]
    assert carriers
    bad = [f"{_where(t)}: {why}" for t in carriers
           if (why := _pump_statuses_refusal(t)) is not None]
    assert not bad, bad


@pytest.mark.parametrize("kind", ["cross_tier_fact_counts",
                                  "cross_tier_per_engine_event_counts"])
def test_rcts_1_2_30__a_cross_tier_kind_may_carry_the_statuses(kind) -> None:
    """Its pumps are every engine's, in step order."""
    steps = [{"engine": "a", "op": "pump"}, {"engine": "b", "op": "pump"}]
    assert _pump_statuses_refusal(_kind_case(
        kind, steps=steps, expected_pump_statuses=[-710, 0])) is None
    why = _pump_statuses_refusal(_kind_case(
        kind, steps=steps, expected_pump_statuses=[-710]))
    assert why is not None and "for 2 `pump` steps" in why, why


# A sender whose one rule publishes an `Out` built from its `Trig`. Its `s` is
# `capacity 8` and the value is the `Trig`'s text twice, so a five-codepoint
# text is refused ([LTIE.4.8], [LSTR.11.3]: -710) and a two-codepoint one is
# published.
_EDGE = ("schema Trig scope logical:\n    k: Int key\n    text: String mutable\n\n"
         "schema Out scope ttl 1_h:\n    k: Int\n    s: String capacity 8\n\n"
         "rule up:\n    Trig t\n->\n    publish Out k: t.k s: \"{t.text}{t.text}\"\n")


def _cross_tier_case(steps: list, **expect) -> ConformanceTest:
    return ConformanceTest(
        id="X", category="cross-tier", scenario="", rules_ds="",
        expect={"kind": "cross_tier_fact_counts",
                "engines": {"edge": {"rules_ds": _EDGE}},
                "steps": steps, "engine_fact_counts_after": {"edge": 1}, **expect},
        path=Path("cross-tier/X.json"))


_REFUSED_PUBLISH = [
    {"engine": "edge", "op": "assert", "schema": "Trig",
     "slots": {"k": 1, "text": "abcde"}},
    {"engine": "edge", "op": "pump"}]


def test_rcts_1_2_30__a_cross_tier_refused_pump_is_its_status() -> None:
    """Run through libds: the publish is refused, the pump reports -710, and
    with the field that is the pump's outcome."""
    result = run_test(_cross_tier_case(_REFUSED_PUBLISH,
                                       expected_pump_statuses=[-710]))
    assert result.status == "passed", result.detail


def test_rcts_1_2_30__a_cross_tier_status_off_its_entry_fails() -> None:
    result = run_test(_cross_tier_case(_REFUSED_PUBLISH,
                                       expected_pump_statuses=[0]))
    assert (result.status == "failed"
            and "pump statuses: want [0], got [-710]" in result.detail), \
        result.detail


def test_rcts_1_2_28__a_cross_tier_refused_pump_without_the_field_fails() -> None:
    result = run_test(_cross_tier_case(_REFUSED_PUBLISH))
    assert result.status == "failed" and "RCTS.1.2.28" in result.detail, \
        result.detail


@pytest.mark.parametrize("category, expect, says", [
    ("logical", {"expected_published_asserted_at": {}}, "cross-tier fixture's alone"),
    ("cross-tier", {"engines": _ENGINES, "expected_published_asserted_at": []},
     "not an object of arrays"),
    ("cross-tier", {"engines": _ENGINES, "expected_published_asserted_at": {"a": 5}},
     "not an object of arrays"),
    ("cross-tier", {"engines": _ENGINES,
                    "expected_published_asserted_at": {"a": [True]}},
     "not an object of arrays"),
    ("cross-tier", {"engines": _ENGINES,
                    "expected_published_asserted_at": {"a": ["5"]}},
     "not an object of arrays"),
    ("cross-tier", {"engines": _ENGINES,
                    "expected_published_asserted_at": {"a": [1.5]}},
     "not an object of arrays"),
    ("cross-tier", {"engines": _ENGINES,
                    "expected_published_asserted_at": {"b": [5]}},
     "names no engine"),
])
def test_rcts_1_2_29__published_asserted_at_off_its_shape_fails(
        category, expect, says) -> None:
    why = _published_asserted_at_refusal(_steps_case(category, expect))
    assert why is not None and says in why and "RCTS.1.2.29" in why, why


def test_rcts_1_2_29__published_asserted_at_of_its_shape_is_admitted() -> None:
    assert _published_asserted_at_refusal(_steps_case("cross-tier", {
        "engines": _ENGINES,
        "expected_published_asserted_at": {"a": [0, None, 2 ** 62]}})) is None
    assert _published_asserted_at_refusal(_steps_case("cross-tier", {
        "engines": _ENGINES})) is None


def _external(at: int | None) -> bytes:
    from pyds.proto import fact_external_pb2
    fe = fact_external_pb2.FactExternal(schema="Out")
    if at is not None:
        fe.asserted_at = at
        fe.has_asserted_at = True
    return fe.SerializeToString()


def test_rcts_1_2_29__published_asserted_at_is_read_off_each_record() -> None:
    """`has_asserted_at` false reads as null; a count or an entry that
    differs fails; a publication with no record fails."""
    got = {"a": [_external(5), _external(None)]}
    assert _published_asserted_at_mismatch({"a": [5, None]}, got) is None
    for want in ([5, 5], [5], [5, None, 7], [None, None], [0, None]):
        why = _published_asserted_at_mismatch({"a": want}, got)
        assert why is not None and "published asserted_at" in why, (want, why)
    why = _published_asserted_at_mismatch({"a": [5]}, {"a": [b""]})
    assert why is not None and "carried no FactExternal" in why, why


_PUBLISHED_AT = [
    {"engine": "edge", "op": "wall_set", "utc_ns": 1700000000000000000},
    {"engine": "edge", "op": "assert", "schema": "Trig",
     "slots": {"k": 1, "text": "ab"}},
    {"engine": "edge", "op": "pump"}]


def test_rcts_1_2_29__a_publication_s_asserted_at_is_read_through_libds() -> None:
    """Run through libds: the one publication carries the wall instant of the
    pump that published it ([RFCS.23.5]), and an entry one off fails."""
    result = run_test(_cross_tier_case(_PUBLISHED_AT, expected_published_asserted_at={
        "edge": [1700000000000000000]}))
    assert result.status == "passed", result.detail
    result = run_test(_cross_tier_case(_PUBLISHED_AT, expected_published_asserted_at={
        "edge": [1700000000000000001]}))
    assert (result.status == "failed"
            and "published asserted_at" in result.detail), result.detail


def test_rcts_1_2_29__an_engine_s_wall_clock_may_be_unset() -> None:
    assert _steps_refusal(_steps_case("cross-tier", {"engines": {
        "a": {"rules_ds": "", "wall_clock": "unset"}}})) is None


@pytest.mark.parametrize("decl", [
    {"rules_ds": "", "wall_clock": "set"},
    {"rules_ds": "", "wall_clock": True},
    {"rules_ds": "", "wall_clock": None},
    {"rules_ds": "", "wall_clock": "unset", "extra": 1},
])
def test_rcts_1_2_29__an_engine_s_wall_clock_off_its_shape_fails(decl) -> None:
    why = _steps_refusal(_steps_case("cross-tier", {"engines": {"a": decl}}))
    assert why is not None and "RCTS.1.2.29" in why, why


def test_rcts_1_2_29__an_unset_wall_clock_publishes_no_instant() -> None:
    """Run through libds: `edge` starts with its wall clock unset, so its
    first publication's FactExternal has no `asserted_at` ([RFCS.23.5]); a
    `wall_set` then gives it one, which the second carries. A driver that set
    the wall clock anyway reads `0` for the first and fails."""
    steps = [
        {"engine": "edge", "op": "assert", "schema": "Trig",
         "slots": {"k": 1, "text": "ab"}},
        {"engine": "edge", "op": "pump"},
        {"engine": "edge", "op": "wall_set", "utc_ns": 1700000000000000000},
        {"engine": "edge", "op": "assert", "schema": "Trig",
         "slots": {"k": 2, "text": "cd"}},
        {"engine": "edge", "op": "pump"}]

    def case(want: list) -> ConformanceTest:
        return ConformanceTest(
            id="X", category="cross-tier", scenario="", rules_ds="",
            expect={"kind": "cross_tier_fact_counts",
                    "engines": {"edge": {"rules_ds": _EDGE,
                                         "wall_clock": "unset"}},
                    "steps": steps, "engine_fact_counts_after": {"edge": 2},
                    "expected_published_asserted_at": {"edge": want}},
            path=Path("cross-tier/X.json"))

    result = run_test(case([None, 1700000000000000000]))
    assert result.status == "passed", result.detail
    result = run_test(case([0, 1700000000000000000]))
    assert (result.status == "failed"
            and "published asserted_at" in result.detail), result.detail


def test_every_dead_rules_expected_names_a_rule_of_its_fixture() -> None:
    """Over the whole corpus, so a typo in a fixture that is not run here
    (`compiler`, or a deprecated one) is caught too."""
    bad = []
    for t in _ALL_TESTS:
        if not t.dead_rules_expected:
            continue
        missing = sorted(set(t.dead_rules_expected) - set(_extract_rule_names(t.rules_ds)))
        if missing:
            bad.append(f"{_where(t)}: {', '.join(missing)}")
    assert not bad, f"dead_rules_expected naming no rule: {bad}"


def test_rcts_1_2_10__event_sequence_lets_unnamed_kinds_interleave() -> None:
    want = ["fact_assert", "rule_fire_begin"]
    assert _event_sequence_projection(
        want, ["tick", "fact_assert", "pump", "rule_lhs_facts",
               "rule_fire_begin", "action_log", "rule_fire_end"],
    ) == want


def test_rcts_1_2_10__event_sequence_states_every_event_of_a_named_kind() -> None:
    """A second `fact_retract`, which a subsequence match would pass."""
    want = ["fact_assert", "fact_retract"]
    assert _event_sequence_projection(
        want, ["fact_assert", "fact_retract", "fact_retract"],
    ) != want


def test_rcts_1_2_10__event_sequence_counts_repeats_of_a_stated_kind() -> None:
    want = ["rule_fire_begin", "rule_fire_begin"]
    assert _event_sequence_projection(
        want, ["rule_fire_begin", "rule_fire_end",
               "rule_fire_begin", "rule_fire_end", "rule_fire_begin"],
    ) != want


def test_rcts_1_2_10__event_sequence_keeps_stream_order() -> None:
    want = ["fact_assert", "computation_error"]
    assert _event_sequence_projection(
        want, ["tick", "computation_error", "fact_assert", "pump"],
    ) != want


@pytest.mark.parametrize("value", [True, False, None, "yes"])
def test_rcts_1_2_14__a_fixture_carrying_stdlib_is_malformed(value) -> None:
    """The standard library is on every fixture's search path, so the key is
    retired, whatever its value."""
    refusal = _format_refusal(_loaded(json.dumps({**_WELL_FORMED, "stdlib": value})))
    assert refusal is not None
    clause, why = refusal
    assert clause == "RCTS.1.2.14" and "`stdlib`" in why


def test_rcts_1_2_14__a_library_the_standard_library_supplies_is_malformed() -> None:
    """`units.core` ships under `stdlib/`, so a fixture's own copy of it would
    shadow or be shadowed by it; the harness refuses rather than choose."""
    lib = "unit dimension widgets storage float64 base widget\nunit widget: widgets\n"
    refusal = _format_refusal(_loaded(json.dumps(
        {**_WELL_FORMED, "libraries": {"units.core": lib}})))
    assert refusal is not None
    clause, why = refusal
    assert clause == "RCTS.1.2.14" and "units.core" in why
    assert _format_refusal(_loaded(json.dumps(
        {**_WELL_FORMED, "libraries": {"widgets": lib}}))) is None


@pytest.mark.parametrize("files", [{}, {"main.dstest": ""}, "not even an object"])
def test_rcts_1_2_35__files_on_a_fixture_this_harness_judges_is_malformed(
        files) -> None:
    """`files` is the `compiler` category's alone, whatever its value: on a
    `logical` fixture it is refused under [RCTS.1.2.35], before
    [RCTS.1.2.14]'s check, as `test_conformance.m`'s `rcts_fixture_format`
    orders them. Its control, the same fixture without the field, is well
    formed."""
    refusal = _format_refusal(_loaded(json.dumps(
        {**_WELL_FORMED, "files": files, "stdlib": True})))
    assert refusal is not None
    clause, why = refusal
    assert clause == "RCTS.1.2.35" and "`logical`" in why, why
    assert _format_refusal(_loaded(json.dumps(_WELL_FORMED))) is None


def test_rcts_1_2_35__no_fixture_this_harness_judges_carries_files() -> None:
    """Over the corpus this harness reads, but the `malformed_fixture` vectors
    that carry the field to be refused."""
    bad = [_where(t) for t in _ALL_TESTS if t.has_files_key
           and t.category != "compiler"
           and not (t.expect.get("kind") == "malformed_fixture"
                    and t.expect.get("reason") == "RCTS.1.2.35")]
    assert not bad, bad


def test_rcts_1_2_14__no_fixture_in_the_corpus_carries_stdlib() -> None:
    """Over the whole corpus, deprecated fixtures included, but the
    `malformed_fixture` vector that carries it to be refused
    (`compiler/RCTS.1.2.14_stdlib_key_retired`)."""
    bad = [_where(t) for t in _ALL_TESTS if t.has_stdlib_key
           and not (t.expect.get("kind") == "malformed_fixture"
                    and t.expect.get("reason") == "RCTS.1.2.14")]
    assert not bad, bad

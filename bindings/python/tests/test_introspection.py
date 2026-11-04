# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""engine.schemas and engine.rules: mappings of frozen dataclasses."""

import dataclasses
from collections.abc import Mapping
from pathlib import Path

import pytest

import pyds

REPO_ROOT = Path(__file__).resolve().parents[3]
SAMPLES_DIR = REPO_ROOT / "bindings" / "python" / "tests" / "grammar_samples"


def _artefact() -> bytes:
    # Through pyds.compile, the path every integrator takes.
    # The sample is a library (no `use` line); this makes it a program, one
    # line longer, so every position below is the sample's own plus one.
    text = "use default\n" + (SAMPLES_DIR / "04_rule_minimal.ds").read_text()
    return pyds.compile(text, file="mvp.ds")


def _loaded_engine() -> pyds.Engine:
    eng = pyds.Engine()
    eng.load_dsc(_artefact())
    return eng


def test_schemas_is_a_mapping_of_the_programs_and_the_built_in_ones():
    # Every artefact also carries the two fault schemas and
    # TimeZoneOffset ([LIMP.12.2]), ahead of the program's own.
    schemas = _loaded_engine().schemas
    assert isinstance(schemas, Mapping)
    assert set(schemas) == {"Trig", "ComputationError", "TypeError", "TimeZoneOffset"}
    assert len(schemas) == 4
    assert "Trig" in schemas and "Nope" not in schemas


def test_a_schema_is_found_by_name_and_a_missing_one_is_a_key_error():
    schemas = _loaded_engine().schemas
    assert schemas["Trig"].name == "Trig"
    assert schemas.get("Nope") is None
    with pytest.raises(KeyError, match="Nope"):
        schemas["Nope"]


def test_rdsc_8_7__a_slot_naming_the_built_in_schema_loads():
    # TimeZoneOffset is `scope logical ambient` ([LTIM.10.6]) and every artefact
    # defines it ([LIMP.12.2]), so a slot naming it dangles nowhere. The Mercury
    # runtime's fixture 152_plan_refusals.ds has a WithZone of this shape.
    text = (
        "use default\nschema Zoned scope logical:\n    k: Int key\n    b: TimeZoneOffset mutable\n"
    )
    eng = pyds.Engine()
    eng.load_dsc(pyds.compile(text, file="zoned.ds"))
    _, b = eng.schemas["Zoned"].slots
    assert b.schema_ref == "TimeZoneOffset"
    assert list(eng.schemas).index("TimeZoneOffset") < list(eng.schemas).index("Zoned")


def test_a_key_that_is_not_a_str_is_a_key_error_not_a_type_error():
    # A Mapping answers a key it cannot hold with KeyError, as dict does.
    with pytest.raises(KeyError):
        _loaded_engine().schemas[3]


def test_the_view_reads_the_engine_when_used():
    # Taken before the load, read after it: the load is the one way a schema
    # reaches an engine ([NFCT.1.1]).
    eng = pyds.Engine()
    schemas = eng.schemas
    assert "Trig" not in schemas
    eng.load_dsc(_artefact())
    assert "Trig" in schemas
    assert list(schemas)[-1] == "Trig"


def test_schema_lifecycle_is_a_lifecycle_and_equals_the_ds_word():
    s = _loaded_engine().schemas["Trig"]
    assert s.lifecycle is pyds.Lifecycle.LOGICAL
    assert s.lifecycle == "logical"
    assert s.ttl_ns == 0


def test_the_fault_schemas_are_internal_and_the_programs_are_not():
    # [NDBG.2.2]: the built-ins enumerate, and an integrator tells them apart
    # by lifecycle, never by name.
    schemas = _loaded_engine().schemas
    assert {name: s.lifecycle for name, s in schemas.items()} == {
        "Trig": pyds.Lifecycle.LOGICAL,
        "ComputationError": pyds.Lifecycle.INTERNAL,
        "TypeError": pyds.Lifecycle.INTERNAL,
        # [LTIM.10.6]: `scope logical ambient`, which the integrator fills.
        "TimeZoneOffset": pyds.Lifecycle.LOGICAL,
    }


def test_a_schemas_slots_are_slot_dataclasses_in_declaration_order():
    (v,) = _loaded_engine().schemas["Trig"].slots
    assert v == pyds.Slot(
        name="v",
        type=pyds.SlotType.INT,
        schema_ref=None,
        nullable=False,
        identity=v.identity,
        sampled=False,
        retained=False,
        hydration_eligible=False,
        tolerance=None,
        docstring=None,
    )
    assert v.identity in (pyds.IdentityRole.KEY, pyds.IdentityRole.MUTABLE)


def test_schema_source_and_proto_source():
    s = _loaded_engine().schemas["Trig"]
    assert s.source == pyds.Source(file="mvp.ds", line=4, column=s.source.column)
    assert s.proto_source is not None
    assert "message Trig" in s.proto_source


def test_a_built_in_schema_has_no_source():
    # The artefact declares no position for a built-in ([LERR.9.4]).
    assert _loaded_engine().schemas["ComputationError"].source is None


def test_a_schema_is_a_frozen_value():
    s = _loaded_engine().schemas["Trig"]
    assert s == _loaded_engine().schemas["Trig"]
    assert hash(s) == hash(_loaded_engine().schemas["Trig"])
    with pytest.raises(dataclasses.FrozenInstanceError):
        s.name = "Other"
    assert repr(s).startswith("Schema(name='Trig', lifecycle=<Lifecycle.LOGICAL")


def test_rules_is_a_mapping_of_rule_dataclasses():
    rules = _loaded_engine().rules
    assert isinstance(rules, Mapping)
    assert list(rules) == ["trig_logger"]
    rule = rules["trig_logger"]
    assert isinstance(rule, pyds.Rule)
    assert (rule.name, rule.cooldown_ns) == ("trig_logger", None)
    # The compiler gives this rule a name template for its firings.
    assert isinstance(rule.debug_name_template, str)
    with pytest.raises(KeyError):
        rules["nope"]


def test_rule_source():
    rule = _loaded_engine().rules["trig_logger"]
    assert rule.source is not None
    assert (rule.source.file, rule.source.line) == ("mvp.ds", 7)


def test_a_rule_has_no_debounce_and_no_refraction_key():
    # The language has no debounce, and no compiler emits a refraction key,
    # so neither is part of a Rule.
    fields = {f.name for f in dataclasses.fields(pyds.Rule)}
    assert fields == {"name", "cooldown_ns", "source", "debug_name_template"}


def test_a_closed_engine_refuses_the_views():
    eng = _loaded_engine()
    schemas, rules = eng.schemas, eng.rules
    eng.close()
    with pytest.raises(ValueError, match="closed Engine"):
        len(schemas)
    with pytest.raises(ValueError, match="closed Engine"):
        rules["trig_logger"]


def test_the_values_are_named_where_they_are_imported_from():
    for cls in (pyds.Schema, pyds.Slot, pyds.Rule, pyds.Source, pyds.Schemas, pyds.Rules):
        assert cls.__module__ == "pyds", cls

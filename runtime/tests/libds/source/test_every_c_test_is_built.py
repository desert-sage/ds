# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Every `test_*.c` in the libds suites has a row in `libds.build`.

The impl and spec suites are built from `libds.build`'s `ImplTest` and
`SpecTest` tables, one row per binary ([ITST.6.2]). A `test_*.c` with no row
is neither compiled nor run, and nothing else says so.

A file that is not a pass/fail test is named in `NOT_TESTS` with its reason.
A name there that gains a row, or whose file goes, fails too.

The tables are read from the build file's text, as `build-unit` reads them: a
`table <Name>` line, then indented lines up to the first blank or unindented
one; `#` comments and the docstring are skipped, the first other line is the
column header, and each row's first word is its `name`.
"""
from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
BUILD = REPO / "libds.build"
SUITES = {
    "ImplTest": REPO / "runtime/tests/libds/impl",
    "SpecTest": REPO / "runtime/tests/libds/spec",
}

# Empty. An entry must name a file with no row, or
# `test_every_not_test_is_a_file_with_no_row` fails.
NOT_TESTS: dict[str, str] = {}


def table_names(text: str, table: str) -> list[str]:
    """The `name` of each row of `table` in a build file's text; [] when the
    file has no such table."""
    lines = text.splitlines()
    try:
        start = lines.index(f"table {table}")
    except ValueError:
        return []
    names: list[str] = []
    header = False
    for line in lines[start + 1:]:
        if not line.strip() or not line[0].isspace():
            break
        body = line.strip()
        if body.startswith("#") or body.startswith('"""'):
            continue
        if not header:
            header = True
            continue
        names.append(body.split()[0])
    return names


def _sources(suite: Path) -> set[str]:
    return {p.stem for p in suite.glob("test_*.c")}


def _rows(table: str) -> set[str]:
    return set(table_names(BUILD.read_text(encoding="utf-8"), table))


def test_every_test_source_has_a_row() -> None:
    for table, suite in SUITES.items():
        missing = _sources(suite) - _rows(table) - NOT_TESTS.keys()
        assert not missing, (
            f"{sorted(missing)} in {suite.relative_to(REPO)} have no row in "
            f"libds.build's `{table}` table, so no lane builds or runs "
            f"them. Add the row ([ITST.6.2]), or name the file in NOT_TESTS "
            f"with its reason.")


def test_every_row_names_a_source() -> None:
    for table, suite in SUITES.items():
        orphan = _rows(table) - _sources(suite)
        assert not orphan, (
            f"`{table}` rows {sorted(orphan)} name no file in "
            f"{suite.relative_to(REPO)}")


def test_every_not_test_is_a_file_with_no_row() -> None:
    rows = set().union(*(_rows(t) for t in SUITES))
    files = set().union(*(_sources(s) for s in SUITES.values()))
    stale = {n for n in NOT_TESTS if n in rows or n not in files}
    assert not stale, (
        f"NOT_TESTS names {sorted(stale)}, which has a row or no file; "
        f"remove it from the list")


def test_the_tables_are_read() -> None:
    # Fails on: a reworded build file the reader no longer matches, which would
    # otherwise read as "every source has a row" over two empty sets.
    impl, spec = _rows("ImplTest"), _rows("SpecTest")
    assert {"test_action_events", "test_wm_basic"} <= impl
    assert {"test_log_spec", "test_ttl_spec"} <= spec
    assert "wrap" not in impl and "name" not in spec


def test_the_reader_takes_rows_and_skips_comments() -> None:
    text = ("table T\n"
            "  \"\"\"what T is\"\"\"\n"
            "  name   wrap\n"
            "  # a comment\n"
            "  test_a \"\"\n"
            "  test_b \"-x\"\n"
            "\n"
            "  test_c \"\"\n"
            "each T t\n")
    assert table_names(text, "T") == ["test_a", "test_b"]


def test_the_reader_answers_nothing_for_an_absent_table() -> None:
    assert table_names("table U\n  name\n  test_a\n", "T") == []

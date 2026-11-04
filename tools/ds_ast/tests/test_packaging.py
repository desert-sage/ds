# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`ds_ast` as a package: what pyproject.toml declares holds of the code.

It declares no dependencies, so every module `ds_ast` imports must be the
standard library's or its own; and the one package it builds must be the
directory the code is in, holding every module of it.
"""
import ast
import pathlib
import sys
import tomllib

HERE = pathlib.Path(__file__).resolve().parents[1]
PKG = HERE / "ds_ast"


def project() -> dict:
    with open(HERE / "pyproject.toml", "rb") as f:
        return tomllib.load(f)


def test_the_wheel_is_the_package_directory():
    got = project()
    # The distribution takes the `ds-lang-` prefix on PyPI; the import name is
    # `ds_ast` (#5776).
    assert got["project"]["name"] == "ds-lang-ast"
    assert got["tool"]["hatch"]["build"]["targets"]["wheel"]["packages"] == ["ds_ast"]
    assert (PKG / "__init__.py").is_file()


def test_no_dependencies_and_none_needed():
    """Every import is relative, or of a standard-library module."""
    assert project()["project"]["dependencies"] == []
    outside = set()
    for path in sorted(PKG.glob("*.py")):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"), str(path))):
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module]
            else:
                continue
            for name in names:
                top = name.split(".")[0]
                if top != "__future__" and top not in sys.stdlib_module_names:
                    outside.add(f"{path.name}: {name}")
    assert not outside, f"ds_ast imports what pyproject.toml does not declare: {sorted(outside)}"

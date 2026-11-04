# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Every third-party module pyds imports at module level is declared.

A module that imports an undeclared package cannot be imported from a clean
install, and CI cannot see it, because the test image installs the package for
its own reasons. This reads the shipped sources and pyproject.toml rather than
the environment, so what the image happens to carry does not matter.

An import inside a function is an optional feature's and is exempt: it fails
only when the feature is used, with a message saying what to install.
"""

from __future__ import annotations

import ast
import re
import sys
import tomllib
from pathlib import Path

BINDING = Path(__file__).resolve().parents[1]
PACKAGE = BINDING / "src" / "pyds"

# The distribution that provides an import name, where the two differ.
# `pyds.proto` is the generated protobuf bindings, which import `google.protobuf`.
DISTRIBUTION = {"google": "protobuf", "pyds.proto": "protobuf"}


def _module_level_imports(tree: ast.Module) -> list[tuple[str, int]]:
    found: list[tuple[str, int]] = []

    def walk(body: list[ast.stmt]) -> None:
        for node in body:
            if isinstance(node, ast.Import):
                found.extend((a.name, node.lineno) for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.level == 0 and node.module:
                    found.append((node.module, node.lineno))
                elif node.level == 1 and node.module and node.module.startswith("proto"):
                    found.append(("pyds.proto", node.lineno))
            elif isinstance(node, (ast.If, ast.Try)):
                walk(node.body)
                walk(getattr(node, "orelse", []))
                for h in getattr(node, "handlers", []):
                    walk(h.body)
                walk(getattr(node, "finalbody", []))

    walk(tree.body)
    return found


def _required_distribution(name: str) -> str | None:
    if name == "pyds.proto" or name.startswith("pyds.proto."):
        return DISTRIBUTION["pyds.proto"]
    top = name.split(".")[0]
    if top in sys.stdlib_module_names or top in ("pyds", "__future__"):
        return None
    return DISTRIBUTION.get(top, top)


def _declared() -> set[str]:
    project = tomllib.loads((BINDING / "pyproject.toml").read_text(encoding="utf-8"))
    deps = project["project"].get("dependencies", [])
    return {re.split(r"[\s<>=!~;\[]", d, maxsplit=1)[0].lower() for d in deps}


def test_every_module_level_import_is_declared():
    declared = _declared()
    missing = []
    sources = sorted(PACKAGE.rglob("*.py"))
    assert sources, f"no package sources under {PACKAGE}"
    for path in sources:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for name, line in _module_level_imports(tree):
            dist = _required_distribution(name)
            if dist is not None and dist.lower() not in declared:
                missing.append(
                    f"{path.relative_to(BINDING)}:{line} imports {name}, which needs {dist}"
                )
    assert not missing, "undeclared:\n" + "\n".join(missing)


def test_the_scan_sees_a_module_level_import():
    # The check above must be able to fire: a module-level import of a package
    # nobody declares is reported, and the same import in a function is not.
    tree = ast.parse("import numpy\nfrom .proto import x_pb2\ndef f():\n    import cryptography\n")
    names = [n for n, _ in _module_level_imports(tree)]
    assert names == ["numpy", "pyds.proto"]
    assert _required_distribution("numpy") == "numpy"
    assert _required_distribution("pyds.proto") == "protobuf"
    assert _required_distribution("json") is None

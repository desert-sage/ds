# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`pyds.proto` carries every `proto/*.proto`, as a package.

Two claims, each of which the meson target can break without any other test
noticing:

- COMPLETE: every proto in the directory has an importable `<stem>_pb2`. The
  output list is derived from the directory at configure time, so this fails if
  that derivation is replaced by a hand list that drifts.
- RELATIVE: importing a module with sibling imports works without the package
  directory on `sys.path`. `schema_def` imports `common`, and `atom` imports
  most of the stream family; a bare `import common_pb2` left in either would
  resolve only where some other copy happened to be loaded first — which, in a
  process that also imports `ds_compiler`, it usually is. So the check asserts
  the sibling came from `pyds.proto`, not merely that the import succeeded.
"""

from __future__ import annotations

import importlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PROTO_STEMS = sorted(p.stem for p in (REPO_ROOT / "proto").glob("*.proto"))


def test_the_proto_directory_is_not_empty():
    # A glob that matches nothing makes the next test pass over nothing.
    assert len(PROTO_STEMS) > 10, PROTO_STEMS


def test_every_proto_has_a_module():
    missing = []
    for stem in PROTO_STEMS:
        try:
            importlib.import_module(f"pyds.proto.{stem}_pb2")
        except ImportError as e:
            missing.append(f"{stem}: {e}")
    assert not missing, missing


def test_sibling_imports_resolve_inside_the_package():
    from pyds.proto import atom_pb2, schema_def_pb2

    assert schema_def_pb2.common__pb2.__name__ == "pyds.proto.common_pb2"
    siblings = [
        v for k, v in vars(atom_pb2).items() if k.endswith("__pb2") and hasattr(v, "__name__")
    ]
    assert siblings, "atom_pb2 imports no sibling -- the check reads nothing"
    wrong = [m.__name__ for m in siblings if not m.__name__.startswith("pyds.proto.")]
    assert not wrong, wrong

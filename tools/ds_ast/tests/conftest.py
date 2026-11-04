# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Put `ds_ast` and its generator on the path.

`ds_ast` is imported from the tree rather than from an installed wheel, so the
tests measure this commit. The generator, `gendsast.py`, sits beside the schema
in `tools/ds_ast/`, and the staleness test imports it rather than shelling
out, so a generator that cannot even be imported is a red here too.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
path = ROOT / "tools" / "ds_ast"
if str(path) not in sys.path:
    sys.path.insert(0, str(path))

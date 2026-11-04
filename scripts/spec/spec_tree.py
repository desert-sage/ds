# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Which files under `specs/` are the clause tree.

`specs/` holds more than clauses. `specs/registry/` holds the EBNF
registries ([STYL.5.2.7]), and `specs/conformance/` holds the conformance
corpus and its harness ([STYL.5.2.8]), in which nothing is a clause. A
reader that walks `specs/**/*.json`, or `specs/*/*/*.json`, takes a vector
for a clause, and a vector and a clause can share a file stem
(`specs/conformance/runtime/LDET.2.2b.json` beside
`specs/language/DETERMINISM/LDET.2.2b.json`). Nothing fails when that
happens: a clause index keyed by stem simply answers with the vector, which
has no `status`. So every reader of the clause tree asks this module for its
files rather than globbing for them.

The clause tree is the four normative trees, named rather than inferred
from what is under `specs/`. A directory added beside them is read by
nothing until it is named here.

Stdlib only, so a reader that runs before the spec tooling's dependencies
are installed can import it.
"""

from __future__ import annotations

from pathlib import Path

# The normative trees, in the order the tooling has always walked them.
TREES: tuple[str, ...] = ("language", "runtime", "impl", "integration")

MANIFEST = "_file.json"


def doc_dirs(specs: str | Path) -> list[Path]:
    """`specs/<tree>/<DOC>/`, for every document of the four trees."""
    root = Path(specs)
    return sorted(d for tree in TREES if (root / tree).is_dir()
                  for d in (root / tree).iterdir() if d.is_dir())


def clause_json(specs: str | Path) -> list[Path]:
    """Every JSON file of the clause tree: the clauses and the documents'
    `_file.json` manifests."""
    return sorted(p for d in doc_dirs(specs) for p in d.glob("*.json"))


def clause_files(specs: str | Path) -> list[Path]:
    """Every clause file, `specs/<tree>/<DOC>/<ID>.json`. Its stem is its id
    ([STYL.5.2.4])."""
    return [p for p in clause_json(specs) if p.name != MANIFEST]


def is_clause_path(rel: str) -> bool:
    """Whether a repo-relative path names a clause file: exactly
    `specs/<tree>/<DOC>/<ID>.json` with `<tree>` one of the four."""
    parts = Path(rel).parts
    return (len(parts) == 4 and parts[0] == "specs" and parts[1] in TREES
            and parts[3].endswith(".json") and parts[3] != MANIFEST)

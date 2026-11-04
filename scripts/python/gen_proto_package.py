#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Generate `pyds.proto`, a module and its stub per `proto/*.proto`, as a package.

    gen_proto_package.py --list PROTO_DIR
        print the stems, one per line (meson reads this for the output list)
    gen_proto_package.py PROTOC PROTO_DIR OUT_DIR PROTO...
        run protoc over every PROTO into OUT_DIR, then make the result a package

The stubs are protoc's own (`--pyi_out`), so `mypy --strict` sees each message's
fields rather than an untyped module (PY.12). They type against
`types-protobuf`, which the `ds-test` image pins beside mypy.

protoc renders a proto import as a BARE module import — `import common_pb2 as
common__pb2` in a module, `import common_pb2 as _common_pb2` in a stub — which
resolves only if the output directory itself is on `sys.path`. That is how
`ds_compiler.dsc.proto_gen` worked, by inserting its own directory into
`sys.path` on import, and why pyds's descriptors used to be seeded into
`sys.modules` by hand. A package has no directory to add: pyds is installed as
a wheel in one layout and as a meson editable install, with the generated files
in the build directory, in the other.

So each bare import of a module this run generated becomes a relative one,
`from . import common_pb2 as common__pb2`, and `from common_pb2 import X`
becomes `from .common_pb2 import X`. Nothing else is touched —
`google.protobuf` imports are already absolute — and a bare import of a `_pb2`
module that survives the rewrite is an error rather than a module that fails on
first use.

The set of protos is the directory, not a list: a proto added to `proto/` is
generated here with no edit, because the meson output list comes from `--list`.
"""

import re
import subprocess
import sys
from pathlib import Path

_BARE = re.compile(r"^import (\w+_pb2)( as \w+)?$", re.MULTILINE)
_BARE_FROM = re.compile(r"^from (\w+_pb2) import ", re.MULTILINE)


def stems(proto_dir: Path) -> list[str]:
    """Return the stem of every ``.proto`` in ``proto_dir``, sorted."""
    return sorted(p.stem for p in proto_dir.glob("*.proto"))


def relativise(path: Path, generated: set[str]) -> None:
    """Rewrite ``path``'s bare imports of a ``generated`` module as relative ones.

    Exits if a bare ``_pb2`` import of a module outside ``generated`` is left.
    """
    text = path.read_text(encoding="utf-8")

    def sub(m: re.Match[str]) -> str:
        if m.group(1) not in generated:
            return m.group(0)
        return f"from . import {m.group(1)}{m.group(2) or ''}"

    def sub_from(m: re.Match[str]) -> str:
        if m.group(1) not in generated:
            return m.group(0)
        return f"from .{m.group(1)} import "

    text = _BARE_FROM.sub(sub_from, _BARE.sub(sub, text))
    left = [m.group(1) for m in (*_BARE.finditer(text), *_BARE_FROM.finditer(text))]
    if left:
        raise SystemExit(
            f"gen_proto_package: {path.name} still imports "
            f"{left} by bare name, and they are not in this run"
        )
    path.write_text(text, encoding="utf-8")


def main(argv: list[str]) -> int:
    """Run the command line the module docstring gives; return the exit status."""
    if len(argv) == 3 and argv[1] == "--list":
        print("\n".join(stems(Path(argv[2]))))
        return 0
    if len(argv) < 5:
        print(__doc__, file=sys.stderr)
        return 2
    protoc, proto_dir, out_dir = argv[1], Path(argv[2]), Path(argv[3])
    protos = argv[4:]
    subprocess.run(
        [
            protoc,
            f"--proto_path={proto_dir}",
            f"--python_out={out_dir}",
            f"--pyi_out={out_dir}",
            *protos,
        ],
        check=True,
    )
    generated = {f"{Path(p).stem}_pb2" for p in protos}
    for name in sorted(generated):
        relativise(out_dir / f"{name}.py", generated)
        relativise(out_dir / f"{name}.pyi", generated)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

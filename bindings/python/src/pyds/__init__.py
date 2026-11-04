# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Python binding for libds."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Iterable
from importlib.metadata import version as _distribution_version
from pathlib import Path

# The events are reached as pyds.events.<Kind>, never from here: one of them
# is pyds.events.TypeError, which must not shadow the builtin.
from pyds import events
from pyds._atom_registry import AtomKind
from pyds._capability import Capability
from pyds._faults import CapName, EngineFault, TrapKind
from pyds._pyds import EncodedFact, JsonText
from pyds._pyds import build_capabilities as _build_capabilities
from pyds._status import Status
from pyds.engine import (
    Cache,
    Clock,
    Debug,
    Engine,
    Facts,
    Justifier,
    LineSpan,
    LineSpans,
    MemoryUsage,
    PlatformSignature,
    ProgramSource,
    Recording,
    RefractedActivation,
    ReplayResult,
    ReteEdge,
    ReteNetwork,
    ReteNode,
    Rule,
    Rules,
    Schema,
    Schemas,
    Slot,
    Source,
    Sources,
    TraceStep,
)
from pyds.enums import (
    Admission,
    CacheRemovalReason,
    ClockMode,
    EventKind,
    IdentityRole,
    Lifecycle,
    LogLevel,
    MatchResult,
    MetricKind,
    NodeKind,
    SlotType,
)
from pyds.errors import (
    ArtefactMismatchError,
    BackendError,
    CompileRefusedError,
    ContractError,
    Error,
    ExecutionError,
    InputError,
    LoadError,
    ReteError,
    StorageError,
    TraceError,
)
from pyds.facts import Fact, FactId
from pyds.session import SessionHeader

__all__ = [
    "BUILD_CAPABILITIES",
    "Admission",
    "ArtefactMismatchError",
    "AtomKind",
    "BackendError",
    "Cache",
    "CacheRemovalReason",
    "CapName",
    "Capability",
    "Clock",
    "ClockMode",
    "CompileRefusedError",
    "ContractError",
    "Debug",
    "EncodedFact",
    "Engine",
    "EngineFault",
    "Error",
    "EventKind",
    "ExecutionError",
    "Fact",
    "FactId",
    "Facts",
    "IdentityRole",
    "InputError",
    "JsonText",
    "Justifier",
    "Lifecycle",
    "LineSpan",
    "LineSpans",
    "LoadError",
    "LogLevel",
    "MatchResult",
    "MemoryUsage",
    "MetricKind",
    "NodeKind",
    "PlatformSignature",
    "ProgramSource",
    "Recording",
    "RefractedActivation",
    "ReplayResult",
    "ReteEdge",
    "ReteError",
    "ReteNetwork",
    "ReteNode",
    "Rule",
    "Rules",
    "Schema",
    "Schemas",
    "SessionHeader",
    "Slot",
    "SlotType",
    "Source",
    "Sources",
    "Status",
    "StorageError",
    "TraceError",
    "TraceStep",
    "TrapKind",
    "compile",
    "compile_file",
    "events",
    "from_source",
]


# The installed distribution's version, which the build decided. The
# distribution is `ds-lang` and the package it installs is this one.
__version__ = _distribution_version("ds-lang")

# The capabilities this build of libds has code for ([NLFC.10.1]). Loading an
# artefact that requires one outside it raises LoadError, with status
# Status.DSC_CAPABILITY_ABSENT. Fixed when libds is built, so read once.
BUILD_CAPABILITIES: frozenset[Capability] = frozenset(map(Capability, _build_capabilities()))


_LIBDS_VERSION: str | None = None


def _libds_version() -> str:
    """Return the DS version the LINKED libds carries ([LDET.1.10]).

    `Engine.platform_signature` reports DS_LIBDS_VERSION — the same string the loader
    compares against and the recorder stamps into a stream.

    Cached: it is a build constant, and the Engine exists only to ask.
    """
    global _LIBDS_VERSION
    if _LIBDS_VERSION is None:
        _LIBDS_VERSION = Engine().platform_signature.libds_version
    return _LIBDS_VERSION


type _Paths = Iterable[str | os.PathLike[str]]


def from_source(source_text: str, *, file: str = "<input>", dialect_files: _Paths = ()) -> Engine:
    """Compile DS source and return an engine with it loaded.

    ``file`` and ``dialect_files`` are passed to ``compile()``.
    """
    eng = Engine()
    eng.load_dsc(compile(source_text, file=file, dialect_files=dialect_files))
    return eng


def compile_file(
    path: str | os.PathLike[str], *, search_path: _Paths | None = None, dialect_files: _Paths = ()
) -> bytes:
    """Compile a ``.ds`` file to ``.dsc`` bytes.

    ``dsc`` reads the file itself, and with it the file's companion
    ``.dstest`` beside it ([LTSL.2.4]), which source handed over as text has
    no place to be beside. Diagnostics and the artefact name the file as
    given ([RDSC.14.2.3]). ``search_path`` is where imports resolve; by
    default the file's own directory, so a library beside it is found. Pass
    ``()`` to search nowhere. ``dialect_files`` is as for ``compile()``.

    Raises what ``compile()`` raises, and ``OSError`` when the file cannot
    be opened.
    """
    p = Path(path)
    # Opened first, so a missing file is the OSError it always was rather
    # than a refusal from dsc.
    with p.open("rb"):
        pass
    file = str(p)
    # dsc reads an argument that starts with `-` as an option, and has no
    # `--` to end them, so such a relative path goes as `./<path>`.
    if file.startswith("-"):
        file = os.path.join(os.curdir, file)
    return _run_dsc(
        ["compile", file, "-o", "-"],
        b"",
        file,
        search_path=(p.parent,) if search_path is None else search_path,
        dialect_files=dialect_files,
    )


# The compiler a wheel carries. Absent
# in a source checkout and in an unvendored build.
_BUNDLED_DSC = Path(__file__).resolve().parent / "bin" / "dsc"


def _dsc() -> str:
    """Which `dsc` `compile()` runs: `DS_MERCURY_DSC`, the bundled one, `PATH`.

    BUNDLED BEFORE `PATH`. The bundled `dsc` was built with the libds this
    package links and stamps the same version, and libds loads an artefact only
    if its compiler shares that `<major>.<minor>.` ([LDET.1.10]). A `dsc` that
    happens to be first on `PATH` may be another release's, whose every artefact
    this package's own loader refuses. An explicit `DS_MERCURY_DSC` still wins:
    it is a choice someone made, and the tree's gates make it.
    """
    explicit = os.environ.get("DS_MERCURY_DSC")
    if explicit:
        return explicit
    if _BUNDLED_DSC.is_file():
        return str(_BUNDLED_DSC)
    return "dsc"


def compile(
    source_text: str,
    *,
    file: str = "<input>",
    search_path: _Paths | None = None,
    dialect_files: _Paths = (),
) -> bytes:
    """Compile DS source text to ``.dsc`` bytes, for ``Engine.load_dsc``.

    The compiler is the ``dsc`` binary: ``DS_MERCURY_DSC`` if set, else the
    one an installed wheel carries, else ``dsc`` on ``PATH``. The source goes
    to it on standard input and the artefact comes back on standard output,
    so an ordinary compile writes nothing to disk.

    ``file`` is the name diagnostics and the artefact give the source,
    recorded as given. ``search_path`` is the directories imports resolve
    in; source handed over as text has no directory of its own, so nothing
    resolves beside it unless ``search_path`` says so. ``dialect_files``
    names dialect definitions (YAML) to register before compiling, in the
    order given: a program names its dialect in its ``use`` line, and these
    make a dialect the language does not define available to it.

    Raises ``CompileRefusedError`` when ``dsc`` refuses the source,
    ``RuntimeError`` when there is no ``dsc`` or it fails otherwise,
    ``OSError`` when one is there and cannot be started, and ``TypeError``
    for one path where a sequence of paths belongs.
    """
    return _run_dsc(
        ["compile", "-", "-o", "-", "--filename", file],
        source_text.encode(),
        file,
        search_path=search_path,
        dialect_files=dialect_files,
    )


def _run_dsc(
    args: list[str],
    stdin: bytes,
    file: str,
    *,
    search_path: _Paths | None,
    dialect_files: _Paths,
) -> bytes:
    """Run ``dsc args -d … -L …`` with ``stdin``, and return the artefact.

    ``file`` is the source's name in the errors ``compile()`` documents.
    """
    # One path is not a sequence of them: iterating a str would pass each
    # character as a path.
    for name, paths in (("search_path", search_path), ("dialect_files", dialect_files)):
        if isinstance(paths, (str, bytes, os.PathLike)):
            raise TypeError(f"{name} takes a sequence of paths, not one path")

    dsc = _dsc()
    argv = [dsc, *args]
    for d in dialect_files:
        argv += ["-d", str(Path(d).resolve())]
    for p in search_path or ():
        argv += ["-L", str(Path(p).resolve())]
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True)
    except FileNotFoundError as e:
        raise RuntimeError(
            f"no dsc binary: {dsc!r} is not there, and this pyds carries "
            f"none -- set DS_MERCURY_DSC or put dsc on PATH"
        ) from e
    stderr = proc.stderr.decode(errors="replace").strip()
    if proc.returncode == 1:
        raise CompileRefusedError(file, stderr)
    if proc.returncode != 0:
        raise RuntimeError(f"dsc exited {proc.returncode} on {file}:\n{stderr}")
    return proc.stdout

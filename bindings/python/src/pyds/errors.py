# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The exceptions pyds raises.

A failed libds call raises `Error`, or the subclass for the range its status
falls in. The ranges are [NERR.3.1]'s, because that table also states what a
caller does about a failure in each, and that is what an `except` clause
chooses between:

==========================  ============  ===================================
Class                       Statuses      What it means
==========================  ============  ===================================
`Error` itself              ``-1..-99``   a generic failure: an argument or
                                          the engine's state (``Status.STATE``)
`InputError`                ``-100..``    the input does not fit: a fact, a
                                          text or an encoded body
`ExecutionError`            ``-200..``    a fact or an activation
`StorageError`              ``-400..``    the integrator's storage or
                                          callbacks
`LoadError`                 ``-500..``    the artefact: rebuild the `.dsc`
`ReteError`                 ``-600..``    the rule network, or real-time
                                          configuration
`BackendError`              ``-620..``    a series backend
`ArtefactMismatchError`     ``-700..``    artefacts built from different
                                          sources
`ContractError`             ``-710..``    the real-time contract
`TraceError`                ``-720..``    a fact stream: its header, or a
                                          replay
==========================  ============  ===================================

`status` is a `Status` when the number is in the dictionary, else the plain
`int` (an integrator-defined status is ``-10000`` or below).
`CompileRefusedError` is the compiler refusing source, and has no status.

Misuse at the Python level raises the builtin exception for it -- `TypeError`
for an argument of the wrong type, `ValueError` for an operation on a closed
`Engine`, as `io` does for a closed file -- and never carries a status.
"""

from __future__ import annotations

from pyds._status import Status

__all__ = [
    "ArtefactMismatchError",
    "BackendError",
    "CompileRefusedError",
    "ContractError",
    "Error",
    "ExecutionError",
    "InputError",
    "LoadError",
    "ReteError",
    "StorageError",
    "TraceError",
]


class Error(Exception):
    """A libds call failed.

    `status` is the `ds_status_t` -- a `Status`, or an `int` outside the
    dictionary -- and `detail` is libds's account of the failure.
    """

    status: Status | int | None
    detail: str

    def __init__(self, status: Status | int | None, detail: str) -> None:
        """Hold the failed call's ``status`` and libds's ``detail``."""
        super().__init__(status, detail)
        self.status = status
        self.detail = detail

    def __str__(self) -> str:
        """Render the status, by number and name where it has one, then the detail."""
        if self.status is None:
            return self.detail
        if isinstance(self.status, Status):
            return f"[{int(self.status)} {self.status.name}] {self.detail}"
        return f"[{self.status}] {self.detail}"


class InputError(Error):
    """Input, ``-100..-199``: fix the fact, text or encoded body that does not fit."""


class ExecutionError(Error):
    """Runtime, ``-200..-299``: a fact or an activation's state."""


class StorageError(Error):
    """Storage and integrator callbacks, ``-400..-499``."""


class LoadError(Error):
    """Artefact load, ``-500..-599``: rebuild the `.dsc`; check its version."""


class ReteError(Error):
    """Native Rete and real-time, ``-600..-610``."""


class BackendError(Error):
    """Series-backend ABI, ``-620..-625``."""


class ArtefactMismatchError(Error):
    """Dialect and artefact binding, ``-700..-704``: rebuild from one source."""


class ContractError(Error):
    """The real-time contract, ``-710..-714``."""


class TraceError(Error):
    """Fact stream, ``-720..-730``: its header, or a replay."""


class CompileRefusedError(Error):
    """The compiler refused the source.

    `diagnostics` is the compiler's rendered output, which names every
    ``DS_*`` code; `status` is None, because no libds call failed.
    """

    def __init__(self, file: str, diagnostics: str) -> None:
        """Hold the refused ``file`` and the compiler's rendered ``diagnostics``."""
        super().__init__(None, f"{file}: refused by dsc\n{diagnostics}")
        self.file = file
        self.diagnostics = diagnostics

    def __reduce__(self) -> tuple[type[CompileRefusedError], tuple[str, str]]:
        """Pickle by the two arguments, which ``__init__`` takes in place of ``Error``'s."""
        return (type(self), (self.file, self.diagnostics))


# [NERR.3.1]: (lowest, highest, class), each range inclusive. The fact-stream
# family runs to -730, as [NERR.3.1] and [NERR.13] state.
_FAMILIES: tuple[tuple[int, int, type[Error]], ...] = (
    (-199, -100, InputError),
    (-299, -200, ExecutionError),
    (-499, -400, StorageError),
    (-599, -500, LoadError),
    (-610, -600, ReteError),
    (-625, -620, BackendError),
    (-704, -700, ArtefactMismatchError),
    (-714, -710, ContractError),
    (-730, -720, TraceError),
)


def _error_for(status: int, detail: str) -> Error:
    """Return the exception for a failed libds call.

    The extension raises what this returns, so a status reaches Python one way.
    """
    try:
        code: Status | int = Status(status)
    except ValueError:
        code = status
    for lowest, highest, cls in _FAMILIES:
        if lowest <= status <= highest:
            return cls(code, detail)
    return Error(code, detail)

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Errors

## `Error`

**`def __init__(self, status: Status | int | None, detail: str) -> None`**

A failed libds call: the base of every exception on this page.

A failed call raises the subclass whose entry names its status's [NERR.3.1](inv:specs:std:label#nerr-3-1) range, and `Error` itself for any other status.

`status` is a `Status`, or an `int` for a number the dictionary does not hold. `detail` is libds's [detail string](inv:integrator:std:doc#conventions/results). `str()` gives `[<number> <name>] <detail>`, without the name for an `int`. A [callback's exception](callbacks.md#a-callbacks-exception) is the `__cause__`.

A builtin exception a page names for misuse carries no status.

```python statement
try:
    engine.pump()
except pyds.StorageError as e:
    print(e.status, e.detail)
```

*(Source: bindings/python/src/pyds/errors.py, bindings/python/src/_pyds/errors.c)*

## `InputError`

**`class InputError(Error)`**

Raised for a status in `-100..-199`.

*(Source: bindings/python/src/pyds/errors.py)*

## `ExecutionError`

**`class ExecutionError(Error)`**

Raised for a status in `-200..-299`.

*(Source: bindings/python/src/pyds/errors.py)*

## `StorageError`

**`class StorageError(Error)`**

Raised for a status in `-400..-499`.

*(Source: bindings/python/src/pyds/errors.py)*

## `LoadError`

**`class LoadError(Error)`**

Raised for a status in `-500..-599`.

*(Source: bindings/python/src/pyds/errors.py)*

## `ReteError`

**`class ReteError(Error)`**

Raised for a status in `-600..-610`.

*(Source: bindings/python/src/pyds/errors.py)*

## `BackendError`

**`class BackendError(Error)`**

Raised for a status in `-620..-625`.

*(Source: bindings/python/src/pyds/errors.py)*

## `ArtefactMismatchError`

**`class ArtefactMismatchError(Error)`**

Raised for a status in `-700..-704`.

*(Source: bindings/python/src/pyds/errors.py)*

## `ContractError`

**`class ContractError(Error)`**

Raised for a status in `-710..-714`.

*(Source: bindings/python/src/pyds/errors.py)*

## `TraceError`

**`class TraceError(Error)`**

Raised for a status in `-720..-730`.

*(Source: bindings/python/src/pyds/errors.py)*

## `CompileRefusedError`

**`def __init__(self, file: str, diagnostics: str) -> None`**

The compiler refused the source: raised by [`compile`](compile.md#compile-1) and [`compile_file`](compile.md#compile_file).

`file` is the name of the refused source, and `diagnostics` the compiler's rendered output, which names every `DS_*` code. `status` is `None`, and `detail` holds `file` and `diagnostics`. `str()` gives `detail`.

*(Source: bindings/python/src/pyds/errors.py)*

## `Status`

**`class Status(enum.IntEnum)`**

A `ds_status_t`, generated from `proto/status.proto`.

A member's value is the status's number. Its name is the code's in the [error catalogue](inv:integrator:std:doc#conventions/errors), with the `DS_ERR_` prefix removed: `DS_ERR_ENGINE_HALTED` is `Status.ENGINE_HALTED`. `DS_OK` is `Status.OK`.

*(Source: bindings/python/src/pyds/_status.py)*

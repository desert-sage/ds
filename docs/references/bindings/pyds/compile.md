<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Compile

## Compiling

### `compile`

**`def compile(source_text: str, *, file: str = "<input>", search_path: _Paths | None = None, dialect_files: _Paths = ()) -> bytes`**

Compiles DS source text to `.dsc` bytes, for [`load_dsc`](engine.md#load_dsc).

`_Paths` is an `Iterable` of `str` or `os.PathLike[str]`.

| Argument | Holds |
|---|---|
| `file` | the name diagnostics and the artefact give the source |
| `search_path` | the directories imports resolve in; by default none |
| `dialect_files` | dialect definitions registered before compiling, in the order given |

| Raises | Condition |
|---|---|
| [`CompileRefusedError`](errors.md#compilerefusederror) | `dsc` refuses the source: it exits with status `1` |
| `RuntimeError` | no `dsc` is found; it exits with a status other than `0` or `1` |
| `OSError` | a `dsc` is found and cannot be started |
| `TypeError` | `file` is not a `str`; one path stands where a sequence of paths belongs; `search_path` or `dialect_files` is not iterable, or holds an item that is not a path |
| `ValueError` | `file` or a path holds a NUL; `source_text` holds a lone surrogate |
| `AttributeError` | `source_text` is not a `str` |

```python statement
dsc = pyds.compile("use default\n", file="a.ds")
engine.load_dsc(dsc)
```

*(Source: bindings/python/src/pyds/__init__.py)*

### `compile_file`

**`def compile_file(path: str | os.PathLike[str], *, search_path: _Paths | None = None, dialect_files: _Paths = ()) -> bytes`**

Compiles a `.ds` file to `.dsc` bytes.

`dsc` reads the file itself. `search_path` is by default the file's own directory, and `()` searches nowhere. `dialect_files` is as for [`compile`](#compile-1).

| Raises | Condition |
|---|---|
| [`CompileRefusedError`](errors.md#compilerefusederror) | `dsc` refuses the source: it exits with status `1` |
| `RuntimeError` | no `dsc` is found; it exits with a status other than `0` or `1` |
| `OSError` | the file cannot be opened; a `dsc` is found and cannot be started |
| `TypeError` | `path` is not a path; one path stands where a sequence of paths belongs; `search_path` or `dialect_files` is not iterable, or holds an item that is not a path |
| `ValueError` | a path holds a NUL |

*(Source: bindings/python/src/pyds/__init__.py)*

### `from_source`

**`def from_source(source_text: str, *, file: str = "<input>", dialect_files: _Paths = ()) -> Engine`**

Compiles DS source text with [`compile`](#compile-1), and returns a new [`Engine`](engine.md#engine-1) with it loaded.

*(Source: bindings/python/src/pyds/__init__.py)*

## Compiler

### Which `dsc` runs

These functions run the first of:

1. the path in the environment variable `DS_MERCURY_DSC`, if set and not empty;
2. the `dsc` bundled at `pyds/bin/dsc`, if the file is there;
3. `dsc` on `PATH`.

*(Source: bindings/python/src/pyds/__init__.py)*

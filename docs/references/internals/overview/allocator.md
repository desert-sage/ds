<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Allocator

## Allocation macros

**`DS_MALLOC(sz)`, `DS_CALLOC(n,sz)`, `DS_REALLOC(p,sz)`, `DS_FREE(p)`, `DS_STRDUP(s)`, `DS_STRNDUP(s,n)`**

The six allocation macros, defined in the internal header `runtime/src/libds/ds_alloc.h`, are libds's allocation layer.

Every hand-written libds translation unit that allocates includes `ds_alloc.h` and allocates through these macros and `ds_free`. None calls libc `malloc`, `calloc`, `realloc`, `free`, `strdup` or `strndup` directly, except `ds_alloc.c`. Each macro parenthesises every argument.

*(Spec: [IALC.1.1], [IALC.2.1], [IALC.2.4], [IALC.11.1])*

## `DS_ALLOC_MODE`

**`DS_ALLOC_MODE`**

The build-time selector of how the allocation macros resolve: `DS_ALLOC_MACRO` (1) or `DS_ALLOC_WEAK` (2).

| Mode | The macros expand to |
|---|---|
| `DS_ALLOC_WEAK` | a call to the same-named weak function (`ds_malloc`, `ds_calloc`, `ds_realloc`, `ds_free`, `ds_strdup`, `ds_strndup`), declared in `ds_alloc.h` and defined in `ds_alloc.c`: one tail-callable frame on the cold path |
| `DS_ALLOC_MACRO` | the integrator's functions, inline, where a header named by `DS_ALLOC_HEADER` defines them; otherwise the libc functions of the same name. With no `DS_ALLOC_HEADER`, each macro is byte-identical to a direct libc call. |

The default is `DS_ALLOC_WEAK`. When `DS_ALLOC_MODE` is unset and `DS_ALLOC_HEADER` is defined, the mode is `DS_ALLOC_MACRO`.

*(Spec: [IALC.1.2], Source: runtime/src/libds/ds_alloc.h)*

## `ds_alloc.c`

`ds_alloc.c` holds libds's only direct libc allocation calls.

In `DS_ALLOC_WEAK` mode it defines the six `ds_*` functions with `__attribute__((weak))`, each forwarding to its libc counterpart. In `DS_ALLOC_MACRO` mode it defines the exported functions the public ABI and the protobuf-c allocator require (at least `ds_free` and `ds_malloc`) as wrappers over the macros. `__attribute__((weak))` is the GCC and Clang spelling; a `#pragma weak` equivalent is permitted.

*(Spec: [IALC.1.3], [IALC.1.4])*

## Routing scope

All hand-written allocation under `runtime/src/libds` routes through the layer.

Three sources are outside the sweep: the generated `*.pb-c.c` files, routed through the protobuf-c allocator; the vendored trees under `runtime/vendor/`, routed per vendor; and `ds_alloc.c`. Only DS-owned allocation routes through the layer: a pointer obtained from a foreign allocator is released with that allocator's `free`.

*(Spec: [IALC.2.2], [IALC.2.3])*

## protobuf-c allocator

**`ProtobufCAllocator ds_pb_allocator`**

The protobuf-c allocator that forwards to the allocation layer, declared in `runtime/src/libds/dsc/ds_pb_alloc.h`.

Every protobuf-c `…__unpack` and `…__free_unpacked` call in hand-written libds passes `&ds_pb_allocator`, never `NULL`. Its dispatch runs only on the artefact-load path.

*(Spec: [IALC.3.1], Source: runtime/src/libds/dsc/ds_pb_alloc.h)*

## Vendored libraries

Every vendored library that allocates is routed to the layer, by a compile-time hook or a header edit, before it lands.

A library that offers neither and calls libc directly is a documented coverage gap. fast_float, Dragonbox and CORE-MATH make no allocation call, and a change to one of their pins re-checks this.

*(Spec: [IALC.3.3], [IALC.3.4], [IALC.9.3])*

## Regex engine

The regex engine is not routed through the layer.

RE2, Abseil, libds's C++ seam over them and the C++ standard library they use allocate through C++'s global `operator new` and `operator delete`, which neither mode reaches. libds defines no global `operator new` or `operator delete`. A build without an RE2-class engine has no such gap.

| When | What allocates |
|---|---|
| Loading an artefact | one compiled pattern per distinct regex, freed with the engine |
| A match, during a pump | RE2's match cache, bounded by RE2's default per-pattern budget |
| A capture, during a pump | the submatch array, freed before the capture returns |

The C++ seam catches a failed allocation in every function it exports to C, so no C++ exception crosses into libds's C code, and reports it to its caller. A failure while compiling a pattern refuses the artefact load with `DS_ERR_OOM`. A failure in a match or a capture after the load, in an alpha `REGEX` test or in a builtin during a firing, is the EngineError ALLOCATION, which halts the tier. No failed allocation is read as a non-match.

*(Spec: [IALC.3.5], [IALC.3.6])*

## Weak-symbol override

In `DS_ALLOC_WEAK` mode an integrator replaces libds's allocator by linking strong definitions of the `ds_*` functions against the archive.

The linker prefers the strong symbols, and libds is not recompiled. An override supplies the whole matched set, `{malloc, calloc, realloc, free, strdup, strndup}`, from one allocator; one without native `strdup` and `strndup` implements them over its own `malloc`. The six symbols have default visibility and are not `static`. A shared-object build, such as the `pyds` extension, applies neither `-fvisibility=hidden` nor `-Bsymbolic` to them.

```{warning}
A partial override, such as `ds_malloc` without `ds_free`, frees memory with an allocator that did not allocate it.
```

*(Spec: [IALC.5])*

## Override semantics

An override, by strong definition or by `DS_ALLOC_HEADER` macros, matches libc semantics.

- `ds_free(NULL)` and `DS_FREE(NULL)` do nothing.
- `ds_realloc(NULL, n)` equals `malloc(n)`; `ds_realloc(p, 0)` follows libc.
- `ds_calloc(n, s)` zero-initialises and checks `n*s` for overflow.
- `ds_malloc(0)` returns `NULL` or a freeable pointer; libds handles either.
- `ds_strdup` and `ds_strndup` return memory `ds_free` releases. libds never calls `DS_STRDUP(NULL)`.
- Returned memory is aligned to `max_align_t`.

*(Spec: [IALC.7.1])*

## Build modes

`libds.build`, at the repository root, compiles `ds_alloc.c` into `libds.a` and passes `DS_ALLOC_MODE` and `DS_ALLOC_HEADER` to libds's own C sources through its `alloc_mode` and `alloc_header` parameters.

| Artefact | Mode |
|---|---|
| From-source build | `DS_ALLOC_WEAK`; `DS_ALLOC_MODE=1` selects libc, and `-DDS_ALLOC_HEADER` inlines an integrator allocator in macro mode |
| Released prebuilt `libds.a` | `DS_ALLOC_WEAK` |
| `pyds` extension | `DS_ALLOC_WEAK`, or the chosen mode |

*(Spec: [IALC.6])*

## Effect on results

The allocation layer changes where bytes come from, not what libds computes.

*(Spec: [IALC.8.1])*

## Lint guards

Two build-failing lints hold the layer.

| Lint | Forbids |
|---|---|
| Raw allocation | `malloc`, `calloc`, `realloc`, `free`, `strdup` and `strndup` in `runtime/src/libds`, outside `ds_alloc.c`, generated `*.pb-c.c` and `runtime/vendor/` |
| protobuf-c allocator | a `NULL` or `0` allocator argument to a protobuf-c `…__unpack` or `…__free_unpacked` in non-generated libds |

*(Spec: [IALC.9.1], [IALC.9.2])*

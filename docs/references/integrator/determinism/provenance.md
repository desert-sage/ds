<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Provenance and determinism

## Guarantee

### Determinism guarantee

The same rule set and the same event trace produce the same output, bit for bit.

A live run varies with wall-clock time and arrival interleaving. A recorded run replays bit for bit on any conforming platform, and across every release of the recording's minor series. A recording is made through the [stream callback](../callbacks/stream.md#ds_engine_set_stream_callback), and what a replaying engine is given is in [Replay settings](../engine/lifecycle.md#replay-settings). The runtime's invariants are in [Determinism](inv:internals:std:doc#guarantees/determinism).

The guarantee covers libds as its own build makes it. libds's `Float` arithmetic is its own: the integrator's C runtime, libm or SDK cannot replace it, and libds does not change the integrator's floating point, rounding mode included. A target's double arithmetic carries the guarantee once it has been shown correct on that target, against the archive its release row ships, and a build using any other is outside the guarantee.

*(libds.h: Platform signature, Spec: [NDET.1.1], [NDET.1.2], [NDET.1.3], [NDET.1.4], [NSBK.7.1], [LDET.3.4.1])*

### Self-contained and lean forms

A file whose leading atom is a `DscHeader` is self-contained, with the DSC bytes at its front. A file whose leading atom is a `StreamHeader` is lean.

A replay or verification path dispatches on the leading atom's field number. It takes the DSC bytes from the file's front if present, and otherwise from a supplied `.dsc`, and verifies them against the session header's [`dsc_hash`](#ds_session_header_t) before replaying. A mismatch is fatal: `DS_ERR_BND_DSC_MISMATCH` or `DS_ERR_BND_DIALECT_MISMATCH`. The forms are in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(Spec: [NDET.7], [RFCS.4.5], [RFCS.13.3])*

## Platform signature

### `ds_platform_signature_t`

**`typedef struct ds_platform_signature { const char *os_family; const char *cpu_arch; const char *libc; const char *compiler; const char *libds_version; const char * const *backends; size_t n_backends; } ds_platform_signature_t;`**

The environment properties of a build, and the identities of the engine's series backends.

It is provenance, not a scope on the [guarantee](#determinism-guarantee): a recorded session replays bit for bit whether or not two runs' signatures match.

| Member | Holds | Valid |
|---|---|---|
| `os_family` | `"linux"`, `"bsd"` or `"unknown"` | for the program's lifetime |
| `cpu_arch` | `"x86_64"`, `"aarch64"`, `"arm"`, `"x86"` or `"unknown"` | for the program's lifetime |
| `libc` | `"glibc-X.Y"`, `"bsd-libc"` or `"unknown"`; a musl build reports `"unknown"` | for the program's lifetime |
| `compiler` | `"gcc-X.Y"`, `"clang-X.Y"` or `"unknown"` | for the program's lifetime |
| `libds_version` | the libds version string, under [Version macros](../conventions/linking.md#version-macros) | for the program's lifetime |
| `backends` | one string per registered series backend, in slot order | for the engine's lifetime |
| `n_backends` | the number of entries in `backends` | |

A `backends` entry is `<atom>:<backend_name>:<backend_version>`, with `<atom>` the body message of the backing's atom: `SeriesBackendRingBuffer:ds-ring-buffer:1.0.0`. The list is exactly the seven entries of [NDET.2.5](inv:specs:std:label#ndet-2-5), in its order. The names and versions are provenance.

*(libds.h: Platform signature, ds_platform_signature_t, Spec: [NDET.2.1], [NDET.2.2], [NDET.2.5], [NSBK.7.1], Source: runtime/src/libds/platform.c)*

### `ds_engine_get_platform_signature`

**`ds_result_t ds_engine_get_platform_signature(ds_engine_t *engine, ds_platform_signature_t *out);`**

Fills `*out` with the engine's platform signature.

The tuple is stable for the engine's lifetime. The call stays valid under the [halt latch](../engine/lifecycle.md#halt-latch).

Errors: `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry); `DS_ERR_OOM` when the backend identity list cannot be built.

*(libds.h: ds_engine_get_platform_signature, Platform signature, Spec: [NCBK.2.9], Source: runtime/src/libds/platform.c)*

## Session header

### `ds_session_header_t`

**`typedef struct ds_session_header { const char *ds_version; const char *session_id; const char *tier_id; const uint8_t *dsc_hash; size_t dsc_hash_len; const uint32_t *capabilities; size_t n_capabilities; const uint8_t *dialect_def_sha256; size_t dialect_def_sha256_len; } ds_session_header_t;`**

The fields of a fact stream's `StreamHeader` that the engine captures.

| Member | Holds |
|---|---|
| `ds_version` | this build's DS version, the only version a stream carries |
| `session_id` | the run id given at [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new); `""` if none was given |
| `tier_id` | the tier id given at `ds_engine_new`; `""` if none was given |
| `dsc_hash`, `dsc_hash_len` | the loaded artefact's header `dsc_sha256`, 32 bytes |
| `capabilities`, `n_capabilities` | the artefact header's [`ds_capability_t`](../engine/loading.md#ds_capability_t) numbers, ascending; may be empty when loaded |
| `dialect_def_sha256`, `dialect_def_sha256_len` | the artefact header's dialect definition hash, 32 bytes |

`dsc_hash`, `capabilities` and `dialect_def_sha256` are NULL, with their lengths 0, until an artefact has been [loaded](../engine/loading.md#ds_engine_load_dsc) successfully.

A reader accepts a stream whose `ds_version` begins with its own `<major>.<minor>.` and refuses any other with `DS_ERR_FS_VERSION`. What else it refuses in a header is in [RFCS.4.7](inv:specs:std:label#rfcs-4-7). `StreamHeader` is in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(libds.h: ds_session_header_t, ds_engine_get_session_header, Spec: [NDET.3.1], [NDET.3.2], [NDET.5])*

### `ds_engine_get_session_header`

**`ds_result_t ds_engine_get_session_header(ds_engine_t *engine, ds_session_header_t *out);`**

Fills `*out` with the engine's session-header fields.

Every pointer points into engine-owned storage, stable for the engine's lifetime. The call stays valid under the [halt latch](../engine/lifecycle.md#halt-latch).

Errors: `DS_ERR_INVAL` for a NULL `engine` or `out`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry).

*(libds.h: ds_engine_get_session_header, Spec: [NCBK.2.9], Source: runtime/src/libds/platform.c)*

## Series

### Series backends

An engine from [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new) or [`ds_engine_clone`](../engine/lifecycle.md#ds_engine_clone) arrives with the seven backings of [NSBK.6.1](inv:specs:std:label#nsbk-6-1) registered, and an integrator registers nothing.

The set is closed: libds accepts no integrator-supplied vtable, and for each backing the implementation libds ships is the only one that runs. The compiler chooses a backing per series and records it in the `.dsc`. The backends are in [Series backends](inv:internals:std:doc#values/series-backends).

*(libds.h: Series, Spec: [NSBK.1.1], [NSBK.1.2], [NSBK.1.3], [NSBK.2.3], [NSBK.6.1])*

### Series reads

No public function reads a series.

A series' values reach an integrator only through what rules do with them: a call, or a fact they emit or publish.

*(libds.h: Series, Spec: [NSBK.6.3])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Recording and atoms

## Recording

### `start_recording`

**`:- pred start_recording(session::in, session::out) is det.`**

Begins recording the session's [fact stream](inv:internals:std:doc#artefacts/fact-stream), or begins again.

From here, each call that changes the session adds what the engine emitted. A second call discards what the first recorded. It refuses nothing.

```mercury declaration
:- pred record_pump(maybe(recording)::out, session::in, session::out) is det.
record_pump(Rec, !S) :-
    start_recording(!S),
    pump(_, !S),
    Rec = recording(!.S).
```

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [RFCS.2])*

### `stop_recording`

**`:- pred stop_recording(session::in, session::out) is det.`**

Ends the recording and discards it.

[`recording`](#recording-function) answers `no` afterwards. With no recording in progress it changes nothing.

*(Source: bindings/mercury/src/mercury_ds.session.m)*

### `recording` type

**`:- type recording ---> recording(recording_bytes :: bitmap, recording_unencodable :: list(stream_event)).`**

A recording, as libds's recorder writes it.

`recording_bytes` is the stream's bytes. `recording_unencodable` is the events the stream could not encode, in the order the engine emitted them, and a non-empty list says the bytes are short of them. `stream_event` is `ds.events`'.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.rfcs.m)*

### `recording` function

**`:- func recording(session) = maybe(recording).`**

The recording so far, or `no` when the session is not recording.

`recording_bytes` is empty until the engine's first event after the recording began, when the header and the schemas are written. It answers on a halted session.

*(Source: bindings/mercury/src/mercury_ds.session.m, Spec: [RFCS.5.1])*

## Replay

### `replay`

**`:- pred replay(bitmap::in, step::out, session::in, session::out) is det.`**

Replays a recording into a session, delivering each input it holds and letting the engine derive the rest.

Replay into a session freshly loaded from the artefact the recording was made with. What else the engine needs is in [Replay settings](inv:integrator:std:doc#engine/lifecycle). The inputs are a host's asserts and retracts, its clock samples and its pumps. Each pump runs with no firing limit. No host method runs, and `step_duties` is empty. The duties the engine derives again are in `step_reports`. A recording in progress keeps what the replay emits.

Refused with the session unchanged:

| `error` with | Condition |
|---|---|
| `engine_halted` | the session has halted |
| `fs_version` | the recording is of another DS series, or names none |
| `fs_unknown_inject` | an unknown atom is numbered 1 to 127 |
| `parse` | anything else malformed: a frame or an atom's body, a malformed `capabilities` list, or an unknown atom numbered 0, 128 to 255, or above 2047 |
| `bnd_incomplete` | the header holds one of `dsc_hash` and `dialect_def_sha256` and not the other |
| `bnd_dsc_mismatch`, `bnd_dialect_mismatch` | the dialect-binding tuple is not the program's: made with another artefact, or under other settings |
| `fs_recording_incomplete` | the recording's first event has a `seq` other than 0 |

A header with neither hash is replayed with no binding check.

Failed at an atom, with what was delivered before it applied, and nothing after it:

| `error` with | Condition |
|---|---|
| `schema_unknown` | a `FactAssert` names a schema no `SchemaDef` announced, or one the engine does not hold |
| `fs_unknown_fact_id` | a `FactRetract` names a fact no earlier atom left in working memory, or one an earlier `FactRetract` named |
| `fs_divergence` | a compare-class atom is not the next the replay re-derived; the replay re-derived one the recording does not hold; a `CacheSeed` is refused, or follows an event atom; an `ExternalAssert`'s delivery is refused, or asserts other facts than its `fact_ids` |
| the refusal's status, as [`assert_fact`](facts.md#assert_fact) lists it | the engine refuses a `FactAssert` for anything but a bound |
| `engine_halted` | a `FactAssert`, a `FactRetract` or a `PumpBoundary` meets an engine already halted |

A bound's refusal of a `FactAssert`, a halt an input itself raises, and any status a `PumpBoundary`'s pump reports, `nan_rejected` among them, do not end the replay.

A replay that reaches the end of its recording with every compare clean answers `ok`, for a run that halted too. [`halted`](session.md#halted) says whether the run halted. `engine_halted` from `replay` means the replay did not reproduce the run, or met an engine already halted.

*(Source: bindings/mercury/src/mercury_ds.session.m, runtime/mercury/src/ds.replay.m, runtime/mercury/src/ds.rfcs.m, runtime/mercury/src/ds.binding.m, Spec: [LDET.1.10], [RFCS.16.3], [RFCS.5.4], [RFCS.6.7], [RFCS.7.3], [RFCS.26.2], [RBND.2.1], [RBND.5.1], [NDET.8.2], [NCBK.2.11])*

## Atoms

### `atom`

**`:- type atom ---> atom(atom_ref :: atom_ref, atom_offset :: int, atom_body_offset :: int, atom_body_length :: int).`**

One atom of a `.dsc` or a recording, in the [framing](inv:internals:std:doc#artefacts/fact-stream) of either.

| Field | Holds |
|---|---|
| `atom_ref` | `known(Id)`, a `ds.atom.atom_id`, or `unknown(Field)` for a field number this runtime has no atom for |
| `atom_offset` | where its frame begins, in bytes |
| `atom_body_offset`, `atom_body_length` | where its body lies, in bytes |

*(Source: bindings/mercury/src/mercury_ds.atoms.m, runtime/mercury/src/ds.atom.m)*

### `atom_listing`

**`:- type atom_listing ---> atom_listing(atom_listing_atoms :: list(atom), atom_listing_outcome :: outcome).`**

What [`atoms`](#atoms-1) read: the atoms in file order, and `ok` or why the walk stopped.

*(Source: bindings/mercury/src/mercury_ds.atoms.m)*

### `atoms`

**`:- func atoms(bitmap) = atom_listing.`**

Reads the atoms of a `.dsc` or a recording, with no session.

It reads the framing alone. An atom with an unknown field number is listed, whatever its [band](inv:specs:std:label#rfcs-16-3).

The walk stops at the first frame that is not well formed, with `parse` and the offset in the detail, and keeps the atoms before it:

| Frame | Condition |
|---|---|
| its first byte | is not `0x0A` |
| its length or body | is cut short, or its varint overruns |
| its atom | has no member, its member is not length-delimited, or its member's body ends early |

*(Source: bindings/mercury/src/mercury_ds.atoms.m, runtime/mercury/src/ds.atom.m, Spec: [RFCS.19.3])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Determinism

## Single writer per stream

Nothing outside an engine's [consumption loop](../overview/runtime-architecture.md#consumption-loop), the sole writer of its stream, touches `seq`, which the loop assigns in consumption order.

*(Spec: [RARC.8.2.1])*

## Consumption-order sequencing

Inputs are sequenced in the order the integrator makes the calls that carry them.

Of two inputs the integrator asserts at the same instant, the one whose call it makes first is sequenced first. The stream holds that order, and a replay makes the calls in that order and produces the same output.

*(Spec: [RARC.8.3.1])*

## No hash-order dependence

Agenda data structures, working-memory indices and the alpha and beta memories may be hashed, and the observable firing order is the [conflict resolver's](../overview/runtime-architecture.md#agenda-and-conflict-resolver) whatever the hashing.

The conflict resolver uses no hash iteration order as a tiebreaker.

*(Spec: [RARC.8.4.1])*

## Parallelism equivalent to sequential

An engine processes every observable event serially, inside its consumption loop.

Parallelism in a deployment is integrator code: sibling engines on different threads, or I/O fan-out on the integrator's side ([Threading model](../overview/runtime-architecture.md#threading-model)).

*(Spec: [RARC.8.5.1])*

## Platform-signature fidelity

Replay is bit-for-bit, within a platform and across platforms.

The platform signature is provenance, and a trace does not record it.

*(Spec: [RARC.8.6.1])*

## No uncontrolled randomness

The runtime takes no identifier and no seed from an entropy source or the wall clock, only from inputs a replay reproduces.

Synthetic identifiers are source-derived ([Mangling](../engine/lowering.md#mangling)). A fact's `event_id` is derived from the run ([Event identity](../overview/runtime-architecture.md#event-identity)).

*(Spec: [RARC.8.7.1])*

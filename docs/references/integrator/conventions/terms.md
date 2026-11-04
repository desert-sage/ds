<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Terms

## Engine

An engine is one self-contained DS runtime instance, with its own Rete network, schema registry, clock, working memory, telemetry and callback registrations.

*(Spec: [NLFC.1.3], [NLFC.4.1])*

## Tier

A tier is one engine of a deployment, with its own working memory, dialect, clock and stream.

*(Spec: [RARC.1.2], [RARC.2.1])*

## Artefact

An artefact is a DS program compiled to the `.dsc` format, carrying the schemas and rules its `.ds` source declared.

*(Spec: [NFCT.1.1], [NGST.1.3])*

## Schema

A schema is a fact type, [registered](../facts/schemas.md#schema-registry) from an artefact, whose [slots](../facts/schemas.md#ds_slot_desc_t) are the slot-type contract its facts are held to.

*(Spec: [NFCT.1.1], [NFCT.1.4.2])*

## Fact

A fact is an [instance](../facts/reading.md#fact-accessor-results) of a schema, held in working memory.

*(Spec: [NFCT.6.1], [NFCT.6.2])*

## Working memory

Working memory is the set of an engine's [live facts](../facts/reading.md#ds_engine_fact_count).

*(Spec: [NFCT.6.1], [NLFC.2.1])*

## Pump

A pump is one call of [`ds_engine_pump`](../engine/pump.md#ds_engine_pump), which runs the engine's agenda to exhaustion.

*(Spec: [NLFC.2.2])*

## Stream event

A stream event is one observable event of an engine, delivered to the stream callback as a `ds_stream_ev_t`.

*(Spec: [NCBK.2.1], [NCBK.2.2])*

## Callback

A callback is an integrator function that libds invokes.

*(Spec: [NCBK.1.1])*

## Handle

A handle is a pointer to a libds type whose layout is [private](handles.md#opaque-layout).

*(Spec: [IARC.1.8], [IDAT.3.1])*

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# runtime/ — DS reference runtime

`libds`, the reference implementation of DS: an **embeddable rule engine** built
as a C library and linked into a host program. It holds a working memory of
facts, matches them against compiled rules with a native C Rete engine, and hands
the results back through callbacks the host registers.

It is not a server, is not addressed over a socket, and spawns no threads. There
is no wire or protocol surface, so the entire integrator API is one header —
[`include/libds.h`](include/libds.h), per `[IARC.1.4]` / `[IARC.9.3]`.

## For integrators

The host drives everything. The shape of an integration:

```c
ds_engine_t *e = NULL;
ds_engine_new(NULL, &e);                          /* NULL: the default config */
ds_engine_set_call_callback(e, on_call, self);    /* effects arrive here */
ds_engine_load_dsc(e, rules_dsc, rules_dsc_len);  /* compiled rules + schemas */
/* assert facts, pump, observe */
ds_engine_free(e);
```

An integrator:

- **Gets facts in.** External events — sensor reads, broker messages, API
  replies, timers — become `ds_engine_assert` calls. The engine has no intake of
  its own.
- **Drives the pump.** Rules fire only inside `ds_engine_pump`. Nothing runs in
  the background.
- **Wires the effect callbacks.** When a rule wants to `call` a service, `cache`
  a value, `record_event`, `alert` or `log`, the engine invokes a registered
  callback. It has no idea what a service or a database is.
- **Registers `call` targets** — C functions linked with the host — and supplies
  storage and the test clock the same way.
- **Defines tier dialects** naming which language forms each tier of their
  platform admits: `specs/runtime/TIER_DIALECTS/` (`RTDI`) and
  `specs/integration/DIALECTS/` (`NDLC`), the latter also carrying the
  `backend_vtables` a tier bundles.
- **Writes adapters** for their platform's external systems, against the
  language-level contract in `specs/language/ADAPTER_CONTRACT/` (`LADP`).

The engine's job is to keep the rule machinery honest: the fact plane, Rete
evaluation, deterministic firing, truth maintenance, TTL expiry, refraction,
recording, metrics and dispatch. Everything touching the outside world is the
integrator's.

Start at
[`docs/references/integrator/`](../docs/references/integrator/index.md) — the
Integrator's Reference is the prose manual for all of the above.

## What is in this tree

| path | what |
|---|---|
| `include/libds.h` | the entire public C surface |
| `src/libds/` | the engine — Rete network, DSC loader, dispatcher, allocator, series backends |
| `tests/libds/` | impl-path and spec-path C tests |
| `docker/`, `vm/` | build images, and the BSD / rv64 lanes |
| `rp2350/`, `esp32*/`, `samd51/`, `nrf52840/`, … | per-board ports |

## Which spec wins

Three prefixes describe this runtime, and they are not interchangeable:

- **`specs/language/`** (`L*`) — what DS *guarantees*, independent of any
  implementation. Authoritative for the language.
- **`specs/runtime/`** (`R*`) — what any conforming runtime must satisfy:
  architecture, the DSC format, lowering, determinism, the fact stream.
- **`specs/impl/`** (`I*`) — what *this* implementation does. Module
  decomposition, struct layouts, the error taxonomy, the dispatcher contract.

**On a disagreement between `specs/runtime/` and `specs/impl/`, `impl/` wins** —
`I*` tracks the code. Where the code and every spec disagree, the header wins,
and that is a defect to file.

---

*Historical note: this engine once wrapped CLIPS, and a protocol layer once
carried facts between tiers. Both are gone. The native C Rete engine became the
default at 0.8.0 (`OFFCLIPS2`) and the only backend at **0.8.6**, which deleted
the dead CLIPS half of the runtime, compiler, build, tests and docs. The wire
layer went separately (`[IARC.2.3]`: "No protocol, no peer, no wire"). Comments
mentioning either are describing what was replaced, not what runs.*

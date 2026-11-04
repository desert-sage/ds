<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Loading an artefact

## Load

### `ds_engine_load_dsc`

**`ds_result_t ds_engine_load_dsc(ds_engine_t *engine, const uint8_t *data, size_t len);`**

Loads a compiled artefact into an engine.

`data` holds the full `.dsc` bytes, and `len` their count; the engine does not retain `data`. A load [registers every schema](../facts/schemas.md#schema-registry) and rule the source declared, with the schemas of the built-in module, and it is the only way a schema reaches an engine. It emits no stream event. What a load checks, and in which order, is in [The .dsc format](inv:internals:std:doc#artefacts/dsc-format), and the network's load in [Rete network](inv:internals:std:doc#engine/rete-network).

An engine holds one artefact. A load comes before the engine's first stream event, which a host [assert](../facts/asserting.md#ds_engine_assert), a [retract](../facts/asserting.md#ds_engine_retract) and a pump each emit. [`ds_engine_set_cache_cap`](../callbacks/cache.md#ds_engine_set_cache_cap), [`ds_engine_cache_seed`](../callbacks/cache.md#ds_engine_cache_seed) and [callback registration](../callbacks/contract.md#registration-order) each state their order against it.

Errors before the read, which change nothing:

| Code | Condition |
|---|---|
| `DS_ERR_INVAL` | `engine` is NULL, or `data` is NULL with `len` above 0 |
| `DS_ERR_ENGINE_HALTED` | the engine has [halted](lifecycle.md#halt-latch), or a failed load spent it |
| `DS_ERR_STATE` | the engine already holds an artefact, has emitted a stream event, or is under [Re-entry](../conventions/handles.md#re-entry) |

Errors after the read begins, each of which [spends the engine](#failed-load): `DS_ERR_DSC_TRUNCATED`, `DS_ERR_DSC_BAD_MAGIC`, `DS_ERR_DSC_VERSION`, `DS_ERR_DSC_DECODE`, `DS_ERR_DSC_SEMANTIC`, `DS_ERR_DSC_DANGLING`, `DS_ERR_DSC_DECOMPRESS`, `DS_ERR_DSC_CAPABILITY_ABSENT`, `DS_ERR_RETP_INVALID`, `DS_ERR_RETP_INDEX_OOB`, `DS_ERR_FN_NOT_FOUND`, `DS_ERR_BND_DIALECT_MISMATCH`, `DS_ERR_BND_INCOMPLETE` and `DS_ERR_OOM`. [RDSC.11.1](inv:specs:std:label#rdsc-11-1) maps each loader condition to its code. An error's detail names the failing atom, the byte offset and the violated rule.

*(libds.h: ds_engine_load_dsc, ds_engine_set_admission, DS_ERR_FN_NOT_FOUND, Spec: [NFCT.1.1], [NGST.4.2], [NERR.8.1], [RDSC.3.7], [RDSC.11.1], [IRET.21])*

### Failed load

A load that fails once it has begun reading the artefact spends the engine.

It returns the error that stopped it and sets the [halt latch](lifecycle.md#halt-latch). It raises no `EngineError` and records no stream event. Another load takes a new engine.

Every code in [NERR.8.1](inv:specs:std:label#nerr-8-1) and [RDSC.11.1](inv:specs:std:label#rdsc-11-1), `DS_ERR_BND_INCOMPLETE` and `DS_ERR_FN_NOT_FOUND` refuse the artefact itself: every engine of this build refuses the same bytes the same way, so another load needs a corrected artefact or, for `DS_ERR_DSC_CAPABILITY_ABSENT` and `DS_ERR_FN_NOT_FOUND`, a build that has what the artefact needs. `DS_ERR_BND_DIALECT_MISMATCH` follows from the engine's [admission policy](#ds_engine_set_admission): an engine with another policy loads the same bytes. `DS_ERR_OOM` follows from neither.

*(libds.h: ds_engine_load_dsc, ds_engine_set_admission, Spec: [RDSC.9.8], [NERR.8.2])*

## Capabilities

### `ds_capability_t`

**`typedef enum ds_capability { … } ds_capability_t;`**

A capability an artefact records, the C mirror of `proto/capabilities.proto`'s `Capability`.

Its members are `DS_CAPABILITY_UNSPECIFIED`, `DS_CAPABILITY_REALTIME`, `DS_CAPABILITY_CONSTSPACE`, `DS_CAPABILITY_LINEAR_SCAN`, `DS_CAPABILITY_LOGICAL`, `DS_CAPABILITY_DYNAMIC_TTL`, `DS_CAPABILITY_REGEX`, `DS_CAPABILITY_FLOAT`, `DS_CAPABILITY_CALL`, `DS_CAPABILITY_PUBLISH`, `DS_CAPABILITY_CACHE`, `DS_CAPABILITY_CACHE_DELETE`, `DS_CAPABILITY_NOCOOLDOWN`, `DS_CAPABILITY_SERIES`, `DS_CAPABILITY_SAMPLED_SLOTS`, `DS_CAPABILITY_PERSIST_ON_SERIES`, `DS_CAPABILITY_STORAGE_HYDRATE_FACTS` and `DS_CAPABILITY_STORAGE_HYDRATE_SAMPLES`.

*(libds.h: ds_capability_t)*

### `ds_build_capabilities`

**`size_t ds_build_capabilities(ds_capability_t *out, size_t out_cap);`**

Reports the capabilities this build of libds has code for, in ascending order.

It writes up to `out_cap` of them to `out`, and returns how many there are in all. `out` may be NULL when `out_cap` is `0`. It [needs no engine](../conventions/handles.md#several-engines). The one capability a build can lack is `DS_CAPABILITY_REGEX`.

A load of an artefact that requires a capability missing from this list fails with `DS_ERR_DSC_CAPABILITY_ABSENT`, and the detail names the lowest.

*(libds.h: ds_build_capabilities, Spec: [NLFC.10.1], [RDSC.16.2.7])*

## Admission

### `ds_admission_t`

**`typedef enum ds_admission { DS_ADMIT_EITHER = 0, DS_ADMIT_TRUE_ONLY = 1, DS_ADMIT_FALSE_ONLY = 2 } ds_admission_t;`**

Which settings of one capability an integration admits.

| Member | A load admits an artefact with the capability |
|---|---|
| `DS_ADMIT_EITHER` | `true` or `false`; the default |
| `DS_ADMIT_TRUE_ONLY` | `true` only |
| `DS_ADMIT_FALSE_ONLY` | `false` only |

*(libds.h: ds_admission_t, Spec: [NLFC.10.2])*

### `ds_engine_set_admission`

**`ds_result_t ds_engine_set_admission(ds_engine_t *engine, ds_capability_t cap, ds_admission_t admit);`**

Sets the admission policy for one capability, before an artefact is loaded.

A later load whose resolved setting for `cap` the policy does not admit fails with `DS_ERR_BND_DIALECT_MISMATCH`, and the detail names the capability. `DS_ERR_DSC_CAPABILITY_ABSENT` means the build has no code for a capability; this code means the integration refuses a setting, whether or not the build has the code.

Errors: `DS_ERR_INVAL` for a NULL `engine`, a `cap` outside the registry, or an `admit` outside `ds_admission_t`; `DS_ERR_STATE` under [Re-entry](../conventions/handles.md#re-entry), and after a successful load, which leaves the policy unchanged; `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_admission, Spec: [NLFC.10.2], [RDSC.16.2.7], Source: runtime/src/libds/dsc/loader.c)*

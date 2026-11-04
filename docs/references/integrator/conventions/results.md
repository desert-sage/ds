<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Results

## `ds_status_t`

**`typedef int ds_status_t;`**

The type of a status code.

`0` is success, a negative value is an error, and positive values are unused. The number identifies the code. Compare a status with `DS_OK` or with a named code, and never by its sign. Every code is in the [catalogue](errors.md).

*(libds.h: Status codes, Spec: [NERR.1.1], [NERR.1.3], [IDAT.2.1.1], [IERR.1.4])*

## `DS_OK`

**`#define DS_OK 0`**

The one success code.

A function with several successful outcomes reports which one through its return values or out-parameters.

*(libds.h: Status codes, Spec: [IERR.2.2.1])*

## `ds_result_t`

**`typedef struct ds_result { ds_status_t status; const char *detail; } ds_result_t;`**

The outcome of a libds call: a status, and a [detail string](#detail-string).

Every libds function that can fail returns it. `ds_free` and the four Rete visitor callback types ([`ds_rete_node_cb_t`](../introspection/network.md#ds_rete_node_cb_t), [`ds_rete_edge_cb_t`](../introspection/network.md#ds_rete_edge_cb_t), [`ds_rete_trace_cb_t`](../introspection/network.md#ds_rete_trace_cb_t), [`ds_rete_refract_cb_t`](../introspection/network.md#ds_rete_refract_cb_t)) cannot fail, and return `void`. A visitor has the shape its call declares: [`ds_fact_visitor_fn`](../facts/reading.md#ds_fact_visitor_fn) returns `ds_result_t`. libds reports every failure this way, allocation failures and internal invariant violations included, and does not call `abort`, `exit` or `longjmp`.

The struct is two words: 16 bytes on a 64-bit platform. A success is `{ DS_OK, NULL }`, and an error is `{ <negative code>, <detail> }`.

Handle or propagate every result that is not `DS_OK`. Propagation inside libds is in [libds modules](inv:internals:std:doc#overview/libds-modules).

*(libds.h: Result type, ds_free, ds_fact_visitor_fn, Rete network introspection, Spec: [IARC.1.12], [NCBK.1.1], [IDAT.1.3], [IDAT.2.3.1], [IERR.1.3], [IERR.1.5], [IERR.3.2], [IERR.3.3], [IERR.3.4], [IERR.8.8])*

## `DS_OK_R`

**`#define DS_OK_R ((ds_result_t){ DS_OK, NULL })`**

The success result.

*(libds.h: Result type, Spec: [NERR.1.3], [IDAT.2.3.2])*

## `DS_ERR_R`

**`#define DS_ERR_R(s, d) ((ds_result_t){ (s), (d) })`**

A result with status `s` and detail `d`.

*(libds.h: Result type, Spec: [NERR.1.3], [IDAT.2.3.2])*

## Detail string

**`const char *detail;`**

The member of `ds_result_t` that describes an outcome to a human.

libds owns it. A call on an engine returns a detail valid until the next libds call on that engine; copy it to keep it longer. A call that [acts on no engine](handles.md#several-engines), and a [`ds_engine_new`](../engine/lifecycle.md#ds_engine_new) that fails, returns a static detail, valid for the life of the process.

It may be `NULL` on `DS_OK`, and on an error only for `DS_ERR_OOM`. Check it before passing it to `printf`.

It is English and advisory, and its text is not stable across versions or across calls. Branch on `status`, never on `detail`.

*(libds.h: Result type, Spec: [NERR.1.2], [NERR.2.1], [NERR.2.3], [IERR.1.6], [IERR.3.3], [IERR.4.1.1], [IERR.4.2.1])*

## Code ranges

Each range of status codes is one category, by originating concern.

| Range | Category |
|---|---|
| `0` | OK |
| `-1..-99` | Generic |
| `-100..-199` | Input |
| `-200..-299` | Runtime |
| `-400..-499` | Storage / callbacks |
| `-500..-599` | Artefact load |
| `-600..-610` | Native Rete |
| `-620..-623` | Series-backend ABI |
| `-700..-704` | Dialect / artefact binding |
| `-710..-714` | Contract |
| `-720..-730` | Event-trace |
| `-10000` and below | An integrator's own return values. libds returns none of them. |

*(libds.h: Status codes, Spec: [NERR.3.1], [IERR.2.1], [IERR.2.8.1], [IERR.2.8.2])*

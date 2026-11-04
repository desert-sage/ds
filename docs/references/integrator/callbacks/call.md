<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Calls

## `ds_call_request_t`

**`typedef struct ds_call_request { const char *service; const char *correlation; const ds_arg_t *args; uint32_t arg_count; int64_t timetag; const char *rule_name; } ds_call_request_t;`**

What a `call` action delivers to the call callback.

| Member | Meaning |
|---|---|
| `service` | the `"domain.method"` string |
| `correlation` | the [correlation](#correlation) |
| `args`, `arg_count` | one [typed argument](../facts/values.md#ds_arg_t) per kwarg the call supplies, sorted by name; an optional kwarg the call omits is absent |
| `timetag`, `rule_name` | the firing activation's identity; `timetag` is never `0`, and `rule_name` never NULL |

Every pointer is valid only for the callback.

*(libds.h: ds_call_request_t, Spec: [NCBK.2.12], [NCBK.6.2], [NSTG.6.1], [NSTG.6.3])*

## `ds_call_cb_t`

**`typedef ds_result_t (*ds_call_cb_t)(ds_engine_t *engine, const ds_call_request_t *request, void *user);`**

The call callback.

It dispatches the request and returns. A status other than `DS_OK` propagates unchanged through [`ds_engine_pump`](../engine/pump.md#ds_engine_pump).

*(libds.h: ds_call_cb_t, Spec: [NCBK.6.1], [NCBK.6.4], [NCBK.6.8], [IDSP.6.3])*

## `ds_engine_set_call_callback`

**`ds_result_t ds_engine_set_call_callback(ds_engine_t *engine, ds_call_cb_t cb, void *user);`**

Registers the call callback.

A NULL `cb` removes it. Errors: `DS_ERR_INVAL`, `DS_ERR_STATE`, `DS_ERR_ENGINE_HALTED`.

*(libds.h: ds_engine_set_call_callback, Spec: [NCBK.2.9], [RARC.13.16])*

## No callback

A `call` with no call callback returns `DS_ERR_STORAGE_UNAVAILABLE` through [`ds_engine_pump`](../engine/pump.md#ds_engine_pump).

`DS_EV_ACTION_CALL` still fires. A replaying engine invokes no call callback, and raises no error for its absence.

*(libds.h: ds_engine_set_call_callback, Spec: [NCBK.6.6], [NCBK.6.9], [IDSP.6.3], [IDSP.6.4])*

## Correlation

The string that ties a call to its answer: the call's `as` value, or a value generated per activation for a call with none.

It is never NULL and never empty. Pass it verbatim to the `corr` slot of the answer. Do not parse it, derive anything from its shape, or substitute another.

*(libds.h: Call callback, Spec: [NCBK.6.2], [NCBK.6.3], [IDSP.6.2])*

## Answers

An answer to a call is a fact the integrator asserts with [`ds_engine_assert`](../facts/asserting.md#ds_engine_assert), once the callback has returned.

It is a fact of the service's response schema, or a `CallError`, with `corr` set to the correlation. For a service declaring `no response`, assert nothing on success and a `CallError` on failure. A response takes its lifetime from its schema's TTL.

Answers enter only through the integrator: time out a call in the integrator, and assert the `CallError` there.

When an answer is asserted, the engine first retracts the live facts with the same `corr`:

| Answer | Retracted |
|---|---|
| a fact of a response schema | every fact of that schema, and every `CallError` |
| a `CallError` | every `CallError`, and every fact of every response schema |

An answer whose `corr` is empty retracts nothing.

A `CallError` whose `code` does not match the pattern of [LECC.1.2](inv:specs:std:label#lecc-1-2) is placed in working memory with `code` set to `internal.invariant` and every other slot as given, and the rewrite counts in `ds.errors.code_invariant_total`. The engine checks the pattern and nothing more.

*(libds.h: Call callback, Spec: [NCBK.6.4], [NCBK.6.5], [NCBK.6.7], [LCRS.6.2.4], [IDSP.6.6], [LECC.1.2], [LECC.1.5], Source: runtime/src/libds/dispatcher.c)*

## Before the callback

The engine applies a call's cooldown, and retracts the prior response and `CallError` for its correlation, before the call reaches the callback.

The integrator does neither.

*(libds.h: Call callback, Spec: [NCBK.6.7], [LCRS.6.2.1], [IDSP.6.3], [IDSP.6.8])*

## Refused arguments

A NaN `Float` argument refuses the call with `DS_ERR_NAN_REJECTED`.

A refused argument emits no `DS_EV_ACTION_CALL` and invokes no callback.

A kwarg whose value is `null` prevents the call: the engine emits no `DS_EV_ACTION_CALL`, invokes no callback and reports no status, the firing's other actions run, and `ds.calls.arg_error_total{service}` counts it.

A call's arity and argument types raise no status. A call whose operands its op does not admit is [`DS_ENGINE_FAULT_ARTEFACT_LIED`](stream.md#ds_engine_fault_t).

A non-finite `Float` in a `Json` argument is the [`NOT_REPRESENTABLE` trap](cache.md#non-finite-values), at the `call`: the call does not run.

*(libds.h: Call callback, Spec: [NCBK.6.8], [IDSP.6.3], [IDSP.6.5], [NERR.6], [LDET.3.2.7])*

## Fact arguments

A kwarg whose value is a fact is an argument of kind [`DS_ARG_ENCODED_FACT`](../facts/values.md#ds_arg_kind_t).

The integrator may forward its bytes to another tier's [`ds_engine_assert_external`](../facts/asserting.md#ds_engine_assert_external) without decoding them. The encoding is in [Fact stream](inv:internals:std:doc#artefacts/fact-stream).

*(libds.h: Call callback, Spec: [NCBK.6.10])*

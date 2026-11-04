<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Error codes

## The code form

### Code form

**`[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*`**

A code is the `String` in [`CallError`](call.md#callerror)'s `code` slot: dot-separated lower-snake-case segments, each starting with a letter.

The leftmost segment is the family, and later segments narrow within it. A code has at most four segments. A sent code has at least `<family>.<leaf>`.

*(Spec: [LECC.1.1], [LECC.1.2], [LECC.1.3], [LECC.1.4])*

### Malformed code

A `CallError` handed to the engine with a `code` outside the pattern enters working memory with `code` `internal.invariant` and every other slot as given.

No rule sees the malformed code. A one-segment code matches the pattern and enters as given.

*(Spec: [LECC.1.5])*

## Families

### Standard families

| Family | Meaning |
|---|---|
| `request` | the request was rejected at validation or dispatch |
| `internal` | a bug on the side answering the call |
| `adapter` | the system behind the service failed: it was unreachable, refused the request, throttled it or answered wrongly |

The sender of an `adapter` code names its leaf, in the code form.

*(Spec: [LECC.2.1], [LECC.2.2], [LECC.4.3])*

## Leaf codes

### `request` leaves

| Code | Meaning |
|---|---|
| `request.unsupported` | the service is not offered |
| `request.invalid_args` | the kwargs failed validation |
| `request.malformed` | no outbound request could be constructed from the call |
| `request.limit_exceeded` | the request exceeded a cap on the answering side, such as a result size or a query window |

A sender may add leaves under a standard family, in the code form.

*(Spec: [LECC.3], [LECC.3.1.1], [LECC.3.1.2], [LECC.3.1.3], [LECC.3.1.4])*

### `internal` leaves

| Code | Meaning |
|---|---|
| `internal.crash` | an unhandled exception while servicing the call |
| `internal.invariant` | a violated invariant during the call's lifecycle |
| `internal.bug` | any other logic error on the answering side |

*(Spec: [LECC.3.7.1], [LECC.3.7.2], [LECC.3.7.3])*

## Engine-emitted codes

### `request.unsupported` from the engine

The engine emits `request.unsupported` itself when nothing is registered for the call's target.

It has the wire shape and matching of any other code. A code's value does not say which side emitted it; `message` may.

*(Spec: [LECC.5.1], [LECC.5.2.2], [LECC.5.3])*

## The pattern-match contract

### Pattern-match contract

An `error` pattern's first segment is `request`, `internal` or `adapter`; any other is refused with `DS_VALIDATE_ERROR_PATTERN_UNKNOWN_FAMILY`. A pattern of more than four segments is refused with `DS_VALIDATE_ERROR_PATTERN_TOO_DEEP`.

`error request:` catches every leaf under the family, and `error request.malformed:` that one leaf. The matching is at [Code matching](continuations.md#code-matching).

```ds action error=DS_VALIDATE_ERROR_PATTERN_UNKNOWN_FAMILY
call svc.op level: r.level nocooldown
    error auth:
        log error "{r.id}"
```

*(Spec: [LECC.1.4], [LECC.6.1], [LECC.6.2], [LECC.6.4])*

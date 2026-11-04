<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Errors

## Results

### `ds_error`

**`:- type ds_error ---> status_error(status, string).`**

Why a call failed: the capability of a non-OK [`ds_result_t`](inv:integrator:std:doc#conventions/results).

The [`status`](#status) is what libds answers for the same case, and is never `ok`. The string is a detail for a person, and is not for parsing.

```mercury declaration
:- func error_name(ds_error) = string.
error_name(E) = status_name(S) :-
    error_status(E, S).
```

*(Source: bindings/mercury/src/mercury_ds.error.m)*

### `error_status`

**`:- pred error_status(ds_error::in, status::out) is det.`**

The status an error carries.

*(Source: bindings/mercury/src/mercury_ds.error.m)*

### `outcome`

**`:- type outcome ---> ok ; error(ds_error).`**

What a call with nothing else to return did: `ok`, or the error.

*(Source: bindings/mercury/src/mercury_ds.error.m)*

## Status codes

### `status`

**`:- type status ---> ok ; inval ; oom ; ... ; fs_unknown_fact_id.`**

A status code, generated from `proto/status.proto`.

A constructor is the code's name in the [error catalogue](inv:integrator:std:doc#conventions/errors), in lower case with the `DS_ERR_` prefix removed: `DS_ERR_ENGINE_HALTED` is `engine_halted`. `DS_OK` is `ok`.

*(Source: bindings/mercury/src/mercury_ds.status.m)*

### `status_number`

**`:- func status_number(status) = int.`**

The code's number, as the error catalogue lists it.

*(Source: bindings/mercury/src/mercury_ds.status.m)*

### `number_status`

**`:- pred number_status(int::in, status::out) is semidet.`**

The code a number names.

It fails if no live code has that number.

*(Source: bindings/mercury/src/mercury_ds.status.m)*

### `status_name`

**`:- func status_name(status) = string.`**

The code's name, as `libds.h` spells it: `status_name(inval)` is `"DS_ERR_INVAL"`.

*(Source: bindings/mercury/src/mercury_ds.status.m)*

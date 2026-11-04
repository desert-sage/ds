<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Errors

## Error class

### `DsError`

**`constructor(statusCode: number, detail?: string, options?: ErrorOptions);`**

A failing libds call: the form of a non-OK [`ds_result_t`](inv:integrator:std:doc#conventions/results), and `class DsError extends Error`.

Its `name` is `"DsError"`. Its `message` is `ds status <status>: <detail>`, without the detail where there is none.

A `TypeError` or `RangeError` these pages name carries no status.

```javascript statement
try {
  engine.pump();
} catch (err) {
  if (err instanceof ds.DsError) console.log(err.status, err.detail);
}
```

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `DsError.status`

**`status: number;`**

The status number, as [the error catalogue](inv:integrator:std:doc#conventions/errors) lists it.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js)*

### `DsError.detail`

**`detail: string;`**

libds's [detail string](inv:integrator:std:doc#conventions/results), copied when the error is made, and `""` where there is none.

*(Source: bindings/js/types/bind.d.ts, bindings/js/lib/bind.js, bindings/js/src/ds.c)*

### `DsError.cause`

**`cause`**

The exception of the host function behind the failure, where there is one: a `writeThrough` handler's, or a recording sink's.

*(Source: bindings/js/lib/bind.js, bindings/js/src/ds.c)*

## Status codes

### `status`

**`export { status };`**

The namespace of status constants: `DS_OK` and each `DS_ERR_*` of [the error catalogue](inv:integrator:std:doc#conventions/errors), each as its number, with [`STATUS`](#status-1).

Both entry points that open libds export it, and [`Api.status`](targets.md#api) is the same namespace. The `./status` entry point exports the same names, and loads no libds.

*(Source: bindings/js/types/bind.d.ts, bindings/js/types/status.d.ts, bindings/js/lib/status.js, bindings/js/package.json)*

### `STATUS`

**`export const STATUS: Readonly<{ DS_OK: 0; ... }>;`**

A frozen object of every status, name to number.

*(Source: bindings/js/types/status.d.ts, bindings/js/lib/status.js)*

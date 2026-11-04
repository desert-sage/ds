<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# mercury_ds

`mercury_ds` is DS's Mercury runtime bound into Mercury programs. A Mercury
program loads a compiled DS program (a `.dsc`), asserts facts into it, pumps
it, and acts on what it reports, with no C runtime in between.

DS has two runtimes. libds, in C, is the one for performance and small
devices. The Mercury runtime (`runtime/mercury`) is the second, written for
correctness, and is differentially tested against libds. This binding is how
anyone runs that second, checked implementation over their own DS program.

## What the types and determinism give you

- **Every call is `det`.** `load`, `pump` and every call that changes a
  session give exactly one answer. A lookup that may find nothing is a
  `search_` predicate, `semidet`, beside a `lookup_` function that throws.
- **A session is a value.** A call that changes one takes it and returns the
  new one; the old one is unchanged, so a snapshot is a variable and a clone
  is a copy. Nothing is freed.
- **The session performs nothing.** Every call that changes a session
  returns, as data, what it reported (stream events, log lines, metrics,
  cache expiries) and the duties it leaves the host (cache writes and
  removals); a pump also returns the service calls it issued. The host
  answers each call back into the session. No host code runs inside a call to
  the session, so nothing is caught and nothing is half done.
- **A slow host is felt only between calls.** A host gets a call's reports,
  duties and calls when the call returns, so it cannot slow the engine inside
  a pump, and a pump holds all of its effects until it returns
  ([RARC.5.8.7]). The order is the order libds hands its callbacks.
- **A failure is a value**: `maybe_error(session, ds_error)` from `load`,
  beside the reports the load logged ([RDSC.9.4]), and
  `ok` or `error(ds_error)` as a call's outcome, carrying the status libds
  gives the same case.
- **What a type cannot hold, a host cannot pass.** A fact's values are
  `storable`, the subtype of the runtime's value that a slot holds, so a
  duration where a slot wants a value is a type error, not a refusal.

## No callback can be left unregistered

A libds integrator registers callbacks, and two conformance kinds test what
libds does when one is missing: `adapter_essential_null_cb_error` (an
essential callback unregistered, and the pump fails) and
`adapter_cache_volatile_no_cb` (no cache persistence callback, and the
`cache` verb still succeeds and emits its action). Neither applies here,
because a session has no callbacks to register. Everything a libds callback
receives comes back from the call as data: a pump's `pumped_reports`,
`pumped_duties` and `pumped_calls`, and every other call's reports and duties,
in its `step` or `assert_step`. A host that does not answer a call, or
does not perform a cache write, has made that choice in its own code, and
the session is the same either way. The `cache` verb's action is reported
whether or not the host keeps the value. The fixtures that carry these
kinds (`adapter/IDSP.1.4_call_recorded_with_no_callback`, `IDSP.6.4`,
`IDSP.7a`, `IDSP.7b`) describe a state this binding cannot be in.

## The purity ledger

`mercury_ds` has no `promise_pure`, no `impure` call, no `foreign_proc` and no
`mutable`; its gate refuses any (`MERCURY_STYLE.md`, MER.6). The only foreign
code in a program that uses it is what the runtime sanctions: RE2 for regular
expressions, the wall-clock read, the shortest round-trip float text,
CORE-MATH's correctly rounded functions and libds's own `fma`, and the
platform signature (`docs/PROMISE_LEDGER.md`).

## Grade

`hlc.gc` only, Mercury 22.01.

## The modules a host imports

`mercury_ds`'s own modules, and the runtime's `ds.*` modules for the runtime's
types the binding uses: `mercury_ds.m`'s header lists each, with the types a
host names from it. A host imports both sets without qualification; where a
call here shares a name with one in `ds.engine`, the argument types decide.

## Building and running

The binding and the runtime are two installed Mercury libraries:
`mercury_ds` and `mercury_ds_runtime`. From the repository root, `mercury.mk`
builds and installs both (`README.md`'s "Building" says what it needs):

    make -f mercury.mk all mercury

That installs the runtime into `.build/mercury/prefix/` and the binding into
`.build/mercury_ds/prefix/`. A program then builds against them, from any
directory:

    mmc --make --grade hlc.gc \
        --mld <checkout>/.build/mercury_ds/prefix/lib/mercury \
        --mld <checkout>/.build/mercury/prefix/lib/mercury \
        --ml mercury_ds --ml mercury_ds_runtime <your program>

That links shared. A static link adds `--mercury-linkage static --library re2
--library stdc++`: the runtime's archive carries its own foreign code, but
not RE2 or libstdc++. A program imports `ds` before any `ds.*` module it
names.

`scripts/mercury/check.py` builds the test program, the harness and the differential's
driver exactly so, shared, and the harness statically too. A DS program is
compiled to a `.dsc` by `dsc`, the DS compiler.

## The harness

`examples/harness.m`, over `examples/harness.ds`, is the integration example:
one program that exercises every feature of the binding, stage by stage, and
prints each call and what it returned. Read it top to bottom; read its output
beside it. The gate builds and runs it, and fails if it stops short of
`harness: OK` or leaves an exported call unused.

## Checks

The binding's check installs the runtime's and the binding's
libraries, builds the test program and the harness against them, and runs
both. It also holds the binding to
its style canon (`MERCURY_STYLE.md`) and its coverage of `libds.h`
(`coverage.tsv`).

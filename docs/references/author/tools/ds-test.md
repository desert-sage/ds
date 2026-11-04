<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# `ds test`

## The command

### `ds test`

**`ds test [-L DIR]... [--program PROG.ds] FILE...`**

Runs the test cases in each `.ds`, `.dstest` or `.dsc` file on libds, and reports pass or fail per case. A test case is a [`test`](dstest.md#test) the artefact carries. `ds test` is a form of [`ds`](dsdb.md#the-ds-command).

| Option | Value | Meaning |
|---|---|---|
| `-L`, `--search-path` | a directory | adds a directory to the search path, and repeats |
| `--program` | a `.ds` | the program a library's tests run under |
| `-h`, `--help` | none | prints the usage |

A `.ds` compiles with its own directory, then each `-L` directory, on the [search path](../lang/imports.md#search-path). Each program compiles once, and each case runs once however many files name it.

```text
ds test -L lib rules.ds
```

*(Spec: [RTIM.8.1.1], Source: tools/dsdb/lib/cli/main.js)*

### Which cases run

| FILE | Runs |
|---|---|
| a `.dsc` | every case it carries |
| a `.ds` that is a program | every case it carries |
| a `.dstest` beside a program of its stem | that program's own module's cases |
| a library `.ds`, or a `.dstest` beside one | that module's cases, under the program below |

A library's tests run under `--program`, or with no `--program`, under the one program in the library's directory that imports it.

A file with no case to run is refused and the files after it still run, for any of:

- a `.dstest` with no `.ds` of its stem beside it;
- a file that is no `.ds`, `.dstest` or `.dsc`;
- a `.ds` that does not compile;
- a library that `--program` does not import;
- with no `--program`, a library that no program, or more than one, in its directory imports;
- a file whose run carries no test case.

*(Source: tools/dsdb/lib/cli/main.js)*

### Report

On standard output:

- each case's line, `[PASS] "name"` or `[FAIL] "name"`;
- under a failed case, indented, each failure and each assertion that did not hold, with what it wanted and what the run observed, then each fault event the case's engine raised, in stream order;
- a line naming the files ahead of a program's cases, when more than one program runs or the file is not the program itself;
- the last line, `ds test: P/N cases passed`, or `ds test: no case ran` with no case run.

A fault line is `<Kind> at T=<seconds>s[ in rule <rule>]: <cause>`, at the mock-clock instant of the step that raised it, naming the rule whose activation it abandoned where the event names one.

| Kind | Cause |
|---|---|
| [`ComputationError`](../errors/fault-facts.md#computationerror-fact) | its kind, `DIVIDE_BY_ZERO`, `DOMAIN` or `NOT_REPRESENTABLE`, then `at <schema>.<slot>` where the event names one |
| [`TypeError`](../errors/fault-facts.md#typeerror-fact) | `<schema>.<slot>`, or `a value` where the event names neither, then `, given <actual>` where it names the value's kind |
| `BoundsError` | the cap, with its limit and the observed value |
| `EngineError` | the engine fault |

A fault fails no case by itself, and a passing case's report shows none.

```text
    ComputationError at T=5.000s in rule divide: DIVIDE_BY_ZERO
```

A refused file goes to standard error, prefixed `ds test:`.

*(Spec: [RTIM.8.1.1], [RTIM.14.16], [NCBK.2.8], Source: tools/dsdb/lib/cli/main.js, tools/dsdb/lib/text/dstest.js, tools/dsdb/lib/core/dstest.js)*

### Exit status

| Status | Meaning |
|---|---|
| `0` | every case of every file passed, or help was asked for |
| `1` | a case failed, or a file did not compile, had no program to run under or held no test case |
| `2` | a usage error: no FILE, an unknown option or an option with no value |
| `4` | a file that cannot be read, or `@ds-lang/ds` not installed |

*(Source: tools/dsdb/lib/cli/main.js)*

## Verdicts

### Fresh engine

Each case runs on a fresh engine, on the [mock clock](inv:integrator:std:doc#engine/clock). State does not pass between cases.

*(Spec: [RTIM.14.2], [RTIM.14.3])*

### Deterministic clock

Every time-dependent operation reads the one clock, including `now()`, timer firings, TTL expiry and window bounds. Moving the clock by an interval fires what would have fired in that interval on a real clock, and the engine finishes that cascade before the move completes. The engine consults no wall time for a language-level decision under the mock clock.

*(Spec: [LTES.3.2.1], [LTES.3.2.4], [LTES.3.2.5], [LTES.3.3.1])*

### Refused step

A cache seed, an arrange or input assertion, a reply's assertion, a clock move or a pump that returns anything but success fails the case, naming the operation and its status, whether or not the engine halted. The case is driven no further: no later instant and no later reply. Assertions over what was observed until then may be reported, and the case does not pass on them.

*(Spec: [RTIM.14.14])*

### Unreadable test atom

A test atom whose body does not decode refuses the run with `DS_ERR_DSC_DECODE`, and one that names something no atom in the artefact defines with `DS_ERR_DSC_DANGLING`. No case runs, and the refusal names the atom.

*(Spec: [RTIM.14.15])*

### Unknown assertion

A case fails when the interpreter evaluated fewer oracle atoms than the artefact carries for it, naming the unrecognised atom. A `Test*` or `Oracle*` atom with a field the interpreter does not know fails its case, naming the atom and the field's number.

*(Spec: [RTIM.14.9])*

### Equality

A literal and an observed value compare by [Exact value match](dstest.md#exact-value-match), in every head, stub key and `cached` value. A `Float` matches exactly.

*(Spec: [LTSL.4.3], [RTIM.14.7])*

### Outside a test

A runtime's load skips the test atoms, and an artefact that carries them costs only its file size.

*(Spec: [LTES.7.6])*

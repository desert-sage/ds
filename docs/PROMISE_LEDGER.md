<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The Mercury promise ledger

Every `promise_pure`, `promise_semipure`, `promise_equivalent_solutions`,
`promise_equivalent_solution_sets`, `promise_only_solution`, `impure`,
`semipure`, `cc_multi`, `cc_nondet` or `foreign_proc` in the Mercury runtime
or compiler stands for a claim the Mercury compiler cannot verify. The target
is zero, with six sanctioned modules: five in the runtime and one in the
compiler. Nothing else earns an exemption by analogy.

The Implementer keeps this inventory; the Logician owns the justification of
each promise.

## The grep

The ledger is what this prints, run from the repository root:

```
git grep -nwE 'promise_(pure|semipure|equivalent_solutions|equivalent_solution_sets|only_solution)|impure|semipure|foreign_proc|cc_multi|cc_nondet' \
    -- 'runtime/mercury/*.m' 'runtime/mercury/*.m.in' 'compiler/mercury/*.m' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*%'
```

The second `grep` drops comment lines. Every line left must be a
`foreign_proc` below, or its `promise_pure` attribute, or the one
`promise_equivalent_solutions` `dsc.cli` is sanctioned for. A line anywhere
else is a promise with no sanction.

## The sanctioned modules

Each `foreign_proc` listed is `promise_pure`, `will_not_call_mercury` and
`thread_safe`. Each module also has one `foreign_decl`, holding the C its
procedures call; `ds.platform`'s is `local` and defines its functions there.

### `ds.re2`

RE2's own specification is the regex language ([LREG.8.1]), so validity,
captures and matches come from RE2, through libds's shim
(`runtime/src/libds/ds_re2.h`) at the `deps.lock` pin. A compile is a function
of pattern and flags, a match of pattern, flags and text; nothing is kept
between calls.

- `foreign_compile`
- `foreign_matches`
- `foreign_capture`

### `ds.chrono`

Nanosecond time is a requirement. The read is
`clock_gettime(CLOCK_MONOTONIC)` and `clock_gettime(CLOCK_REALTIME)` back to
back in one call, as libds's `clock.c` reads them, because [LTIM.2.8.4]
samples the two together. It is sequenced by `io` and is also
`tabled_for_io`.

- `both_clocks_ns`

### `ds.float_text`

Float to shortest text is Dragonbox and text to Float is fast_float, vendored
under `vendor/` and shaped by libds's `float_fmt.c`. libds, this runtime and
the compiler share one implementation ([LDET.3.3a.8]).

- `foreign_canonical`
- `foreign_fixed`
- `foreign_parse`

### `ds.core_math`

The transcendentals are INRIA's CORE-MATH at the `vendor/source.lock` pin,
compiled as libds compiles it, so both runtimes call one correctly rounded
function. A call sets round-to-nearest-even and restores the caller's mode
([LDET.3.6.1]). The compiler's `const` folder imports the module and declares
no promise of its own.

- `exp`, `ln`, `log2`, `log10`
- `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`
- `sinh`, `cosh`, `tanh`
- `pow`
- `fma`: CORE-MATH has none, so it is libds's own ([IARC.7.14]): musl's at
  `vendor/source.lock`'s `[musl]` pin, compiled under the private name
  `ds_libm_fma` by `libds.build`'s `Libm` rows and `mercury.build`'s
  `MercuryLibm` rows alike, never the C library's.

### `ds.platform`

The platform signature's build facts ([LDET.2.3]): OS family, CPU
architecture, libc and C compiler, answered by the preprocessor tests libds's
`platform.c` makes. Each is a constant of the build. `dsdev mercury verify
platform` holds the copy to libds's answer, field by field.

- `os_family`
- `cpu_arch`
- `libc`
- `compiler`

## The compiler

The compiler (`compiler/mercury`) declares no promise but these; the grep
covers it.

### `dsc.cli`

[RCLI.3.1] makes exit `3` an internal
compiler error: a compiler that cannot finish must exit `3`, say why on
standard error, and leave no artefact. Two of the ways it stops are outside
Mercury, and the third needs a commitment Mercury cannot verify, so the
command line's entry point, `rcli_3_1_run`, holds every promise the compiler
makes. Its header says how the three fit together.

- `promise_equivalent_solutions [Result, !:IO]` around `exception.try_io`,
  in `rcli_3_1_run`. `try_io` is `cc_multi` because its declarative semantics
  admits `exception(_)` as a solution beside `succeeded(_)` whatever the goal
  does, and only its operational semantics picks the one the goal reached;
  which exception a goal throws can also depend on evaluation order, since
  the compiler may reorder the pure conjuncts of a `det` goal and drop one
  whose result is unused. So `det` gives `run` one *result*, not one
  solution of `try_io`, and the promise does not claim uniqueness. It claims
  that the program's behaviour does not depend on which solution is taken:
  `rcli_3_1_run` maps every solution to one of three outcomes [RCLI.3.1]
  admits, and nothing else reads `Result`. `succeeded(Status)` is the status
  `run` computed; `exception(E)` with `E` an `io.error` is `2`, a path that
  could not be written, the file being written removed; any other exception
  is `3`, the file removed. The reason written to standard error is the
  exception's text and is not a contract observable. Two different
  exceptions in one invocation, one per evaluation order, need a compiler
  defect and a failed write together; `2` and `3` are then both faithful to
  the clause, and the promise is kept up to that coincidence. `!:IO` is
  unique by construction.
- The `foreign_proc`s, each `promise_pure`, `will_not_call_mercury` and
  `thread_safe`, and each sequenced by `io`:
  - `rcli_3_1_install_exit_hooks`: `atexit` for an exit the runtime takes
    before `run` returns (`MR_fatal_error`, the wasm32 grade's "heap
    overflow"), and Boehm's `GC_set_oom_fn` on the grades that have Boehm,
    for an exhausted heap. Both end the process with `_exit(3)`.
  - `rcli_3_1_finished`: `run` returned; the exit hook stands down.
  - `rcli_3_1_writing`, `rcli_3_1_written`: the output file being written,
    which a compiler that stops removes.
  - `rcli_3_1_abandon_output`: remove it, from the exception path.

  The module has one `foreign_decl`, `local`, and one `foreign_code` holding
  the hooks and the path they read. Nothing in a hook allocates, since one of
  them runs because allocation failed. The process-wide state is that path,
  the finished flag, and the two hooks `rcli_3_1_install_exit_hooks` arms
  once; only these procedures touch them, every call is ordered by `io`, and
  the compiler is single-threaded, which is what `thread_safe` rests on.

  The bounds, stated beside the claim. The hooks cover an exit the runtime
  takes through `exit` and Boehm's exhaustion; an end by signal runs no
  `atexit` hook, so a C-level fault in the compiler ends with the signal's
  status, outside [RCLI.3.1]'s `3`, and so does an exit before
  `rcli_3_1_run` arms the hooks (the few calls `dsc_cli.main` makes first).
  The path buffer holds 4096 bytes, which excludes no path a hosted row can
  open: every hosted row's `PATH_MAX` is at most that, so a longer path is
  refused by the OS before any byte is written and there is no artefact to
  remove. Standard output already flushed cannot be retracted; `_exit` drops
  what the C library still buffers, and every subcommand writes its output
  after computing it.

  Each hook is shown to fire on every run: Boehm's by `test_cli.m`'s
  `cases_internal_error` in the `compiler` gate, under a 2 MB heap cap, with
  an uncapped control that must compile; the exit hook by
  `scripts/private/lanes/js_dsc_gate.mjs`'s `overflow` case, on the wasm32 build past its
  fixed heap, which also fails when the heap comes to hold the program. The
  `try_io` exception arm has no fixture: no phase of `dsc` throws.

## Outside the runtime and the compiler
- **`mercury_ds`** (`bindings/mercury`) declares none, and its own gate
  refuses any (`scripts/mercury/check.py`, MER.6).

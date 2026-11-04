# vendor/ — vendored third-party libraries

Source dependencies libds needs to build. Vendored in-tree because DS is an
independent language implementation with its own build stack.

**This directory is one of TWO vendoring mechanisms, and "vendored" means both.**
Here the source is *committed to this repository* as a snapshot. The other is
`deps.lock` and the build that reads it, where the source is
*fetched at a pinned digest*, verified, built and installed into the store —
Abseil, RE2, protobuf and protobuf-c reach `libds.a` that way. A dependency's
bytes end up inside `libds.a` under either mechanism; what differs is whether
this repository carries the source or a pin to it.

Say which mechanism, not just "vendored". Reading the word as meaning only this
directory is what produced the claim that *"RE2 and Abseil are not vendored"* —
they are, by the other mechanism, and that claim was cited as precedent for a
third dependency before anyone noticed.

## Contents

| Dir           | Source       | Role                                                    |
|---------------|--------------|---------------------------------------------------------|
| `protobuf-c/` | protobuf-c   | DSC-artefact decode (RDSC §12); cold load path only, per IARC.7.4 |
| `dragonbox/`  | Dragonbox    | `Float` → shortest text ([LDET.3.2.7]); `to_chars_n` with the compact cache |
| `fast_float/` | fast_float   | text → `Float`, correctly rounded ([LDET.3.2.8]) |
| `core-math/`  | CORE-MATH    | the correctly rounded transcendentals and `**` ([LEXP.3.9.1], [LEXP.7.3a]); the 22 files libds compiles, at the pin in `source.lock` |
| `musl/`       | musl libm    | `fma` and the `scalbn` it calls, libds's own on every row ([IARC.7.14]), renamed `ds_libm_*` at compile time; `fmin`, `fmax`, `round`, kept for the post-v1 microcontroller rows; the 6 files at the pin in `source.lock` |
| `softfloat/`  | Berkeley SoftFloat | the IEEE reference [NDET.1.4]'s double-backend check compares a row's doubles against; f64, f32 and the integer conversions, the files at the pin in `source.lock`; compiled into the check, never into `libds.a` |
| `testfloat/`  | Berkeley TestFloat | that check's case generator and verifier, `testfloat_gen` and `testfloat_ver`, with DS's own subject between them; the files at the pin in `source.lock`; compiled into the check, never into `libds.a` |
| `ucd16/`      | Unicode 16.0 UCD | the character data the compiler's identifier tables (`dsc.unicode.m`) are generated from, and `NormalizationTest.txt` for its NFC tests; not compiled into `libds.a` |

## Source commits

- **Dragonbox 1.1.3**, Junekey Jeon, built on Giulietti's Schubfach — shortest
  round-trip digits, nearest with ties to even.
  The release <https://github.com/jk-jeon/dragonbox/releases/tag/1.1.3>,
  unmodified: `include/dragonbox/dragonbox.h`,
  `include/dragonbox/dragonbox_to_chars.h` and `source/dragonbox_to_chars.cpp`.
  License: **Apache-2.0 with LLVM Exceptions OR BSL-1.0**, both texts kept
  verbatim. libds calls only `to_chars_n` with `policy::cache::compact`, from
  `runtime/src/libds/float_text/float_shortest.cc`, which #includes the source
  file so the library is one object. C++17; it allocates nothing and references
  no C++ runtime. ⚠ `dragonbox.h` declares `template <int N>`, so a `-DN=…`
  reaching that unit breaks it.
- **fast_float 8.3.0**, Daniel Lemire et al., the Eisel–Lemire algorithm
  (*"Number Parsing at a Gigabyte per Second"*, Software: Practice and
  Experience, 2021) with an exact fallback. The single-header release asset
  <https://github.com/fastfloat/fast_float/releases/tag/v8.3.0>, sha256
  `f23d93a4d1adf052e7b50e2a55ac54feeef91e188b71d35ae3038597e2659b90`, and
  `LICENSE-MIT` from the same tag. License: **MIT** (offered as MIT OR
  Apache-2.0 OR BSL-1.0; this tree takes MIT). C++, but it references no C++
  runtime: compiled with `g++ 14.2 -std=c++17` it needs only `memmove`,
  `memset` and `__assert_fail`.
- **CORE-MATH**, INRIA's correctly rounded `binary64` functions, at commit
  `6b84457310ad90b644b3335af2faa8c7301e1c47`, the one the eligibility probe
  measured. License: **MIT**; the upstream `LICENSE` is kept at
  `core-math/LICENSE` and every file keeps its own header. The 22 files libds
  compiles are **committed** under `core-math/`, at their upstream paths,
  unmodified, the `exit(1)` branches included.
  `source.lock` is the provenance record: the commit, each
  file's sha256 and the compile flags ([IARC.7.10]). `DIGESTS` repeats the
  digests so `vendor-digests` holds the bytes, and a pin test holds
  `DIGESTS`, the lock and the tree to one another. Nothing fetches them at
  build time.

  **Why committed.** They were fetched by the build from the commit's raw
  URLs, and gitlab.inria.fr sits behind a bot proxy (Anubis) that answers some
  automated GETs with an HTML refusal page: cold builds failed at random, on a
  different file each time, and more builders made it worse. The snapshot was
  taken once and checked against the lock's digests. A refresh is the same: move the pin in `source.lock`, take the
  snapshot, rewrite `DIGESTS`, in one commit.

  Built with clang or gcc on the hosted rows. The eligibility probe's 128-bit
  portable layer was its Xtensa track, and DS ships no Xtensa row.
- **`DIGESTS`** holds the sha256 of every file under `dragonbox/`,
  `fast_float/`, `core-math/`, `musl/`, `softfloat/` and `testfloat/`, and the
  `vendor-digests` check runs `sha256sum -c` on it, so an edit to a snapshot
  fails the check. These six snapshots are therefore enforced, not merely
  recorded; protobuf-c above is not yet.
- **musl's libm**, at commit `c4e1bb3994c14ed5112c894d15a451bf00f0d501`, the
  one the board probe took `fma` from. License:
  **MIT**; musl's `COPYRIGHT` is kept at `musl/COPYRIGHT`. The six files are
  **committed** under `musl/`, at their upstream paths, unmodified, as
  CORE-MATH's are and for the same reason: a build that fetches from a
  third-party server fails whenever that server refuses it. They are
  pinned as `[musl]` in `source.lock`, beside CORE-MATH, because every libds
  build compiles two of them; `DIGESTS` repeats the digests, and a pin
  test holds `DIGESTS`, the lock and the tree to one another. A refresh moves the
  pin, takes the snapshot, and rewrites `DIGESTS`, in one commit.
  **`src/math/fma.c` and `scalbn.c`, every row** ([IARC.7.14]):
  `libds.build`'s `Libm` rows compile them unmodified with the lock's
  flags, against `runtime/src/libds/mcu_libm/atomic.h`, renaming `fma` and
  `scalbn` to `ds_libm_fma` and `ds_libm_scalbn` at compile time, and the
  Mercury runtime and `dsc` compile them the same way (`mercury.build`,
  `runtime/docker/release.build`). `math.fma` and CORE-MATH's calls to `fma`
  reach `ds_libm_fma`, never the integrator's C library, which not every libc
  rounds once. **`fmin.c`, `fmax.c` and `round.c`** are kept for the
  microcontroller rows, which are post-v1 and have no build: on a soft-double
  target they are otherwise the integrator's C library's.
- **Berkeley SoftFloat and TestFloat**, John R. Hauser's (University of
  California), release 3e, at upstream git's commits
  `497c81c1f5016dc6ef5b3219ece2f3c261d4d8f1` (ucb-bar/berkeley-softfloat-3)
  and `a9c849f1b0eb0264b626d9686ffae167d996e3be` (ucb-bar/berkeley-testfloat-3),
  each default branch's when pinned; upstream tags no release. License:
  **BSD-3-Clause**; each tree's `COPYING.txt` is kept. They are the part 1 of
  [NDET.1.4]'s admission evidence that `docs/steering/TESTING.md` defines —
  TestFloat level 2, round to nearest even, against SoftFloat — which binds the
  hosted 1.0.0 rows. **Neither reaches `libds.a` or
  any shipped artefact**: the check compiles them into upstream's
  `testfloat_gen` and `testfloat_ver` and pipes the one into the other through
  DS's own subject, the operations as libds compiles them, linked against the
  row's `libds.a`. **What is committed is what those two programs compile**,
  derived from their links by `ci/testfloat_files.py`, never hand-picked: f64,
  the f32 code the generic generator and verifier carry, the integer
  conversions, SoftFloat's 8086-SSE specialisation, and none of the f16,
  bf16, extF80 or f128 code. Upstream's in-process `testfloat`, its `subj-C`
  subject and its build directories' `platform.h` are not taken; DS supplies
  its own subject and `platform.h`. **Committed**, unmodified, at
  their upstream paths, as CORE-MATH's and musl's are: `source.lock`'s
  `[softfloat]` and `[testfloat]` are the provenance, `DIGESTS` repeats the
  digests, and the pin tests hold the three together. A refresh moves the
  pins, re-derives the set with `ci/testfloat_files.py`, takes the snapshot
  with `ci/vendor_snapshot.py`, and rewrites `DIGESTS`, in one commit.
- The `t-digest-c/` snapshot was removed in PROBRM1q when the approximate
  sketch backends were dropped from the v1 exact-only series model.
- The `libobserve/` snapshot was removed as dead scaffolding — it had no live
  call sites (see
  [`../docs/specs/proposals/RFC_remove_libobserve.md`](../docs/specs/proposals/RFC_remove_libobserve.md)).

## Rules

- These trees are **vendor snapshots**, not an active fork. We do not hack on
  them in-tree.
- Refresh is a deliberate bump commit: copy a newer snapshot in, record the new
  source SHA here, note any local patch we had to carry.

<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# The committed fuzz corpus

Read by the `fuzz-dsc` lane, which declares it as an input. Everything here is
fed to both phases of the lane: the time-boxed SEARCH, and the deterministic REPLAY that a ratchet can
key on.

## What belongs here, and what does not

**Does not:** ordinary seeds. Those are *compiled in the gate* from the
conformance corpus's `rules_ds` bodies — every fixture whose `expect.kind` is
`compile_ok`, 675 of them at the time of writing. They are byte-reproducible
from committed source through a pinned compiler, so committing them would carry
binaries that a build already derives. Do not add a `.dsc` here that a compile
would produce.

**Does:** inputs no compile can reproduce.

1. **`regress_*.dsc` — crash and leak reproducers.** A defect that a randomized
   search found once is a defect nobody can reproduce on demand. Committing the
   input converts it into a deterministic REPLAY failure that stays failing
   until the fix lands, and then guards the fix afterwards. This is the only
   mechanism that makes a fuzz finding behave like a regression test.
2. **`merged_*.dsc` — `-merge=1` survivors.** Coverage-increasing mutants from
   past runs, so a new run starts where the last one ended instead of
   re-deriving the same ground inside every 60-second budget. Tracked as
   FUZZMAX1c; none are committed yet.

## Current contents

| file | bytes | why |
|---|---:|---|
| `regress_retesegv1.dsc.b64` | 871 | **RETESEGV1** *(fixed)* — SEGV via an uninitialised `pb_len` output reaching `strndup`; the `0x80` read was stale stack garbage, not `decode_expr` recursion |
| `regress_retesegv1_stack.dsc.b64` | 858 | **RETESEGV1**, second reproducer *(fixed)* — the **same** defect, a different stale value in the same slot. Not a second bug, and not stack exhaustion: `EXPR_MAX_DEPTH` is 48 and every recursive call honours it |
| `regress_reteleak1.dsc.b64` | 604 | **RETELEAK1** *(fixed)* — 64 bytes per **successful** load; the term cleanup's success branch freed the action array but not each action's `assigns`. Its one alpha test reads the candidate fact, which the capture marked as compilers then did, `pattern_index` 0xFFFF; [RDSC.4a.9.1] made the marker 255 and refuses past it, so the load stopped short of the success path the pin is for. That VarExpr is re-encoded to 255 (`08 ff ff 03` → `08 ff 01`, and each length around it one less); every other byte is as captured. It is here and not in `_restamp_pinned` because the marker sits inside an expression tree, and the tooling does not decode one. The compiled seeds whose programs emit with slots take the same path; this row is the capture that leaked, and stays the guard that does not depend on what the corpus happens to compile |
| `regress_dscrash1.dsc.b64` | 612 | **DSCRASH1** — found by SEARCH once the inputs above stopped masking it. **Cause not yet diagnosed**; pinned so it fails on demand rather than when a randomized search happens to rediscover it. It stops at its first deformation in stream order, a TerminalNode body at 489 that does not decode, which both runtimes refuse in the walk. Its malformed frame after that is no longer reached; no stack trace from the capture survives to say which of the two it crashed in |
| `regress_dscrash1_frame.dsc.b64` | 563 | **DSCRASH1**, derived — `regress_dscrash1.dsc` with its one TerminalNode frame, bytes 481–529, removed and every other byte kept, so the walk passes where the original now stops and reaches the malformed frame after it, as the original did before the walk refused it. Together the two rows reach both places DSCRASH1 could have crashed in. Not a compiler output: no compile writes a malformed frame |

The fixed rows stay. A pinned input that has stopped faulting is the guard
for the fix — deleting it is how the defect comes back unnoticed. The
descriptions are corrected to what each turned out to be, because three of the
originally pinned four described a mechanism that was not the one at fault.

**Retired: `regress_reteoom1.dsc.b64`.** RETEOOM1 was a
`malloc(2 GiB)` in `pir_loader.c`, which left with the portable IR (PIRRET1);
libds now skips the atoms that input deforms. A guard for code that no longer
exists can only ever pass, so it is gone rather than kept. It is in git
history if the IR ever returns.

## Each input is brought up to today's format rules when it is materialised

**A pinned input is only a guard if libds reads as far as its defect.** These
were captured with `compiler_version` "0.0.0". Once the fuzz archive was
version-stamped, libds refused each at [LDET.1.10] in the first atom (-502),
so for weeks none reached the defect it pins, and REPLAY — which sees only
crashes and leaks — could not tell that from fixed defects. Re-stamping
the header was not enough: four then stopped at the next rule, a SchemaLogical
`lifecycle` the captures predate ([RDSC.5.4.5]).

So `_seed_fuzz_corpus` rewrites, on the way in (`_restamp_pinned`), only what a
format rule newer than the capture refuses: `compiler_version` becomes the
archive's own version; `dialect_def_sha256` becomes 32 bytes if it is not
([RDSC.3.7]); an empty CapabilityInfo follows the DscHeader if the input has
none ([RDSC.16.2.4]); and a SchemaLogical with no `lifecycle` gets LOGICAL,
which is what a SchemaLogical atom meant when these were captured. A field that is present is never
changed, and nothing past the first malformed frame is touched, so the
deformation the pin is for is as captured. The committed `.b64` is unchanged.
The fuzz-dsc log says, per input, what was rewritten.

Then `_fuzz_pinned_verdicts` loads each one alone, prints where libds stopped —
a `PINNED:` line with the status and libds's detail, or `crash` — and **fails
the lane if any input stops anywhere other than where `verdicts.txt` records**,
or is refused at the header. A new rule, a minor bump, or a defect fixed or
undone moves a verdict and turns the lane red; none can disarm a pin silently
again. Re-record a row only for a reason the commit states.

## Why base64, and not the bytes

**Tracked `.dsc` are banned repo-wide by `.gitignore`.** A compiled artefact is
a build output and is never committed.

These reproducers are the opposite kind of object. They are deliberately
malformed **inputs to the loader under test** — bytes no compiler would emit —
pinned because those exact bytes crashed it. There is no source to recompile
from and there must not be one: regenerating them destroys the thing that makes
them valuable.

So they are stored as base64 text and materialised at run time by
`_seed_fuzz_corpus`, which keeps them out of any `git ls-files '*.dsc'`
population rather than carving an exemption into the ban.

Keep the `.dsc.b64` suffix. The materialised name drops only `.b64`, so what the
fuzzer loads is what every log, todo and note already calls it.

All of them are mutated real bundles: a `Sensor` schema with a `trig` rule,
whose structure the fuzzer deformed. They exist only because `c87c1c914` made
the lane base64 its artifacts into the run log — the run's clone is deleted on
failure, so an earlier run's reproducer for RETESEGV1 was lost outright.

**Two rows still pin one todo, and that is now a settled fact rather than an
open question.** `regress_retesegv1.dsc` and `regress_retesegv1_stack.dsc` were
kept separately because one faulted near NULL and the other at a stack-shaped
address, and nobody could tell whether that was one defect or two. It was one:
the same uninitialised `pb_len` output holding different stale values. Both
stopped faulting on the same fix.

Keeping both is still right. The reason has changed from "these may be two
bugs" to "one defect reached this code by two routes, and a future regression
might restore only one of them".

**These files make `fuzz-dsc` REPLAY fail, deliberately.** That is not a lane to
work around. When each defect is fixed, its input stops faulting and stays here
as the guard.

## Adding a reproducer

The lane prints each artifact as base64 (`_dump_fuzz_artifacts`), because the
run's clone does not survive to be copied from. Decode that into
`regress_<todo-id>.dsc`, name it for the todo it pins, and add a row above
saying what it reproduces, and a row in `verdicts.txt` saying where libds
stops on it (the lane prints the line to copy). A file here without a row is
an input nobody can explain, which is worse than no file: the next person cannot tell a pinned
defect from a stray byte string.

## Size discipline

Keep it small and bounded. A corpus that grows without limit becomes a slow
lane that people skip, and a skipped lane finds nothing. Minimize before
committing (`-merge=1` keeps only what adds coverage), and prefer the smallest
input that still reproduces.

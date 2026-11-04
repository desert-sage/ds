#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""ds-version.py [root] [--clean] — emit the canonical DS version string.
ds-version.py [root] --write-header FILE | --check-header FILE

The second form writes, or checks, libds.h's compile-time version: the block
between HEADER_BEGIN and HEADER_END, DS_VERSION_MAJOR, _MINOR, _PATCH and
_STRING, all from VERSION in the clean form. The release cut
writes it in the commit that bumps VERSION, and the `version` gate checks it,
so the header carries VERSION and no literal of its own. `--check-header`
exits 1, naming what differs.

Python port of the retired ds-version.sh (SPY1). The BASE version is the
committed VERSION file at the repo root — the ONE source of truth (robust; not a
fragile git tag, which `git describe` would happily read from an unrelated tag
like a docs-book tag). Two forms:

  --clean   the release/distribution version, VERSION verbatim   e.g.  0.10.0
            (used for artifact filenames, wheel/package versions, image tags)
  (default) the build-provenance version, VERSION + git HEAD sha  e.g. 0.10.0+16f9feed
            (embedded in binaries — libds's DS_LIBDS_VERSION macro, pyds's
            __version__ — so a binary states its release AND exact commit)

The provenance suffix is the short HEAD sha only: it is present on the shallow
(--depth 1) clones every build uses, whereas a commit COUNT is not (rev-list on a
shallow clone is truncated), so counting would report a wrong, non-reproducible
number — exactly the drift this file exists to prevent.

Fallbacks: no VERSION file -> empty (callers keep platform.c's "0.0.0+dev"
default); VERSION present but `root` is no repository of its own (no `.git`
there: an unpacked source bundle) or there is no git -> the bare VERSION
(release form). A repository ENCLOSING `root` is never asked: a bundle unpacked
inside someone's own project would otherwise state that project's commit.

This is the ONE derivation; every consumer execs it, so the rule lives in exactly
one place.
"""
import re
import subprocess
import sys
from pathlib import Path

# libds.h's generated block, bounded by these two lines and nothing else.
HEADER_BEGIN = ("/* -- The version, generated from VERSION by scripts/build/ds-version.py "
                "--write-header. Edit VERSION, never these lines. -- */")
HEADER_END = "/* -- End of the generated version. -- */"

# VERSION's shape: three numbers, as semver and PEP 440 both read a release.
_RELEASE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def derive(root: str = ".", clean: bool = False) -> str:
    """The version string for repo `root`. Empty when there is no VERSION file."""
    version_file = Path(root) / "VERSION"
    try:
        base = version_file.read_text().strip()
    except OSError:
        base = ""
    if not base:                       # no VERSION -> empty; callers keep the default
        return ""
    if clean:
        return base
    # Provenance form: base + short HEAD sha (git-optional; tag-independent).
    #
    # `-c safe.directory=*` IS LOAD-BEARING (VERSHA1). Every release step runs in
    # a container as root over a bind-mounted, host-owned clone, so plain git
    # refuses:
    #
    #     fatal: detected dubious ownership in repository at '/ds'   (rc 128)
    #
    # This function swallowed that — non-zero rc, empty stdout, and the `if sha`
    # below silently returned the RELEASE form. So `0.10.0+d0d6f57` degraded to
    # `0.10.0`, which is a valid-looking version, and the degradation was
    # invisible: the failure output is indistinguishable from success.
    #
    # It was not cosmetic. This value becomes `DS_LIBDS_VERSION` inside libds.a
    # and `pyds.__version__`, and the docstring above promises a binary "states
    # its release AND exact commit". Every shipped binary stated the release
    # twice. RELPROV1's provenance file inherited it, and RELREPRO2's
    # same-commit guard would have compared "0.10.0" with "0.10.0" and passed
    # vacuously — on exactly the tagged builds it exists to protect.
    #
    # Per-invocation, not `git config --global`: `rev-parse` runs no hooks, so
    # this widens nothing, and the coordinator already does the global form.
    sha = ""
    # ONLY `root`'s OWN repository. `git -C root` walks up to the nearest
    # enclosing one, so a source bundle unpacked inside another checkout (a
    # user's own project, or a release clone) stamped THAT repository's commit
    # into its libds, as a valid-looking provenance version. `root` is the tree
    # VERSION sits at, so a clone or a worktree of it has `.git` right here (a
    # directory, or a file in a worktree); a bundle has none, and takes the
    # release form without asking git at all.
    if not (Path(root) / ".git").exists():
        return base
    try:
        # `--short=9`, NOT bare `--short` (VERSHA3). Bare `--short` sizes the
        # abbreviation PER REPOSITORY — object count and `core.abbrev` — so the
        # same commit renders differently in two clones. Measured, twice: the
        # coordinator's ephemeral clone against a build host's synced checkout
        # gave `0.10.0.63ac3bc` and `0.10.0.63ac3bca9`, seven hex against nine,
        # on all four container rows of one release.
        #
        # That is this file's own failure mode. Its docstring promises a binary
        # "states its release AND exact commit", and two renderings of one commit
        # make the promise depend on where the string was produced —
        # a gate had to DECLINE an equality assertion between the build's
        # provenance and the coordinator's derivation because of it, printing
        # both side by side instead and enforcing only the shape.
        #
        # WHY 9 AND NOT 8, measured rather than assumed. `git rev-parse --short`
        # in this repository returns NINE characters today: `core.abbrev` is
        # unset, so git sizes from the object count — 7,654 loose + 115,738
        # packed = 123,392 — and 8 would put the expected number of colliding
        # prefixes across that set at roughly 1.8, against 0.11 at 9. Git steps
        # to 9 for exactly that reason.
        #
        # So 9 is git's own answer for this repository, pinned rather than
        # recomputed. Pinning BELOW it would have narrowed every sha the project
        # has ever emitted to less than git thinks is safe, which is a strange
        # thing to do while fixing a provenance defect.
        #
        # This string is a LABEL — it lands in DS_LIBDS_VERSION, PROVENANCE.txt
        # and artifact filenames — rather than something fed back to git to
        # resolve a ref, so a collision would not break a lookup. It would make a
        # shipped binary name its origin ambiguously, which is the one thing this
        # file exists to prevent.
        #
        # ⚠ `--short=9` DID NOT PIN THE WIDTH, and the paragraph above was wrong
        # about its own fix. `--short=N` is a MINIMUM: git still guarantees the
        # abbreviation is unique in that repository, so it returns MORE than N
        # whenever N is ambiguous there. That is the same per-repository sizing
        # VERSHA3 set out to remove, merely with a floor under it.
        #
        # Measured on the 0.13.0 cut at d50e8e7e6: PROVENANCE.txt read
        # `0.13.0+d50e8e7e6` on glibc-amd64, musl-amd64, riscv64 and netbsd, and
        # `0.13.0+d50e8e7e61` on BOTH arm64 rows — one commit, two renderings,
        # decided by which objects each clone happened to hold. The "shelf life"
        # the previous comment predicted arrived, and it arrived unevenly across
        # clones, which is the failure rather than a milestone.
        #
        # So the sha is taken in FULL and truncated here. That is a function of
        # the commit alone and of nothing about the clone, which is the property
        # this file needs and the only way to get it: raising the floor to 10
        # would move the boundary, not remove it.
        #
        # Safe by the argument already made above — this string is a LABEL, in
        # DS_LIBDS_VERSION, PROVENANCE.txt and artifact filenames, never fed back
        # to git to resolve a ref. A collision would make a binary name its
        # origin ambiguously; it would not break a lookup. Nine stays the width
        # for the reason given above, now as a decision rather than as whatever
        # the local object store implies.
        r = subprocess.run(["git", "-c", "safe.directory=*", "-C", str(root),
                            "rev-parse", "HEAD"],
                           capture_output=True, text=True)
        sha = r.stdout.strip()[:9]
        if not sha:
            # LOUD. Falling back to the release form is legitimate only when
            # there is no repository — an unpacked source tarball. A git that is
            # present and REFUSING is a defect, and the whole cost of this bug
            # was that the two were reported identically.
            print(f"ds-version: git could not resolve HEAD in {root!r} "
                  f"(rc={r.returncode}): {r.stderr.strip() or 'no output'}\n"
                  f"            falling back to the release form {base!r} — the "
                  f"build-provenance sha will be ABSENT from this artifact.",
                  file=sys.stderr)
    except OSError:
        pass                          # no git at all: the documented fallback
    # `+{sha}`, with NO `g` prefix.
    #
    # `+` AND NOT `.`. `0.12.0.ed405104c` is neither valid
    # semver nor valid PEP 440: semver is three dot-separated NUMERIC
    # components, and PEP 440 requires an all-numeric release segment — so a
    # fourth dotted component makes `packaging.version.parse()` raise
    # InvalidVersion outright. Anything downstream that sorts, compares or
    # merely parses a DS version had to special-case us.
    #
    # Both standards have a field for exactly this concept and both spell it
    # `+` — semver build metadata (§10), PEP 440 local version identifier — and
    # both specify it is IGNORED FOR PRECEDENCE. That is the semantics a
    # provenance suffix actually wants: `0.12.0+abc` and `0.12.0+def` are one
    # release built twice, not two releases.
    #
    # ONLY THIS FORM MOVES. `--clean` is untouched, so artifact filenames, wheel
    # and package versions, and image tags are byte-identical — a wheel filename
    # could not carry `+` anyway.
    #
    # The `g` prefix went earlier for a related reason: it was `git describe`'s
    # convention (`v1.2.3-4-gabc1234`), this file deliberately does not use
    # describe — see the docstring — and nothing ever parsed the `g`.
    return f"{base}+{sha}" if sha else base


def header_block(version: str) -> str:
    """libds.h's generated block for a clean `version`, its two bounds included.
    Refuses a VERSION that is not three numbers: a macro an integrator compares
    with `#if` must be a number."""
    m = _RELEASE.fullmatch(version)
    if m is None:
        raise ValueError(f"VERSION {version!r} is not MAJOR.MINOR.PATCH")
    major, minor, patch = m.groups()
    return "\n".join([
        HEADER_BEGIN,
        f"#define DS_VERSION_MAJOR  {major}",
        f"#define DS_VERSION_MINOR  {minor}",
        f"#define DS_VERSION_PATCH  {patch}",
        f'#define DS_VERSION_STRING "{version}"',
        HEADER_END,
    ])


def _block_span(text: str, path) -> tuple[int, int]:
    """Where the block is in `text`: exactly one HEADER_BEGIN, then one
    HEADER_END after it, or a ValueError naming `path`."""
    begin, end = text.count(HEADER_BEGIN), text.count(HEADER_END)
    if begin != 1 or end != 1:
        raise ValueError(f"{path}: expected one generated version block, found "
                         f"{begin} begin and {end} end lines")
    start = text.index(HEADER_BEGIN)
    stop = text.index(HEADER_END) + len(HEADER_END)
    if stop < start:
        raise ValueError(f"{path}: the version block's end comes before its begin")
    return start, stop


def block_problem(text: str, version: str, where) -> str | None:
    """None if the header `text` (from `where`) carries `version`'s block,
    else what differs. The one comparison: the tree's check and the release
    rows' check of a shipped tarball's header both make it."""
    try:
        want = header_block(version)
        start, stop = _block_span(text, where)
    except ValueError as e:
        return str(e)
    got = text[start:stop]
    if got != want:
        return (f"{where}'s version block does not carry VERSION {version}:\n"
                f"--- in the header\n{got}\n--- from VERSION\n{want}")
    return None


def header_problem(root: str, header) -> str | None:
    """None if `header`'s block is the one VERSION gives, else what differs."""
    version = derive(root, clean=True)
    if not version:
        return f"no VERSION in {root!r}"
    problem = block_problem(Path(header).read_text(encoding="utf-8"), version, header)
    if problem and "does not carry" in problem:
        problem += f"\nRun: scripts/build/ds-version.py {root} --write-header {header}"
    return problem


def write_header(root: str, header) -> None:
    """Rewrite `header`'s block from VERSION, leaving the rest byte for byte."""
    version = derive(root, clean=True)
    if not version:
        raise ValueError(f"no VERSION in {root!r}")
    text = Path(header).read_text(encoding="utf-8")
    start, stop = _block_span(text, header)
    Path(header).write_text(text[:start] + header_block(version) + text[stop:],
                            encoding="utf-8")


def main(argv):
    root = "."
    clean = False
    header_mode = header = None
    it = iter(argv)
    for a in it:
        if a == "--clean":
            clean = True
        elif a in ("--write-header", "--check-header"):
            header_mode, header = a, next(it, None)
            if header is None:
                sys.exit(f"ds-version: {a} needs the header's path")
        else:
            root = a
    if header_mode == "--write-header":
        try:
            write_header(root, header)
        except ValueError as e:
            sys.exit(f"ds-version: {e}")
        return
    if header_mode == "--check-header":
        problem = header_problem(root, header)
        if problem:
            sys.exit(f"ds-version: {problem}")
        print(f"ds-version: {header} carries VERSION {derive(root, clean=True)}")
        return
    v = derive(root, clean)
    if v:
        print(v)


if __name__ == "__main__":
    main(sys.argv[1:])

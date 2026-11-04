# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""VENDOR1 — fetch, verify and build the pinned dependency set.

`vendor/deps.lock` pins the four projects whose bytes end up inside
`libds.a`: Abseil -> RE2, protobuf -> protobuf-c. This module turns a row of
that file into an installed prefix under a content-addressed store, and it is
driven by a build graph — one build-unit Step per dep, so each becomes
a Product with a digest.

## Why these are build-unit steps and not Dockerfile RUNs

`ds-check` vendors Abseil and RE2 inside its Dockerfile today, and that works,
but the dependency is then INVISIBLE TO THE STEP KEY: bumping RE2 would not
invalidate `libds.a`, because the only thing the key sees is a compiler flag
that did not change. A pin nothing can invalidate is a pin in name only.

As build-unit steps, each vendored library is an ordinary Product with a digest, so
`libds.a` Consumes it and RE2's version is part of `libds.a`'s identity — which
is the property that makes [LREG.7.1] ("RE2 IS DS's regex") checkable rather
than aspirational.

## The store, and the mistake it is copied from

`/ds-cache` is ONE host directory mounted into every image, and for as long as
a libds archive store keyed on (sources ⊕ knobs), an archive built by jammy's
gcc 11.4 answered a lookup made by trixie's gcc 14.2 (LIBDSSTORE1). The same directory now serves
glibc and musl containers on the same host, so the key here carries the source
digest AND the toolchain identity AND the platform (arch + libc). Two lineages
building RE2 from identical sources produce two entries, not one race.

## Fail closed

A digest mismatch raises. There is no "warn and continue", and no fallback to
the system library — a fallback would let the build produce a `libds.a` linked
against something nobody pinned while every check downstream stayed green, which
is the exact shape of BUCASAN1 and of the `SOURCE_DATE_EPOCH` fallback that
reproduced nine tarballs stamped 1970.
"""
from __future__ import annotations

import configparser
import functools
import hashlib
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


HERE = Path(__file__).resolve().parent
LOCK = HERE.parents[1] / "vendor" / "deps.lock"

# ── what we compile FOR, where the machine name does not say it (RV64ISA1) ───
#
# `riscv64` NAMES A MACHINE, NOT A TARGET. It is what `uname -m` reports and
# what Docker calls the platform, and it says nothing about which extensions the
# object code uses. RISC-V is a family: rv64imac has no FPU, rv64gc has the
# general set plus compression, and an artifact built for one does not run on
# the other — it links, loads, and traps on the first instruction the hardware
# does not implement.
#
# Until this, nothing in the build said which one. The archives were rv64gc
# because Debian's and Alpine's riscv64 toolchains default to `rv64gc/lp64d` —
# an implicit promise resting on a distro default, in artifacts we publish for
# other people to link against.
#
# So the target is STATED. `-mabi=lp64d` is not redundant beside it: the ISA
# says the hardware has double-precision registers, the ABI says arguments are
# passed in them, and a mismatch between two objects is a link that succeeds and
# a call that corrupts.
#
# The store key needs no change: it hashes the COMMAND STREAM, so adding a flag
# re-keys every affected entry for free (`store_key`).
TARGET_FLAGS = {
    "riscv64": "-march=rv64gc -mabi=lp64d",
}


def target_flags(machine: str = "") -> str:
    """The ISA/ABI flags this machine's artifacts must state, or "".

    Empty for amd64 and arm64, deliberately: `x86_64` and `aarch64` name a
    baseline that every CPU running the build implements, so there is nothing a
    flag would add. riscv64 is the outlier because its baseline is a choice.
    """
    import platform as _platform
    return TARGET_FLAGS.get(machine or _platform.machine(), "")


# The environment overrides a cross build sets, for the four generic tool names.
# `emcc` under $CC is the same kind of statement as `aarch64-linux-gnu-gcc`, and
# a name that is not one of these four is already specific (`protoc-c`, `emar`)
# and takes no override.
_TOOL_ENV = {"cc": "CC", "c++": "CXX", "ar": "AR", "ld": "LD"}


@functools.lru_cache(maxsize=None)
def _tool_banner(argv: tuple[str, ...]) -> str:
    """One subprocess per distinct argv, cached.

    THE CACHE KEY IS THE RESOLVED ARGV AND NOT THE TOOL NAME, which is the whole
    reason this is a separate function. `tool_identity` was
    `@functools.lru_cache`d directly, and it now reads the environment — so
    keeping the cache on the name would let one `vendor.py` process building two
    lineages ask about `cc` twice and get the first lineage's compiler both
    times. A cache whose key omits an input it depends on is the store-key
    defect this change exists to fix, reproduced inside the fix.
    """
    try:
        r = subprocess.run([*argv, "--version"], capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError):
        return "(absent)"
    line = ((r.stdout or "") + (r.stderr or "")).splitlines()
    return " ".join(line[0].split()) if line else "(no version output)"


def tool_identity(name: str) -> str:
    """A tool's FULL version banner — the distro patch string included.

    `-dumpfullversion` gives `11.4.0`, which cannot tell Ubuntu's gcc 11.4.0 from
    anyone else's; the banner says `gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0`
    and can. Two archives are interchangeable only if the thing that emitted
    their object code is the same thing, and a distro patch level is part of
    that.

    THE ENVIRONMENT DECIDES WHICH BINARY `cc` MEANS, and until this followed
    `$CC` the answer was wrong for every cross build. `scripts/vendor/vendor.py`'s store key
    asks for the literal `cc`, `c++` and `ar`; a wasm build runs on an amd64
    glibc host with the host's gcc still first on PATH, so it computed THE SAME
    KEY as the native amd64-glibc build and the content-addressed store would
    hand one prefix out for the other. That is the failure `store_key`'s own
    docstring names — "one returning an entry built against a DIFFERENT Abseil
    is worse" — reached without anyone doing anything wrong.

    THE SPEC IS PART OF THE IDENTITY, not just the banner it produces. `$CC` may
    carry flags — `gcc -m32` emits different object code from `gcc` and prints
    an identical banner — so the requested spelling is recorded alongside. A
    key that cannot tell those apart is the same defect one level down.

    First line only, whitespace-collapsed: gcc prints four lines of licence after
    it, and `ar` on some builds reports a build date that would mint a new key
    per rebuild of binutils.

    `(absent)` when the tool cannot run. That is not a fallback that lets the
    build proceed on a guess — the build is about to invoke this binary and will
    fail on its own. It exists so the KEY is well-defined either way, because a
    key that raises here would take out the cache lookup rather than the build.
    """
    spec = os.environ.get(_TOOL_ENV.get(name, ""), "").strip()
    argv = tuple(shlex.split(spec)) if spec else ()
    if not argv:
        return _tool_banner((name,))
    return f"{spec}: {_tool_banner(argv)}"


# Where ds-base records which glibc build its link-time half is
# (runtime/docker/glibc_link_install.py's ID_FILE). Absent on every host that
# links against its own distribution's glibc.
GLIBC_ID = Path("/usr/share/ds/glibc.id")


@functools.lru_cache(maxsize=1)
def platform_identity() -> str:
    """What the object code will be compatible with: architecture, libc, OS.

    Not the kernel, deliberately, and this is where the store parts company with
    `build_unit.effects._toolchain` — which folds `machine.signature()` (kernel
    AND libc) into every step key. That is right for a step, whose product may be
    anything. This names ONE artifact: a static archive. A kernel patch release
    does not change a `.a`, and folding it in would evict the whole store on
    every host reboot into a new kernel, for a cache that keeps twenty entries.

    libc DOES belong: the objects are compiled against its headers. So does the
    architecture, which nothing else here carries — `source_key` is bytes on
    disk, and a compile line says `-c -o foo.o foo.c` on every machine alive.

    THE OS IS PART OF THE IDENTITY. Neither probe below answers on the BSDs —
    `confstr` has no GNU libc to report and there is no GNU `ldd --version` — so
    both fall through, and OpenBSD/arm64 and NetBSD/arm64 would otherwise share
    one identity while shipping different artifacts from the same commit.
    `uname -r` too, not just the sysname: the libc on a BSD is part of base, so
    the OS release IS the libc version.

    AND WHICH BUILD OF IT. The build images compile against DS's own
    glibc 2.41 headers and start files, while `confstr` still answers 2.41 from
    Debian's runtime library, so the version alone would hand an archive
    compiled against Debian's headers to a build against DS's. ds-base writes
    the build's identity to `GLIBC_ID`, and it is part of the platform.
    """
    system = os.uname().sysname
    if system not in ("Linux",):
        return f"{os.uname().machine} {system} {os.uname().release}"

    try:
        libc = os.confstr("CS_GNU_LIBC_VERSION") or ""
    except (ValueError, OSError, AttributeError):
        libc = ""
    if not libc:
        # musl reports nothing through confstr, which is the ds-musl image and
        # the one place this runs on a non-glibc libc. `ldd --version` is the
        # only reading there; it writes to stderr and exits non-zero.
        try:
            r = subprocess.run(["ldd", "--version"], capture_output=True,
                               text=True)
            got = re.search(r"\d+(?:\.\d+)+", (r.stdout or "") + (r.stderr or ""))
            libc = f"musl-or-other {got.group(0)}" if got else "unknown"
        except (OSError, subprocess.SubprocessError):
            libc = "unknown"
    built = GLIBC_ID.read_text(encoding="utf-8").strip() if GLIBC_ID.is_file() else ""
    return f"{os.uname().machine} {libc.strip()}" + (f" ({built})" if built else "")


STORE_ENV = "DS_VENDOR_STORE"
DEFAULT_STORE = Path("/ds-cache/vendor")
# The image's INHERITED native set, named separately so a cross step can shadow
# `STORE_ENV` without shadowing this. See `native_store_dir`.
NATIVE_STORE_ENV = "DS_VENDOR_NATIVE_STORE"

# Build order is the dependency order, and it is not alphabetical: RE2 needs
# Abseil installed first, protobuf-c needs protobuf's protoc. Declared once here
# so a graph's Consumes edges and this module agree by construction.
ORDER = ("abseil", "re2", "protobuf", "protobuf-c")
# protobuf DOES depend on abseil, and the intermediate state where it did not
# was a wrong turn worth recording. protobuf 35.1 failed against Abseil
# 20250127.0 on ABSL_ATTRIBUTE_VIEW; I read that as "keep protobuf off our
# Abseil" and cut the edge. That cannot work: protobuf 35.1 bundles no Abseil at
# all, so with no prefix on CMAKE_PREFIX_PATH its `find_package(absl)` simply
# resolved to /usr/include/absl — the system copy `libre2-dev` drags in, older
# than the one that had just failed.
#
# There is no "let it find its own". There is only WHICH Abseil it finds, and the
# answer is upstream's own: protobuf-30.2/MODULE.bazel declares 20250127.0, so
# deps.lock pins that and all three consumers take it. (An intermediate pass
# pinned protobuf 35.1 and chased Abseil 20250512.1 to satisfy it; 35.1 was the
# wrong protobuf — protobuf-c 1.5.2 only supports 30.x. deps.lock's header has
# the full chain.)
NEEDS = {"abseil": (), "re2": ("abseil",),
         "protobuf": ("abseil",), "protobuf-c": ("protobuf", "abseil")}
# protobuf-c needs abseil TRANSITIVELY, and the edge has to be explicit because
# nothing computes closures here: its configure probes for
# `google/protobuf/compiler/command_line_interface.h`, and that header includes
# absl headers, so a CPPFLAGS naming only protobuf's include dir does not
# compile.

# THE CROSS SET IS A DIFFERENT GRAPH, and the paragraph above says why without
# meaning to. A cross build takes `--disable-protoc` (see `recipe`), so configure
# never probes for `command_line_interface.h` — the header whose absl includes
# are the entire reason for protobuf-c's two edges. The runtime that remains is
# standalone C and needs neither.
#
# An OVERRIDE rather than an edit to NEEDS, so the native graph stays the single
# thing a graph's edge rows are checked against, and
# the divergence is one line carrying its reason instead of a second table to
# keep in step.
CROSS_NEEDS = {"protobuf-c": ()}

# THE CROSS SET IS ALSO SHORTER, for the same reason and stated the same way.
# `protobuf` is in ORDER only because the native rows build `protoc-gen-c`, which
# links it; `--disable-protoc` removes that consumer, so a cross lineage has
# nothing to build it for. Cross-compiling it anyway would produce a code
# generator that cannot run where code is generated.
#
# Named here rather than left implicit in a graph, because two places
# already have to agree about a lineage's row set and a third statement is a
# third thing to drift.
CROSS_ORDER = tuple(d for d in ORDER if d != "protobuf")

# Which lineages are built by a cross toolchain. A lineage NOT listed here is
# held to the native ORDER and NEEDS, so adding a cross lineage without adding
# it here fails the pins rather than silently taking the native expectation.
CROSS_LINEAGES = ("wasm",)


def needs_for(name: str) -> tuple[str, ...]:
    """This dependency's edges, for the toolchain actually in use.

    Read through this rather than indexing NEEDS, because `store_key` recurses
    over the result: a cross protobuf-c built against nothing must not key the
    same as a native one built against protobuf and abseil, and it would if the
    key asked the native table.
    """
    if cross_toolchain() and name in CROSS_NEEDS:
        return CROSS_NEEDS[name]
    return NEEDS[name]


def order_for() -> tuple[str, ...]:
    """The dependency SET to build or require, for the toolchain in use.

    The companion to `needs_for`, and read through for the same reason: a
    consumer that iterates `ORDER` directly holds a cross lineage to the native
    set, and `CROSS_ORDER` exists precisely because that set is wrong. The
    paragraph above it has the argument — `protobuf` is native-only because it
    is there to build `protoc-gen-c`, which `--disable-protoc` removes, so
    cross-compiling it would produce a code generator that cannot run where
    code is generated.

    This existed as a comment and a constant with no accessor, which is how
    `release-wasm32-regex` came to refuse a wasm set that was COMPLETE: every
    dependency the lineage is specified to have was installed and correctly
    keyed, and `prefixes()` demanded a fourth that the same module argues must
    not exist. A subset is not a missing member, and only the toolchain knows
    which of the two it is looking at.
    """
    return CROSS_ORDER if cross_toolchain() else ORDER


def lock(path: Path = LOCK) -> configparser.ConfigParser:
    cp = configparser.ConfigParser()
    if not cp.read(path, encoding="utf-8"):
        raise SystemExit(f"vendor: cannot read {path}")
    return cp


def deps(cp: configparser.ConfigParser | None = None) -> list[str]:
    """The rows that are VENDORED DEPENDENCIES — `kind = dep` — in lock order.

    deps.lock holds pins, and from BUCSIG1 P2 not every pin is a thing to build:
    signature verification needs a trust anchor pinned the same way, and
    it is a fetched-and-pinned artifact rather than something baked into
    an image, so that it rotates by editing this file.

    That row must not be built, and three readers assumed every section was —
    `ORDER` here, and the section-set assertions in test_deps_lock.py and
    test_vendor.py. Filtering on an explicit `kind` is what lets a non-buildable
    pin live in the one file deps.lock's header argues for ("WHY ONE FILE ...
    three copies, two updated") without any of the three silently trying to
    compile it.

    `kind` is REQUIRED, not defaulted. A row that forgets it would otherwise fall
    into whichever bucket the default named, and the failure mode differs by
    direction: a dep silently treated as trust is never built, a trust row
    treated as a dep is handed to cmake. Neither should be reachable by omission.
    """
    cp = cp or lock()
    missing = [s for s in cp.sections() if not cp[s].get("kind", "").strip()]
    if missing:
        raise SystemExit(
            f"vendor: deps.lock rows declare no `kind`: {', '.join(sorted(missing))}. "
            f"Every row must say `kind = dep` (a vendored dependency this builds), "
            f"`kind = trust` (a pinned trust anchor it does not) or `kind = image` "
            f"(a pin an image builds). It is not "
            f"defaulted because the two failure modes are opposite: a dep read as "
            f"trust is never built, a trust row read as a dep is handed to cmake.")
    return [s for s in cp.sections() if cp[s]["kind"].strip() == "dep"]


def store_dir() -> Path | None:
    """Where installed prefixes live, or None when nothing mounted one.

    Absent is legitimate — a laptop, or an image the scaffold gave no cache. The
    caller then builds into a scratch prefix. What must NOT happen is falling
    back to the system library, which is why this returns a location or nothing
    and never a boolean 'use the distro copy'.
    """
    env = os.environ.get(STORE_ENV)
    if env:
        return Path(env)
    return DEFAULT_STORE if DEFAULT_STORE.parent.is_dir() else None


def native_store_dir() -> Path | None:
    """The image's inherited NATIVE prefix set, or None when nothing named one.

    `ds-deps` builds the vendored set once for the image's own lineage and points
    both this and `STORE_ENV` at it, inherited
    rather than rebuilt per host. A cross step then repoints `STORE_ENV` at the
    mounted store where ITS prefixes belong, and in doing so loses the only name
    for the native set it is still standing in.

    This is that name. `store_dir` answers "where do the prefixes for the thing I
    am BUILDING live"; this answers "where do the prefixes for the machine I am
    building ON live", and a cross build needs both.
    """
    env = os.environ.get(NATIVE_STORE_ENV)
    return Path(env) if env else None


VENDORED_ENV = "DS_VENDORED"


def enabled() -> bool:
    """Whether THIS build links the vendored set — declared, never sniffed.

    An explicit switch rather than "use the prefixes if they happen to be
    installed". The two modes produce different bytes, so which one ran belongs
    in the step's record instead of depending on whether a cache was warm: an
    auto-detecting build with a cold store would quietly emit a tarball linked
    against the system RE2, byte-different from yesterday's, with nothing in the
    log saying so.

    Every caller reads it HERE. A caller had its own copy of
    this two-line predicate, which was fine while it was the only consumer and
    is exactly how a second spelling of one decision gets introduced — the
    failure that rotted three copies of ds-wheelbuild with two updated.
    """
    return os.environ.get(VENDORED_ENV, "") not in ("", "0")


def store_key(name: str, row: configparser.SectionProxy,
              cp: configparser.ConfigParser | None = None) -> str:
    """(source digest ⊕ toolchain ⊕ platform ⊕ flags ⊕ EVERY DEPENDENCY'S KEY), hashed.

    The source digest alone would be the LIBDSSTORE1 bug again: identical RE2
    sources compiled by gcc 14.2 against glibc and by gcc 14.2 against musl are
    not interchangeable archives, and one `/ds-cache` serves both.

    ## Why the dependencies are in here, which cost a release run to learn

    Without the recursion this function had LIBDSSTORE1's defect ITSELF. RE2's
    key covered RE2's sources and the compiler — not Abseil's version — so when
    the Abseil pin moved 20250127.0 -> 20250512.1 and back, RE2's key never
    changed and the store returned an archive built against the OTHER Abseil.
    The link failed with:

        libre2.a(re2.cc.o): undefined reference to
        `AbslInternalSpinLockWake_lts_20250512'

    against an Abseil prefix that says 20250127.0 on the tin. A cache returning
    a stale entry is bad; one returning an entry built against a DIFFERENT
    dependency is the failure this whole item exists to prevent, reproduced
    inside the mechanism meant to prevent it.

    The recursion is what makes a prefix mean "built from these sources by this
    toolchain against THESE dependencies" rather than "built from these sources,
    against whatever was installed at the time".
    """
    cp = cp or lock()
    h = hashlib.sha256()
    h.update(f"{name}\0{row['version']}\0{row['sha256']}\0".encode())
    for tool in ("cc", "c++", "ar"):
        h.update(f"{tool}={tool_identity(tool)}\0".encode())
    h.update(f"platform={platform_identity()}\0".encode())
    # The flags `build` compiles it with, so a hardened prefix and an
    # unhardened one are two entries, never one answering for the other.
    h.update(f"flags={compile_flags(name)}\0".encode())
    # Sorted, so the key does not depend on NEEDS' declaration order. Recursive,
    # so protobuf-c inherits Abseil's key through protobuf as well as directly —
    # a dependency reachable by two paths must not produce two answers.
    for need in sorted(needs_for(name)):
        h.update(f"needs:{need}={store_key(need, cp[need], cp)}\0".encode())
    return h.hexdigest()[:16]


MANIFEST_FILE = "manifest.tsv"

# The C++ standard the vendored set is built with. It MUST equal the one
# libds.build compiles `ds_re2.cc` with (`-std=c++17`, line ~334) — that is the
# single DS translation unit including <re2/re2.h>, and RE2's headers pull in
# Abseil's.
#
# Compiler VERSION skew between a prebuilt Abseil and its consumer is tolerable;
# STANDARD-level skew is not, and it is silent. `absl::string_view` is an alias
# for `std::string_view` from C++17 and a distinct class before it, so a mismatch
# changes what a function signature MEANS across a library boundary while both
# sides compile without complaint. Recorded in the manifest and asserted below,
# because the pair agreeing today is not the same as the pair being held.
CXX_STANDARD = "17"

# `built_with` is `compile_flags(name)` as the builder compiled it.
MANIFEST_FIELDS = ("name", "version", "sha256", "store_key", "prefix",
                   "built_by_cc", "built_by_std", "built_with")


def write_manifest(store: Path, cp: configparser.ConfigParser | None = None) -> Path:
    """Record what this store contains, for consumers that must not recompute.

    `store_key` folds the LOCAL compiler, so a consumer with a different one
    derives a different directory name and cannot find a prefix that is sitting
    right there. That is correct while every consumer builds its own set and
    wrong the moment one builder serves many — a consumer choosing nothing
    should not be deriving a key to find it.

    So the builder keeps the key (it still names the directory, so two builds
    cannot collide in one store — LIBDSSTORE1 and VENDORKEY1 stay closed) and
    publishes this instead.
    """
    cp = cp or lock()
    lines = ["\t".join(MANIFEST_FIELDS)]
    for name in deps(cp):
        row = cp[name]
        # The key is computed here, NOT via prefix_for: on a rebuild into a store
        # that already has a manifest, prefix_for would read the OLD one and this
        # would faithfully republish yesterday's paths. The builder always
        # derives; only consumers read.
        key = store_key(name, row, cp)
        lines.append("\t".join((
            name, row["version"], row["sha256"], key,
            str((store / f"{name}-{row['version']}-{key}").resolve()),
            tool_identity("c++"), CXX_STANDARD,
            compile_flags(name))))
    path = store / MANIFEST_FILE
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def _manifest(store: Path) -> dict[str, dict[str, str]] | None:
    """The store's manifest as {name: row}, or None when it has none.

    None is the ordinary case for a laptop, a bare host, or the builder itself
    mid-build — everything then computes keys exactly as before. Presence is what
    opts a NATIVE consumer in, so this change is inert until an image supplies
    one; a cross consumer is never opted in (`prefix_for`).
    """
    path = store / MANIFEST_FILE
    if not path.is_file():
        return None
    rows: dict[str, dict[str, str]] = {}
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith(MANIFEST_FIELDS[0] + "\t"):
            continue
        fields = line.split("\t")
        if len(fields) != len(MANIFEST_FIELDS):
            raise SystemExit(
                f"vendor: {path}:{n} has {len(fields)} fields, expected "
                f"{len(MANIFEST_FIELDS)} ({', '.join(MANIFEST_FIELDS)}). A "
                f"manifest that cannot be parsed must not be half-read: the "
                f"prefixes it names decide what gets linked into the release.")
        rows[fields[0]] = dict(zip(MANIFEST_FIELDS, fields))
    return rows


def _prefix_from_manifest(name: str, row: configparser.SectionProxy,
                          entry: dict[str, str], store: Path) -> Path:
    """The prebuilt prefix, checked against this tree's pins before it is used.

    THREE WAYS THIS FAILS LOUDLY, and none of them can happen today because
    nothing is prebuilt — everything is rebuilt, so nothing can be stale. That
    is precisely why the checks have to arrive WITH the mechanism.
    """
    for field, want in (("version", row["version"]), ("sha256", row["sha256"])):
        if entry[field] != want:
            raise SystemExit(
                f"vendor: the prebuilt set was built for {name} "
                f"{field}={entry[field]}, but deps.lock pins {want}. The image "
                f"is older than this tree. Rebuild it (and bump DEPS_REF), or "
                f"unset {STORE_ENV} to build the set here.")
    if entry["built_by_std"] != CXX_STANDARD:
        raise SystemExit(
            f"vendor: {name} was built with -std=c++{entry['built_by_std']} and "
            f"this tree compiles ds_re2.cc with -std=c++{CXX_STANDARD}. Abseil "
            f"changes what absl::string_view IS across that boundary, so the "
            f"mismatch would link cleanly and misbehave. Rebuild the set.")
    prefix = Path(entry["prefix"])
    if not (prefix / ".vendor-ok").exists():
        raise SystemExit(
            f"vendor: the manifest names {prefix} for {name} and it is not "
            f"installed there. The manifest and the store disagree, which means "
            f"the image is damaged rather than merely stale.")
    return prefix


def prefix_for(name: str, row: configparser.SectionProxy,
               store: Path | None = None,
               cp: configparser.ConfigParser | None = None) -> Path:
    """ABSOLUTE, always. These paths become `-DCMAKE_PREFIX_PATH` entries, and a
    relative one is resolved against whatever directory cmake happens to be run
    from. It worked because build-unit runs steps at the tree root — which is a fact
    about the harness, not a property of this function, and the failure it would
    eventually produce is `find_package` silently falling through to the system
    copy instead of erroring.

    ⚠ A CROSS BUILD NEVER READS THE MANIFEST. A manifest describes a
    NATIVE prebuilt set — `ds-deps` writes it into the image's own store — and
    `_prefix_from_manifest` checks version, digest and C++ standard, none of
    which says which target the prefix was compiled for. With a native manifest
    sitting in the shared `/ds-cache/vendor`, the wasm rows took the native
    Abseil and RE2 and failed their smoke link on `re2::RE2::~RE2()`. A cross
    build derives its key instead, which `tool_identity` makes follow `$CC`;
    `protoc_c` is the one cross consumer of a native manifest, and it reads the
    native store by name."""
    store = store or store_dir() or Path("vendor-out")
    entry = None if cross_toolchain() else (_manifest(store) or {}).get(name)
    if entry is not None:
        # THE FLAGS ARE CHECKED HERE, for a native consumer, which shares the
        # builder's lineage. The manifest stands in for the store key,
        # which hashes them, so without this an image built before a change to
        # them answers with the prefixes compiled the old way: the first
        # `fleet` run linked ds-deps' unhardened set into the wheels.
        # `protoc_c`, a cross build's reader of the native set, takes a
        # generator, whose flags ship in nothing.
        want = compile_flags(name)
        if entry["built_with"] != want:
            raise SystemExit(
                f"vendor: {store}'s manifest says {name} was compiled with "
                f"{entry['built_with']!r}, and this lineage compiles it with "
                f"{want!r}. The image is older than scripts/vendor/vendor.py: give "
                f"runtime/docker/ds-deps.pin a new id, or unset {STORE_ENV} "
                f"to build the set here.")
        return _prefix_from_manifest(name, row, entry, store)
    return (store / f"{name}-{row['version']}-{store_key(name, row, cp)}").resolve()


def digest(blob: Path) -> str:
    """sha256 of a file, read in chunks — the protobuf tarball is not small and
    this runs in a container whose memory is shared with a compile."""
    h = hashlib.sha256()
    with open(blob, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(blob: Path, expected: str) -> str:
    """Refuse anything but the pinned digest. Returns it."""
    got = digest(blob)
    if got != expected:
        raise SystemExit(
            f"vendor: DIGEST MISMATCH for {blob.name}\n"
            f"  expected {expected}\n"
            f"  got      {got}\n"
            f"  Refusing to build. If this is an intended bump, update "
            f"vendor/deps.lock — never this check."
        )
    return got


TRUST_ROW = "sigstore-trust-root"


def trust_root(dest: Path, cp: configparser.ConfigParser | None = None) -> Path:
    """Fetch the pinned sigstore trusted root and check its digest.

    The anchor, and it is fetched-and-pinned rather than baked into an image so
    that rotating it is a deps.lock edit. Its URL is
    content-addressed — TUF serves targets as `<sha256>.<name>` — so the pin and
    the location cannot disagree; the digest check below is still made, because
    a URL is a request and a digest is what arrived.
    """
    cp = cp or lock()
    if TRUST_ROW not in cp:
        raise SystemExit(
            f"vendor: deps.lock has no [{TRUST_ROW}] row, so there is no trust "
            f"anchor to verify signatures against. Signature verification "
            f"cannot be done 'by default' — without a pinned root, cosign would "
            f"trust whatever TUF served this morning, which is the property "
            f"deps.lock exists to remove.")
    row = cp[TRUST_ROW]
    dest.mkdir(parents=True, exist_ok=True)
    blob = dest / "trusted_root.json"
    if not blob.exists() or digest(blob) != row["sha256"]:
        subprocess.run(["curl", "-fsSL", row["url"], "-o", str(blob)], check=True)
    verify(blob, row["sha256"])
    return blob


def verify_signature(name: str, blob: Path, dest: Path,
                     cp: configparser.ConfigParser | None = None) -> str:
    """Check `blob`'s upstream signature. Returns the identity that signed it.

    THE DIGEST AND THIS ARE DIFFERENT CLAIMS. A pinned sha256 proves the bytes
    are the ones we recorded; it says nothing about whether they are the ones
    upstream published, because the first recording was trust-on-first-use. This
    closes that, for the rows where upstream publishes anything.

    ROWS THAT PUBLISH NOTHING RETURN "" AND ARE NOT AN ERROR — three of the four
    are `sig = none`, honestly, and pretending otherwise was RELSUM2's defect in
    the opposite direction. A row that DECLARES a signature and cannot produce a
    verified one is fatal.

    IDENTITY IS REQUIRED, and it is the whole point. `cosign verify-blob` with a
    bundle and no `--certificate-identity` checks that somebody holds a valid
    Fulcio certificate — which any GitHub Actions run on earth can obtain. The
    expected signer comes from deps.lock, beside the version it is tied to.
    """
    cp = cp or lock()
    row = cp[name]
    kind = row.get("sig", "none").strip()
    if kind == "none":
        return ""
    if kind != "sigstore":
        raise SystemExit(
            f"vendor: [{name}] declares sig={kind!r}, which this does not know "
            f"how to check. Implement it or set sig = none and say why — a "
            f"method nothing verifies is worse than an honest absence.")

    identity = row.get("sig_identity", "").strip()
    issuer = row.get("sig_issuer", "").strip()
    if not identity or not issuer:
        raise SystemExit(
            f"vendor: [{name}] declares sig=sigstore but gives no "
            f"sig_identity/sig_issuer. Verifying without an expected signer "
            f"checks only that SOMEONE signed it, which every GitHub Actions "
            f"run in the world can satisfy. Refusing to call that verified.")

    bundle = dest / (row["sig_url"].rsplit("/", 1)[-1])
    if not bundle.exists():
        subprocess.run(["curl", "-fsSL", row["sig_url"], "-o", str(bundle)],
                       check=True)
    root = trust_root(dest, cp)

    argv = ["cosign", "verify-blob", "--bundle", str(bundle),
            "--trusted-root", str(root),
            "--certificate-identity", identity,
            "--certificate-oidc-issuer", issuer, str(blob)]
    print("+ " + " ".join(argv), flush=True)
    done = subprocess.run(argv, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(
            f"vendor: SIGNATURE VERIFICATION FAILED for {blob.name}\n"
            f"  expected signer {identity}\n"
            f"  issuer          {issuer}\n"
            f"{done.stdout}{done.stderr}\n"
            f"  Refusing to build. The digest may still match — that only means "
            f"the bytes are the ones we recorded, not the ones upstream signed.")
    return identity


def fetch(name: str, dest: Path, cp: configparser.ConfigParser | None = None) -> Path:
    """Download the pinned tarball, digest it, and check its signature — all
    before it is ever unpacked.

    Order is the point, as it was for RELSUM1's Dockerfile checks: a tar of a
    substituted archive has already written into the tree by the time any later
    assertion could run. The signature check joins the digest check on the same
    side of `extract` for the same reason.
    """
    cp = cp or lock()
    row = cp[name]
    dest.mkdir(parents=True, exist_ok=True)
    blob = dest / row["url"].rsplit("/", 1)[-1]
    if not blob.exists() or digest(blob) != row["sha256"]:
        subprocess.run(["curl", "-fsSL", row["url"], "-o", str(blob)], check=True)
    verify(blob, row["sha256"])
    signer = verify_signature(name, blob, dest, cp)
    print(f"vendor: {name} "
          + (f"VERIFIED against {signer}" if signer
             else "pinned by digest only (upstream publishes no signature)"),
          flush=True)
    _verified[name] = signer or ""
    _record_attestation(name, row, signer)
    return blob


# What `verify_signature` actually returned this run, per dep. Recorded rather
# than re-derived from `sig_identity`, because the pin says who we EXPECT to
# have signed and only the check says who did — writing the expectation into
# `.vendor-ok` would make the store assert a verification nobody performed.
_verified: dict[str, str] = {}

ATTEST_FILE = "vendor-attest.tsv"

# The document this run writes its verdicts to. `main` sets it from the step's
# declared Output so each vendor step gets its OWN file; ATTEST_FILE is the
# fallback for a direct call. It used to be ATTEST_FILE unconditionally, which
# meant all eight steps of a build appended to one path in one checkout — a race
# at --jobs > 1 and, worse, a document in which one step's rows are
# indistinguishable from another's.
_attest_path = ATTEST_FILE


def _installed_signer(prefix: Path) -> str:
    """The signer recorded in a prefix's `.vendor-ok`, or "" if it records none.

    Field four, absent from records written before it existed — and absent is
    reported as unverified rather than assumed fine, because the whole point of
    the field is that nothing else on disk says a signature was ever checked.
    """
    try:
        fields = (prefix / ".vendor-ok").read_text(encoding="utf-8").split()
    except OSError:
        return ""
    return fields[3] if len(fields) > 3 else ""


def _record_attestation(name: str, row, signer: str) -> None:
    """Append this row's provenance verdict to the step's attestation document.

    BUCSIG1 P2b. Until now the verdict existed only in the line printed above —
    which is a log, and a log is what §7.1 rejects for test results for exactly
    this reason: it cannot be joined, replayed, or asserted against. The harness
    parses this file into `Verified` / `Unverified` facts, so the `.buildstate`
    records what was checked and against whom.

    APPENDED, because one vendor step fetches one dependency but the same
    document accumulates across the deps a step pulls in; written into the step's
    working directory, so it is the declared Output the graph names and the
    harness collects.

    `_clean_field` is not paranoia about upstream — the reason strings are ours —
    but the format is tab-separated and a tab arriving from a lock file would
    silently shift every later field by one. Cheaper to normalise than to debug.
    """
    verdict = "verified" if signer else "unverified"
    detail = signer or (
        f"sig={row.get('sig', 'none').strip()}: upstream publishes nothing to "
        f"check, so the pinned sha256 is the only control")
    line = "\t".join(_clean_field(f) for f in (
        verdict, name, row.get("sig", "none").strip(),
        TRUST_ROW if signer else "", detail))
    with open(_attest_path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def _clean_field(text: str) -> str:
    return " ".join(str(text).split())


def extract(blob: Path, into: Path) -> Path:
    """Unpack and return the single top-level directory.

    `data` filter (3.12+) refuses absolute paths and traversal outside the
    destination. These are pinned tarballs from named upstreams, so this is not
    the primary control — the digest is — but an extractor that can write
    outside its target is worth not having regardless.
    """
    shutil.rmtree(into, ignore_errors=True)
    into.mkdir(parents=True, exist_ok=True)
    with tarfile.open(blob) as tar:
        tar.extractall(into, filter="data")
    tops = [p for p in into.iterdir() if p.is_dir()]
    if len(tops) != 1:
        raise SystemExit(
            f"vendor: {blob.name} unpacked to {len(tops)} top-level directories, "
            f"expected exactly one: {[p.name for p in tops]}"
        )
    # Absolute, because `build()` runs every step with cwd set to this directory
    # and a relative path would then resolve against itself.
    return tops[0].resolve()


def dep_env(deps: list[Path]) -> dict[str, str]:
    """The environment that makes OUR prefixes win over the system's.

    cmake takes `-DCMAKE_PREFIX_PATH` on the command line, so the cmake rows
    were covered. Autotools does not: protobuf-c's `configure` finds protobuf
    through **pkg-config**, and with nothing pointing there it failed with
    `Package requirements (protobuf >= 3.0.0) were not met` — having just built
    protobuf into a prefix twenty seconds earlier.

    Both variables are PREPENDED, never replaced. The images still carry the
    distro's protobuf and RE2 (`libre2-dev`, `libprotobuf-c-dev`), so this is a
    precedence fight rather than a lookup: the system copy is always findable,
    and what decides the outcome is who is first. That is the whole hazard of
    vendoring into an image that already has the thing being vendored — until
    those packages come out of ds-base, "we built it from pinned source" and
    "the build linked what we built" are two different claims.

    PATH gets the prefixes' `bin` for the same reason: protobuf-c's build
    invokes `protoc`, and ds-base has an apt one that would otherwise answer.
    """
    env = dict(os.environ)
    pkg = os.pathsep.join(str(d / "lib" / "pkgconfig") for d in deps)
    if pkg:
        env["PKG_CONFIG_PATH"] = os.pathsep.join(
            p for p in (pkg, env.get("PKG_CONFIG_PATH", "")) if p)
    bins = os.pathsep.join(str(d / "bin") for d in deps)
    if bins:
        env["PATH"] = os.pathsep.join(p for p in (bins, env.get("PATH", "")) if p)
    # CPPFLAGS/LDFLAGS as well as pkg-config, because autoconf uses BOTH and they
    # are not interchangeable. `PKG_CONFIG_PATH` alone got protobuf-c past
    # `protobuf >= 3.0.0` and straight into `required protobuf header file not
    # found` — `AC_CHECK_HEADER` compiles a probe with CPPFLAGS and never
    # consults pkg-config. Two lookup mechanisms in one configure script, and
    # satisfying one moves the error rather than fixing it.
    inc = " ".join(f"-I{d / 'include'}" for d in deps)
    if inc:
        env["CPPFLAGS"] = " ".join(p for p in (inc, env.get("CPPFLAGS", "")) if p)
    lib = " ".join(f"-L{d / 'lib'}" for d in deps)
    if lib:
        env["LDFLAGS"] = " ".join(p for p in (lib, env.get("LDFLAGS", "")) if p)
    env["SOURCE_DATE_EPOCH"] = env.get("SOURCE_DATE_EPOCH", "0")
    # MAKE, because `configure` RUNS MAKE ITSELF (VENDORBSD1, measured).
    #
    # Spelling the recipe's make steps `gmake` was necessary and not sufficient:
    # protobuf-c's configure bootstraps its automatic-dependency-tracking
    # fragments by invoking `$MAKE`, defaulting to `make`, BEFORE any step of
    # ours runs. On NetBSD that is BSD make, and the first real run of the
    # netbsd row died in `config.status` with
    #
    #     Something went wrong bootstrapping makefile fragments for automatic
    #     dependency tracking.  If GNU make was not used, consider re-running
    #     the configure script with MAKE="gmake"
    #
    # which is autoconf naming this exact fix. Setting it here rather than at
    # the configure step covers every sub-make configure spawns, and on linux it
    # is the identity — `gnu_make()` returns "make" there.
    env["MAKE"] = gnu_make()
    # THE TARGET IS STATED HERE TOO (RV64ISA1). These prefixes are linked into
    # the artifacts libds ships, so an Abseil built for a different RISC-V
    # baseline than libds.a is the same trap one layer down — and worse, because
    # `find_package` would report success. `target_flags` is the one
    # definition; empty on amd64 and arm64, so this is a no-op there.
    #
    # PREPENDED to whatever the caller exported, for dep_env's own reason: the
    # last flag wins in both cmake and autotools, so ours must not be first.
    isa = target_flags()
    if isa:
        for var in ("CFLAGS", "CXXFLAGS"):
            env[var] = f"{isa} {env.get(var, '')}".strip()
    return env


# The BSDs' base `make` is BSD make. pkgsrc and ports install GNU make BESIDE
# it as `gmake` rather than replacing it, so on those platforms the two names
# are two different programs and only one of them can build this set.
_GMAKE_PLATFORMS = ("NetBSD", "OpenBSD", "FreeBSD", "DragonFly")


def gnu_make() -> str:
    """GNU make, under the name this platform gives it (VENDORBSD1).

    protobuf-c is the only row of the four that is not cmake: its RELEASE
    tarball ships a generated `configure` and an autotools Makefile, and an
    autotools Makefile is a GNU make program — `$(shell …)`, pattern rules,
    `ifeq`. BSD make does not read one. It does not read it and stop cleanly
    either; it gets some way in and fails on a construct, which is a build error
    about a syntax rather than about the wrong tool.

    DECLARED FROM THE OS, NEVER PROBED. `shutil.which("gmake")` is the obvious
    alternative and is the `enabled()` mistake one function over: a Linux host
    with gmake installed for some other reason would silently build this set
    with a different make than the one the record names, and the two would be
    indistinguishable afterwards. The guest provisioning flows install `gmake`
    on the BSDs and
    nothing installs it anywhere else; this switch is the other half of that
    single fact, which is why `test_vendor.py` pins the two together.
    """
    return "gmake" if platform.system() in _GMAKE_PLATFORMS else "make"


# ── cross-compiling this set ─────────────────────────────────────────────────
#
# ONE ENV VAR, NAMING A FILE, and deliberately not a lineage word. `emcmake` and
# `emconfigure` are wrappers that mostly export CC/CXX/AR and point cmake at a
# toolchain file; naming the file directly is the same effect with nothing
# hidden, and it works for any cross toolchain rather than for Emscripten
# specifically. The wasm STEPS set it, not
# the image — ds-build is shared with the four native lineages, and an
# image-wide value would make every one of them think it was cross-compiling.
# A native run therefore never sees it and every native recipe is byte-identical
# to before.
#
# THE STORE KEY IS NOT THIS FUNCTION'S JOB. `store_key` already separates a
# cross build from a native one, because `tool_identity` follows
# `$CC`/`$CXX`/`$AR`/`$LD` and the toolchain image sets those. Were it not for
# that, these prefixes would collide with the native ones in a single
# DS_VENDOR_STORE — one key, two different Abseils.
CROSS_ENV = "DS_VENDOR_TOOLCHAIN_FILE"

# `--host` for the one autotools row. wasm32-unknown-emscripten is what
# emconfigure passes, and autotools only needs it to stop running its test
# binaries on a host that cannot execute them.
CROSS_HOST = os.environ.get("DS_VENDOR_CROSS_HOST", "wasm32-unknown-emscripten")


def cross_toolchain() -> str:
    """The cmake toolchain file for a cross build, or "" when building natively.

    Returns the path rather than a boolean so the caller has the one thing it
    needs to pass on, and so a misconfigured image fails as a cmake error naming
    a missing file rather than as a native build wearing a cross store key.
    """
    return os.environ.get(CROSS_ENV, "").strip()


# ── the set is hardened as libds is ──────────────────────────────────
#
# RE2 and Abseil are folded into the shipped `libds.a`, and `libprotobuf-c.a`
# ships beside it and links into the wheels' `_pyds`. The linker ANDs the CET
# and BTI property notes of every object it links, so one member built without
# them switches the protection off for the integrator's whole program, however
# hardened libds's own members are.
#
# BY LINEAGE, because the set is built once per lineage (ds-deps' own
# `vendor.py all`), not once per release row. The
# values are the ones each libds release row
# passes for libds itself.
#
# STATED HERE, NOT IMPORTED: ds-deps.Dockerfile builds the
# image's own set from this file alone.
HARDEN = ("-fstack-protector-strong -D_FORTIFY_SOURCE=3 "
          "-fstack-clash-protection -ftrivial-auto-var-init=zero")
HARDEN_PROFILES = {
    "portable": HARDEN,
    # fortify-headers 1.1, musl's FORTIFY, predates level 3.
    "musl": HARDEN.replace("-D_FORTIFY_SOURCE=3", "-D_FORTIFY_SOURCE=2"),
    "none": "",
}
# (profile, CFI switch or `none`), by VendorDep lineage. riscv64 has no stable
# control-flow protection in gcc 14, and NetBSD's gcc 12.5 writes no property
# note under -fcf-protection (hardening_check's NO_CFI and NO_CFI_ROWS). wasm32
# has no CET or BTI, and neither the stack protector nor FORTIFY there.
LINEAGE_HARDENING = {
    "glibc-amd64": ("portable", "-fcf-protection=full"),
    "glibc-arm64": ("portable", "-mbranch-protection=standard"),
    "glibc-rv64gc": ("portable", "none"),
    "musl-amd64": ("musl", "-fcf-protection=full"),
    "musl-arm64": ("musl", "-mbranch-protection=standard"),
    "musl-rv64gc": ("musl", "none"),
    "netbsd-amd64": ("portable", "none"),
    "wasm": ("none", "none"),
}

# platform.machine()'s answers, Linux's and NetBSD's, to a lineage's arch word.
_LINEAGE_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64",
                 "arm64": "arm64", "riscv64": "rv64gc"}


def _linux_libc() -> str:
    """`glibc` or `musl`, from what the C library answers; anything else is
    refused. musl reports nothing through confstr, and its loader names itself
    on `ldd --version`, as platform_identity reads it."""
    try:
        if os.confstr("CS_GNU_LIBC_VERSION"):
            return "glibc"
    except (ValueError, OSError, AttributeError):
        pass
    try:
        r = subprocess.run(["ldd", "--version"], capture_output=True, text=True)
        if "musl" in (r.stdout or "") + (r.stderr or ""):
            return "musl"
    except (OSError, subprocess.SubprocessError):
        pass
    raise SystemExit("vendor: this Linux's C library is neither glibc nor musl, "
                     "so no lineage says how the vendored set is hardened")


def lineage() -> str:
    """The VendorDep lineage this process builds for, from the toolchain and the
    platform. DERIVED, NEVER DEFAULTED: a platform no lineage names is refused,
    since a guess would harden the set for another target or not at all."""
    if cross_toolchain():
        return CROSS_LINEAGES[0]
    arch = _LINEAGE_ARCH.get(platform.machine())
    system = platform.system()
    if arch is not None and system == "NetBSD":
        name = f"netbsd-{arch}"
    elif arch is not None and system == "Linux":
        name = f"{_linux_libc()}-{arch}"
    else:
        name = f"{system} {platform.machine()}"
    if name not in LINEAGE_HARDENING:
        raise SystemExit(
            f"vendor: no lineage in LINEAGE_HARDENING is this platform "
            f"({name}); say how the vendored set is hardened there")
    return name


def hardening() -> str:
    """The exploit mitigations this lineage compiles the set with: its profile's
    flags and its CFI switch, "" for a lineage that takes none."""
    profile, cfi = LINEAGE_HARDENING[lineage()]
    return " ".join(f for f in (HARDEN_PROFILES[profile],
                                "" if cfi == "none" else cfi) if f)


def compile_flags(name: str) -> str:
    """What `build` adds to a dependency's CFLAGS and CXXFLAGS: the hardening,
    `-g` so a hardening check can read each unit's flags from the debug
    pack's DWARF, and `-O2` for protobuf-c. Its configure keeps autoconf's
    `-g -O2` default only while CFLAGS is unset, and FORTIFY does nothing
    without optimisation. The cmake rows keep their build type's own `-O3`,
    which comes after these. "" for a lineage that is not hardened, so wasm's
    recipes run as they did."""
    harden = hardening()
    if not harden:
        return ""
    return " ".join((harden, "-g", *(("-O2",) if name == "protobuf-c" else ())))


# What one C++ compile of these dependencies may hold at its peak. protobuf's
# larger translation units pass 1 GiB under -O2; this leaves headroom.
_GIB_PER_JOB = 1.5


def _mem_available_gib(meminfo: str = "/proc/meminfo") -> float | None:
    try:
        with open(meminfo, encoding="ascii") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) / (1024 * 1024)
    except (OSError, ValueError, IndexError):
        pass
    return None


def build_jobs(cpus: int | None = None, mem_gib: float | None = None) -> int:
    """Parallel compiles for these builds: the cores, capped by memory.

    `-j <cores>` alone runs a riscv64 build host (4 cores, about 4 GB) out of
    memory: four protobuf compiles at once, and it stops answering ssh. So each
    job is given `_GIB_PER_JOB` of what the kernel says is available, never
    fewer than one job, never more than the cores.

    The job count is not in any store key (`store_key` hashes the pinned
    source and the toolchain, not the recipe's argv), so it moves no digest.
    """
    cpus = cpus if cpus is not None else (os.cpu_count() or 1)
    mem = mem_gib if mem_gib is not None else _mem_available_gib()
    if mem is None:
        return max(1, cpus)
    return max(1, min(cpus, int(mem // _GIB_PER_JOB)))


def protoc_with_includes(protobuf: Path, work: Path) -> Path:
    """Our protoc, with our protobuf's `include/` named on its command line.

    protobuf-c's Makefile regenerates `protobuf-c.pb.cc` with whatever
    `configure` found as `PROTOC` — it must, so the C++ it compiles matches the
    protobuf it links — and that `.proto` imports
    `google/protobuf/descriptor.proto`. protoc finds its own well-known types
    by locating its executable, which on Linux it reads from /proc/self/exe.
    On the NetBSD row it found nothing, and the release build died with

        google/protobuf/descriptor.proto: File not found.

    (0.16.0's vendor-protobuf-c-netbsd-amd64.) Naming the directory makes the
    lookup a fact of the invocation instead of a property of the host.

    A Python shim rather than a `PROTOC="protoc -I…"` value: protobuf-c's
    Makefile names `PROTOC` as a PREREQUISITE of the generated file, so a value
    with an argument in it becomes a second target nobody can build. One path,
    exec'd with the include prepended, and nothing else changes. Written into
    `work`, never into a prefix: it is how this build ran, not something the
    store holds.

    ABSOLUTE, and the first version of this was not. `configure` reads PROTOC
    through `AC_PATH_PROG`, which takes a preset value only when it is an
    absolute path. A relative one (`work` defaults to `vendor-work`) is
    silently replaced by a PATH search for `protoc`, which finds the real
    binary, and the build failed as before.
    """
    shim = (work / "protoc").resolve()
    protoc = protobuf / "bin" / "protoc"
    inc = protobuf / "include"
    shim.parent.mkdir(parents=True, exist_ok=True)
    shim.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        f"os.execv({str(protoc)!r}, [{str(protoc)!r}, {'-I' + str(inc)!r}, "
        "*sys.argv[1:]])\n",
        encoding="utf-8")
    shim.chmod(0o755)
    return shim


def recipe(name: str, src: Path, prefix: Path, deps: list[Path]) -> list[list[str]]:
    """The build, as argv lists — no shell, for the reason build-unit has none.

    `deps` are the prefixes of already-installed dependencies; they go on
    CMAKE_PREFIX_PATH / PKG_CONFIG_PATH so RE2 finds our Abseil and protobuf-c
    finds our protobuf, rather than the distro's. That redirection IS the
    vendoring: building from pinned source and then linking the system copy
    would pass every check here and ship the wrong bytes.
    """
    jobs = str(build_jobs())
    prefix_path = ";".join(str(d) for d in deps)
    cross = cross_toolchain()
    if name in ("abseil", "re2", "protobuf"):
        build = src / "_build"
        cmake = [
            "cmake", "-S", str(src), "-B", str(build),
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DCMAKE_CXX_STANDARD=17",
            "-DBUILD_TESTING=OFF",
        ]
        if prefix_path:
            cmake.append(f"-DCMAKE_PREFIX_PATH={prefix_path}")
        if cross:
            cmake.append(f"-DCMAKE_TOOLCHAIN_FILE={cross}")
            # CMAKE_PREFIX_PATH IS NOT ENOUGH UNDER A CROSS TOOLCHAIN, and this
            # is the one flag the native rows do not need. Emscripten.cmake sets
            # CMAKE_FIND_ROOT_PATH_MODE_PACKAGE to ONLY and puts only its
            # sysroot on CMAKE_FIND_ROOT_PATH, so `find_package` never consults
            # the prefix path — re2's `find_package(absl)` fails with "could not
            # find abslConfig.cmake" while that file sits installed in the
            # prefix we just built. Adding the prefixes as find roots keeps the
            # ONLY policy and makes OUR dependencies visible.
            #
            # NOT `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH`, which also works and
            # re-admits the host — the failure this module exists to prevent:
            # "building from pinned source and then linking the system copy
            # would pass every check here and ship the wrong bytes".
            if prefix_path:
                cmake.append(f"-DCMAKE_FIND_ROOT_PATH={prefix_path}")
        if name == "abseil":
            cmake.append("-DABSL_PROPAGATE_CXX_STD=ON")
        elif name == "re2":
            cmake.append("-DRE2_BUILD_TESTING=OFF")
        elif name == "protobuf":
            # `package` means find_package(absl), which takes CMAKE_PREFIX_PATH
            # — so this is what points protobuf at OUR Abseil rather than the
            # system one. `module` is not an option: protobuf 35.1's release
            # tarball bundles no Abseil (only third_party/utf8_range), so there
            # is no submodule to build against.
            #
            # Which makes the flag and the NEEDS edge one mechanism, not two.
            # Dropping the flag while keeping the edge changed nothing (the
            # prefix still won); dropping the edge while keeping the flag would
            # send it to /usr/include/absl. Both, or neither and a system Abseil.
            cmake += ["-Dprotobuf_ABSL_PROVIDER=package",
                      "-Dprotobuf_BUILD_TESTS=OFF",
                      "-Dprotobuf_BUILD_SHARED_LIBS=OFF"]
        return [cmake,
                ["cmake", "--build", str(build), "-j", jobs],
                ["cmake", "--install", str(build)]]
    if name == "protobuf-c":
        # `--with-pic` is NOT optional. libprotobuf-c.a is linked into
        # `_pyds.so`, a shared object, and libtool builds a static-only library
        # without PIC unless told otherwise. Debian's own archive is built that
        # way and the link fails with `relocation R_X86_64_PC32 ... can not be
        # used when making a shared object` — measured, and the reason this flag
        # is here rather than assumed from `--enable-static`.
        #
        # The cmake rows get the same property from
        # CMAKE_POSITION_INDEPENDENT_CODE=ON above.
        #
        # `gnu_make()` rather than a literal `make`: this is the one autotools
        # row, and on the BSD guests base `make` cannot build it (VENDORBSD1).
        gmake = gnu_make()
        configure = [str(src / "configure"), f"--prefix={prefix}",
                     "--disable-shared", "--enable-static", "--with-pic"]
        if cross:
            # `--host` is what tells autotools it is cross-compiling; without it
            # configure runs its test binaries and they cannot execute here.
            configure.append(f"--host={CROSS_HOST}")
            # `--disable-protoc` IS NOT AN OPTIMISATION. protoc-gen-c is a C++
            # HOST tool that links protobuf and emits the `.pb-c.c` the loader
            # includes; a cross copy of it could not run where code is
            # generated. Only the RUNTIME is wanted here, which is standalone C
            # — and it is why the wasm protobuf-c row carries no VendorEdge
            # while the native one needs protobuf and abseil.
            configure.append("--disable-protoc")
        return [configure,
                [gmake, "-C", str(src), f"-j{jobs}"],
                [gmake, "-C", str(src), "install"]]
    raise SystemExit(f"vendor: no recipe for {name!r}")


def build(name: str, *, work: Path, cp: configparser.ConfigParser | None = None,
          store: Path | None = None) -> Path:
    """Fetch, verify, unpack and install one dep. Returns its prefix.

    A prefix that already exists is REUSED, because the key covers the source
    digest, the toolchain and the platform — the three things that decide
    whether the installed bytes would differ.
    """
    cp = cp or lock()
    row = cp[name]
    prefix = prefix_for(name, row, store, cp)
    if (prefix / ".vendor-ok").exists():
        print(f"vendor: {name} {row['version']} reused -> {prefix}", flush=True)
        # THE ATTESTATION IS WRITTEN ON THE REUSE PATH TOO, and leaving it out
        # was a defect that only a warm store could show. The step DECLARES an
        # attest Report, and a declared document that is not produced fails the
        # step — so on any host whose /ds-cache already held the prefix, every
        # vendor step failed with "declared a 'attest' Report and did not write
        # one". The first run after a cold clone passed, which is the worst
        # possible distribution of that bug.
        #
        # It restates the verdict RECORDED WITH THOSE BYTES rather than
        # re-deriving one. The store key covers the source digest, the toolchain
        # and the platform, so the prefix and the signature that was checked to
        # install it belong to each other. A `.vendor-ok` written before this
        # field existed has no signer and is reported unverified, which is the
        # truthful reading: nothing on disk says a signature was ever checked.
        _record_attestation(name, row, _installed_signer(prefix))
        return prefix
    deps = [prefix_for(d, cp[d], store, cp) for d in needs_for(name)]
    missing = [d for d in deps if not (d / ".vendor-ok").exists()]
    if missing:
        raise SystemExit(
            f"vendor: {name} needs {[d.name for d in missing]} installed first. "
            f"Build order is {' -> '.join(ORDER)}: "
            f"something has run them out of order."
        )
    blob = fetch(name, work / "src", cp)
    src = extract(blob, work / "unpack" / name)
    prefix.mkdir(parents=True, exist_ok=True)
    env = dep_env(deps)
    # The hardening goes HERE and not into dep_env, whose other callers build
    # with the installed set rather than build it. Appended: the last flag
    # wins in cmake and autotools alike.
    flags = compile_flags(name)
    if flags:
        for var in ("CFLAGS", "CXXFLAGS"):
            env[var] = f"{env.get(var, '')} {flags}".strip()
    if name == "protobuf-c" and not cross_toolchain():
        env["PROTOC"] = str(protoc_with_includes(
            prefix_for("protobuf", cp["protobuf"], store, cp), work))
    # cwd IS the source tree, and that is not cosmetic. Autotools configures into
    # the CURRENT directory — only cmake takes -S/-B — so running protobuf-c's
    # configure from the repo root wrote its Makefile to /ds, and the following
    # `make -C <src>` reported "No targets specified and no makefile found"
    # about a directory configure had never touched. Every step runs here, which
    # costs cmake nothing (its paths are absolute) and makes the autotools rows
    # correct by construction rather than by remembering.
    for step in recipe(name, src, prefix, deps):
        print(f"+ {' '.join(step)}", flush=True)
        subprocess.run(step, check=True, env=env, cwd=src)
    # The stamp is written LAST and is what `reused` tests. A prefix that exists
    # because a build died halfway must not read as installed.
    #
    # The SIGNER is a fourth field so the reuse path above can restate this
    # run's verdict instead of inventing one. Appended rather than given its own
    # file because it is a property OF this record: the line says which bytes
    # were installed and who was checked to have signed them, and splitting
    # those into two files is how they drift apart.
    (prefix / ".vendor-ok").write_text(
        f"{name} {row['version']} {row['sha256']} {_verified.get(name, '')}".rstrip()
        + "\n", encoding="utf-8")
    print(f"vendor: {name} {row['version']} installed -> {prefix}", flush=True)
    return prefix


# ── the consumer API (VENDOR1 wiring, PROPOSAL §9.2) ─────────────────────────
#
# Six places used to reach for a system copy — the compile rules, the harness
# link, the protoc steps, the cold-start plan, the tarball's libprotobuf-c.a and
# its smoke link. They ask HERE rather than each re-deriving a path, for the
# reason §3.1 gives about scattered pins: three copies, two updated.
#
# Every one of these RAISES when a prefix is missing. That is the whole design.
# The tempting alternative — fall back to the system library when the vendored
# set is absent — produces a `libds.a` linked against something nobody pinned,
# from a build that reported success, and no downstream check can tell the two
# apart. It is BUCASAN1 (asan over an uninstrumented archive) and
# SOURCE_DATE_EPOCH's fixed `0` in a third costume.


def prefixes(cp: configparser.ConfigParser | None = None,
             store: Path | None = None) -> dict[str, Path]:
    """Every installed prefix by name, or a refusal naming what is missing.

    The set comes from `order_for()`, not `ORDER`: on a cross lineage the two
    differ, and iterating the native one turns a complete set into a refusal.
    """
    cp = cp or lock()
    out, missing = {}, []
    for name in order_for():
        p = prefix_for(name, cp[name], store, cp)
        (out.__setitem__(name, p) if (p / ".vendor-ok").exists()
         else missing.append(f"{name} ({p})"))
    if missing:
        raise SystemExit(
            "vendor: the vendored set is not installed: " + ", ".join(missing) +
            "\n  Build it first: python3 scripts/vendor/vendor.py all <stamp>. "
            "Refusing rather than falling back to the system "
            "copies, which would link bytes nobody pinned and still report OK."
        )
    return out


def cflags(cp: configparser.ConfigParser | None = None,
           store: Path | None = None) -> str:
    """`-I` for every vendored prefix, for a compile of libds against the set.

    Abseil is included even though only RE2's headers name it: `re2/re2.h`
    includes `absl/...`, so a translation unit compiling ds_re2.cc needs both.
    """
    return " ".join(f"-I{p / 'include'}" for p in prefixes(cp, store).values())


def link_flags(cp: configparser.ConfigParser | None = None,
               store: Path | None = None) -> list[str]:
    """The STATIC link line for RE2, resolved by pkg-config rather than listed.

    A static libre2.a needs Abseil's archives too — around forty of them, whose
    membership changes between Abseil releases. Hardcoding that list would be a
    fourth copy of the dependency graph and would rot on the next bump, so this
    asks `pkg-config --static --libs re2` with our prefixes on the path and lets
    re2.pc's `Requires.private` name them.

    `--static` matters: without it pkg-config emits `-lre2` alone, the link
    fails on absl symbols, and the obvious-looking fix is to add the system
    Abseil.
    """
    pcs = prefixes(cp, store)
    env = dep_env(list(pcs.values()))
    out = subprocess.run(["pkg-config", "--static", "--libs", "re2"],
                         env=env, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(
            f"vendor: pkg-config could not resolve re2 from the vendored "
            f"prefixes: {out.stderr.strip()}"
        )
    return out.stdout.split()


def split_link_flags(flags: list[str]) -> tuple[list[Path], list[str]]:
    """Partition a static link line into (OUR archives, the platform's flags).

    RELSELF1. The shipped `libds.a` folds the vendored objects in, so a consumer
    can link the tarball without owning our store — and to fold them in, the
    build needs the archive PATHS, not `-L`/`-l` pairs. Everything resolvable to
    a `.a` under one of our prefixes is ours and gets merged; everything else is
    the platform's and stays on the link line.

    The distinction is not cosmetic and the NetBSD row shows why: that link line
    carries `-lrt`, `-lpthread`, `-lm` and an absolute `/usr/lib/libexecinfo.so`
    alongside sixty of our `-labsl_*`. Merging a system library into a shipped
    archive would bake one machine's libc-adjacent objects into an artifact
    meant for every machine of that platform — the LIBDSSTORE1 mistake with a
    wider blast radius. Ours are identified by living under a store prefix, not
    by name, because `-labsl_*` is a naming convention and a store path is a
    fact.
    """
    roots = [p.resolve() for p in prefixes().values()]
    libdirs: list[Path] = []
    ours: list[Path] = []
    rest: list[str] = []

    def _is_ours(p: Path) -> bool:
        rp = p.resolve()
        return any(rp == r or r in rp.parents for r in roots)

    for f in flags:
        if f.startswith("-L"):
            d = Path(f[2:])
            libdirs.append(d)
            # A -L into our store is consumed by the merge; one pointing
            # elsewhere still has to reach the linker.
            if not _is_ours(d):
                rest.append(f)
        elif f.startswith("-l"):
            hit = next((d / f"lib{f[2:]}.a" for d in libdirs
                        if (d / f"lib{f[2:]}.a").is_file() and _is_ours(d)), None)
            if hit is not None:
                ours.append(hit)
            else:
                rest.append(f)
        elif f.endswith(".a") and _is_ours(Path(f)):
            ours.append(Path(f))
        else:
            rest.append(f)
    # SORTED, because this feeds `ar` and the artifact must reproduce. pkg-config
    # emits topological link order, which is meaningless once every object lives
    # in one archive with an index — but a set iterated in a varying order would
    # change the member sequence and therefore the bytes.
    return sorted(set(ours)), rest


def protoc_c(cp: configparser.ConfigParser | None = None,
             store: Path | None = None) -> str:
    """The GENERATOR — a build-host TOOL, so it comes from the NATIVE set.

    `protoc-c` runs where code is GENERATED, not where the code it generates is
    compiled to. A cross lineage's protobuf-c is configured `--disable-protoc`
    and ships no binary at all — that is `CROSS_ORDER`'s argument seen from the
    other end — so asking the cross prefix for it asks for something that cannot
    exist there:

        error: '…/protobuf-c-1.5.2-af325b1d479f39ea/bin/protoc-c' not on PATH

    So one dependency is consumed from two lineages, deliberately: the generator
    from the native set, and the `libprotobuf-c.a` that is SHIPPED from the cross
    set (`libprotobuf_c`, below). "Generator and runtime must come from one
    place" is a VERSION constraint and deps.lock pins one protobuf-c that
    both lineages build; it is not an architecture constraint, because the
    generator emits portable C.

    Read through the MANIFEST rather than by deriving a key, because no key can
    be derived here: `store_key` folds the local compiler, which in this step is
    `emcc`. That is the case `write_manifest` exists for — "a consumer with a
    different one cannot find a prefix that is sitting right there" — and it
    checks the prebuilt set against this tree's pins on the way through, so an
    image older than deps.lock fails loudly instead of generating with a skewed
    protoc.
    """
    cp = cp or lock()
    native = native_store_dir()
    if cross_toolchain() and native is not None:
        entry = (_manifest(native) or {}).get("protobuf-c")
        if entry is None:
            raise SystemExit(
                f"vendor: this is a cross build and {NATIVE_STORE_ENV}={native} "
                f"has no manifest row for protobuf-c. The cross set cannot "
                f"supply a generator — it is built --disable-protoc — so the "
                f"native set the image inherited is the only source for one, "
                f"and it is absent or half-built."
            )
        return str(_prefix_from_manifest("protobuf-c", cp["protobuf-c"],
                                         entry, native) / "bin" / "protoc-c")
    return str(prefixes(cp, store)["protobuf-c"] / "bin" / "protoc-c")


def libprotobuf_c(cp: configparser.ConfigParser | None = None,
                  store: Path | None = None) -> str:
    """The archive COPIED INTO the tarball — the one shipped byte-for-byte from
    this set, and the reason `_find_libprotobuf_c`'s `find /usr/lib` had to go."""
    return str(prefixes(cp, store)["protobuf-c"] / "lib" / "libprotobuf-c.a")


def main(argv: list[str]) -> int:
    """`vendor.py <dep|all> <stamp>` — build one row, then write the step's Output.

    The stamp is the declared Output, not the installed prefix: a prefix is a
    directory of many files under a content-addressed path, and what a consumer
    needs is "this dep is installed, and WHICH one". So the stamp carries the
    store key, which means a changed pin changes the stamp and everything
    downstream re-runs — the property that makes vendoring visible to the step
    key at all.

    `all` builds nothing itself; its Consumes edges have already forced the
    four, and it exists so `libds.a` can demand one name.
    It still verifies rather than trusting the graph: a stamp asserting the set
    is present, written without checking, is the fallback-shaped green this
    project keeps finding.
    """
    global _attest_path
    # `--write-manifest` publishes what the store contains, for consumers that
    # must not recompute a key with their own compiler (PROPOSAL §4). Separate
    # from the build so it runs LAST, after `all` has verified every prefix: a
    # manifest written mid-build would advertise a store that is not there yet.
    if len(argv) == 2 and argv[1] == "--write-manifest":
        store = store_dir()
        if store is None:
            print(f"vendor: --write-manifest needs {STORE_ENV} or a mounted "
                  f"store; there is nothing to describe", file=sys.stderr)
            return 2
        print(f"vendor: manifest -> {write_manifest(store)}", flush=True)
        return 0
    # THE OUTPUTS ARRIVE AS A SET, NOT A FIXED ARITY. The step's argv is
    # `vendor.py <dep> {outputs}`, and P2b gave the per-dep steps a SECOND
    # declared Output (the attest document) — so `{outputs}` began materialising
    # two paths and this parser, which demanded exactly three argv, exited 2 on
    # every vendor step in the fleet. Nothing caught it until the gate ran,
    # because the same commit added the Output and the reader that could not
    # cope with it.
    #
    # Classified by SUFFIX rather than by position, because `{outputs}` orders
    # by the graph's declarations and pinning a recipe to that order makes an
    # unrelated edit to a buildfile silently pass the wrong file. The fan-in
    # step (`vendor.py all`) declares only the stamp and still works.
    if len(argv) < 3 or argv[1] not in (*ORDER, "all"):
        print(f"usage: vendor.py <{'|'.join(ORDER)}|all> <stamp> [attest.tsv]",
              file=sys.stderr)
        return 2
    name = argv[1]
    paths = [Path(a) for a in argv[2:]]
    stamps = [p for p in paths if p.suffix == ".stamp"]
    attests = [p for p in paths if p.suffix == ".tsv"]
    if len(stamps) != 1 or len(attests) > 1 or len(stamps) + len(attests) != len(paths):
        print(f"usage: vendor.py <{'|'.join(ORDER)}|all> <stamp> [attest.tsv] — "
              f"got {[str(p) for p in paths]}, which is not one .stamp and at "
              f"most one .tsv", file=sys.stderr)
        return 2
    stamp = stamps[0]
    if attests:
        _attest_path = str(attests[0])
        # Truncated, not appended to. The document is this STEP's verdicts and
        # the checkout outlives the step: a re-run in a synced tree would
        # otherwise stack today's rows on yesterday's and the parsed facts would
        # claim a product was attested twice.
        open(_attest_path, "w", encoding="utf-8").close()
    cp = lock()
    work = Path(os.environ.get("DS_VENDOR_WORK", "vendor-work"))
    if name == "all":
        lines = []
        # `order_for()`, not `ORDER` — the fan-in stamp asserts the set that was
        # built, and on a cross lineage that set is `CROSS_ORDER`. Iterating the
        # native one demands a prefix no cross row produces.
        for dep in order_for():
            prefix = prefix_for(dep, cp[dep], cp=cp)
            if not (prefix / ".vendor-ok").exists():
                raise SystemExit(
                    f"vendor: `all` was asked for a stamp but {dep} is not "
                    f"installed at {prefix}. Its Consumes edge should have "
                    f"built it — a stamp written anyway would assert a set that "
                    f"is not there."
                )
            lines.append(f"{dep} {cp[dep]['version']} {prefix.name}")
    else:
        prefix = build(name, work=work, cp=cp)
        lines = [f"{name} {cp[name]['version']} {prefix.name}"]
    stamp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

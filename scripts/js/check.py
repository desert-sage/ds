#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""js: build the module and run its suite, from the public tree.

    python3 scripts/js/check.py --libds runtime/src/libds/libds.a
    python3 scripts/js/check.py --target wasm

Run from anywhere; paths are the repository's. Both targets need Node >= 20
and Python >= 3.12.

The native target (the default) also needs a Mercury `dsc` to compile the
test fixtures (`--dsc PATH`, or `DS_MERCURY_DSC`, or `dsc` on `PATH`), a C
compiler and a C++ driver,
`pkg-config` with RE2's and protobuf-c's `.pc` files, and a built `libds.a`
(PORTING.md says how).

The wasm target builds its own `libds.a` and its own compiler, so it needs
what those take: emsdk 3.1.74, activated (`emcc`, `em++`, `emar`, `emranlib`,
`emnm` and `em-config` on `PATH`); `cmake`, GNU `make`, `curl`, `pkg-config`
and `cosign`, which verifies RE2's signature; a NATIVE `protoc-c`, protobuf-c
1.x, to generate libds's protobuf sources (`--protoc-c PATH`, or `PROTOC_C`,
or `protoc-c` on `PATH`); and Mercury 22.01.8 cross-built for
`wasm32-unknown-emscripten`, grade `hlc`, as `runtime/docker/ds-emsdk.Dockerfile`
builds it with `scripts/vendor/mercury-wasm32.py`'s patches (`--mmc-wasm32
PATH`, or `MMC_WASM32`: its `bin/mmc`). The protobuf-c it links, and the RE2
and Abseil both link, are built here, at the pins.

## The check, in order

1. `tsc --checkJs`, strict, over `lib/` (JS_STYLE.md JS.13), and the
   declarations it writes held to the committed `types/`.
2. On the native target, `test/fixtures/*.ds` compiled by the `dsc`. (On
   the wasm target this comes after 3, by the compiler 3 built.)
3. On the native target: the glue (`src/ds.c`) compiled against the
   pinned Node-API headers and linked with `libds.a` by the C++ driver, since
   `libds.a` carries RE2's C++ objects (DISTRIBUTION.md).
   On the wasm target: Abseil, RE2 and protobuf-c built for wasm32 at
   `vendor/deps.lock`'s pins, by `scripts/vendor/vendor.py` under emsdk's cmake toolchain
   file; `libds.a` built for wasm32 by its projected Makefile under emcc; and
   the SAME glue compiled by emcc against the pinned emnapi and linked by em++
   into `build/ds_wasm.mjs`. Then the compiler, ds_dsc: the
   Mercury `dsc` for wasm32, by `mercury.mk`'s `dsc_cli_wasm32` (the Makefile
   projected from mercury.build) with that RE2 and Abseil, packaged into
   `build/ds_dsc/` with the standard library beside it.
4. Every `test/*.test.mjs` under `node --test` on that target; on wasm, with
   ds_dsc as the compiler its wasm runner's tests run.

IT READS NOTHING OUTSIDE THE PUBLIC TREE: the repository's private
CI, tooling and image directories leave it at 1.0.0. `scripts/vendor/vendor.py` is public,
kept because every `libds.a` is
built from the set it pins. The CI lane, which is
private, imports these functions and adds what only it needs: the vendored
link set, the `coverage.tsv` check, dsdb's suite beside this one, and a wasm
lane over the release's own wasm archive.

THE PINNED PACKAGES ARE FETCHED AND REFUSED UNLESS npm's INTEGRITY DIGEST
MATCHES: the Node-API headers (nodejs's `node-api-headers`, since a Node
install need not ship `node_api.h`), the wasm target's emnapi, the type
check's TypeScript and Node types, and the TextMate grammar check's tokenizer (`vscode-textmate`,
`vscode-oniguruma`); and the tree-sitter grammar check's CLI, tree-sitter's own
release binary for this machine, refused unless its sha512 matches. Node-API is ABI-stable, so the headers build a module every Node at or
above the NAPI_VERSION in ds.c loads. A verified tarball is kept in
the directory `DS_NPM_STORE` names, and read from there first.
"""
from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PKG = ROOT / "bindings" / "js"
# ds_names.h: the enum names @ds-lang/ds shares with pyds (header-only).
BINDINGS = ROOT / "runtime" / "src" / "bindings"
WORK = ROOT / ".build" / "js"

# nodejs/node-api-headers -- MIT. npm's own dist.integrity for this version.
NODE_API_HEADERS = (
    "1.9.0",
    "https://registry.npmjs.org/node-api-headers/-/node-api-headers-1.9.0.tgz",
    "2oNILP4jXwRB4ywnYKjVk1YyJ96n2D4EOVJO6S3oYZ5PtbJrw3Yt9TpAuX3nBLMuzn74rnfGQrv13pS9vC+YiA==",
)

# The type check (JS_STYLE.md JS.13), pinned and fetched as the headers are.
# TypeScript 6.0 is JavaScript, so Node runs it on either architecture. Node's
# types are at the floor package.json declares (node >= 20), so a call newer
# than Node 20 fails the check; undici-types is @types/node's one dependency,
# laid beside it so tsc finds it as npm would. npm's dist.integrity for each,
# without its `sha512-`.
TYPECHECK = {
    "typescript": ("https://registry.npmjs.org/typescript/-/typescript-6.0.3.tgz",
                   "y2TvuxSZPDyQakkFRPZHKFm+KKVqIisdg9/CZwm9ftvKXLP8NRWj38/ODjNbr43SsoXqNuAisEf1GdCxqWcdBw=="),
    "@types/node": ("https://registry.npmjs.org/@types/node/-/node-20.19.43.tgz",
                    "6oYBAi5ikg4Pl+kGsoYtawUMBT2zZMCvPNF7pVLnHZfd1zf38DRiWn/gT01RYCdUqkv7Fhr+C9ot4/tb+2sVvA=="),
    "undici-types": ("https://registry.npmjs.org/undici-types/-/undici-types-6.21.0.tgz",
                     "iwDZqg0QAGrg9Rav5H4n0M64c3mkR59cJ6wQp+7C4nI0gsmExaedaYLNO44eT4AtBBwjbTiGPMlt2Md0T9H9JQ=="),
}



def say(msg: str) -> None:
    print(f"=== {msg} ===", flush=True)


def run(*argv, env: dict | None = None, cwd: Path | None = None) -> None:
    print("+ " + " ".join(str(a) for a in argv), flush=True)
    subprocess.run([str(a) for a in argv], check=True, cwd=cwd,
                   env={**os.environ, **env} if env else None)


def _unpack_npm(blob: bytes, tgz: Path, dest: Path) -> None:
    """An npm tarball, kept at `tgz`, unpacked from its `package/` into `dest`.
    The tarball is kept OUTSIDE any node_modules: one inside `@types/` would
    sit where tsc looks for type packages."""
    tgz.parent.mkdir(parents=True, exist_ok=True)
    tgz.write_bytes(blob)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(tgz) as t:
        for m in t.getmembers():
            parts = Path(m.name).parts[1:]           # npm tarballs: package/
            if parts:
                m.name = str(Path(*parts))
                t.extract(m, dest, filter="data")


# THE PINNED TARBALLS ARE KEPT, not fetched on every cold run. WORK is
# per checkout, so a fresh one fetched every package from the registry, and a
# registry 5xx failed the check for a change that had nothing to do with it. A
# verified tarball is kept in the store, named by its sha512, and read from
# there first; the integrity check stays the gate, so a kept tarball is exactly
# as trustworthy as a fresh one. The store is the directory `DS_NPM_STORE`
# names, else `/ds-cache/npm` where `/ds-cache` exists (the CI images' shared
# store); with neither, nothing is kept.
NPM_STORE_ENV = "DS_NPM_STORE"
DEFAULT_NPM_STORE = Path("/ds-cache/npm")

# A fetch that fails for a reason the next one may not (a 5xx, a refused or
# dropped connection, a timeout) is tried again, this many times in all, after
# 5, 10 and 20 seconds. A 4xx is the URL's fault and fails at once.
FETCH_ATTEMPTS = 4


def _npm_store() -> Path | None:
    env = os.environ.get(NPM_STORE_ENV)
    if env:
        return Path(env)
    return DEFAULT_NPM_STORE if DEFAULT_NPM_STORE.parent.is_dir() else None


def _integrity_of(blob: bytes) -> str:
    """npm's dist.integrity for `blob`, without its `sha512-`."""
    return base64.b64encode(hashlib.sha512(blob).digest()).decode()


def _download(label: str, url: str) -> bytes:
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == FETCH_ATTEMPTS:
                raise
            why = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == FETCH_ATTEMPTS:
                raise
            why = str(getattr(e, "reason", e))
        wait = 5 * 2 ** (attempt - 1)
        print(f"js: {label}: {why} from the registry; try {attempt + 1} of "
              f"{FETCH_ATTEMPTS} in {wait}s", flush=True)
        time.sleep(wait)
    raise AssertionError("unreachable")


def _keep(kept: Path, blob: bytes, label: str) -> None:
    """`blob`, verified, written to the store as `kept`: by a rename, so a
    reader never meets half a file. A store it cannot write is reported and
    passed over; the blob is still good."""
    try:
        kept.parent.mkdir(parents=True, exist_ok=True)
        part = kept.with_name(f".{kept.name}.{os.getpid()}")
        part.write_bytes(blob)
        part.replace(kept)
    except OSError as e:
        print(f"js: {label}: not kept in {kept.parent} ({e})", flush=True)


def _fetch_pinned(label: str, url: str, integrity: str) -> bytes:
    """A pinned tarball's bytes, verified against `integrity`: the store's
    copy if it has a good one, else the registry's, kept for the next run."""
    store = _npm_store()
    kept = store / f"{base64.b64decode(integrity).hex()}.tgz" if store else None
    if kept is not None and kept.is_file():
        blob = kept.read_bytes()
        if _integrity_of(blob) == integrity:
            print(f"js: {label}: from the store, {kept}", flush=True)
            return blob
        print(f"js: {label}: the store's copy does not verify; fetching", flush=True)
    blob = _download(label, url)
    if _integrity_of(blob) != integrity:
        raise SystemExit(f"js: {label}: integrity mismatch -- refusing it")
    if kept is not None:
        _keep(kept, blob, label)
    return blob


def node_api_headers() -> Path:
    """The pinned Node-API headers' include directory, fetched and verified."""
    ver, url, integrity = NODE_API_HEADERS
    dest = WORK / f"node-api-headers-{ver}"
    inc = dest / "include"
    if (inc / "node_api.h").is_file():
        return inc
    blob = _fetch_pinned(f"node-api-headers {ver}", url, integrity)
    _unpack_npm(blob, WORK / f"node-api-headers-{ver}.tgz", dest)
    print(f"js: node-api-headers {ver} (sha512 verified) -> {inc}", flush=True)
    return inc


def npm_package(name: str, pins: dict[str, tuple[str, str]] | None = None) -> Path:
    """A pinned npm package, fetched, verified and unpacked under one
    node_modules, so packages that depend on each other resolve as npm lays
    them out. `pins` defaults to the type check's."""
    url, integrity = (pins or TYPECHECK)[name]
    dest = WORK / "npm" / "node_modules" / name
    if (dest / "package.json").is_file():
        return dest
    blob = _fetch_pinned(name, url, integrity)
    _unpack_npm(blob, WORK / "npm" / f"{name.replace('/', '__')}.tgz", dest)
    print(f"js: {name} (sha512 verified) -> {dest}", flush=True)
    return dest




def _with_header(decl: Path, out: Path) -> str:
    """A declaration tsc wrote, opening with the SPDX lines of the lib/ file it
    declares: tsc carries a JSDoc comment into a .d.ts and drops a `//` one, so
    without this every declaration would be the one file in the package with
    no header. A source with none is refused rather than passed over."""
    src = PKG / "lib" / decl.relative_to(out).with_name(
        decl.name[:-len(".d.ts")] + ".js")
    head = [line for line in src.read_text(encoding="utf-8").split("\n")[:15]
            if line.startswith("// SPDX-")]
    if not head:
        raise SystemExit(f"js: {src.relative_to(ROOT)} carries no SPDX header "
                         "for its declaration to take")
    return "\n".join(head) + "\n" + decl.read_text(encoding="utf-8")


def typecheck() -> None:
    """`tsc --checkJs`, strict, over lib/ (JS_STYLE.md JS.13), and the
    declarations it writes against the committed types/, which ship with the
    package: a stale or hand-edited .d.ts is a red build, as status.js's is.
    On a difference it prints the diff, which is what to commit."""
    say("js: tsc --checkJs, strict, and the declarations it writes")
    tsc = npm_package("typescript") / "bin" / "tsc"
    node_types = npm_package("@types/node")
    npm_package("undici-types")
    out = WORK / "types"
    if out.exists():
        shutil.rmtree(out)
    run("node", tsc, "-p", PKG / "tsconfig.json", "--typeRoots", node_types.parent, "--outDir", out)
    committed = PKG / "types"
    want = {p.relative_to(out).as_posix(): _with_header(p, out) for p in sorted(out.rglob("*.d.ts"))}
    have = {p.relative_to(committed).as_posix(): p.read_text(encoding="utf-8")
            for p in sorted(committed.rglob("*.d.ts"))} if committed.is_dir() else {}
    if not want:
        raise SystemExit("js: tsc wrote no declarations -- the check proved nothing")
    if want == have:
        print(f"js: {len(want)} declaration files, each as committed", flush=True)
        return
    for name in sorted(set(want) | set(have)):
        if want.get(name) == have.get(name):
            continue
        print("".join(difflib.unified_diff(have.get(name, "").splitlines(keepends=True),
                                           want.get(name, "").splitlines(keepends=True),
                                           f"committed/types/{name}", f"tsc/types/{name}")), flush=True)
    raise SystemExit("js: bindings/js/types/ is not what tsc writes from lib/; "
                     "the diff above is what to commit")


def pkg_config_libs() -> list[str]:
    """The platform libraries `libds.a` needs, as `pkg-config` names them."""
    libs = subprocess.run(["pkg-config", "--libs", "re2", "libprotobuf-c"],
                          check=True, capture_output=True, text=True).stdout.split()
    return [*libs, "-lpthread", "-lm"]


# The glue's exploit mitigations: libds.build's portable `harden` set, which
# CI's HARDEN states and a pin holds equal to this.
# The architecture's CET or BTI flag is the caller's, as libds.build's
# `harden_cfi` is: empty by default, because gcc refuses each on the other
# architecture. A linker ANDs the CET and BTI notes of every object, so glue
# without them strips them from the module.
HARDEN = ("-fstack-protector-strong -D_FORTIFY_SOURCE=3 "
          "-fstack-clash-protection -ftrivial-auto-var-init=zero")
RELRO_NOW = "-Wl,-z,relro,-z,now"


def build_native(libds: Path, link_libs: list[str], out: Path | None = None, *,
                 harden: str = HARDEN, harden_cfi: str = "") -> Path:
    """build/ds.node from `libds` and the glue, or `out` for a caller
    that must not share that file.

    A CALLER BESIDE ANOTHER BUILD PASSES ITS OWN `out` (the binding
    differential): two steps writing one `.node` race, one replacing
    the module the other has loaded or is linking. The object file goes beside
    `out` for the same reason.

    `harden` and `harden_cfi` go on the compile, and RELRO_NOW on the link,
    always. A build linking an instrumented libds.a passes `harden=""`, as
    the instrumented lanes build libds."""
    say("js native: compile the glue (C), link with the C++ driver")
    if not libds.is_file():
        raise SystemExit(f"js: no {libds} -- build libds.a first (PORTING.md)")
    inc = node_api_headers()
    if out is None:
        out = PKG / "build" / "ds.node"
        obj = WORK / "ds.o"
    else:
        obj = out.with_suffix(".o")
    out.parent.mkdir(parents=True, exist_ok=True)
    obj.parent.mkdir(parents=True, exist_ok=True)
    run("gcc", "-c", "-fPIC", "-O2", "-std=c11", "-Wall", "-Wextra",
        *harden.split(), *harden_cfi.split(),
        f"-I{inc}", f"-I{ROOT / 'runtime' / 'include'}", f"-I{BINDINGS}",
        # rfcs/rfcs.h, from where the tarball's include/internal/ copies it.
        f"-I{ROOT / 'runtime' / 'src' / 'libds'}",
        PKG / "src" / "ds.c", "-o", obj)
    # The C++ driver: libds.a carries ds_re2.o (DISTRIBUTION.md).
    run("g++", "-shared", "-fPIC", RELRO_NOW, obj, libds, *link_libs, "-o", out)
    return out


# ── the wasm target ──────────────────────────────────────────────────
#
# THE SAME GLUE, compiled by emcc against emnapi (Node-API for Emscripten) and
# linked with a wasm32 libds.a that this builds as a newcomer would: no
# build-unit, nothing private. The release's wasm archive comes from the
# release graph and has RE2 and Abseil folded into it; this one links them
# beside it, which a module link cannot tell apart.

# emnapi — Node-API for Emscripten (MIT). npm's own dist.integrity; the pins
# the R0 probe measured, and the CI lane's.
EMNAPI = {
    "emnapi": ("https://registry.npmjs.org/emnapi/-/emnapi-1.11.3.tgz",
               "+/ZS90YK/rYfVOHtGLHkGffVsnmD/MAKaBHio+Y4XAtg75RLr4cveV/w0jTkUdLM1CcAlaRgG76mpIemWAlk0A=="),
    "emnapi-runtime": ("https://registry.npmjs.org/@emnapi/runtime/-/runtime-1.11.3.tgz",
                       "Xz4Tpyki7XyrpbUK1jR1AhdAdaXyhhY4lZ3neLodmhpuWfy2PAQN5B46sAiU4liOXGLkHypn/qU+jvfWSCYYLA=="),
}

# The pinned set's one recipe: what fetches, verifies and builds Abseil, RE2
# and protobuf-c at vendor/deps.lock's pins, for every libds.a there is.
VENDOR = ROOT / "scripts" / "vendor" / "vendor.py"

# A threading request, to emcc: either one links the `-mt` sysroot and asks
# wasm-ld for shared memory, which the single-threaded Abseil refuses. libds
# is thread-free by construction, so neither belongs on a wasm link; RE2's
# `.pc` file brings `-pthread` with it.
THREAD_REQUESTS = ("-pthread", "-lpthread")


def _vendor():
    """scripts/vendor/vendor.py, loaded by path under a name of its own, as the CI lane
    loads this file."""
    if "ds_vendor" in sys.modules:
        return sys.modules["ds_vendor"]
    spec = importlib.util.spec_from_file_location("ds_vendor", VENDOR)
    module = importlib.util.module_from_spec(spec)
    sys.modules["ds_vendor"] = module
    spec.loader.exec_module(module)
    return module


def emsdk() -> tuple[dict[str, str], Path]:
    """emsdk's tools, as its activation leaves them on PATH, and its cmake
    toolchain file. `LD` is wasm-ld, by absolute path: libds's partial links
    (`$(LD) -r`) need it, the host `ld` cannot read a wasm object, and
    activation does not put it on PATH."""
    emcc = shutil.which("emcc")
    if emcc is None:
        raise SystemExit("js: no emcc on PATH -- the wasm target needs emsdk, activated")
    run("emcc", "--version")
    llvm = subprocess.run(["em-config", "LLVM_ROOT"], check=True,
                          capture_output=True, text=True).stdout.strip()
    tools = {"CC": "emcc", "CXX": "em++", "AR": "emar", "RANLIB": "emranlib",
             "NM": "emnm", "LD": str(Path(llvm) / "wasm-ld")}
    toolchain = Path(emcc).resolve().parent / "cmake" / "Modules" / "Platform" / "Emscripten.cmake"
    for need in (Path(tools["LD"]), toolchain):
        if not need.is_file():
            raise SystemExit(f"js: emsdk has no {need}")
    return tools, toolchain


def wasm_deps(tools: dict[str, str], toolchain: Path) -> dict[str, Path]:
    """Each dependency libds.a takes, built for wasm32 by `scripts/vendor/vendor.py` into
    a store under WORK, by name. Its cross set (`CROSS_ORDER`): no protobuf,
    because only protoc-c links it, and protoc-c runs where code is generated.
    A prefix already built is reused; the store key holds its pin and its
    toolchain."""
    say("js wasm: Abseil, RE2 and protobuf-c for wasm32, at the pins (scripts/vendor/vendor.py)")
    work = WORK / "wasm"
    work.mkdir(parents=True, exist_ok=True)
    store = work / "vendor"
    env = {**tools, "DS_VENDOR_TOOLCHAIN_FILE": str(toolchain),
           "DS_VENDOR_STORE": str(store), "DS_VENDOR_WORK": str(work / "vendor-work")}
    prefixes = {}
    for dep in _vendor().CROSS_ORDER:
        stamp = work / f"{dep}.stamp"
        run(sys.executable, VENDOR, dep, stamp, work / f"{dep}.attest.tsv", env=env, cwd=work)
        name, _version, prefix = stamp.read_text(encoding="utf-8").split()
        prefixes[name] = store / prefix
    return prefixes


def wasm_libds(tools: dict[str, str], prefixes: dict[str, Path], protoc_c: str) -> Path:
    """libds.a for wasm32, by the projected Makefile (PORTING.md) under emcc.

    IN A COPY OF ITS DIRECTORY, so a native build beside it in the tree is left
    alone: the Makefile writes its objects and archive where it runs. Only the
    sources are copied, no product; what the recipes read beside it (the public
    header, the allocator probe's two headers every object's rule names, the
    protos, the vendored sources) is linked in. The version is the
    tree's own, as the Makefile would derive it in place."""
    say("js wasm: libds.a for wasm32, by its projected Makefile under emcc")
    if not protoc_c or not Path(protoc_c).is_file():
        raise SystemExit(f"js: no native protoc-c at {protoc_c!r} -- pass --protoc-c, "
                         "or set PROTOC_C")
    tree = WORK / "wasm" / "tree"
    if tree.exists():
        shutil.rmtree(tree)
    src = tree / "runtime" / "src" / "libds"
    shutil.copytree(ROOT / "runtime" / "src" / "libds", src, symlinks=True,
                    ignore=shutil.ignore_patterns("*.o", "*.a", "*.pb-c.c", "*.pb-c.h",
                                                  "version.stamp"))
    for rel in ("runtime/include", "runtime/tests/libds/alloc_conformance", "proto", "vendor"):
        (tree / rel).parent.mkdir(parents=True, exist_ok=True)
        (tree / rel).symlink_to(ROOT / rel, target_is_directory=True)
    version = subprocess.run([sys.executable, ROOT / "scripts" / "build" / "ds-version.py", ROOT],
                             check=True, capture_output=True, text=True).stdout.strip()
    # RE2's headers include Abseil's, and the protobuf-c sources include
    # protobuf-c's: one -I per prefix, as the release's wasm row passes them.
    cflags = " ".join(f"-I{p / 'include'}" for p in prefixes.values())
    run("make", "-C", src, f"-j{os.cpu_count() or 1}",
        *(f"{var}={tools[var]}" for var in ("CC", "CXX", "AR", "LD")),
        f"PROTOC_C={protoc_c}", f"VERSION={version}", f"CFLAGS_EXTRA={cflags}")
    return src / "libds.a"


def re2_link(prefixes: dict[str, Path]) -> list[str]:
    """RE2 and the Abseil archives it needs, statically, as RE2's `.pc` names
    them: pkg-config looks in these prefixes and nowhere else, so a system RE2
    cannot answer. Without its threading requests."""
    pc = os.pathsep.join(str(prefixes[d] / "lib" / "pkgconfig") for d in ("abseil", "re2"))
    libs = subprocess.run(["pkg-config", "--static", "--libs", "re2"], check=True,
                          capture_output=True, text=True,
                          env={**os.environ, "PKG_CONFIG_LIBDIR": pc, "PKG_CONFIG_PATH": ""}
                          ).stdout.split()
    return [f for f in libs if f not in THREAD_REQUESTS]


def wasm_glue(includes: list[Path], link: list[str | Path]) -> tuple[Path, Path]:
    """build/ds_wasm.mjs, with its .wasm beside it: the glue compiled
    by emcc against emnapi, then linked by em++ with `link` (libds.a, the
    protobuf-c runtime, what they need). `includes` find libds.h and
    `rfcs/rfcs.h`. Returns the module and the emnapi runtime it is
    initialised with."""
    say("js wasm: the glue, by emcc against emnapi (the same ds.c)")
    emnapi = npm_package("emnapi", EMNAPI)
    runtime = npm_package("emnapi-runtime", EMNAPI)
    # An ES module (-sEXPORT_ES6), because @ds-lang/ds is one: a MODULARIZE'd
    # CommonJS glue inside a `"type": "module"` package is read as ESM and
    # `require()` refuses it. `import()` is also the browser's form.
    out = PKG / "build" / "ds_wasm.mjs"
    out.parent.mkdir(parents=True, exist_ok=True)
    obj = WORK / "ds_wasm.o"
    run("emcc", "-c", "-O2", "-std=c11", "-Wall", "-Wextra",
        f"-I{emnapi}/include/node", *(f"-I{d}" for d in includes), f"-I{BINDINGS}",
        PKG / "src" / "ds.c", "-o", obj)
    exported = ("['_malloc','_free','_napi_register_wasm_v1',"
                "'_node_api_module_get_api_version_v1']")
    run("em++", "-O2", obj, *link,
        f"-L{emnapi}/lib/wasm32-emscripten", "-lemnapi",
        f"--js-library={emnapi}/dist/library_napi.js",
        "-sWASM_BIGINT=1",                 # int64 across the boundary, exactly
        "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sEXPORT_NAME=createDsWasm",
        "-sALLOW_MEMORY_GROWTH=1",
        f"-sEXPORTED_FUNCTIONS={exported}",
        "-sEXPORTED_RUNTIME_METHODS=['emnapiInit']",
        "-o", out)
    return out, runtime


def build_wasm(protoc_c: str, tools: dict[str, str] | None = None,
               prefixes: dict[str, Path] | None = None) -> tuple[Path, Path]:
    """The wasm target from the public tree: the pinned set, libds.a, then the
    glue linked against them. Returns `wasm_glue`'s module and runtime. A
    caller that has run `emsdk` and `wasm_deps` already passes what they
    returned."""
    if tools is None or prefixes is None:
        tools, toolchain = emsdk()
        prefixes = wasm_deps(tools, toolchain)
    libds = wasm_libds(tools, prefixes, protoc_c)
    libprotobuf_c = prefixes["protobuf-c"] / "lib" / "libprotobuf-c.a"
    return wasm_glue([ROOT / "runtime" / "include", libds.parent],
                     [libds, libprotobuf_c, *re2_link(prefixes), "-lm"])


# ── the wasm compiler, ds_dsc ──────────────────────────
#
# THE MERCURY `dsc` FOR wasm32, as mercury.mk builds it: `dsc_cli_wasm32`, the
# Makefile projected from mercury.build, whose `mercury-wasm32-*` steps the
# release builds the same compiler from. Nothing here compiles a unit or
# names a link flag; the Makefile does. What it is handed is what ds-emsdk's
# image carries: the cross `mmc`, `wasm-ld`, and a directory of the wasm32 RE2
# and Abseil it links, here the ones `wasm_deps` built.

def wasm_dsc_deps(prefixes: dict[str, Path]) -> Path:
    """mercury.mk's WASM32_DEPS, laid out as ds-emsdk lays out /opt/ds-wasm32:
    `re2` and `abseil` naming the prefixes `wasm_deps` built, and
    `re2-link.rsp`, their static link line as a wasm-ld response file, every
    archive in one group so wasm-ld resolves their references to each other
    in any order."""
    deps = WORK / "wasm" / "mercury-deps"
    if deps.exists():
        shutil.rmtree(deps)
    deps.mkdir(parents=True)
    for name in ("re2", "abseil"):
        (deps / name).symlink_to(prefixes[name], target_is_directory=True)
    re2 = deps / "re2" / "lib" / "libre2.a"
    abseil = sorted((deps / "abseil" / "lib").glob("*.a"))
    if not re2.is_file() or not abseil:
        raise SystemExit(f"ds_dsc: no wasm32 RE2 and Abseil archives under {deps}")
    lines = ["--start-group", str(re2), *map(str, abseil), "--end-group"]
    (deps / "re2-link.rsp").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return deps


def dsc_library() -> str:
    """The standard library as ds_dsc's `library` export: every
    `stdlib/**/*.ds` by its path below `stdlib/`, its text a JSON string
    literal, ASCII with every other code point escaped, so the text the
    runner writes back is the file's to the byte.

    [LIMP.3.3.1], [RCLI.1.11]: the wasm compiler
    has no file system of its own, so its package carries the library, and
    @ds-lang/ds's runner (lib/dsc-wasm.js) writes each file at
    `../share/ds/stdlib` from the program's path before `main`."""
    stdlib = ROOT / "stdlib"
    files = sorted(stdlib.rglob("*.ds"))
    if not any(f.relative_to(stdlib).as_posix() == "units/core.ds" for f in files):
        raise SystemExit("ds_dsc: no stdlib/units/core.ds to package; every compile reads it")
    entries = ",\n".join(
        f"    {json.dumps(f.relative_to(stdlib).as_posix())}: "
        f"{json.dumps(f.read_text(encoding='utf-8'))}"
        for f in files)
    return ("\n// The standard library this compiler ships with ([LIMP.3.3.1],\n"
            "// [RCLI.1.11]), generated from stdlib/ by scripts/js/check.py.\n"
            "export const library = Object.freeze({\n" + entries + "\n});\n")


def package_dsc(dsc_cli: Path, dest: Path) -> Path:
    """ds_dsc as the package lays it out, in `dest`: the ES module
    Emscripten linked, with the standard library appended as its `library`
    export (`dsc_library`), as `ds_dsc.mjs`, and its wasm beside it
    as `dsc_cli.wasm`. Returns the module."""
    wasm = dsc_cli.with_name(dsc_cli.name + ".wasm")
    if not dsc_cli.is_file() or not wasm.is_file():
        raise SystemExit(f"ds_dsc: the link made no {dsc_cli} and {wasm}")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    module = dest / "ds_dsc.mjs"
    module.write_bytes(dsc_cli.read_bytes() + dsc_library().encode("ascii"))
    shutil.copy(wasm, dest / "dsc_cli.wasm")
    for f in sorted(dest.iterdir()):
        print(f"  {f.name:24} {f.stat().st_size:>10} bytes", flush=True)
    return module


def build_wasm_dsc(tools: dict[str, str], prefixes: dict[str, Path],
                   mmc_wasm32: str) -> Path:
    """ds_dsc, built by mercury.mk's `dsc_cli_wasm32` from the tree and
    packaged into build/ds_dsc/, where the package looks for it
    (lib/index.js). Returns its module."""
    say("ds_dsc: the wasm32 dsc, by mercury.mk's dsc_cli_wasm32 under emcc")
    if not mmc_wasm32 or not Path(mmc_wasm32).is_file():
        raise SystemExit(f"ds_dsc: no cross mmc at {mmc_wasm32!r} -- pass --mmc-wasm32, "
                         "or set MMC_WASM32 (Mercury for wasm32, as ds-emsdk builds it)")
    deps = wasm_dsc_deps(prefixes)
    run("make", "-f", "mercury.mk", f"-j{os.cpu_count() or 1}", "dsc_cli_wasm32",
        f"MMC_WASM32={mmc_wasm32}", f"WASM32_DEPS={deps}", f"WASM_LD={tools['LD']}", cwd=ROOT)
    return package_dsc(ROOT / ".build" / "wasm32" / "mdsc" / "dsc_cli",
                       PKG / "build" / "ds_dsc")


def _fixtures(extra: list[Path] | None) -> tuple[list[Path], Path]:
    """test/fixtures/*.ds and any `extra` sources, and a fresh
    .build/js/fixtures/ for their .dsc. One directory, so one name
    space: two sources with one stem are refused."""
    out = WORK / "fixtures"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    srcs = sorted((PKG / "test" / "fixtures").glob("*.ds")) + list(extra or [])
    if not srcs:
        raise SystemExit("js: no fixtures -- a suite with nothing to load proves nothing")
    stems = [s.stem for s in srcs]
    if len(set(stems)) != len(stems):
        raise SystemExit(f"js: two fixtures share a name: {sorted(stems)}")
    return srcs, out


def compile_fixtures_wasm(compiler: Path, extra: list[Path] | None = None,
                          node: str = "node") -> Path:
    """test/fixtures/*.ds, and any `extra` sources, to
    .build/js/fixtures/ as .dsc, by ds_dsc through the
    package's own wasm runner (scripts/js/compile_fixtures.mjs): the wasm target's
    compiler is the one it built, so it needs no native `dsc`."""
    say("js: compile the test fixtures with ds_dsc")
    srcs, out = _fixtures(extra)
    run(node, ROOT / "scripts" / "js" / "compile_fixtures.mjs", compiler, out, ROOT, *srcs)
    return out


def compile_fixtures(dsc: str, extra: list[Path] | None = None) -> Path:
    """test/fixtures/*.ds, and any `extra` sources, to .build/js/fixtures/
    as .dsc, by `dsc` (stdin to stdout, as pyds.compile does). One directory,
    so one name space: two sources with one stem are refused."""
    say("js: compile the test fixtures with the Mercury dsc")
    if not dsc or not Path(dsc).is_file():
        raise SystemExit(f"js: no dsc at {dsc!r} -- pass --dsc, or set DS_MERCURY_DSC")
    srcs, out = _fixtures(extra)
    for src in srcs:
        rel = src.relative_to(ROOT)
        p = subprocess.run([dsc, "compile", "-", "-o", "-", "--filename", str(rel)],
                           input=src.read_bytes(), capture_output=True)
        if p.returncode != 0:
            raise SystemExit(f"js: dsc refused {rel} (exit {p.returncode}):\n"
                             f"{p.stderr.decode(errors='replace')}")
        (out / (src.stem + ".dsc")).write_bytes(p.stdout)
        print(f"  {rel} -> {len(p.stdout)} bytes", flush=True)
    return out


def run_suite(target: str, fixtures: Path, junit: str | None = None, *,
              node: str = "node", extra_tests: list[Path] | None = None,
              extra_env: dict | None = None, lcov: str | None = None) -> None:
    """test/*.test.mjs, and any `extra_tests`, on one target: the `spec`
    reporter to the log, junit to `junit` when one is named, and, when `lcov`
    is named, Node's own line coverage of every module the suite loaded, as
    lcov, to that file (the `coverage` gate's JavaScript figures, ITST.10.9)."""
    say(f"js: the suite on the {target} target")
    tests = sorted(str(p) for p in (PKG / "test").glob("*.test.mjs")) \
        + [str(p) for p in (extra_tests or [])]
    if not tests:
        raise SystemExit("js: no *.test.mjs -- refusing a vacuous pass")
    env = {"DS_JS_TARGET": target, "DS_JS_FIXTURES": str(fixtures),
           **(extra_env or {})}
    if target == "native":
        env["DS_JS_NATIVE"] = str(PKG / "build" / "ds.node")
    reporters = ["--test-reporter=spec", "--test-reporter-destination=stdout"]
    if junit:
        reporters += ["--test-reporter=junit", f"--test-reporter-destination={junit}"]
    if lcov:
        reporters += ["--experimental-test-coverage", "--test-reporter=lcov",
                      f"--test-reporter-destination={lcov}"]
    run(node, "--test", *reporters, *tests, env=env)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Build @ds-lang/ds and run its suite.")
    ap.add_argument("--target", choices=("native", "wasm"), default="native",
                    help="the Node-API module (default), or the wasm32 module")
    ap.add_argument("--libds", type=Path,
                    help="native: the libds.a to link (PORTING.md builds one)")
    ap.add_argument("--protoc-c", default=os.environ.get("PROTOC_C") or shutil.which("protoc-c"),
                    help="wasm: the native protoc-c (default: PROTOC_C, else protoc-c on PATH)")
    ap.add_argument("--dsc", default=os.environ.get("DS_MERCURY_DSC") or shutil.which("dsc"),
                    help="the Mercury dsc (default: DS_MERCURY_DSC, else dsc on PATH)")
    ap.add_argument("--mmc-wasm32", default=os.environ.get("MMC_WASM32"),
                    help="wasm: the cross mmc that builds ds_dsc (default: MMC_WASM32)")
    ap.add_argument("--junit", help="also write the suite's junit report here")
    args = ap.parse_args(argv[1:])
    if args.target == "native" and args.libds is None:
        ap.error("the native target links a libds.a: pass --libds (PORTING.md builds one)")
    if args.target == "wasm" and args.libds is not None:
        ap.error("--libds is the native target's; the wasm target builds its own libds.a")
    if args.target == "wasm" and not args.mmc_wasm32:
        ap.error("the wasm target builds its compiler, ds_dsc: pass --mmc-wasm32, "
                 "or set MMC_WASM32")
    typecheck()
    # The suite's native-runner compile() tests run the dsc DS_MERCURY_DSC
    # names, and skip without one: the one --dsc names, by absolute path.
    dsc_env = {"DS_MERCURY_DSC": str(Path(args.dsc).resolve())} if args.dsc else {}
    if args.target == "native":
        fixtures = compile_fixtures(args.dsc)
        build_native(args.libds.resolve(), pkg_config_libs())
        run_suite("native", fixtures, args.junit, extra_env=dsc_env)
    else:
        tools, toolchain = emsdk()
        prefixes = wasm_deps(tools, toolchain)
        module, runtime = build_wasm(args.protoc_c, tools, prefixes)
        compiler = build_wasm_dsc(tools, prefixes, args.mmc_wasm32)
        fixtures = compile_fixtures_wasm(compiler)
        run_suite("wasm", fixtures, args.junit,
                  extra_env={**dsc_env, "DS_JS_WASM": str(module),
                             "DS_JS_EMNAPI_RUNTIME": str(runtime),
                             "DS_JS_DSC": str(compiler)})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""dsdb: its type check and suite on @ds-lang/ds, and the DS tools package, from
the public tree.

    python3 scripts/dsdb/check.py --libds runtime/src/libds/libds.a
    python3 scripts/dsdb/check.py --target wasm [--pack DIR]

dsdb runs on @ds-lang/ds, so this is @ds-lang/ds's own check,
`scripts/js/check.py`, with dsdb's beside it, and it takes that check's
arguments and needs its prerequisites, which its docstring states: on the wasm
target, emsdk, a native `protoc-c` and the cross `mmc`, and no native `dsc`.
Run from anywhere; paths are the repository's.

## The check, in order

1. `tsc --checkJs`, strict, over @ds-lang/ds's `lib/` and the declarations it
   ships, then over dsdb's `lib/`, which reads @ds-lang/ds through them
   (JS_STYLE.md JS.13, DSDB.md section 5).
2. The target, built as @ds-lang/ds's check builds it: on wasm, its libds, glue
   and compiler, ds_dsc.
3. @ds-lang/ds's fixtures and dsdb's (`test/fixtures/dsdb_*.ds`, one name space)
   compiled by that target's compiler.
4. One suite, @ds-lang/ds's `test/*.test.mjs` and dsdb's, under `node --test`,
   with the protocols' published schemas that dsdb's suite holds every `ds dap`
   and `ds lsp` message to (`PROTOCOL_SCHEMAS`).
5. With `--pack DIR`, on wasm only: `ds-tools-<version>.tgz` in DIR, by
   `scripts/dsdb/pack.mjs` over the glue and compiler step 2 built, bundling
   the `@emnapi/runtime` the glue was built against and the `tslib` it needs.
   `npm install --offline` of that file puts `ds` on PATH with
   nothing else (DISTRIBUTION.md). The version is the tree's, `VERSION`.

Every file fetched is pinned and refused unless it verifies: the npm tarballs
by npm's integrity digest, as @ds-lang/ds's check holds its own, and the two
schemas, which no npm package carries, by sha256 at a commit of their own
repository. Both are kept in @ds-lang/ds's check's store (`DS_NPM_STORE`).
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DSDB = ROOT / "tools" / "dsdb"


def _load_check():
    """scripts/js/check.py, loaded by path under a name of its own, as the
    CI lane loads it: `check` is a common module name."""
    if "js_check" in sys.modules:
        return sys.modules["js_check"]
    spec = importlib.util.spec_from_file_location(
        "js_check", ROOT / "scripts" / "js" / "check.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["js_check"] = module
    spec.loader.exec_module(module)
    return module


check = _load_check()

# THE PROTOCOLS' PUBLISHED SCHEMAS: what dsdb's suite checks every
# message `ds dap` and `ds lsp` send against (test/dap_schema.mjs,
# test/lsp_schema.mjs, which find them in the directory PROTOCOL_ENV names).
# Neither file ships in an npm package, so each is pinned at a commit of its
# own repository and held to its sha256; a raw file at a commit is that
# commit's blob, so its bytes do not move.
#   debugAdapterProtocol.json: microsoft/debug-adapter-protocol main,
#     2026-10-05 (MIT).
#   metaModel.json: microsoft/language-server-protocol, LSP 3.17.0's
#     metaModel as last changed on 2025-05-14 (MIT).
PROTOCOL_SCHEMAS = {
    "debugAdapterProtocol.json": (
        "https://raw.githubusercontent.com/microsoft/debug-adapter-protocol/"
        "c10f18c3332ca04cece1081aa00232a9d882438d/debugAdapterProtocol.json",
        "ff8ae4c6cfd588a050e9346c35fd104748a27ef4518d1c3268529ca6f8ff5818"),
    "metaModel.json": (
        "https://raw.githubusercontent.com/microsoft/language-server-protocol/"
        "f20ba0702f2bbfe538226a5255739fc118744407/_specifications/lsp/3.17/metaModel/metaModel.json",
        "c207890d9e0f54d8f9e462a924670f563423ec9af90a0a369645ff55384c8d6d"),
}
PROTOCOL_ENV = "DS_PROTOCOL_SCHEMAS"

# The packer's bundles: npm's own dist.integrity. @emnapi/runtime is the
# glue's own pin (@ds-lang/ds's check's EMNAPI), so the package bundles the
# runtime its glue was built against; tslib is what @emnapi/runtime 1.11.3
# depends on (`^2.4.0`), at 2.8.1.
BUNDLES = {
    "runtime-1.11.3.tgz": check.EMNAPI["emnapi-runtime"],
    "tslib-2.8.1.tgz": ("https://registry.npmjs.org/tslib/-/tslib-2.8.1.tgz",
                        "oJFu94HQb+KVduSUQL7wnpmqnfmLsOA/nAh6b6EH0wCEoK0/mPeXU6c3wKDV83MkOuHPRHtSXKKU99IBazS/2w=="),
}


def _fetch_sha256(label: str, url: str, sha256: str) -> bytes:
    """A pinned file's bytes, verified against `sha256`: the store's copy if
    it has a good one, else the URL's, kept for the next run."""
    store = check._npm_store()
    kept = store / f"{sha256}.bin" if store else None
    if kept is not None and kept.is_file():
        blob = kept.read_bytes()
        if hashlib.sha256(blob).hexdigest() == sha256:
            print(f"dsdb: {label}: from the store, {kept}", flush=True)
            return blob
        print(f"dsdb: {label}: the store's copy does not verify; fetching", flush=True)
    blob = check._download(label, url)
    if hashlib.sha256(blob).hexdigest() != sha256:
        raise SystemExit(f"dsdb: {label}: sha256 mismatch -- refusing it")
    if kept is not None:
        check._keep(kept, blob, label)
    return blob


def protocol_schemas() -> Path:
    """The directory holding PROTOCOL_SCHEMAS, each fetched and verified."""
    out = check.WORK / "protocol"
    out.mkdir(parents=True, exist_ok=True)
    for name, (url, sha256) in PROTOCOL_SCHEMAS.items():
        dest = out / name
        if not (dest.is_file() and hashlib.sha256(dest.read_bytes()).hexdigest() == sha256):
            dest.write_bytes(_fetch_sha256(name, url, sha256))
        print(f"dsdb: {name} (sha256 verified) -> {dest}", flush=True)
    return out


def typecheck_dsdb() -> None:
    """`tsc --checkJs`, strict, over dsdb's lib/, with @ds-lang/ds's check's
    pinned TypeScript and Node types. dsdb ships no declarations, so this
    writes nothing: it reads @ds-lang/ds through the declarations @ds-lang/ds
    ships, which `check.typecheck` has just held to @ds-lang/ds's lib/."""
    check.say("dsdb: tsc --checkJs, strict")
    tsc = check.npm_package("typescript") / "bin" / "tsc"
    node_types = check.npm_package("@types/node")
    check.npm_package("undici-types")
    check.run("node", tsc, "-p", DSDB / "tsconfig.json", "--typeRoots", node_types.parent)
    print("dsdb: lib/ type-checks under strict", flush=True)


def dsdb_fixtures() -> list[Path]:
    return sorted((DSDB / "test" / "fixtures").glob("*.ds"))


def dsdb_tests() -> list[Path]:
    return sorted((DSDB / "test").glob("*.test.mjs"))


def compiler_tgz(module: Path, version: str) -> Path:
    """ds_dsc-<version>.tgz, as the packer takes the compiler: its
    `ds_dsc/` directory, the module and its .wasm, from where
    @ds-lang/ds's check packaged them."""
    pkg = module.parent
    for f in (module, pkg / "dsc_cli.wasm"):
        if not f.is_file():
            raise SystemExit(f"dsdb: no {f}; @ds-lang/ds's check packages the compiler there")
    out = check.WORK / "ds-tools" / f"ds_dsc-{version}.tgz"
    out.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out, "w:gz") as t:
        t.add(pkg, arcname="ds_dsc")
    return out


def pack(version: str, glue: Path, module: Path, out: Path, node: str = "node") -> Path:
    """ds-tools-<version>.tgz in `out`, by scripts/dsdb/pack.mjs over `glue`
    and the compiler `module`, with BUNDLES."""
    check.say(f"dsdb: the DS tools package, ds-tools-{version}.tgz (scripts/dsdb/pack.mjs)")
    bundles = check.WORK / "ds-tools" / "bundles"
    if bundles.exists():
        shutil.rmtree(bundles)
    bundles.mkdir(parents=True)
    args = []
    for name, (url, integrity) in sorted(BUNDLES.items()):
        (bundles / name).write_bytes(check._fetch_pinned(name, url, integrity))
        args += ["--bundle", str(bundles / name)]
    check.run(node, ROOT / "scripts" / "dsdb" / "pack.mjs", "--version", version, "--glue", glue,
              "--compiler", compiler_tgz(module, version), *args, "--out", out)
    tgz = out / f"ds-tools-{version}.tgz"
    if not tgz.is_file():
        raise SystemExit(f"dsdb: pack.mjs wrote no {tgz}")
    print(f"dsdb: {tgz} ({tgz.stat().st_size} bytes)", flush=True)
    return tgz


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Type-check dsdb and run its suite on @ds-lang/ds, "
                                             "and pack the DS tools package.")
    ap.add_argument("--target", choices=("native", "wasm"), default="native",
                    help="@ds-lang/ds's Node-API module (default), or its wasm32 module")
    ap.add_argument("--libds", type=Path, help="native: the libds.a to link")
    ap.add_argument("--protoc-c", default=os.environ.get("PROTOC_C") or shutil.which("protoc-c"),
                    help="wasm: the native protoc-c (default: PROTOC_C, else protoc-c on PATH)")
    ap.add_argument("--dsc", default=os.environ.get("DS_MERCURY_DSC") or shutil.which("dsc"),
                    help="native: the Mercury dsc (default: DS_MERCURY_DSC, else dsc on PATH)")
    ap.add_argument("--mmc-wasm32", default=os.environ.get("MMC_WASM32"),
                    help="wasm: the cross mmc that builds ds_dsc (default: MMC_WASM32)")
    ap.add_argument("--pack", type=Path, metavar="DIR",
                    help="wasm: also write ds-tools-<version>.tgz into DIR")
    ap.add_argument("--junit", help="also write the suite's junit report here")
    args = ap.parse_args(argv[1:])
    if args.target == "native" and args.libds is None:
        ap.error("the native target links a libds.a: pass --libds (PORTING.md builds one)")
    if args.target == "wasm" and args.libds is not None:
        ap.error("--libds is the native target's; the wasm target builds its own libds.a")
    if args.target == "wasm" and not args.mmc_wasm32:
        ap.error("the wasm target builds its compiler, ds_dsc: pass --mmc-wasm32, "
                 "or set MMC_WASM32")
    if args.pack is not None and args.target != "wasm":
        ap.error("--pack is the wasm target's: the DS tools package is dsdb on wasm @ds-lang/ds")
    check.typecheck()
    typecheck_dsdb()
    env = {PROTOCOL_ENV: str(protocol_schemas())}
    if args.dsc:
        env["DS_MERCURY_DSC"] = str(Path(args.dsc).resolve())
    if args.target == "native":
        fixtures = check.compile_fixtures(args.dsc, dsdb_fixtures())
        check.build_native(args.libds.resolve(), check.pkg_config_libs())
        check.run_suite("native", fixtures, args.junit, extra_tests=dsdb_tests(), extra_env=env)
        return 0
    tools, toolchain = check.emsdk()
    prefixes = check.wasm_deps(tools, toolchain)
    glue, runtime = check.build_wasm(args.protoc_c, tools, prefixes)
    compiler = check.build_wasm_dsc(tools, prefixes, args.mmc_wasm32)
    fixtures = check.compile_fixtures_wasm(compiler, dsdb_fixtures())
    check.run_suite("wasm", fixtures, args.junit, extra_tests=dsdb_tests(),
                    extra_env={**env, "DS_JS_WASM": str(glue),
                               "DS_JS_EMNAPI_RUNTIME": str(runtime),
                               "DS_JS_DSC": str(compiler)})
    if args.pack is not None:
        version = subprocess.run([sys.executable, ROOT / "scripts" / "build" / "ds-version.py", "--clean", ROOT],
                                 check=True, capture_output=True, text=True).stdout.strip()
        pack(version, glue, compiler, args.pack.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

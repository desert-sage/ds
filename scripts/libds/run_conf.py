#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""run_conf.py <conf_weak|conf_macro> — run both IALC.10 conformance workloads of a
built harness binary: libds.build's alloc_weak and alloc_macro steps. Run from
runtime/tests/libds/alloc_conformance.
"""
import subprocess
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.exit("usage: run_conf.py <conf_weak|conf_macro>")
    binary = argv[1]
    # `rt-supersede` is not run: it compiles a `constspace: true` program, and
    # constspace is deferred from this edition (D15), refused by
    # the compiler with DS_VALIDATE_REALTIME_DEFERRED. It measures the slab-pool
    # pump, which no program of this edition reaches. The workload stays in
    # conformance_main.c for the edition that turns constspace back on.
    # `rdsc-9-8-oom` fails each allocation a load makes in turn ([RDSC.9.8]).
    for workload in ("no-protobuf", "full-dsc", "rdsc-9-8-oom"):
        print(f"--- {binary} / {workload} ---", flush=True)
        rc = subprocess.run([f"./{binary}", workload]).returncode
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

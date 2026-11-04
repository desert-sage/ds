#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# gen_ebnf_registry.py — an EBNF enumeration registry and its generated consumers.
#
#   gen_ebnf_registry.py --from-proto proto/validate.proto --out specs/registry/validate.ebnf
#   gen_ebnf_registry.py specs/registry/validate.ebnf --emit mercury --out <path>
#   gen_ebnf_registry.py specs/registry/validate.ebnf --emit mercury_compiler --out <path>
#   gen_ebnf_registry.py specs/registry/validate.ebnf --check
#
# [STYL.2.15.6]: EBNF registers enumerations. The alternation is the closure, a
# terminal production is the allocation, and a production kept out of the
# alternation is a retirement that still says which name held the number.
#
# [STYL.2.15.6.1]: a registry generates into EVERY consumer and privileges none.
# `protoc-c` emits C and not Mercury, so under protobuf the Mercury compiler and
# runtime would maintain their view of a shared enumeration by hand. Every
# output here is generated: regenerate, never hand-write ([STYL.5.9.6]).
#
# There is no Python consumer. The Python compiler and its
# `_validate_codes.py` were deleted in `146c2eabf`.
#
# THE REGISTRY FORMAT, which is ordinary EBNF and deliberately not a dialect:
#
#     ds_validate = DS_VALIDATE_UNSPECIFIED
#                 | DS_VALIDATE_HARD_KEYWORD_NAME ;
#
#     DS_VALIDATE_UNSPECIFIED       = "0" ;
#     DS_VALIDATE_HARD_KEYWORD_NAME = "1000" ;
#     DS_VALIDATE_RESERVED_SCHEMA_NAME = "1005" ;   (* retired *)
#
# A name with a production but no membership is RETIRED: the number stays
# allocated and still records which name held it. Protobuf reserves numbers and
# names in separate statements and connects them only in a comment — see
# `proto/validate.proto`'s "1005 was DS_VALIDATE_RESERVED_SCHEMA_NAME", which is
# prose and verified by nobody.
from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Every registry and the artefacts generated from it. `--check` regenerates each
# in memory and diffs against what is committed, so a registry edited without
# regenerating is a gate failure rather than a discovery.
#
# WITHOUT THIS THE GENERATION IS UNGATED. [STYL.5.9.6] says a generated artefact
# is regenerated and never hand-written, and nothing enforced that: the
# committed Mercury could drift from the `.ebnf` silently, which is the same
# two-sources-of-truth failure moving the registry out of proto/ was meant to
# end.
#
# A registry may have more than one view in one language, each shaped for its
# consumer ([STYL.2.13.3]: the numbers are normative, the names suggestive). The
# validate registry has two Mercury views: the runtime's `ds.ds_validate` and
# the compiler's `dsc.validate_codes`.
GENERATED: dict[str, list[tuple[str, str]]] = {
    "specs/registry/validate.ebnf": [
        ("mercury", "runtime/mercury/src/ds.ds_validate.m"),
        ("mercury_compiler", "compiler/mercury/src/dsc.validate_codes.m"),
    ],
}

SET_RE = re.compile(r"^\s*([a-z_][a-z0-9_]*)\s*=\s*(.+?)\s*;", re.MULTILINE | re.DOTALL)
ALLOC_RE = re.compile(r'^\s*([A-Z][A-Z0-9_]*)\s*=\s*"(\d+)"\s*;', re.MULTILINE)
COMMENT_RE = re.compile(r"\(\*.*?\*\)", re.DOTALL)

PROTO_MEMBER_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(\d+)\s*;", re.MULTILINE)
PROTO_RESERVED_NUM_RE = re.compile(r"^\s*reserved\s+([0-9,\s]+);", re.MULTILINE)
# "1005 was DS_VALIDATE_RESERVED_SCHEMA_NAME" — the ONLY place protobuf records
# which name held a retired number, and it records it in prose.
PROTO_WAS_RE = re.compile(r"(\d+)\s+was\s+([A-Z][A-Z0-9_]*)")


class Registry:
    def __init__(self, name: str, live: list[tuple[str, int]],
                 retired: list[tuple[str, int]]) -> None:
        self.name = name
        self.live = live
        self.retired = retired

    def check(self) -> list[str]:
        """Every invariant [STYL.2.8.7] asks of an allocation registry."""
        bad: list[str] = []
        seen: dict[int, str] = {}
        for who, members in (("live", self.live), ("retired", self.retired)):
            for nm, num in members:
                if num in seen:
                    bad.append(f"{num} allocated twice: {seen[num]} and {nm}")
                seen[num] = nm
        names = [n for n, _ in self.live] + [n for n, _ in self.retired]
        for n in names:
            if names.count(n) > 1:
                bad.append(f"{n} declared more than once")
        retired_names = {n for n, _ in self.retired}
        for nm, _num in self.live:
            if nm in retired_names:
                bad.append(f"{nm} is both live and retired")
        return sorted(set(bad))


def parse(path: str) -> Registry:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    bare = COMMENT_RE.sub(" ", src)

    alloc = {m.group(1): int(m.group(2)) for m in ALLOC_RE.finditer(bare)}

    # The set production is the one whose right-hand side is an alternation of
    # NAMEs. Anything else in the file is an allocation.
    set_name, members = "", []
    for m in SET_RE.finditer(bare):
        rhs = m.group(2)
        if "|" not in rhs and rhs.strip() not in alloc:
            continue
        names = [t.strip() for t in rhs.split("|")]
        if names and all(re.fullmatch(r"[A-Z][A-Z0-9_]*", n) for n in names):
            set_name, members = m.group(1), names
            break
    if not set_name:
        raise SystemExit(f"{path}: no set production found")

    missing = [n for n in members if n not in alloc]
    if missing:
        raise SystemExit(f"{path}: members with no allocation: {', '.join(missing)}")

    live = [(n, alloc[n]) for n in members]
    retired = sorted(((n, v) for n, v in alloc.items() if n not in set(members)),
                     key=lambda kv: kv[1])
    return Registry(set_name, live, retired)


def load_pairings(path: str) -> dict[int, str]:
    """`<number> <NAME>` per line — pairings protobuf could not express.

    Recovered from history: a reserved number was a live member before it was
    retired, so `git log -p proto/validate.proto` still shows the
    `NAME = NNNN;` line at the commit that deleted it. The recovery is one-time;
    once written into the registry the binding is permanent, because there a
    production IS the pairing.
    """
    out: dict[int, str] = {}
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2 or not parts[0].isdigit():
                raise SystemExit(f"{path}:{n}: expected `<number> <NAME>`")
            out[int(parts[0])] = parts[1]
    return out


def from_proto(path: str, pairings: dict[int, str] | None = None
               ) -> tuple[str, list[tuple[str, int]], list[tuple[str, int]], list[int]]:
    """Convert a proto enum, reporting what cannot be carried across.

    A reserved NUMBER whose name protobuf never recorded cannot become a
    production — there is no name to bind it to. Those are returned separately
    and reported rather than invented, because a fabricated name would read
    exactly like a real retirement.
    """
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    enum_name = (re.search(r"^enum\s+(\w+)", src, re.MULTILINE) or [None, "registry"])[1]
    live = [(m.group(1), int(m.group(2))) for m in PROTO_MEMBER_RE.finditer(src)]

    was = {int(n): nm for n, nm in PROTO_WAS_RE.findall(src)}
    # Recovered pairings win over nothing and lose to the file's own comment:
    # if the proto says "1005 was X", that is the record, and a pairings file
    # disagreeing with it is a conflict worth failing on rather than resolving.
    for num, nm in (pairings or {}).items():
        if num in was and was[num] != nm:
            raise SystemExit(
                f"{path}: pairing conflict on {num}: file says {was[num]}, "
                f"recovery says {nm}")
        was.setdefault(num, nm)
    reserved: list[int] = []
    for m in PROTO_RESERVED_NUM_RE.finditer(src):
        for part in m.group(1).split(","):
            part = part.strip()
            if part.isdigit():
                reserved.append(int(part))

    retired = [(was[n], n) for n in sorted(reserved) if n in was]
    unnamed = [n for n in sorted(reserved) if n not in was]
    snake = re.sub(r"(?<!^)(?=[A-Z])", "_", enum_name).lower()
    return snake, live, retired, unnamed


def render_ebnf(name: str, live: list[tuple[str, int]],
                retired: list[tuple[str, int]]) -> str:
    w = max((len(n) for n, _ in live + retired), default=1)
    out = [
        "(* SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors *)",
        "(* SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later *)",
        "",
        f"(* {name} — an enumeration registry ([STYL.2.15.6]).",
        "",
        "   Its consumers are generated from it; never hand-write them",
        "   ([STYL.5.9.6]).",
        "",
        "   The alternation below is the closure: these names and no others.",
        "   Each production is an allocation. A production that is NOT a member",
        "   of the alternation is out of use — the number stays allocated to that",
        "   name ([STYL.2.8.7]). *)",
        "",
    ]
    out.append(f"{name} = " + ("\n" + " " * (len(name) + 3) + "| ").join(
        n for n, _ in live) + " ;")
    out += ["", "(* allocations *)", ""]
    out += [f"{n.ljust(w)} = \"{v}\" ;" for n, v in live]
    if retired:
        out += ["", "(* out of use: allocated, not members *)", ""]
        out += [f"{n.ljust(w)} = \"{v}\" ;" for n, v in retired]
    return "\n".join(out) + "\n"


def render_mercury(r: Registry, source: str) -> str:
    mod = f"ds.{r.name}"
    ctor = {n: n.lower() for n, _ in r.live}
    out = [
        "% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors",
        "% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later",
        f"% GENERATED from {source} by scripts/spec/gen_ebnf_registry.py. Do not edit.",
        f":- module {mod}.",
        ":- interface.",
        "",
        f":- type {r.name}",
    ]
    for i, (n, _v) in enumerate(r.live):
        out.append(("    --->    " if i == 0 else "    ;       ") + ctor[n])
    out[-1] += "."
    out += [
        "",
        f":- func {r.name}_code({r.name}) = int.",
        f":- func {r.name}_name({r.name}) = string.",
        "",
        ":- implementation.",
        "",
    ]
    for n, v in r.live:
        out.append(f"{r.name}_code({ctor[n]}) = {v}.")
    out.append("")
    for n, _v in r.live:
        out.append(f'{r.name}_name({ctor[n]}) = "{n}".')
    return "\n".join(out) + "\n"


# The compiler's view of the validate registry ([RCLI.5.1]). `dsc.diag` raises a
# diagnostic as `dv_<code>`, the code name lower-cased without its
# `DS_VALIDATE_` prefix (`dv_unknown_type` for DS_VALIDATE_UNKNOWN_TYPE), and
# this view keeps that idiom so no raise site changes when the hand-kept DU goes.
# `DS_VALIDATE_UNSPECIFIED` names no code, so it has no constructor here.
VALIDATE_PREFIX = "DS_VALIDATE_"
VALIDATE_ZERO = "DS_VALIDATE_UNSPECIFIED"


def render_mercury_compiler(r: Registry, source: str) -> str:
    if r.name != "ds_validate":
        raise SystemExit(f"{source}: the compiler view is the validate "
                         f"registry's, not {r.name}'s")
    codes = [(n, v) for n, v in r.live if n != VALIDATE_ZERO]
    bad = [n for n, _ in codes if not n.startswith(VALIDATE_PREFIX)]
    if bad:
        raise SystemExit(f"{source}: no {VALIDATE_PREFIX} prefix: {', '.join(bad)}")
    ctor = {n: "dv_" + n[len(VALIDATE_PREFIX):].lower() for n, _ in codes}
    out = [
        "% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors",
        "% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later",
        f"% GENERATED from {source} by scripts/spec/gen_ebnf_registry.py. Do not edit.",
        "%",
        "% The compiler's view of the registry ([RCLI.5.1]): one `dv_` constructor",
        "% per live code, DS_VALIDATE_UNSPECIFIED excepted, which names no code.",
        ":- module dsc.validate_codes.",
        ":- interface.",
        "",
        ":- type ds_validate",
    ]
    for i, (n, _v) in enumerate(codes):
        out.append(("    --->    " if i == 0 else "    ;       ") + ctor[n])
    out[-1] += "."
    out += [
        "",
        ":- func ds_validate_name(ds_validate) = string.",
        ":- func ds_validate_code(ds_validate) = int.",
        "",
        ":- implementation.",
        "",
    ]
    for n, _v in codes:
        out.append(f'ds_validate_name({ctor[n]}) = "{n}".')
    out.append("")
    for n, v in codes:
        out.append(f"ds_validate_code({ctor[n]}) = {v}.")
    return "\n".join(out) + "\n"


RENDER = {"mercury": render_mercury, "mercury_compiler": render_mercury_compiler}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("registry", nargs="?", help="a specs/registry/*.ebnf")
    ap.add_argument("--from-proto", default="")
    ap.add_argument("--pairings", default="",
                    help="`<number> <NAME>` lines recovered from history, for "
                         "retirements protobuf recorded without a pairing")
    ap.add_argument("--emit", choices=("mercury", "mercury_compiler", "ebnf"))
    ap.add_argument("--out", default="")
    ap.add_argument("--check", action="store_true",
                    help="registry invariants only; emits nothing")
    args = ap.parse_args(argv[1:])

    if args.from_proto:
        pairs = load_pairings(args.pairings) if args.pairings else {}
        name, live, retired, unnamed = from_proto(args.from_proto, pairs)
        text = render_ebnf(name, live, retired)
        if args.out:
            os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as fh:
                fh.write(text)
            print(f"wrote {args.out}: {len(live)} live, {len(retired)} retired")
        else:
            sys.stdout.write(text)
        if unnamed:
            # NOT invented. A fabricated name would read exactly like a real
            # retirement, and the number is the only thing protobuf recorded.
            print(f"\n{len(unnamed)} reserved number(s) carry no recorded name "
                  f"and were NOT converted:", file=sys.stderr)
            print("  " + ", ".join(str(n) for n in unnamed), file=sys.stderr)
            print("  Each needs its name recovered from history, or an explicit "
                  "decision that it is lost.", file=sys.stderr)
            return 1
        return 0

    if args.check and not args.registry:
        # Every registry and every artefact, which is what a gate wants: naming
        # one registry would check that one and pass over a stale sibling.
        import difflib
        stale = 0
        for rel, outs in sorted(GENERATED.items()):
            src = os.path.join(ROOT, rel)
            if not os.path.exists(src):
                print(f"{rel}: missing", file=sys.stderr)
                return 1
            reg = parse(src)
            for problem in reg.check():
                print(f"{rel}: {problem}", file=sys.stderr)
                stale += 1
            for emit, out_rel in outs:
                want = RENDER[emit](reg, rel)
                out = os.path.join(ROOT, out_rel)
                have = ""
                if os.path.exists(out):
                    with open(out, encoding="utf-8") as fh:
                        have = fh.read()
                if have == want:
                    continue
                stale += 1
                print(f"\n{out_rel} is STALE — regenerate with:\n"
                      f"  python scripts/spec/gen_ebnf_registry.py {rel} "
                      f"--emit {emit} --out {out_rel}\n", file=sys.stderr)
                sys.stderr.writelines(difflib.unified_diff(
                    have.splitlines(keepends=True), want.splitlines(keepends=True),
                    fromfile=out_rel + " (committed)", tofile="(regenerated)",
                    n=1))
        if stale:
            return 1
        n = sum(len(v) for v in GENERATED.values())
        print(f"gen-ebnf-registry: {len(GENERATED)} registry/registries, "
              f"{n} generated artefact(s) — all current")
        return 0

    if not args.registry:
        ap.error("a registry is required unless --from-proto is given")
    reg = parse(args.registry)
    problems = reg.check()
    for p in problems:
        print(f"{args.registry}: {p}", file=sys.stderr)
    if problems:
        return 1
    if args.check:
        print(f"{args.registry}: {reg.name} — {len(reg.live)} live, "
              f"{len(reg.retired)} retired, no duplicate allocation")
        return 0

    src = os.path.relpath(args.registry, ROOT)
    text = RENDER[args.emit](reg, src)
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {args.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

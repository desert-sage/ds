# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# The version is decided here, at configure time, and meson-python writes it
# into the distribution's metadata, where `pyds.__version__` reads it back.
# scripts/python/version.py says which form: the release's when DS_BUILD_VERSION names
# one, the provenance form otherwise.
project('pyds', 'c',
    version: run_command('python3', '../../scripts/python/version.py', check: true).stdout().strip(),
    meson_version: '>=1.4',
    default_options: ['c_std=c11', 'warning_level=2'])

py = import('python').find_installation(pure: false)

cc = meson.get_compiler('c')

# Repo root, relative to this meson.build (bindings/python → repo root).
repo_root = meson.current_source_dir() / '..' / '..'
libds_dir = repo_root / 'runtime' / 'src' / 'libds'
libds_inc = repo_root / 'runtime' / 'include'

# The static library, built beforehand from runtime/src/libds/Makefile or
# libds.build (PORTING.md, "Building libds.a"); meson does not build it.
libds_a = cc.find_library(
    'ds',
    dirs: [libds_dir],
    static: true,
    required: true,
)

# Link deps per IARC.7.4 — resolved by PKG-CONFIG, not by the linker path
# (VENDORWHL1).
#
# These were `cc.find_library('protobuf-c')` and `cc.find_library('re2')`, which
# search the LINKER PATH and consult no pkg-config at all. That made this file
# the one consumer the vendored set could not reach: VENDOR1 points every other
# site at the pinned prefixes through PKG_CONFIG_PATH, and `find_library` does
# not look there. `_pyds.so` links RE2 INTO ITSELF — it is the only artifact
# that does — so a wheel resolving libds.a's `ds_re2.o` symbols against the
# system libre2 while libds.a was COMPILED against vendored RE2 headers is a
# header/library skew, not merely an unpinned choice.
#
# `dependency()` follows PKG_CONFIG_PATH, so the same line serves both: the
# vendored prefix when the caller has put it first, the distro's otherwise. No
# build-mode switch, and nothing to keep in step.
#
# `static:` IS NOT A CONSTANT, and the reason is measured rather than stylistic.
#
# An earlier version of this asked for `static: true` unconditionally, on the
# reasoning that the vendored RE2 is built BUILD_SHARED_LIBS=OFF so only
# `--static` emits the ~40 Abseil archives from Requires.private. That is true,
# and it broke the build:
#
#   /usr/lib/x86_64-linux-gnu/libprotobuf-c.a(protobuf-c.o): relocation
#   R_X86_64_PC32 ... can not be used when making a shared object;
#   recompile with -fPIC
#
# DEBIAN'S STATIC ARCHIVES ARE NOT PIC. They are fine in an executable and
# cannot go into a shared object, and `_pyds.so` is a shared object. I had
# checked that the `.a` files EXIST and concluded the two modes "resolve
# identically" — existence was the wrong question.
#
# So the mode depends on WHOSE archives are on the path, which is the caller's
# knowledge and not this file's. `meson.options` carries it (see there for both
# halves of the constraint), and the caller sets it together with the
# PKG_CONFIG_PATH it belongs with.
vendored = get_option('vendored')
libprotobuf_c = dependency('libprotobuf-c', required: true, static: vendored)
# REGEXRE2 — libds.a carries ds_re2.o, the C++ RE2 seam. RE2 IS the language's
# regex ([LREG.7.1] / [LREG.8.1]), so the engine every extension loads has to be
# it; a target that will not carry RE2 disables the `regex` dialect form instead.
libre2 = dependency('re2', required: true, static: vendored)
# The C++ runtime, named explicitly: this project is declared `'c'`, so meson
# drives the link with the C compiler, which adds none. Two names because the
# two platforms disagree — GNU ships libstdc++, macOS ships libc++ and no
# libstdc++ at all — and `required: false` on the first is how we ask.
libcxx = cc.find_library('stdc++', required: false)
if not libcxx.found()
    libcxx = cc.find_library('c++', required: true)
endif
# zlib retired ([RDSC.4.5]): .dsc bodies are uncompressed, so libds no longer links -lz.
libpthread = cc.find_library('pthread', required: true)
libm = cc.find_library('m', required: true)

py.install_sources(
    'src/pyds/__init__.py',
    'src/pyds/_dsc_command.py',
    # PEP 561: the package carries its own type information, and the
    # extension's is its stub (PY.12), installed beside `_pyds.so`.
    'src/pyds/py.typed',
    'src/pyds/_pyds.pyi',
    # The exception classes, and the Status enum, generated from
    # proto/status.proto.
    'src/pyds/errors.py',
    'src/pyds/_status.py',
    # The Capability enum, generated from
    # proto/capabilities.proto; pyds.BUILD_CAPABILITIES holds its members.
    'src/pyds/_capability.py',
    # The fault enums (TrapKind, CapName, EngineFault), generated from the
    # fault protos; the fault events carry them.
    'src/pyds/_faults.py',
    # FactId, the only way a Python value names a fact.
    'src/pyds/facts.py',
    # pyds.Engine, the public class over the extension's _Engine, its views
    # and its value types; and the closed vocabularies they report in.
    'src/pyds/engine.py',
    'src/pyds/enums.py',
    # The stream events and callback payloads, one frozen dataclass each.
    'src/pyds/events.py',
    # SessionHeader, which the engine reports.
    'src/pyds/session.py',
    # AtomKind, generated from proto/atom.proto and the census columns -- the same source the C header and the
    # compiler's map come from. pyds.atoms reads it, so a wheel without it
    # raises ImportError on first use, which is the shape PYDSPROF1 was: a
    # module that only the gates' editable install made work.
    'src/pyds/_atom_registry.py',
    # libds's atom reader and framing (pyds.atoms), the
    # one way pyds reads a trace or a .dsc.
    'src/pyds/atoms.py',
    subdir: 'pyds',
)

# `pyds.proto` — the Python bindings for EVERY `proto/*.proto`, as a package.
#
# `pyds.atoms`'s `Atom.message()` and the fault codec read their descriptors
# from here, and so does every Python consumer of them. The one place the
# bindings live is the runtime's own package.
#
# One target for the whole directory rather than one per proto: the list comes
# from `scripts/python/gen_proto_package.py --list`, so a proto added to `proto/` ships
# with no edit here — the ten hand-written targets this replaces were a second
# copy of the directory listing, with a comment beside each explaining why that
# proto had been added. The script also rewrites protoc's BARE sibling imports
# (`import common_pb2`) to relative ones, which is what lets these be a package
# at all; see its docstring.
#
# `protoc` must be the IMAGE's (PROTOCVER1): generated Python is version-checked
# at import against the pip `protobuf` runtime beside it.
protoc = find_program('protoc', required: true)
proto_dir = repo_root / 'proto'
proto_gen_script = meson.current_source_dir() / '..' / '..' / 'scripts' / 'python' / 'gen_proto_package.py'
proto_stems = run_command(py, proto_gen_script, '--list', proto_dir,
                          check: true).stdout().strip().split('\n')
proto_inputs = []
proto_outputs = []
foreach stem : proto_stems
    proto_inputs += proto_dir / (stem + '.proto')
    proto_outputs += stem + '_pb2.py'
    # protoc's stub for it (PY.12): mypy reads the messages' fields from it.
    proto_outputs += stem + '_pb2.pyi'
endforeach
pyds_proto = custom_target('pyds_proto',
    input: proto_inputs,
    output: proto_outputs,
    command: [py, proto_gen_script, protoc, proto_dir, '@OUTDIR@', '@INPUT@'],
    install: true,
    install_dir: py.get_install_dir(subdir: 'pyds' / 'proto'),
)
py.install_sources('src/pyds/proto/__init__.py', subdir: 'pyds' / 'proto')

# NO libdl SINCE [NSBK.2.3]: libds no longer dlopens a series backend, so the
# only reason pyds linked it is gone.
pyds_deps = [libds_a, libprotobuf_c, libre2, libcxx, libpthread, libm]

# No platform's workarounds (DARWINSPLIT1). This carried `-Wl,-no_uuid -Wl,-S`
# under a `host_machine.system() == 'darwin'` guard.
#
# DS no longer builds darwin, and a flag DS never exercises does not belong in
# DS's meson: nothing here would notice if ld64 stopped accepting it, renamed
# it, or if a third non-determinism mechanism appeared. Carrying an untested
# platform's workarounds is how a file comes to describe a build nobody runs.
#
# What it carries is the glue's hardening: libds.build's two values on the
# compile (meson.options says which), and on the link the GOT read-only after
# relocation with every symbol bound at load. None of it touches a Float
# result.
pyds_c_args = get_option('harden').split() + get_option('harden_cfi').split()
pyds_link_args = ['-Wl,-z,relro,-z,now']

py.extension_module('_pyds',
    sources: [
        'src/_pyds/pyds_module.c',
        'src/_pyds/engine.c',
        'src/_pyds/errors.c',
        'src/_pyds/schema.c',
        'src/_pyds/rule_meta.c',
        'src/_pyds/atoms.c',
    ],
    include_directories: [
        include_directories('../../runtime/include'),
        # PYRFCS1 — engine.c includes "rfcs/rfcs.h" for Engine.replay.
        # RFCS is not part of the integrator C ABI (nothing in runtime/include
        # declares it), but pyds is a first-party binding compiled from this
        # tree and already links the libds.a built from it.
        include_directories('../../runtime/src/libds'),
        # The enum names pyds and @ds-lang/ds share (ds_names.h, header-only).
        include_directories('../../runtime/src/bindings'),
    ],
    dependencies: pyds_deps,
    c_args: pyds_c_args,
    link_args: pyds_link_args,
    # THE 3.12 STABLE ABI: defines
    # Py_LIMITED_API=0x030C0000, so the one `_pyds.so` loads in every CPython
    # from 3.12, the floor (PY.1). A call outside the limited API is a compile
    # error, which is the check that the extension stays inside it. Tagging the
    # wheel `cp312-abi3` is the release graph's.
    limited_api: '3.12',
    install: true,
    subdir: 'pyds',
)

# `_pyds.so` links protobuf-c, RE2 and Abseil statically from the
# vendored set (VENDORWHL1), so the wheel is a binary redistribution of all
# three, and RE2's BSD-3 clause 2 wants the notice "in the documentation and/or
# other materials provided with the distribution". Installed beside `_pyds.so`
# in the package, which is where a recipient of the wheel finds it. The release
# checks the built wheel for it.
#
# The caller's file when it passes one (meson.options): a wheel with no `dsc`
# must not carry the Mercury sections, and only the caller knows which it built.
notices = get_option('notices')
install_data(notices != '' ? notices : '../../THIRD_PARTY_NOTICES.md',
    install_dir: py.get_install_dir(subdir: 'pyds'),
    rename: 'THIRD_PARTY_NOTICES.md',
)

# The Mercury compiler, at `pyds/bin/dsc`, where `pyds.compile()` looks for it
# after `DS_MERCURY_DSC`. Executable, because install_data's default mode is a data file's.
dsc = get_option('dsc')
if dsc != ''
  install_data(dsc,
      install_dir: py.get_install_dir(subdir: 'pyds' / 'bin'),
      rename: 'dsc',
      install_mode: 'rwxr-xr-x',
  )
endif

# The standard library the compiler ships with ([LIMP.3.3.1]), at
# `pyds/share/ds/stdlib`: `dsc` searches `<its directory>/../share/ds/stdlib`
# after every `-L`, so `pyds.compile` resolves `import units.si` with no
# `search_path`. A directory named `stdlib`, kept under its own name.
stdlib = get_option('stdlib')
if stdlib != ''
  install_subdir(stdlib,
      install_dir: py.get_install_dir(subdir: 'pyds' / 'share' / 'ds'),
  )
endif

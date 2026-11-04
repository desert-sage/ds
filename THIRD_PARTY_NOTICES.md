<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Third-party notices

DS itself is AGPL-3.0-or-later (see `LICENSE`). This file carries the notices
that third-party components **require us to reproduce when we ship binaries**.

## Why this file exists, and what it obliges

RE2 is BSD-3-Clause, and its **second condition** is the operative one for a
project that ships compiled artefacts:

> Redistributions in binary form must reproduce the above copyright notice,
> this list of conditions and the following disclaimer **in the documentation
> and/or other materials provided with the distribution**.

"In the documentation and/or other materials provided with the distribution" is
not satisfied by the notice living in a source tree the recipient never
receives. Anything DS ships that contains RE2 code must carry the text below
**alongside it**:

| Artefact | Third-party code it carries | Must ship this file |
|---|---|---|
| release tarballs with regex (`linux-glibc-*`, `linux-musl-*`, `emscripten-wasm32-regex`, and the BSD/riscv64 rows) | protobuf-c, fast_float, Dragonbox, CORE-MATH; RE2 + Abseil | **yes** |
| the `ds-check` / `ds-base` container images | protobuf, protobuf-c, RE2, Abseil | **yes** |
| `bin/dsc` — the Mercury compiler, in every libds tarball but the wasm32 one, and in each debug pack | RE2 + Abseil; fast_float, Dragonbox, CORE-MATH; the Mercury Core Libraries, the Boehm-Demers-Weiser garbage collector and musl's getopt, all linked statically | **yes**, in the same tarball |
| the `pyds` wheel | protobuf-c, fast_float, Dragonbox, CORE-MATH; RE2 + Abseil; in `pyds/bin/dsc`, the Mercury Core Libraries, the Boehm-Demers-Weiser garbage collector and musl's getopt; all linked statically | **yes**, inside the `pyds` package |
| firmware images (regex disabled by dialect) | protobuf-c, fast_float, Dragonbox, CORE-MATH — **but not RE2** | **yes**, for the protobuf-c, fast_float and CORE-MATH notices |
| `ds-tools-<version>.tgz` — dsdb on wasm @ds-lang/ds, with `ds_dsc` | in `ds_wasm.wasm`: libds as the `emscripten-wasm32-regex` row builds it (protobuf-c, fast_float, Dragonbox, CORE-MATH, RE2 + Abseil) and emnapi; in `ds_dsc`: everything `bin/dsc` carries; in both, Emscripten's runtime and libc. Bundled beside them: `@emnapi/runtime` and `tslib`, each with its own licence file | **yes**, at the package's root |
| `ds-docs-<version>.tar.gz`, the rendered books | Fira Code, a font, in each book's `_static/` | **no**: its licence ships beside it as `OFL.txt` |

**Both obligations are live.** protobuf-c's always was — libds links it, so
every binary DS has ever shipped is covered by the second condition below.
RE2's started with REGEXRE2: `libds.a` now contains `ds_re2.o`, the C++ seam
that links RE2, so a release tarball is a binary redistribution of RE2 as well.
This file used to say RE2's clock had not started. It has.

**The `pyds` wheel contains RE2, Abseil and protobuf-c.** The release builds it
against the vendored prefixes with `-Dvendored=true` (VENDORWHL1), so
`_pyds.so` links all three statically and imports no `libre2`. `meson.build`
installs this file into the `pyds` package, beside `_pyds.so`.

**`bin/dsc` is a Mercury program, linked statically**, so it redistributes the
parts of the Mercury system every Mercury executable contains. These are the
core libraries (the runtime and the standard library), the Boehm-Demers-Weiser
collector the `hlc.gc` grade links, and the musl-derived getopt in the runtime.
Their sections are below. The Mercury compiler that BUILT it is GPL and is not
in the binary. Mercury's `LICENSE` says the core libraries are the only part
"automatically linked into an executable program by the Mercury system". A
tarball without `bin/dsc` ships the file without those three sections, and the
release checks both directions.

**The no-regex tarball ships this file without the RE2 and Abseil sections**,
since it contains neither; the release drops them for a `re2=stub` build. The
release reads every built tarball and wheel and fails in both directions: code
whose section is missing, and a section whose code is absent.

**A dialect that disables the regex forms links no RE2, and so carries no RE2
obligation.** That is the point of making regex a gateable form rather than a
baked-in feature: a microcontroller target that never matches a pattern should
not ship a regex engine, and should not have to reproduce a licence for code it
does not contain. Do not add this file to such an image reflexively — shipping
a notice for a component that is absent is its own kind of inaccuracy.

Abseil is Apache-2.0 and travels with RE2; its `NOTICE` requirements are
separate from and additional to RE2's, and it is listed below for that reason.

**fast_float and Dragonbox are in every `libds.a`, regex or not.** They are the
two Float-text seams: `float_text/float_parse.cc` over fast_float
(text → `Float`) and `float_text/float_shortest.cc` over Dragonbox (`Float` →
shortest text), compiled from `vendor/` into the archive on every row,
because no build may lack them. So every artefact that carries libds carries
both, and neither is stripped by any configuration.

**CORE-MATH is in every `libds.a` too, and its notice is owed by every binary.**
It computes the transcendentals ([LEXP.3.9.1]); its fifteen files are
fetched at the commit `vendor/source.lock` pins and compiled into the
archive on every row. Its licence is MIT, which has no object-code exception:
the notice goes with "all copies or substantial portions of the Software",
compiled ones included. `bin/dsc` carries it as well, because every Mercury
binary links the same objects.

---

## RE2

Used for regular-expression matching. RE2 is not merely the engine DS happens
to link — [LREG.7.1] / [LREG.8.1] define **DS's regex syntax and semantics as
RE2's**, so an implementation that matches a different language is
nonconformant regardless of which library it links.

- Upstream: https://github.com/google/re2
- Licence: BSD-3-Clause
- Also reached indirectly via the `google-re2` Python bindings, used by
  `ds_compiler` to validate patterns at compile time with the same engine the
  runtime matches with.

```
Copyright (c) 2009 The RE2 Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The third condition also binds us in a way worth stating plainly: **DS must not
use Google's name, or the names of RE2's contributors, to endorse or promote
DS.** Describing DS's regex semantics as "RE2 semantics" is a factual statement
about the language and is not endorsement; implying that Google endorses DS
would be.

---

## Abseil

A transitive dependency of RE2 — RE2 does not build without it, so any binary
containing RE2 contains Abseil.

- Upstream: https://github.com/abseil/abseil-cpp
- Licence: Apache-2.0

Apache-2.0 §4 requires that recipients of a derivative work receive a copy of
the licence, that modified files carry prominent notices, and that any `NOTICE`
file's attributions be reproduced. DS does not modify Abseil; it links it as
supplied. The full Apache-2.0 text and Abseil's `NOTICE` must ship with the
same artefacts listed in the table above.

---

## protobuf-c

The C implementation of Protocol Buffers. **libds links this today** — it is
how the runtime reads `.dsc` artefacts — so unlike RE2, this obligation already
attaches to every binary DS has shipped.

- Upstream: https://github.com/protobuf-c/protobuf-c
- Licence: BSD-2-Clause (Simplified BSD)

Two conditions rather than three: there is no no-endorsement clause, but the
binary-redistribution requirement is worded identically to RE2's and binds the
same artefacts.

```
Copyright (c) 2008-2025, Dave Benson and the protobuf-c authors.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The code generated by the protoc-gen-c code generator and by the
protoc-c compiler is owned by the owner of the input files used when
generating it. This code is not standalone and requires a support
library to be linked with it. This support library is covered by the
above license.
```

The closing paragraph matters for us specifically: the `.pb-c.c` / `.pb-c.h`
files generated from DS's own `.proto` files are **ours**, owned by the owner
of the input `.proto`. They are not standalone, and the support library they
link is protobuf-c under the licence above. So generating them creates no new
third-party claim on DS's code — but shipping them still ships protobuf-c.

---

## Protocol Buffers (protobuf)

Google's Protocol Buffers — `protoc`, and the `protobuf` Python runtime used by
`ds_compiler` and the tooling.

- Upstream: https://github.com/protocolbuffers/protobuf
- Licence: BSD-3-Clause

```
Copyright 2008 Google Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
    * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Code generated by the Protocol Buffer compiler is owned by the owner
of the input file used when generating it.  This code is not
standalone and requires a support library to be linked with it.  This
support library is itself covered by the above license.
```

Its third condition is the same no-endorsement rule as RE2's, and binds us the
same way.

---

## fast_float

Parses decimal text to a correctly rounded `Float` ([LDET.3.2.8]), the
Eisel–Lemire algorithm with an exact fallback. Vendored unmodified at
`vendor/fast_float/` (8.3.0) and compiled into `libds.a`.

- Upstream: https://github.com/fastfloat/fast_float
- Licence: offered as MIT OR Apache-2.0 OR BSL-1.0; **DS takes MIT**
  (`vendor/README.md`)

MIT asks that the notice be included in "all copies or substantial portions of
the Software", which a compiled copy is, so it ships with every artefact in the
table above.

```
MIT License

Copyright (c) 2021 The fast_float authors

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

---

## Dragonbox

Renders a `Float` as its shortest round-trip digits, nearest with ties to even
([LDET.3.2.7]). Junekey Jeon's Dragonbox, built on Giulietti's Schubfach.
Vendored unmodified at `vendor/dragonbox/` (1.1.3) and compiled into
`libds.a`.

- Upstream: https://github.com/jk-jeon/dragonbox
- Licence: Apache-2.0 with LLVM Exceptions OR BSL-1.0; **DS takes BSL-1.0**.
  Both texts are kept verbatim beside the source.

BSL-1.0 requires its notice in copies of the Software "unless such copies or
derivative works are solely in the form of machine-executable object code
generated by a source language processor", which is what `libds.a`, `bin/dsc`
and `_pyds.so` are. So no binary DS ships owes this section; it is here so that
the choice of licence, and the code's presence, are stated where a recipient
looks.

```
Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

---

## CORE-MATH

The correctly rounded transcendental functions — `exp`, `log`, `log2`,
`log10`, the trigonometric, inverse trigonometric and hyperbolic functions, and
`pow` ([LEXP.3.9.1]). The CORE-MATH project's binary64 functions, compiled
unmodified from the files `vendor/source.lock` pins, each checked
against its digest, with every entry point renamed to a libds-private name.

- Upstream: https://gitlab.inria.fr/core-math/core-math, at commit
  `6b84457310ad90b644b3335af2faa8c7301e1c47`
- Licence: MIT

The copyright lines the compiled files carry:

```
Copyright (c) 2022 CERN.
Copyright (c) 2022, 2023 CERN and Inria
Copyright (c) 2022-2025 CERN and Inria
Copyright (c) 2022 INRIA and CERN.
Copyright (c) 2022-2025 INRIA and CERN.
Copyright (c) 2022-2025 Paul Zimmermann and Tom Hubrecht
Copyright (c) 2022-2026 Paul Zimmermann and Tom Hubrecht and Alexei Sibidanov
Copyright (c) 2022-2025 Alexei Sibidanov.
Copyright (c) 2022-2026 Alexei Sibidanov <sibid@uvic.ca>.
Copyright (c) 2023 Alexei Sibidanov.
Copyright (c) 2023-2025 Alexei Sibidanov <sibid@uvic.ca>
Copyright (c) 2023-2026 Alexei Sibidanov <sibid@uvic.ca>.
Copyright (c) 2023-2026 Alexei Sibidanov and Paul Zimmermann.
Copyright (c) 2023-2026 Alexei Sibidanov, Cyprien Peignier, Paul Zimmermann
Copyright (c) 2023-2024 Paul Zimmermann and Alexei Sibidanov
Copyright (c) 2024-2025 Paul Zimmermann and Alexei Sibidanov
Copyright (c) 2024-2025 Alexei Sibidanov.
```

```
The CORE-MATH code is distributed under the following license
(MIT license, https://spdx.org/licenses/MIT).

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Mercury Core Libraries

The Mercury runtime and standard library, linked statically into `bin/dsc`.
Mercury 22.01.8, built from its pinned source tarball.

- Upstream: https://mercurylang.org
- Licence: GNU Library General Public License version 2, with a
  static-linking exception

The exception is what lets `bin/dsc` ship under DS's terms. The copyright is
quoted from Mercury's `LICENSE`, and the licence and exception from its
`COPYING.LIB`:

```
The Mercury implementation is free software.
It is Copyright (C) 1993-2012 The University of Melbourne and
Copyright (C) 2013-2023 The Mercury team.

The Mercury Core Libraries are distributed under the terms of the
GNU Library General Public License (LGPL) version 2.

As a special exception to the GNU Library General Public License, you
may link, statically or dynamically, a "work that uses the Mercury
Core Libraries" with the Mercury Core Libraries to produce an
executable file containing portions of the Mercury Core Libraries,
and distribute that executable file under terms of your choice,
without any of the additional requirements listed in clause 6 of the
GNU Library General Public License. This exception does not however
invalidate any other reasons why the executable file might be covered
by the GNU Library General Public License. If you modify the Mercury
Core Libraries, you may extend this exception to your version, but you
are not obligated to do so. If you do not wish to do so, delete this
exception statement from your version.
```

DS does not modify the Mercury Core Libraries.

---

## Boehm-Demers-Weiser garbage collector

The collector the `hlc.gc` grade links into every Mercury executable, so it is
in `bin/dsc`. Mercury ships a slightly modified copy in its `boehm_gc`
directory. DS builds it as Mercury supplies it.

- Upstream: https://github.com/ivmai/bdwgc
- Licence: permissive, with notice retention

```
Copyright (c) 1988, 1989 Hans-J. Boehm, Alan J. Demers
Copyright (c) 1991-1996 by Xerox Corporation.  All rights reserved.
Copyright (c) 1996-1999 by Silicon Graphics.  All rights reserved.
Copyright (c) 1999-2011 by Hewlett-Packard Development Company.
Copyright (c) 2008-2019 Ivan Maidanski

THIS MATERIAL IS PROVIDED AS IS, WITH ABSOLUTELY NO WARRANTY EXPRESSED
OR IMPLIED.  ANY USE IS AT YOUR OWN RISK.

Permission is hereby granted to use or copy this program
for any purpose,  provided the above notices are retained on all copies.
Permission to modify the code and to distribute modified code is granted,
provided the above notices are retained, and a notice that the code was
modified is included with the above copyright notice.
```

The copy in `bin/dsc` is the one Mercury modified. That modification is
Mercury's, made in the Mercury source tree, and DS makes none of its own.

---

## musl

`bin/dsc` is linked fully static against musl, so it contains the
parts of musl's C library it calls. `runtime/mercury_getopt.c` and its
siblings in the Mercury runtime derive from musl's getopt too; they are part
of the core libraries linked into `bin/dsc`.

- Upstream: https://musl.libc.org
- Licence: MIT

```
Copyright © 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## emnapi

Node-API for Emscripten. Its C library is linked into `ds_wasm.wasm`,
the wasm build of the JavaScript binding in `ds-tools-<version>.tgz`, and its
JavaScript runtime, `@emnapi/runtime`, is bundled beside it with its own copy
of this licence.

- Upstream: https://github.com/toyobayashi/emnapi
- Licence: MIT

```
Copyright (c) 2021-present Toyobayashi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

`tslib`, which `@emnapi/runtime` requires, is bundled too. It is 0BSD, which
asks for no notice, and carries its own licence file.

---

## Emscripten

The toolchain both wasm programs in `ds-tools-<version>.tgz` are linked by:
`ds_wasm` and `ds_dsc`. Each carries Emscripten's JavaScript
runtime and the parts of its libc the program uses. Emscripten is offered
under MIT or the University of Illinois/NCSA licence; DS takes MIT. The LLVM
libraries Emscripten links (libc++, libc++abi, compiler-rt) are Apache-2.0
with LLVM's exception, which waives the notice for their portions embedded in
object form.

- Upstream: https://github.com/emscripten-core/emscripten (3.1.74)
- Licence: MIT

```
Copyright (c) 2010-2014 Emscripten authors, see AUTHORS file.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Emscripten's libc derives from musl, whose notice is above.

---

## Fira Code

The monospace face the documentation's code is set in. Fira Code 6.2's Regular face, `FiraCode-Regular.woff2`, ships unmodified from its release in each rendered book's `_static/`, with the licence from Fira Code's repository beside it as `OFL.txt`. The licence reserves no font name.

- Upstream: https://github.com/tonsky/FiraCode, release 6.2
- Licence: SIL Open Font License 1.1

```
Copyright (c) 2014, The Fira Code Project Authors (https://github.com/tonsky/FiraCode)
```

---

## Keeping this honest

This file is a claim about what our binaries contain, so it rots the moment a
dependency is added or a link is dropped. Two failure modes, both bad: shipping
a binary whose components are not all listed here, and listing a component the
binary does not contain. For RE2 and Abseil both are now caught: the release
reads every built tarball and wheel for their code and for their sections, and
fails either way. Nothing checks the protobuf-c and protobuf
rows, whose code leaves no mangled marker to find, nor fast_float and
Dragonbox: both are header templates instantiated inside DS's own two units, so
whether a `fast_float::` or `jkj::dragonbox::` name survives into the archive
depends on what the compiler inlined, and a marker that can vanish under
optimisation would fail a correct archive.

It has now rotted once, in the safe direction. This file was written while the
compiler validated with RE2 and the runtime still matched with POSIX ERE, so
the table said RE2's obligation began "once libds links them". REGEXRE2rt made
that true and the table did not notice; a human did, a commit later. A guard
that diffs the linked-library list of each shipped artefact against this table
would have said so at build time, and is the obvious thing to build next.

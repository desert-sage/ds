<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# pyds

The Python binding for libds, the DS rules engine.

```python
import pyds

engine = pyds.from_source("""\
use default

schema Reading scope ttl 1_min:
    sensor: String
    celsius: Float
""")
fid = engine.assert_("Reading", sensor="t1", celsius=21.5)
engine.pump()
```

- `pyds.compile` runs the DS compiler, `dsc`, and returns the artefact as
  `bytes`. A wheel carries its own `dsc`, and installs it as the `dsc` command.
- `pyds.Engine` loads an artefact, takes facts and runs the rules.
- A failed libds call raises a subclass of `pyds.Error`; its `status` is a
  `pyds.Status`.

Requires CPython 3.12 or later. Licensed under `BSD-4-Clause OR
AGPL-3.0-or-later`, at your choice.

## Building and testing from source

Build `libds.a` first, as `PORTING.md` at the repository root describes. Then,
from this directory:

```sh
pip install . --group test
pytest tests
```

The tests compile DS source, so they need the compiler: set `DS_MERCURY_DSC`
to a `dsc` from the release `libds` tarball of the same release as the tree, or
put one on `PATH`.

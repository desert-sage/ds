# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Generated Python bindings for every DS protobuf — `proto/*.proto`.

One `<stem>_pb2` module per proto, with protoc's stub for it beside it, built
by meson through `scripts/python/gen_proto_package.py`, which makes protoc's sibling
imports relative so the set works as a package in both the wheel and the
editable layout:

    from pyds.proto import schema_def_pb2

Nothing is imported eagerly; each module is loaded when asked for.
"""

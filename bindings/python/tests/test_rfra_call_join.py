# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The CallIssued↔RuleFireAnnotation fire-identity join at the event source.

The RuleFireAnnotation atom's identity (recorded from `rule_fire_begin`/`_end`)
and the CallIssued atom's identity (recorded from `action_call`) must be the
**byte-identical** `(timetag, rule_name)` — that equality is the join that
resolves a recorded CallIssued to its bracketing rule firing ([RFCS.11.2] /
[RFCS.15.2]). Both are the firing activation's `creation_timetag`, never a
constant.

This validates the join at the live-stream event level (where the encoders read
their fields from); the codec round-trip is covered in test_rfcs_codec.c.
"""

from __future__ import annotations

import pyds

_PROG = """\
service svc.notify:
    kwarg who: String
    no response

schema Trig scope logical:
    who: String key

rule r:
    Trig t
->
    call svc.notify who: t.who nocooldown
"""


def test_rfra_and_call_share_the_fire_identity():
    eng = pyds.from_source(_PROG)
    events = []
    eng.on_event = events.append
    eng.set_call_callback(lambda _req: None)
    eng.assert_("Trig", who="alice")
    eng.pump()

    ev = pyds.events
    begins = [e for e in events if isinstance(e, ev.RuleFireBegin) and e.rule_name == "r"]
    ends = [e for e in events if isinstance(e, ev.RuleFireEnd) and e.rule_name == "r"]
    calls = [e for e in events if isinstance(e, ev.ActionCall) and e.service == "svc.notify"]
    assert begins and ends and calls, f"missing events: {[e.kind for e in events]}"

    begin, end, call = begins[0], ends[0], calls[0]

    # The join: RuleFireAnnotation(begin) and the CallIssued it brackets carry
    # the identical (timetag, rule_name). This is the whole point.
    assert call.timetag == begin.timetag, (
        "CallIssued and RuleFireAnnotation timetag must match (the join)"
    )
    assert call.rule_name == begin.rule_name == "r"

    # begin and end RuleFireAnnotation carry the same identity (one firing).
    assert end.timetag == begin.timetag

    # A real fire identity, not the old hard-coded 0 / the AOT-path sentinel.
    assert begin.timetag > 0, "native-rete firing must carry a real creation_timetag"
    eng.close()

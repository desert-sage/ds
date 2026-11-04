# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Validation test for the derivation-graph reference reconstructor.

It runs real DS programs, captures each engine's live stream via
`Engine.on_event`, reconstructs the derivation graph, and asserts it against
the expected lineage — exercising the tightened edges, not just the happy path:

- §6 party example (the integration walk-back);
- factless firing (T1) — a negative-only rule → input-less firing node;
- rate-gated firing (T3 / §5.4) — a cooldown firing → output-less firing node;
- multi-justifier logical fact (§5.2) — the bare stream shows one parent, the
  `debug.justifiers` pull enrichment (I6) unions the rest in (NOT
  `RuleFireAnnotation`);
- cross-tier call↔response stitch (§5.3) — by the author correlation;
- cross-check — the push reconstruction agrees with the `debug.justifiers`
  pull surface (`getFactLineage` [RDBG.6.4] is not on the pyds surface — it is
  itself a stream reconstruction — so `debug.justifiers` is the pull reference).

The join key is the FactId every event carries: monotonic, never reused.
"""

from __future__ import annotations

from derivation import DerivationReconstructor

import pyds


def _run(source: str, driver, *, mock_clock: bool = False):
    """Load `source`, run `driver` with a fresh reconstructor on the stream, and return it.

    `driver` drives asserts / pumps. The engine is left open so
    `debug.justifiers` can be queried while paused.
    """
    try:
        eng = pyds.from_source(source)
    except Exception as exc:  # surface compile-error detail for diagnosis
        errs = getattr(exc, "errors", None)
        if errs:
            detail = "\n".join(
                f"  {getattr(e, 'code', '?')}: {getattr(e, 'message', e)}" for e in errs
            )
            raise AssertionError(f"compile failed:\n{detail}") from exc
        raise
    recon = DerivationReconstructor(eng)
    eng.on_event = recon.on_event
    eng.set_call_callback(lambda _req: None)  # calls succeed; ACTION_CALL fires
    if mock_clock:
        eng.clock.mode = "mock"
        # Non-zero base: the rate table uses last_fire_ns == 0 as its "never
        # fired" sentinel (adapters.c:795), so firing at t=0 would never gate.
        eng.clock.set(1_000_000_000)
    driver(eng)
    return eng, recon


# ---------------------------------------------------------------------------
# Factless firing (T1) — a negative-only rule fires with EMPTY inputs.
# ---------------------------------------------------------------------------

_FACTLESS = """\
schema Noise scope logical:
    entity_id: String key

schema Quiet scope logical:
    dummy: Int key

rule silence_rule:
    no Noise
->
    emit Quiet logical dummy: 0
"""


def test_factless_firing_is_inputless_node():
    def drive(eng):
        eng.pump()  # no Noise present -> silence_rule fires factless

    eng, recon = _run(_FACTLESS, drive)
    g = recon.graph

    firings = [f for f in g.firings if f.rule == "silence_rule"]
    assert len(firings) == 1, "silence_rule should fire exactly once"
    f = firings[0]
    # T1: a factless firing has NO preceding RULE_LHS_FACTS -> empty inputs,
    # but it is a real firing node, not dropped/malformed.
    assert f.inputs == [], "factless firing must have empty inputs (pending is None)"

    quiet = g.fact_by_slot("Quiet", dummy=0)
    assert quiet is not None
    assert f.outputs == [quiet], "the firing produced the Quiet fact"

    # The derivation tree of Quiet is an interior node whose single firing has
    # no fact children (a rule fired on an absence, not on facts).
    tree = g.tree(quiet)
    assert not tree.is_leaf
    assert tree.branches == [("silence_rule", [])]
    eng.close()


# ---------------------------------------------------------------------------
# Rate-gated firing (T3 / §5.4) — a cooldown firing is OUTPUT-LESS.
# ---------------------------------------------------------------------------

_RATE_GATED = """\
schema Ping scope logical:
    id: Int key

schema Pong scope ttl 60s:
    id: Int

rule echo cooldown 10min:
    Ping p
->
    emit Pong id: p.id
"""


def test_rate_gated_firing_is_outputless_node():
    # Cooldown is keyed by the bound fact's declared `key` slots ([LCDB.3.3.1]),
    # so re-firing the SAME key within the window is what gets gated. Fire echo
    # for Ping id:1, then retract + re-assert the same key so it re-fires inside
    # the 10-min window — the RHS is gated ([LCDB.3.2.1], RHS-level gate), the
    # FIRE_BEGIN/END bracket still runs.
    def drive(eng):
        h1 = eng.assert_("Ping", id=1)
        eng.pump()  # echo fires for key id:1, emits Pong, arms cooldown
        eng.retract(h1)
        eng.pump()
        eng.assert_("Ping", id=1)  # same activation key, still within the window
        eng.pump()  # echo re-fires -> RHS rate-gated -> no Pong

    eng, recon = _run(_RATE_GATED, drive, mock_clock=True)
    g = recon.graph

    echoes = [f for f in g.firings if f.rule == "echo"]
    assert len(echoes) >= 2, "echo fires for both the initial and the re-asserted Ping"
    assert len(echoes[0].outputs) == 1, "first firing emits Pong"
    # §5.4: the rate-gated firing fired (has inputs) but asserted nothing.
    gated = [f for f in echoes if f.inputs and not f.outputs]
    assert gated, (
        "a rate-gated firing is a node with inputs and ZERO outputs — "
        "'fired, RHS rate-gated', not 'derived nothing'"
    )
    eng.close()


# ---------------------------------------------------------------------------
# Multi-justifier logical fact (§5.2) — bare stream shows one parent; the
# debug.justifiers pull enrichment unions the second rule in.
# ---------------------------------------------------------------------------

_MULTI_JUSTIFIER = """\
schema A scope logical:
    id: Int key

schema B scope logical:
    id: Int key

schema L scope logical:
    id: Int key

rule from_a:
    A a
->
    emit L logical id: a.id

rule from_b:
    B b
->
    emit L logical id: b.id
"""


def test_multi_justifier_enriched_via_pull_api():
    def drive(eng):
        eng.assert_("A", id=1)
        eng.assert_("B", id=1)
        eng.pump()  # both derive L id:1; second coalesces (LFAC.2)

    eng, recon = _run(_MULTI_JUSTIFIER, drive)
    g = recon.graph

    lid = g.fact_by_slot("L", id=1)
    assert lid is not None

    # Bare stream: exactly ONE producer — the coalesced re-derivation emits no
    # fresh FACT_ASSERT, so only the first justifier appears in the graph.
    bare = g.producers(lid)
    assert len(bare) == 1, "the bare stream records only the first justifier"

    # §5.2 enrichment via the PULL API (debug.justifiers, I6): both supporting
    # rules surface. This is the union the bare tree cannot show.
    just = recon.justifiers(lid)
    assert len(just) == 2, "debug.justifiers reports both supporting activations"
    assert recon.justifier_rules(lid) == {"from_a", "from_b"}

    # The enrichment came from debug.justifiers, NOT the RuleFireAnnotation atom
    # (whose join is latent, work-order B). The reconstructor never reads
    # RuleFireAnnotation.
    assert bare[0].rule in {"from_a", "from_b"}
    eng.close()


# ---------------------------------------------------------------------------
# Cross-tier call -> response stitch (§5.3) — by the author correlation.
# ---------------------------------------------------------------------------

_CROSS_TIER = """\
service svc.notify:
    kwarg who: String
    no response

schema Trigger scope logical:
    who: String key

schema Response scope logical:
    corr: String key
    ok: Bool mutable

rule invite:
    Trigger t
->
    call svc.notify who: t.who nocooldown as "rsvp-1"
"""


def test_cross_tier_call_response_stitch():
    def drive(eng):
        eng.assert_("Trigger", who="alice")
        eng.pump()  # invite fires -> call as "rsvp-1"
        eng.assert_("Response", corr="rsvp-1", ok=True)  # the response (a root you assert)
        eng.pump()

    eng, recon = _run(_CROSS_TIER, drive)
    g = recon.graph

    # The engine saw an ACTION_CALL with the author correlation.
    assert any(c.correlation == "rsvp-1" for c in g.calls), "the call was captured"

    resp = g.fact_by_slot("Response", corr="rsvp-1")
    assert resp is not None
    assert g.facts[resp].root, "the response fact is a root in the engine's view (§5.3)"

    # §5.3: the stitch links the response fact to its originating call by the
    # author correlation — the engine's per-engine stream does not.
    stitched = recon.stitch_call_response(corr_slot="corr")
    assert stitched == 1
    assert g.call_of_fact[resp].correlation == "rsvp-1"
    eng.close()


# ---------------------------------------------------------------------------
# §6 party example — the integration walk-back + cross-check.
# ---------------------------------------------------------------------------

_PARTY = """\
service guest.invite:
    kwarg guest: String
    no response

schema GuestCandidate scope logical:
    guest: String key

schema Rsvp scope logical:
    guest: String key
    corr: String mutable
    attending: Bool mutable

schema HeadcountReached scope logical:
    id: Int key

schema PartyConfirmed scope logical:
    id: Int key

rule r1:
    GuestCandidate g
->
    call guest.invite guest: g.guest nocooldown as g.guest

rule r2:
    Rsvp r where r.attending == true
->
    emit HeadcountReached logical id: 1

rule r3:
    HeadcountReached h
->
    publish PartyConfirmed id: h.id
"""


def test_party_example_walk_back_and_cross_check():
    def drive(eng):
        eng.assert_("GuestCandidate", guest="alice")
        eng.assert_("GuestCandidate", guest="bob")
        eng.pump()  # r1 fires x2 -> calls
        # The RSVPs come back (roots you assert), carrying the call correlation.
        eng.assert_("Rsvp", guest="alice", corr="alice", attending=True)
        eng.assert_("Rsvp", guest="bob", corr="bob", attending=True)
        eng.pump()  # r2 x2 -> HeadcountReached; r3 -> publish

    eng, recon = _run(_PARTY, drive)
    g = recon.graph

    # Roots: the seed GuestCandidates and the asserted Rsvps.
    gc_alice = g.fact_by_slot("GuestCandidate", guest="alice")
    rsvp_alice = g.fact_by_slot("Rsvp", guest="alice")
    assert g.facts[gc_alice].root and g.facts[rsvp_alice].root

    # PartyConfirmed is published by r3, and is in no working memory here
    # ([LTIE.4.3]): a publish node, not a fact node.
    party = g.published("PartyConfirmed", id=1)
    assert party is not None and party.firing is not None
    assert party.firing.rule == "r3"
    assert g.fact_by_slot("PartyConfirmed", id=1) is None

    head = g.fact_by_slot("HeadcountReached", id=1)
    assert head is not None

    # Walk-back: the publish <- r3 <- HeadcountReached <- r2 <- Rsvp ... <- r1 <- GuestCandidate.
    assert party.firing.inputs == [head]
    head_sub = g.tree(head)
    assert head_sub.branches[0][0] == "r2"
    rsvp_leaf = head_sub.branches[0][1][0]
    assert rsvp_leaf.schema == "Rsvp"
    assert rsvp_leaf.is_leaf, "the Rsvp is a root leaf (its R1 link is the §5.3 stitch)"

    # §5.2 on HeadcountReached: two Rsvps justify it (both r2 firings), but the
    # bare stream coalesced them to one producer; the pull enrichment recovers both.
    assert len(g.producers(head)) == 1
    assert len(recon.justifiers(head)) == 2

    # §5.3: both Rsvps stitch to their originating r1 calls by correlation.
    assert recon.stitch_call_response(corr_slot="corr") == 2
    assert g.call_of_fact[rsvp_alice].correlation == "alice"

    # Cross-check: the push reconstruction agrees with the pull surface.
    # Every rule the stream attributed as a producer of HeadcountReached is among
    # the debug.justifiers activations for it (push ⊆ pull).
    pull_rules = {j.rule_name for j in recon.justifiers(head)}
    push_rules = {f.rule for f in g.producers(head)}
    assert push_rules <= pull_rules, "reconstruction disagrees with debug.justifiers reference"
    eng.close()

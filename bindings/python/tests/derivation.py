# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Reconstruct a fact **derivation graph** from the live stream-callback surface.

A reference implementation. This is the *push / live*
counterpart to the engine's *pull* lineage surface
(`engine.debug.justifiers` [NDBG.5.1]; `getFactLineage` [RDBG.6.4]): it builds fact
lineage continuously from the `Engine.on_event` event stream, with no
debugger attached. It adds **no engine behaviour** — it consumes the existing
normative stream contract, whose invariants (I1 to I6) are audited in
`SPEC_stream_provenance_reconstruction.md` §2.

Vocabulary (deliberate, from the logic-programming / TMS side — not "provenance",
which is the data-provenance/semiring theory and claims more than this delivers):

- **Derivation graph** — the persistent reconstructed object: a *bipartite DAG*
  of fact nodes and firing nodes, edges `input-fact -> firing -> output-fact`.
  It is a genuine DAG, not a tree: shared ancestors fan out, and a logical fact
  with multiple justifiers (§5.2) fans in. Acyclic because a fact's producers
  precede it in `seq`.
- **Derivation tree** — `graph.tree(fact_id)`: one fact's answer, the backward
  *unfolding* of its ancestor cone. A tree because unfolding re-expands shared
  sub-derivations (an SLD proof tree for one goal).
- **Justification** — the `engine.debug.justifiers` (I6) enrichment (§5.2):
  the TMS supporting-activation set for a logical fact. The bare stream shows
  only the first justifier; this unions the rest in. It uses the **pull API,
  not the `RuleFireAnnotation` stream atom** — `RuleFireAnnotation`'s
  `(timetag, rule_name)` join is latent (work-order B), so §5.2 routes through
  the built `justifiers` surface.

The §5 gaps are honest and inherent: the graph is *positive fact-lineage within
one engine*. It states which facts, via which rule, produced this fact — not the
full computational *why* (negation, `where` guards, `let`, series aggregations,
`cached()`/`now()` reads are non-fact inputs with no edge, §5.1).

Substrate: Python over `pyds`. Every event names its facts by FactId (the
stable monotonic join key) but a publish, which asserts nothing here
([LTIE.4.3]) and carries its schema and slots instead, recorded as a
`PublishNode` on its firing; the reconstructor needs `engine.facts[fid]`
(schema + slots), inside the callback for a fact the event is retracting, and,
for the §5.2 enrichment, `engine.debug.justifiers(fact_id)`.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import pyds


@dataclass
class FactNode:
    """A fact, keyed by its engine-local monotonic `fact_id` (I4).

    Slots are a snapshot copied inside the callback, never the live pointer.
    """

    fid: int
    schema: str
    slots: dict
    born_seq: int
    dead_seq: int | None = None
    root: bool = False  # asserted outside any firing bracket (seed / response / ambient)


@dataclass
class FiringNode:
    """A rule firing, keyed by `(rule, begin_seq)`.

    `inputs` are the resolved matched LHS facts (I1); `outputs` are the facts
    asserted in the bracket.
    """

    rule: str
    begin_seq: int
    inputs: list[int] = field(default_factory=list)
    outputs: list[int] = field(default_factory=list)


@dataclass
class PublishNode:
    """An `ACTION_PUBLISH`: a fact a firing sent to another tier (I5).

    It is in no working memory here ([LTIE.4.3]), so it has no `fact_id` and
    is no `FactNode`. Its schema and slots are the event's copies; its
    derivation is the firing that sent it, whose `inputs` are the facts it
    matched.
    """

    schema: str
    slots: dict
    seq: int
    firing: FiringNode | None


@dataclass
class CallNode:
    """An `ACTION_CALL`: the origin side of a cross-tier round trip (§5.3).

    It is stitched to its response fact by the author's `correlation` (LCRS).
    """

    service: str
    correlation: str
    args: dict
    seq: int


@dataclass
class DerivationTree:
    """One fact's derivation tree: the unfolding of `tree(fact_id)`.

    A leaf (a root fact) has empty `branches`; an interior fact has one branch
    per producing firing: `(rule, [child DerivationTree, ...])`.
    """

    fid: int
    schema: str
    branches: list[tuple[str, list[DerivationTree]]] = field(default_factory=list)

    @property
    def is_leaf(self) -> bool:
        return not self.branches


class DerivationGraph:
    """The reconstructed bipartite DAG.

    Build it via `DerivationReconstructor`, then query `tree(fact_id)`,
    `producers(fact_id)` and `roots()`.
    """

    def __init__(self) -> None:
        self.facts: dict[int, FactNode] = {}
        self.firings: list[FiringNode] = []
        self.calls: list[CallNode] = []
        self.publishes: list[PublishNode] = []
        # §5.3 cross-tier stitch edges: response fact_id -> originating CallNode.
        self.call_of_fact: dict[int, CallNode] = {}

    # --- §4.2 query -----------------------------------------------------

    def producers(self, fid: int) -> list[FiringNode]:
        """Return the firings that asserted `fid` in their bracket.

        Empty for a root fact. More than one is a multi-justifier fan-in, but
        the *bare* stream records only the first justifier (see
        `justifier_rules`, §5.2).
        """
        return [f for f in self.firings if fid in f.outputs]

    def tree(self, fid: int) -> DerivationTree:
        """Backward-unfold `fid`'s ancestor cone into a derivation tree.

        A root fact is a leaf. It terminates at the roots, since the DAG is
        acyclic (§4.2).
        """
        node = self.facts.get(fid)
        schema = node.schema if node is not None else "<unknown>"
        prods = self.producers(fid)
        if not prods:
            return DerivationTree(fid=fid, schema=schema)  # LEAF — a root
        branches = [(f.rule, [self.tree(i) for i in f.inputs]) for f in prods]
        return DerivationTree(fid=fid, schema=schema, branches=branches)

    def roots(self) -> list[int]:
        """Return the facts asserted outside any firing: the leaves of every tree.

        They are seed data, response facts and ambient facts.
        """
        return [fid for fid, n in self.facts.items() if n.root]

    def published(self, schema: str, **slots) -> PublishNode | None:
        """Return the first publish whose schema and given slots match."""
        for p in self.publishes:
            if p.schema == schema and all(p.slots.get(k) == v for k, v in slots.items()):
                return p
        return None

    # --- helpers --------------------------------------------------------

    def fact_by_slot(self, schema: str, **slots) -> int | None:
        """Return the first fact_id whose schema and given slots match.

        A test convenience: the graph keys on fact_id, not on content.
        """
        for fid, n in self.facts.items():
            if n.schema == schema and all(n.slots.get(k) == v for k, v in slots.items()):
                return fid
        return None


class DerivationReconstructor:
    """The ingest pass (§4.1): register `on_event` as the stream callback, then read `.graph`.

    The enrichments (§5.2 justification, §5.3 stitch) are separate,
    explicitly labelled steps, because they consult the pull API and the
    author's correlation, not the bare stream.
    """

    def __init__(self, engine) -> None:
        self._engine = engine
        self.graph = DerivationGraph()
        self._pending = None  # staged LHS facts (single slot — safe by I1/I3)
        self._cur: FiringNode | None = None  # open firing (single slot — I3 non-nesting)

    # --- §4.1 ingest ----------------------------------------------------

    def on_event(self, ev: pyds.events.Event) -> None:
        """Take one event, in `seq` order.

        Slots are snapshotted INSIDE the callback (I4), while the fact is still live.
        """
        seq = ev.seq
        match ev:
            case pyds.events.RuleLhsFacts():
                self._pending = {
                    "rule": ev.rule_name,
                    "inputs": list(ev.lhs_facts),
                }

            case pyds.events.RuleFireBegin():
                self._cur = FiringNode(
                    rule=ev.rule_name,
                    begin_seq=seq,
                    inputs=(self._pending["inputs"] if self._pending else []),  # None -> [] (T1)
                    outputs=[],
                )
                self.graph.firings.append(self._cur)
                self._pending = None

            case pyds.events.FactAssert(fact_id=fid):
                if fid not in self.graph.facts:
                    snap = self._engine.facts[fid]
                    self.graph.facts[fid] = FactNode(
                        fid=fid,
                        schema=snap.schema,
                        slots=dict(snap.slots),
                        born_seq=seq,
                    )
                if self._cur is not None:
                    if fid not in self._cur.outputs:
                        self._cur.outputs.append(fid)
                else:
                    self.graph.facts[fid].root = True  # asserted outside a firing

            case pyds.events.ActionPublish():
                # No fact here to tag: a publish asserts nothing in this tier
                # ([LTIE.4.3]). It is recorded against the firing that sent it.
                self.graph.publishes.append(
                    PublishNode(
                        schema=ev.schema,
                        slots=dict(ev.slots),
                        seq=seq,
                        firing=self._cur,
                    )
                )

            case pyds.events.ActionEmit():
                # The emitted fact is the FACT_ASSERT already handled above (dedupe by
                # fact_id, §4.1). A coalesced re-derivation of an existing logical fact
                # emits no fresh FACT_ASSERT (LFAC.2), so it is intentionally NOT
                # attributed here — the second justifier is recovered via §5.2.
                pass

            case pyds.events.FactRetract(fact_id=fid):
                node = self.graph.facts.get(fid)
                if node is not None:
                    node.dead_seq = seq

            case pyds.events.ActionCall():
                self.graph.calls.append(
                    CallNode(
                        service=ev.service,
                        correlation=ev.correlation,
                        args=dict(ev.args),
                        seq=seq,
                    )
                )

            case pyds.events.RuleFireEnd():
                self._cur = None

        # everything else (tick / timer / log / alert / record / cache) is not a
        # fact-lineage edge — ignored by the derivation graph.

    # --- §5.2 justification enrichment (pull API, NOT RuleFireAnnotation) ---

    def justifiers(self, fid: int) -> list[pyds.Justifier]:
        """Return every `(rule_name, timetag)` activation supporting a logical fact.

        This is I6, `engine.debug.justifiers`. It is meaningful only while the
        engine is paused (valid TMS state), so call it after the run. It is the
        pull surface §5.2 enriches with; it does NOT read the latent
        `RuleFireAnnotation` atom (work-order B).
        """
        return self._engine.debug.justifiers(fid)

    def justifier_rules(self, fid: int) -> set[str]:
        """Return the enriched parent-rule set.

        That is the union of the bare-stream producers and the
        `debug.justifiers` supporting rules. For a coalesced multi-justifier
        logical fact the bare graph shows one; this reveals all.
        """
        rules = {f.rule for f in self.graph.producers(fid)}
        rules |= {j.rule_name for j in self.justifiers(fid)}
        return rules

    # --- §5.3 cross-tier stitch (author correlation, NOT engine lineage) --

    def stitch_call_response(self, corr_slot: str = "corr") -> int:
        """Link each response fact to its originating `ACTION_CALL`; return how many.

        A response fact is a root you asserted, carrying the call's correlation
        in `corr_slot`, and the link is by the author's correlation (LCRS). The
        engine's per-engine stream stops at the call boundary (§5.3), so this
        edge is yours to add.
        """
        by_corr = {c.correlation: c for c in self.graph.calls}
        stitched = 0
        for fid, node in self.graph.facts.items():
            if not node.root:
                continue
            corr = node.slots.get(corr_slot)
            call = by_corr.get(corr) if corr is not None else None
            if call is not None:
                self.graph.call_of_fact[fid] = call
                stitched += 1
        return stitched

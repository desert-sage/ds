/*
 * SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
 * SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
 *
 * DS data model — ds_json single-ownership (Alloy 6).
 *
 * NORMATIVE COMPANION. Two traceability mechanisms, both machine-checked by
 * the spec gate's crossref:
 *
 *   1. NAME. Every element is named after the spec paragraph it formalizes,
 *      exactly as the conformance suite names its tests (test_idat_3_3_4__<tag>):
 *      <lowercased-clause-id>__<snake_tag>. A satisfiability probe carries the
 *      `probe__` marker.
 *   2. TAG. The line above each element repeats the clause in bracket form so the
 *      checker can confirm the id exists in the normative tree AND matches the name.
 *
 * THE INVARIANT. Every ds_json node has exactly ONE owner at any time ([IDAT.1.4]). A node
 * is owned EITHER by a containing node (its `parent`, established by a successful
 * `ds_json_array_append` / `ds_json_object_set` — [IDAT.3.3.4]) XOR by an external holder
 * (the caller who built it, or the engine's deep-cloned copy — [IDAT.3.3.3]/[IDAT.3.3.8]),
 * never both and never neither. Containment is an acyclic forest, and every node's ancestor
 * chain terminates at exactly one externally-held root. This model proves the consequences
 * that keep disposal deterministic: single ownership (one owner per node), free-once
 * (disposing every holder reaches each node exactly once — no double-free, no leak), and
 * ownership acyclicity (free terminates).
 *
 * TEETH: drop the held-iff-root rule and a node acquires two owners (a parent AND a holder →
 * double-free) or none (a leak); drop the acyclic rule and a containment cycle appears whose
 * nodes no free ever reaches.
 */
module ds/json_single_owner

//@spec [IDAT.3.3.4]
// A ds_json tree node. `parent` is the containing node that owns it after a successful
// append/set; `lone` encodes at-most-one container. A parent-less node is a tree root.
sig idat_3_3_4__node { parent: lone idat_3_3_4__node }

//@spec [IDAT.1.4]
// An external owner of root trees: the caller who built a tree, or the engine's stored
// deep-clone. `holds` are the root nodes this holder owns and must dispose exactly once.
sig idat_1_4__holder { holds: set idat_3_3_4__node }

//@spec [IDAT.1.4]
// Single ownership: containment is an acyclic forest; a node is externally held IFF it is a
// root (no parent); each held root has exactly one holder.
fact idat_1_4__single_owner {
  no n: idat_3_3_4__node | n in n.^parent
  all n: idat_3_3_4__node | (n in idat_1_4__holder.holds) iff (no n.parent)
  all n: idat_1_4__holder.holds | one h: idat_1_4__holder | n in h.holds
}

//@probe
// A valid ownership forest: at least one containment edge (a non-trivial tree) and an
// externally-held root. Satisfiable — the invariant is not vacuous.
run probe__valid_ownership_forest {
  some parent and some idat_1_4__holder.holds
} for 6

// SINGLE OWNER: every node is owned by exactly one owner — a contained node has exactly one
// parent and no holder; a root has no parent and exactly one holder. NO counterexample.
assert idat_3_3_4__exactly_one_owner {
  all n: idat_3_3_4__node |
    (one n.parent and n not in idat_1_4__holder.holds)
    or (no n.parent and one holds.n)
}
//@spec [IDAT.3.3.4]
check idat_3_3_4__exactly_one_owner for 6

// FREE-ONCE: disposing every holder frees each node exactly once — each node's ancestor
// chain contains exactly one externally-held root. No double-free, no leak. NO counterexample.
assert idat_3_3_4__free_reaches_each_node_once {
  all n: idat_3_3_4__node | one (idat_1_4__holder.holds & n.*parent)
}
//@derives [IDAT.3.3.4]
check idat_3_3_4__free_reaches_each_node_once for 6

// OWNERSHIP ACYCLIC: no node is its own ancestor, so the containment chain terminates and
// free is well-founded. NO counterexample.
assert idat_3_3_4__ownership_acyclic {
  no n: idat_3_3_4__node | n in n.^parent
}
//@spec [IDAT.3.3.4]
check idat_3_3_4__ownership_acyclic for 6

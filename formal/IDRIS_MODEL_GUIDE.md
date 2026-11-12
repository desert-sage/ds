<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->
# Finding your way in the Idris model

`formal/idris` is large (`ls formal/idris` is the census), and nobody
needs to read it whole. The lane is a chain of results: each module imports the ones
below it and exports a few theorems the ones above it rest on. To work on
one part, read that part's module, the headers of the modules it imports,
and the one or two exported theorems it actually uses. This guide says
which those are.

Two rules of thumb before the map:

- **The header is the contract.** Every module opens with a `|||` block
  that says what it models, which clauses it reads, what it proves, and
  what it relies on but does not establish. Read headers first; read
  bodies only for the theorem you are changing.
- **Do not re-derive what a lower layer exports.** If you need a fact
  about lists, Bool, `Maybe`, filters or the engine's step function, it
  almost certainly exists; the "Where the shared helpers live" section
  says where. Restating one is the commonest defect the review pass found.

The exact import graph is the modules' `import` lines; the map below is
that graph, with what each edge carries.

## Conventions, in ten lines

- Every element is named `<clause>__<tag>`: `iret_7_7__wave_consistent` is
  a fact about [IRET.7.7]. A capitalised head (`Iret_8_1__act`) is a type.
  `gap__…` elements state no clause, and their `--@gap` tag carries no reason.
- The line above an element, `--@spec [ID]`, `--@derives [ID]` or
  `--@gap`, is what the crossref reads. `spec` means "this defines
  what the clause says"; `derives` means "this follows from it".
- Each tagged element has a tie in `specs/**/<ID>.json` under
  `checks.idris` (path, name, tag, role, verdict, note), sorted by path
  then name. The roles table holds the role of every name. The crossref
  must report 0 checks-drift, 0 misnamed, 0 untagged after any rename,
  move or deletion.
- Verdicts: `proven` (the statement is the clause's), `partial` (the
  statement is narrower or wider than the clause, and the note says how),
  `refuted`, `assumed`. A `partial` is not a defect; it is a boundary the
  note names.
- `%default total` everywhere; no `believe_me`, `assert_total`,
  `assert_smaller` or postulate. `covering` appears only on the two
  runners' `main` and `fixtureMain` (file IO).
- `Main.idr` and `Fixture.idr` carry no tags by design.

## The map: four chains and a shelf

Modules are listed in import order. "Exports used above" is the interface
the next layer actually calls; if you change one of those, everything
above it is affected.

### Chain 1: the engine and its termination (`Rete/FireLoop`, `Lcyc/*`)

| Module | What it is | Exports used above |
|---|---|---|
| `Rete/FireLoop` | The deterministic fire loop as the specs define it: facts, tokens, tables, `iret_11_4__step`, `iret_11_4__run`, selection ([LDET.5.1]), the `fired` flag ([IDAT.6.2.2]), `Iret_11_4__halt` (`Quiescent` / `FuelOut`). Imports nothing. | Every definition. Its `Uninhabited` instances for the halt type. |
| `Lcyc/Lemmas` | Library lemmas: Nat/Bool bridging, `Elem`/`All`/`filter`/`map` facts, `rarc_5_6_5__nth`/`set_at`, working-memory frame lemmas. | `lcyc_1_1__*` list lemmas used lane-wide (`elem_filter_inv`, `all_lookup`, `filter_ext`, `not_true_is_false`, `and_true_l/_r`…). |
| `Lcyc/Propagation` | A rule's re-propagation depends only on the kinds it reads; a settled table is a fixpoint; marking keeps settledness. | `Iret_8_1__settled`, `iret_8_1__prop_with_settled`, `ldet_5_1__select_next_pending`, `lcyc_1_1__just_injective`, `map_id_all`. |
| `Lcyc/Certificate` | The termination certificate `Lcyc_3_1_1__certified`: strata, literals, the lexicographic measure, `Lcyc_1_1__lex_lt` and its accessibility (`lcyc_1_1__lex_acc`, on base `Accessible`), the run invariant `Lcyc_1_1__inv`. | `lcyc_1_1__measure`, `lcyc_1_1__lex_acc`, `Lcyc_1_1__inv`, `lcyc_1_1__dom_of`. |
| `Lcyc/Termination` | Every step of a certified program decreases the measure and keeps the invariant; **`lcyc_1_1__certified_terminates`**. Also the shape lemmas `iret_19_1__emit_shape`, `lscp_2_1_1__withdraw_shape` and the emit/withdraw frame facts every later engine reuses. | `lcyc_1_1__quiesces`, the shape lemmas, `lcyc_1_1__lte_neq_lt`, `lcyc_1_1__pair_eta`, `lfac_2_5_3__fresh_id_free` (from TmsRun; see below). |
| `Lcyc/Witnesses`, `Lcyc/WitnessProofs` | Executable witness programs (the W-series, grow/reap, churn) and computed `halts_at` / `FuelOut` facts about them. Leaves; nothing imports WitnessProofs. | Nothing. Read when you need an example run. |
| `Lcyc/CertifiedWitness` | One program that carries the certificate, built: two rules in two strata, each field of `Lcyc_3_1_1__certified_tms` proved for it, and the two termination theorems applied to it (`lcyc_1_1__chain_terminates`, `lcyc_1_1__chain_terminates_tms`). Leaf. | Nothing. It is the witness that the theorems' hypothesis can be met. |

Read for: what a firing does, why a certified program halts, what the
certificate demands. Skip `Lemmas` bodies; grep it for the lemma you need.

### Chain 2: truth maintenance on the engine (`Rete/Refcount` … `Rete/TtlSweep`)

| Module | What it is | Exports used above |
|---|---|---|
| `Rete/Refcount` | Standalone: the justification refcount over a graph that may have cycles ([IRET.12.2]), the well-founded semantics of [LLOG.2.5], ranked programs ([IRET.12.3]). Imports nothing from the lane, by design, so it duplicates two Nat-equality lemmas of `Lemmas` on purpose. | `iret_12_2__cascade`, `iret_12_2__cascade_fixed/_greatest/_unfounded`, `iret_12__bool_split`, `iret_12__not_false`, `iret_12__filter_lte`. |
| `Rete/FireLoopTms` | FireLoop plus the dependency table ([IRET.12.4]) and the phase that drops ended rows and retracts what they alone supported: `Iret_12__state`, `iret_12_2__phase`, `iret_11_4__step_tms`, `iret_11_4__run_tms`. | The definitions; `iret_11_4__just_inj`; `iret_11_4__step_agrees` (a TMS step is a core step plus the phase). |
| `Rete/TmsBridge` | The engine's cascade **is** Refcount's cascade of its own table (`iret_12_2__bridge`). Also the Bool/`Maybe`/table helpers the network side uses. | `iret_12_2__bridge`, `iret_12_2__phase_n_fixed`, `iret_12__and_both`, `iret_12_2__any_true`, `iret_12_2__elem_concat_map`, `iret_11__table_at_nth`, `iret_12__cons_not_nil`. |
| `Rete/TmsRun` | The run invariant: every state of a TMS run satisfies the bridge's premises (`iret_12__run_inv_holds`, `_certified`). The run-unfolding lemmas `iret_11_4__run_tms_nothing/_just`; `lfac_2_5_3__fresh_id_free`. | Those, plus `iret_12__elem_set_at`, `iret_12__or_inv`, `iret_12__lte_b`. |
| `Lcyc/TmsTermination` | **`lcyc_1_1__certified_terminates_tms`**: a certified positive program quiesces with logical retraction in the loop. | `lcyc_1_1__quiesces_tms`, `Lcyc_3_1_1__certified_tms`. |
| `Rete/PumpBoundary` | Inputs each pumped to quiescence, [LFST.9.2.1]'s cadence: `rarc_5_6_4__apply`, `rarc_5_6_6__pump_tms`, `lfst_9_2_1__boundary`, `Lfst_9_2_1__canonical`; the boundary keeps the bridge (`iret_12_2__boundary_fixpoint`). | `Rarc_5_6_1__event`, `lfst_9_2_1__canonical_from_input`, the apply/boundary invariants. |
| `Rete/TmsRanked` | What [IRET.12.2] rests on: on a program certified as [LCYC.3.1.1] admits it, the table is ranked at every state with the run invariant (`iret_12_3__certified_ranked`), so the count leaves live exactly the well-founded set (`iret_12_2__certified_exact`, through `PumpBoundary`'s `iret_12_3__boundary_ranked`). | `iret_12_3__certified_ranked`, `iret_12_3__rank`, `iret_12_4__row_justif`. |
| `Rete/RecomputeDiff`, `RecomputeFire`, `RecomputeStrata`, `Lcyc/TmsWitnesses` | The exploration of a recursive admission: recompute-and-diff, a candidate for the mechanism that finds unfounded sets, which [IRET.12.2]'s last paragraph requires before emit-and-read cycles can be admitted. `RecomputeDiff` is the step at a boundary, exact against [LLOG.2.5]'s well-founded set (`llog_2_5__rd_exact`) and the identity on every certified program, through `TmsRanked`; `RecomputeFire` puts it after every action; `RecomputeStrata` confines it to the recursive strata; `Lcyc/TmsWitnesses` is the reach run the count gets wrong. No clause states the step: its elements are `gap__`, and what they show of [LLOG.2.5] is tied there. Leaves. | `gap__run_rd` for Main's examples. |
| `Rete/TtlSweep` | The clock, the deadline table and the TTL sweep at every pump ([IRET.19.3], [IRET.22.6]; expiry is at or before the clock): `Iret_19_3__clocked`, `rarc_5_6_3__sweep`, `iret_11_4__run_ttl`, `Lfst_9_2_1__canonical_ttl`. Imported only by `Rete/NetworkTtl`. | `lfst_9_2_1__canonical_ttl_from_input`, `Iret_4_3__deadlines_ok`, `rarc_5_6_3__next_clock`. |

Read for: what a phase does, why the refcount is correct, what a pump is.
This chain encodes: well-founded is the contract, and the
count is libds's mechanism (`Refcount` header, `TmsRanked` header);
expiry is inclusive (`TtlSweep`).

### Chain 3: the network, and the transfer (`Rete/Network` … `Rete/NetworkTraced`)

This is the long one. Its shape: the network is defined once
(`Network`), three invariants are proved of it layer by layer (the view,
the order, refraction), then the network is shown to agree with the
engine of chain 1 step for step (the transfer), then with the engine of
chain 2 (the transfer with truth maintenance), then with the clock.

| Module | What it is | Exports used above |
|---|---|---|
| `Rete/Network` | The Rete network as the specs define it: alphas ([IRET.6]), betas and the four propagation paths ([IRET.7]), terminals and the agenda ([IRET.8], [IRET.11]), working-memory operations ([IRET.19]), the firing loop, the loader (`rdsc_4a_5__load`), and the lowering of a chain to a rule (`rlow_4_2_1__rule_of`, [RLOW.4.2.1]). | All definitions. |
| `Rete/NetworkView` | The view invariant `Iret_7_7__consistent` (every memory is the recompute) and the generic list lemmas the network side shares: `iret_11_3__elem_cons`, `iret_7_9_1__length_snoc`, `iret_8_1__insert_keeps`, `lcyc_1_1__filter_ext_on`, `lcyc_1_1__filter_filter`, `Iret_11_3__distinct`, `Iret_7_4__same_set`. | Those, plus `wave_consistent`, `unwave_consistent`. |
| `Rete/NetworkPaths` | Right-activation and right-retraction keep the view ([IRET.7.7], [IRET.7.9.2], [IRET.7.9.3]). | `right_activate_consistent`, `right_retract_consistent`, `iret_7_7__extend_elem_inv/_fwd`. |
| `Rete/NetworkDispatch` | **The view theorem** (`rarc_5_6_5__recompute_after_history`): after any history every memory is the recompute. Also `Iret_19__view`, `lfac_2_5_3__fresh_not_elem`, `lcyc_1_1__lte_neq_lt`'s users. | `Iret_19__view`, `rarc_5_6_5__view_recomputed`, `lfst_9_2_1__replay_net_view`, `rdsc_4a_5__load_view`. |
| `Rete/NetworkOrder` | The canonical activation order ([LDET.5.5]): `ldet_5_5__before`, irreflexive/asymmetric/transitive/total, kept by every terminal operation and every change of working memory. | `Ldet_5_5__sorted`, `before_append`, `ldet_5_9__before_remove`, `before_irrefl/_asym`. |
| `Rete/NetworkOrderKeep` | **The order theorem** (`ldet_5_9__order_after_history`): terminals are always in canonical order; no two activations of a rule share a timetag. | `Ldet_5_9__ordered`, `ldet_5_9__sorted_unique`, `*_ordered` for every operation. |
| `Rete/NetworkRefraction` | **The refraction theorem** (`iret_11_3__refraction_after_history`): the `fired` flag is the whole of [IRET.11.3]'s set, on the flag reading. | `iret_8_2__insert_act_inv`, `iret_11_4__map_ext`. |
| `Rete/NetworkCorollaries` | Corollaries after any history (one live fact per key, at most one candidate per anchor, acquire). | `rlow_4_2_1__*_unique` facts used by Agree. |
| `Rete/NetworkAgree` | **Transfer, part one**: the network's recompute of a chain is, as a set, FireLoop's match set less the blocked (`rlow_4_2_1__recompute_agrees`, `terminal_agrees`). | Those two; `rlow_5_3__tests/_facts`. |
| `Rete/NetworkTransferOrder` | **Part two (i)**: FireLoop's enumeration is the key's order (`iret_7_4__tuples_lex_sorted`, `ldet_5_9__sorted_tuples_unique`). | `Ldet_5_5__sorted_tuples`, `ldet_5_5__lex_to_sorted`, `iret_7_4__match_sub`. |
| `Rete/NetworkTransferTable` | **Part two (ii)**: FireLoop's tables stay well-formed (`Iret_8_1__well`, `Rarc_5_6_5__well`) through every history of the plain pipeline (`lfst_9_2_1__replay_plain`). | `rarc_5_6_5__well_grow/_shrink`, `rarc_5_6_4__apply_plain`, `rarc_5_6_5__well_after_history`, `iret_11_3__tuples_of`. |
| `Rete/NetworkTransferFlags` | **Part two (iii)**: the `fired` flag persists across a change of working memory (`Iret_8_1__evolves`, `iret_19_1__insert_flags`, `iret_19_2__retract_flags`). | Those. |
| `Rete/NetworkTransferAgree` | **Part two (iv)**: the agreement `Rlow_4_2_1__agree` (rules, tables, order, well-formedness) and its step, `rlow_4_2_1__change_agree`. Also `Lgra_6_1__same_rule` (extensional rule equality) and `iret_11_3_1__unblocked_acts`. | `Rlow_4_2_1__agree`, `Rlow_4_2_1__tables_agree`, `change_agree`, `iret_7_9__any_ext`. |
| `Rete/NetworkTransfer` | **The transfer theorem** (`rlow_4_2_1__transfer`): on one history the network and FireLoop reach one working memory and every table's unblocked tokens are the terminal's activations, in order and with flags. Plain pipeline only. | `select_agree`, `mark_tables_agree`, `do_actions_agree`, `assert_agree`, `retract_agree`, `init_agree`, `rlow_4_2_1__rule_at`. |
| `Rete/NetworkTmsCascade` | Retracting facts one at a time (the network) reaches the state of the batch retraction (FireLoop): propagation composes along a shrink. | `rarc_5_6_5__propagate_shrink_compose`, `propagate_settled_id`, `iret_12_2__retract_ids_cons_live/_dead`. |
| `Rete/NetworkTms` | The network engine with the dependency table; one phase agrees, and the cascade (`rlow_4_2_1__phase_agree`). | `Iret_12__net_state`, `iret_12_2__phase_net`, `phase_agree`, `retract_ids_agree`, `iret_19__engine_eta`. |
| `Rete/NetworkTmsTransfer` | **The transfer with truth maintenance** (`rlow_4_2_1__transfer_tms`, `transfer_canonical`): TmsRun's and TmsTermination's results reach the network. | `rarc_5_6_4__apply_tms_net`, `iret_11_4__run_tms_net`, `run_tms_agree`, `apply_tms_agree`. |
| `Rete/NetworkTtl` | **The transfer with ticks** (`rlow_4_2_1__transfer_ttl`), [LDTL.6.1]'s expiry order, [IRET.22.6] on the network. Leaf. | Nothing; read it for the clocked network. |
| `Rete/NetworkTraced` | Any cadence of inputs and pumps keeps the agreement; the traced pump. What `Fixture.idr` runs, under `Rete/NetworkCooldown`'s gate. | `rarc_5_6_1__run_steps_net`, `iret_11_4__run_tms_net_traced`, `iret_11_4__fire_ttl_net`, `iret_11_4__run_ttl_net_traced`. |

Read for: anything about alpha or beta memories, terminals, order,
refraction, or "does the network do what FireLoop does". To change how a
path propagates, start at `Network` and expect to touch `NetworkPaths`,
`NetworkOrderKeep`, `NetworkTransferFlags` and `NetworkTransferAgree`,
because each proves a different invariant of the same path.

### Chain 4: the `where` evaluator (`Rete/Eval`)

| Module | What it is | Exports used above |
|---|---|---|
| `Rete/Eval` | Values, results, the four answers, the absorbing `and`/`or`/`not` of [LNUL.4.2], arithmetic and comparison with null propagation, `is null`, a `Json` document with its paths, `has`, `len` and deep equality, a String's text with its codepoint equality and order, its `len`, and the Int and Bool parses and renders, the Float parse and render -- [LCST.4.5.8]'s nearest double and [LDET.3.2.7]'s shortest round-trip text in [LDET.3.2.8]'s rounding, exact Integer arithmetic, run not proved -- expressions and `iret_7_6__eval` over an environment `Iret_7_6__env` (what an id stands for; the runner's value code, `Fixture.idr`, supplies the decoder and resolves a String token to its text through the input's `string` records), the two join relations. Imports only FireLoop. | `Lnul_4_2__answer`, `lnul_4_3__admits`, `lnul_4_7__blocks`, `iret_7_6__admits_join/_blocks_join`. |

Read for: what a `where` answers and what a `no` node blocks on. The V5
reading of `and` with faults, and the anchor probe of [IRET.7.5.1] with the
`null` anchor that escapes it, are `formal/alloy/where_v5.als` and
`formal/k/dswherev5.k`; the evaluator here carries one trap kind.

### Leaves off chain 3

The clocked network and what stands on it. Each leaf's header is its
contract and its review brief (in the lane's working records, outside the
public tree) is its reading; one line each here, with the theorem to look for.

- `Rete/NetworkTick`: a join test that reads the clock, re-timed by the
  tick (LTIM.2.4.1); a window that shuts and reopens fires once per opening
  (`ltim_2_5_1__second_edge_refires`). Unit N.
- `Rete/NetworkClocked`: NetworkTtl's tables with NetworkTick's tests, one
  tick in IRET.19.5's order (`ldet_5_8__quiet_tick_clocked`,
  `iret_19_5__tick_clocked_view`); the pumped history as one fold
  (`iret_19_5__run_clocked`). Unit Q.
- `Rete/NetworkEdges`: for an action-free program the pump at a tick fires
  the matches the tick made, and over a history a gate's rising edges
  (`ltim_2_5_1__counts_are_edges`). Unit Q.
- `Rete/NetworkTwoClocks`: the wall clock and the entry stamps beside the
  engine; the replay drives it where the recording went, the wall clock
  moves no monotonic gate, a rising gate fires at most once
  (`rfcs_10_5__replay_drives_the_engine`, `ltim_2_8_2__counts_ignore_wall`,
  `ltim_2_5_1__rising_fires_at_most_once`). Unit Q.
- `Rete/NetworkCooldown`: Rete/RateGate.idr's gate threaded through the
  clocked network's firing, the trackers beside the engine, a rule's
  cooldown as a window and a key function of the fired match
  (LCDB.3.2.1, RLOW.4.6.2.2, IRET.10.4, RDSC.4a.8.2.3); the window
  suppresses and the boundary is inclusive, a refused firing marks the
  activation and runs no action, one stamp per firing, and the frame: with
  no rule cooled the gated pump is `iret_11_4__run_ttl_net_traced`
  (`lcdb_3_2_1__no_cooldown_is_the_plain_pump`). `Rete/NetworkTimed`'s
  pump runs this gated pump. Unit W.
- `Rete/NetworkTimed`: the time-dependent `where` on the Idris model's engine
  (LTIM.2.4.1, LTIM.2.4.2, LTIM.2.5.4, LEXP.9.5.1, LCDB.3.2.3,
  RDSC.4a.8.2.1 to 4a.8.2.3): `Rete/Eval`'s clock leaf (`EClock`: `now()`,
  `monotonic_ns()`, `t.dwell`) substituted by its literal under the pump's
  sample and the entry stamps before the plain evaluator runs
  (`ltim_2_4_1__at_sample`), a rule's timed test as a function of the stamps
  and the sample, the RHS stamping every mint, the gated firing with stamps,
  and the pump re-timing every timed chain at its entry then running
  NetworkCooldown's gated pump; the frame: with no rule timed the timed pump
  is the gated pump (`ltim_2_4_1__no_timed_rule_is_the_gated_pump`); a tick
  then a pump is NetworkClocked's pump, so on this engine the wall clock
  moves no monotonic gate, a rising gate fires at most once and the counts
  are the edges; the timed fixtures' shapes executed. `Fixture.idr` runs a
  timed `where` through it. Unit X.
- `Rete/NetworkWall`: the wall clock on the Idris model's engine (LTIM.2.8.3,
  NTST.3.1, LTIM.2.1.1, LTIM.2.1.2, LTIM.2.8.2): the wall step that sets the
  wall sample alone (`ltim_2_8_3__wall_set_timed`, NTST.3.1's wall set and
  the wall half of an advance) and a fixture's steps with it; on this
  engine a wall step moves no firing of a monotonic `where`
  (`ltim_2_8_2__wall_step_moves_no_monotonic_pump`), whose hypothesis the
  runner's monotonic form inhabits; a `now()` test is not a monotonic gate
  (`ltim_2_8_3__now_test_is_not_monotonic`); the thirteen wall-clock
  fixtures' shapes executed, the wall gate that reopens among them.
  `Fixture.idr` runs a `wall` step through it. Unit Y.
- `Rete/NetworkTimer`: `after` timers, the reading the fixture lowering
  writes (LTAC.3.2 to 3.6, 4.1, 5.1, 5.3, 7.1, LCCO.5.4): the timer fact
  with no `fire_at` slot -- its entry stamp carries it -- so the follow-up's
  guard `monotonic_ns() >= t.fire_at` is the `dwell` gate `t.dwell >= dur`
  (`ltac_3_4__guard_is_due`, a Nat lemma under LTAC.7.1's positive
  duration) and the stamp of a mint is `fire_at` less the duration
  (`ltac_3_3__stamp_is_fire_at`); the captures riding on the timer's
  payload, the snapshot proved by substitution
  (`ltac_3_5__capture_snapshot`). No engine and no lowering of its own:
  the runner executes a lowered `after` clause on `Rete/NetworkTimed`'s
  engine, and the engine comparison holds how often the follow-up fires.
  Unit Z.
- `Rete/NetworkCall`: the call surface on the Idris model's engine
  (LCRS.4.2.1, 4.2.2, 4.3.1, 4.3.2, 6.2, 6.2.1, 6.2.4, 8.2, 17.1,
  RLOW.7.3.8, 4.6.6.1, 4.6.6.6, NCBK.6.4, 6.9, LRST.1.2): a program's answer
  kinds and where each keeps its `corr`, read through `Rete/Eval`'s
  environment; the sweep a call performs on its correlation before it is
  issued and the sweep an arriving answer performs before it enters, each
  `Rete/NetworkTtl`'s retraction of a list of ids and then the cascade; a
  call site at its position among the rule's actions, the per-call rate
  gate on the site's own tracker table, and the call record;
  `Rete/NetworkTimed`'s stamped fold walked beside the sites
  (`rlow_7_3_8__do_actions_called`), the gated firing with calls, the pump,
  and the arrival (`lcrs_6_2_4__arrive_timed`). The frames: with no site the
  called pump is NetworkTimed's (`lcrs_6_2_1__no_site_is_the_timed_pump`),
  and with no kind carrying a `corr` an arrival is the input. The sweep
  only removes and what it was asked to remove is gone
  (`lcrs_6_2_1__issued_call_sweeps`); a call its cooldown suppresses is not
  issued and retracts nothing (`lcrs_6_2_1__suppressed_retracts_nothing`);
  the twelve call fixtures' shapes executed. That one answer per
  correlation holds after every history is
  `formal/tla/call_response.tla`'s `lcrs_6_2_4__one_answer_per_corr`,
  within its bounds, and no theorem here. What `Fixture.idr` runs a
  `callsite` record through. Unit AA.

### The shelf: definitional units and side proofs

- Standalone side proofs, one clause each, importing nothing:
  `AbsentTrichotomy` ([LNUL.11.1]: the verbs' table over a `null` argument,
  and no total function recovers a store miss once it is collapsed into
  `null`), `Rete/ActivationKey` ([RLOW.4.6.2.1],
  [IRET.25.5.3]: the key's identity and libds's frame injective over it),
  `Rete/RateGate` ([RLOW.4.6.2.2]: the gate, and the sentinel it refuses).
- `FixedRound` (LDET.3.2.8): `float_fmt.c`'s primitives,
  taken at their contracts, compose into the clause's fixed-precision
  rounding for every value and precision. Imports nothing; its pass is owed.
- `Rete/RunFold`: the bounded run as one fold over any step
  (`iret_11_4__run_by`, the traced `iret_11_4__trace_by`), the unfoldings
  proved once; each engine bridges its loop to it (`iret_11_4__run_*_by`)
  and takes the unfoldings through the bridge. `NetworkTraced`'s traced
  `_core` keeps its own proof (its firing names two things; the regrouping
  lemma is a constraint the checker leaves unsolved). To prove something of
  a new engine's run, bridge it and take the lemmas from here.
- The two clocks: `TwoClocks` (one sample per step, the replay from any
  starting clocks; imports nothing) and its leaf `Rete/EntryStamp`
  ([LTIM.2.8.6]), which the clocked network engines import.
- Runners: `Main` (the worked examples, run not proved) and `Fixture` (a
  lowered conformance fixture run on `NetworkTraced`). Untagged.

## Task → what to read

| You want to… | Read | Then touch |
|---|---|---|
| Change how a firing selects, marks or runs actions | `Rete/FireLoop` header and `iret_11_4__step`; `Rete/Network` `iret_11_4__step_net` | `NetworkTransfer` (`select_agree`, `mark_agree`, `step_fire`) and `NetworkTmsTransfer`'s copies |
| Change the termination certificate or measure | `Lcyc/Certificate`, `Lcyc/Termination` header and `lcyc_1_1__step_decreases_inv` | `Lcyc/TmsTermination` (`step_tms_decreases`) |
| Change the TMS phase or the dependency table | `Rete/FireLoopTms`, `Rete/TmsBridge` header and `iret_12_2__bridge` | `Rete/TmsRun` (the run invariant), `Rete/NetworkTms` (`phase_agree`) |
| Change what the refcount means | `Rete/Refcount` header | `TmsBridge`, `TmsRanked` (`certified_ranked`, `certified_exact`), `RecomputeDiff` (the step's exactness) |
| Change a propagation path (wave, right-activate, retract) | `Rete/Network`, `Rete/NetworkPaths` | `NetworkOrderKeep`, `NetworkTransferFlags`, `NetworkTransferAgree` shapes |
| Change the activation order | `Rete/NetworkOrder`, `NetworkOrderKeep` header | `NetworkTransferOrder`, `NetworkTransferTable` (`prop_well_grow`) |
| Change refraction | `Rete/NetworkRefraction` header | `NetworkTransferFlags`, `NetworkTick` |
| Change the pump, the boundary or a canonical replay | `Rete/PumpBoundary` | `NetworkTmsTransfer` (`boundary_tms_agree`, `canonical_tms_agree`), `TtlSweep`, `NetworkTtl` |
| Change the clock, deadlines or the sweep | `Rete/TtlSweep` header | `NetworkTtl` (`sweep_agree`, `ldtl_6_1__order`) |
| Change what `where` evaluates or how `and` treats a trap | `Rete/Eval` header | `Fixture` if the fixture grammar does; `formal/alloy/where_v5.als` and `formal/k/dswherev5.k` for the fault kinds |
| Change the rate gate, a cooldown's key or what a refused firing leaves | `Rete/RateGate` header; `Rete/NetworkCooldown` header and `lcdb_3_2_1__fire_gated` | `NetworkCooldown`'s firing theorems and its frame (`no_cooldown_is_the_plain_pump`); `NetworkTimed`'s stamped copies (`ltim_2_5_4__rhs_gated`, `fire_timed`) and their projections; `Fixture` for the `cool` record and the `gated` line; the lowering's key composition |
| Add a clock leaf, change what `dwell` reads, or where a timed `where` is re-evaluated | `Rete/Eval` `Ltim_2_4_1__read`; `Rete/NetworkTimed` header, `ltim_2_4_1__at_sample` and `ltim_2_4_3__retime_at_entry` | `NetworkTimed`'s leaf theorems (`clock_free_unchanged`, `subst_ignores_wall`), its frame and `tick_then_pump_is_clocked`; `NetworkWall`'s `now_leaf_reads_the_wall` and `now_test_is_not_monotonic`; `Fixture` for the `dwell` / `mono` / `now` grammar and the timed test it builds; the lowering's `where:timed-shape` refusal |
| Change what moves the wall sample, or what `now()` reads | `Rete/NetworkWall` header and `ltim_2_8_3__wall_set_timed`; `Rete/NetworkTwoClocks` C2 and C3b | `NetworkWall`'s `wall_step_moves_no_monotonic_pump` and its witnesses; `Fixture` for the `wall` step; the lowering's wall tracking (`step wall`, `calendar.time`'s fold) |
| Change what an `after` clause lowers to, the timer's guard, or what rides on the timer | `Rete/NetworkTimer` header and `ltac_3_4__guard_is_due` | `NetworkTimer`'s `ltac_3_3__stamp_is_fire_at`, `ltac_3_5__rewrite` and the snapshot; the lowering's AFTER TIMERS section and `_capture_reads`; `Fixture` for the `synthetic` record |
| Change what a call sweeps, where the sweep sits in the RHS, the per-call gate's key, or what an arriving answer retracts | `Rete/NetworkCall` header, `lcrs_6_2_1__issue`, `rlow_7_3_8__do_actions_called` and `lcrs_6_2_4__arrive_timed` | `NetworkCall`'s sweep theorems (`issued_call_sweeps`, `retraction_keeps_non_victims`), the gate's (`site_admitted`, `site_refused`) and its frames; `Fixture` for the `answer` and `callsite` records and the `call` line; the lowering's CALLS section; `formal/tla/call_response.tla`'s MODEL <-> MODEL paragraph |
| Add a witness program or an example run | `Lcyc/Witnesses`, `Lcyc/WitnessProofs` (`halts_at`), `Main` `cases` | Nothing else |
| Understand a `partial` verdict | The tie's note in `specs/**/<ID>.json`, then the module header's "not claimed" or "residue" paragraph | Nothing; that is a spec boundary |

## Where the shared helpers live

Before writing a lemma, grep these. The names say which layer owns them.

- `Lcyc/Lemmas`: Nat/Bool bridging (`lcyc_1_1__nat_eq_*`, `and_true_*`,
  `not_true_is_false`, `bool_not_both`), `Elem`/`All`/`filter`/`map`
  (`elem_filter_inv/_fwd`, `all_lookup`, `all_from_elem`, `filter_ext`,
  `filter_all_true/_false`, `elem_map_inv/_fwd`, `any_elem`,
  `any_false_all`), `nth`/`set_at`, working-memory frames.
- `Lcyc/Propagation`: `lcyc_1_1__just_injective`, `map_id_all`, settledness.
- `Lcyc/Termination`: `iret_19_1__emit_shape`, `lscp_2_1_1__withdraw_shape`,
  `lcyc_1_1__lte_neq_lt`, `lcyc_1_1__pair_eta`, `lcyc_3_1_1__range_widen`.
- `Rete/Refcount` (standalone): `iret_12__bool_split`, `iret_12__not_false`,
  `iret_12__filter_lte`, `iret_12__elem_singleton`.
- `Rete/TmsBridge`: `iret_12__and_both`, `iret_12_2__any_true`,
  `iret_12_2__elem_concat_map`, `iret_11__table_at_nth`,
  `iret_12__cons_not_nil`, `rarc_5_6_4__lookup_some`.
- `Rete/TmsRun`: `iret_11_4__run_tms_nothing/_just`, `iret_12__elem_set_at`,
  `iret_12__or_inv`, `lfac_2_5_3__fresh_id_free`.
- `Rete/FireLoopTms`: `iret_11_4__just_inj`.
- `Rete/RunFold`: the run's unfoldings over any step (`iret_11_4__run_by_nothing`,
  `_just`, `_fst_nothing`, `_fst_just`), the traced fold's (`trace_by_core`,
  `_cons`, `_end`) and `iret_11_4__run_by_sim`; an engine reaches them through
  its bridge (the shelf entry below).
- `Rete/NetworkView`: `iret_11_3__elem_cons`, `iret_7_9_1__length_snoc`,
  `iret_8_1__insert_keeps`, `lcyc_1_1__filter_ext_on`,
  `lcyc_1_1__filter_filter`, `iret_7_2__snoc_inj`, distinctness and
  same-set lemmas.
- Base library, confirmed in Idris 2 0.8.0: `reflexive`, `transitive`,
  `antisymmetric` (for `LTE`), `cong2`, `lengthMap`, `fromLteSucc`,
  `succNotLTEpred`, `plusLteMonotoneLeft`, `notLTImpliesGTE`,
  `lteSuccRight`, `succNotLTEzero`, `minusLteMonotone`, `minusPlus`,
  `Injective S`, `consInjective`, `Uninhabited` for
  `True = False`, `Just x = Nothing` and their mirrors,
  `Control.WellFounded.Accessible` and `WellFounded Nat LT`. NOT present:
  `lengthAppend`, `Injective Just`, `succInjective`, `Uninhabited (S n = Z)`,
  `multLteMonotoneLeft`, `multLteMonotoneRight`, a map-append equation
  (`mapAppend` is the SnocList one), `Data.List.Perm`.

Accepted duplicates, on purpose: `Refcount` restates two `Lemmas` Nat
lemmas and `TmsBridge`'s `filter_lte` because it is standalone;
`iret_11_4__just_inj` (FireLoopTms) and `lcyc_1_1__just_injective`
(Propagation) because neither imports the other and base has no
`Injective Just`.

## Readings the code encodes

| Reading | Where it lands |
|---|---|
| Well-founded is the contract, the count is libds's mechanism | `Refcount`, `TmsRanked`, `RecomputeDiff`, `RecomputeStrata`, `RecomputeFire` headers |
| Expiry is at or before the clock | `TtlSweep`, `NetworkTtl` |
| `and`/`or` absorb a trap | `Eval` |
| Refraction is the flag reading | `NetworkRefraction`, `NetworkTick`, `NetworkTtl` |
| No clause admits recursion ([LCYC.3.1.1]); the mechanism a recursive admission needs is explored, every element of it `gap__` | `Recompute*`, `Lcyc/TmsWitnesses`, `Lcyc/Witnesses` gap tags; `Lcyc/Termination` |
| [LTIM.2.5.1]: a condition that closes ends the match, a reopening is a new edge | `NetworkTick`, `Rete/EntryStamp` |
| One clocked network engine, its edge count, its two clocks | `Rete/NetworkClocked`, `Rete/NetworkEdges`, `Rete/NetworkTwoClocks`; unit N's brief |
| The compiler's fire guard ([RDSC.4a.8.2.1], [RDSC.4a.8.2.2]) is the single positive node's join test re-timed at the pump's entry, the two agreeing at every pump boundary; the edge-once set ([IRET.11.3.5]) is the `fired` flag; between two pumps the engine re-evaluates once, at the pump ([LTIM.2.4.2]'s "each pump") | `Rete/NetworkTimed` header and `ltim_2_4_3__retime_at_entry`; unit X's brief |
| The wall sample is carried in nanoseconds unmapped and moved by the wall step alone, written by the lowering only when a `where` reads `now()`; a wall clock with no value ([LTIM.2.8.3]'s third paragraph) is outside the fragment | `Rete/NetworkWall` header; unit Y's brief |
| An `after` timer carries no `fire_at` slot, its entry stamp plus the duration being `fire_at` ([LTAC.3.3] under [LTIM.2.8.6] and [LTIM.2.8.4]), so the follow-up's guard is the `dwell` gate; the parent's captured bindings ride on the timer's payload ([LTAC.3.5] by its effect, the capture fact and its correlation not modelled); the follow-up's ordinal is the one after its parent's, the compiler's terminal order; `as`, a nested clause, a `call` in a body and `every` are outside | `Rete/NetworkTimer` header; unit Z's brief |
| A service is a declaration the lowering reads, not a thing the engine holds; a call is a sweep and a record, at the call's position in the RHS and inside the per-call gate ([RLOW.7.3.8], [LCRS.8.2]); an arriving answer sweeps as the call does, before it enters ([LCRS.6.2.4], [NCBK.6.4]); the empty correlation sweeps nothing on either side ([LRST.1.2], [LCRS.6.2.4]), and a call whose activation binds no `logical` fact with a `key` slot has the empty key and one window per site ([LCRS.8.2]); a rule's emit into an answer kind is what [LCRS.4.3.4] has the compiler reject, and the lowering refuses it too (`emit:answer-kind`); the generated and computed correlations, continuations and `timeout` are outside | `Rete/NetworkCall` header; unit AA's brief |
| The two clocks: the loop samples whatever the event carries, a restored fact keeps its atom's stamp, the first sample and the atom order are recorded | `TwoClocks`, `Rete/EntryStamp`, `Rete/TtlSweep`'s docs; `formal/tla/clock_sample.tla` for the held sample, the mock clock and the checkpoint |

## Checking a change

The lane is `formal/formal.build`'s `idris.stamp`: `scripts/formal/check_idris.py`
typechecks every module under `formal/idris`, then builds `ds-formal.ipkg`
and runs its worked examples. Nothing runs locally. The fleet runs it on a
pushed commit, through dev-mcp (the whole tree as one step, with the
crossref beside it) or as the test driver's check `idris` (private
tooling); the lane's working record has the exact invocations.

- `idris2 --check Main.idr` alone reaches less than half the lane: it misses
  every leaf and most of the shelf. Check the tree, never one entry point.
- A change to `FireLoop`, `Lemmas`, `Certificate`, `Network` or
  `NetworkView` rebuilds most of the lane (about fifteen minutes); a leaf
  rebuilds in a minute or two. Idris buffers its output in the container,
  so an empty log is not a hang; a `Refl` over many engine steps can be
  (twenty firings of an accumulating program did not finish; six did).
- After any rename, move or deletion: fix every tie (`specs/**/*.json`,
  sorted by path then name) and the roles table, then the crossref
  must report 0 checks-drift, 0 misnamed, 0 untagged. `git grep -w` the
  old name across the WHOLE lane first; the review pass once deleted a
  lemma with 25 users in files outside the unit.
- The write round runs the crossref's write mode, the roles
  table, the dated verdict records and the verdict stamper as one process
  and verifies them (private tooling). Through dev-mcp it runs as a python
  debug session whose output window is its last 5,000 lines, which is why
  the diff comes out gzipped and base64-encoded with its sha256: decode,
  `git apply --index`, commit the `specs/` paths, and the pull request
  merges on the coordinator's record. A new module's record joins the
  round's list; a record owns its module's ties alone, and the generic
  table owns a clause's ties module by module.
  THE TREE IS THE ONLY COPY OF A VERDICT ONCE STAMPED: a record
  fills the ties that have no verdict and never overwrites one, its
  `--check` names the ties the tree has moved on from without failing on
  them, and a deliberate re-note is `--renote` on one record, by hand. The
  crossref's writer touches only the clause files whose `checks` moved and
  keeps a hand-formatted file's bytes outside them, so a round on a tree
  that needs nothing changes no file, and a test feeds both the inputs they
  must refuse.
- Header claims that no proof states are fidelity claims; if you change
  what a module relies on, change the header's "relies on" paragraph.
- A `Refl` witness computes only through functions whose module the file
  IMPORTS: a definition reached through another module's import is in
  scope for typing and not for unfolding. `NetworkClocked` imports
  `Rete/TmsRun` for `iret_12__lte_b` alone, because the clock's advance
  compares with it; without the import its tick witnesses were stuck on
  `if iret_12__lte_b 0 1 then 1 else 0` with every function involved
  `public export`.
- Inside a `let` block, a local definition WITH a type signature turns the
  lines after it into clauses of a definition: a pattern binding
  (`(x ** p) = …`) or a two-line signature that follows it is read as a
  pattern and refused with "Head term in pattern must be a function
  name". Give a local its type with `the (T) e` on a plain binding, or
  hoist it to a top-level lemma (`NetworkEdges`).
- A `with` branch proves the goal AS REDUCED under the pattern, and a
  lemma stated on the unreduced scrutinee is not convertible to it. Use
  `with` for lemmas whose own goal reduces to a `Refl` or a rewrite
  (`counts_clocked_cons`), and in a proof that needs a result's parts by
  name, take them from an existential instead
  (`ltim_2_8_4__triple`, `iret_11_1__select_cases`).
- Two lambdas whose bodies differ in an unused argument are not
  convertible when the body is a lifted `case`: Idris compares a case
  block's arguments, not its result. A gate that must be provably
  independent of the wall sample is written as a function of the monotonic
  sample applied to `fst sm` (`ltim_2_7_1__within_gate`), so the
  independence is `Refl`.
- A module step proves that a module typechecks and says nothing about
  its names: fifteen helpers named under a clause their tag line did not
  carry passed every module step for a day. The crossref runs on every
  change that adds or renames a tagged element, before its commit is asked
  for.
- The base's `transitive` and `reflexive` take their implicits at runtime:
  a lemma that passes an erased `{0 c : Nat}` to them fails with "c is not
  accessible in this context". Make the implicit unerased.
- A theorem over `Nat` applied at literals does not reduce against a
  literal in a type: the unifier left `mult 9 10` as a Peano term beside
  `408`. State an executed instance as closed equations by `Refl`, which
  the checker evaluates.
- A failed `Refl`'s "Mismatch between" names what the engine computed:
  read it as the model's answer before changing anything. One square
  witness failed with a tuple of its fourth word six times over, because a
  constant word is its own row and its own column and the model had found
  the second square the author had not.
- A clause-level pattern on an indexed family unifies the forced variable;
  a `case` on an `Elem` whose index is a variable in scope does not refine
  that variable. Split such evidence in a lemma's clauses, not a `case`:
  `NetworkView`'s `iret_11_3__elem_cons` is that lemma, and a new copy of
  it is a restatement.
- An impossible clause is written `... Refl ... impossible` on the
  hypothesis that is impossible, not `absurd` on another: `nth i (y0 :: ys)
  = Just y` is inhabited, `length [] = length (y0 :: ys)` is not.
- `Rarc_5_6_1__event` is `Rete/PumpBoundary`'s; a module that writes
  `Assert` or `Retract` imports it even when `Network` is imported.
- Two statements of one expensive term are spelled identically, or the
  unifier evaluates it to compare them. A four-firing run stated once
  through a named network and once as the `prepared_net` term the theorem
  takes, with a bare lambda for the TTL on one side, ran the wall clock out
  (nothing printed for 1,100 s) where
  the firings themselves take seconds each. Name the TTL, spell the
  prepared network the same way everywhere, prove it equal to its literal
  once and reach it by `replace` through that equation (257 s for the
  lane). The step-wise form of a long run, each firing a
  `Refl` from a literal state as `Lcyc/WitnessProofs` has, only helps when
  nothing restates the run.
- `minus n 0` is not `n` by computation: a goal `minus n 0 = n` is
  `minusZeroRight n`, not `Refl`.
- A `rewrite` on a record's projection does not reach the unfolding of a
  function applied to the whole record. State the lemma on the explicit
  components and chain it with `cong` and an eta lemma.
- A `let (a, b) = e in …` pattern does not reduce inside a type, so an
  executed run stated through a function that binds its result that way
  (`iret_11_4__run`) is stuck. The lane executes `iret_11_4__step_n`,
  written by pattern matching alone, for this reason; name every test,
  action and lifecycle a program literal uses so the evaluator has no
  lambda to compare.
- A module that executes FireLoop at the type level imports `Data.List`
  and `Data.Maybe`, as `Lcyc/WitnessProofs` does, or
  the evaluator stops with "Undefined name Data.Zippable.zipWith" inside
  `rarc_5_6_5__propagate`. A stuck `Refl` and a wrong one give the same
  "Can't solve constraint": read the message for an undefined name first,
  and state an executed run in closed equations step by step before the
  whole, so the failing one names the stop.
- A theorem about a function defined through `let`s is stated over an
  ABSTRACT test, never by restating the lets and rewriting the goal through
  them: the unifier unfolds the let-bound functions on symbolic arguments.
  `Rete/Eval`'s first `ldet_3_2_7__candidate_round_trips` did that over
  `round_trips` and `nearest` and the checker sat in it for thirteen minutes
  while every other element of the section elaborated in milliseconds; the
  choice is now `ldet_3_2_7__candidates_by` over any test and the search's
  step `ldet_3_2_7__shortest_step`, the two proofs are over variables, and
  the original statements are instances (Eval alone: 62 s).
  `idris2 --timing 10 --check <Module>` on the host streams the elaboration
  time of every declaration as it finishes, which is how the stuck one is
  found: the last name printed before the silence is not it; the one that
  never prints is.
- `with (e)` normalises the goal and rewrites the hypotheses in scope; a
  term built in the branch from a lemma keeps its unnormalised type. Where
  the goal mentions a function that unfolds to the scrutinee, split on a
  Bool lemma with `case` and use `trans`, `cong` and `replace` by hand.
- `rewrite h in Refl` serves a one-step unfolding; `rewrite` cannot find a
  term normalisation has dissolved. State an unfolding with the scrutinee
  on the right.
- A `with` abstracts the scrutinee only where the normalised goal shows it;
  a term stuck behind another stuck term is not shown. Keep the proof and
  `rewrite` it in after the inner `with` has opened the way.
- An inline `if` in a THEOREM STATEMENT is a lifted case block whose
  captured environment differs between the goal and a recursive call
  ("Mismatch between: d and nd"); name it as a function. Inside a
  definition the inline `if` is fine, and `replace` on an `if` motive can
  fail to unify: prefer a `with` helper.
- A with-clause repeats the parent's patterns exactly. Never restate a
  definition's `case` in a lemma type: name it and bridge with a `with` on
  the scrutinee. A `case` in a definition can block reduction at the
  unifier; define by pattern matching, matched argument first.
- Constructor patterns on indexed families force arguments: `_` for the
  forced one, never a named variable.
- `readFile` is not total: mark the reader `covering`, say why, and keep
  `%default total` in the module.
- The crossref naming rule: a name's prefix before `__` must be one of the
  element's own tags. A primed name is invisible to the crossref and its
  tag leaks onto the next element.
- `%unbound_implicits off` in every module that states a witness: without
  it a lowercase name in a type is bound as an implicit even where a global
  of that name exists, and a witness about one value becomes a claim about
  every value. Capitalise type-level names.
- An `impossible` clause is checked, not believed, and coverage is checked
  after elaboration: a module with any other error reports nothing about
  its `impossible` clauses. A witness is known good only from a run in
  which the whole module is green.
- A theorem that a thing defined as `e` is worth what `e` is worth is
  `Refl` and checks nothing. Ask of every `Refl` whether it computes or
  restates; a transcription's tie note says so.
- A zero-argument `where`-local is not unfolded by the conversion checker;
  a parameter named `all` shadows `Prelude.all`; a function another module
  must reduce is `public export`; `absurd` on `True = False` fails on an
  unreduced `with` result, so use an explicit `impossible` lemma.
- `Nat` literals are Peano at run time: `Integer` for anything executed.
  The type-level evaluator re-evaluates a derivation round per membership
  test, so a witness over more than about five facts belongs in `Main.idr`'s
  runner, not in a `Refl`.
- Two definitions of one fold (a tail-recursive accumulator and a
  pair-returning recursion) are equal by induction, not by `Refl`; the
  fold's projection on a cons IS the fold over the rest from the head's
  result, which is what a `cong` over the one-step lemma uses
  (`iret_19_5__run_clocked`).
- The coverage checker does not see through deep `Here` / `There` patterns
  over a LITERAL list when the indexed value is forced: thirteen clauses
  over a three-element list were "not covering" with thirty impossible
  cases. State the property as a Bool decided by computation and prove the
  Bool implies it by induction on a cons cell.
- A `with` on the whole-list scrutinee of a `case` inside a public
  definition abstracts the goal so that both `ended = []` and the unfolded
  definition are `Refl` in the branch; an `Either` of the two cases with
  the result NAMED, not existential, is what a later induction needs
  (`iret_12_2__phase_step_net_split`).
- Two hand-written loops of one shape are equal by induction on the fuel
  with a `with` on the shared scrutinee, then `with ... proof rr` on the
  recursive call's result matched to its tuple and `rewrite (trans IH rr)
  in Refl`: the two lifted case blocks are different functions and never
  convertible on an abstract scrutinee (the RunFold bridges).
- The unifier does not reduce a user function to identify `snd` at two
  pair types: `snd (f q) = snd (snd q)` with `f` a regrouping stays "Can't
  solve constraint", even over the constructors. A firing that names two
  things is not bridged to a fold over pairs that way; keep the hand proof
  (NetworkTraced's traced `_core`).

## Further reading

- The lane's working records are outside the public tree: the formal
  lanes' architecture; the comparison of the Idris model with libds, which
  says how `Fixture.idr` and the lowering drive the network model against
  fixtures; the start page
  that says what a Logician reads and under which rules; the review
  briefs, one per unit, each with "what it proves", "what it relies on but
  does not establish" and "tags that are naming, not meaning"; the split
  note that orders the units and carries the review checklist; and the
  record of the lane's state, its queue and the exact invocations.

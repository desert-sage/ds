% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%-----------------------------------------------------------------------------%
% ds.engine -- the pump: the pure core, run to quiescence.
%
% `pump` takes an engine and returns an engine and a list of effects; there is
% no I/O, no callback, no handle. A host's consumer of an effect has no path
% back into a pump.
%
% The integrator serialises access; nothing here spawns a thread or queues an
% input. `assert` applies immediately and `pump` runs to quiescence.
%-----------------------------------------------------------------------------%

:- module ds.engine.
:- interface.

:- import_module ds.cache.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.events.
:- import_module ds.fact.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.json.
:- import_module ds.json_text.
:- import_module ds.rfcs.
:- import_module ds.schema.
:- import_module ds.series.

:- import_module ds.tms.
:- import_module ds.wm.
:- import_module ds.value.
:- import_module bool.
:- import_module list.
:- import_module maybe.
:- import_module uint64.

%-----------------------------------------------------------------------------%

:- type engine.

    % Build an engine from a loaded artefact.
    %
:- func init_engine(program) = engine.

    % [RDSC.9.4]: the info line, category `dsc-load`, for each atom the load
    % stepped over, in encounter order. A shell delivers these at load, before
    % anything else the session does.
    %
:- func load_logs(program) = list(effect).

    % [NDBG.2.2], [LSCP.2.6.2]: the lifecycle a schema enumerates with. The
    % built-in fault schemas answer `nl_internal`; `explicit` answers
    % `nl_logical`. Not `ds.schema.lifecycle`, which is what working memory does
    % with the facts.
    %
:- type ndbg_lifecycle
    --->    nl_logical
    ;       nl_ttl
    ;       nl_internal.

:- func ndbg_2_2_lifecycle(program, schema) = ndbg_lifecycle.

    % How many firings one pump may perform: a limit, or none. With none, a
    % pump that never quiesces does not return. At the limit the pump stops,
    % reports, and leaves the survivors queued [LTIM.2.5.1].
    %
:- type fire_budget
    --->    fire_budget(int)
    ;       no_fire_limit.

:- func default_budget = fire_budget.

%-----------------------------------------------------------------------------%
% Input
%-----------------------------------------------------------------------------%

    % Assert a fact from the host. Applies and matches immediately; firing
    % happens in `pump`.
    %
:- pred host_assert(schema::in, list(ds_value)::in, maybe(instant)::in,
                    assert_result::out, list(effect)::out,
                    engine::in, engine::out) is det.

    % `host_assert` with a TTL window in place of a deadline, for `ds.replay`:
    % the deadline is the window from the assert's own sample, whatever the
    % schema's declared lifecycle. Adding the window to `engine_now` first would
    % use the last sample instead.
    %
:- pred host_assert_with_ttl(schema::in, list(ds_value)::in, duration::in,
                             assert_result::out, list(effect)::out,
                             engine::in, engine::out) is det.

    % One input that asserts several facts [RFCS.23.7]: `ds.fact_receive`.
    %
    % `input_step_begin` samples both clocks once for the input [LTIM.2.8.4] and
    % gives its tick, then what the step's [LGRA.24.3] `initial` block raised,
    % which the caller records with `lgra_24_3_after_input`. `yes(Cap)` is that
    % block refused on a cache cap: nothing of it was placed, and the caller
    % asserts nothing. Each `host_assert_in_step` is `host_assert` without its
    % own sample [LTIM.2.8.6], fault-fact drain or stamping; `input_step_end`
    % runs those once, over everything the step produced, tick first.
    %
:- pred input_step_begin(list(effect)::out, list(effect)::out,
                         maybe(cap)::out, engine::in, engine::out) is det.

    % [NLFC.9.5]: the engine's first sample, taken now, would give a held seed a
    % deadline outside the `Time` range. The call that would take it is refused
    % with `DS_ERR_TIME_RANGE`, before its step. Read off the clock source.
    % Fails after the first sample, when no entry holds a TTL.
    %
:- pred nlfc_9_5_first_sample_out_of_range(engine::in) is semidet.

    % What a delivery's plan refuses in one fact it would assert [NCBK.10.4], in
    % the order the host's door asks.
    %
:- type delivery_refusal
    --->    dr_tz_row           % [LTIM.10.9]
    ;       dr_time_range       % [RFCS.6.7]
    ;       dr_over_capacity.   % [LSTR.11.3]

    % Why this fact, as the plan holds its values, refuses the whole record.
    % Fails if it does not. `Window` is the received fact's recorded window, `no`
    % for the schema's own TTL. The deadline is judged on the clock source.
    %
    %@spec [NCBK.10.4]
:- pred ncbk_10_4_value_refused(engine::in, schema::in, list(ds_value)::in,
                                maybe(duration)::in, delivery_refusal::out)
    is semidet.

:- func lgra_24_3_after_input(list(effect), list(effect)) = list(effect).

:- pred host_assert_in_step(schema::in, list(ds_value)::in, maybe(instant)::in,
                            assert_result::out, list(effect)::out,
                            engine::in, engine::out) is det.

:- pred input_step_end(list(effect)::in, list(effect)::out,
                       engine::in, engine::out) is det.

:- pred host_retract(fact_id::in, list(effect)::out,
                     engine::in, engine::out) is det.

%-----------------------------------------------------------------------------%
% The engine's schemas
%-----------------------------------------------------------------------------%

    % The schemas the engine holds, in schema-id order. All are its artefact's
    % [NFCT.1.1].
    %
:- func engine_schemas(engine) = list(schema).

    % Advance the mock clock: the monotonic clock, and the wall clock by the same
    % duration when it is set. Not a sample [NTST.3.3]: the next input or pump
    % samples it. `Effects` holds only, when the advance succeeds,
    % `ds.clock.advance_total` [NMET.4.1]. The TTL sweep is at pump entry, so
    % working memory reports an expired fact live until the next `pump`.
    %
:- pred advance(duration::in, list(effect)::out, engine::in, engine::out)
    is det.

    % [NTST.3.1]: `advance` would be refused for a clock's range, and leave the
    % engine as it was. `advance` has no status, so a host's answer is read here.
    %
:- pred engine_advance_past_range(engine::in, duration::in) is semidet.

    % Set the mock monotonic clock to an absolute instant. Not a sample;
    % `Effects` is always `[]`. Refused below the current value once an input has
    % been consumed, and above the top of the clock's range [NTST.3.1]; a refusal
    % leaves the engine unchanged. `set_clock` has no status, so a host's answer
    % for the second is `ntst_3_1_set_past_range`'s.
    %
:- pred set_clock(instant::in, list(effect)::out, engine::in, engine::out)
    is det.

    % Set the mock wall clock to UTC nanoseconds since the Unix epoch, earlier or
    % later [NTST.3.1]. Not a sample. A live clock or a halted engine is
    % unchanged.
    %
:- pred set_wall_clock(int64::in, engine::in, engine::out) is det.

    % Return the mock wall clock to no value, for a `ClockAdvance` recorded with
    % `has_wall` false [RFCS.10.5]. Not a sample. A live clock or a halted engine
    % is unchanged.
    %
:- pred unset_wall_clock(engine::in, engine::out) is det.

    % Move a live clock's source to the reading the host took with
    % `ds.chrono.read_wall_clock`. The first reading anchors the monotonic clock
    % at its current instant; each later one moves it forward by the time
    % elapsed, never back. Not a sample. A no-op on a mock clock or a halted
    % engine.
    %
:- pred observe_wall_clock(wall_reading::in, engine::in, engine::out) is det.

%-----------------------------------------------------------------------------%
% The pump
%-----------------------------------------------------------------------------%

    % Run to quiescence, or until the budget trips.
    %
:- pred pump(fire_budget::in, list(effect)::out, engine::in, engine::out)
    is det.

%-----------------------------------------------------------------------------%
% Reading
%-----------------------------------------------------------------------------%

    % Put the clock into mock mode: the monotonic clock at 0 and the wall clock
    % unset until `set_wall_clock`. An engine from `init_engine` starts live, and
    % `advance` against a live clock does nothing. Does nothing once the engine
    % has consumed an input.
    %
:- pred engine_use_mock_clock(engine::in, engine::out) is det.

    % A replay's first recorded sample puts the clock on mock [RFCS.10.5],
    % whatever it was loaded with.
    %
:- func engine_clock_mode(engine) = clock_mode.

    % The cache bounds: live keys, then value bytes, zero unbounded for each.
    % They replace whatever the engine held, a contract's included, and bind
    % every later cache write. No recording carries them, so a replaying engine
    % is given the bound the recording one had [LDET.2.7], [NDET.8.1]. A halted
    % engine ignores this.
    %
:- pred set_cache_cap(uint32::in, uint64::in, engine::in, engine::out) is det.

    % The engine's run id and tier id, either possibly absent. Set on the fresh
    % engine; an id that is not well-formed UTF-8 answers `id_encoding` and
    % leaves the engine as it was [NLFC.1.2], [LSTR.8.5].
    %
:- type id_result
    --->    id_set
    ;       id_encoding.

:- pred set_run_id(maybe(string)::in, id_result::out, engine::in, engine::out)
    is det.
:- pred set_tier_id(maybe(string)::in, id_result::out, engine::in, engine::out)
    is det.

    % [NLFC.1.2]: an id absent, or present and well-formed UTF-8.
    %
:- pred nlfc_1_2_id_well_formed(maybe(string)::in) is semidet.
:- func run_id(engine) = maybe(string).
:- func tier_id(engine) = maybe(string).

    % [RFCS.4]'s session header: the DS version this runtime is [LDET.1.10], the
    % loaded artefact's `dsc_sha256` [RFCS.4.5], and the run id and tier id, ""
    % for one not given [RFCS.4.3], [RFCS.4.4]. A recording's `StreamHeader` is
    % this value.
    %
:- func session_header(engine) = stream_meta.

:- func default_hydration_budget = int.

    % What `seed_cache` did. Each refusal leaves the engine unchanged and writes
    % nothing to the stream.
    %
:- type seed_result
    --->    seeded
    ;       seed_after_pump
            % Past the setup window: `DS_ERR_STATE`. For a host seed that is the
            % engine's first stream event [NLFC.9.1]; for the `initial:` block's
            % items, the first pump.
    ;       seed_halted(engine_error)
            % [NCBK.2.9].
    ;       seed_nonfinite
            % `DS_ERR_JSON_NONFINITE`.
    ;       seed_json_limit(json_breach)
            % [LGRA.5.8.6]: `DS_ERR_JSON_LIMIT`.
    ;       seed_capped(cap)
            % [RTCT.7]: `DS_ERR_CONTRACT_BREACH`.
    ;       seed_text_refused(json_refusal)
            % `seed_cache_text` only: the text is not one JSON value, for a
            % reason that is not a limit.
    ;       seed_encoding
            % [LSTR.8.5]: a host's key, the text it handed `seed_cache_text`, or
            % a string or key in its value is not well-formed UTF-8:
            % `DS_ERR_ENCODING`. A replayed seed is not asked [RDSC.9.9].
    ;       seed_time_range.
            % [NLFC.9.5]: a host seed's TTL is longer than 2^63 - 1 ns:
            % `DS_ERR_TIME_RANGE`.

    % Restore one cache entry before the run [NSTG.9.1], [IARC.12.1]. An upsert;
    % `no` TTL is no expiry. Setup only, before the engine's first stream event
    % [NLFC.9.1], [NFCT.1.1]. No effect and no event; the value is stored and
    % counted against the caps as a rule's write is.
    %
:- pred seed_cache(string::in, json::in, maybe(duration)::in, seed_result::out,
                   engine::in, engine::out) is det.

    % `seed_cache`, handed the value's JSON text. The parse, under [LGRA.5.8.6]'s
    % limits, comes before the engine's state is asked.
    %
:- pred seed_cache_text(string::in, string::in, maybe(duration)::in,
                        seed_result::out, engine::in, engine::out) is det.

    % [RFCS.26.2]: a recorded `CacheSeed` applied as a host seed, with the
    % deadline the recorded cache held, in engine-clock ns, 0 for none, in place
    % of a TTL. Anything but `seeded` is the replayer's to report as a divergence.
    %
:- pred replay_seed_cache(string::in, string::in, uint64::in, seed_result::out,
                          engine::in, engine::out) is det.

    % [RFCS.26.1]: every entry the cache held at the engine's first stream event,
    % `[]` before that event, in the cache's key order.
    %
:- func prelude_seeds(engine) = list(cache_seed).

    % Intern a string into the engine's table, which a host needs to build a
    % `String` slot value.
    %
:- pred engine_intern(string::in, intern_ref::out, engine::in, engine::out)
    is det.

:- func engine_wm(engine) = wm.

:- func engine_refraction_size(engine) = int.

    % One entry of [NDBG.4.3]'s refracted listing.
    %
:- type refracted_activation
    --->    refracted_activation(
                ra_rule   :: string,
                ra_reason :: string,
                ra_detail :: string,
                ra_facts  :: list(fact_id)
                            % The author's facts the match bound, in token order.
            ).

    % [NDBG.4.3]: every entry of the terminals' refraction sets [IRET.11.3],
    % optionally for one rule: terminals in ordinal order [LDET.5.4], then
    % entries ascending by their listed fact-id tuple, which leaves out
    % compiler-synthesised facts.
    %
:- func engine_refracted_activations(engine, maybe(string))
    = list(refracted_activation).

    % One row of [NDBG.4.2]'s match trace.
    %
:- type trace_step
    --->    trace_step(
                ts_node   :: string,
                            % The decimal text of the alpha node's artefact
                            % `node_id` [NDBG.4.1].
                ts_kind   :: string,
                            % "alpha": the trace reports alpha nodes only.
                ts_result :: string,
                            % "passed" or "filtered".
                ts_detail :: string
            ).

    % [NDBG.4.2]: a live fact's path through the alpha nodes that dispatch on its
    % schema, in dispatch order. `[]` for an id no live fact carries, and for a
    % compiler-synthesised fact.
    %
:- func engine_rete_match_trace(engine, fact_id) = list(trace_step).

    % Rebuilds a `rete_state` by replaying every live fact in fact-id order,
    % against the series the last pump matched against [LSER.8.6.1], and compares
    % its fact tuples with the incrementally maintained state. Returns one string
    % per beta node whose memories differ.
    %
:- pred audit_match_paths(engine::in, list(string)::out) is det.

    % The fact count an integrator sees: working memory less the
    % compiler-synthesised facts. `live_count` is the raw size.
    %
:- func engine_fact_count(engine) = int.
:- func engine_tms(engine) = tms.

    % How many events the engine has emitted: the `seq` its next one takes
    % [LFST.5.3].
    %
:- func engine_event_count(engine) = uint64.

    % The series state, for a test's read of an aggregation outside any rule.
    %
:- func engine_series(engine) = series_state.

    % The engine-owned cache: an entry holds the Json text a rule's write or a
    % seed stored, as a `str` in `engine_interns`.
    %
:- func engine_cache(engine) = cache.
:- func pending_activations(engine) = int.

    % The monotonic clock's held sample: what the engine's last input or pump
    % read [LTIM.2.8.4], and what every read inside the engine returns.
    %
:- func engine_now(engine) = instant.

    % The monotonic clock's source: what it would read now. Not a sample; between
    % a mutation and the next step it differs from `engine_now`.
    %
:- func engine_clock_now(engine) = instant.

    % [NLFC.2.5]: the earliest deadline later than the clock's source, or `no`. It
    % scans every live fact and cache entry: nothing holds a timer's `fire_at`,
    % and `ds.wm`'s queue keeps entries for facts that have left.
    %
:- func nlfc_2_5_next_deadline(engine) = maybe(instant).

    % The wall clock's source: UTC nanoseconds since the Unix epoch, or `no` while
    % it has no value. Not a sample. A host stamps a `ts` it supplies from this
    % [LFAC.9.2], after its last `observe_wall_clock` and before the input it
    % stamps.
    %
:- func engine_wall_clock_now(engine) = maybe(int64).

    % The engine's current intern table. `interns(program)` holds only what the
    % artefact interned at load; runtime strings intern here.
    %
:- func engine_interns(engine) = intern_table.

    % [NDBG.2.1]: `ds_engine_mem_t`'s fields, in its order. Logical counts are
    % exact, `wm_fact_count` including synthetic facts. The intern fields are this
    % runtime's own table. The other byte fields are 0, since they measure C
    % layouts, and `total_bytes` is `intern_string_bytes`.
    %
:- type engine_mem
    --->    engine_mem(
                em_wm_fact_count       :: int,
                em_wm_fact_bytes       :: int,
                em_wm_index_bytes      :: int,
                em_alpha_node_count    :: int,
                em_alpha_match_count   :: int,
                em_alpha_index_bytes   :: int,
                em_beta_node_count     :: int,
                em_beta_token_count    :: int,
                em_beta_token_bytes    :: int,
                em_beta_index_bytes    :: int,
                em_intern_count        :: int,
                em_intern_string_bytes :: int,
                em_intern_index_bytes  :: int,
                em_pool_reserved_bytes :: int,
                em_total_bytes         :: int
            ).

:- func engine_mem(engine) = engine_mem.

    % The halt latch: the error that halted the tier, or `no` [LERR.1],
    % [NCBK.2.9]. Every entry point is then a no-op that emits nothing, and the
    % latch never clears. This is how a host tells an empty pump from quiescence.
    %
    % The reads above stay total, and what they answer after the halt is
    % undefined [LERR.1.4.7]. `mercury_ds.session` refuses each with `halted`.
    %
:- func engine_halted(engine) = maybe(engine_error).

    % [NFCT.1.4.6]: a host's number through the conversion of a slot that
    % names a unit ([RDSC.5.5.9]). `ud_to_stored` takes a number in the unit
    % the slot names to its stored number; `ud_from_stored` takes the stored
    % number back. The outcome is the first that holds, in the clause's order.
    % A halt before the call is the caller's to refuse, as it is every other
    % read's. Nothing in the engine changes, save for an EngineError the
    % conversion raises: the engine halts, and the effects are its event.
    %
:- type unit_direction
    --->    ud_to_stored
    ;       ud_from_stored.

:- type unit_outcome
    --->    uo_ok(ds_value)
    ;       uo_no_slot              % DS_ERR_NOT_FOUND
    ;       uo_no_unit              % DS_ERR_INVAL
    ;       uo_kind_mismatch        % DS_ERR_SLOT_TYPE_MISMATCH
    ;       uo_nan                  % DS_ERR_NAN_REJECTED
    ;       uo_halted               % DS_ERR_ENGINE_HALTED: the conversion
                                    % raised an EngineError
    ;       uo_not_representable.   % DS_ERR_NOT_REPRESENTABLE

:- pred nfct_1_4_6_convert(schema::in, int::in, unit_direction::in,
    ds_value::in, unit_outcome::out, list(effect)::out,
    engine::in, engine::out) is det.

%-----------------------------------------------------------------------------%
:- implementation.
:- import_module ds.binding.
:- import_module ds.contract.
:- import_module ds.version.
:- import_module uint8.

:- import_module ds.action.
:- import_module ds.agenda.
:- import_module ds.atom.
:- import_module ds.effect.
:- import_module ds.event_kind.
:- import_module ds.eval.
:- import_module ds.exec.
:- import_module ds.expr.
:- import_module ds.float_text.
:- import_module char.
:- import_module float.
:- import_module ds.match.
:- import_module ds.network.
:- import_module ds.format.
:- import_module require.
:- import_module array.
:- import_module string.
:- import_module uint32.
:- import_module int64.
:- import_module ds.rate.
:- import_module ds.rules.
:- import_module ds.token.
:- import_module assoc_list.
:- import_module require.
:- import_module int.
:- import_module pair.
:- import_module map.
:- import_module set.

%-----------------------------------------------------------------------------%

:- type engine
    --->    engine(
                en_index   :: net_index,
                en_schemas :: map(uint32, schema),
                en_metas   :: map(uint32, rule_meta),
                en_actions :: map(uint32, list(action)),
                en_frames  :: map(uint32, int),
                            % Each terminal's `bind_count`, by raw node id: the size
                            % of its firing's bind frame [RDSC.4a.9.6].
                en_interns :: intern_table,

                en_wm      :: wm,
                en_tms     :: tms,
                en_cache   :: cache,
                en_rate    :: rate_table,
                            % Cooldown windows, per (rule, key); not persisted
                            % [LCDB.7.3].

                en_rete    :: rete_state,
                en_agenda  :: agenda,
                en_refract :: refraction,
                en_clock   :: clock,
                en_series  :: series_state,
                en_sdecls  :: list(series_decl),
                en_absorbed :: set(uint64),
                            % The live facts the series sweep has already
                            % walked, by raw `fact_id`. See `absorb_series`.
                en_matched :: series_state,
                            % The series as the last pump's rules read them
                            % [LSER.8.6.1], before `absorb_series`. Read by
                            % `audit_match_paths` alone.

                en_contract :: maybe(contract),
                            % [RTCT.6.6]; `no` on an ordinary bundle.

                en_cache_caps :: cache_caps,
                            % The contract's at load, then whatever
                            % `set_cache_cap` last gave.

                en_hydration_budget :: int,
                            % [LHYD.7.4]: the effective value.

                en_run_id  :: maybe(string),
                en_tier_id :: maybe(string),

                en_binding :: dialect_binding,
                            % [RBND.1.3], from the artefact's header [RBND.3.1].

                en_synth   :: set(uint64),
                            % Live facts of a compiler-synthesised schema, by raw
                            % `fact_id` (`ds.schema.synthetic`): in working
                            % memory, but filtered from what leaves it. Ids,
                            % because a retract event carries only the id.

                en_tick    :: maybe(fact_id),
                            % The current `$ClockTick` fact, if the program
                            % declares that schema. Cycled at pump entry.

                en_seeded  :: bool,
                            % Whether `seed_roots` has run, at the first pump, so
                            % a root NOT node counts a fact asserted before it.
                            % Only negative roots are seeded [IRET.7.9.1]: a
                            % positive one's token is what `left_input` supplies.

                en_gensym  :: int,
                            % The next `FN_GENSYM` number [IARC.11.3], threaded
                            % through each firing by `ds.exec`.

                en_halted  :: maybe(engine_error),
                            % The first error whose `ds.fault.disposition` is
                            % `latched`, raised where a fact change raises it
                            % (`lerr_1_4_7_raise`) or as the step's effects are
                            % scanned. Never cleared [LERR.1.4.7].

                en_fault_handlers :: set(uint32),
                            % [LERR.9.6]: every node a fault handler's patterns
                            % use, and every handler's terminal, by raw node id.
                            % A fault raised at one is recorded and never asserted
                            % as a fault fact.

                en_fault_latch :: map(fault_site_key, fact_id),
                            % [LERR.9.5]: the live fault fact of each site. An
                            % entry whose fact a handler withdrew stays; the drain
                            % finds the id no longer live.

                en_fault_schemas :: list(schema_id),
                            % The two fault schemas' ids [LERR.9.4]. Their facts
                            % never count against `wm_max` [LERR.9.10].

                en_events  :: uint64,
                            % Stream events handed to a host, all steps together:
                            % the next one's seq.

                en_act_attach :: map(uint64, list(fact_id)),
                            % `scope activation` facts waiting on a token fact,
                            % by the token's raw id, retracted when it is
                            % discharged [LSCP.3.1].

                en_responses :: list(schema),
                            % [LCRS.6.2.4]: the schemas a `service` answers with,
                            % once each in schema-id order. A host assert of one,
                            % or of a `CallError`, supersedes the live answers
                            % with its `corr` (`host_supersede`).

                en_service_responses :: map(string, string),
                            % [LCRS.6.2.1]: each service's response schema, `""`
                            % for `no response`. Read by `ds.exec`'s
                            % `lcrs_6_2_1_call_supersede`.

                en_initial :: list(initial_item),
                            % [LGRA.24.3]: pending until the engine's first step
                            % (`clock_step`), `[]` once applied.

                en_prelude_seeds :: list(cache_seed)
                            % [RFCS.26.1]: the cache as the engine's first stream
                            % event found it, `[]` until then.
            ).

    % A fault-fact site [LERR.9.5]: which of the two schemas (`yes` for
    % `TypeError`), the node, and the rule name's text, since a site is the same
    % whichever table interned it.
    %
:- type fault_site_key == {bool, uint32, string}.

init_engine(P) = engine(
        build_index(network(P), schemas(P)),
        list.foldl(by_schema_id, schemas(P), map.init),
        list.foldl(by_terminal, rule_metas(P), map.init),
        list.foldl(by_term_id, action_lists(P), map.init),
        list.foldl(by_term_frame, terminal_nodes(network(P)), map.init),
        interns(P),
        init_wm_for(synthetic_schema_ids(P), ltim_10_6_tz_schema(P)),
        init_tms, init_cache, init_rate_table, init_rete, init_agenda,
        init_refraction, init_clock(from_ns(0u64)),
        init_series_state, series_decls(P), set.init, init_series_state,
        expanded_contract(P), contract_cache_caps(expanded_contract(P)),
        default_hydration_budget, no, no,
        dialect_binding(header(P) ^ dh_sha256, header(P) ^ dh_capabilities,
            header(P) ^ dh_dialect_sha),
        set.init, no, no, 0, no,
        lerr_9_6_handler_sites(network(P), interns(P)), map.init,
        fault_schema_ids(schemas(P), interns(P)), 0u64, map.init,
        response_schemas_of(P),
        list.foldl(
            ( func(Service, M) = map.set(M, fst(Service), snd(Service)) ),
            service_responses(P), map.init),
            % Of two `ServiceDef`s for one service, the later wins.
        initial_items(P),
        []).

load_logs(P) = list.map(rdsc_9_4_skip_log, skips(P)).

    %@spec [RDSC.9.4]
    %@spec [RDSC.4c.3]
:- func rdsc_9_4_skip_log(skip) = effect.

rdsc_9_4_skip_log(skip_named(A, Offset)) =
    eff_host_log(log_info, "dsc-load",
        "skipping atom " ++ string.uint32_to_string(atom_field(A))
        ++ " (" ++ atom_message(A) ++ ") at byte offset "
        ++ string.int_to_string(Offset)
        ++ ( if A = at_doc_string then
                ": tooling metadata (RDSC.14.4.4)"
            else
                ": this loader does not read it (RDSC.9.4)"
            )).
rdsc_9_4_skip_log(skip_code(Offset)) =
    eff_host_log(log_info, "dsc-load",
        "skipping atom "
        ++ string.uint32_to_string(atom_field(at_compiled_code))
        ++ " (" ++ atom_message(at_compiled_code) ++ ") at byte offset "
        ++ string.int_to_string(Offset)
        ++ ": this edition runs no compiled code (RDSC.4c.3)").

    % Apply the `initial` items under the first step's sample, in
    % `ds.dsc.initial_items`' order. `clock_step` calls this after its sample.
    %
    % A fact asserts as an input with no `ts`, inside the step, with its effects
    % dropped: no event, no `seq`. `ts` is the step's wall sample [LFAC.9.2]. With
    % no wall value it is a DOMAIN fault and the fact is not placed [LTIM.2.8.3];
    % `Raised` holds that event, which the caller records after the input.
    %
    % A seed is the host's seed [NLFC.9.1], except:
    %   * a key in `Host`, the cache as the step began, keeps the host's value
    %     [NLFC.9.3], while an importer's item still overwrites its library's;
    %   * a refusal on `cache_cap` or `cache_bytes_cap` puts the engine back to
    %     `E0`, the block pending again, and `Outcome` carries the cap and bound.
    %
    % An item that does not fit the program is dropped [RDSC.9.9]: a fact naming
    % an unknown schema, a `json(...)` text that does not parse, or literals the
    % assert refuses for their slots.
    %
    %@spec [LGRA.24.3]
    %@spec [NLFC.9.3]
    %@spec [LTIM.2.8.3]
:- pred lgra_24_3_apply(list(initial_item)::in, initial_outcome::out,
                        list(effect)::out, engine::in, engine::out) is det.

lgra_24_3_apply(Items, Outcome, Raised, !E) :-
    E0 = !.E,
    Host = !.E ^ en_cache,
    !E ^ en_initial := [],
    lgra_24_3_items(Host, Items, Refused, [], RevRaised, !E),
    (
        Refused = no,
        Outcome = initial_applied,
        Raised = list.reverse(RevRaised)
    ;
        Refused = yes({Cap, Bound}),
        !:E = E0,
        Outcome = initial_refused(Cap, no_site ^ fs_bound := Bound),
        Raised = []
    ).

:- pred lgra_24_3_items(cache::in, list(initial_item)::in,
                        maybe({cap, maybe(fault_bound)})::out,
                        list(effect)::in, list(effect)::out,
                        engine::in, engine::out) is det.

lgra_24_3_items(_, [], no, !RevRaised, !E).
lgra_24_3_items(Host, [Item | Items], Refused, !RevRaised, !E) :-
    lgra_24_3_item(Host, Item, Refused0, !RevRaised, !E),
    (
        Refused0 = yes(_),
        Refused = Refused0
    ;
        Refused0 = no,
        lgra_24_3_items(Host, Items, Refused, !RevRaised, !E)
    ).

:- pred lgra_24_3_item(cache::in, initial_item::in,
                       maybe({cap, maybe(fault_bound)})::out,
                       list(effect)::in, list(effect)::out,
                       engine::in, engine::out) is det.

lgra_24_3_item(_, initial_fact(_, Name, Slots, _), no, !RevRaised, !E) :-
    ( if schema_named(!.E, Name, Schema) then
        ( if ltim_2_8_3_unset_wall_ts(!.E, Schema) then
            !:RevRaised = [eff_event(se_engine_error(ee_expr_fault(rf_domain),
                no_site)) | !.RevRaised]
        else if
            % Only the literals the schema's slots take, the first per name.
            all [C, L] (
                (
                    list.member(C, slot_commons(Schema)),
                    expand(!.E ^ en_interns, C ^ sc_name, SlotName),
                    assoc_list.search(Slots, SlotName, L)
                )
            =>
                literal_parses(L)
            )
        then
            list.map_foldl(initial_slot_value(Slots), slot_commons(Schema),
                Values, !E),
            host_assert_core(no, Schema, Values, ov_deadline(no), _, _, !E)
        else
            true
        )
    else
        true
    ).
lgra_24_3_item(Host, initial_seed(_, Key, Literal, _), Refused, !RevRaised,
        !E) :-
    ( if cache_get(Host, Key, _) then
        Refused = no
    else if not literal_parses(Literal) then
        Refused = no
    else
        seed_cache_bounded(Key, initial_json(Literal), seed_ttl(no), Result,
            Bound, !E),
        ( if Result = seed_capped(Cap) then
            Refused = yes({Cap, Bound})
        else
            % `seed_nonfinite` and `seed_json_limit` drop the item. No other
            % refusal can reach an item.
            Refused = no
        )
    ).

    % [LTIM.2.8.3]: the schema declares `ts`, which an item never gives, and the
    % wall clock has no value to fill it with.
    %
:- pred ltim_2_8_3_unset_wall_ts(engine::in, schema::in) is semidet.

ltim_2_8_3_unset_wall_ts(E, Schema) :-
    clock_wall(E ^ en_clock) = no,
    list.find_first_match(
        ( pred(C::in) is semidet :- expand(E ^ en_interns, C ^ sc_name, "ts") ),
        slot_commons(Schema), _).

    % A literal this runtime can make a value of: every one but a `json(...)`
    % text that does not parse.
    %
:- pred literal_parses(test_value::in) is semidet.

literal_parses(L) :-
    ( if L = tv_json(Text) then
        ds.json_text.parse(Text, parsed(_))
    else
        true
    ).

    % One slot's value: the literal its item gives it; for `ts`, the step's wall
    % sample [LFAC.9.2]; `null` for any other slot the item omits, which the
    % assert refuses in a non-nullable slot.
    %
:- pred initial_slot_value(assoc_list(string, test_value)::in,
                           slot_common::in, ds_value::out,
                           engine::in, engine::out) is det.

initial_slot_value(Slots, C, Value, !E) :-
    ( if
        expand(!.E ^ en_interns, C ^ sc_name, Name),
        assoc_list.search(Slots, Name, Literal)
    then
        literal_value(Literal, Value, !E)
    else if
        expand(!.E ^ en_interns, C ^ sc_name, "ts"),
        clock_wall(!.E ^ en_clock) = yes(Wall)
    then
        Value = int(Wall)
    else
        Value = null
    ).

    % A literal as a slot value, a duration as its INT representation
    % [RDSC.5.5.8]. The assert refuses a kind the slot does not take.
    %
:- pred literal_value(test_value::in, ds_value::out,
                      engine::in, engine::out) is det.

literal_value(tv_int(I), int(I), !E).
literal_value(tv_float(F), float(F), !E).
literal_value(tv_string(S), str(Ref), !E) :-
    engine_intern(S, Ref, !E).
literal_value(tv_bool(B), bool(B), !E).
literal_value(tv_duration(Ns), int(int64.cast_from_uint64(Ns)), !E).
literal_value(tv_json(Text), json(initial_json(tv_json(Text))), !E).

    % A literal as the JSON a cache seed stores; a `Duration` is its nanoseconds.
    %
:- func initial_json(test_value) = json.

initial_json(tv_int(I)) = j_int(I).
initial_json(tv_float(F)) = j_float(F).
initial_json(tv_string(S)) = j_string(S).
initial_json(tv_bool(B)) = j_bool(B).
initial_json(tv_duration(Ns)) = j_int(int64.cast_from_uint64(Ns)).
initial_json(tv_json(Text)) = J :-
    ds.json_text.parse(Text, Parsed),
    (
        Parsed = parsed(J)
    ;
        Parsed = refused(_),
        unexpected($pred, "a block's `json(...)` text that does not parse "
            ++ "reached initial_json")
    ).

    % [LCRS.6.2.4]: the program's schemas some `ServiceDef` names as its
    % `response`, in schema-id order, each once.
    %
:- func response_schemas_of(program) = list(schema).

response_schemas_of(P) = list.filter(
    ( pred(S::in) is semidet :-
        expand(interns(P), schema_name_ref(S ^ s_name), Name),
        list.member(Name, response_schemas(P))
    ), map.values(list.foldl(by_schema_id, schemas(P), map.init))).

    % The ids of the program's two fault schemas, by name [LERR.9.4]; none on a
    % hand-built test network.
    %
:- func fault_schema_ids(list(schema), intern_table) = list(schema_id).

fault_schema_ids(Schemas, IT) = list.filter_map(
    ( func(S) = S ^ s_id is semidet :-
        expand(IT, schema_name_ref(S ^ s_name), Name),
        lerr_9_4_fault_schema_name(Name)
    ), Schemas).

ndbg_2_2_lifecycle(P, S) = Lifecycle :-
    ( if
        expand(interns(P), schema_name_ref(S ^ s_name), Name),
        lerr_9_4_fault_schema_name(Name)
    then
        Lifecycle = nl_internal
    else
        Lc = S ^ s_lifecycle,
        (
            Lc = lc_ttl(_, _),
            Lifecycle = nl_ttl
        ;
            Lc = lc_logical(_, _),
            Lifecycle = nl_logical
        ;
            Lc = lc_explicit(_),
            Lifecycle = nl_logical
        ;
            % [RDSC.5.4.5]: a SchemaLogical schema, as `explicit` is.
            Lc = lc_activation(_),
            Lifecycle = nl_logical
        )
    ).

    % The contract stored expanded, so no cap check meets [RTCT.6.7]'s two node
    % encodings.
    %
:- func expanded_contract(program) = maybe(contract).

expanded_contract(P) =
    ( if contract_of(P) = yes(C) then
        yes(expanded(network(P), C))
    else
        no
    ).

    % `DS_RETE_HYDRATION_BUDGET_DEFAULT`.
    %
default_hydration_budget = 100000.

    % For working memory's separate id range (`ds.wm.init_wm_for`).
    %
:- func synthetic_schema_ids(program) = list(schema_id).

synthetic_schema_ids(P) = list.filter_map(
    ( func(S) = Id is semidet :-
        synthetic(interns(P), S),
        Id = S ^ s_id ),
    schemas(P)).

    % The built-in `TimeZoneOffset`, whose facts are working memory's zone index
    % (`ds.wm.ltim_10_7_offset`). The four slots keep a hand-built schema of
    % another shape from being read as zone rows.
    %
    %@spec [LTIM.10.6]
:- func ltim_10_6_tz_schema(program) = maybe(schema_id).

ltim_10_6_tz_schema(P) =
    ( if
        list.find_first_match(
            ( pred(S::in) is semidet :-
                expand(interns(P), schema_name_ref(S ^ s_name), Name),
                Name = "TimeZoneOffset",
                list.length(slot_commons(S)) = 4
            ), schemas(P), Tz)
    then
        yes(Tz ^ s_id)
    else
        no
    ).

seed_cache(Key, Value, Ttl, Result, !E) :-
    host_seed(Key, Value, seed_ttl(Ttl), Result, !E).

    % A host's seed, its TTL given or, replayed, its deadline: the window, then
    % `seed_cache_bounded`. A halted engine answers `seed_halted` first.
    %
:- pred host_seed(string::in, json::in, seed_expiry::in, seed_result::out,
                  engine::in, engine::out) is det.

host_seed(Key, Value, Expiry, Result, !E) :-
    ( if
        !.E ^ en_halted = no,
        engine_event_count(!.E) \= 0u64
    then
        Result = seed_after_pump
    else if
        !.E ^ en_halted = no,
        Expiry = seed_ttl(yes(Ttl)),
        duration_ns(Ttl) > uint64.cast_from_int64(int64.max_int64)
    then
        % [NLFC.9.5]: a TTL no `Time` can hold has no deadline at any sample.
        Result = seed_time_range
    else if
        !.E ^ en_halted = no,
        !.E ^ en_seeded = no,
        limit_breach(Value) = no,
        Expiry = seed_ttl(_),
        ( not utf8_well_formed(Key)
        ; not lstr_8_5_well_formed(Value)
        )
    then
        % [LSTR.8.5]: after the halt, the window and the Json limits.
        Result = seed_encoding
    else
        seed_cache_bounded(Key, Value, Expiry, Result, _, !E)
    ).

seed_cache_text(Key, Text, Ttl, Result, !E) :-
    seed_text(Key, Text, seed_ttl(Ttl), Result, !E).

replay_seed_cache(Key, Text, DeadlineNs, Result, !E) :-
    ( if DeadlineNs = 0u64 then
        Expires = no
    else
        Expires = yes(from_ns(DeadlineNs))
    ),
    seed_text(Key, Text, seed_deadline(Expires), Result, !E).

:- pred seed_text(string::in, string::in, seed_expiry::in, seed_result::out,
                  engine::in, engine::out) is det.

seed_text(Key, Text, Expiry, Result, !E) :-
    ( if
        % [LSTR.8.5]: after the text limit, before the parse. A replayed seed's
        % text is trusted [RDSC.9.9].
        Expiry = seed_ttl(_),
        string.count_utf8_code_units(Text) =< ds.json.max_text_bytes,
        not utf8_well_formed(Text)
    then
        Result = seed_encoding
    else
        seed_text_parsed(Key, Text, Expiry, Result, !E)
    ).

:- pred seed_text_parsed(string::in, string::in, seed_expiry::in,
                         seed_result::out, engine::in, engine::out) is det.

seed_text_parsed(Key, Text, Expiry, Result, !E) :-
    ds.json_text.parse(Text, Parsed),
    (
        Parsed = parsed(Value),
        host_seed(Key, Value, Expiry, Result, !E)
    ;
        Parsed = refused(Why),
        ( if Why = jr_limit(Limit) then
            % A tree limit reports one past its bound: the parser stops there.
            ( if Limit = jl_text_bytes then
                Observed = string.count_utf8_code_units(Text)
            else
                Observed = json_limit_max(Limit) + 1
            ),
            Result = seed_json_limit(json_breach(Limit, json_limit_max(Limit),
                Observed))
        else
            Result = seed_text_refused(Why)
        )
    ).

:- func json_limit_max(json_limit) = int.

json_limit_max(jl_depth) = ds.json.max_depth.
json_limit_max(jl_nodes) = ds.json.max_nodes.
json_limit_max(jl_string_bytes) = ds.json.max_string_bytes.
json_limit_max(jl_text_bytes) = ds.json.max_text_bytes.

    % `seed_cache`, and on `seed_capped` the cap's limit and the size the refused
    % write would have reached. [LGRA.24.3]'s refused step records it; a host
    % seed records nothing.
    %
:- pred seed_cache_bounded(string::in, json::in, seed_expiry::in,
    seed_result::out, maybe(fault_bound)::out, engine::in, engine::out) is det.

:- type seed_expiry
    --->    seed_ttl(maybe(duration))
            % A host's seed or an `initial` item: a TTL from the engine clock.
    ;       seed_deadline(maybe(instant)).
            % A replayed `CacheSeed`: the recorded deadline [RFCS.26.2].

seed_cache_bounded(Key, Value, Expiry, Result, Bound, !E) :-
    ( if !.E ^ en_halted = yes(Err) then
        Result = seed_halted(Err),
        Bound = no
    else if !.E ^ en_seeded = yes then
        Result = seed_after_pump,
        Bound = no
    else if limit_breach(Value) = yes(Breach) then
        % Before `json_text`, whose recursion the depth limit bounds.
        Result = seed_json_limit(Breach),
        Bound = no
    else if json_text(unsigned_zeros(Value), Text) then
        % [LGRA.5.8.8]: this `Json` value's float zeros lose their sign here.
        %
        % `E1` is kept only if no cap refuses it, so a refused seed leaves no
        % interned text.
        engine_intern(Text, Ref, !.E, E1),
        Bytes = string.count_utf8_code_units(Text),
        Clock = E1 ^ en_clock,
        % [NLFC.9.4]: before the first sample a TTL is held as a duration, and
        % `clock_step`'s first sample fixes the deadline.
        (
            Expiry = seed_deadline(Deadline),
            cache_put(Key, str(Ref), Bytes, Deadline, E1 ^ en_cache, Cache)
        ;
            Expiry = seed_ttl(Ttl),
            ( if
                Ttl = yes(D),
                not clock_sampled(Clock)
            then
                cache_put_held(Key, str(Ref), Bytes, D, E1 ^ en_cache, Cache)
            else
                Now = clock_now(Clock),
                Expires = maybe.map_maybe(
                    (func(D1) = ds.chrono.add(Now, D1)), Ttl),
                cache_put(Key, str(Ref), Bytes, Expires, E1 ^ en_cache, Cache)
            )
        ),
        Caps = E1 ^ en_cache_caps,
        ( if
            cache_capped(Caps, E1 ^ en_cache, Cache, Cap)
        then
            Result = seed_capped(Cap),
            ( if Cap = cap_cache then
                Bound = yes(fault_bound(uint32.cast_to_uint64(Caps ^ cc_keys),
                    uint64.det_from_int(cache_size(Cache))))
            else
                Bound = yes(fault_bound(Caps ^ cc_bytes,
                    uint64.det_from_int(cache_bytes(Cache))))
            )
        else
            !:E = E1 ^ en_cache := Cache,
            Result = seeded,
            Bound = no
        )
    else
        Result = seed_nonfinite,
        Bound = no
    ).

set_cache_cap(Keys, Bytes, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        true
    else
        !E ^ en_cache_caps := cache_caps(Keys, Bytes)
    ).

    % An empty string is absent [NLFC.1.2].
    %
set_run_id(Id, Result, !E) :-
    ( if nlfc_1_2_id_well_formed(Id) then
        !E ^ en_run_id := nlfc_1_2_given(Id),
        Result = id_set
    else
        Result = id_encoding
    ).

set_tier_id(Id, Result, !E) :-
    ( if nlfc_1_2_id_well_formed(Id) then
        !E ^ en_tier_id := nlfc_1_2_given(Id),
        Result = id_set
    else
        Result = id_encoding
    ).

%@spec [NLFC.1.2]
nlfc_1_2_id_well_formed(no).
nlfc_1_2_id_well_formed(yes(S)) :-
    utf8_well_formed(S).

%@spec [NLFC.1.2]
:- func nlfc_1_2_given(maybe(string)) = maybe(string).

nlfc_1_2_given(no) = no.
nlfc_1_2_given(yes(S)) = ( if S = "" then no else yes(S) ).

run_id(E) = E ^ en_run_id.

tier_id(E) = E ^ en_tier_id.

session_header(E) = stream_meta(ds.version.ds_version,
    E ^ en_binding ^ db_dsc_sha, E ^ en_binding ^ db_capabilities,
    E ^ en_binding ^ db_def_sha,
    maybe.maybe_default("", E ^ en_run_id),
    maybe.maybe_default("", E ^ en_tier_id)).

:- func by_schema_id(schema, map(uint32, schema)) = map(uint32, schema).

by_schema_id(S, M) = map.set(M, schema_id_value(S ^ s_id), S).

:- func by_terminal(rule_meta, map(uint32, rule_meta)) =
    map(uint32, rule_meta).

by_terminal(Meta, M) = map.set(M, node_id_value(Meta ^ rm_terminal), Meta).

:- func by_term_id(pair(node_id, list(action)),
                   map(uint32, list(action))) = map(uint32, list(action)).

by_term_id(Term - Actions, M) = map.set(M, node_id_value(Term), Actions).

:- func by_term_frame(terminal_node, map(uint32, int)) = map(uint32, int).

by_term_frame(T, M) = map.set(M, node_id_value(T ^ tn_id), T ^ tn_binds).

    % The size of an activation's bind frame: its terminal's `bind_count`.
    %
:- func frame_of(engine, activation) = int.

frame_of(E, Activation) =
    ( if map.search(E ^ en_frames, node_id_value(Activation ^ ac_terminal), N)
    then N
    else 0 ).

default_budget = no_fire_limit.

%-----------------------------------------------------------------------------%
% Input
%-----------------------------------------------------------------------------%

    % [LGRA.24.3]: what the step's application of a pending `initial` block came
    % to. `initial_refused` refuses the step: the caller records its input, then
    % the `BoundsError` this carries, and applies nothing more of the step.
    %
:- type initial_outcome
    --->    initial_applied
            % Nothing was pending, or every item was placed.
    ;       initial_refused(cap, fault_site).

    % One sample per step [LTIM.2.8.4]: `Tick` is its event when it must go on
    % the trace [LTIM.2.8.5], to be placed before everything the step emits.
    % `Raised` is the `initial` block's faults, for `lgra_24_3_after_input`.
    %
:- pred clock_step(clock_step::in, list(effect)::out, list(effect)::out,
                   initial_outcome::out, engine::in, engine::out) is det.

clock_step(Step, Tick, Raised, Outcome, !E) :-
    ( if clock_sampled(!.E ^ en_clock) then
        First = no
    else
        First = yes
    ),
    clock_sample(Step, Record, !.E ^ en_clock, Clock0),
    % [NLFC.9.4]: the first sample fixes each host seed's deadline.
    (
        First = yes,
        cache_resolve_held(clock_now(Clock0), !.E ^ en_cache, Cache1),
        !E ^ en_cache := Cache1
    ;
        First = no
    ),
    % After the deadlines are fixed, before the `initial` block writes the cache.
    rfcs_26_1_snapshot(!E),
    (
        Record = yes,
        clock_mark_recorded(Clock0, Clock),
        Sample = [eff_event(se_clock_tick(clock_now(Clock), clock_wall(Clock)))]
    ;
        Record = no,
        Clock = Clock0,
        Sample = []
    ),
    !E ^ en_clock := Clock,
    % The sample stands whatever the block comes to [LGRA.24.3].
    Pending = !.E ^ en_initial,
    (
        Pending = [],
        Outcome = initial_applied,
        Raised = []
    ;
        Pending = [_ | _],
        lgra_24_3_apply(Pending, Outcome, Raised, !E)
    ),
    Tick = Sample.

    % At the engine's first step, the cache as it stands: only the host can have
    % written it. From the second step on, `en_events` is past 0.
    %
    %@spec [RFCS.26.1]
:- pred rfcs_26_1_snapshot(engine::in, engine::out) is det.

rfcs_26_1_snapshot(!E) :-
    ( if !.E ^ en_events = 0u64 then
        !E ^ en_prelude_seeds := list.filter_map(
            seed_of_entry(!.E ^ en_interns), cache_entries(!.E ^ en_cache))
    else
        true
    ).

    % One cache entry as a `CacheSeed`. Every writer stores interned JSON text, so
    % every entry converts. No deadline is 0.
    %
:- func seed_of_entry(intern_table, {string, ds_value, maybe(instant)})
    = cache_seed is semidet.

seed_of_entry(IT, {Key, str(Ref), Expires}) = cache_seed(Key, Text, Ns) :-
    expand(IT, Ref, Text),
    (
        Expires = no,
        Ns = 0u64
    ;
        Expires = yes(Deadline),
        Ns = instant_ns(Deadline)
    ).

prelude_seeds(E) = E ^ en_prelude_seeds.

    % `Raised` placed in `Rest`, what the step records after its tick: right after
    % its first event, the step's input, or at the end when it records none.
    % Each caller drains the step after this [LERR.9.7]. An external delivery's
    % faults follow its first `se_fact_assert`, inside the bracket.
    %
    %@spec [LGRA.24.3]
    %@spec [LTIM.2.8.3]
lgra_24_3_after_input(Raised, Rest) = Out :-
    ( if
        Raised = [_ | _],
        list.find_index_of_match(
            ( pred(Ef::in) is semidet :- Ef = eff_event(_) ), Rest, 0, I),
        list.split_list(I + 1, Rest, Through, After)
    then
        Out = Through ++ Raised ++ After
    else
        Out = Rest ++ Raised
    ).

%-----------------------------------------------------------------------------%
% The FactExternal stamps [LFST.5.6], [RFCS.23.5]
%-----------------------------------------------------------------------------%

    % Every public step ends here, once per event: this numbers the events from
    % `en_events` and stamps each fact by its first FactAssert (`ds.wm.stamp_fact`)
    % with that seq and the step's wall sample. The pump runs it segment by
    % segment, so a fact one firing emits is stamped before the next firing can
    % hand it to a `call`.
    %
    % The result adds the metrics dispatch emits [NMET.4.1]; keep it, not the
    % input: `ds.recorder.events_emitted_total{kind}` immediately before each
    % event with a kind, and `ds.clock.tick_total` immediately after each tick.
    %
:- pred stamp_step(list(effect)::in, list(effect)::out,
                   engine::in, engine::out) is det.

stamp_step(Effects0, Effects, !E) :-
    Wall = clock_wall(!.E ^ en_clock),
    list.foldl2(stamp_effect(Wall), Effects0, !.E ^ en_events, Events,
        !.E ^ en_wm, WM),
    !E ^ en_events := Events,
    !E ^ en_wm := WM,
    Effects = list.condense(list.map(dispatched, Effects0)).

:- func dispatched(effect) = list(effect).

dispatched(Effect) = Out :-
    ( if Effect = eff_event(Event) then
        ( if recorder_kind_label(Event) = yes(Kind) then
            Before = [eff_metric(counter("ds.recorder.events_emitted_total",
                [{"kind", stream_event_kind_name(Kind)}]))]
        else
            Before = []
        ),
        ( if Event = se_clock_tick(_, _) then
            After = [eff_metric(counter("ds.clock.tick_total", []))]
        else
            After = []
        ),
        Out = Before ++ [Effect] ++ After
    else
        Out = [Effect]
    ).

:- pred stamp_effect(maybe(int64)::in, effect::in, uint64::in, uint64::out,
                     wm::in, wm::out) is det.

stamp_effect(_, eff_action(_), !Seq, !WM).
stamp_effect(_, eff_input(_), !Seq, !WM).
stamp_effect(_, eff_cache_expired(_), !Seq, !WM).
stamp_effect(_, eff_metric(_), !Seq, !WM).
stamp_effect(_, eff_host_log(_, _, _), !Seq, !WM).
stamp_effect(_, eff_pump_status(_), !Seq, !WM).
stamp_effect(Wall, eff_event(Event), !Seq, !WM) :-
    ( if Event = se_fact_assert(FactId, _, _, _) then
        stamp_fact(FactId, fact_stamp(!.Seq, Wall), !WM)
    else
        true
    ),
    !:Seq = !.Seq + 1u64.

host_assert(Schema, Values, Override, Result, Effects, !E) :-
    host_assert_unstamped(Schema, Values, Override, Result, Effects0, !E),
    stamp_step(Effects0, Effects1, !E),
    Effects = bracket_external(!.E, Effects1).

host_assert_with_ttl(Schema, Values, Window, Result, Effects, !E) :-
    host_assert_core(yes, Schema, Values, ov_window(Window), Result,
        Effects0, !E),
    stamp_step(Effects0, Effects1, !E),
    Effects = bracket_external(!.E, Effects1).

    % An absolute deadline (`no` for the schema's own), or a window that
    % `host_assert_core` resolves once it has sampled.
    %
:- type ttl_override
    --->    ov_deadline(maybe(instant))
    ;       ov_window(duration).

:- func resolve_override(ttl_override, instant) = maybe(instant).

resolve_override(ov_deadline(Deadline), _) = Deadline.
resolve_override(ov_window(Window), Now) = yes(add(Now, Window)).

    % A host assert whose deadline, the entry stamp plus its window, would pass
    % INT64_MAX [LTIM.1.1.5]. The window is the replayer's override, else a `ttl`
    % schema's own TTL. A deadline given outright is the caller's.
    %
    %@spec [RFCS.6.7]
:- pred rfcs_6_7_deadline_out_of_range(schema::in, ttl_override::in,
    instant::in) is semidet.

nlfc_9_5_first_sample_out_of_range(E) :-
    Clock = E ^ en_clock,
    not clock_sampled(Clock),
    cache_held_ttl_max(E ^ en_cache) = yes(Ttl),
    ltim_1_1_5_deadline_past_range(clock_source_now(Clock), Ttl).

rfcs_6_7_deadline_out_of_range(Schema, Override, Now) :-
    (
        Override = ov_window(Window),
        W = duration_ns(Window)
    ;
        Override = ov_deadline(no),
        Schema ^ s_lifecycle = lc_ttl(_, Ttl),
        W = duration_ns(Ttl)
    ),
    W > 0u64,
    W > uint64.cast_from_int64(int64.max_int64) - instant_ns(Now).

    % [RFCS.24.1]: a host assert whose fact holds a non-null reference is recorded
    % as one ExternalAssert, with each referenced live fact inlined, so its first
    % FactAssert is bracketed. A refused assert's fact packs to nothing and is not.
    %
:- func bracket_external(engine, list(effect)) = list(effect).

bracket_external(E, Effects) = Out :-
    ( if
        list.find_index_of_match(
            ( pred(Ef::in) is semidet :-
                Ef = eff_event(se_fact_assert(_, _, _, _)) ),
            Effects, 0, I),
        list.split_list(I, Effects, Before, [Assert | After]),
        Assert = eff_event(se_fact_assert(FactId, _, Slots, _)),
        list.find_first_match(
            ( pred(V::in) is semidet :- V = fact_ref(_) ), Slots, _),
        recorded_external_bytes(E ^ en_schemas, E ^ en_interns, E ^ en_wm,
            clock_wall(E ^ en_clock), FactId, Bytes)
    then
        Out = Before ++ [eff_input(hi_open(Bytes)), Assert,
            eff_input(hi_close)] ++ After
    else
        Out = Effects
    ).

input_step_begin(Tick, Raised, Refused, !E) :-
    clock_step(step_input, Tick, Raised, Outcome, !E),
    (
        Outcome = initial_applied,
        Refused = no
    ;
        Outcome = initial_refused(Cap, _),
        Refused = yes(Cap)
    ).

host_assert_in_step(Schema, Values, Override, Result, Effects, !E) :-
    host_assert_core(no, Schema, Values, ov_deadline(Override), Result,
        Effects, !E).

input_step_end(Effects0, Effects, !E) :-
    host_drain(Effects0, Effects1, !E),
    lerr_1_4_7_halt(Effects1, Effects2, !E),
    stamp_step(Effects2, Effects, !E).

host_retract(FactId, Effects, !E) :-
    host_retract_unstamped(FactId, Effects0, !E),
    stamp_step(Effects0, Effects, !E).

advance(D, Effects, !E) :-
    advance_unstamped(D, Effects0, !E),
    stamp_step(Effects0, Effects, !E).

set_clock(At, Effects, !E) :-
    set_clock_unstamped(At, Effects0, !E),
    stamp_step(Effects0, Effects, !E).

pump(Budget, Effects, !E) :-
    pump_unstamped(Budget, Effects, !E).

    % A host's slot value as the engine stores it: a `Time` as its UTC nanoseconds
    % [LTIM.1.1.3], a `Json` term with its float zeros unsigned [LGRA.5.8.8]. A
    % term past a Json limit passes unchanged, and `ds.fact` refuses it.
    %
:- func host_slot_value(ds_value) = ds_value.

host_slot_value(V0) = V :-
    V1 = stored_value(V0),
    ( if V1 = json(J), limit_breach(J) = no then
        V = json(unsigned_zeros(J))
    else
        V = V1
    ).

:- pred host_assert_unstamped(schema::in, list(ds_value)::in,
    maybe(instant)::in, assert_result::out, list(effect)::out,
    engine::in, engine::out) is det.
:- pred host_retract_unstamped(fact_id::in, list(effect)::out,
    engine::in, engine::out) is det.
:- pred advance_unstamped(duration::in, list(effect)::out,
    engine::in, engine::out) is det.
:- pred set_clock_unstamped(instant::in, list(effect)::out,
    engine::in, engine::out) is det.
:- pred pump_unstamped(fire_budget::in, list(effect)::out,
    engine::in, engine::out) is det.

host_assert_unstamped(Schema, Values, Override, Result, Effects, !E) :-
    host_assert_core(yes, Schema, Values, ov_deadline(Override), Result,
        Effects, !E).

    % Which condition a host-asserted `TimeZoneOffset` row breaks: the period, the
    % offset, then the zone "UTC". Fails for a well-formed row and for any other
    % schema. The slots are zone, valid_from, valid_until, offset_s [LIMP.12.2].
    %
    %@spec [LTIM.10.9]
:- pred ltim_10_9_tz_row_fault(engine::in, schema::in, list(ds_value)::in,
                               tz_row_fault::out) is semidet.

ltim_10_9_tz_row_fault(E, Schema, Values, Fault) :-
    is_tz_schema(E ^ en_wm, Schema ^ s_id),
    Values = [Zone, int(From), int(Until), int(Offset)],
    ( if not From < Until then
        Fault = tzf_empty_period
    else if ( Offset < -64800i64 ; Offset > 64800i64 ) then
        Fault = tzf_offset_range
    else
        (
            Zone = str(Ref),
            expand(E ^ en_interns, Ref, Name),
            Name = "UTC"
        ;
            Zone = text("UTC")
        ),
        Fault = tzf_utc_zone
    ).

ncbk_10_4_value_refused(E, Schema, Values, Window, Why) :-
    (
        Window = yes(D),
        Override = ov_window(D)
    ;
        Window = no,
        Override = ov_deadline(no)
    ),
    ( if ltim_10_9_tz_row_fault(E, Schema, Values, _) then
        Why = dr_tz_row
    else if
        rfcs_6_7_deadline_out_of_range(Schema, Override,
            clock_source_now(E ^ en_clock))
    then
        Why = dr_time_range
    else
        lstr_11_3_over_capacity(E ^ en_interns, Schema, Values, _, _),
        Why = dr_over_capacity
    ).

    % The reference names a live fact of another schema, or no live fact
    % [NFCT.2.3].
    %
:- pred nfct_2_3_refused_target(engine::in, schema_name::in, fact_id::in)
    is semidet.

nfct_2_3_refused_target(E, Declared, Id) :-
    ( if lookup_fact(E ^ en_wm, Id, Fact) then
        map.search(E ^ en_schemas, schema_id_value(Fact ^ f_schema), Target),
        Target ^ s_name \= Declared
    else
        true
    ).

    % The host assert, as its own step (`Own = yes`: its sample, its drain) or
    % inside an enclosing one (`Own = no`, `host_assert_in_step`).
    %
:- pred host_assert_core(bool::in, schema::in, list(ds_value)::in,
    ttl_override::in, assert_result::out, list(effect)::out,
    engine::in, engine::out) is det.

host_assert_core(Own, Schema, Values0, Override0, Result, Effects, !E) :-
    Values = list.map(host_slot_value, Values0),
    % [NFCT.2.11]: the first refusal in the clause's order decides, and the arms
    % below are in that order. Each refusal is before the step: no sample, no
    % event, no fact, and a pending `initial` block still pending.
    ( if !.E ^ en_halted = yes(Halt) then
        % [NCBK.2.9].
        Result = refused_halted(Halt),
        Effects = []
    else if not nfct_1_1_registered(!.E, Schema) then
        % [NFCT.1.1].
        Result = refused_unregistered(Schema ^ s_name),
        Effects = []
    else if
        Given = list.length(Values),
        Slots = list.length(slot_commons(Schema)),
        Given \= Slots
    then
        % [NFCT.2.2].
        Result = refused_arity(Slots, Given),
        Effects = []
    else if
        Own = yes,
        slot_ref_fault(nfct_2_3_refused_target(!.E), Schema, Values, RefIndex)
    then
        % [NFCT.2.3], in slot order with the kinds and ahead of a NaN. A host's
        % own call only: [RFCS.23.7] judges a delivery's references once, in
        % `ds.fact_receive`'s plan.
        Result = invalid(RefIndex, sr_kind_mismatch),
        Effects = []
    else if
        not slot_fault(Schema, Values, _, _),
        lstr_8_5_first_ill_formed(!.E ^ en_interns, Values, 0, TextIndex)
    then
        % [LSTR.8.5]: `DS_ERR_ENCODING`.
        Result = refused_encoding(TextIndex),
        Effects = []
    else if
        not slot_fault(Schema, Values, _, _),
        ltim_1_2_2_first_date_out_of_range(Schema, Values, DateIndex)
    then
        % [LTIM.1.2.2]: `DS_ERR_TIME_RANGE`.
        Result = refused_time_range(DateIndex),
        Effects = []
    else if
        not slot_fault(Schema, Values, _, _),
        ltim_10_9_tz_row_fault(!.E, Schema, Values, TzFault)
    then
        % [LTIM.10.9]: `DS_ERR_INVAL`.
        Result = refused_tz_row(TzFault),
        Effects = []
    else if
        not slot_fault(Schema, Values, _, _),
        rfcs_6_7_deadline_out_of_range(Schema, Override0,
            ( if Own = yes then
                clock_source_now(!.E ^ en_clock)
            else
                clock_now(!.E ^ en_clock)
            ))
    then
        % [RFCS.6.7], [LTIM.1.1.5]: `DS_ERR_TIME_RANGE`, reading the value the
        % step would sample, or a nested assert's enclosing sample.
        Result = refused_ttl_range,
        Effects = []
    else if
        Own = yes,
        not slot_fault(Schema, Values, _, _),
        nlfc_9_5_first_sample_out_of_range(!.E)
    then
        % [NLFC.9.5]: the same, for a held seed's deadline this sample would fix.
        Result = refused_ttl_range,
        Effects = []
    else
        % Sampled here, outside `host_assert_live`: that puts the whole engine
        % back on a node-cap breach, and the sample must survive that.
        %
        % A slot the schema does not admit takes no step, and `slot_fault` here is
        % the check `assert_fact` makes: it rewrites nothing, samples nothing,
        % leaves a pending `initial` block pending and supersedes nothing.
        ( if slot_fault(Schema, Values, _, _) then
            Admitted = Values,
            Rewritten = []
        else
            lecc_1_2_code_rewrite(Schema, Values, Admitted, Rewritten, !E)
        ),
        Clock0 = !.E ^ en_clock,
        ( if Own = yes, not slot_fault(Schema, Admitted, _, _) then
            clock_step(step_input, Tick, Raised, Outcome, !E)
        else
            Tick = [],
            Raised = [],
            Outcome = initial_applied
        ),
        % After the sample [LTIM.2.8.6], [RFCS.6.7]. In range: refused above.
        Override = resolve_override(Override0, clock_now(!.E ^ en_clock)),
        (
            Outcome = initial_refused(Cap, Site),
            % [LGRA.24.3]: the block refused the step, which is recorded as a
            % refused assert is [RFCS.6.7]: the input's `FactAssert`, under an id
            % taken without a fact, then the `BoundsError`.
            Result = rejected(Cap),
            Now = clock_now(!.E ^ en_clock),
            ( if Override = yes(_) then
                Deadline = Override
            else
                Deadline = schema_deadline(Schema, Now)
            ),
            mint_unentered_id(Schema, ViewId, !.E ^ en_wm, ViewWM),
            !E ^ en_wm := ViewWM,
            Effects1 = Rewritten ++ Tick ++ lgra_24_3_after_input(Raised, [
                eff_event(se_fact_assert(ViewId, Schema ^ s_id, Admitted,
                    recorded_ttl(Deadline, Now))),
                eff_event(se_engine_error(ee_contract_breach(Cap), Site))])
        ;
            Outcome = initial_applied,
            % [LCRS.6.2.4]: an arriving answer supersedes before it enters working
            % memory, and is recorded ahead of the withdrawals (`input_first`,
            % [RFCS.6.7]). Outside `host_assert_live`, so a cap breach keeps them.
            ( if slot_fault(Schema, Admitted, _, _) then
                Superseded = []
            else
                host_supersede(Schema, Admitted, Superseded, !E)
            ),
            host_assert_live(Schema, Admitted, Override, Result, Effects0,
                !E),
            ( if Result = invalid(_, _) then
                !E ^ en_clock := Clock0,
                Effects1 = Rewritten ++ lgra_24_3_after_input(Raised,
                    Effects0)
            else
                Effects1 = Rewritten ++ Tick ++ lgra_24_3_after_input(
                    Raised, input_first(Superseded, Effects0))
            )
        ),
        (
            Own = yes,
            host_drain(Effects1, Effects2, !E)
        ;
            Own = no,
            Effects2 = Effects1
        ),
        % A rung-7 fault the match raised halts here [LERR.1.4.7].
        lerr_1_4_7_halt(Effects2, Effects, !E)
    ).

    % A host-asserted `CallError` whose `code` breaks [LECC.1.2]'s wire format is
    % asserted with `internal.invariant` instead, and counted as
    % `ds.errors.code_invariant_total{schema}` [NMET.4.1]. Any other schema, a
    % `code` that is not a String, and a well-formed one pass unchanged.
    %
:- pred lecc_1_2_code_rewrite(schema::in, list(ds_value)::in,
    list(ds_value)::out, list(effect)::out, engine::in, engine::out) is det.

lecc_1_2_code_rewrite(Schema, Values0, Values, Counted, !E) :-
    IT0 = !.E ^ en_interns,
    ( if
        expand(IT0, schema_name_ref(Schema ^ s_name), SchemaName),
        SchemaName = "CallError",
        list.find_index_of_match(
            ( pred(C::in) is semidet :-
                expand(IT0, C ^ sc_name, SlotName),
                SlotName = "code"
            ), slot_commons(Schema), 0, Index),
        list.index0(Values0, Index, Code),
        code_text(IT0, Code, Text),
        not lecc_1_2_well_formed(Text)
    then
        intern("internal.invariant", Ref, IT0, IT),
        !E ^ en_interns := IT,
        list.det_replace_nth(Values0, Index + 1, str(Ref), Values),
        Counted = [eff_metric(counter("ds.errors.code_invariant_total",
            [{"schema", SchemaName}]))]
    else
        Values = Values0,
        Counted = []
    ).

:- pred code_text(intern_table::in, ds_value::in, string::out) is semidet.

code_text(IT, str(Ref), Text) :-
    expand(IT, Ref, Text).
code_text(_, text(Text), Text).

    % [LSTR.8.5]: the index of the first host value whose text is not well-formed
    % UTF-8: a `String`, or a `Json` term holding such a string or key anywhere.
    % Fails when there is none.
    %
:- pred lstr_8_5_first_ill_formed(intern_table::in, list(ds_value)::in,
                                  int::in, int::out) is semidet.

lstr_8_5_first_ill_formed(IT, [V | Vs], I, Index) :-
    ( if lstr_8_5_ill_formed(IT, V) then
        Index = I
    else
        lstr_8_5_first_ill_formed(IT, Vs, I + 1, Index)
    ).

:- pred lstr_8_5_ill_formed(intern_table::in, ds_value::in) is semidet.

lstr_8_5_ill_formed(IT, V) :-
    (
        V = str(Ref),
        expand(IT, Ref, S),
        not utf8_well_formed(S)
    ;
        V = text(S),
        not utf8_well_formed(S)
    ;
        V = json(J),
        not lstr_8_5_well_formed(J)
    ).

    % [LECC.1.2]: `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*`, ASCII only.
    %
:- pred lecc_1_2_well_formed(string::in) is semidet.

lecc_1_2_well_formed(Text) :-
    list.all_true(lecc_1_2_segment, string.split_at_char('.', Text)).

:- pred lecc_1_2_segment(string::in) is semidet.

lecc_1_2_segment(Segment) :-
    Chars = string.to_char_list(Segment),
    Chars = [Head | Tail],
    code_lower(Head),
    list.all_true(code_tail_char, Tail).

:- pred code_lower(char::in) is semidet.

code_lower(C) :-
    N = char.to_int(C),
    N >= 0x61,
    N =< 0x7A.

:- pred code_tail_char(char::in) is semidet.

code_tail_char(C) :-
    N = char.to_int(C),
    ( N >= 0x61, N =< 0x7A
    ; N >= 0x30, N =< 0x39
    ; N = 0x5F
    ).

    % [LCRS.6.2.4]: retract the live answers an arriving fact supersedes
    % (`ds.exec.lcrs_6_2_4_arrival_victims`), each an ordinary removal. An answer
    % is never a token fact, so no activation fact waits on one.
    %
:- pred host_supersede(schema::in, list(ds_value)::in, list(effect)::out,
                       engine::in, engine::out) is det.

host_supersede(Schema, Values, Effects, !E) :-
    Victims = lcrs_6_2_4_arrival_victims(!.E ^ en_schemas, !.E ^ en_interns,
        !.E ^ en_responses, Schema, Values, !.E ^ en_wm),
    list.foldl2(supersede_one, Victims, [], Effects, !E).

    % [LCRS.6.2.4], [RFCS.6.7]: the superseded effects follow the answer's first
    % `se_fact_assert`, though working memory removed those facts first, and its
    % cascade follows them. With no `FactAssert`, they follow everything.
    %
:- func input_first(list(effect), list(effect)) = list(effect).

input_first(Superseded, Effects) = Out :-
    ( if
        list.find_index_of_match(
            ( pred(Ef::in) is semidet :-
                Ef = eff_event(se_fact_assert(_, _, _, _)) ),
            Effects, 0, I),
        list.split_list(I + 1, Effects, Upto, After)
    then
        Out = Upto ++ Superseded ++ After
    else
        Out = Effects ++ Superseded
    ).

:- pred supersede_one(fact_id::in, list(effect)::in, list(effect)::out,
                      engine::in, engine::out) is det.

supersede_one(FactId, !Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: stops at the halt, between facts. The answer still enters
        % working memory and propagates nothing (`settle_turnover`).
        true
    else if retract_fact(FactId, rc_supersede, !.E ^ en_wm, WM) then
        !E ^ en_wm := WM,
        settle_fact_split(retracted(FactId), Faults, Cascade, !E),
        !:Effects = !.Effects ++ Faults
            ++ [eff_event(removal_event(FactId, rc_supersede))] ++ Cascade
    else
        true
    ).

    % [LERR.9.7]: a host call's fault facts, asserted as it returns. Not behind an
    % `EngineError`.
    %
:- pred host_drain(list(effect)::in, list(effect)::out,
                   engine::in, engine::out) is det.

host_drain(Effects0, Effects, !E) :-
    ( if list.find_first_match(latching, Effects0, _) then
        Effects = Effects0
    else
        drain_fault_facts(Effects0, Drained, !E),
        Effects = Effects0 ++ Drained
    ).

:- pred host_assert_live(schema::in, list(ds_value)::in, maybe(instant)::in,
                         assert_result::out, list(effect)::out,
                         engine::in, engine::out) is det.

host_assert_live(Schema, Values, Override, Result, Effects, !E) :-
    % A per-node capacity has no answer until propagation has finished, so the
    % assert runs and a breach puts the engine back [RTCT.7.2].
    E0 = !.E,
    host_assert_uncapped(Schema, Values, Override, Result0, Effects0, !E),
    ( if
        Result0 \= rejected(_),
        over_capacity(!.E, Cap)
    then
        % Off the overfilled engine, for the count that breached.
        Site = capacity_site(!.E, Cap),
        !:E = E0,
        Result = rejected(Cap),
        Effects = [eff_event(se_engine_error(ee_contract_breach(Cap), Site))]
    else
        Result = Result0,
        Effects = Effects0
    ).

    % The first cap breached, an observable when several are over: alpha and beta
    % capacities, `agenda_cap`, then terminal capacities, each by ascending node
    % id. O(nodes) per assert, only under a contract.
    %
:- pred over_capacity(engine::in, cap::out) is semidet.

over_capacity(E, Cap) :-
    E ^ en_contract = yes(RT),
    % `c_nodes` is ascending [RBND.4b.8], and `list.filter` keeps each side so.
    list.filter(is_terminal_cap, RT ^ c_nodes, Terminals, Upstream),
    ( if list.find_first_match(node_over(E), Upstream, Node) then
        node_id(Node ^ nc_id, Id),
        Cap = cap_node(Id)
    else if agenda_over(E, RT) then
        Cap = cap_agenda
    else
        list.find_first_match(node_over(E), Terminals, Term),
        node_id(Term ^ nc_id, TermId),
        Cap = cap_node(TermId)
    ).

:- pred is_terminal_cap(node_cap::in) is semidet.

is_terminal_cap(N) :-
    N ^ nc_kind = "term".

    % [RTCT.7]: `agenda_cap` counts the pending queue, so firing gives a slot back;
    % a terminal's capacity does not.
    %
:- pred agenda_over(engine::in, contract::in) is semidet.

agenda_over(E, RT) :-
    RT ^ c_agenda_cap > 0u32,
    agenda_count(E ^ en_agenda) > uint32.cast_to_int(RT ^ c_agenda_cap).

:- pred node_over(engine::in, node_cap::in) is semidet.

node_over(E, N) :-
    N ^ nc_capacity > 0u32,
    node_held(E, N, Held),
    Held > uint32.cast_to_int(N ^ nc_capacity).

    % What a capped node holds now: an alpha's or a beta's memory, a terminal's
    % match count. Fails on a kind the contract spells otherwise [RTCT.6.7].
    %
:- pred node_held(engine::in, node_cap::in, int::out) is semidet.

node_held(E, N, Held) :-
    node_id(N ^ nc_id, Id),
    (
        N ^ nc_kind = "alpha",
        Held = list.length(alpha_memory(E ^ en_rete, Id))
    ;
        N ^ nc_kind = "beta",
        Held = list.length(beta_memory(E ^ en_rete, Id))
    ;
        N ^ nc_kind = "term",
        Held = terminal_matches(E ^ en_rete, Id)
    ).

    % A per-node capacity names its node; both it and `agenda_cap` carry the cap
    % and the count that went over it.
    %
:- func capacity_site(engine, cap) = fault_site.

capacity_site(E, Cap) = Site :-
    ( if
        E ^ en_contract = yes(RT),
        Cap = cap_node(Id),
        list.find_first_match(
            ( pred(N::in) is semidet :- node_id(N ^ nc_id, Id) ),
            RT ^ c_nodes, Node),
        node_held(E, Node, Held)
    then
        Site = (no_site ^ fs_node := yes(Id)) ^ fs_bound :=
            yes(fault_bound(uint32.cast_to_uint64(Node ^ nc_capacity),
                uint64.det_from_int(Held)))
    else if
        E ^ en_contract = yes(RT),
        Cap = cap_agenda
    then
        Site = no_site ^ fs_bound := yes(fault_bound(
            uint32.cast_to_uint64(RT ^ c_agenda_cap),
            uint64.det_from_int(agenda_count(E ^ en_agenda))))
    else
        Site = no_site
    ).

:- pred host_assert_uncapped(schema::in, list(ds_value)::in,
                             maybe(instant)::in, assert_result::out,
                             list(effect)::out, engine::in, engine::out) is det.

host_assert_uncapped(Schema, Values, Override, Result, Effects, !E) :-
    Now = clock_now(!.E ^ en_clock),
    ( if Override = yes(_) then
        Deadline = Override
    else
        Deadline = schema_deadline(Schema, Now)
    ),
    % [RTCT.7]: `Candidate` tells an insert from a no-op or a replace, since only
    % an insert can breach `wm_max`; a refusal drops `WM` [RTCT.7.2]. `tms_none`
    % because this is the host path: justification is keyed on the assertion verb,
    % not the schema [LLOG.15.1, 15.2].
    assert_fact(Schema, Values, Now, Deadline, tms_none, live, Candidate,
        !.E ^ en_wm, WM),
    ( if
        % [LSTR.11.3]: before `wm_max`. A slot fault in the candidate still wins.
        not Candidate = invalid(_, _),
        lstr_11_3_over_capacity(!.E ^ en_interns, Schema, Values, CapN, Len)
    then
        Result = rejected(cap_value_capacity),
        CapacityBound = yes(fault_bound(uint32.cast_to_uint64(CapN), Len))
    else if
        % [LSER.13.14]: a sample past a step backing's `capacity`, counting this
        % pump's unabsorbed samples. After the String capacity, before `wm_max`.
        lser_13_14_over_capacity(!.E ^ en_sdecls, !.E ^ en_interns,
            !.E ^ en_series, Now, Schema, !.E ^ en_wm, WM, Candidate,
            SeriesCap, SeriesReached)
    then
        Result = rejected(cap_series),
        CapacityBound = yes(fault_bound(uint32.cast_to_uint64(SeriesCap),
            SeriesReached))
    else if
        !.E ^ en_contract = yes(RT),
        RT ^ c_wm_max > 0u32,
        Candidate = inserted(_),
        lerr_9_10_capacity_count(WM, !.E ^ en_fault_schemas)
            > uint32.cast_to_int(RT ^ c_wm_max)
    then
        Result = rejected(cap_wm_max),
        CapacityBound = no
    else
        Result = Candidate,
        CapacityBound = no,
        !E ^ en_wm := WM
    ),
    (
        Result = rejected(Cap),
        % [RTCT.7.2]: nothing entered working memory.
        (
            CapacityBound = yes(_),
            CapSite = no_site ^ fs_bound := CapacityBound
        ;
            CapacityBound = no,
            CapSite = host_wm_site(!.E, WM)
        ),
        % [RFCS.6.7]: a refused assert is recorded too, its `FactAssert` first,
        % under an id taken without a fact.
        mint_unentered_id(Schema, ViewId, !.E ^ en_wm, ViewWM),
        !E ^ en_wm := ViewWM,
        Effects = [
            eff_event(se_fact_assert(ViewId, Schema ^ s_id, Values,
                recorded_ttl(Deadline, Now))),
            eff_event(se_engine_error(ee_contract_breach(Cap), CapSite))]
    ;
        Result = invalid(Index, Reason),
        % [NFCT.2.11]: the status is the whole refusal; nothing is recorded. A NaN
        % counts `ds.facts.nan_rejected_total{schema,slot}` [NMET.4.1], on the host
        % path only.
        ( if
            Reason = sr_nan_rejected,
            slot_name_at(Schema, Index) = yes(SlotRef),
            expand(!.E ^ en_interns, schema_name_ref(Schema ^ s_name),
                SchemaText),
            expand(!.E ^ en_interns, SlotRef, SlotText)
        then
            Effects = [eff_metric(counter("ds.facts.nan_rejected_total",
                [{"schema", SchemaText}, {"slot", SlotText}]))]
        else
            Effects = []
        )
    ;
        % `host_assert_core` answers this and the next six before this runs.
        Result = refused_halted(_),
        Effects = []
    ;
        Result = refused_unregistered(_),
        Effects = []
    ;
        Result = refused_arity(_, _),
        Effects = []
    ;
        Result = refused_time_range(_),
        Effects = []
    ;
        Result = refused_encoding(_),
        Effects = []
    ;
        Result = refused_tz_row(_),
        Effects = []
    ;
        Result = refused_ttl_range,
        Effects = []
    ;
        Result = noop(Standing),
        % No re-match [LFAC.2.5.1], but the arriving assert is recorded [RFCS.6.7],
        % after `ds.facts.noop_reassert_suppressed_total{schema}` [NMET.4.1].
        Counted = list.map((func(M) = eff_metric(M)),
            noop_counted(!.E ^ en_interns, Schema)),
        ( if lookup_fact(!.E ^ en_wm, Standing, Fact) then
            Effects = Counted ++ [eff_event(se_fact_assert(Standing,
                Schema ^ s_id, array.to_list(Fact ^ f_slots),
                recorded_ttl(Fact ^ f_deadline, Fact ^ f_asserted)))]
        else
            Effects = Counted
        )
    ;
        Result = inserted(FactId),
        Base = [eff_event(se_fact_assert(FactId, Schema ^ s_id, Values,
                recorded_ttl(Deadline, Now)))],
        settle_fact_split(asserted(FactId), Faults0, Cascade, !E),
        split_expiries(Faults0, Expiries, Faults),
        % [RFCS.6.7]: the arriving assert precedes everything its evaluation
        % produces. A cache notification is no record, and comes first.
        Effects = Expiries ++ Base ++ Faults ++ Cascade
    ;
        Result = replaced(Old, FactId),
        settle_fact_split(retracted(Old), OldFaults0, OldCascade, !E),
        % [LERR.1.4.7]: after an EngineError from the retract, this settles nothing.
        settle_fact_split(asserted(FactId), NewFaults0, NewCascade, !E),
        split_expiries(OldFaults0, OldExpiries, OldFaults),
        split_expiries(NewFaults0, NewExpiries, NewFaults),
        % [RFCS.6.7], [LFAC.2.5.3]: the cache notifications, the arriving assert,
        % the withdrawal it caused (the engine's, so `rc_supersede`), both halves'
        % faults, both cascades.
        Effects =
            OldExpiries ++ NewExpiries ++
            [eff_event(se_fact_assert(FactId, Schema ^ s_id, Values,
                recorded_ttl(Deadline, Now)))] ++
            [eff_event(se_fact_withdraw(Old, rc_supersede))] ++
            OldFaults ++
            NewFaults ++
            OldCascade ++
            NewCascade
    ).

    % The cache notifications a match's reads raised, apart from its faults.
    %
:- pred split_expiries(list(effect)::in, list(effect)::out, list(effect)::out)
    is det.

split_expiries(Effects, Expiries, Rest) :-
    list.filter((pred(Ef::in) is semidet :- Ef = eff_cache_expired(_)),
        Effects, Expiries, Rest).

host_retract_unstamped(FactId, Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        Effects = []
    else if nlfc_9_5_first_sample_out_of_range(!.E) then
        % [NLFC.9.5]: takes no step and changes nothing.
        Effects = []
    else
        % Sampled whether or not the fact is live [LTIM.2.8.4].
        clock_step(step_input, Tick, Raised, Outcome, !E),
        ( if Outcome = initial_refused(Cap, Site) then
            % [LGRA.24.3]: nothing is retracted.
            Effects = Tick ++ [eff_event(se_engine_error(ee_contract_breach(Cap),
                Site))]
        else if retract_fact(FactId, rc_explicit, !.E ^ en_wm, WM) then
            !E ^ en_wm := WM,
            settle_fact_split(retracted(FactId), Faults, Cascade, !E),
            % [RFCS.6.7]: recorded on arrival, before its faults and cascade.
            Effects0 = Tick ++ lgra_24_3_after_input(Raised,
                [eff_event(se_fact_retract(FactId))] ++ Faults ++ Cascade),
            host_drain(Effects0, Effects1, !E),
            % A rung-7 fault the match raised halts here [LERR.1.4.7].
            lerr_1_4_7_halt(Effects1, Effects, !E)
        else
            host_drain(Tick ++ lgra_24_3_after_input(Raised, []), Effects, !E)
        )
    ).

advance_unstamped(D, Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        Effects = []
    else if clock_advance(D, !.E ^ en_clock, Clock) then
        !E ^ en_clock := Clock,
        Effects = [eff_metric(counter("ds.clock.advance_total", []))]
    else
        % A live clock, or past a clock's range [NTST.3.1].
        Effects = []
    ).

engine_advance_past_range(E, D) :-
    ntst_3_1_advance_past_range(D, E ^ en_clock).

set_clock_unstamped(At, Effects, !E) :-
    Effects = [],
    ( if !.E ^ en_halted = yes(_) then
        true
    else if clock_set(At, !.E ^ en_clock, Clock) then
        !E ^ en_clock := Clock
    else
        % A live clock, a backward set after the first sample, or a set past the
        % clock's range [NTST.3.1].
        true
    ).

set_wall_clock(Utc, !E) :-
    ( if
        !.E ^ en_halted = no,
        clock_wall_set(Utc, !.E ^ en_clock, Clock)
    then
        !E ^ en_clock := Clock
    else
        true
    ).

unset_wall_clock(!E) :-
    ( if
        !.E ^ en_halted = no,
        clock_wall_unset(!.E ^ en_clock, Clock)
    then
        !E ^ en_clock := Clock
    else
        true
    ).

observe_wall_clock(Reading, !E) :-
    ( if
        !.E ^ en_halted = no,
        clock_observe(Reading, !.E ^ en_clock, Clock)
    then
        !E ^ en_clock := Clock
    else
        true
    ).

:- func expiry_event(fact) = effect.

expiry_event(Fact) = eff_event(se_fact_withdraw(Fact ^ f_id, rc_ttl)).

:- pred settle_expiry(fact::in, list(effect)::in, list(effect)::out,
                      engine::in, engine::out) is det.

settle_expiry(Fact, !Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: the sweep stops at the halt, between facts.
        true
    else
        settle_fact(retracted(Fact ^ f_id), More, !E),
        !:Effects = !.Effects ++ More
    ).

%-----------------------------------------------------------------------------%
% Feeding a fact change into the network
%-----------------------------------------------------------------------------%

:- type fact_change
    --->    asserted(fact_id)
    ;       retracted(fact_id).

    % Whether the fact is compiler-synthesised. `en_synth` still holds one retracted
    % earlier in this pump: `prune_synthetic` runs as the pump ends.
    %
:- pred synthetic_change(fact_change::in, engine::in) is semidet.

synthetic_change(Change, E) :-
    ( Change = asserted(FactId) ; Change = retracted(FactId) ),
    set.contains(E ^ en_synth, fact_id_value(FactId)).

    % Re-match, then reconcile the agenda with what changed.
    %
:- pred settle_fact(fact_change::in, list(effect)::out,
                    engine::in, engine::out) is det.

settle_fact(Change, Effects, !E) :-
    settle_fact_split(Change, Faults, Cascade, !E),
    Effects = Faults ++ Cascade.

    % The same, with the faults the match raised kept apart from the cascade: a
    % host assert or retract places them after its own records [RFCS.6.7].
    %
:- pred settle_fact_split(fact_change::in, list(effect)::out, list(effect)::out,
                          engine::in, engine::out) is det.

settle_fact_split(Change, FaultEvents, Effects, !E) :-
    settle_turnover(Change, not_turnover, FaultEvents, Effects, _, !E).

    % Which side of the tick's turnover a change is, if either [IRET.19.5]. A
    % turnover ends no match, so no justification [IRET.12.2]: the old tick leaving
    % holds the activations it removed; the new tick arriving hands each one's
    % justification to the activation its token re-formed, and ends only those no
    % token re-formed.
    %
:- type tick_turnover
    --->    not_turnover
    ;       tick_out
    ;       tick_in(
                ti_carried :: list(activation),
                ti_ticks   :: list(fact_id)
                            % The old tick and the new.
            ).

:- pred settle_turnover(fact_change::in, tick_turnover::in, list(effect)::out,
                        list(effect)::out, list(activation)::out,
                        engine::in, engine::out) is det.

settle_turnover(Change, Turnover, FaultEvents, Effects, Held, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: once latched, no change is matched, joined or cascaded.
        % The working-memory edit the caller already made stands.
        FaultEvents = [],
        Effects = [],
        Held = []
    else
        settle_turnover_live(Change, Turnover, FaultEvents, Effects, Held, !E)
    ).

:- pred settle_turnover_live(fact_change::in, tick_turnover::in,
                             list(effect)::out, list(effect)::out,
                             list(activation)::out,
                             engine::in, engine::out) is det.

settle_turnover_live(Change, Turnover, FaultEvents, Effects, Held, !E) :-
    Ctx = match_ctx(!.E ^ en_wm, !.E ^ en_schemas, !.E ^ en_interns,
        clock_now(!.E ^ en_clock), clock_wall(!.E ^ en_clock), !.E ^ en_cache,
        !.E ^ en_series),
    (
        Change = asserted(FactId),
        fact_asserted(!.E ^ en_index, Ctx, FactId, Delta, !.E ^ en_rete, Rete)
    ;
        Change = retracted(FactId),
        forget_fact(FactId, !.E ^ en_tms, TMS),
        !E ^ en_tms := TMS,
        fact_retracted(!.E ^ en_index, Ctx, FactId, Delta, !.E ^ en_rete, Rete)
    ),
    !E ^ en_rete := Rete,
    % An author change's removed activations stop refracting [IRET.11.3.2]. A
    % synthetic fact's forgets nothing: every pump cycles the tick, which would
    % re-fire a matured rule every pump [IRET.19.5].
    ( if synthetic_change(Change, !.E) then
        true
    else
        Synth = !.E ^ en_synth,
        !E ^ en_refract := list.foldl(
            ( func(A, R) = forget(Synth, A, R) ),
            Delta ^ md_removed, !.E ^ en_refract)
    ),

    list.foldl(withdraw_activation, Delta ^ md_removed, !E),

    % Tell the TMS those activations ended, and retract what loses its last
    % support.
    (
        Turnover = not_turnover,
        Ended = Delta ^ md_removed,
        Held = [],
        Unclaimed = []
    ;
        Turnover = tick_out,
        Ended = [],
        Held = Delta ^ md_removed,
        Unclaimed = []
    ;
        Turnover = tick_in(Carried, Ticks),
        Ended = Delta ^ md_removed,
        Held = [],
        TMS0 = !.E ^ en_tms,
        list.foldl2(claim_carried(Ticks, Delta ^ md_added), Carried,
            [], Unclaimed, TMS0, TMS1),
        !E ^ en_tms := TMS1
    ),
    list.foldl2(end_justifications, Ended, [], Cascaded0, !E),

    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: the cascade raised an EngineError; this change stops.
        Cascaded = Cascaded0
    else
        list.foldl(queue_activation, Delta ^ md_added, !E),

        % After this tick's activations are queued.
        list.foldl2(end_justifications, Unclaimed, Cascaded0, Cascaded, !E)
    ),
    % The expired cache entries the match read go now, each with its notification,
    % in the order first read [NSTG.2.4.2].
    list.foldl(cache_delete, Delta ^ md_expired, !.E ^ en_cache, Cache),
    !E ^ en_cache := Cache,
    % The pairs the event derived [LERR.1.4.12], against the network as the event
    % left it; none from a change whose cascade halted.
    E0 = !.E,
    ( if E0 ^ en_halted = yes(_) then
        Derived = []
    else
        Derived = lerr_1_4_12_derived(E0 ^ en_index, E0 ^ en_rete,
            terminal_ordinal(E0), Delta ^ md_faults)
    ),
    FaultEvents = list.map((func(K) = eff_cache_expired(K)), Delta ^ md_expired)
        ++ list.map(match_fault_event, Derived),
    Effects = Cascaded,
    lerr_1_4_7_raise(FaultEvents, !E).

    % A terminal's place in the firing order [LDET.5.4].
    %
:- func terminal_ordinal(engine, node_id) = maybe(source_index).

terminal_ordinal(E, Terminal) =
    ( if map.search(E ^ en_metas, node_id_value(Terminal), Meta) then
        yes(Meta ^ rm_source)
    else
        no
    ).

    % Hand a carried activation's justification to the activation the new tick
    % re-formed from the same match: the same terminal, the same facts but the
    % tick alone, since two `$Timer_` facts of one rule are two matches. With no
    % successor it has ended.
    %
:- pred claim_carried(list(fact_id)::in, list(activation)::in, activation::in,
                      list(activation)::in, list(activation)::out,
                      tms::in, tms::out) is det.

claim_carried(Ticks, Added, Old, !Unclaimed, !TMS) :-
    ( if
        list.find_first_match(same_match(Ticks, Old), Added, New)
    then
        carried_over(Old, New, !TMS)
    else
        !:Unclaimed = !.Unclaimed ++ [Old]
    ).

:- pred same_match(list(fact_id)::in, activation::in, activation::in)
    is semidet.

same_match(Ticks, Old, New) :-
    Old ^ ac_terminal = New ^ ac_terminal,
    NotTick = (pred(F::in) is semidet :- not list.member(F, Ticks)),
    list.filter(NotTick, Old ^ ac_token ^ t_facts, OldFacts),
    list.filter(NotTick, New ^ ac_token ^ t_facts, NewFacts),
    OldFacts = NewFacts.

    % A fault a join test or an alpha test raised, as the same event as a fault in
    % an action. Its site and rule name are the node's [LERR.9.11].
    %
:- func match_fault_event(match_fault) = effect.

match_fault_event(match_fault(Node, Site, Fault, Origin, _, _)) =
    eff_event(se_engine_error(ee_expr_fault(Fault),
        origin_site((no_site ^ fs_node := yes(Node)) ^ fs_rule := Rule,
            Origin))) :-
    (
        Site = ms_alpha,
        Rule = fr_alpha(Node)
    ;
        Site = ms_beta,
        Rule = fr_beta(Node)
    ).

%-----------------------------------------------------------------------------%
% Fault facts -- [LERR.9]
%-----------------------------------------------------------------------------%
%
% A `TypeError` or `ComputationError` is recorded where it is raised, then
% asserted as a fact of the built-in schema of the same name [LERR.9.1]. The
% effect list is the queue: the drain reads a step's effects in order [LERR.9.7].
% It runs before each agenda selection (`pump_loop`) and as a host call returns
% (`host_drain`).
%
% A program without the schemas asserts nothing.

:- pred drain_fault_facts(list(effect)::in, list(effect)::out,
                          engine::in, engine::out) is det.

drain_fault_facts(Raised, Asserted, !E) :-
    Pending = lerr_9_7_pending(!.E, Raised),
    list.foldl2(drain_one, Pending, [], Rev, !E),
    Asserted = list.condense(list.reverse(Rev)).

    % One fault awaiting assertion: TypeError or not, the fault, its site.
    %
:- type pending_fault ---> pending_fault(bool, runtime_fault, fault_site).

    % At most one fault pending per `(node, rule)` site: a later fault replaces it
    % in place, whichever schema either is, keeping the order sites first faulted.
    % Handler sites [LERR.9.6] are dropped first.
    %
%@spec [LERR.9.7]
:- func lerr_9_7_pending(engine, list(effect)) = list(pending_fault).

lerr_9_7_pending(E, Raised) = Pending :-
    list.foldl2(lerr_9_7_coalesce(E), Raised, [], RevOrder, map.init, BySite),
    Pending = list.map(map.lookup(BySite), list.reverse(RevOrder)).

:- pred lerr_9_7_coalesce(engine::in, effect::in,
    list({uint32, string})::in, list({uint32, string})::out,
    map({uint32, string}, pending_fault)::in,
    map({uint32, string}, pending_fault)::out) is det.

lerr_9_7_coalesce(E, Effect, !Order, !BySite) :-
    ( if
        Effect = eff_event(se_engine_error(ee_expr_fault(Fault), Site)),
        Class = expr_fault_class(Fault),
        ( Class = fc_computation ; Class = fc_type ),
        not handler_site(E, Site)
    then
        TypeError = ( if Class = fc_type then yes else no ),
        Node = ( if Site ^ fs_node = yes(N) then node_id_value(N) else 0u32 ),
        Key = {Node, fault_rule_name(E ^ en_interns, Site ^ fs_rule)},
        ( if map.contains(!.BySite, Key) then
            true
        else
            !:Order = [Key | !.Order]
        ),
        !:BySite = map.set(!.BySite, Key, pending_fault(TypeError, Fault, Site))
    else
        true
    ).

:- pred drain_one(pending_fault::in,
                  list(list(effect))::in, list(list(effect))::out,
                  engine::in, engine::out) is det.

drain_one(pending_fault(TypeError, Fault, Site), !Acc, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: a fault fact drained before this one raised an EngineError.
        true
    else
        assert_fault_fact(TypeError, Fault, Site, Effects, !E),
        !:Acc = [Effects | !.Acc]
    ).

:- pred handler_site(engine::in, fault_site::in) is semidet.

handler_site(E, Site) :-
    Site ^ fs_node = yes(Node),
    set.member(node_id_value(Node), E ^ en_fault_handlers).

    % One fault fact [LERR.9.2]: `kind` the TrapKind's name without `TRAP_`,
    % `actual` the tag the value had, `rule` the fault's rule name, `schema` and
    % `slot` what the offending operand was read from, "" where it was not a slot
    % read, and `node` the raising node, 0 with none.
    %
:- pred assert_fault_fact(bool::in, runtime_fault::in, fault_site::in,
                          list(effect)::out, engine::in, engine::out) is det.

assert_fault_fact(TypeError, Fault, Site, Effects, !E) :-
    ( if
        fault_schema(!.E, TypeError, Schema),
        list.length(slot_commons(Schema)) = 5
    then
        IT0 = !.E ^ en_interns,
        Rule = fault_rule_name(IT0, Site ^ fs_rule),
        What = ( if TypeError = yes then
                    ( if Site ^ fs_actual = yes(A) then A else "" )
                 else trap_kind_name(expr_trap_kind(Fault)) ),
        SchemaText = ref_text(IT0, Site ^ fs_schema),
        SlotText = ref_text(IT0, Site ^ fs_slot),
        Node = ( if Site ^ fs_node = yes(N)
                 then int64.from_int(uint32.cast_to_int(node_id_value(N)))
                 else 0i64 ),
        engine_intern(What, WhatRef, !E),
        engine_intern(Rule, RuleRef, !E),
        engine_intern(SchemaText, SchemaRef, !E),
        engine_intern(SlotText, SlotRef, !E),
        ByName = map.from_assoc_list([
            ( if TypeError = yes then "actual" else "kind" ) - str(WhatRef),
            "rule" - str(RuleRef),
            "schema" - str(SchemaRef),
            "slot" - str(SlotRef),
            "node" - int(Node)]),
        ( if
            list.map(slot_value(!.E ^ en_interns, ByName), slot_commons(Schema),
                Values)
        then
            Key = {TypeError, uint32.det_from_int(int64.cast_to_int(Node)),
                Rule},
            latched_assert(Schema, Key, Values, Effects, !E)
        else
            % Not the built-in's shape.
            Effects = []
        )
    else
        Effects = []
    ).

:- pred slot_value(intern_table::in, map(string, ds_value)::in,
                   slot_common::in, ds_value::out) is semidet.

slot_value(IT, ByName, C, V) :-
    expand(IT, C ^ sc_name, Name),
    map.search(ByName, Name, V).

:- func ref_text(intern_table, maybe(intern_ref)) = string.

ref_text(IT, MaybeRef) =
    ( if MaybeRef = yes(Ref), expand(IT, Ref, T) then T else "" ).

    % `TrapKind` (`proto/engine_error.proto`) by number, without `TRAP_`.
    %
:- func trap_kind_name(uint32) = string.

trap_kind_name(N) =
    ( if N = 1u32 then "DIVIDE_BY_ZERO"
    else if N = 2u32 then "DOMAIN"
    else if N = 3u32 then "NOT_REPRESENTABLE"
    else "" ).

:- pred fault_schema(engine::in, bool::in, schema::out) is semidet.

fault_schema(E, TypeError, Schema) :-
    Name = ( if TypeError = yes then "TypeError" else "ComputationError" ),
    interned(E ^ en_interns, Name, Ref),
    Match = (pred(S::in) is semidet :- schema_name_ref(S ^ s_name) = Ref),
    list.find_first_match(Match, map.values(E ^ en_schemas), Schema).

    % [LERR.9.5]: the site's live fault fact, if any: equal is a no-op, different
    % is a retract (`rc_supersede`) and a fresh assert. The events are a rule
    % `emit`'s, so the recorder writes a `FactEmit` [LERR.9.8].
    %
:- pred latched_assert(schema::in, fault_site_key::in, list(ds_value)::in,
                       list(effect)::out, engine::in, engine::out) is det.

latched_assert(Schema, Key, Values, Effects, !E) :-
    ( if
        map.search(!.E ^ en_fault_latch, Key, Live),
        lookup_fact(!.E ^ en_wm, Live, LiveFact)
    then
        ( if array.to_list(LiveFact ^ f_slots) = Values then
            Effects = []
        else
            retract_one_fact(Live, rc_supersede, Dropped, !E),
            ( if !.E ^ en_halted = yes(_) then
                % [LERR.1.4.7].
                Effects = Dropped
            else
                insert_fault_fact(Schema, Key, Values, Inserted, !E),
                Effects = Dropped ++ Inserted
            )
        )
    else
        insert_fault_fact(Schema, Key, Values, Effects, !E)
    ).

:- pred insert_fault_fact(schema::in, fault_site_key::in, list(ds_value)::in,
                          list(effect)::out, engine::in, engine::out) is det.

insert_fault_fact(Schema, Key, Values, Effects, !E) :-
    assert_fact(Schema, Values, clock_now(!.E ^ en_clock), no, tms_none, live,
        Result, !.E ^ en_wm, WM),
    ( if ( Result = inserted(Id) ; Result = replaced(_, Id) ) then
        !E ^ en_wm := WM,
        !E ^ en_fault_latch := map.set(!.E ^ en_fault_latch, Key, Id),
        settle_fact_split(asserted(Id), Faults, Cascade, !E),
        Effects = Faults ++ Cascade ++
            [eff_event(se_fact_assert(Id, Schema ^ s_id, Values, no)),
             eff_event(se_emit(Id, Schema ^ s_id))]
    else
        Effects = []
    ).

    % A host assert refused by `wm_max`: the cap, and the live count the insert
    % would have reached, the candidate memory's.
    %
:- func host_wm_site(engine, wm) = fault_site.

host_wm_site(E, WM) = no_site ^ fs_bound := Bound :-
    ( if E ^ en_contract = yes(RT) then
        Bound = yes(fault_bound(
            uint64.det_from_int(uint32.cast_to_int(RT ^ c_wm_max)),
            uint64.det_from_int(
                lerr_9_10_capacity_count(WM, E ^ en_fault_schemas))))
    else
        Bound = no
    ).

:- pred end_justifications(activation::in, list(effect)::in, list(effect)::out,
                           engine::in, engine::out) is det.

end_justifications(Activation, !Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: the cascade stops at the halt, between activations.
        true
    else
        activation_ended(Activation, Unsupported, !.E ^ en_tms, TMS),
        !E ^ en_tms := TMS,
        list.foldl2(retract_unsupported, Unsupported, !Effects, !E)
    ).

    % Retract a fact that has lost its last justification, and cascade. Each round
    % of this recursion through `settle_fact` removes a fact, so it terminates.
    %
:- pred retract_unsupported(fact_id::in, list(effect)::in, list(effect)::out,
                            engine::in, engine::out) is det.

retract_unsupported(FactId, !Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [LERR.1.4.7]: the cascade stops at the halt, between facts.
        true
    else if retract_fact(FactId, rc_justifier_end, !.E ^ en_wm, WM) then
        !E ^ en_wm := WM,
        !:Effects = !.Effects ++
            [eff_event(se_fact_withdraw(FactId, rc_justifier_end))],
        settle_fact(retracted(FactId), More, !E),
        !:Effects = !.Effects ++ More
    else
        % Already gone.
        true
    ).

:- pred queue_activation(activation::in, engine::in, engine::out) is det.

queue_activation(Activation, !E) :-
    ( if meta_for(!.E, Activation, Meta) then
        Key = order_key_of(Meta, Activation ^ ac_token ^ t_created),
        ( if enqueue(Key, Activation, !.E ^ en_agenda, Agenda) then
            !E ^ en_agenda := Agenda
        else
            % A duplicate order key is dropped, unreported.
            true
        )
    else
        % No rule metadata: unreachable from a loaded artefact.
        true
    ).

:- pred withdraw_activation(activation::in, engine::in, engine::out) is det.

withdraw_activation(Activation, !E) :-
    ( if
        meta_for(!.E, Activation, Meta),
        Key = order_key_of(Meta, Activation ^ ac_token ^ t_created),
        withdraw(Key, !.E ^ en_agenda, Agenda)
    then
        !E ^ en_agenda := Agenda
    else
        % Already fired, or never queued.
        true
    ).

:- pred meta_for(engine::in, activation::in, rule_meta::out) is semidet.

meta_for(E, Activation, Meta) :-
    map.search(E ^ en_metas, node_id_value(Activation ^ ac_terminal), Meta).

%-----------------------------------------------------------------------------%
% The pump
%-----------------------------------------------------------------------------%

pump_unstamped(Budget, Effects, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % [NCBK.2.9].
        Effects = []
    else if nlfc_9_5_first_sample_out_of_range(!.E) then
        % [NLFC.9.5]: refused before its step, the engine left as it was.
        Effects = [eff_pump_status(ps_time_range)]
    else
        pump_live(Budget, Effects, !E)
    ).

:- pred pump_live(fire_budget::in, list(effect)::out,
                  engine::in, engine::out) is det.

pump_live(Budget, Effects, !E) :-
    % The pump's one sample, first [LTIM.2.8.4].
    clock_step(step_pump, Tick0, Raised0, Outcome, !E),
    stamp_step(Tick0, Tick, !E),
    % [RFCS.22]: after the tick, before anything the pump records.
    stamp_step([eff_event(se_pump_boundary)], Boundary, !E),
    (
        Outcome = initial_refused(Cap, Site),
        % [LGRA.24.3]: the block refused the step: the boundary, the `BoundsError`,
        % and no rule, root seeding, sweep or tick.
        stamp_step([eff_event(se_engine_error(ee_contract_breach(Cap), Site))],
            Refusal, !E),
        Effects = Tick ++ Boundary ++ Refusal,
        latch_from(Effects, !E)
    ;
        Outcome = initial_applied,
        stamp_step(Raised0, Raised, !E),
        pump_admitted(Budget, Raised0, Tick,
            lgra_24_3_after_input(Raised, Boundary), Effects, !E)
    ).

    % The pump once its step is admitted. `Input` holds the boundary and the
    % `initial` block's faults, stamped; `Raised0` is those faults as raised, which
    % the first selection drains.
    %
:- pred pump_admitted(fire_budget::in, list(effect)::in, list(effect)::in,
                      list(effect)::in, list(effect)::out,
                      engine::in, engine::out) is det.

pump_admitted(Budget, Raised0, Tick, Input, Effects, !E) :-
    seed_once(!E),
    sweep_expired(Swept, !E),
    % [LERR.1.4.7]: a stage that raised an EngineError is the pump's last.
    ( if list.find_first_match(latching, Swept, _) then
        CacheExpired = [],
        Ticked = [],
        Gauges = []
    else
        sweep_cache(CacheExpired, !E),
        cycle_clock_tick(Ticked, !E),
        % [NMET.4.1]: each pump, before the first selection.
        ( if list.find_first_match(latching, Ticked, _) then
            Gauges = []
        else
            Gauges = intern_gauges(!.E)
        )
    ),
    % `pump_loop` filters and stamps each segment it is handed, this one first;
    % `en_synth` is pruned at the end, so it names every synthetic fact this pump
    % has touched.
    pump_loop(Budget, Budget, [], Raised0,
        Swept ++ CacheExpired ++ Ticked ++ Gauges, Fired, !E),
    ( if list.find_first_match(latching, Fired, _) then
        true
    else
        !E ^ en_matched := !.E ^ en_series,
        absorb_series(!E)
    ),
    Effects = Tick ++ Input ++ Fired,
    prune_synthetic(!E),
    latch_from(Effects, !E).

    % [RDSC.4a.7]'s nil token into every root beta, before the TTL sweep and the
    % clock tick, so a root NOT node counts the working memory the pump started
    % with. A seed removes no activation, so only `md_added` is absorbed.
    %
:- pred seed_once(engine::in, engine::out) is det.

seed_once(!E) :-
    (
        !.E ^ en_seeded = yes
    ;
        !.E ^ en_seeded = no,
        Ctx = match_ctx(!.E ^ en_wm, !.E ^ en_schemas, !.E ^ en_interns,
            clock_now(!.E ^ en_clock), clock_wall(!.E ^ en_clock),
            !.E ^ en_cache, !.E ^ en_series),
        seed_roots(!.E ^ en_index, Ctx, Delta, !.E ^ en_rete, Rete),
        !E ^ en_rete := Rete,
        list.foldl(queue_activation, Delta ^ md_added, !E),
        !E ^ en_seeded := yes
    ).

    % Drop dead ids from the synthetic set. `engine_fact_count` subtracts its size.
    %
:- pred prune_synthetic(engine::in, engine::out) is det.

prune_synthetic(!E) :-
    WM = !.E ^ en_wm,
    Live = (pred(Id::in) is semidet :- lookup_fact(WM, make_fact_id(Id), _)),
    !E ^ en_synth := set.filter(Live, !.E ^ en_synth).

    % Retract the previous `$ClockTick` fact and assert a fresh one, after the TTL
    % sweep. A new fact makes a new token, so an `after` follow-up terminal
    % re-activates each pump to re-check whether `fire_at` has passed. A no-op when
    % the program declares no `$ClockTick` schema.
    %
:- pred cycle_clock_tick(list(effect)::out, engine::in, engine::out) is det.

cycle_clock_tick(Effects, !E) :-
    ( if clock_tick_schema(!.E, Schema) then
        ( if
            !.E ^ en_tick = yes(Old),
            retract_fact(Old, rc_explicit, !.E ^ en_wm, WM0)
        then
            !E ^ en_wm := WM0,
            settle_turnover(retracted(Old), tick_out, OutFaults, OutCascade,
                Carried, !E),
            Dropped = [eff_event(removal_event(Old, rc_explicit))]
                ++ OutFaults ++ OutCascade,
            OldTicks = [Old]
        else
            Dropped = [],
            Carried = [],
            OldTicks = []
        ),
        ( if !.E ^ en_halted = yes(_) then
            % [LERR.1.4.7]: the old tick's retract raised an EngineError.
            Asserted = []
        else
            assert_fact(Schema, [], clock_now(!.E ^ en_clock), no, tms_none,
                live, Result, !.E ^ en_wm, WM),
            !E ^ en_wm := WM,
            cycle_new_tick(Schema, Result, Carried, OldTicks, Asserted, !E)
        ),
        Effects = Dropped ++ Asserted
    else
        Effects = []
    ).

    % The fresh tick `cycle_clock_tick` asserted, propagated here since this is no
    % firing for `settle_effect` to drive.
    %
:- pred cycle_new_tick(schema::in, assert_result::in, list(activation)::in,
                       list(fact_id)::in, list(effect)::out,
                       engine::in, engine::out) is det.

cycle_new_tick(Schema, Result, Carried, OldTicks, Asserted, !E) :-
    ( if
        ( Result = inserted(NewId) ; Result = replaced(_, NewId) )
    then
        !E ^ en_tick := yes(NewId),
        note_synthetic(Schema, NewId, !E),
        Turnover = tick_in(Carried, [NewId | OldTicks]),
        settle_turnover(asserted(NewId), Turnover, Faults, Cascade, _, !E),
        Asserted = Faults ++
            [eff_event(se_fact_assert(NewId, Schema ^ s_id, [], no))] ++
            Cascade
    else
        % With no new tick, nothing re-forms a carried match.
        list.foldl2(end_justifications, Carried, [], Asserted, !E)
    ).

:- pred clock_tick_schema(engine::in, schema::out) is semidet.

clock_tick_schema(E, Schema) :-
    interned(E ^ en_interns, clock_tick_name, Ref),
    Match = (pred(S::in) is semidet :- schema_name_ref(S ^ s_name) = Ref),
    list.find_first_match(Match, map.values(E ^ en_schemas), Schema).

:- pred retract_one_fact(fact_id::in, retract_cause::in, list(effect)::out,
                         engine::in, engine::out) is det.

retract_one_fact(FactId, Cause, Effects, !E) :-
    ( if retract_fact(FactId, Cause, !.E ^ en_wm, WM) then
        !E ^ en_wm := WM,
        settle_fact(retracted(FactId), Cascade, !E),
        Effects = [eff_event(removal_event(FactId, Cause))] ++ Cascade
    else
        Effects = []
    ).

    % The end-of-pump series sweep. It emits nothing. Each fact is sampled once:
    % `en_absorbed` holds the facts already walked. A fact an identity upsert
    % replaced before the sweep reached it is parked by `ds.wm` and taken here,
    % oldest first, before the live facts.
    %
:- pred absorb_series(engine::in, engine::out) is det.

absorb_series(!E) :-
    % Taken every pump, series or not, so the parked list cannot grow.
    take_superseded(Parked, !.E ^ en_wm, WM),
    !E ^ en_wm := WM,
    Decls = !.E ^ en_sdecls,
    (
        Decls = []
    ;
        Decls = [_ | _],
        Now = clock_now(!.E ^ en_clock),
        list.foldl(absorb_decl(!.E, Now, Parked), Decls, !.E ^ en_series,
            Series),
        !E ^ en_series := Series,
        !E ^ en_absorbed := walked(!.E, Decls)
    ).

    % Every live fact of a schema some series observes: the only ones a later
    % sweep could meet again.
    %
:- func walked(engine, list(series_decl)) = set(uint64).

walked(E, Decls) = list.foldl(walked_schema(E), Names, set.init) :-
    Names = list.sort_and_remove_dups(list.map(decl_schema, Decls)).

:- func decl_schema(series_decl) = string.

decl_schema(D) = D ^ sd_schema.

:- func walked_schema(engine, string, set(uint64)) = set(uint64).

walked_schema(E, Name, Walked) =
    ( if schema_named(E, Name, Schema) then
        list.foldl((func(F, W) = set.insert(W, fact_id_value(F ^ f_id))),
            facts_of_schema(E ^ en_wm, Schema ^ s_id), Walked)
      else
        Walked ).

    % The facts not yet walked: the parked ones of this schema, oldest first, then
    % the live ones in insertion order.
    %
:- pred absorb_decl(engine::in, instant::in, list(fact)::in, series_decl::in,
                    series_state::in, series_state::out) is det.

absorb_decl(E, Now, Parked, Decl, !S) :-
    ( if schema_named(E, Decl ^ sd_schema, Schema) then
        Walked = E ^ en_absorbed,
        Unwalked = (pred(F::in) is semidet :-
            F ^ f_schema = Schema ^ s_id,
            not set.contains(Walked, fact_id_value(F ^ f_id))),
        Facts = list.filter(Unwalked,
            Parked ++ facts_of_schema(E ^ en_wm, Schema ^ s_id)),
        list.foldl(absorb_fact(E ^ en_interns, Schema, Now, Decl), Facts, !S)
    else
        % A dangling backing, which the loader refuses [RDSC.8.7].
        true
    ).

:- pred schema_named(engine::in, string::in, schema::out) is semidet.

schema_named(E, Name, Schema) :-
    interned(E ^ en_interns, Name, Ref),
    find_schema(map.values(E ^ en_schemas), Ref, Schema).

:- pred find_schema(list(schema)::in, intern_ref::in, schema::out) is semidet.

find_schema([S | Ss], Ref, Found) :-
    ( if schema_name_ref(S ^ s_name) = Ref then
        Found = S
    else
        find_schema(Ss, Ref, Found)
    ).

    % [NFCT.1.1]: by name [RDSC.5.2], since a host's `schema` value may carry any
    % `schema_id`.
    %
:- pred nfct_1_1_registered(engine::in, schema::in) is semidet.

nfct_1_1_registered(E, Schema) :-
    list.find_first_match(
        ( pred(Known::in) is semidet :-
            Known ^ s_name = Schema ^ s_name
        ), map.values(E ^ en_schemas), _).

    % Absorb a fact the sweep has not walked before (`absorb_decl`).
    %
:- pred absorb_fact(intern_table::in, schema::in, instant::in,
                    series_decl::in, fact::in,
                    series_state::in, series_state::out) is det.

absorb_fact(Interns, Schema, _Now, Decl, Fact, !S) :-
    ( if
        % [RHIM.5.3]: a hydrated fact is not absorbed.
        Fact ^ f_hydrated = live,
        slot_text_value(Interns, Schema, Fact, Decl ^ sd_slot, Read),
        identity_text(Interns, Schema, Fact, Decl ^ sd_id_slot, Id),
        % [RDSC.5a.8.1]: this atom's window, so each window has its own row.
        Key = series_key(Decl ^ sd_schema, Decl ^ sd_slot,
            Decl ^ sd_id_slot, Id, Decl ^ sd_window),
        lnul_8_6_sample(Interns, Schema, Decl, Key, !.S, Read, Value)
    then
        absorb(Decl, Key, Value, Fact ^ f_asserted, !.S, !:S)
    else
        true
    ).

    % The value a reading absorbs, if any. A sample-able value is itself. A `null`
    % becomes the row's last absorbed value under `hold`, the slot's zero under
    % `zero`, and nothing under `skip` or on a non-nullable source.
    %
    %@spec [LNUL.8.6]
:- pred lnul_8_6_sample(intern_table::in, schema::in, series_decl::in,
                        series_key::in, series_state::in, ds_value::in,
                        ds_value::out) is semidet.

lnul_8_6_sample(Interns, Schema, Decl, Key, State, Read, Value) :-
    ( if sampleable(Read) then
        Value = Read
    else
        Read = null,
        Policy = Decl ^ sd_nulls,
        (
            Policy = np_hold,
            held_value(Key, State, Value)
        ;
            Policy = np_zero,
            interned(Interns, Decl ^ sd_slot, Ref),
            slot_by_name(Schema, Ref, Common),
            lnul_8_6_zero(Common ^ sc_kind, Value)
        )
    ).

    %@helper
:- pred lnul_8_6_zero(slot_kind::in, ds_value::out) is semidet.

lnul_8_6_zero(k_int, int(0i64)).
lnul_8_6_zero(k_float, float(0.0)).

    % Retract every fact whose deadline has passed, at pump entry: one
    % `se_fact_withdraw(_, rc_ttl)` per expiry, which a replayer re-derives
    % [RFCS.7a].
    %
:- pred sweep_expired(list(effect)::out, engine::in, engine::out) is det.

sweep_expired(Effects, !E) :-
    Now = clock_now(!.E ^ en_clock),
    expire(Now, Expired, !.E ^ en_wm, WM),
    !E ^ en_wm := WM,
    list.foldl2(settle_expiry, Expired, [], ExpiryCascade, !E),
    Effects = list.map(expiry_event, Expired) ++ ExpiryCascade.

    % Drop every cache entry whose deadline has passed [NSTG.2.4.2], at pump entry,
    % after the fact sweep and before `$ClockTick`: one `eff_cache_expired` per
    % entry, in the order the keys were last set [LDET.5.11].
    %
:- pred sweep_cache(list(effect)::out, engine::in, engine::out) is det.

sweep_cache(Effects, !E) :-
    cache_sweep(clock_now(!.E ^ en_clock), Expired, !.E ^ en_cache, Cache),
    !E ^ en_cache := Cache,
    Effects = list.map((func(K) = eff_cache_expired(K)), Expired).

    % `Carried` is the `initial` block's faults [LTIM.2.8.3], already stamped, so
    % drained here and not stamped again. Empty after the first selection.
    %
:- pred pump_loop(fire_budget::in, fire_budget::in,
                  list(effect)::in, list(effect)::in, list(effect)::in,
                  list(effect)::out, engine::in, engine::out) is det.

pump_loop(Configured, Remaining, Acc0, Carried, Step, Effects, !E) :-
    ( if
        Observed1 = observable(!.E, Step),
        list.find_first_match(latching, Observed1, _)
    then
        % [LERR.1.4.7]: an EngineError ends the pump where it was raised. The
        % segment is cut before stamping, no fault fact is drained and no
        % activation selected; the agenda stays as it is.
        stamp_step(lerr_1_4_7_last_record(Observed1), Observed, !E),
        Effects = Acc0 ++ Observed
    else
        pump_loop_on(Configured, Remaining, Acc0, Carried, Step, Effects, !E)
    ).

:- pred pump_loop_on(fire_budget::in, fire_budget::in,
                     list(effect)::in, list(effect)::in, list(effect)::in,
                     list(effect)::out, engine::in, engine::out) is det.

pump_loop_on(Configured, Remaining, Acc0, Carried, Step, Effects, !E) :-
    % [LERR.9.7]: the fault facts of `Step` are asserted before the next selection.
    % Stamped now, since a later firing's `call` may hand on what it emitted.
    Observed0 = observable(!.E, Step),
    stamp_step(Observed0, Observed, !E),
    drain_fault_facts(Carried ++ Observed0, Drained0, !E),
    stamp_step(observable(!.E, Drained0), Drained, !E),
    Acc = Acc0 ++ Observed ++ Drained,
    ( if Remaining = fire_budget(Left), Left =< 0 then
        % Stop, report, and leave the survivors queued for the next pump. The
        % limit is the caller's, not a contract's.
        ( if agenda_count(!.E ^ en_agenda) > 0 then
            stamp_step([eff_event(se_engine_error(
                ee_fire_budget_exceeded(limit_of(Configured)), no_site))],
                Trip, !E),
            Effects = Acc ++ Trip
        else
            Effects = Acc
        )
    else
        select_guarded(!.E ^ en_refract, !.E ^ en_synth,
            guarded_terminals(!.E), Selection, !.E ^ en_agenda, Agenda),
        !E ^ en_agenda := Agenda,
        (
            Selection = nothing_to_fire,
            Effects = Acc
        ;
            Selection = fire(_Key, Activation),
            fire_one(Activation, Fired, !E),
            pump_loop(Configured, spend(Remaining), Acc, [], Fired, Effects,
                !E)
        )
    ).

:- func spend(fire_budget) = fire_budget.

spend(fire_budget(N)) = fire_budget(N - 1).
spend(no_fire_limit) = no_fire_limit.

:- func limit_of(fire_budget) = int.

limit_of(fire_budget(N)) = N.
limit_of(no_fire_limit) = 0.

    % The terminals whose rule has a maturity guard, by raw node id: the ones
    % `select_guarded` hands out without consulting refraction, so `fire_one`
    % can read the guard first ([LTIM.2.5.1]).
    %
:- func guarded_terminals(engine) = set(uint32).

guarded_terminals(E) = map.foldl(
    ( func(Terminal, Meta, S) =
        ( if maturity_guarded(Meta) then set.insert(S, Terminal) else S ) ),
    E ^ en_metas, set.init).

:- pred fire_one(activation::in, list(effect)::out, engine::in, engine::out)
    is det.

fire_one(Activation, Effects, !E) :-
    ( if meta_for(!.E, Activation, Meta) then
        Ctx = exec_ctx(!.E ^ en_schemas, clock_now(!.E ^ en_clock),
            clock_wall(!.E ^ en_clock), Meta, !.E ^ en_contract,
            !.E ^ en_cache_caps, !.E ^ en_hydration_budget,
            !.E ^ en_sdecls, !.E ^ en_fault_schemas,
            !.E ^ en_service_responses, frame_of(!.E, Activation)),
        State0 = exec_state(!.E ^ en_wm, !.E ^ en_tms, !.E ^ en_cache,
            !.E ^ en_series, !.E ^ en_rate, bool.no,
            !.E ^ en_interns, !.E ^ en_gensym,
            [], [], !.E ^ en_act_attach),
        ( if maturity_guarded(Meta) then
            % The guard first, then refraction: its condition is read under this
            % pump's sample every pump [LTIM.2.5.1].
            check_guard(Ctx, Activation, State0, Check),
            (
                Check = gc_admits,
                ( if
                    is_refracted(!.E ^ en_refract, !.E ^ en_synth, Activation)
                then
                    Effects = []
                else
                    fire_admitted(Activation, Meta, Ctx, State0, Effects, !E)
                )
            ;
                Check = gc_denies,
                end_match(Activation, Ended, !E),
                Effects = Ended
            ;
                % The match ends as on a `false`, after the fault's record.
                Check = gc_faulted(Faults),
                end_match(Activation, Ended, !E),
                Effects = Faults ++ Ended
            )
        else
            fire_admitted(Activation, Meta, Ctx, State0, Effects, !E)
        )
    else
        Effects = []
    ).

    % [LTIM.2.5.1]: a maturity guard false or faulting under this pump's sample
    % ends the match, so the next false -> true edge fires anew. What the match
    % justified is retracted now [LLOG.3.11.1], since its token stands and no
    % removal will end it. `Effects` is the cascade.
    %
:- pred end_match(activation::in, list(effect)::out, engine::in, engine::out)
    is det.

end_match(Activation, Effects, !E) :-
    !E ^ en_refract := forget(!.E ^ en_synth, Activation, !.E ^ en_refract),
    end_justifications(Activation, [], Effects, !E).

:- pred fire_admitted(activation::in, rule_meta::in, exec_ctx::in,
                      exec_state::in, list(effect)::out,
                      engine::in, engine::out) is det.

fire_admitted(Activation, _Meta, Ctx, State0, Effects, !E) :-
        Terminal = node_id_value(Activation ^ ac_terminal),
        Actions = ( if map.search(!.E ^ en_actions, Terminal, As) then As
                    else [] ),
        fire(Ctx, Activation, Actions, settle_actions, Fired, State0, State,
            !E),

        !E ^ en_wm := State ^ xs_wm,
        !E ^ en_tms := State ^ xs_tms,
        !E ^ en_cache := State ^ xs_cache,
        !E ^ en_rate := State ^ xs_rate,
        !E ^ en_interns := State ^ xs_interns,
        !E ^ en_gensym := State ^ xs_gensym,
        !E ^ en_act_attach := State ^ xs_act_attach,

        % Every firing emits at least its frame, so `Fired` is empty only for one
        % that did not happen [LTAC.4.2].
        ( if Fired = [] then
            true
        else
            latch(!.E ^ en_synth, Activation, !.E ^ en_refract, Refract),
            !E ^ en_refract := Refract
        ),

        % `fire` settled each action through `settle_actions`, so the cascade is
        % already in `Fired`.
        Effects = Fired.

    % Propagate one action's fact changes, passed to `ds.exec.fire`. The executor's
    % working memory goes in, and comes back with what propagation retracted, for
    % the next action to run against.
    %
:- pred settle_actions(list(effect)::in, list(effect)::out, list(effect)::out,
                       exec_state::in, exec_state::out,
                       engine::in, engine::out) is det.

settle_actions(Own, Kept, Cascade, !S, !E) :-
    % The state after the previous action, for a capacity breach to restore.
    E0 = !.E,
    !E ^ en_wm := !.S ^ xs_wm,
    !E ^ en_tms := !.S ^ xs_tms,
    !E ^ en_cache := !.S ^ xs_cache,
    % Not written back: propagation never interns.
    !E ^ en_interns := !.S ^ xs_interns,
    list.foldl2(settle_effect, Own, [], Settled, !E),
    % [RTCT.7]: an emitted fact can overfill a node or the agenda. Refused, it
    % never entered: its events go, and the next action runs without it.
    ( if over_capacity(!.E, Cap) then
        Site = capacity_site(!.E, Cap),
        !:E = E0,
        !S ^ xs_wm := E0 ^ en_wm,
        !S ^ xs_tms := E0 ^ en_tms,
        !S ^ xs_capped := bool.yes,
        Kept = [],
        Cascade = [eff_event(se_engine_error(ee_contract_breach(Cap), Site))]
    else
        Kept = Own,
        Cascade = Settled,
        !S ^ xs_wm := !.E ^ en_wm,
        !S ^ xs_tms := !.E ^ en_tms
    ).

:- pred note_synthetic(schema::in, fact_id::in, engine::in, engine::out) is det.

note_synthetic(Schema, FactId, !E) :-
    ( if synthetic(!.E ^ en_interns, Schema) then
        !E ^ en_synth := set.insert(!.E ^ en_synth, fact_id_value(FactId))
    else
        true
    ).

    % The effects a host sees: all but the fact events of a compiler-synthesised
    % schema, which `settle_effect` still needed. A synthetic rule's firing frame
    % stays.
    %
:- func observable(engine, list(effect)) = list(effect).

observable(E, Effects) = Out :-
    list.filter_map(observable_effect(E), Effects, Out).

engine_halted(E) = E ^ en_halted.

    % The kind [NFCT.2.3] pairs with the slot's type: an `Int` for one stored as
    % an integer, a `Duration`'s nanoseconds among them, a `Float` for one
    % stored as a float. A slot that names a unit has no other type. The input
    % is `bind_ref` 0 as a rule's `x::<unit>`, or its kwarg conversion, reads
    % it, and the result is the stored number or the number in the unit, of
    % that same kind ([RDSC.5.5.9]). The frame has that one slot
    % ([RDSC.4a.9.6]).
    %
    % An EngineError the conversion raises is raised as any public call
    % raises one ([NCBK.2.9]): the event, which names no node and the
    % `$engine` rule, since no rule's evaluation holds it ([LERR.9.11]), then
    % the halt. Any other fault, a result of another kind and a NaN are each
    % NOT_REPRESENTABLE: the conversion raised where a rule's evaluation
    % would ([LERR.1.4]), and no event, fault fact or halt follows from it.
    %
nfct_1_4_6_convert(Schema, Index, Direction, In, Outcome, Effects, !E) :-
    ( if
        Index >= 0,
        list.index0(slot_commons(Schema), Index, Common)
    then
        Units = Common ^ sc_units,
        (
            Units = no,
            Outcome = uo_no_unit,
            Effects = []
        ;
            Units = yes(unit_conversion(ToStored, FromStored)),
            ( if not nfct_2_3_unit_kind(Common ^ sc_kind, In) then
                Outcome = uo_kind_mismatch,
                Effects = []
            else if In = float(F), float.is_nan(F) then
                Outcome = uo_nan,
                Effects = []
            else
                (
                    Direction = ud_to_stored,
                    Conversion = ToStored
                ;
                    Direction = ud_from_stored,
                    Conversion = FromStored
                ),
                E0 = !.E,
                Ctx = eval_ctx([], no, engine_wm(E0), map.init,
                    engine_interns(E0), engine_clock_now(E0), no,
                    map.singleton(0, In), 1, engine_cache(E0),
                    engine_series(E0)),
                ds.eval.eval(Conversion, Ctx, Result),
                ( if
                    Result = ev_ok(Out),
                    nfct_2_3_unit_kind(Common ^ sc_kind, Out),
                    not ( Out = float(G), float.is_nan(G) )
                then
                    Outcome = uo_ok(Out),
                    Effects = []
                else if
                    Result = ev_fault(Fault),
                    expr_fault_class(Fault) = fc_engine
                then
                    stamp_step(
                        [eff_event(se_engine_error(ee_expr_fault(Fault),
                            no_site))],
                        Effects, !E),
                    latch_from(Effects, !E),
                    Outcome = uo_halted
                else
                    Outcome = uo_not_representable,
                    Effects = []
                )
            )
        )
    else
        Outcome = uo_no_slot,
        Effects = []
    ).

:- pred nfct_2_3_unit_kind(slot_kind::in, ds_value::in) is semidet.

nfct_2_3_unit_kind(Kind, V) :-
    ( if Kind = k_float then
        V = float(_)
    else
        int_represented(Kind),
        V = int(_)
    ).

%-----------------------------------------------------------------------------%
% The engine's schemas
%-----------------------------------------------------------------------------%

engine_schemas(E) = map.values(E ^ en_schemas).

    % Latch on the first effect carrying an error whose disposition is `latched`,
    % and leave an already-halted engine alone.
    %
:- pred latch_from(list(effect)::in, engine::in, engine::out) is det.

latch_from(Effects, !E) :-
    ( if
        !.E ^ en_halted = no,
        list.find_first_match(latching, Effects, Match),
        Match = eff_event(se_engine_error(Err, _))
    then
        !E ^ en_halted := yes(Err)
    else
        true
    ).

    % The EngineError is the tier's last record: a step's effects up to and
    % including the first error that latches. Cut before stamping, so a record cut
    % spends no `seq`. A delivery's close is kept: it is no record, and without it
    % a delivery that halted would be missing from its recording [RFCS.24.2].
    %
    %@spec [LERR.1.4.7]
:- func lerr_1_4_7_last_record(list(effect)) = list(effect).

lerr_1_4_7_last_record(Effects) = Kept :-
    ( if list.find_index_of_match(latching, Effects, 0, I) then
        list.det_split_list(I + 1, Effects, Head, Tail),
        Kept = Head ++ list.filter(
            ( pred(Effect::in) is semidet :- Effect = eff_input(hi_close) ),
            Tail)
    else
        Kept = Effects
    ).

    % The latch is set where a fact change raises the error, so `settle_turnover`
    % and the loops that drive it stop there. A join test's error is derived at the
    % end of its own change [LERR.1.4.12].
    %
    %@spec [LERR.1.4.7]
:- pred lerr_1_4_7_raise(list(effect)::in, engine::in, engine::out) is det.

lerr_1_4_7_raise(Raised, !E) :-
    latch_from(Raised, !E).

:- pred lerr_1_4_7_halt(list(effect)::in, list(effect)::out,
                        engine::in, engine::out) is det.

lerr_1_4_7_halt(Effects0, Effects, !E) :-
    Effects = lerr_1_4_7_last_record(Effects0),
    latch_from(Effects, !E).

    % One effect as a host sees it. `se_rule_lhs_facts` loses its synthetic ids, and
    % goes when none are left.
    %
:- pred observable_effect(engine::in, effect::in, effect::out) is semidet.

observable_effect(E, Effect, Out) :-
    ( if
        Effect = eff_event(se_rule_lhs_facts(Fire, Facts))
    then
        Kept = list.filter(not_synthetic_id(E), Facts),
        Kept = [_ | _],
        Out = eff_event(se_rule_lhs_facts(Fire, Kept))
    else
        not_synthetic_fact(E, Effect),
        Out = Effect
    ).

:- pred not_synthetic_id(engine::in, fact_id::in) is semidet.

not_synthetic_id(E, FactId) :-
    not set.contains(E ^ en_synth, fact_id_value(FactId)).

:- pred not_synthetic_fact(engine::in, effect::in) is semidet.

not_synthetic_fact(E, Effect) :-
    ( if
        Effect = eff_event(Event),
        synthetic_fact_event(Event, FactId)
    then
        not set.contains(E ^ en_synth, fact_id_value(FactId))
    else
        true
    ).

    % The events that name a fact a host must not see. `se_publish` names no
    % fact ([LTIE.4.3]).
    %
:- pred synthetic_fact_event(stream_event::in, fact_id::out) is semidet.

synthetic_fact_event(se_fact_assert(FactId, _, _, _), FactId).
synthetic_fact_event(se_fact_retract(FactId), FactId).
synthetic_fact_event(se_fact_withdraw(FactId, _), FactId).
synthetic_fact_event(se_emit(FactId, _), FactId).

:- pred settle_effect(effect::in, list(effect)::in, list(effect)::out,
                      engine::in, engine::out) is det.

settle_effect(eff_action(_), !Effects, !E).
settle_effect(eff_input(_), !Effects, !E).
settle_effect(eff_cache_expired(_), !Effects, !E).
settle_effect(eff_metric(_), !Effects, !E).
settle_effect(eff_host_log(_, _, _), !Effects, !E).
settle_effect(eff_pump_status(_), !Effects, !E).
settle_effect(eff_event(Event), !Effects, !E) :-
    ( if Event = se_fact_assert(FactId, SchemaId, _, _) then
        ( if map.search(!.E ^ en_schemas, schema_id_value(SchemaId), Schema) then
            note_synthetic(Schema, FactId, !E)
        else
            true
        ),
        settle_fact(asserted(FactId), Cascade, !E),
        !:Effects = !.Effects ++ Cascade
    else if
        ( Event = se_fact_retract(FactId)
        ; Event = se_fact_withdraw(FactId, _)
        )
    then
        settle_fact(retracted(FactId), Cascade, !E),
        !:Effects = !.Effects ++ Cascade
    else
        true
    ).

%-----------------------------------------------------------------------------%

engine_clock_mode(E) = mode_of(E ^ en_clock).

engine_use_mock_clock(!E) :-
    ( if
        !.E ^ en_halted = no,
        clock_to_mock(!.E ^ en_clock, Clock)
    then
        !E ^ en_clock := Clock
    else
        % Halted, or an input already consumed [NLFC.5.4].
        true
    ).

engine_intern(S, Ref, !E) :-
    ( if !.E ^ en_halted = yes(_) then
        % The table stays as it is; every assert is refused anyway.
        intern(S, Ref, !.E ^ en_interns, _)
    else
        intern(S, Ref, !.E ^ en_interns, IT),
        !E ^ en_interns := IT
    ).

engine_wm(E) = E ^ en_wm.

engine_refraction_size(E) = refraction_size(E ^ en_refract).

engine_refracted_activations(E, Filter) = Listing :-
    Entries = refraction_entries(E ^ en_refract),
    Metas = list.sort(list.map((func(M) = {M ^ rm_source, M}),
        map.values(E ^ en_metas))),
    Listing = list.condense(list.map(terminal_listing(E, Filter, Entries),
        Metas)).

:- func terminal_listing(engine, maybe(string), list({uint32, list(fact_id)}),
                         {source_index, rule_meta})
    = list(refracted_activation).

terminal_listing(E, Filter, Entries, {_, Meta}) = Listing :-
    Rule = ( if expand(E ^ en_interns, Meta ^ rm_name, R) then R else "?" ),
    ( if Filter = yes(Wanted), Wanted \= Rule then
        Listing = []
    else
        Terminal = node_id_value(Meta ^ rm_terminal),
        % A tuple that is a prefix of another sorts first.
        Rows = list.sort(list.filter_map(
            ( func({T, Tuple}) = Authored is semidet :-
                T = Terminal,
                Authored = list.filter_map(
                    ( func(F) = Raw is semidet :-
                        Raw = fact_id_value(F),
                        not set.contains(E ^ en_synth, Raw) ),
                    Tuple) ),
            Entries)),
        Listing = list.map(
            ( func(Raws) = refracted_activation(Rule, "refraction",
                "fired, and not re-created since", list.map(make_fact_id, Raws)) ),
            Rows)
    ).

engine_rete_match_trace(E, Id) = Steps :-
    ( if
        lookup_fact(E ^ en_wm, Id, Fact),
        not set.contains(E ^ en_synth, fact_id_value(Id)),
        map.search(E ^ en_schemas, schema_id_value(Fact ^ f_schema), Schema)
    then
        Ctx = match_ctx(E ^ en_wm, E ^ en_schemas, E ^ en_interns,
            clock_now(E ^ en_clock), clock_wall(E ^ en_clock), E ^ en_cache,
            E ^ en_series),
        Steps =list.map(trace_row(E ^ en_interns, Schema),
            alpha_trace(E ^ en_index, Ctx, Fact))
    else
        Steps = []
    ).

:- func trace_row(intern_table, schema, pair(alpha_node, bool)) = trace_step.

trace_row(IT, Schema, Alpha - Passed) = trace_step(Node, "alpha", Result,
        Detail) :-
    Node = string.int_to_string(
        uint32.cast_to_int(node_id_value(Alpha ^ an_id))),
    SchemaName = ( if expand(IT, schema_name_ref(Schema ^ s_name), S) then S
                   else "?" ),
    Filter = alpha_filter_text(IT, Schema, Alpha ^ an_tests),
    (
        Passed = yes,
        Result = "passed",
        Detail = "schema " ++ SchemaName ++ " passed"
            ++ ( if Alpha ^ an_tests = [] then " (no alpha filter)" else "" )
    ;
        Passed = no,
        Result = "filtered",
        Detail = "alpha filter failed: "
            ++ ( if Filter = "" then "<test>" else Filter )
    ).

    % An alpha node's tests: each `slot op value`, joined by ", ". A regex test
    % does not print its pattern.
    %
:- func alpha_filter_text(intern_table, schema, list(alpha_test)) = string.

alpha_filter_text(IT, Schema, Tests) =
    string.join_list(", ", list.map(alpha_test_text(IT, Schema), Tests)).

:- func alpha_test_text(intern_table, schema, alpha_test) = string.

alpha_test_text(IT, Schema, Test) = Slot ++ " " ++ Op ++ " " ++ Value :-
    (
        Test = at_eq(Ix, Lit),
        Op = "==",
        Value = alpha_literal_text(IT, Lit)
    ;
        Test = at_cmp(Ix, BinOp, Lit),
        Op = alpha_op_text(BinOp),
        Value = alpha_literal_text(IT, Lit)
    ;
        Test = at_regex(Ix, _),
        Op = "~",
        Value = "/<re>/"
    ),
    Slot = ( if
                slot_name_at(Schema, slot_index_int(Ix)) = yes(Ref),
                expand(IT, Ref, Name)
             then Name
             else "?" ).

:- func alpha_op_text(binop) = string.

alpha_op_text(Op) =
    ( if Op = op_ne then "!="
    else if Op = op_lt then "<"
    else if Op = op_gt then ">"
    else if Op = op_le then "<="
    else if Op = op_ge then ">="
    else "==" ).

:- func alpha_literal_text(intern_table, alpha_literal) = string.

alpha_literal_text(_, al_int(I)) = string.int64_to_string(I).
alpha_literal_text(_, al_float(F)) = ds.float_text.canonical(F).
alpha_literal_text(_, al_bool(B)) = ( if B = yes then "true" else "false" ).
alpha_literal_text(IT, al_string(Ref)) =
    "\"" ++ ( if expand(IT, Ref, S) then S else "?" ) ++ "\"".

audit_match_paths(E, Problems) :-
    % `en_matched`: every match reads the pre-sample snapshot [LSER.8.6.1].
    Ctx = match_ctx(E ^ en_wm, E ^ en_schemas, E ^ en_interns,
        clock_now(E ^ en_clock), clock_wall(E ^ en_clock), E ^ en_cache,
        E ^ en_matched),
    Facts = list.condense(list.map(
        (func(S) = facts_of_schema(E ^ en_wm, S ^ s_id)),
        map.values(E ^ en_schemas))),
    Ids = list.sort(list.map((func(F) = fact_id_value(F ^ f_id)), Facts)),
    seed_roots(E ^ en_index, Ctx, _, init_rete, Seeded),
    list.foldl(replay_fact(E ^ en_index, Ctx), Ids, Seeded, Fresh),
    Nodes = list.sort_and_remove_dups(
        beta_nodes_with_memory(E ^ en_rete) ++ beta_nodes_with_memory(Fresh)),
    list.filter_map(beta_mismatch(E ^ en_rete, Fresh), Nodes, Problems).

:- pred replay_fact(net_index::in, match_ctx::in, uint64::in,
                    rete_state::in, rete_state::out) is det.

replay_fact(Index, Ctx, Raw, !S) :-
    fact_asserted(Index, Ctx, make_fact_id(Raw), _, !S).

:- pred beta_mismatch(rete_state::in, rete_state::in, node_id::in,
                      string::out) is semidet.

beta_mismatch(Actual, Fresh, Id, Msg) :-
    A = list.sort(list.map((func(T) = T ^ t_facts), beta_memory(Actual, Id))),
    F = list.sort(list.map((func(T) = T ^ t_facts), beta_memory(Fresh, Id))),
    A \= F,
    Msg = string.format("beta %d: incremental %d token(s), replayed %d",
        [i(uint32.cast_to_int(node_id_value(Id))),
         i(list.length(A)), i(list.length(F))]).

engine_fact_count(E) =
    live_count(E ^ en_wm) - set.count(E ^ en_synth).
engine_tms(E) = E ^ en_tms.
engine_event_count(E) = E ^ en_events.
engine_series(E) = E ^ en_series.


engine_cache(E) = E ^ en_cache.

pending_activations(E) = agenda_count(E ^ en_agenda).
engine_now(E) = clock_now(E ^ en_clock).
engine_clock_now(E) = clock_source_now(E ^ en_clock).

nlfc_2_5_next_deadline(E) = Next :-
    Now = engine_clock_now(E),
    FromFacts = list.foldl(schema_next_deadline(E ^ en_wm, E ^ en_interns, Now),
        map.values(E ^ en_schemas), no),
    FromCache = cache_next_deadline(E ^ en_cache, Now),
    (
        FromCache = yes(At),
        Next = keep_sooner(At, FromFacts)
    ;
        FromCache = no,
        Next = FromFacts
    ).

:- func schema_next_deadline(wm, intern_table, instant, schema, maybe(instant))
    = maybe(instant).

schema_next_deadline(WM, Interns, Now, Schema, Best0) =
        list.foldl(fact_next_deadline(IsTimer, Now),
            facts_of_schema(WM, Schema ^ s_id), Best0) :-
    ( if
        expand(Interns, schema_name_ref(Schema ^ s_name), Name),
        string.prefix(Name, "$Timer_")
    then
        IsTimer = yes
    else
        IsTimer = no
    ).

:- func fact_next_deadline(bool, instant, fact, maybe(instant))
    = maybe(instant).

fact_next_deadline(IsTimer, Now, Fact, Best0) = Best :-
    Expiry = Fact ^ f_deadline,
    ( if
        Expiry = yes(Expires),
        before(Now, Expires)
    then
        Best1 = keep_sooner(Expires, Best0)
    else
        Best1 = Best0
    ),
    ( if
        IsTimer = yes,
        ltac_3_2_fire_at(Fact, FireAt),
        before(Now, FireAt)
    then
        Best = keep_sooner(FireAt, Best1)
    else
        Best = Best1
    ).

    % [LTAC.3.2]: `fire_at` is a timer schema's first slot.
    %
:- pred ltac_3_2_fire_at(fact::in, instant::out) is semidet.

ltac_3_2_fire_at(Fact, FireAt) :-
    array.semidet_lookup(Fact ^ f_slots, 0, Slot),
    (
        Slot = duration(D),
        FireAt = from_ns(duration_ns(D))
    ;
        Slot = int(I),
        I > 0i64,
        FireAt = from_ns(uint64.cast_from_int64(I))
    ).

:- func keep_sooner(instant, maybe(instant)) = maybe(instant).

keep_sooner(At, no) = yes(At).
keep_sooner(At, yes(Held)) = yes(Sooner) :-
    ( if before(At, Held) then
        Sooner = At
    else
        Sooner = Held
    ).
engine_wall_clock_now(E) = clock_source_wall(E ^ en_clock).

engine_interns(E) = E ^ en_interns.

engine_mem(E) = engine_mem(
        live_count(E ^ en_wm), 0, 0,
        alpha_node_count(E ^ en_index),
        alpha_match_count(E ^ en_index, E ^ en_rete), 0,
        beta_node_count(E ^ en_index),
        beta_token_count(E ^ en_index, E ^ en_rete), 0, 0,
        intern_count(E ^ en_interns), Bytes, 0,
        0,
        Bytes) :-
    Bytes = intern_bytes(E ^ en_interns).

    % [NMET.4.1]'s four intern gauges, of this runtime's own table [NMET.4.7]. Every
    % entry is pinned, since nothing is released; there is no computed-string arena,
    % so its high water is 0.
    %
:- func intern_gauges(engine) = list(effect).

intern_gauges(E) = list.map((func(M) = eff_metric(M)), [
        gauge("ds.intern.entries", float(Count)),
        gauge("ds.intern.bytes", float(intern_bytes(E ^ en_interns))),
        gauge("ds.intern.pinned_entries", float(Count)),
        gauge("ds.intern.arena_high_water_bytes", 0.0)
    ]) :-
    Count = intern_count(E ^ en_interns).

%-----------------------------------------------------------------------------%

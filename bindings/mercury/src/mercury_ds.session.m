%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: mercury_ds.session.m.
%
% A session: an engine loaded from one artefact, and the calls that drive it.
%
% A session is a value. A call that changes one takes it and returns the new
% one, and the old one is unchanged, so a snapshot costs nothing and a clone
% is a copy. Nothing needs freeing.
%
% Each call that changes a session returns what it reported: stream events,
% log lines and metrics, in order (`mercury_ds.events`). Nothing the session
% does reaches outside it. A pump returns the duties its firings produced
% and the calls they issued as data (`mercury_ds.host`), for the host to
% perform and to answer back into the session, and every other call that
% changes a session returns the duties it produced too; the clock is
% read only by `read_clock`. So every call that changes a session is `det`
% and takes no `io` (MER.7), and the one that takes the host's own `io`,
% `pump_serving`, is a loop over the others.
%
%---------------------------------------------------------------------------%

:- module mercury_ds.session.
:- interface.

:- import_module mercury_ds.error.
:- import_module mercury_ds.events.
:- import_module mercury_ds.host.
:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fault.
:- import_module ds.id.
:- import_module ds.json.
:- import_module ds.schema.
:- import_module bitmap.
:- import_module io.
:- import_module list.
:- import_module maybe.

    % Qualified: only its `stream_meta` is wanted here.
    %
:- use_module ds.rfcs.

%---------------------------------------------------------------------------%
% Sessions
%---------------------------------------------------------------------------%

:- type session.

:- type clock_choice
    --->    mock_clock
            % Moved only by `advance`, `set_clock` and `set_wall_clock`.
    ;       live_clock.
            % Wall time, moved only by `read_clock`.

:- type session_config
    --->    session_config(
                session_config_clock     :: clock_choice,
                session_config_budget    :: fire_budget,
                            % How many firings one pump may perform. There is
                            % no timezone resolver: a host asserts
                            % `TimeZoneOffset` facts ([LTIM.10.6]), and
                            % `local()` resolves through them ([LTIM.10.7]).
                session_config_run_id    :: maybe(string),
                session_config_tier_id   :: maybe(string),
                            % The run and the tier this engine is, which
                            % every fact's `event_id` derives from and the
                            % session header reports ([RFCS.4.3],
                            % [RFCS.4.4]). An empty string is none
                            % ([NLFC.1.2]).
                session_config_admission :: admission_policy
                            % Which setting of each capability a load
                            % admits ([NLFC.10.2]); a capability with no
                            % entry admits either. What this build has code
                            % for is `ds.dsc.build_capabilities`
                            % ([NLFC.10.1]).
            ).

    % The mock clock, no firing limit, no run or tier id, and every setting
    % admitted.
    %
:- func default_config = session_config.

    % Load an artefact into a new session, or say why not, with the status
    % libds refuses the same artefact with. An artefact with a setting the
    % configuration does not admit is refused as `bnd_dialect_mismatch`, a
    % configuration with a negative firing limit as `inval`, and one whose
    % run or tier id is not well-formed UTF-8 as `encoding`, before anything
    % is loaded ([NLFC.1.2]).
    %
    % The reports are what the load logged, as every call that changes a
    % session returns its own: one `dsc-load` info line for each atom the
    % loader steps over by name -- `DocString`, the test and oracle atoms, and
    % `CompiledCode` -- with its field number, message and byte offset, in the
    % order the load met them ([RDSC.9.4]). A refused load reports nothing.
    %
:- pred load(bitmap::in, session_config::in,
    maybe_error(session, ds_error)::out, list(report)::out) is det.

    % Under a live clock, read the wall clock into the session: the reading
    % is the instant every later call samples, until the next reading. The
    % first reading is the clock's 0. Under a mock clock, do nothing.
    %
:- pred read_clock(session::in, session::out, io::di, io::uo) is det.

%---------------------------------------------------------------------------%
% Calls that change a session
%---------------------------------------------------------------------------%

    % What a call did, what it reported, and what it leaves the host to do.
    %
    % A call that is not a pump has duties too. An input's join
    % tests can read a cache entry whose deadline has passed, and that read
    % evicts it and tells the host ([NSTG.2.4.2]): the `remove_cache` duty
    % its write-through store needs, which libds hands its removal callback
    % from inside the same call. Every call that changes a session hands
    % them over, from the same effects a pump's come from, except a replay,
    % which reaches no host store ([NDET.8.2]).
    %
:- type step
    --->    step(
                step_outcome :: outcome,
                step_reports :: list(report),
                step_duties  :: list(duty)
                            % The duties the call produced, in the order it
                            % produced them, for the host to perform.
            ).

:- type assert_outcome
    --->    asserted(fact_id)
    ;       unchanged(fact_id)
            % The same fact was live: its id ([LFAC.2.5.1]). Its `FactAssert`
            % is still recorded ([RFCS.6.7]).
    ;       replaced(fact_id, fact_id)
            % The old fact and the new one that replaced it ([LFAC.2.5.3]).
    ;       error(ds_error).
            % Refused, and nothing entered; or the call halted the engine,
            % and the fact may have entered ([NCBK.2.9]).

:- type assert_step
    --->    assert_step(
                assert_step_outcome :: assert_outcome,
                assert_step_reports :: list(report),
                assert_step_duties  :: list(duty)
                            % As a `step`'s: the expiries its own reads met.
            ).

    % Assert a fact of the named schema, one value per slot in declaration
    % order. Its deadline is its schema's TTL: there is no per-fact
    % override. A `fact_ref` that names no live fact of its
    % slot's schema is refused with `slot_type_mismatch` ([NFCT.2.3]).
    %
:- pred assert_fact(string::in, list(storable)::in,
    assert_step::out, session::in, session::out) is det.

    % Retract a live fact. A fact that is not live is refused with
    % `not_found`.
    %
:- pred retract_fact(fact_id::in, step::out, session::in, session::out)
    is det.

    % Assert a fact published by another tier: a FactExternal's bytes, which
    % the runtime's `encode_fact_external` writes from a publish's
    % `fact_external`. Each fact it asserts gets this engine's own event id
    % and its lifetime from this program's schema; a reference equal to a
    % live fact is that fact.
    %
    % Refused, asserting nothing, as libds refuses it: `engine_halted`,
    % `parse` for bytes that are not a FactExternal, nest deeper than 16 or
    % hold ill-formed text, `schema_unknown`, `schema_hash_mismatch` for a
    % schema of the same name and another shape, `fact_ref_conflict` for a
    % reference that meets a live fact with its key and other values,
    % `slot_type_mismatch`, `nan_rejected` and `json_limit` for a value its
    % slot does not take, and `time_range` for a `Date`, or a seeded entry's
    % deadline, outside the `Time` range. An assert of it that
    % fails afterwards fails as `assert_fact` would, and the facts asserted
    % before it stand.
    %
:- pred assert_external(bitmap::in, step::out, session::in, session::out)
    is det.

    % What a pump did, what it reported, and what it leaves the host to do.
    %
:- type pumped
    --->    pumped(
                pumped_outcome :: outcome,
                pumped_reports :: list(report),
                pumped_duties  :: list(duty),
                            % The duties the firings produced, in the order
                            % they produced them, for the host to perform.
                pumped_calls   :: list(service_call)
                            % The calls the firings issued, in the order
                            % they issued them, for the host to answer.
            ).

    % Run the agenda until it is empty or the firing limit is reached. The
    % duties and the calls are returned, not performed: the session is
    % unchanged by whatever the host then does with them, until the host
    % answers a call.
    %
:- pred pump(pumped::out, session::in, session::out) is det.

    % Answer a call a pump issued: assert the service's response, a fact of
    % the service's response schema with the call's correlation, or a
    % `CallError`. Pump afterwards for the rules that read it.
    %
    % Every answer is asserted, an earlier call's too: the engine retracts
    % the live answers with its correlation as it arrives, so the answer
    % asserted last is the one that stays. A service's failure is a
    % `CallError` fact, never the step's outcome: `not_offered` is
    % `request.unsupported`, and an answer that does not fit the service is
    % `internal.bug`. Every call has a correlation to answer into
    % ([LCRS.3.1]).
    %
    % Text that is not well-formed UTF-8, in a response's slot or a
    % `CallError`'s code or message, is refused as `encoding`, changing nothing
    % and asserting no `CallError` ([LSTR.8.5]).
    %
    % The binding is the adapter that received the answer, so a `CallError`'s
    % `ts` is the wall clock's present reading. With no wall value, no
    % `CallError` is asserted, and the log says so.
    %
:- pred answer(service_call::in, service_answer::in, step::out,
    session::in, session::out) is det.

    % Pump, and answer every call the pump issued through `Serve`, pumping
    % again after each answer that asserted something, until no call is
    % waiting: the loop a host that answers at once would write. Calls are
    % answered in the order they were issued, and the calls an answer causes
    % wait behind those already waiting. The clock is read before the first
    % pump and after each service runs.
    %
    % The result is every pump's, in order: the first failure ([NCBK.1.5]),
    % every report, every duty for the host to perform, and every call
    % issued, each already answered. Nothing `Serve` throws is caught.
    %
:- pred pump_serving(
    pred(service_call, service_answer, H, H, io, io)
        ::in(pred(in, out, in, out, di, uo) is det),
    pumped::out, session::in, session::out, H::in, H::out,
    io::di, io::uo) is det.

    % Move the mock clock forward, or set it. Refused with `state` on a live
    % clock, and a set below the current value once the engine has sampled,
    % which leaves both clocks as they were ([NTST.3.1]). An advance past a
    % clock's range is refused with `time_range`, and leaves them too.
    %
:- pred advance(duration::in, step::out, session::in, session::out) is det.
:- pred set_clock(instant::in, step::out, session::in, session::out) is det.

    % Set the mock wall clock, in UTC nanoseconds since the Unix epoch, to
    % any instant ([NTST.3.1]). Under a mock clock the wall clock has no
    % value until this sets one, and `now()` faults until then. Refused with
    % `engine_halted` on a halted session ([NCBK.2.9]) and `state` on a live
    % clock, which leave the wall clock as it was.
    %
:- pred set_wall_clock(int64::in, outcome::out, session::in, session::out)
    is det.

    % Restore one cache entry before the first pump: the read-back half of
    % write-through persistence. An upsert; `no` TTL is no expiry. Refused on a
    % halted engine (`engine_halted`), after the engine's first stream event
    % (`state`), for a zero TTL (`inval`), past a cache cap
    % (`contract_breach`), for a value with no JSON spelling
    % (`json_nonfinite`) or over a limit (`json_limit`), for ill-formed text
    % (`encoding`), and for a TTL past the `Time` range (`time_range`).
    %
:- pred cache_seed(string::in, json::in, maybe(duration)::in, outcome::out,
    session::in, session::out) is det.

    % NO `register_schema`. A schema reaches a session from its artefact and
    % in no other way ([NFCT.1.1]).

%---------------------------------------------------------------------------%
% Recording and replay
%---------------------------------------------------------------------------%

    % Begin recording the session's fact stream ([RFCS.2]), or begin again:
    % from here, each call that changes the session adds what the engine
    % emitted. `stop_recording` ends it.
    %
:- pred start_recording(session::in, session::out) is det.
:- pred stop_recording(session::in, session::out) is det.

    % A recording, as libds's recorder writes it: the stream's bytes, and
    % the events the stream should carry and could not encode, which a
    % non-empty list says it is short of. Where the bytes go is the host's.
    %
:- type recording
    --->    recording(
                recording_bytes       :: bitmap,
                recording_unencodable :: list(stream_event)
            ).

    % The recording so far, or `no` when the session is not recording. It
    % has no bytes until the engine's first event after it began, when the
    % header and the schemas are written ([RFCS.5.1]).
    %
:- func recording(session) = maybe(recording).

    % Replay a recording into the session, which should be freshly loaded
    % from the artefact the recording was made with: deliver each input it
    % holds -- a host's asserts and retracts, its clock samples, its pumps
    % ([RFCS.22]) -- and let the engine derive the rest ([RFCS.6a.1]). No
    % host method runs: a service's answer is an input the recording holds,
    % and the duties the engine derives again are in the reports.
    %
    % Refused, with the session unchanged: `engine_halted` on a halted engine,
    % `fs_version` for a recording of another DS series ([LDET.1.10]),
    % `parse` for anything malformed, an atom whose field number has no
    % registry entry among it ([RFCS.19.3]), `bnd_dsc_mismatch`,
    % `bnd_dialect_mismatch` or `bnd_incomplete` for one whose
    % dialect-binding tuple is not the program's, made with another artefact
    % or under other settings
    % ([RBND.5.1]), or that carries one of `dsc_sha256` and
    % `dialect_def_sha256` and not the other ([RBND.2.1]), as libds refuses it,
    % and `fs_recording_incomplete` for one begun after its engine's first
    % event. Failed, with nothing after the failing atom delivered: with
    % `fs_divergence` where a delivery did not reproduce what the recording
    % holds; with `schema_unknown` for a FactAssert of a schema the engine
    % does not hold ([RFCS.5.4]); with `fs_unknown_fact_id` for a FactRetract
    % of a fact no earlier atom carries ([RFCS.7.3]); and with an input's own
    % status where the engine refuses it for anything but a bound
    % ([RFCS.6.7]), `engine_halted` for an input that met an engine already
    % halted. A pump's status does not fail a replay ([RFCS.6.7]).
    %
    % A HALT THE RECORDING'S OWN INPUT RAISES IS THE RUN'S OUTCOME
    % ([RFCS.6.7]): the replay goes on, compares the `EngineError`, and answers
    % `ok`, as libds's does. Read `halted` after a replay.
    %
    % The replay's recorded clock samples put the session on the mock clock
    % ([RFCS.10.5]), whatever it was loaded with, and `clock_mode` says so.
    %
:- pred replay(bitmap::in, step::out, session::in, session::out) is det.

%---------------------------------------------------------------------------%
% Configuration
%---------------------------------------------------------------------------%

    % No hydration budget ([LHYD.7.4]).

    % How many firings each later pump may perform: the configuration's
    % `session_config_budget`, changed. Refused on a halted engine as
    % `engine_halted` ([NCBK.2.9]), and a negative limit as `inval`, and the
    % session is unchanged.
    %
:- pred set_fire_budget(fire_budget::in, outcome::out,
    session::in, session::out) is det.

    % Bound the cache: live keys, then value bytes, zero for unbounded. A
    % write past either is refused. Refused on a halted engine as
    % `engine_halted` ([NCBK.2.9]), and a negative bound, or a key bound past
    % 4294967295 (libds's is a 32-bit count), as `inval`, and the session is
    % unchanged.
    %
:- pred set_cache_cap(int::in, int::in, outcome::out,
    session::in, session::out) is det.

%---------------------------------------------------------------------------%
% Reads
%---------------------------------------------------------------------------%

    % What a read answers: its value, or the error that halted the session's
    % engine. After the halt the engine's state is undefined ([LERR.1.4.7]),
    % so a read of it is refused ([NCBK.2.9]); `halted` and `session_header`
    % are the reads that still answer.
    %
:- type read(T)
    --->    ok(T)
    ;       halted(engine_error).

    % The schemas a host can assert into, by name, in schema order.
    %
:- func schema_names(session) = read(list(string)).

:- func fact_count(session) = read(int).

    % Every live fact a host can see, schema by schema.
    %
:- func facts(session) = read(list(fact_view)).

    % The live fact with this id. `search_fact` fails if there is none;
    % `lookup_fact` throws an exception. Both answer `halted` after the halt,
    % whatever the id.
    %
:- pred search_fact(session::in, fact_id::in, read(fact_view)::out)
    is semidet.
:- func lookup_fact(session, fact_id) = read(fact_view).

    % The clock, as a host reads it between calls.
    %
:- func now(session) = read(instant).

    % The earliest deadline later than the clock's current value, or `no`
    % ([NLFC.2.5]). Not a sample, and it changes nothing a later call does.
    %
:- func next_deadline(session) = read(maybe(instant)).

    % The error that halted the engine ([NCBK.2.9]), or `no`.
    %
:- func halted(session) = maybe(engine_error).

:- func clock_mode(session) = read(clock_choice).

    % What the session's engine holds ([NDBG.2.1]): its facts, network
    % nodes, matches, tokens and interned strings, each counted as libds
    % counts it. The byte sizes of libds's own C layout are 0: this runtime
    % has no such layout to measure.
    %
:- func memory_usage(session) = read(engine_mem).

    % The run id and tier id the session was loaded with, `no` for one not
    % given.
    %
:- func run_id(session) = read(maybe(string)).
:- func tier_id(session) = read(maybe(string)).

    % The session header a recording of this session begins with ([LFST.4]):
    % the DS version, the artefact's `dsc_sha256` ([RFCS.4.5]), its
    % capabilities and dialect definition hash, which with the `dsc_sha256`
    % are its dialect-binding tuple ([RBND.1.3]), and the run id and tier id,
    % "" for one not given.
    %
:- func session_header(session) = ds.rfcs.stream_meta.

    % The schema of this name. `search_schema` fails if the session holds
    % none; `lookup_schema` throws an exception. Both answer `halted` after
    % the halt, whatever the name.
    %
:- pred search_schema(session::in, string::in, read(schema)::out) is semidet.
:- func lookup_schema(session, string) = read(schema).

    % The names of a schema's slots, in declaration order: the order
    % `assert_fact` takes their values in. The session's, because a name is
    % held in its engine's table of strings.
    %
:- func slot_names(session, schema) = read(list(string)).

    % A number through the conversion of the slot at a zero-based index of
    % a schema, a slot that names a unit ([NFCT.1.4.6]). `slot_to_stored`
    % takes a number in the unit the slot names to the number the slot
    % stores, which `assert_fact` takes; `slot_from_stored` takes a stored
    % number back. Each computes what a rule's `x::<unit>`, or its kwarg of
    % that unit, computes, and changes nothing, save for an `EngineError`
    % the conversion raises: the artefact has lied, and the call halts the
    % engine and reports the `EngineError`, as any call that raises one
    % does ([NCBK.2.9]). Refused with the first of these that holds:
    % `engine_halted` on a halted engine; `not_found` for an index that
    % names no slot; `inval` for a slot that names no unit;
    % `slot_type_mismatch` for a value that is not an `int` on a slot
    % stored as an integer, a `Duration` among them, or a `float` on one
    % stored as a float; `nan_rejected` for a NaN; `engine_halted` where
    % the conversion raised an `EngineError`; and `not_representable` where
    % it has no result for the number.
    %
:- type unit_step
    --->    unit_step(
                unit_step_result  :: maybe_error(storable, ds_error),
                unit_step_reports :: list(report)
                            % The `EngineError` and what dispatch reports
                            % beside it, or nothing.
            ).

:- pred slot_to_stored(schema::in, int::in, storable::in, unit_step::out,
    session::in, session::out) is det.
:- pred slot_from_stored(schema::in, int::in, storable::in, unit_step::out,
    session::in, session::out) is det.

    % The runtime's own values, for a tool that needs more than this surface.
    % These are the runtime's, not the binding's, and refuse nothing: a read
    % through them after the halt has no defined answer ([LERR.1.4.7]).
    %
:- func session_engine(session) = engine.
:- func session_program(session) = program.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.from_runtime.
:- import_module mercury_ds.status.
:- import_module ds.action.
:- import_module ds.fact.
:- import_module ds.intern.
:- import_module ds.value.
:- import_module ds.wm.
:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

    % Qualified: their constructor names are not this module's to claim.
    %
:- use_module ds.fact_receive.
:- use_module ds.replay.

    % Qualified: `error/1` is also `outcome`'s and `maybe_error`'s failure,
    % so the throw is written `require.error`.
    %
:- use_module require.

%---------------------------------------------------------------------------%

:- type session
    --->    session(
                ses_engine     :: engine,
                ses_program    :: program,
                ses_config     :: session_config,
                ses_clock      :: instant,
                            % The clock the last event was emitted at, and
                            % the next is unless a `tick` moves it.
                ses_recorder   :: maybe(recorder)
                            % The recording in progress, if one is.
            ).

    % A recording in progress: the clock when it began, the `seq` its first
    % event takes, and every effect since, newest first.
    %
:- type recorder
    --->    recorder(
                rcd_origin  :: instant,
                rcd_first   :: uint64,
                rcd_effects :: list(effect)
            ).

default_config =
    session_config(mock_clock, no_fire_limit, no, no, map.init).

load(Bytes, Config, Outcome, Reports) :-
    ( if
        ( not nlfc_1_2_id_well_formed(Config ^ session_config_run_id)
        ; not nlfc_1_2_id_well_formed(Config ^ session_config_tier_id)
        )
    then
        % [NLFC.1.2], [LSTR.8.5]: an id that is not well-formed UTF-8
        % is refused before anything is loaded, as libds's `ds_engine_new`
        % refuses it before the engine exists, and so before the firing
        % limit is set.
        Outcome = error(status_error(encoding,
            "load: the configuration's run_id or tier_id is not "
                ++ "well-formed UTF-8")),
        Reports = []
    else if negative_budget(Config ^ session_config_budget) then
        Outcome = error(status_error(inval,
            "load: the configuration's firing limit is negative")),
        Reports = []
    else
        load_configured(Bytes, Config, Outcome, Reports)
    ).

    % The load logs are reported from the fresh session, so they carry its
    % clock. No recording is in progress yet, so none holds them.
    %
:- pred load_configured(bitmap::in, session_config::in,
    maybe_error(session, ds_error)::out, list(report)::out) is det.

load_configured(Bytes, Config, Outcome, Reports) :-
    load_dsc_admitted(Config ^ session_config_admission, Bytes, Result),
    (
        Result = loaded(Program),
        % libds takes the ids in `ds_engine_config_t`, at creation; here they
        % are set on the fresh engine, before anything else. `load` refused
        % an ill-formed one already, so both answer `id_set`; an
        % `id_encoding` is still the refusal, not a session.
        some [!E] (
            !:E = init_engine(Program),
            set_run_id(Config ^ session_config_run_id, RunSet, !E),
            set_tier_id(Config ^ session_config_tier_id, TierSet, !E),
            E0 = !.E
        ),
        ( if RunSet = id_set, TierSet = id_set then
            Clock = Config ^ session_config_clock,
            (
                Clock = mock_clock,
                engine_use_mock_clock(E0, E)
            ;
                Clock = live_clock,
                E = E0
            ),
            S0 = session(E, Program, Config, engine_now(E), no),
            reports(load_logs(Program), Reports, S0, S),
            Outcome = ok(S)
        else
            Outcome = error(status_error(encoding,
                "load: the configuration's run_id or tier_id is not "
                    ++ "well-formed UTF-8")),
            Reports = []
        )
    ;
        Result = load_failed(Error),
        Outcome = error(load_failure(Error)),
        Reports = []
    ).

    % No series_declarations and no store_sample duty: there is no samples
    % plane, and NSTG.5 is deferred.

%---------------------------------------------------------------------------%
% Asserting and retracting
%---------------------------------------------------------------------------%

assert_fact(Name, Values, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = assert_step(error(Refusal), [], [])
    else if find_schema(!.S, Name, Schema) then
        assert_values(Schema, Values, Result, Reports, Duties, !S),
        Step = assert_step(
            reporting_halt_assert(!.S, outcome_of_assert(Name, Result)),
            Reports, Duties)
    else
        Step = assert_step(error(status_error(schema_unknown,
            "no schema named " ++ Name)), [], [])
    ).

    % Assert the values as the host, and report what the engine emitted and
    % the duties it handed over.
    %
:- pred assert_values(schema::in, list(storable)::in,
    assert_result::out, list(report)::out, list(duty)::out,
    session::in, session::out) is det.

assert_values(Schema, Values, Result, Reports, Duties, !S) :-
    E0 = !.S ^ ses_engine,
    list.map_foldl(intern_input, Values, Slots, E0, E1),
    % No deadline of the host's: the schema's TTL, if it has one.
    host_assert(Schema, Slots, no, Result, Effects, E1, E2),
    !S ^ ses_engine := E2,
    reports(Effects, Reports, !S),
    list.filter_map(duty_of, Effects, Duties).

    % A host's `text` becomes a string in the engine's intern table, which is
    % what a slot holds.
    %
:- pred intern_input(storable::in, ds_value::out, engine::in, engine::out)
    is det.

intern_input(V, Slot, !E) :-
    ( if V = text(Str) then
        engine_intern(Str, Ref, !E),
        Slot = str(Ref)
    else
        Slot = to_value(V)
    ).

    % libds's answer for each of the runtime's assert results.
    %
:- func outcome_of_assert(string, assert_result) = assert_outcome.

outcome_of_assert(_, inserted(Id)) = asserted(Id).
outcome_of_assert(_, noop(Id)) = unchanged(Id).
outcome_of_assert(_, replaced(Old, New)) = replaced(Old, New).
outcome_of_assert(Name, rejected(Cap)) =
    error(status_error(cap_status(Cap),
        Name ++ ": the assert would exceed a cap")).
outcome_of_assert(Name, invalid(Index, Reason)) =
    error(status_error(slot_status(Reason),
        string.format("%s: slot %d does not admit the value",
            [s(Name), i(Index)]))).
outcome_of_assert(_, refused_halted(_)) = error(halted_error).
outcome_of_assert(Name, refused_arity(Expected, Given)) =
    error(status_error(inval,
        string.format("%s has %d slots, %d given",
            [s(Name), i(Expected), i(Given)]))).
outcome_of_assert(Name, refused_unregistered(_)) =
    error(status_error(schema_unknown, Name ++ " is not this engine's")).
outcome_of_assert(Name, refused_time_range(Index)) =
    error(status_error(time_range,
        string.format("%s: slot %d holds a Date outside its range",
            [s(Name), i(Index)]))).
outcome_of_assert(Name, refused_encoding(Index)) =
    error(status_error(encoding,
        string.format("%s: slot %d's text is not well-formed UTF-8",
            [s(Name), i(Index)]))).
outcome_of_assert(_, refused_tz_row(Fault)) =
    error(status_error(inval, ltim_10_9_message(Fault))).
outcome_of_assert(Name, refused_ttl_range) =
    error(status_error(time_range,
        Name ++ ": a deadline, the fact's or a seeded entry's, is outside "
            ++ "the Time range")).

    % libds refuses an assert past `wm_max` as `wm_full`, and past any other
    % cap as a contract breach.
    %
:- func cap_status(cap) = status.

cap_status(cap_wm_max) = wm_full.
cap_status(cap_agenda) = contract_breach.
cap_status(cap_max_fires_per_pump) = contract_breach.
cap_status(cap_token_pool) = contract_breach.
cap_status(cap_intern) = contract_breach.
cap_status(cap_intern_bytes) = contract_breach.
cap_status(cap_pump_wcet) = contract_breach.
cap_status(cap_node(_)) = contract_breach.
cap_status(cap_series) = contract_breach.
cap_status(cap_cache) = contract_breach.
cap_status(cap_cache_bytes) = contract_breach.
cap_status(cap_value_capacity) = contract_breach.

:- func slot_status(slot_reason) = status.

slot_status(sr_kind_mismatch) = slot_type_mismatch.
slot_status(sr_null_non_nullable) = slot_type_mismatch.
slot_status(sr_nan_rejected) = nan_rejected.
slot_status(sr_json_nonfinite) = json_nonfinite.
slot_status(sr_json_limit(_)) = json_limit.

retract_fact(Id, Step, !S) :-
    E0 = !.S ^ ses_engine,
    ( if refused_call(!.S, Refusal) then
        Step = step(error(Refusal), [], [])
    else if ds.wm.lookup_fact(engine_wm(E0), Id, _) then
        host_retract(Id, Effects, E0, E1),
        !S ^ ses_engine := E1,
        reports(Effects, Reports, !S),
        list.filter_map(duty_of, Effects, Duties),
        Step = step(reporting_halt(!.S, ok), Reports, Duties)
    else
        Step = step(error(status_error(not_found,
            "fact " ++ uint64_to_string(fact_id_value(Id)) ++
            " is not live")), [], [])
    ).

assert_external(Bytes, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = step(error(Refusal), [], [])
    else
        ds.fact_receive.assert_external(Bytes, Result, Effects,
            !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        reports(Effects, Reports, !S),
        list.filter_map(duty_of, Effects, Duties),
        Step = step(reporting_halt(!.S, external_outcome(Result)), Reports,
            Duties)
    ).

    % libds's answer for each of the runtime's results.
    %
:- func external_outcome(ds.fact_receive.external_result) = outcome.

external_outcome(ds.fact_receive.ext_asserted) = ok.
external_outcome(ds.fact_receive.ext_refused(Refusal)) =
    error(external_refusal(Refusal)).
external_outcome(ds.fact_receive.ext_stopped(Result)) = Outcome :-
    ( if outcome_of_assert("FactExternal", Result) = error(Error) then
        Outcome = error(Error)
    else
        Outcome = ok
    ).

:- func external_refusal(ds.fact_receive.external_refusal) = ds_error.

external_refusal(ds.fact_receive.xr_parse) =
    status_error(parse, "not a FactExternal, or nested deeper than 16").
external_refusal(ds.fact_receive.xr_schema_unknown) =
    status_error(schema_unknown, "a schema this program does not declare").
external_refusal(ds.fact_receive.xr_schema_hash_mismatch) =
    status_error(schema_hash_mismatch,
        "a schema of this program's name and another shape").
external_refusal(ds.fact_receive.xr_fact_ref_conflict) =
    status_error(fact_ref_conflict,
        "a reference meets a live fact with its key and other values").
external_refusal(ds.fact_receive.xr_slot_type_mismatch) =
    status_error(slot_type_mismatch, "a value its slot does not take").
external_refusal(ds.fact_receive.xr_nan_rejected) =
    status_error(nan_rejected, "a NaN in a Float slot").
external_refusal(ds.fact_receive.xr_json_limit) =
    status_error(json_limit, "a Json value over a limit").
external_refusal(ds.fact_receive.xr_time_range) =
    status_error(time_range,
        "a Date, or a fact's or seed's deadline, outside the Time range").
external_refusal(ds.fact_receive.xr_inval) =
    status_error(inval, "a malformed TimeZoneOffset").
external_refusal(ds.fact_receive.xr_contract_breach) =
    status_error(contract_breach, "a value over its slot's capacity").
external_refusal(ds.fact_receive.xr_halted(_)) = halted_error.

%---------------------------------------------------------------------------%
% The pump
%---------------------------------------------------------------------------%

pump(Pumped, !S) :-
    ( if refused_call(!.S, Refusal) then
        Pumped = pumped(error(Refusal), [], [], [])
    else
        ds.engine.pump(!.S ^ ses_config ^ session_config_budget, Effects,
            !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        % The pump that latches the halt reports it, as every call that does
        % ([NCBK.2.9], `reporting_halt`). Else the first status a firing
        % raised and went on past: libds returns its first stashed
        % error unless the run failed, which wins.
        ( if first_pump_status(Effects) = yes(Status) then
            Outcome0 = error(pump_status_error(Status))
        else
            Outcome0 = ok
        ),
        Outcome = reporting_halt(!.S, Outcome0),
        reports(Effects, PumpReports, !S),
        Interns = engine_interns(E),
        list.filter_map(duty_of, Effects, Duties),
        list.filter_map(issued_call(Interns), Effects, Calls),
        Pumped = pumped(Outcome, PumpReports, Duties, Calls)
    ).

    % A pump's status as the error libds returns for it, by NERR's number.
    %
:- func pump_status_error(pump_status) = ds_error.

pump_status_error(ps_nan_rejected) =
    status_error(nan_rejected, "a NaN Float argument refuses the call").
pump_status_error(ps_contract_breach(Cap)) =
    status_error(cap_status(Cap),
        "a bound refused a rule's action, and its firing stopped there").
pump_status_error(ps_time_range) =
    status_error(time_range,
        "a seeded entry's deadline would be outside the Time range").

    % The duty an effect hands the host. Fail for an effect that hands it
    % none.
    %
:- pred duty_of(effect::in, duty::out) is semidet.

duty_of(eff_event(se_cache_set(Key, Value, Ttl)),
    write_cache(cache_write(Key, Value, Ttl))).
duty_of(eff_event(se_cache_delete(Key)),
    remove_cache(cache_removal(Key, removed_by_rule))).
duty_of(eff_cache_expired(Key), remove_cache(cache_removal(Key, expired))).

    % The call an effect issued. Fail for any other effect.
    %
:- pred issued_call(intern_table::in, effect::in, service_call::out)
    is semidet.

issued_call(Interns, eff_event(Event), Call) :-
    call_of(Interns, Event, Call).

%---------------------------------------------------------------------------%
% Services
%---------------------------------------------------------------------------%

answer(Call, Answer, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = step(error(Refusal), [], [])
    else
        answer_call(Call, Answer, Reports, Duties, _, Refused, !S),
        (
            Refused = yes(Error),
            Outcome0 = error(Error)
        ;
            Refused = no,
            Outcome0 = ok
        ),
        Step = step(reporting_halt(!.S, Outcome0), Reports, Duties)
    ).

pump_serving(Serve, Pumped, !S, !H, !IO) :-
    read_clock(!S, !IO),
    pump(First, !S),
    serve_waiting(Serve, First ^ pumped_calls, First, Pumped, !S, !H, !IO).

    % Answer the waiting calls in order, pumping after each answer that
    % asserted something, so the calls an answer causes wait behind those
    % already waiting. A halted session is answered nothing more.
    %
:- pred serve_waiting(
    pred(service_call, service_answer, H, H, io, io)
        ::in(pred(in, out, in, out, di, uo) is det),
    list(service_call)::in, pumped::in, pumped::out,
    session::in, session::out, H::in, H::out, io::di, io::uo) is det.

serve_waiting(_, [], !Pumped, !S, !H, !IO).
serve_waiting(Serve, [Call | Waiting], !Pumped, !S, !H, !IO) :-
    ( if refused_call(!.S, _) then
        true
    else
        Serve(Call, Answer, !H, !IO),
        read_clock(!S, !IO),
        answer_call(Call, Answer, Reports, Duties, Asserted, Refused, !S),
        % The first failure ([NCBK.1.5]): a refused answer is the loop's too.
        (
            Refused = yes(Error),
            ( if !.Pumped ^ pumped_outcome = ok then
                !Pumped ^ pumped_outcome := error(Error)
            else
                true
            )
        ;
            Refused = no
        ),
        % The answer's duties with its reports: its assert's reads
        % can expire a cache entry, as a pump's can.
        !Pumped ^ pumped_reports := !.Pumped ^ pumped_reports ++ Reports,
        !Pumped ^ pumped_duties := !.Pumped ^ pumped_duties ++ Duties,
        (
            Asserted = yes,
            pump(Next, !S),
            !:Pumped = followed_by(!.Pumped, Next),
            serve_waiting(Serve, Waiting ++ Next ^ pumped_calls, !Pumped, !S,
                !H, !IO)
        ;
            Asserted = no,
            serve_waiting(Serve, Waiting, !Pumped, !S, !H, !IO)
        )
    ).

    % Two pumps' results as one: the first failure ([NCBK.1.5]), and each
    % list in order.
    %
:- func followed_by(pumped, pumped) = pumped.

followed_by(pumped(O1, R1, D1, C1), pumped(O2, R2, D2, C2)) =
        pumped(O, R1 ++ R2, D1 ++ D2, C1 ++ C2) :-
    O = ( if O1 = error(_) then O1 else O2 ).

    % Assert a service's answer: a fact of its response schema, or a
    % `CallError`. `Asserted` says whether anything entered. `Refused` is the
    % status of text [LSTR.8.5] refuses, and then the session is as it was:
    % not even the refused text is interned.
    %
:- pred answer_call(service_call::in, service_answer::in, list(report)::out,
    list(duty)::out, bool::out, maybe(ds_error)::out,
    session::in, session::out) is det.

answer_call(Call, Answer, Reports, Duties, Asserted, Refused, S0, S) :-
    answer_into(Call, Answer, Reports0, Duties0, Asserted, Refused, S0, S1),
    (
        Refused = yes(_),
        Reports = [],
        Duties = [],
        S = S0
    ;
        Refused = no,
        Reports = Reports0,
        Duties = Duties0,
        S = S1
    ).

:- pred answer_into(service_call::in, service_answer::in, list(report)::out,
    list(duty)::out, bool::out, maybe(ds_error)::out,
    session::in, session::out) is det.

answer_into(Call, Answer, Reports, Duties, Asserted, Refused, !S) :-
    Service = Call ^ service_call_service,
    Response = response_schema(!.S, Service),
    (
        Answer = answered(Slots),
        ( if Response = "" then
            call_error(Call, "internal.bug",
                Service ++ " declares no response, and answered one",
                Reports, Duties, Asserted, Refused, !S)
        else
            respond(Call, Response, Slots, Reports, Duties, Asserted, Refused,
                !S)
        )
    ;
        Answer = no_response,
        ( if Response = "" then
            Reports = [],
            Duties = [],
            Asserted = no,
            Refused = no
        else
            call_error(Call, "internal.bug",
                Service ++ " answers with " ++ Response ++
                ", and gave nothing",
                Reports, Duties, Asserted, Refused, !S)
        )
    ;
        Answer = call_error(Code, Message),
        call_error(Call, Code, Message, Reports, Duties, Asserted, Refused, !S)
    ;
        Answer = not_offered,
        call_error(Call, "request.unsupported",
            "the host offers no service " ++ Service, Reports, Duties,
            Asserted, Refused, !S)
    ).

    % [LSTR.8.5]: the assert's refusal of ill-formed text, which the
    % host hears as its status: not a `CallError`, whose text may be what was
    % refused.
    %
:- pred lstr_8_5_refused(string::in, assert_result::in, ds_error::out)
    is semidet.

lstr_8_5_refused(Name, Result, Error) :-
    Result = refused_encoding(_),
    outcome_of_assert(Name, Result) = error(Error).

    % The schema a service answers with, "" for `no response`.
    %
:- func response_schema(session, string) = string.

response_schema(S, Service) =
    ( if assoc_list.search(service_responses(S ^ ses_program), Service, R) then
        R
    else
        ""
    ).

:- pred respond(service_call::in, string::in, list(storable)::in,
    list(report)::out, list(duty)::out, bool::out, maybe(ds_error)::out,
    session::in, session::out) is det.

respond(Call, Response, Slots, Reports, Duties, Asserted, Refused, !S) :-
    Corr = Call ^ service_call_correlation,
    ( if
        find_schema(!.S, Response, Schema),
        with_corr(Corr, schema_slot_names(!.S, Schema), Slots, Values)
    then
        assert_values(Schema, Values, Result, Reports0, Duties0, !S),
        ( if entered(Result) then
            Reports = Reports0,
            Duties = Duties0,
            Asserted = yes,
            Refused = no
        else if lstr_8_5_refused(Response, Result, Error) then
            Reports = Reports0,
            Duties = Duties0,
            Asserted = no,
            Refused = yes(Error)
        else
            Outcome = outcome_of_assert(Response, Result),
            call_error(Call, "internal.bug", refusal_text(Outcome),
                Reports1, Duties1, Asserted, Refused, !S),
            Reports = Reports0 ++ Reports1,
            Duties = Duties0 ++ Duties1
        )
    else
        call_error(Call, "internal.bug",
            "the answer does not fit " ++ Response, Reports, Duties,
            Asserted, Refused, !S)
    ).

    % The answer's slots with `corr` put in its place. Fail if they are not
    % one per slot.
    %
:- pred with_corr(string::in, list(string)::in, list(storable)::in,
    list(storable)::out) is semidet.

with_corr(_, [], [], []).
with_corr(Corr, [Name | Names], Slots, [Value | Values]) :-
    ( if Name = "corr" then
        Value = text(Corr),
        with_corr(Corr, Names, Slots, Values)
    else
        Slots = [Value | Rest],
        with_corr(Corr, Names, Rest, Values)
    ).

    % Assert a `CallError` for the call, if the program has a `CallError`
    % schema.
    %
    % The binding is the adapter here, so it supplies `ts`, when the error was
    % received ([LCRS.4.2.1], [LFAC.9.2]): the wall clock's source, and so
    % the instant this assert samples. Under a live clock that is the last
    % `read_clock`, which `pump_serving` takes after the service runs. A host
    % assert supplies every slot and `ts` admits no `null`, so with no wall
    % value there is no `CallError` to assert, and the log says so.
    %
:- pred call_error(service_call::in, string::in, string::in,
    list(report)::out, list(duty)::out, bool::out, maybe(ds_error)::out,
    session::in, session::out) is det.

call_error(Call, Code, Message, Reports, Duties, Asserted, Refused, !S) :-
    Corr = Call ^ service_call_correlation,
    ( if find_schema(!.S, "CallError", Schema) then
        Wall = engine_wall_clock_now(!.S ^ ses_engine),
        (
            Wall = yes(Received),
            Values = list.map(call_error_slot(Corr, Code, Message, Received),
                schema_slot_names(!.S, Schema)),
            assert_values(Schema, Values, Result, Reports, Duties, !S),
            Asserted = ( if entered(Result) then yes else no ),
            ( if lstr_8_5_refused("CallError", Result, Error) then
                Refused = yes(Error)
            else
                Refused = no
            )
        ;
            Wall = no,
            Reports = [logged(log_line(log_warning, "services",
                "no CallError for " ++ Call ^ service_call_service ++
                " (" ++ Code ++ "): the wall clock has no value for its ts"))],
            Duties = [],
            Asserted = no,
            Refused = no
        )
    else
        Reports = [],
        Duties = [],
        Asserted = no,
        Refused = no
    ).

:- func call_error_slot(string, string, string, int64, string) = storable.

call_error_slot(Corr, Code, Message, Received, Name) =
    ( if Name = "corr" then text(Corr)
      else if Name = "code" then text(Code)
      else if Name = "message" then text(Message)
      else if Name = "ts" then int(Received)
      else null ).

:- pred entered(assert_result::in) is semidet.

entered(inserted(_)).
entered(noop(_)).
entered(replaced(_, _)).

:- func refusal_text(assert_outcome) = string.

refusal_text(Outcome) =
    ( if Outcome = error(status_error(_, Detail)) then Detail
      else "the answer was refused" ).

%---------------------------------------------------------------------------%
% The clock
%---------------------------------------------------------------------------%

    % A halted engine and a live clock answer first, as libds's do
    % (`clock_call`), so this asks only of a mock clock on a live engine.
    %
advance(D, Step, !S) :-
    ( if
        not refused_call(!.S, _),
        !.S ^ ses_config ^ session_config_clock \= live_clock,
        engine_advance_past_range(!.S ^ ses_engine, D)
    then
        Step = step(error(status_error(time_range,
            "an advance past a clock's range")), [], [])
    else
        clock_call(ds.engine.advance(D), Step, !S)
    ).

    % The engine refuses a backward set after the first sample by leaving the
    % clock where it was, and has no status to say so. So the clock not reading
    % `At` is the refusal, and the host is told as libds tells it ([NTST.3.1]).
    % A set past the top of the range is asked first, as `advance` asks.
    %
set_clock(At, Step, !S) :-
    ( if
        not refused_call(!.S, _),
        !.S ^ ses_config ^ session_config_clock \= live_clock,
        ntst_3_1_set_past_range(At)
    then
        Step = step(error(status_error(time_range,
            "a set past the monotonic clock's range")), [], [])
    else
        clock_call(ds.engine.set_clock(At), Step0, !S),
        ( if
            Step0 ^ step_outcome = ok,
            engine_clock_now(!.S ^ ses_engine) \= At
        then
            Step = Step0 ^ step_outcome := error(status_error(state,
                "the clock has been sampled, and a set may not move it back"))
        else
            Step = Step0
        )
    ).

    % The order libds's `ds_engine_wall_clock_set` answers in.
    %
set_wall_clock(Utc, Outcome, !S) :-
    ( if refused_call(!.S, Refusal) then
        Outcome = error(Refusal)
    else if !.S ^ ses_config ^ session_config_clock = live_clock then
        Outcome = error(status_error(state,
            "the clock is live; set_wall_clock is mock-only"))
    else
        ds.engine.set_wall_clock(Utc, !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        Outcome = ok
    ).

:- pred clock_call(pred(list(effect), engine, engine)::in(pred(out, in, out)
    is det), step::out, session::in, session::out) is det.

clock_call(Move, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = step(error(Refusal), [], [])
    else if !.S ^ ses_config ^ session_config_clock = live_clock then
        Step = step(error(status_error(state,
            "the clock is live; advance and set_clock are mock-only")), [],
            [])
    else
        Move(Effects, !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        reports(Effects, Reports, !S),
        list.filter_map(duty_of, Effects, Duties),
        Step = step(reporting_halt(!.S, ok), Reports, Duties)
    ).

    % A mock clock moves only by `advance`, `set_clock` and
    % `set_wall_clock`, so it is not read.
    %
read_clock(!S, !IO) :-
    Clock = !.S ^ ses_config ^ session_config_clock,
    (
        Clock = live_clock,
        read_wall_clock(Reading, !IO),
        observe_wall_clock(Reading, !.S ^ ses_engine, E),
        !S ^ ses_engine := E
    ;
        Clock = mock_clock
    ).

%---------------------------------------------------------------------------%
% The cache
%---------------------------------------------------------------------------%

cache_seed(Key, Value, Ttl, Outcome, !S) :-
    ( if refused_call(!.S, Refusal) then
        Outcome = error(Refusal)
    else if Ttl = yes(Zero), duration_ns(Zero) = 0u64 then
        Outcome = error(status_error(inval,
            "a zero TTL is no expiry; pass `no` for that"))
    else
        seed_cache(Key, Value, Ttl, Result, !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        Outcome = reporting_halt(!.S, seed_outcome(Result))
    ).

:- func seed_outcome(seed_result) = outcome.

seed_outcome(seeded) = ok.
seed_outcome(seed_after_pump) =
    error(status_error(state,
        "cache_seed: not permitted after the first pump")).
seed_outcome(seed_halted(_)) = error(halted_error).
seed_outcome(seed_nonfinite) =
    error(status_error(json_nonfinite,
        "cache_seed: a non-finite Float has no JSON spelling")).
seed_outcome(seed_json_limit(_)) =
    error(status_error(json_limit, "cache_seed: the value is over a limit")).
seed_outcome(seed_capped(_)) =
    error(status_error(contract_breach,
        "cache_seed: the seed would exceed a cache cap")).
    % Unreached: this binding seeds a term, never text. libds's parser answers
    % such text DS_ERR_PARSE.
seed_outcome(seed_text_refused(_)) =
    error(status_error(parse, "cache_seed: the text is not one JSON value")).
seed_outcome(seed_time_range) =
    error(status_error(time_range,
        "cache_seed: the TTL is longer than the Time range")).
seed_outcome(seed_encoding) =
    error(status_error(encoding,
        "cache_seed: the key or the value's text is not well-formed UTF-8")).

%---------------------------------------------------------------------------%
% Recording and replay
%---------------------------------------------------------------------------%

start_recording(!S) :-
    E = !.S ^ ses_engine,
    % The clock when it begins, which each recorded tick moves on
    % (`ds.rfcs.encode_stream`), and the engine's own count, so each atom
    % carries the `seq` the engine gave its event.
    Recorder = recorder(engine_now(E), engine_event_count(E), []),
    !S ^ ses_recorder := yes(Recorder).

stop_recording(!S) :-
    !S ^ ses_recorder := no.

recording(S) = Result :-
    MaybeRecorder = S ^ ses_recorder,
    (
        MaybeRecorder = yes(R),
        E = S ^ ses_engine,
        Effects = list.reverse(R ^ rcd_effects),
        % The engine's schemas and interns now: the schemas are the
        % artefact's, and a string interned since is in the table, so these
        % are the ones the recorded events name.
        Context = ds.rfcs.rfcs_ctx(engine_schemas(E), engine_interns(E)),
        % [RFCS.26.1]: the host's seeds, when the recording began before the
        % engine's first event; one begun after it writes none, as libds's
        % recorder attached late writes none.
        ( if R ^ rcd_first = 0u64 then
            Seeds = ds.engine.prelude_seeds(E)
        else
            Seeds = []
        ),
        ds.rfcs.encode_recording(ds.engine.session_header(E), Context,
            R ^ rcd_origin, Seeds,
            ds.rfcs.record_items(R ^ rcd_first, Effects),
            Bytes0, Unencodable),
        % libds's recorder writes the header and the schemas at the first
        % event after it begins, so over no event it has written nothing.
        ( if list.find_first_match(is_event, Effects, _) then
            Bytes = Bytes0
        else
            Bytes = []
        ),
        Result = yes(recording(bytes_bitmap(Bytes), Unencodable))
    ;
        MaybeRecorder = no,
        Result = no
    ).

:- pred is_event(effect::in) is semidet.

is_event(eff_event(_)).

    % Keep a call's effects, if the session is recording.
    %
:- pred record(list(effect)::in, session::in, session::out) is det.

record(Effects, !S) :-
    MaybeRecorder = !.S ^ ses_recorder,
    (
        MaybeRecorder = yes(R0),
        R = R0 ^ rcd_effects := list.reverse(Effects) ++ R0 ^ rcd_effects,
        !S ^ ses_recorder := yes(R)
    ;
        MaybeRecorder = no
    ).

replay(Bytes, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = step(error(Refusal), [], [])
    else
        ds.rfcs.decode_stream(Bytes, init_interns, Decoded),
        (
            Decoded = ds.rfcs.decode_failed(Clause, Offset),
            Step = step(error(status_error(decode_status(Clause),
                string.format("replay refused [%s] at byte %d",
                    [s(Clause), i(Offset)]))), [], [])
        ;
            Decoded = ds.rfcs.decoded(Stream),
            ds.replay.replay_stream(!.S ^ ses_program, Stream, Steps,
                !.S ^ ses_engine, E),
            replayed(Steps, E, Step, !S)
        ;
            % [RFCS.5.4]: the reader stopped at a FactAssert no
            % SchemaDef announced. What came before it is replayed, and the
            % replay is refused there, as libds's replay is.
            Decoded = ds.rfcs.unannounced_schema(Stream, Seq, _),
            ds.replay.replay_unannounced(!.S ^ ses_program, Stream, Seq, Steps,
                !.S ^ ses_engine, E),
            replayed(Steps, E, Step, !S)
        )
    ).

    % A replay's steps into the session: its engine, and one run of effects
    % for every step, as one call of the engine emitted them, their numbers
    % counted back from the engine's count after the last.
    %
:- pred replayed(list(ds.replay.replay_step)::in, engine::in, step::out,
                 session::in, session::out) is det.

replayed(Steps, E, Step, !S) :-
    !S ^ ses_engine := E,
    % [RFCS.10.5]: a recorded sample put the engine on the mock clock,
    % as libds's replay sets DS_CLOCK_MOCK, so the session's clock is that one
    % from here: `clock_mode`, `advance` and `read_clock` all ask the config.
    ( if engine_clock_mode(E) = mock then
        !S ^ ses_config ^ session_config_clock := mock_clock
    else
        true
    ),
    replay_effects(Steps, Effects, ok, Outcome),
    reports(Effects, Reports, !S),
    % NO DUTIES: a replay reaches no host store ([NDET.8.2]), as libds's
    % invokes no persistence callback while it runs.
    Step = step(Outcome, Reports, []).

    % libds's status for a recording its reader refuses (`codec.c`): another
    % series has its own, and the rest of what the reader refuses is a parse
    % error.
    %
:- func decode_status(string) = status.

decode_status(Clause) =
    ( if Clause = "LDET.1.10" then fs_version
      else parse ).

    % The effects of each replayed step, in order, and the first failure
    % ([NCBK.1.5]).
    %
:- pred replay_effects(list(ds.replay.replay_step)::in, list(effect)::out,
    outcome::in, outcome::out) is det.

replay_effects([], [], !Outcome).
replay_effects([Step | Steps], Effects, !Outcome) :-
    replay_step_effects(Step, Here, !Outcome),
    replay_effects(Steps, Rest, !Outcome),
    Effects = Here ++ Rest.

:- pred replay_step_effects(ds.replay.replay_step::in, list(effect)::out,
    outcome::in, outcome::out) is det.

replay_step_effects(Step, Effects, !Outcome) :-
    (
        Step = ds.replay.delivered(Effects)
    ;
        Step = ds.replay.pumped(Effects)
    ;
        Step = ds.replay.unknown_schema(Seq),
        % [RFCS.5.4]: the replay stopped at that FactAssert.
        note_failure(status_error(schema_unknown,
            "replay: the FactAssert at seq " ++ uint64_to_string(Seq) ++
            " names a schema the engine does not hold"), !Outcome),
        Effects = []
    ;
        Step = ds.replay.unknown_fact_id(Seq),
        % [RFCS.7.3]: the replay stopped at that FactRetract.
        note_failure(status_error(fs_unknown_fact_id,
            "replay: the FactRetract at seq " ++ uint64_to_string(Seq) ++
            " names a fact no earlier atom carries"), !Outcome),
        Effects = []
    ;
        Step = ds.replay.recording_incomplete(First),
        note_failure(status_error(fs_recording_incomplete,
            "replay: the recording's first event has seq " ++
            uint64_to_string(First) ++ ", not 0"), !Outcome),
        Effects = []
    ;
        Step = ds.replay.binding_refused(Code, Detail),
        % The runtime gives libds's own code for the refusal, -700, -701 or
        % -703; any other is a bug in the runtime.
        ( if number_status(Code, Status) then
            note_failure(status_error(Status, "replay: " ++ Detail),
                !Outcome)
        else
            require.error("mercury_ds.session.replay: a binding refusal "
                ++ "with no status, " ++ string.int_to_string(Code))
        ),
        Effects = []
    ;
        Step = ds.replay.diverged(Seq),
        note_failure(status_error(fs_divergence,
            "replay: the input at seq " ++ uint64_to_string(Seq) ++
            " did not reproduce the recording"), !Outcome),
        Effects = []
    ;
        Step = ds.replay.input_refused(Seq, Code, Detail),
        % [RFCS.6.7]: the runtime gives libds's own code for it.
        ( if number_status(Code, Status) then
            note_failure(status_error(Status,
                "replay: the input at seq " ++ uint64_to_string(Seq) ++
                " was refused: " ++ Detail), !Outcome)
        else
            require.error("mercury_ds.session.replay: a refused input with "
                ++ "no status, " ++ string.int_to_string(Code))
        ),
        Effects = []
    ).

%---------------------------------------------------------------------------%
% Configuration
%---------------------------------------------------------------------------%

set_fire_budget(Budget, Outcome, !S) :-
    % [NCBK.2.9] names a configuration setter among the refused calls. libds
    % has no call for this one, and the clause binds it all the same.
    ( if refused_call(!.S, Refusal) then
        Outcome = error(Refusal)
    else if negative_budget(Budget) then
        Outcome = error(status_error(inval,
            "set_fire_budget: a negative firing limit"))
    else
        !S ^ ses_config ^ session_config_budget := Budget,
        Outcome = ok
    ).

set_cache_cap(Keys, Bytes, Outcome, !S) :-
    % [NCBK.2.9], as `ds_engine_set_cache_cap` refuses it first.
    ( if refused_call(!.S, Refusal) then
        Outcome = error(Refusal)
    else if Keys < 0 ; Bytes < 0 then
        Outcome = error(status_error(inval,
            "set_cache_cap: a negative bound"))
    else if Keys > max_key_cap then
        Outcome = error(status_error(inval,
            "set_cache_cap: a key bound past libds's 32-bit count"))
    else
        ds.engine.set_cache_cap(uint32.cast_from_int(Keys),
            uint64.cast_from_int(Bytes), !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        Outcome = ok
    ).

    % The largest key bound `ds_engine_set_cache_cap`'s `uint32_t` holds.
    %
:- func max_key_cap = int.

max_key_cap = 4_294_967_295.

:- pred negative_budget(fire_budget::in) is semidet.

negative_budget(fire_budget(N)) :-
    N < 0.

%---------------------------------------------------------------------------%
% Reads
%---------------------------------------------------------------------------%

    % [NCBK.2.9]: each read is refused once the
    % engine has halted, decided by the latch alone, as libds's are. The
    % value is a closure so that nothing reads the halted engine's state to
    % build an answer no one gets. `ds.engine`'s own reads stay total: they
    % are the runtime's internals, which guard no integrator.
    %
:- func reading(session, (func) = T) = read(T).

reading(S, Value) = Read :-
    ( if engine_halted(S ^ ses_engine) = yes(Error) then
        Read = halted(Error)
    else
        Read = ok(apply(Value))
    ).

schema_names(S) = reading(S, (func) = all_schema_names(S)).

:- func all_schema_names(session) = list(string).

all_schema_names(S) =
        list.map(schema_name_string(Interns), visible_schemas(S)) :-
    Interns = engine_interns(S ^ ses_engine).

fact_count(S) = reading(S, (func) = engine_fact_count(S ^ ses_engine)).

facts(S) = reading(S, (func) = all_facts(S)).

:- func all_facts(session) = list(fact_view).

all_facts(S) = list.condense(list.map(schema_facts(Interns, WM),
        visible_schemas(S))) :-
    E = S ^ ses_engine,
    Interns = engine_interns(E),
    WM = engine_wm(E).

search_fact(S, Id, Read) :-
    ( if engine_halted(S ^ ses_engine) = yes(Error) then
        Read = halted(Error)
    else
        live_fact_view(S, Id, View),
        Read = ok(View)
    ).

:- pred live_fact_view(session::in, fact_id::in, fact_view::out) is semidet.

live_fact_view(S, Id, View) :-
    E = S ^ ses_engine,
    Interns = engine_interns(E),
    ds.wm.lookup_fact(engine_wm(E), Id, F),
    list.find_first_match(has_id(F ^ f_schema), visible_schemas(S), Schema),
    View = view_of(Interns, schema_name_string(Interns, Schema), F).

lookup_fact(S, Id) = Read :-
    ( if search_fact(S, Id, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.session.lookup_fact: no live fact " ++
            uint64_to_string(fact_id_value(Id)))
    ).

now(S) = reading(S, (func) = engine_clock_now(S ^ ses_engine)).

next_deadline(S) = reading(S, (func) = nlfc_2_5_next_deadline(S ^ ses_engine)).

halted(S) = engine_halted(S ^ ses_engine).

clock_mode(S) = reading(S, (func) = S ^ ses_config ^ session_config_clock).

memory_usage(S) = reading(S, (func) = engine_mem(S ^ ses_engine)).

run_id(S) = reading(S, (func) = ds.engine.run_id(S ^ ses_engine)).

tier_id(S) = reading(S, (func) = ds.engine.tier_id(S ^ ses_engine)).

session_header(S) = ds.engine.session_header(S ^ ses_engine).

search_schema(S, Name, Read) :-
    ( if engine_halted(S ^ ses_engine) = yes(Error) then
        Read = halted(Error)
    else
        find_schema(S, Name, Schema),
        Read = ok(Schema)
    ).

lookup_schema(S, Name) = Read :-
    ( if search_schema(S, Name, Read0) then
        Read = Read0
    else
        require.error("mercury_ds.session.lookup_schema: no schema named " ++
            Name)
    ).

slot_names(S, Schema) = reading(S, (func) = schema_slot_names(S, Schema)).

:- func schema_slot_names(session, schema) = list(string).

schema_slot_names(S, Schema) =
        list.map(slot_name(Interns), slot_commons(Schema)) :-
    Interns = engine_interns(S ^ ses_engine).

:- func slot_name(intern_table, slot_common) = string.

slot_name(Interns, Common) =
    ( if expand(Interns, Common ^ sc_name, Name) then Name else "" ).

slot_to_stored(Schema, Index, In, Step, !S) :-
    through_unit(Schema, Index, ud_to_stored, In, Step, !S).

slot_from_stored(Schema, Index, In, Step, !S) :-
    through_unit(Schema, Index, ud_from_stored, In, Step, !S).

:- pred through_unit(schema::in, int::in, unit_direction::in, storable::in,
    unit_step::out, session::in, session::out) is det.

through_unit(Schema, Index, Direction, In, Step, !S) :-
    ( if refused_call(!.S, Refusal) then
        Step = unit_step(error(Refusal), [])
    else
        nfct_1_4_6_convert(Schema, Index, Direction, to_value(In), Outcome,
            Effects, !.S ^ ses_engine, E),
        !S ^ ses_engine := E,
        reports(Effects, Reports, !S),
        Step = unit_step(unit_result(Outcome), Reports)
    ).

    % libds's answer for each of the runtime's conversion outcomes.
    %
:- func unit_result(unit_outcome) = maybe_error(storable, ds_error).

unit_result(Outcome) = Result :-
    (
        Outcome = uo_ok(V),
        ( if V = int(I) then
            Result = ok(int(I))
        else if V = float(F) then
            Result = ok(float(F))
        else
            require.unexpected($pred, "a conversion's value is neither")
        )
    ;
        Outcome = uo_no_slot,
        Result = error(status_error(not_found,
            "the index names no slot of the schema"))
    ;
        Outcome = uo_no_unit,
        Result = error(status_error(inval, "the slot names no unit"))
    ;
        Outcome = uo_kind_mismatch,
        Result = error(status_error(slot_type_mismatch,
            "the value is not of the kind the slot stores"))
    ;
        Outcome = uo_nan,
        Result = error(status_error(nan_rejected, "the value is a NaN"))
    ;
        Outcome = uo_halted,
        Result = error(halted_error)
    ;
        Outcome = uo_not_representable,
        Result = error(status_error(not_representable,
            "the conversion has no result for this number"))
    ).

session_engine(S) = S ^ ses_engine.

session_program(S) = S ^ ses_program.

%---------------------------------------------------------------------------%
% Shared pieces
%---------------------------------------------------------------------------%

    % The reports of the run of effects the engine last emitted. Their
    % events are numbered as the engine numbered them: it counts every event
    % it emits, so the first of these took its count less theirs. They are
    % clocked on from the last event's clock. Every sample that moves the
    % clock emits a `tick` before its step's events ([LTIM.2.8.5]), so a
    % run that holds several steps, as a replay's does, clocks each step's
    % events at that step's sample.
    %
:- pred reports(list(effect)::in, list(report)::out,
    session::in, session::out) is det.

reports(Effects, Reports, !S) :-
    E = !.S ^ ses_engine,
    Emitted = uint64.cast_from_int(list.length(list.filter(is_event,
        Effects))),
    First = engine_event_count(E) - Emitted,
    effect_reports(engine_interns(E), engine_schemas(E), Effects, Reports,
        !.S ^ ses_clock, Clock, First, _),
    !S ^ ses_clock := Clock,
    % Every effect list a call gets from the engine passes through here, so
    % this is where a recording keeps them.
    record(Effects, !S).

    % The first failure is the one reported ([NCBK.1.5]).
    %
:- pred note_failure(ds_error::in, outcome::in, outcome::out) is det.

note_failure(Error, ok, error(Error)).
note_failure(_, error(First), error(First)).

    % Why a call that changes the session is refused before it starts: a
    % halted engine ([NCBK.2.9]).
    %
:- pred refused_call(session::in, ds_error::out) is semidet.

refused_call(S, halted_error) :-
    engine_halted(S ^ ses_engine) = yes(_).

:- func halted_error = ds_error.

halted_error = status_error(engine_halted, "the engine has halted").

    % [NCBK.2.9]: the call during which the
    % engine raised an EngineError reports the halt, ahead of whatever it
    % would have returned, as libds's does (`ds_api_leave`). Only a call
    % `refused_call` let start reaches this, so a latch set now was set by
    % the call: a pump whose firing faulted, an assert or retract whose
    % propagation did.
    %
:- func reporting_halt(session, outcome) = outcome.

reporting_halt(S, Outcome) =
    ( if engine_halted(S ^ ses_engine) = yes(_) then error(halted_error)
      else Outcome ).

:- func reporting_halt_assert(session, assert_outcome) = assert_outcome.

reporting_halt_assert(S, Outcome) =
    ( if engine_halted(S ^ ses_engine) = yes(_) then error(halted_error)
      else Outcome ).

    % The schemas a host can see: the engine's, less those the compiler
    % made for itself, which libds keeps out of its registry.
    %
:- func visible_schemas(session) = list(schema).

visible_schemas(S) = Visible :-
    E = S ^ ses_engine,
    Interns = engine_interns(E),
    list.filter(visible(Interns), engine_schemas(E), Visible).

:- pred visible(intern_table::in, schema::in) is semidet.

visible(Interns, Schema) :-
    not synthetic(Interns, Schema).

:- pred find_schema(session::in, string::in, schema::out) is semidet.

find_schema(S, Name, Schema) :-
    Interns = engine_interns(S ^ ses_engine),
    list.find_first_match(named(Interns, Name), visible_schemas(S), Schema).

:- pred named(intern_table::in, string::in, schema::in) is semidet.

named(Interns, Name, Schema) :-
    expand(Interns, schema_name_ref(Schema ^ s_name), Name).

:- pred has_id(schema_id::in, schema::in) is semidet.

has_id(Id, Schema) :-
    Schema ^ s_id = Id.

:- func schema_name_string(intern_table, schema) = string.

schema_name_string(Interns, Schema) =
    ( if expand(Interns, schema_name_ref(Schema ^ s_name), Name) then Name
      else "" ).

:- func schema_facts(intern_table, wm, schema) = list(fact_view).

schema_facts(Interns, WM, Schema) =
    list.map(view_of(Interns, schema_name_string(Interns, Schema)),
        facts_of_schema(WM, Schema ^ s_id)).

%---------------------------------------------------------------------------%

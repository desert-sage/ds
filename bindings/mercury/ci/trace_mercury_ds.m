%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: trace_mercury_ds.m.
%
% The mercury_ds driver of the binding differential: run one scenario of
% the runtime lockstep corpus (runtime/mercury/test/scenarios) against an
% artefact through mercury_ds, and print the canonical trace.
%
%   trace_mercury_ds ARTEFACT.dsc SCENARIO.scn
%
% It is the pyds driver, trace_libds.py, translated:
% the same steps, the same lines and the same refusal rules, in the same
% order, so that a difference between two bindings' traces is one between
% the bindings and never one between their drivers. A step, a line or a rule
% changed there is changed here in the same commit, as it is in
% trace_js.mjs.
%
% Translated, not transliterated. A scenario is parsed into a closed union
% of steps, and the run is a `det` fold over them with the session as a
% value. A step the binding refuses is traced, as trace_libds.py traces a
% `pyds.Error`, and so is a load it refuses, which pyds's exception would
% stop: `load_refused <status>`, and nothing after it. A step this driver
% cannot perform is a value, `error(Why)`, that stops the run, where pyds
% would raise something else: a stopped run prints nothing on standard
% output and exits 1, as an exception stops trace_libds.py before it prints
% its trace.
%
% It drives the session through mercury_ds alone, and reads two of the
% runtime's own values where the binding hands a host the runtime's type,
% as mercury_ds.m says a host does: a slot's nullability, in the runtime's
% `schema`, and a fact's FactExternal bytes, which the runtime's
% `encode_fact_external` writes.
%
% A host is handed what a libds integrator's callbacks receive when a call
% returns, as data, and not by a callback inside it. So
% the trace places each callback's line by what the data says of it:
%
% - A rule's `call` is reported in the stream where the rule issued it, and
%   handed over again in the pump's calls, the same calls in the same
%   order. `cb_call` is printed at the first, where libds calls its
%   callback, and a pump whose two lists disagree stops the run, since the
%   placing would then be unfounded.
% - A cache entry's expiry is reported where it happened, among the pump's
%   reports, and handed over again as a duty. `cb_cache_expired` is printed
%   at the report, where libds calls its callback ([NSTG.2.4.2]).
%
% Where the binding gives a host otherwise than pyds does, the trace shows
% what the binding gives, because that difference is what the differential
% exists to find.
%
%---------------------------------------------------------------------------%

:- module trace_mercury_ds.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.
:- import_module mercury_ds.error.
:- import_module mercury_ds.events.
:- import_module mercury_ds.host.
:- import_module mercury_ds.introspect.
:- import_module mercury_ds.session.
:- import_module mercury_ds.status.
:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.action.
:- import_module ds.chrono.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fact_external.
:- import_module ds.id.
:- import_module ds.names.
:- import_module ds.schema.
:- import_module assoc_list.
:- import_module bitmap.
:- import_module bool.
:- import_module char.
:- import_module cord.
:- import_module float.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint64.
:- import_module uint8.

%---------------------------------------------------------------------------%

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    io.stderr_stream(Stderr, !IO),
    ( if Args = [ArtefactPath, ScenarioPath] then
        read_text(ScenarioPath, Scenario, !IO),
        read_artefact(ArtefactPath, Artefact, !IO),
        Traced = trace_run(ScenarioPath, Scenario, Artefact),
        (
            Traced = ok(ran(Lines, Notes)),
            list.foldl(put_line(Stderr), cord.list(Notes), !IO),
            io.stdout_stream(Stdout, !IO),
            list.foldl(put_line(Stdout), cord.list(Lines), !IO)
        ;
            Traced = error(Why),
            put_line(Stderr, "trace_mercury_ds: " ++ Why, !IO),
            io.set_exit_status(1, !IO)
        )
    else
        put_line(Stderr,
            "usage: trace_mercury_ds ARTEFACT.dsc SCENARIO.scn", !IO),
        io.set_exit_status(2, !IO)
    ).

:- pred put_line(io.text_output_stream::in, string::in, io::di, io::uo)
    is det.

put_line(Stream, Line, !IO) :-
    io.write_string(Stream, Line ++ "\n", !IO).

%---------------------------------------------------------------------------%
% The run
%---------------------------------------------------------------------------%

    % A run that finished: its trace, and what each refused step said.
    %
:- type ran
    --->    ran(
                ran_lines :: cord(string),
                            % The trace, for standard output.
                ran_notes :: cord(string)
                            % One line per refused step, for standard
                            % error, as trace_libds.py writes its
                            % `refused:` lines.
            ).

    % The run in progress.
    %
:- type run
    --->    run(
                run_session :: session,
                run_handles :: list(fact_id),
                            % The facts `retract N` and `trace N` name, in
                            % the order the steps gave them.
                run_sent    :: list(bitmap),
                            % The FactExternal bytes of every fact the run
                            % has sent as a call argument, in the order the
                            % calls were handed over and each call's
                            % arguments in their order: what `resend K`
                            % sends back.
                run_lines   :: cord(string),
                run_notes   :: cord(string)
            ).

    % Parse the scenario, load the artefact with the mock clock, run every
    % step, and end with the fact count, as trace_libds.py's `main` does.
    %
:- func trace_run(string, maybe_error(string, string),
    maybe_error(bitmap, string)) = maybe_error(ran, string).

trace_run(ScenarioPath, Scenario, Artefact) = Result :-
    (
        Scenario = error(Why),
        Result = error(Why)
    ;
        Scenario = ok(Text),
        Parsed = parse_lines(string.split_at_char('\n', Text)),
        (
            Parsed = error(Why),
            Result = error(ScenarioPath ++ ": " ++ Why)
        ;
            Parsed = ok(Steps),
            (
                Artefact = error(Why),
                Result = error(Why)
            ;
                Artefact = ok(Bytes),
                % MOCK CLOCK, ALWAYS, as trace_libds.py sets it: a wall
                % clock makes every run differ. `default_config`'s clock.
                load(Bytes, default_config, Loaded, LoadReports),
                (
                    % A LOAD THE BINDING REFUSES IS TRACED, not a stop:
                    % this runtime refuses artefacts libds loads
                    % (`unevaluable-test-refused` in divergences.jsonl),
                    % and that refusal is the binding's to show. The status
                    % is on the line; nothing follows it, as there is no
                    % session to run.
                    Loaded = error(Error),
                    Result = ok(ran(
                        cord.singleton("load_refused " ++ status_text(Error)),
                        cord.singleton("refused: load_dsc: " ++
                            error_text(Error))))
                ;
                    Loaded = ok(Session),
                    % The load's own log lines first ([RDSC.9.4]), as
                    % trace_libds.py registers its log callback before it
                    % loads.
                    trace_reports(LoadReports, _, start(Session), Loaded0),
                    run_steps(Steps, Loaded0, Finished),
                    (
                        Finished = error(Why),
                        Result = error(Why)
                    ;
                        Finished = ok(Run),
                        % A HALTED SESSION'S COUNT IS REFUSED ([NCBK.2.9]), so
                        % the line says so, as trace_libds.py's does.
                        Count = fact_count(Run ^ run_session),
                        (
                            Count = ok(N),
                            Final = "final facts=" ++ string.int_to_string(N)
                        ;
                            Count = halted(_),
                            Final = "final halted"
                        ),
                        Result = ok(ran(cord.snoc(Run ^ run_lines, Final),
                            Run ^ run_notes))
                    )
                )
            )
        )
    ).

:- func start(session) = run.

start(Session) = run(Session, [], [], cord.empty, cord.empty).

:- pred run_steps(list(scenario_step)::in, run::in,
    maybe_error(run, string)::out) is det.

run_steps([], Run, ok(Run)).
run_steps([Step | Steps], Run0, Result) :-
    run_step(Step, Run0, Stepped),
    (
        Stepped = ok(Run),
        run_steps(Steps, Run, Result)
    ;
        Stepped = error(Why),
        Result = error(Why)
    ).

%---------------------------------------------------------------------------%
% The steps
%---------------------------------------------------------------------------%

    % One step, as trace_libds.py's `main` and `apply_step` run it.
    %
:- pred run_step(scenario_step::in, run::in, maybe_error(run, string)::out)
    is det.

run_step(sc_assert(Name, Assigns), Run0, Result) :-
    S0 = Run0 ^ run_session,
    ( if search_schema(S0, Name, Read) then
        (
            Read = ok(Schema),
            Values = slot_values(S0, Schema, Name, Assigns)
        ;
            % A HALTED SESSION READS NO SCHEMA ([NCBK.2.9]), and `assert_fact`
            % refuses before it looks for one, as pyds's schema lookup
            % refuses in trace_libds.py.
            Read = halted(_),
            Values = ok([])
        ),
        (
            Values = error(Why),
            Result = error(Why)
        ;
            Values = ok(Slots),
            assert_fact(Name, Slots, Step, S0, S),
            trace_reports(Step ^ assert_step_reports, Breach,
                (Run0 ^ run_session := S), Run1),
            % THE HANDLE IS THE FACT LEFT LIVE, as pyds's `assert_` returns
            % it: the new fact, the live one an unchanged assert met, or the
            % one that replaced its predecessor.
            Outcome = Step ^ assert_step_outcome,
            (
                Outcome = asserted(Id),
                Run = add_handles([Id], Run1)
            ;
                Outcome = unchanged(Id),
                Run = add_handles([Id], Run1)
            ;
                Outcome = replaced(_, Id),
                Run = add_handles([Id], Run1)
            ;
                Outcome = error(Error),
                Run = refused("assert " ++ Name, Error, Breach, Run1)
            ),
            Result = ok(Run)
        )
    else
        % NO SUCH SCHEMA, so nothing to assert: one whose registration was
        % refused. trace_libds.py prints the same line from pyds's registry
        % and asserts nothing. Not a refusal, so not `engine_error`.
        Result = ok(add_line(["unknown_schema", Name], Run0))
    ).
run_step(sc_retract(N), Run0, Result) :-
    ( if list.index0(Run0 ^ run_handles, N, Id) then
        retract_fact(Id, Step, Run0 ^ run_session, S),
        Result = ok(stepped("retract", Step, (Run0 ^ run_session := S)))
    else
        Result = error(no_handle("retract", N, Run0))
    ).
run_step(sc_advance(Ns), Run0, Result) :-
    ( if Ns >= 0 then
        advance(duration_from_ns(uint64.det_from_int(Ns)), Step,
            Run0 ^ run_session, S),
        Result = ok(stepped("advance", Step, (Run0 ^ run_session := S)))
    else
        Result = error(negative("advance", Ns))
    ).
run_step(sc_set(At), Run0, Result) :-
    % An ABSOLUTE mock-clock instant, where `advance` is a delta. Not a
    % sample, so it emits nothing until the next input or pump samples it.
    ( if At >= 0 then
        set_clock(from_ns(uint64.det_from_int(At)), Step,
            Run0 ^ run_session, S),
        Result = ok(stepped("set", Step, (Run0 ^ run_session := S)))
    else
        Result = error(negative("set", At))
    ).
run_step(sc_wall(Utc), Run0, Result) :-
    % The mock wall clock, UTC ns. Not a sample. A refusal is traced as
    % `trace_libds.py` traces pyds's raise.
    set_wall_clock(int64.from_int(Utc), Outcome, Run0 ^ run_session, S),
    Run1 = Run0 ^ run_session := S,
    (
        Outcome = ok,
        Result = ok(Run1)
    ;
        Outcome = error(Error),
        Result = ok(refused("wall", Error, no, Run1))
    ).
run_step(sc_resend(K), Run0, Result) :-
    % The K-th fact this run sent as a call argument, from 0, asserted back
    % as another tier's ([NCBK.10.4]): the bytes this runtime wrote, as
    % pyds feeds back the ones libds wrote.
    Sent = Run0 ^ run_sent,
    ( if list.index0(Sent, K, Bytes) then
        S0 = Run0 ^ run_session,
        Before = live_ids(facts(S0)),
        assert_external(Bytes, Step, S0, S),
        trace_reports(Step ^ step_reports, _, (Run0 ^ run_session := S),
            Run1),
        Outcome = Step ^ step_outcome,
        (
            Outcome = ok,
            % A HANDLE FOR EACH FACT IT PUT INTO WORKING MEMORY, in
            % assertion order, which is id order: the facts live after it
            % and not before, so a no-op adds none.
            New = list.sort(list.filter(
                (pred(Id::in) is semidet :- not list.member(Id, Before)),
                live_ids(facts(S)))),
            Run = add_handles(New, Run1)
        ;
            % WHICH REFUSAL, by its status number, as trace_libds.py prints
            % it. A record turned away is not a breach, so not
            % `engine_error`.
            Outcome = error(Error),
            Run = add_line(["external_refused", status_text(Error)],
                note("resend " ++ string.int_to_string(K), Error, Run1))
        ),
        Result = ok(Run)
    else
        Result = error(string.format("resend %d: the run has sent %d facts",
            [i(K), i(list.length(Sent))]))
    ).
run_step(sc_pump, Run0, Result) :-
    % THE PUMP BOUNDARY MARKER, the driver's own and on every trace alike, so
    % that a run of bare `retract` lines can be told apart by pump.
    Run1 = add_line(["-- pump"], Run0),
    pump(Pumped, Run1 ^ run_session, S),
    ( if Pumped ^ pumped_calls = reported_calls(Pumped ^ pumped_reports) then
        trace_reports(Pumped ^ pumped_reports, Breach,
            (Run1 ^ run_session := S), Run2),
        Run3 = list.foldl(trace_duty, Pumped ^ pumped_duties, Run2),
        Outcome = Pumped ^ pumped_outcome,
        (
            Outcome = ok,
            Run = Run3
        ;
            Outcome = error(Error),
            Run = refused("pump", Error, Breach, Run3)
        ),
        Result = ok(Run)
    else
        Result = error("pump: the calls handed over are not the calls the "
            ++ "stream reported")
    ).
run_step(sc_refracted, Run0, ok(Run)) :-
    % [NDBG.4.3]'s listing, one line per entry. No fact ids: they are
    % engine-local, so the count and the row order are compared.
    % A halted session's listing is refused ([NCBK.2.9]): the line is the
    % marker trace_libds.py prints for it.
    Read = refracted_activations(Run0 ^ run_session, no),
    (
        Read = halted(_),
        Run = add_line(["refracted", "halted"], Run0)
    ;
        Read = ok(Entries),
        Run = list.foldl(trace_refracted, Entries, Run0)
    ).
run_step(sc_trace(N), Run0, Result) :-
    % [NDBG.4.2]'s match trace of the fact the N-th handle names, one line
    % per alpha node, the node id the artefact's. A halted session's is
    % refused, whatever the handle, as trace_libds.py marks it.
    ( if list.index0(Run0 ^ run_handles, N, Id) then
        Read = match_trace(Run0 ^ run_session, Id),
        (
            Read = halted(_),
            Result = ok(add_line(["trace", "halted"], Run0))
        ;
            Read = ok(Steps),
            Result = ok(list.foldl(trace_alpha_step, Steps, Run0))
        )
    else if halted(Run0 ^ run_session) = yes(_) then
        Result = ok(add_line(["trace", "halted"], Run0))
    else
        Result = error(no_handle("trace", N, Run0))
    ).
run_step(sc_mem, Run0, ok(Run)) :-
    % The logical counts only. The byte and intern fields are
    % implementation-defined ([NDBG.2.1]), so they are not on the line.
    % A HALTED SESSION'S STATE IS REFUSED ([NCBK.2.9]): the line is the marker
    % trace_libds.py prints for it.
    Read = memory_usage(Run0 ^ run_session),
    (
        Read = halted(_),
        Run = add_line(["mem", "halted"], Run0)
    ;
        Read = ok(M),
        Run = mem_line(M, Run0)
    ).

:- func mem_line(engine_mem, run) = run.

mem_line(M, Run0) = add_line(["mem",
        "wm_fact_count=" ++ string.int_to_string(M ^ em_wm_fact_count),
        "alpha_node_count=" ++ string.int_to_string(M ^ em_alpha_node_count),
        "alpha_match_count=" ++
            string.int_to_string(M ^ em_alpha_match_count),
        "beta_node_count=" ++ string.int_to_string(M ^ em_beta_node_count),
        "beta_token_count=" ++
            string.int_to_string(M ^ em_beta_token_count)], Run0).

    % A step's reports traced, and its refusal if it was refused.
    %
:- func stepped(string, step, run) = run.

stepped(What, Step, Run0) = Run :-
    trace_reports(Step ^ step_reports, Breach, Run0, Run1),
    Outcome = Step ^ step_outcome,
    (
        Outcome = ok,
        Run = Run1
    ;
        Outcome = error(Error),
        Run = refused(What, Error, Breach, Run1)
    ).

    % A step the binding refused: what it said, for standard error, and
    % the `engine_error` marker, unless the step's own stream already
    % carried the refusal, as a bounds error or as the EngineError that
    % halted the engine, each traced where it happened. trace_libds.py's
    % one translation: the marker says that a refusal happened at this
    % step, in a token both runtimes share, and compares where it
    % happened, not how it is worded.
    %
:- func refused(string, ds_error, bool, run) = run.

refused(What, Error, Breach, Run0) = Run :-
    Run1 = note(What, Error, Run0),
    (
        Breach = yes,
        Run = Run1
    ;
        Breach = no,
        Run = add_line(["engine_error"], Run1)
    ).

:- func note(string, ds_error, run) = run.

note(What, Error, Run) =
    Run ^ run_notes := cord.snoc(Run ^ run_notes,
        "refused: " ++ What ++ ": " ++ error_text(Error)).

:- func add_line(list(string), run) = run.

add_line(Words, Run) =
    Run ^ run_lines := cord.snoc(Run ^ run_lines,
        string.join_list(" ", Words)).

:- func add_handles(list(fact_id), run) = run.

add_handles(Ids, Run) = Run ^ run_handles := Run ^ run_handles ++ Ids.

    % The facts a read found; none from a halted session, whose working
    % memory is refused ([NCBK.2.9]), as pyds's `engine.facts` is.
    %
:- func live_views(read(list(fact_view))) = list(fact_view).

live_views(ok(Views)) = Views.
live_views(halted(_)) = [].

:- func live_ids(read(list(fact_view))) = list(fact_id).

live_ids(Read) =
    list.map((func(View) = View ^ fact_view_id), live_views(Read)).

:- func no_handle(string, int, run) = string.

no_handle(What, N, Run) =
    string.format("%s %d: the run has %d handles",
        [s(What), i(N), i(list.length(Run ^ run_handles))]).

:- func negative(string, int) = string.

negative(What, N) =
    string.format("%s %d: a negative instant", [s(What), i(N)]).

:- func error_text(ds_error) = string.

error_text(status_error(Status, Detail)) =
    string.format("[%d %s] %s",
        [i(status_number(Status)), s(status_name(Status)), s(Detail)]).

:- func status_text(ds_error) = string.

status_text(Error) = string.int_to_string(status_number(Status)) :-
    error_status(Error, Status).

%---------------------------------------------------------------------------%
% An assert's values
%---------------------------------------------------------------------------%

    % An assert's values in slot order, built as pyds builds them from its
    % keyword arguments: the value given for each slot, the last where a
    % name is given twice; `""` for an omitted `hydrated_corr`; `null` for
    % any other omitted slot that is nullable. A value that names no slot,
    % or an omitted slot that is not nullable, is a TypeError in pyds, which
    % stops trace_libds.py.
    %
:- func slot_values(session, schema, string,
    assoc_list(string, scenario_value)) = maybe_error(list(storable), string).

slot_values(S, Schema, Name, Assigns) = Result :-
    Read = slot_names(S, Schema),
    (
        % Not met: the step asks only once `search_schema` has answered, which
        % a halted session does not.
        Read = halted(_),
        Result = error("schema `" ++ Name ++ "`: the session has halted")
    ;
        Read = ok(Names),
        Result = named_values(S, Schema, Name, Assigns, Names)
    ).

:- func named_values(session, schema, string,
    assoc_list(string, scenario_value), list(string))
    = maybe_error(list(storable), string).

named_values(S, Schema, Name, Assigns, Names) = Result :-
    ( if
        list.find_first_match(
            (pred(Slot - _::in) is semidet :- not list.member(Slot, Names)),
            Assigns, Extra - _)
    then
        Result = error(string.format("schema `%s`: no slot `%s`",
            [s(Name), s(Extra)]))
    else
        Result = values_by_slot(S, Name, list.reverse(Assigns), Names,
            slot_commons(Schema))
    ).

:- func values_by_slot(session, string, assoc_list(string, scenario_value),
    list(string), list(slot_common)) = maybe_error(list(storable), string).

values_by_slot(_, _, _, [], []) = ok([]).
values_by_slot(_, Name, _, [], [_ | _]) = slots_differ(Name).
values_by_slot(_, Name, _, [_ | _], []) = slots_differ(Name).
values_by_slot(S, Name, Assigns, [Slot | Slots], [Common | Commons])
        = Result :-
    One = slot_value(S, Name, Assigns, Slot, Common),
    (
        One = error(Why),
        Result = error(Why)
    ;
        One = ok(Value),
        Rest = values_by_slot(S, Name, Assigns, Slots, Commons),
        (
            Rest = error(Why),
            Result = error(Why)
        ;
            Rest = ok(Values),
            Result = ok([Value | Values])
        )
    ).

:- func slots_differ(string) = maybe_error(list(storable), string).

slots_differ(Name) =
    error("schema `" ++ Name ++ "`: its slot names and slots differ").

:- func slot_value(session, string, assoc_list(string, scenario_value),
    string, slot_common) = maybe_error(storable, string).

slot_value(S, Name, Assigns, Slot, Common) = Result :-
    ( if assoc_list.search(Assigns, Slot, Value) then
        Result = storable_of(S, Value)
    else if Slot = "hydrated_corr" then
        Result = ok(text(""))
    else if Common ^ sc_nullable = nullable then
        Result = ok(null)
    else
        Result = error(string.format(
            "schema `%s`: missing kwarg for slot `%s`", [s(Name), s(Slot)]))
    ).

    % A scenario's value as the binding takes it: of the kind its text
    % spells, as trace_libds.py hands pyds a Python value of that kind. A
    % slot that does not take it is the binding's refusal.
    %
:- func storable_of(session, scenario_value) = maybe_error(storable, string).

storable_of(_, sv_int(I)) = ok(int(I)).
storable_of(_, sv_float(F)) = ok(float(F)).
storable_of(_, sv_text(Text)) = ok(text(Text)).
storable_of(_, sv_bool(B)) = ok(bool(B)).
storable_of(_, sv_null) = ok(null).
storable_of(_, sv_json(Text)) = Result :-
    Read = json_from_text(Text),
    (
        Read = ok(Json),
        Result = ok(json(Json))
    ;
        % trace_libds.py reads the text with Python's `json`, and a text
        % it cannot read stops the run.
        Read = error(Error),
        Result = error("json:" ++ Text ++ ": " ++ error_text(Error))
    ).
storable_of(S, sv_live(Schema)) = ok(Value) :-
    % THE EARLIEST-ASSERTED LIVE FACT OF THE SCHEMA, resolved when the step
    % runs: fact ids are minted in order. `null` when none is live.
    Live = list.sort(list.filter_map(
        (func(View) = Id is semidet :-
            View ^ fact_view_schema = Schema,
            Id = View ^ fact_view_id),
        live_views(facts(S)))),
    (
        Live = [First | _],
        Value = fact_ref(First)
    ;
        Live = [],
        Value = null
    ).

%---------------------------------------------------------------------------%
% Reports
%---------------------------------------------------------------------------%

    % A call's reports on the trace, in order, and whether its stream
    % carried a bounds error.
    %
:- pred trace_reports(list(report)::in, bool::out, run::in, run::out)
    is det.

trace_reports(Reports, Breach, !Run) :-
    list.foldl2(trace_report, Reports, no, Breach, !Run).

:- pred trace_report(report::in, bool::in, bool::out, run::in, run::out)
    is det.

trace_report(streamed(Event), !Breach, !Run) :-
    trace_event(Event ^ integrator_event_kind, !Breach, !Run).
trace_report(logged(_), !Breach, !Run) :-
    % THE LOG CALLBACK, a bare line for each call of it, as trace_libds.py
    % prints libds's: the arguments are not compared.
    !:Run = add_line(["cb_log"], !.Run).
trace_report(measured(Metric), !Breach, !Run) :-
    !:Run = add_line(metric_words(Metric), !.Run).
trace_report(cache_expired(Key), !Breach, !Run) :-
    % THE CACHE-REMOVAL HANDLER, FOR AN EXPIRY ONLY, as trace_libds.py
    % registers it, where the report places it ([NSTG.2.4.2]): a rule's
    % `cache_delete` is traced from the stream already.
    !:Run = add_line(["cb_cache_expired", Key], !.Run).

    % trace_libds.py's `on_stream`, kind by kind. What is not in its
    % vocabulary is dropped there, and prints nothing here.
    %
:- pred trace_event(event_kind::in, bool::in, bool::out, run::in, run::out)
    is det.

trace_event(Kind, !Breach, !Run) :-
    (
        Kind = fact_assert(_, Schema, _),
        !:Run = add_line(["assert", schema_text(Schema)], !.Run)
    ;
        Kind = fact_retract(_),
        !:Run = add_line(["retract"], !.Run)
    ;
        Kind = rule_lhs_facts(Activation, Facts),
        !:Run = add_line(["lhs", Activation ^ activation_rule,
            string.int_to_string(list.length(Facts))], !.Run)
    ;
        Kind = rule_fire_begin(Activation),
        !:Run = add_line(["fire_begin", Activation ^ activation_rule], !.Run)
    ;
        Kind = rule_fire_end(Activation),
        !:Run = add_line(["fire_end", Activation ^ activation_rule], !.Run)
    ;
        % THE CORRELATION AND THE ARGUMENTS ARE COMPARED, the arguments
        % last because they hold commas and may hold spaces. Then the call
        % callback's line, here, where the stream places the call.
        Kind = action_call(Call),
        !:Run = add_line(["call", Call ^ service_call_service,
            correlation_text(Call ^ service_call_correlation),
            arguments_text(Call ^ service_call_args)], !.Run),
        !:Run = handed_over(Call, !.Run)
    ;
        Kind = action_emit(_, Schema),
        !:Run = add_line(["emit", schema_text(Schema)], !.Run)
    ;
        % THE FactExternal IS COMPARED ([NCBK.10.1]), as a fact call
        % argument's is.
        Kind = action_publish(Schema, _, External),
        !:Run = add_line(["publish", schema_text(Schema),
            published_text(External)], !.Run)
    ;
        Kind = action_cache_set(_),
        !:Run = add_line(["cache_set"], !.Run)
    ;
        Kind = action_cache_delete(_),
        !:Run = add_line(["cache_delete"], !.Run)
    ;
        % THE MESSAGE IS COMPARED, last because it may hold spaces.
        Kind = action_log(log_line(Level, _, Message)),
        !:Run = add_line(["log", log_level_name(Level), Message], !.Run)
    ;
        Kind = tick(_),
        !:Run = add_line(["tick"], !.Run)
    ;
        Kind = timer_armed(Activation, _, _),
        !:Run = add_line(["timer_armed", Activation ^ activation_rule], !.Run)
    ;
        % ONE TOKEN PER FAULT CLASS ([LERR.1]), where the fault happened;
        % the payload is not compared.
        Kind = type_error(_),
        !:Run = add_line(["fault", "type"], !.Run)
    ;
        Kind = computation_error(_, _),
        !:Run = add_line(["fault", "computation"], !.Run)
    ;
        % The call that raised it reports the halt as its outcome
        % ([NCBK.2.9]), already on the stream here, so no refusal
        % marker follows it: trace_libds.py's rule.
        Kind = engine_error(_, _),
        !:Run = add_line(["fault", "engine"], !.Run),
        !:Breach = yes
    ;
        % A DECLARED CAP REACHED: the refused-operation token, where the
        % refusal happened, and no marker after the step for it.
        Kind = bounds_error(_, _),
        !:Run = add_line(["engine_error"], !.Run),
        !:Breach = yes
    ;
        % The driver's `-- pump` marker is this line already.
        Kind = pump
    ).

    % pyds names a fact's schema `?` where it cannot read it, and the
    % binding gives an empty name.
    %
:- func schema_text(string) = string.

schema_text(Name) = ( if Name = "" then "?" else Name ).

    % A call's correlation, always present ([LCRS.3.1]). `-` for an
    % empty one, as `trace_libds.py` and `trace_js.mjs` print a falsy one, so
    % the three traces still agree token for token if a runtime ever breaks
    % [LCRS.3.1].
    %
:- func correlation_text(string) = string.

correlation_text(Correlation) =
    ( if Correlation = "" then "-" else Correlation ).

:- func published_text(maybe(fact_external)) = string.

published_text(no) = "-".
published_text(yes(External)) =
    ( if
        encode_fact_external(External, Bytes),
        Bytes = [_ | _]
    then
        "fact:" ++ hex(Bytes)
    else
        "-"
    ).

    % `metric <name> <kind> <labels>`, the labels sorted by key, a counter's
    % value last, and a gauge's not on the line: the intern gauges' values
    % are implementation-defined ([NMET.4.7]).
    %
:- func metric_words(metric) = list(string).

metric_words(metric(Name, Kind, Value, Labels)) = Words :-
    Sorted = list.sort(Labels),
    LabelText = ( if Sorted = [] then "-"
                  else string.join_list(",", list.map(label_text, Sorted)) ),
    Head = ["metric", Name, metric_kind_name(Kind), LabelText],
    (
        Kind = mk_counter,
        Words = Head ++ [python_float(Value)]
    ;
        Kind = mk_gauge,
        Words = Head
    ).

:- func label_text({string, string}) = string.

label_text({Key, Value}) = Key ++ "=" ++ Value.

    % A call's arguments, `{"name":value,...}` in their order, as
    % trace_libds.py's `trace_args` renders pyds's: a Json value as its
    % text unquoted, Bytes as a JSON string of lower-case hex, a fact as
    % `fact:` and its FactExternal bytes in hex.
    %
:- func arguments_text(list(arg)) = string.

arguments_text(Args) =
    "{" ++ string.join_list(",", list.map(argument_text, Args)) ++ "}".

:- func argument_text(arg) = string.

argument_text(arg(Name, Value)) =
    json_string(Name) ++ ":" ++ argument_value_text(Value).

:- func argument_value_text(arg_value) = string.

argument_value_text(av_int(I)) = string.int_to_string(int64.cast_to_int(I)).
argument_value_text(av_float(F)) = python_float(F).
argument_value_text(av_string(S)) = json_string(S).
argument_value_text(av_bool(yes)) = "true".
argument_value_text(av_bool(no)) = "false".
argument_value_text(av_json(Text)) = Text.
argument_value_text(av_bytes(Bytes)) = json_string(hex(Bytes)).
argument_value_text(av_null) = "null".
    % A slot's reference, which no call argument carries: a call hands its
    % fact encoded.
argument_value_text(av_fact_ref(_)) = "\"<fact>\"".
argument_value_text(av_encoded_fact(External)) =
    ( if encode_fact_external(External, Bytes) then
        json_string("fact:" ++ hex(Bytes))
    else
        "\"<unencodable fact>\""
    ).

%---------------------------------------------------------------------------%
% What the host is handed when a pump returns
%---------------------------------------------------------------------------%

    % NOTHING FROM THE DUTIES. No write-through handler, as trace_libds.py
    % registers none; an expiry's line is its report's (`trace_report`),
    % where the report places it, and a rule's `cache_delete` is traced from
    % the stream.
    %
:- func trace_duty(duty, run) = run.

trace_duty(write_cache(_), Run) = Run.
trace_duty(remove_cache(_), Run) = Run.

    % THE CALL CALLBACK: its line, and the FactExternal bytes of each fact
    % the call sent, for `resend`, as trace_libds.py's `capture_sent`
    % records them. Nothing answers it, as pyds's callback answers nothing.
    %
:- func handed_over(service_call, run) = run.

handed_over(Call, Run0) = Run :-
    Sent = list.filter_map(sent_fact, Call ^ service_call_args),
    Run1 = Run0 ^ run_sent := Run0 ^ run_sent ++ Sent,
    Run = add_line(["cb_call"], Run1).

    % The calls a run of reports carries, in order.
    %
:- func reported_calls(list(report)) = list(service_call).

reported_calls(Reports) = list.filter_map(
    (func(Report) = Call is semidet :-
        Report = streamed(Event),
        Event ^ integrator_event_kind = action_call(Call)),
    Reports).

    % A fact sent as a call argument, as the bytes another tier receives.
    % Fail for any other argument, and for a fact that will not encode.
    %
:- func sent_fact(arg) = bitmap is semidet.

sent_fact(arg(_, av_encoded_fact(External))) = bytes_bitmap(Bytes) :-
    encode_fact_external(External, Bytes).

:- func trace_refracted(refracted_activation, run) = run.

trace_refracted(Entry, Run) =
    add_line(["refracted", Entry ^ ra_rule, Entry ^ ra_reason,
        "facts=" ++ string.int_to_string(list.length(Entry ^ ra_facts)),
        "|", Entry ^ ra_detail], Run).

:- func trace_alpha_step(trace_step, run) = run.

trace_alpha_step(Step, Run) =
    add_line(["trace", Step ^ ts_node, Step ^ ts_kind, Step ^ ts_result,
        "|", Step ^ ts_detail], Run).

%---------------------------------------------------------------------------%
% Python's spellings
%---------------------------------------------------------------------------%

    % A string as Python's `json.dumps(S, ensure_ascii=False)` writes it:
    % `"` and `\` escaped, the five control characters with short forms
    % as those, every other below U+0020 as `\u00xx`, the rest as it is.
    %
:- func json_string(string) = string.

json_string(S) =
    "\"" ++ string.append_list(list.map(json_char, string.to_char_list(S)))
        ++ "\"".

:- func json_char(char) = string.

json_char(C) = Text :-
    ( if C = '"' then
        Text = "\\\""
    else if C = ('\\') then
        Text = "\\\\"
    else if C = '\n' then
        Text = "\\n"
    else if C = '\r' then
        Text = "\\r"
    else if C = '\t' then
        Text = "\\t"
    else if C = '\b' then
        Text = "\\b"
    else if C = '\f' then
        Text = "\\f"
    else if char.to_int(C) < 0x20 then
        Text = string.format("\\u%04x", [i(char.to_int(C))])
    else
        Text = string.char_to_string(C)
    ).

    % A float as Python's `repr` writes it, which `json.dumps` writes for
    % a finite one: the fewest significant digits that read back as the
    % same float, positional for a decimal exponent from -4 to 15 with
    % `.0` when there is no fraction, else `d[.ddd]e±XX`. A float that is
    % not finite is spelled as DS spells it, `inf`, `-inf` or `nan`, as
    % trace_libds.py spells one.
    %
:- func python_float(float) = string.

python_float(F) = Text :-
    ( if float.is_nan(F) then
        Text = "nan"
    else if float.is_infinite(F) then
        Text = ( if F > 0.0 then "inf" else "-inf" )
    else if F = 0.0 then
        Text = ( if string.prefix(string.format("%e", [f(F)]), "-")
                 then "-0.0" else "0.0" )
    else
        Sign = ( if F < 0.0 then "-" else "" ),
        shortest_digits(1, float.abs(F), Digits, Exponent),
        Text = Sign ++ python_layout(Digits, Exponent)
    ).

    % The fewest significant digits, from `Precision` up, that read back as
    % `X`, and the decimal exponent of the first. Each count is correctly
    % rounded by C's `printf`, and 17 always reads back.
    %
:- pred shortest_digits(int::in, float::in, string::out, int::out) is det.

shortest_digits(Precision, X, Digits, Exponent) :-
    Text = string.format("%." ++ string.int_to_string(Precision - 1) ++ "e",
        [f(X)]),
    ( if
        Precision < 17,
        not (
            string.to_float(Text, Back),
            Back = X
        )
    then
        shortest_digits(Precision + 1, X, Digits, Exponent)
    else if
        [Mantissa, ExponentText] = string.split_at_char('e', Text),
        signed_int(ExponentText, Exponent0)
    then
        Digits = without_trailing_zeros(
            string.replace_all(Mantissa, ".", "")),
        Exponent = Exponent0
    else
        % `printf`'s `%e` always writes a mantissa, an `e` and an exponent.
        Digits = "0",
        Exponent = 0
    ).

:- func without_trailing_zeros(string) = string.

without_trailing_zeros(Digits) =
    ( if
        string.remove_suffix(Digits, "0", Rest),
        Rest \= ""
    then
        without_trailing_zeros(Rest)
    else
        Digits
    ).

:- func python_layout(string, int) = string.

python_layout(Digits, Exponent) = Text :-
    Count = string.length(Digits),
    Point = Exponent + 1,
    ( if ( Point =< -4 ; Point > 16 ) then
        ( if Count = 1 then
            Mantissa = Digits
        else
            string.split(Digits, 1, Lead, Tail),
            Mantissa = Lead ++ "." ++ Tail
        ),
        Magnitude = string.int_to_string(int.abs(Exponent)),
        Text = Mantissa ++ "e" ++ ( if Exponent < 0 then "-" else "+" )
            ++ ( if string.length(Magnitude) < 2 then "0" else "" )
            ++ Magnitude
    else if Point =< 0 then
        Text = "0." ++ string.duplicate_char('0', -Point) ++ Digits
    else if Point >= Count then
        Text = Digits ++ string.duplicate_char('0', Point - Count) ++ ".0"
    else
        string.split(Digits, Point, Whole, Fraction),
        Text = Whole ++ "." ++ Fraction
    ).

:- func hex(list(uint8)) = string.

hex(Bytes) =
    string.append_list(list.map(
        (func(B) = string.format("%02x", [i(uint8.cast_to_int(B))])),
        Bytes)).

:- func bytes_bitmap(list(uint8)) = bitmap.

bytes_bitmap(Bytes) =
    fill_bytes(Bytes, 0, bitmap.init(list.length(Bytes) * 8)).

:- func fill_bytes(list(uint8), int, bitmap) = bitmap.
:- mode fill_bytes(in, in, bitmap_di) = bitmap_uo is det.

fill_bytes([], _, BM) = BM.
fill_bytes([B | Bs], I, BM0) =
    fill_bytes(Bs, I + 1, BM0 ^ byte(I) := uint8.cast_to_int(B)).

%---------------------------------------------------------------------------%
% The scenario
%---------------------------------------------------------------------------%

    % One step of a scenario, as trace_libds.py's `parse_scenario` reads it.
    %
:- type scenario_step
    --->    sc_assert(string, assoc_list(string, scenario_value))
            % `assert <Schema> <slot>=<value>...`: a host assert.
    ;       sc_retract(int)
            % `retract N`: the fact the N-th handle names, from 0.
    ;       sc_advance(int)
            % `advance NS`: the mock clock forward.
    ;       sc_set(int)
            % `set NS`: the mock clock to an instant.
    ;       sc_wall(int)
            % `wall NS`: the mock wall clock, UTC ns.
    ;       sc_resend(int)
            % `resend K`: the K-th fact sent as a call argument, from 0,
            % asserted back as another tier's.
    ;       sc_pump
    ;       sc_refracted
            % The refracted matches. A read.
    ;       sc_trace(int)
            % The match trace of the fact the N-th handle names. A read.
    ;       sc_mem.
            % The engine's counts. A read.
            %
            % No `register` step: a schema reaches a session from its
            % artefact alone ([NFCT.1.1]).

    % A slot's value as a scenario writes it.
    %
:- type scenario_value
    --->    sv_int(int64)
    ;       sv_float(float)
    ;       sv_text(string)
    ;       sv_bool(bool)
    ;       sv_json(string)
            % `json:` and a Json document's text.
    ;       sv_null
    ;       sv_live(string).
            % `@Schema`: the earliest-asserted live fact of the schema.

:- type line_parse
    --->    blank
            % Blank, or a comment.
    ;       parsed_step(scenario_step)
    ;       unreadable(string).

:- func parse_lines(list(string)) = maybe_error(list(scenario_step), string).

parse_lines([]) = ok([]).
parse_lines([Line | Lines]) = Result :-
    Parsed = parse_line(string.words(Line)),
    (
        Parsed = blank,
        Result = parse_lines(Lines)
    ;
        Parsed = parsed_step(Step),
        Rest = parse_lines(Lines),
        (
            Rest = ok(Steps),
            Result = ok([Step | Steps])
        ;
            Rest = error(Why),
            Result = error(Why)
        )
    ;
        % AN UNRECOGNISED HEAD STOPS THE RUN. Dropped, the scenario would
        % run with a line missing, and the traces would still agree.
        Parsed = unreadable(Why),
        Result = error(Why)
    ).

    % One line's words. An integer argument is the first word after the
    % head, and the rest are ignored, as trace_libds.py reads them.
    %
:- func parse_line(list(string)) = line_parse.

parse_line([]) = blank.
parse_line([Head | Rest]) = Parsed :-
    ( if string.prefix(Head, "#") then
        Parsed = blank
    else if Head = "pump" then
        Parsed = parsed_step(sc_pump)
    else if Head = "advance" then
        Parsed = with_int(Head, Rest, (func(N) = sc_advance(N)))
    else if Head = "set" then
        Parsed = with_int(Head, Rest, (func(N) = sc_set(N)))
    else if Head = "wall" then
        Parsed = with_int(Head, Rest, (func(N) = sc_wall(N)))
    else if Head = "retract" then
        Parsed = with_int(Head, Rest, (func(N) = sc_retract(N)))
    else if Head = "resend" then
        Parsed = with_int(Head, Rest, (func(N) = sc_resend(N)))
    else if Head = "refracted", Rest = [] then
        Parsed = parsed_step(sc_refracted)
    else if Head = "trace" then
        Parsed = with_int(Head, Rest, (func(N) = sc_trace(N)))
    else if Head = "mem", Rest = [] then
        Parsed = parsed_step(sc_mem)
    else if Head = "assert", Rest = [Schema | Assigns] then
        Parsed = parsed_step(sc_assert(Schema,
            list.map(assignment, Assigns)))
    else if Head = "assert" then
        Parsed = unreadable("assert: no schema")
    else
        Parsed = unreadable("unknown scenario step '" ++ Head ++ "'")
    ).

:- func with_int(string, list(string), (func(int) = scenario_step))
    = line_parse.

with_int(Head, Rest, Make) = Parsed :-
    ( if
        Rest = [Text | _],
        python_int(Text, N)
    then
        Parsed = parsed_step(Make(N))
    else
        Parsed = unreadable(Head ++ ": no integer argument")
    ).

    % `<slot>=<value>`, split at the first `=`, as Python's `partition`
    % splits it: with none, the whole word names the slot and the value is
    % empty.
    %
:- func assignment(string) = pair(string, scenario_value).

assignment(Word) = Name - scenario_value(ValueText) :-
    Parts = string.split_at_char('=', Word),
    (
        Parts = [],
        Name = Word,
        ValueText = ""
    ;
        Parts = [Name],
        ValueText = ""
    ;
        Parts = [Name, Value | Values],
        ValueText = string.join_list("=", [Value | Values])
    ).

    % A value, tried as trace_libds.py's `parse_value` tries it, in its
    % order: Json, a quoted string, a boolean, null, a live reference, an
    % integer, a float, and otherwise the text as a string.
    %
:- func scenario_value(string) = scenario_value.

scenario_value(Text) = Value :-
    ( if string.remove_prefix("json:", Text, Json) then
        Value = sv_json(Json)
    else if
        string.prefix(Text, "\""),
        string.suffix(Text, "\"")
    then
        Value = sv_text(string.between(Text, 1, string.length(Text) - 1))
    else if Text = "true" then
        Value = sv_bool(yes)
    else if Text = "false" then
        Value = sv_bool(no)
    else if Text = "null" then
        Value = sv_null
    else if
        string.remove_prefix("@", Text, Schema),
        Schema \= ""
    then
        Value = sv_live(Schema)
    else if python_int(Text, I) then
        Value = sv_int(int64.from_int(I))
    else if python_float_value(Text, F) then
        Value = sv_float(F)
    else
        Value = sv_text(Text)
    ).

    % An integer as Python's `int` reads one: a sign, and decimal digits
    % that a single `_` may separate. Fail for anything else, and for one
    % outside `int`.
    %
:- pred python_int(string::in, int::out) is semidet.

python_int(Text, N) :-
    signed(Text, Sign, Unsigned),
    digit_groups(Unsigned, Digits),
    string.to_int(Sign ++ Digits, N).

    % A float as Python's `float` reads one: a sign, then `inf`,
    % `infinity` or `nan` in any case, or decimal digits with an optional
    % point and an optional exponent, a single `_` separating digits.
    %
:- pred python_float_value(string::in, float::out) is semidet.

python_float_value(Text, F) :-
    signed(Text, Sign, Unsigned),
    Lower = string.to_lower(Unsigned),
    ( if ( Lower = "inf" ; Lower = "infinity" ) then
        F = ( if Sign = "-" then 0.0 - float.infinity else float.infinity )
    else if Lower = "nan" then
        F = float.infinity - float.infinity
    else
        ( if
            string.sub_string_search(Lower, "e", At)
        then
            string.split(Lower, At, Mantissa, AfterMantissa),
            string.remove_prefix("e", AfterMantissa, ExponentText),
            signed(ExponentText, ExponentSign, ExponentDigits0),
            digit_groups(ExponentDigits0, ExponentDigits),
            Exponent = "e" ++ ExponentSign ++ ExponentDigits
        else
            Mantissa = Lower,
            Exponent = ""
        ),
        Pieces = string.split_at_char('.', Mantissa),
        (
            Pieces = [Whole0],
            digit_groups(Whole0, Whole),
            Fraction = "0"
        ;
            Pieces = [Whole0, Fraction0],
            ( Whole0 \= "" ; Fraction0 \= "" ),
            optional_digits(Whole0, Whole),
            optional_digits(Fraction0, Fraction)
        ),
        string.to_float(Sign ++ Whole ++ "." ++ Fraction ++ Exponent, F)
    ).

    % A sign, `-` kept for the reader and `+` dropped, and what follows it.
    %
:- pred signed(string::in, string::out, string::out) is det.

signed(Text, Sign, Unsigned) :-
    ( if string.remove_prefix("-", Text, Rest) then
        Sign = "-",
        Unsigned = Rest
    else if string.remove_prefix("+", Text, Rest) then
        Sign = "",
        Unsigned = Rest
    else
        Sign = "",
        Unsigned = Text
    ).

    % Decimal digits that a single `_` may separate, and the digits
    % without the separators. Fail for none.
    %
:- pred digit_groups(string::in, string::out) is semidet.

digit_groups(Text, Digits) :-
    Chars = string.to_char_list(Text),
    Chars = [First | _],
    char.is_digit(First),
    list.last(Chars, Last),
    char.is_digit(Last),
    list.all_true(
        (pred(C::in) is semidet :- ( char.is_digit(C) ; C = '_' )),
        Chars),
    not string.sub_string_search(Text, "__", _),
    Digits = string.from_char_list(list.filter(char.is_digit, Chars)).

    % Digit groups, or nothing, which reads as `0`.
    %
:- pred optional_digits(string::in, string::out) is semidet.

optional_digits(Text, Digits) :-
    ( if Text = "" then
        Digits = "0"
    else
        digit_groups(Text, Digits)
    ).

    % A signed exponent as `printf` writes one, `+05` or `-05`.
    %
:- pred signed_int(string::in, int::out) is semidet.

signed_int(Text, N) :-
    signed(Text, Sign, Digits),
    string.to_int(Sign ++ Digits, N).

%---------------------------------------------------------------------------%
% Files
%---------------------------------------------------------------------------%

:- pred read_text(string::in, maybe_error(string, string)::out,
    io::di, io::uo) is det.

read_text(Path, Result, !IO) :-
    io.open_input(Path, Opened, !IO),
    (
        Opened = ok(Stream),
        io.read_file_as_string(Stream, Read, !IO),
        io.close_input(Stream, !IO),
        (
            Read = ok(Text),
            Result = ok(Text)
        ;
            Read = error(_, Error),
            Result = error(Path ++ ": " ++ io.error_message(Error))
        )
    ;
        Opened = error(Error),
        Result = error(Path ++ ": " ++ io.error_message(Error))
    ).

:- pred read_artefact(string::in, maybe_error(bitmap, string)::out,
    io::di, io::uo) is det.

read_artefact(Path, Result, !IO) :-
    io.open_binary_input(Path, Opened, !IO),
    (
        Opened = ok(Stream),
        io.read_binary_file_as_bitmap(Stream, Read, !IO),
        io.close_binary_input(Stream, !IO),
        (
            Read = ok(Bytes),
            Result = ok(Bytes)
        ;
            Read = error(Error),
            Result = error(Path ++ ": " ++ io.error_message(Error))
        )
    ;
        Opened = error(Error),
        Result = error(Path ++ ": " ++ io.error_message(Error))
    ).

%---------------------------------------------------------------------------%
:- end_module trace_mercury_ds.
%---------------------------------------------------------------------------%

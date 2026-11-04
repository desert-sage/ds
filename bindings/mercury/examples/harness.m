%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: harness.m.
%
% The mercury_ds integration harness: the minimal program that exercises
% every feature of the binding, over harness.ds compiled to a .dsc. It has no
% application logic, and its values are placeholders. The point is the
% mechanics: which call does what, what each returns, and what the host does
% with it.
%
% main/2 is a pipeline of stages, in dependency order:
%
%   load_session        load the artefact; a refused load is a value
%   inspect_schemas     schema names, lookups, .proto text, services
%   setup_clock        the mock clock, and the wall clock now() reads
%   cache_and_limits    a cache seed, the cache bounds, the budgets
%   begin_recording     the session's fact stream, from here
%   assert_facts        one value of each kind a slot holds, a ttl fact
%   read_facts          the live facts, by id and all together
%   pump_and_answer     a pump's reports, duties and calls; every answer
%   from_another_tier   a published fact asserted into a second session
%   advance_and_expire  the mock clock moves; a TTL and a cache entry expire
%   introspection       rules, source, justifiers, the network, the header
%   determinism_reads   the session header, the platform, the build
%   record_and_replay   the recording, its atoms, a replay into a new session
%   live_clock          a session on wall time
%   finish              a retract; nothing to free
%
% A session is a value: each stage takes the session and returns the next.
% Nothing the host does runs inside a call to the session, so every call
% that changes one returns what it reported, and the host acts on that.
%
% Its main action is to print what it does: each call and its outcome, each
% report, each duty and each answer. The mercury gate builds and runs
% it, and fails unless it ends "harness: OK" and calls everything mercury_ds
% exports for a host.
%
% Usage: harness HARNESS.dsc
%
%---------------------------------------------------------------------------%

:- module harness.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%---------------------------------------------------------------------------%
:- implementation.
%---------------------------------------------------------------------------%

:- import_module mercury_ds.
:- import_module mercury_ds.atoms.
:- import_module mercury_ds.error.
:- import_module mercury_ds.events.
:- import_module mercury_ds.host.
:- import_module mercury_ds.introspect.
:- import_module mercury_ds.session.
:- import_module mercury_ds.status.
:- import_module mercury_ds.value.
:- import_module ds.
:- import_module ds.capability.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fact_external.
:- import_module ds.id.
:- import_module ds.json.
:- import_module ds.platform.
:- import_module ds.rfcs.
:- import_module ds.schema.
:- import_module ds.service.
:- import_module bitmap.
:- import_module bool.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module string.
:- import_module uint64.

    % Qualified: `error/1` is also `outcome`'s and `maybe_error`'s failure,
    % and only a few names from each of the others are wanted here.
    %
:- use_module map.
:- use_module require.
:- use_module set.
:- use_module uint32.
:- use_module uint8.

%---------------------------------------------------------------------------%

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    ( if Args = [Path] then
        read_artefact(Path, Read, !IO),
        (
            Read = ok(Bytes),
            run(Bytes, !IO)
        ;
            Read = error(Message),
            io.format("harness: cannot read %s: %s\n",
                [s(Path), s(Message)], !IO),
            io.set_exit_status(2, !IO)
        )
    else
        io.write_string("usage: harness HARNESS.dsc\n", !IO),
        io.set_exit_status(2, !IO)
    ).

    % The stages, in order. Each is a complete step: a harness that stops
    % after any of them runs.
    %
:- pred run(bitmap::in, io::di, io::uo) is det.

run(Bytes, !IO) :-
    load_session(Bytes, Session, !IO),
    some [!S] (
        !:S = Session,
        inspect_schemas(!.S, !IO),
        setup_clock(!S, !IO),
        cache_and_limits(!S, !IO),
        begin_recording(!S, !IO),
        assert_facts(Go, !S, !IO),
        read_facts(!.S, Go, !IO),
        pump_and_answer(Published, !S, !IO),
        from_another_tier(Bytes, Published, !IO),
        advance_and_expire(!S, !IO),
        introspection(!.S, Go, !IO),
        determinism_reads(!.S, !IO),
        record_and_replay(Bytes, !S, !IO),
        live_clock(Bytes, !IO),
        finish(!.S, Go, !IO)
    ),
    io.write_string("\nharness: OK\n", !IO).

%---------------------------------------------------------------------------%
% The configuration
%---------------------------------------------------------------------------%

    % Every field of a session's configuration: the mock clock, no firing
    % limit, a run and a tier id, and an admission policy that admits only
    % artefacts that call a service. A time zone is not configuration: it is
    % facts (`assert_facts`).
    %
:- func config = session_config.

config = session_config(mock_clock, no_fire_limit,
    yes("run-1"), yes("edge"), map.singleton(cap_call, admit_true_only)).

    % A wall clock reading: 2023-11-14T22:13:20Z.
    %
:- func wall_epoch = int64.

wall_epoch = 1_700_000_000_000_000_000i64.

%---------------------------------------------------------------------------%
% Stages
%---------------------------------------------------------------------------%

:- pred load_session(bitmap::in, session::out, io::di, io::uo) is det.

load_session(Bytes, Session, !IO) :-
    section("load the artefact", !IO),
    load(bitmap.init(0), config, Empty, _),
    (
        Empty = ok(_),
        require.error("harness: an empty artefact loaded")
    ;
        Empty = error(EmptyError),
        refusal("load of no bytes", EmptyError, !IO)
    ),
    % The reports are the load's log lines ([RDSC.9.4]); this artefact
    % carries no atom the load skips, so there are none to show.
    load(Bytes, config, Loaded, _),
    (
        Loaded = ok(Session),
        line("ok   load", !IO)
    ;
        Loaded = error(Error),
        fatal("load", Error)
    ).

:- pred inspect_schemas(session::in, io::di, io::uo) is det.

inspect_schemas(S, !IO) :-
    section("schemas and services", !IO),
    line("schema_names: " ++ string.join_list(", ", got(schema_names(S))),
        !IO),
    ( if search_schema(S, "Probe", ok(_)) then
        line("search_schema Probe: found", !IO)
    else
        require.error("harness: the artefact's Probe is not found")
    ),
    ( if search_schema(S, "Absent", _) then
        require.error("harness: a schema no artefact declares was found")
    else
        line("search_schema Absent: not found", !IO)
    ),
    Note = got(lookup_schema(S, "Note")),
    ( if proto_text(Note) = yes(Proto) then
        line(string.format("proto_text Note: %d characters",
            [i(string.length(Proto))]), !IO)
    else
        require.error("harness: proto_text answered wrongly")
    ),
    ( if
        search_schema_source(S, "Note", ok(NoteLoc)),
        lookup_schema_source(S, "Note") = ok(NoteLoc),
        not search_schema_source(S, "ComputationError", _)
    then
        line(string.format("search_schema_source Note: line %d; "
            ++ "ComputationError, built in: none",
            [i(NoteLoc ^ source_loc_line)]), !IO)
    else
        require.error("harness: search_schema_source answered wrongly")
    ),
    % The order `assert_fact` takes a schema's values in.
    line("slot_names Note: " ++
        string.join_list(", ", got(slot_names(S, Note))), !IO),
    list.foldl(print_service, got(services(S)), !IO).

:- pred print_service(service_info::in, io::di, io::uo) is det.

print_service(Info, !IO) :-
    Response = ( if Info ^ service_info_response = yes(R) then R
                 else "no response" ),
    Names = string.join_list(", ",
        list.map((func(K) = K ^ sk_name), Info ^ service_info_kwargs)),
    line(string.format("service %s -> %s; kwargs: %s",
        [s(Info ^ service_info_name), s(Response), s(Names)]), !IO).

:- pred setup_clock(session::in, session::out, io::di, io::uo) is det.

setup_clock(!S, !IO) :-
    section("the clock", !IO),
    line("clock_mode: " ++ string.string(got(clock_mode(!.S))), !IO),
    set_clock(from_ns(0u64), Set, !S),
    must_step("set_clock 0", Set, !IO),
    % `now()` and a CallError's `ts` read the wall clock, which a mock
    % clock leaves with no value until the host sets one.
    set_wall_clock(wall_epoch, Wall, !S),
    must("set_wall_clock", Wall, !IO),
    line("now: " ++ instant_text(got(now(!.S))), !IO).

:- pred cache_and_limits(session::in, session::out, io::di, io::uo) is det.

cache_and_limits(!S, !IO) :-
    section("the cache and the limits", !IO),
    % A seed restores what a store kept, before the first pump: here a
    % document the store kept as JSON text, which is the term a host would
    % build.
    Kept = json_from_text("{\"on\": true}"),
    (
        Kept = ok(Seed),
        ( if json_to_text(Seed) = ok(Text) then
            line("ok   json_from_text; json_to_text: " ++ Text, !IO)
        else
            require.error("harness: json_to_text refused a document")
        ),
        cache_seed("restored", Seed, no, Seeded, !S),
        must("cache_seed restored", Seeded, !IO)
    ;
        Kept = error(KeptError),
        fatal("json_from_text", KeptError)
    ),
    ( if json_from_text("{\"on\": true} {}") = error(TwoError) then
        refusal("json_from_text of two documents", TwoError, !IO)
    else
        require.error("harness: json_from_text read two documents as one")
    ),
    set_cache_cap(64, 65_536, Capped, !S),
    must("set_cache_cap 64 keys, 65536 bytes", Capped, !IO),
    set_fire_budget(fire_budget(1_000), Fires, !S),
    must("set_fire_budget 1000", Fires, !IO),
    set_cache_cap(-1, 0, Negative, !.S, _),
    expect_refused("set_cache_cap -1", Negative, !IO).

:- pred begin_recording(session::in, session::out, io::di, io::uo) is det.

begin_recording(!S, !IO) :-
    section("begin recording", !IO),
    start_recording(!S),
    ( if
        recording(!.S) = yes(Recording),
        bitmap.num_bits(Recording ^ recording_bytes) = 0
    then
        line("ok   start_recording: no bytes until the next event", !IO)
    else
        require.error("harness: a new recording has bytes")
    ).

    % Assert the offset `local()` reads for Europe/London, a built-in
    % `TimeZoneOffset` row ([LTIM.10.6]): zone, valid_from, valid_until and
    % offset_s, here 0 over every instant a row can state. Then a Go, which
    % fires every rule, a Probe holding one value of each kind a slot holds,
    % a Note with its schema's TTL, and a Reading for the series.
    %
:- pred assert_facts(fact_id::out, session::in, session::out,
    io::di, io::uo) is det.

assert_facts(Go, !S, !IO) :-
    section("assert facts", !IO),
    assert_fact("TimeZoneOffset", [text("Europe/London"),
        int(int64.min_int64), int(int64.max_int64), int(0i64)], TzStep,
        !S),
    must_assert("assert TimeZoneOffset for Europe/London", TzStep, _, !IO),
    assert_fact("Go", [int(1i64), int(0i64)], GoStep, !S),
    must_assert("assert Go", GoStep, Go, !IO),
    Probe = [int(1i64), float(2.5), text("probe"), bool(yes),
        json(j_object(object(["k" - j_string("v")]))),
        bytes(bitmap.init(16, no)), int(0i64), int(0i64),
        int(1_000_000_000i64), fact_ref(Go), null],
    assert_fact("Probe", Probe, ProbeStep, !S),
    must_assert("assert Probe (every kind)", ProbeStep, _, !IO),
    assert_fact("Note", [text("porch"), int(0i64)], NoteStep, !S),
    must_assert("assert Note, its schema's TTL 1 h", NoteStep, _, !IO),
    assert_fact("Reading", [text("attic"), float(21.5)], ReadStep, !S),
    must_assert("assert Reading", ReadStep, _, !IO),
    assert_fact("Nope", [], Unknown, !.S, _),
    UnknownOutcome = Unknown ^ assert_step_outcome,
    (
        UnknownOutcome = error(UnknownError),
        refusal("assert of an unknown schema", UnknownError, !IO)
    ;
        ( UnknownOutcome = asserted(_)
        ; UnknownOutcome = unchanged(_)
        ; UnknownOutcome = replaced(_, _)
        ),
        require.error("harness: an unknown schema was asserted")
    ).

:- pred read_facts(session::in, fact_id::in, io::di, io::uo) is det.

read_facts(S, Go, !IO) :-
    section("read facts", !IO),
    line(string.format("fact_count: %d", [i(got(fact_count(S)))]), !IO),
    list.foldl(print_view, got(facts(S)), !IO),
    ( if search_fact(S, Go, ok(View)), lookup_fact(S, Go) = ok(View) then
        line("search_fact and lookup_fact agree on Go", !IO),
        list.foldl(print_value, View ^ fact_view_slots, !IO)
    else
        require.error("harness: Go is not live")
    ).

:- pred print_view(fact_view::in, io::di, io::uo) is det.

print_view(View, !IO) :-
    line(string.format("%s %s: %d slots, asserted %s, %s",
        [s(View ^ fact_view_schema), s(string.string(View ^ fact_view_id)),
        i(list.length(View ^ fact_view_slots)),
        s(instant_text(View ^ fact_view_asserted)),
        s(deadline_text(View ^ fact_view_deadline))]), !IO).

    % A value as the host reads it, and as the runtime holds it.
    %
:- pred print_value(storable::in, io::di, io::uo) is det.

print_value(Value, !IO) :-
    line(string.format("  %s, the runtime's %s",
        [s(string.string(Value)), s(string.string(to_value(Value)))]), !IO).

    % Pump: every rule fires. Answer the call it issued four ways: on two
    % copies of the session, with a failure and as a service not offered;
    % on the session, with the response; then let `pump_serving` answer
    % the call that response causes.
    %
:- pred pump_and_answer(maybe(fact_external)::out,
    session::in, session::out, io::di, io::uo) is det.

pump_and_answer(Published, !S, !IO) :-
    section("pump, perform the duties, answer the calls", !IO),
    pump(First, !S),
    must_pumped("pump", First, !IO),
    ( if list.find_first_map(published, First ^ pumped_reports, External) then
        Published = yes(External)
    else
        Published = no
    ),
    ( if First ^ pumped_calls = [Call | _] then
        answer(Call, call_error("weather.down", "the forecast is down"),
            Failed, !.S, FailedCopy),
        must_step("answer call_error, on a copy", Failed, !IO),
        print_call_errors(FailedCopy, !IO),
        answer(Call, not_offered, Unoffered, !.S, UnofferedCopy),
        must_step("answer not_offered, on a copy", Unoffered, !IO),
        print_call_errors(UnofferedCopy, !IO),
        answer(Call, answered([text("hall"), int(18i64)]), Answered, !S),
        must_step("answer with the response", Answered, !IO)
    else
        require.error("harness: the pump issued no call")
    ),
    pump_serving(serve, Served, !S, 0, Count, !IO),
    must_pumped("pump_serving", Served, !IO),
    line(string.format("pump_serving served %d calls", [i(Count)]), !IO).

    % A service, as the host offers it: dispatch on the name.
    %
:- pred serve(service_call::in, service_answer::out, int::in, int::out,
    io::di, io::uo) is det.

serve(Call, Answer, !Served, !IO) :-
    !:Served = !.Served + 1,
    Service = Call ^ service_call_service,
    ( if Service = "weather.forecast" then
        Answer = answered([text("hall"), int(18i64)])
    else if Service = "light.turn_on" then
        Answer = no_response
    else
        Answer = not_offered
    ),
    line(string.format("[serve] %s %s -> %s",
        [s(Service), s(string.string(Call ^ service_call_correlation)),
        s(string.string(Answer))]), !IO).

:- pred print_call_errors(session::in, io::di, io::uo) is det.

print_call_errors(S, !IO) :-
    Errors = list.filter((pred(V::in) is semidet :-
        V ^ fact_view_schema = "CallError"), got(facts(S))),
    list.foldl(print_view, Errors, !IO).

    % The fact a publish carries to another tier. Fail for any other report.
    %
:- pred published(report::in, fact_external::out) is semidet.

published(streamed(Event), External) :-
    Event ^ integrator_event_kind = action_publish(_, _, yes(External)).

    % A fact one tier published, asserted into another.
    %
:- pred from_another_tier(bitmap::in, maybe(fact_external)::in,
    io::di, io::uo) is det.

from_another_tier(Bytes, Published, !IO) :-
    section("a fact from another tier", !IO),
    load(Bytes, config, Loaded, _),
    ( if
        Loaded = ok(Other),
        Published = yes(External),
        encode_fact_external(External, Octets)
    then
        assert_external(octets_bitmap(Octets), Step, Other, Received),
        must_step("assert_external", Step, !IO),
        list.foldl(print_view, got(facts(Received)), !IO)
    else
        require.error("harness: no published fact to receive")
    ).

:- pred advance_and_expire(session::in, session::out, io::di, io::uo) is det.

advance_and_expire(!S, !IO) :-
    section("advance the clock; a TTL and a cache entry expire", !IO),
    % Past the Note's 1 h, its schema's TTL.
    advance(duration_from_ns(3_610_000_000_000u64), Advanced, !S),
    must_step("advance 1 h 10 s", Advanced, !IO),
    pump(Swept, !S),
    must_pumped("pump (the expiry sweep)", Swept, !IO).

:- pred introspection(session::in, fact_id::in, io::di, io::uo) is det.

introspection(S, Go, !IO) :-
    section("introspection", !IO),
    Memory = got(memory_usage(S)),
    line(string.format("memory_usage: %d facts in working memory",
        [i(Memory ^ em_wm_fact_count)]), !IO),
    list.foldl(print_rule, got(rules(S)), !IO),
    ( if
        search_rule(S, "every_verb", ok(Rule)),
        lookup_rule(S, "every_verb") = ok(Rule)
    then
        line("search_rule and lookup_rule agree on every_verb", !IO)
    else
        require.error("harness: every_verb is not found")
    ),
    Sources = got(sources(S)),
    Spans = got(line_spans(S)),
    line(string.format("sources: %d modules; line_spans: %d nodes",
        [i(list.length(Sources)), i(list.length(Spans))]), !IO),
    ( if
        Spans = [Span | _],
        search_line_span(S, Span ^ ls_node, ok(Found)),
        lookup_line_span(S, Span ^ ls_node) = ok(Found),
        search_source_file(S, Span ^ ls_clip, ok(File)),
        lookup_source_file(S, Span ^ ls_clip) = ok(File)
    then
        line(string.format("node %d is at %s:%d",
            [i(uint32.cast_to_int(Span ^ ls_node)), s(File),
            i(uint32.cast_to_int(Span ^ ls_line))]), !IO)
    else
        require.error("harness: no span maps a node to its source")
    ),
    line(string.format("justifiers of Go: %d; match_trace: %d steps; "
        ++ "refracted: %d", [i(list.length(got(justifiers(S, Go)))),
        i(list.length(got(match_trace(S, Go)))),
        i(list.length(got(refracted_activations(S, no))))]), !IO),
    % No series read: no public function reads a series ([NSBK.6.3]). The
    % `reads` rule reads Reading.level, and logs.
    Header = got(artefact_header(S)),
    line("artefact_header: compiled by " ++ Header ^ dh_compiler_version,
        !IO),
    line("halted: " ++ string.string(halted(S)), !IO),
    % The runtime's own values, for a tool that needs more than this
    % surface: its engine and its loaded program.
    _Program = session_program(S),
    line(string.format("session_engine: %d facts",
        [i(engine_fact_count(session_engine(S)))]), !IO).

:- pred print_rule(rule_info::in, io::di, io::uo) is det.

print_rule(Rule, !IO) :-
    Where = ( if Rule ^ rule_info_source = yes(source_loc(_, Line, _))
              then string.format("line %d", [i(Line)]) else "unknown" ),
    line(string.format("rule %s at %s", [s(Rule ^ rule_info_name), s(Where)]),
        !IO).

:- pred determinism_reads(session::in, io::di, io::uo) is det.

determinism_reads(S, !IO) :-
    section("determinism reads", !IO),
    stream_meta(Version, Hash, Capabilities, DefSha, Run, Tier) =
        session_header(S),
    line(string.format("session_header: DS %s, dsc_sha256 of %d bytes, "
        ++ "%d capabilities, dialect_def_sha256 of %d bytes, run %s, tier %s",
        [s(Version), i(list.length(Hash)), i(list.length(Capabilities)),
        i(list.length(DefSha)), s(Run), s(Tier)]), !IO),
    line(string.format("run_id %s, tier_id %s",
        [s(string.string(got(run_id(S)))),
        s(string.string(got(tier_id(S))))]), !IO),
    Platform = platform_signature,
    line(string.format("platform: %s/%s, %s, %s",
        [s(Platform ^ ps_os_family), s(Platform ^ ps_cpu_arch),
        s(Platform ^ ps_libc), s(Platform ^ ps_compiler)]), !IO),
    line(string.format("build_capabilities: %d",
        [i(set.count(build_capabilities))]), !IO).

    % The recording since `begin_recording`, its atoms, and a replay into a
    % new session, loaded with the same configuration as the recording's
    % session was.
    %
:- pred record_and_replay(bitmap::in, session::in, session::out,
    io::di, io::uo) is det.

record_and_replay(Bytes, !S, !IO) :-
    section("record and replay", !IO),
    ( if recording(!.S) = yes(Recording) then
        Stream = Recording ^ recording_bytes,
        line(string.format("recording: %d bytes, %d events unencodable",
            [i(bitmap.num_bits(Stream) / 8),
            i(list.length(Recording ^ recording_unencodable))]), !IO),
        Listing = atoms(Stream),
        must("atoms", Listing ^ atom_listing_outcome, !IO),
        line(string.format("%d atoms", [i(list.length(
            Listing ^ atom_listing_atoms))]), !IO),
        stop_recording(!S),
        load(Bytes, config, Loaded, _),
        (
            Loaded = ok(Fresh0),
            replay(Stream, Replayed, Fresh0, Fresh),
            must_step("replay", Replayed, !IO),
            % The replay ends with the recorded session's facts: a replay
            % that re-derives every compare-class atom holds what the run
            % held.
            FreshCount = got(fact_count(Fresh)),
            RecordedCount = got(fact_count(!.S)),
            ( if FreshCount = RecordedCount then
                line(string.format("replayed: %d facts, as recorded: %d",
                    [i(FreshCount), i(RecordedCount)]), !IO)
            else
                require.error(string.format("harness: the replay holds "
                    ++ "%d facts, the recorded session %d",
                    [i(FreshCount), i(RecordedCount)]))
            )
        ;
            Loaded = error(Error),
            fatal("load for the replay", Error)
        )
    else
        require.error("harness: the session is not recording")
    ).

:- pred live_clock(bitmap::in, io::di, io::uo) is det.

live_clock(Bytes, !IO) :-
    section("a session on wall time", !IO),
    % The default configuration, but for the clock.
    load(Bytes, default_config ^ session_config_clock := live_clock, Loaded,
        _),
    (
        Loaded = ok(Live0),
        line("clock_mode: " ++ string.string(got(clock_mode(Live0))), !IO),
        read_clock(Live0, Live, !IO),
        line("read_clock; now: " ++ instant_text(got(now(Live))), !IO),
        advance(duration_from_ns(1u64), Advanced, Live, _),
        expect_refused("advance on a live clock", Advanced ^ step_outcome,
            !IO)
    ;
        Loaded = error(Error),
        fatal("load live", Error)
    ).

:- pred finish(session::in, fact_id::in, io::di, io::uo) is det.

finish(S0, Go, !IO) :-
    section("retract; nothing to free", !IO),
    retract_fact(Go, Retracted, S0, S1),
    must_step("retract Go", Retracted, !IO),
    retract_fact(Go, Again, S1, _),
    expect_refused("retract Go again", Again ^ step_outcome, !IO),
    line("a session is a value: nothing to free", !IO).

%---------------------------------------------------------------------------%
% Printing what a call returned
%---------------------------------------------------------------------------%

:- pred section(string::in, io::di, io::uo) is det.

section(Title, !IO) :-
    io.format("\n== %s ==\n", [s(Title)], !IO).

:- pred line(string::in, io::di, io::uo) is det.

line(Text, !IO) :-
    io.format("  %s\n", [s(Text)], !IO).

    % A call that should succeed: print it, or throw if it failed.
    %
:- pred must(string::in, outcome::in, io::di, io::uo) is det.

must(What, ok, !IO) :-
    line("ok   " ++ What, !IO).
must(What, error(Error), !IO) :-
    fatal(What, Error).

:- pred must_step(string::in, step::in, io::di, io::uo) is det.

must_step(What, Step, !IO) :-
    must(What, Step ^ step_outcome, !IO),
    list.foldl(print_report, Step ^ step_reports, !IO),
    list.foldl(perform, Step ^ step_duties, !IO).

:- pred must_assert(string::in, assert_step::in, fact_id::out,
    io::di, io::uo) is det.

must_assert(What, Step, Id, !IO) :-
    Outcome = Step ^ assert_step_outcome,
    (
        Outcome = asserted(Id),
        line("ok   " ++ What, !IO)
    ;
        Outcome = unchanged(Id),
        line("ok   " ++ What ++ " (unchanged)", !IO)
    ;
        Outcome = replaced(_, Id),
        line("ok   " ++ What ++ " (replaced)", !IO)
    ;
        Outcome = error(Error),
        fatal(What, Error)
    ),
    list.foldl(print_report, Step ^ assert_step_reports, !IO),
    list.foldl(perform, Step ^ assert_step_duties, !IO).

    % A pump: its outcome and reports, each duty performed, and each call it
    % issued.
    %
:- pred must_pumped(string::in, pumped::in, io::di, io::uo) is det.

must_pumped(What, Pumped, !IO) :-
    must(What, Pumped ^ pumped_outcome, !IO),
    list.foldl(print_report, Pumped ^ pumped_reports, !IO),
    list.foldl(perform, Pumped ^ pumped_duties, !IO),
    list.foldl(print_call, Pumped ^ pumped_calls, !IO).

    % A call that should be refused: print the refusal, or throw if it was
    % not refused.
    %
:- pred expect_refused(string::in, outcome::in, io::di, io::uo) is det.

expect_refused(What, ok, !IO) :-
    require.error("harness: " ++ What ++ " was not refused").
expect_refused(What, error(Error), !IO) :-
    refusal(What, Error, !IO).

    % A refusal, by the status libds gives the same case: its name, and its
    % number, which maps back to it.
    %
:- pred refusal(string::in, ds_error::in, io::di, io::uo) is det.

refusal(What, Error, !IO) :-
    error_status(Error, Status),
    Number = status_number(Status),
    ( if number_status(Number, Back), Back = Status then
        line(string.format("refused %s: %s (%d)",
            [s(What), s(status_name(Status)), i(Number)]), !IO)
    else
        require.error("harness: a status number does not map back")
    ).

:- pred fatal(string::in, ds_error::in) is erroneous.

fatal(What, Error) :-
    require.error("harness: " ++ What ++ ": " ++ string.string(Error)).

%---------------------------------------------------------------------------%
% Reports, duties and calls
%---------------------------------------------------------------------------%

:- pred print_report(report::in, io::di, io::uo) is det.

print_report(streamed(Event), !IO) :-
    line(string.format("[stream] seq=%s clock=%s %s",
        [s(uint64_to_string(seq_value(Event ^ integrator_event_seq))),
        s(instant_text(Event ^ integrator_event_clock)),
        s(kind_text(Event ^ integrator_event_kind))]), !IO).
print_report(logged(Log), !IO) :-
    line(string.format("[log] %s %s: %s",
        [s(string.string(Log ^ log_line_level)),
        s(Log ^ log_line_category), s(Log ^ log_line_message)]), !IO).
print_report(measured(Metric), !IO) :-
    line(string.format("[metric] %s %g",
        [s(Metric ^ m_name), f(Metric ^ m_value)]), !IO).
print_report(cache_expired(Key), !IO) :-
    % Where the expiry happened; the store's removal is the duty the same
    % call hands over, a pump's or another step's.
    line("[cache] expired " ++ Key, !IO).

    % Every kind of stream event: a new kind is a compile error here until
    % the host says what it does with it.
    %
:- func kind_text(event_kind) = string.

kind_text(fact_assert(Id, Schema, Values)) =
    string.format("fact_assert %s %s, %d slots",
        [s(Schema), s(string.string(Id)), i(list.length(Values))]).
kind_text(fact_retract(Id)) = "fact_retract " ++ string.string(Id).
kind_text(rule_lhs_facts(Activation, Ids)) =
    string.format("rule_lhs_facts %s, %d facts",
        [s(Activation ^ activation_rule), i(list.length(Ids))]).
kind_text(rule_fire_begin(Activation)) =
    "rule_fire_begin " ++ Activation ^ activation_rule.
kind_text(rule_fire_end(Activation)) =
    "rule_fire_end " ++ Activation ^ activation_rule.
kind_text(action_call(Call)) = "action_call " ++ Call ^ service_call_service.
kind_text(action_emit(_, Schema)) = "action_emit " ++ Schema.
kind_text(action_publish(Schema, _, _)) = "action_publish " ++ Schema.
kind_text(action_cache_set(Write)) =
    "action_cache_set " ++ Write ^ cache_write_key.
kind_text(action_cache_delete(Key)) = "action_cache_delete " ++ Key.
kind_text(action_log(Log)) = "action_log " ++ Log ^ log_line_message.
kind_text(tick(Wall)) = "tick, wall " ++ string.string(Wall).
kind_text(timer_armed(Activation, _, _)) =
    "timer_armed " ++ Activation ^ activation_rule.
kind_text(type_error(Info)) = "type_error in " ++ Info ^ fault_info_rule.
kind_text(computation_error(Trap, Info)) =
    string.format("computation_error %s in %s",
        [s(string.string(Trap)), s(Info ^ fault_info_rule)]).
kind_text(bounds_error(Cap, Info)) =
    string.format("bounds_error %s in %s",
        [s(string.string(Cap)), s(Info ^ fault_info_rule)]).
kind_text(engine_error(Fault, Info)) =
    string.format("engine_error %s in %s",
        [s(string.string(Fault)), s(Info ^ fault_info_rule)]).
kind_text(pump) = "pump".

    % What the host does with a duty: here, say it.
    %
:- pred perform(duty::in, io::di, io::uo) is det.

perform(write_cache(Write), !IO) :-
    line(string.format("[duty] write_cache %s = %s, %s",
        [s(Write ^ cache_write_key), s(Write ^ cache_write_value_json),
        s(ttl_text(Write ^ cache_write_ttl))]), !IO).
perform(remove_cache(Removal), !IO) :-
    line(string.format("[duty] remove_cache %s, %s",
        [s(Removal ^ cache_removal_key),
        s(string.string(Removal ^ cache_removal_reason))]),
        !IO).

:- pred print_call(service_call::in, io::di, io::uo) is det.

print_call(Call, !IO) :-
    line(string.format("[call] %s %s, %d arguments, from %s",
        [s(Call ^ service_call_service),
        s(string.string(Call ^ service_call_correlation)),
        i(list.length(Call ^ service_call_args)),
        s(Call ^ service_call_activation ^ activation_rule)]), !IO).

%---------------------------------------------------------------------------%
% Small conversions
%---------------------------------------------------------------------------%

    % A read's value. Every read answers `halted` once the session's engine
    % has halted ([NCBK.2.9]); nothing this harness runs halts one, so a
    % read that does is the harness's own bug.
    %
:- func got(read(T)) = T.

got(ok(Value)) = Value.
got(halted(_)) = _ :-
    require.error("harness: a read was refused: the session has halted").

:- func instant_text(instant) = string.

instant_text(At) = uint64_to_string(instant_ns(At)) ++ " ns".

:- func ttl_text(maybe(duration)) = string.

ttl_text(no) = "no expiry".
ttl_text(yes(Ttl)) = "ttl " ++ uint64_to_string(duration_ns(Ttl)) ++ " ns".

:- func deadline_text(maybe(instant)) = string.

deadline_text(no) = "no deadline".
deadline_text(yes(At)) = "expires " ++ instant_text(At).

:- func octets_bitmap(list(uint8)) = bitmap.

octets_bitmap(Octets) =
        fill(Codes, 0, bitmap.init(list.length(Codes) * 8)) :-
    Codes = list.map(uint8.cast_to_int, Octets).

:- func fill(list(int), int, bitmap) = bitmap.
:- mode fill(in, in, bitmap_di) = bitmap_uo is det.

fill([], _, Bitmap) = Bitmap.
fill([Code | Codes], I, Bitmap0) =
    fill(Codes, I + 1, Bitmap0 ^ byte(I) := Code).

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
            Result = error(io.error_message(Error))
        )
    ;
        Opened = error(Error),
        Result = error(io.error_message(Error))
    ).

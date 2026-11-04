%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
% SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
%---------------------------------------------------------------------------%
%
% File: test_mercury_ds.m.
%
% mercury_ds's tests, over the artefacts in $MERCURY_DS_FIXTURES: the
% binding's own fixtures (`test/fixtures/`), compiled by the Mercury `dsc`.
% Each check is named for the behaviour it holds. The program prints one
% line per check and exits 1 if any failed.
%
%---------------------------------------------------------------------------%

:- module test_mercury_ds.
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
:- import_module ds.action.
:- import_module ds.atom.
:- import_module ds.capability.
:- import_module ds.chrono.
:- import_module ds.dsc.
:- import_module ds.engine.
:- import_module ds.events.
:- import_module ds.fact_external.
:- import_module ds.id.
:- import_module ds.intern.
:- import_module ds.json.
:- import_module ds.rfcs.
:- import_module ds.schema.
:- import_module ds.service.
:- import_module ds.value.
:- import_module bitmap.
:- import_module bool.
:- import_module int.
:- import_module int64.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module string.
:- import_module uint32.
:- import_module uint64.

:- use_module ds.fault.
:- use_module ds.sha256.
:- use_module float.
:- use_module map.
:- use_module uint8.

%---------------------------------------------------------------------------%

:- type tally
    --->    tally(
                tl_passed  :: int,
                tl_failed  :: int,
                tl_skipped :: int
                            % How many checks passed, failed and were
                            % skipped.
            ).

main(!IO) :-
    io.get_environment_var("MERCURY_DS_FIXTURES", MaybeDir, !IO),
    (
        MaybeDir = yes(Dir),
        read_fixtures(Dir, ["verbs", "services", "series", "local_tz",
            "div_zero", "cache_order", "cache_read_expiry", "fact_ref",
            "verbs_short_call"], Fixtures, !IO),
        (
            Fixtures = yes(F),
            run_all(F, !IO)
        ;
            Fixtures = no,
            io.set_exit_status(2, !IO)
        )
    ;
        MaybeDir = no,
        io.write_string("test_mercury_ds: MERCURY_DS_FIXTURES is not set\n",
            !IO),
        io.set_exit_status(2, !IO)
    ).

    % The compiled fixtures, by name.
    %
:- type fixtures == list(pair(string, bitmap)).

:- pred read_fixtures(string::in, list(string)::in, maybe(fixtures)::out,
    io::di, io::uo) is det.

read_fixtures(_, [], yes([]), !IO).
read_fixtures(Dir, [Name | Names], Result, !IO) :-
    Path = Dir ++ "/" ++ Name ++ ".dsc",
    read_bytes(Path, MaybeBytes, !IO),
    (
        MaybeBytes = yes(Bytes),
        read_fixtures(Dir, Names, Rest, !IO),
        Result = map_maybe((func(Fs) = [Name - Bytes | Fs]), Rest)
    ;
        MaybeBytes = no,
        io.format("test_mercury_ds: cannot read %s\n", [s(Path)], !IO),
        Result = no
    ).

:- func fixture(fixtures, string) = bitmap.

fixture(Fixtures, Name) = Bytes :-
    ( if list.find_first_match(named_fixture(Name), Fixtures, _ - B) then
        Bytes = B
    else
        unexpected($pred, "no fixture " ++ Name)
    ).

:- pred named_fixture(string::in, pair(string, bitmap)::in) is semidet.

named_fixture(Name, Name - _).

:- pred run_all(fixtures::in, io::di, io::uo) is det.

run_all(F, !IO) :-
    some [!T] (
        !:T = tally(0, 0, 0),
        test_loading(fixture(F, "verbs"), !T, !IO),
        test_load_reports(fixture(F, "verbs"), !T, !IO),
        test_run_and_tier(fixture(F, "verbs"), !T, !IO),
        test_admission(fixture(F, "verbs"), !T, !IO),
        test_memory(fixture(F, "verbs"), !T, !IO),
        test_network_reads(fixture(F, "verbs"), !T, !IO),
        test_program_reads(fixture(F, "verbs"), fixture(F, "services"), !T,
            !IO),
        test_json_text(!T, !IO),
        test_recording(fixture(F, "verbs"), fixture(F, "services"), !T,
            !IO),
        test_atoms(fixture(F, "verbs"), !T, !IO),
        test_external(fixture(F, "verbs"), !T, !IO),
        test_facts(fixture(F, "verbs"), !T, !IO),
        test_nfct_2_3_dead_reference(fixture(F, "fact_ref"), !T, !IO),
        test_duties(fixture(F, "verbs"), !T, !IO),
        test_cache_expiry(fixture(F, "verbs"), !T, !IO),
        test_cache_expiry_order(fixture(F, "cache_order"), !T, !IO),
        test_cache_read_expiry_duty(fixture(F, "cache_read_expiry"), !T,
            !IO),
        test_services(fixture(F, "services"), !T, !IO),
        test_service_failures(fixture(F, "services"), !T, !IO),
        test_clock(fixture(F, "verbs"), !T, !IO),
        test_cache_seed(fixture(F, "verbs"), !T, !IO),
        test_copy(fixture(F, "verbs"), !T, !IO),
        test_introspect(fixture(F, "verbs"), fixture(F, "series"), !T, !IO),
        test_halted_reads(fixture(F, "verbs"), fixture(F, "verbs_short_call"),
            !T, !IO),
        test_local_tz(fixture(F, "local_tz"), !T, !IO),
        test_fault_payload(fixture(F, "div_zero"), !T, !IO),
        test_deferred(!T, !IO),
        T = !.T
    ),
    io.format("%d passed, %d failed, %d skipped\n",
        [i(T ^ tl_passed), i(T ^ tl_failed), i(T ^ tl_skipped)], !IO),
    ( if T ^ tl_failed > 0 then
        io.set_exit_status(1, !IO)
    else
        true
    ).

%---------------------------------------------------------------------------%
% The test server
%---------------------------------------------------------------------------%

    % A server for `pump_serving` that writes down each call it was handed,
    % newest first, and answers as its mode says.
    %
:- type test_server
    --->    test_server(
                srv_mode  :: service_mode,
                srv_lines :: list(string)
            ).

:- type service_mode
    --->    forecast(int)
            % `weather.forecast` answers with this high; `light.turn_on` is
            % done.
    ;       offer_nothing
    ;       fail_with(string)
            % Every call fails with this code.
    ;       answer_everything
            % `light.turn_on`, declared `no response`, answers one.
    ;       wrong_slots.
            % `weather.forecast` answers one slot too few.

:- func server(service_mode) = test_server.

server(Mode) = test_server(Mode, []).

    % The calls a server was handed, in order.
    %
:- func served(test_server) = list(string).

served(H) = list.reverse(H ^ srv_lines).

:- pred test_serve(service_call::in, service_answer::out,
    test_server::in, test_server::out, io::di, io::uo) is det.

test_serve(Call, Answer, !H, !IO) :-
    !H ^ srv_lines := [call_text(Call) | !.H ^ srv_lines],
    Answer = answer_for(!.H ^ srv_mode, Call).

:- func call_text(service_call) = string.

call_text(Call) = string.join_list(" ",
        ["serve", Call ^ service_call_service,
            Call ^ service_call_correlation |
            list.map(arg_text, Call ^ service_call_args)]).

:- func answer_for(service_mode, service_call) = service_answer.

answer_for(Mode, Call) = Answer :-
    Service = Call ^ service_call_service,
    Zone = zone_of(Call ^ service_call_args),
    (
        Mode = forecast(High),
        ( if Service = "weather.forecast" then
            Answer = answered([text(Zone), int(int64.from_int(High))])
        else
            Answer = no_response
        )
    ;
        Mode = offer_nothing,
        Answer = not_offered
    ;
        Mode = fail_with(Code),
        Answer = call_error(Code, "down")
    ;
        Mode = answer_everything,
        ( if Service = "weather.forecast" then
            Answer = answered([text(Zone), int(35i64)])
        else
            Answer = answered([])
        )
    ;
        Mode = wrong_slots,
        Answer = answered([int(35i64)])
    ).

:- func zone_of(list(arg)) = string.

zone_of(Args) =
    ( if list.find_first_match(zone_arg, Args, arg(_, av_string(Z))) then Z
      else "" ).

:- pred zone_arg(arg::in) is semidet.

zone_arg(arg("zone", av_string(_))).

:- func arg_text(arg) = string.

arg_text(arg(Name, Value)) = Name ++ "=" ++ Text :-
    ( if Value = av_string(S) then
        Text = S
    else
        Text = "?"
    ).

    % A duty as one line, for the order checks.
    %
:- func duty_text(duty) = string.

duty_text(write_cache(W)) = string.join_list(" ",
        ["write_cache", W ^ cache_write_key, W ^ cache_write_value_json,
        Ttl]) :-
    Ttl = ( if W ^ cache_write_ttl = no then "forever" else "ttl" ).
duty_text(remove_cache(R)) =
        "remove_cache " ++ R ^ cache_removal_key ++ " " ++ Reason :-
    Reason = ( if R ^ cache_removal_reason = expired then "expired"
               else "by_rule" ).

%---------------------------------------------------------------------------%
% Loading
%---------------------------------------------------------------------------%

:- pred test_loading(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_loading(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    check("an artefact loads, and its schemas are there by name",
        ( if
            Loaded = ok(S),
            schema_names(S) = ok(Names),
            list.member("Trig", Names),
            list.member("Alert", Names)
        then yes else no ), !T, !IO),
    % An empty artefact is too short to contain a DscHeader ([RDSC.11.1]),
    % which libds refuses as `dsc_truncated`; the runtime does the same.
    load(bitmap.init(0), default_config, Empty, _),
    check_saw("an empty artefact holds no DscHeader, and is refused as "
        ++ "dsc_truncated",
        ( if Empty = error(status_error(dsc_truncated, _))
          then yes else no ),
        load_text(Empty), !T, !IO),
    load(bytes_bitmap("not an artefact"), default_config, Prose, _),
    load(bitmap.init(64, no), default_config, Zeros, _),
    check_saw("bytes that are not an artefact are refused with a dsc status",
        ( if
            refused_as_dsc(Prose),
            refused_as_dsc(Zeros)
        then yes else no ),
        string.join_list(", ", list.map(load_text, [Prose, Zeros])),
        !T, !IO).

    % [RDSC.9.4]: `load` returns its reports, and
    % an artefact carrying a skip-band atom no registry entry names reports
    % one `dsc-load` info line naming the atom's field number and the byte
    % offset its frame starts at. The artefact is verbs.dsc with an atom of
    % field 999 appended, resealed, so the offset is verbs.dsc's length.
    %
:- pred test_load_reports(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_load_reports(Verbs, !T, !IO) :-
    load(Verbs, default_config, Plain, PlainReports),
    ( if
        Plain = ok(S),
        session_header(S) ^ sm_dsc_hash = Hash,
        with_skip_atom(Verbs, Hash, Skipping)
    then
        check_saw("an artefact with nothing to skip reports nothing at load",
            ( if PlainReports = [] then yes else no ),
            string.string(PlainReports), !T, !IO),
        load(Skipping, default_config, Loaded, Reports),
        At = bitmap.det_num_bytes(Verbs),
        check_saw("[RDSC.9.4] a skip-band atom no entry names loads, and "
            ++ "load reports one dsc-load info line with its field and offset",
            ( if
                Loaded = ok(_),
                Reports = [logged(log_line(log_info, "dsc-load", Message))],
                string.sub_string_search(Message, "999", _),
                string.sub_string_search(Message,
                    "byte offset " ++ string.int_to_string(At), _)
            then yes else no ),
            string.string(Reports), !T, !IO)
    else
        check("verbs.dsc loads, and is resealed with a skip-band atom", no,
            !T, !IO)
    ).

    % `Bytes` with an atom of field 999, in the skip band (256-2047) and
    % allocated to nothing, appended, and resealed as the compiler seals
    % ([RDSC.3.6]): the stored `dsc_sha256`, which the session header
    % reports, zeroed in place, the whole artefact hashed, and the digest
    % written back. The atom is `Atom` field 1, length 4, holding field 999
    % (tag 7994, `BA 3E`) with one byte of body.
    %
:- pred with_skip_atom(bitmap::in, list(uint8)::in, bitmap::out) is semidet.

with_skip_atom(Bytes, Hash, Sealed) :-
    N = bitmap.det_num_bytes(Bytes),
    Ints = list.map((func(I) = bitmap.byte(I, Bytes)), 0 .. N - 1)
        ++ [0x0A, 0x04, 0xBA, 0x3E, 0x01, 0x00],
    HashInts = list.map(uint8.cast_to_int, Hash),
    list.length(HashInts) = 32,
    offset_of(HashInts, Ints, 0, Off),
    Zeroed = splice(Off, list.duplicate(32, 0), Ints),
    Digest = ds.sha256.sha256(list.map(uint8.cast_from_int, Zeroed)),
    Resealed = splice(Off, list.map(uint8.cast_to_int, Digest), Zeroed),
    Sealed = fill(Resealed, 0, bitmap.init(list.length(Resealed) * 8)).

    % Where `Needle` first starts in `Hay`, counting from `At`.
    %
:- pred offset_of(list(int)::in, list(int)::in, int::in, int::out)
    is semidet.

offset_of(Needle, Hay, At, Off) :-
    Hay = [_ | Rest],
    ( if list.append(Needle, _, Hay) then
        Off = At
    else
        offset_of(Needle, Rest, At + 1, Off)
    ).

    % `List` with the elements from `At` on replaced by `New`, as many as
    % `New` has.
    %
:- func splice(int, list(int), list(int)) = list(int).

splice(At, New, List) = Before ++ New ++ After :-
    list.split_upto(At, List, Before, Rest),
    list.split_upto(list.length(New), Rest, _, After).

:- func load_text(maybe_error(session, ds_error)) = string.

load_text(ok(_)) = "loaded".
load_text(error(E)) = string.string(E).

:- pred refused_as_dsc(maybe_error(session, ds_error)::in) is semidet.

refused_as_dsc(error(status_error(Status, _))) :-
    Number = status_number(Status),
    Number =< status_number(dsc_truncated),
    Number >= status_number(dsc_capability_absent).

%---------------------------------------------------------------------------%
% Run and tier ids, and the session header
%---------------------------------------------------------------------------%

:- pred test_run_and_tier(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_run_and_tier(Verbs, !T, !IO) :-
    Given = (default_config ^ session_config_run_id := yes("run-7"))
        ^ session_config_tier_id := yes("edge"),
    Empty = (default_config ^ session_config_run_id := yes(""))
        ^ session_config_tier_id := yes(""),
    load(Verbs, Given, LoadedG, _),
    load(Verbs, default_config, LoadedD, _),
    load(Verbs, Empty, LoadedE, _),
    ( if
        LoadedG = ok(G),
        LoadedD = ok(D),
        LoadedE = ok(E)
    then
        HeaderG = session_header(G),
        HeaderG = stream_meta(Version, Hash, Capabilities, DefSha, RunG,
            TierG),
        check_saw("a session's run and tier ids are those it was loaded "
            ++ "with, and its header reports them",
            ( if
                run_id(G) = ok(yes("run-7")),
                tier_id(G) = ok(yes("edge")),
                RunG = "run-7",
                TierG = "edge"
            then yes else no ), string.string(HeaderG), !T, !IO),
        check_saw("the header names the DS version, the artefact's SHA-256, "
            ++ "and the rest of its dialect-binding tuple",
            ( if
                Version \= "",
                list.length(Hash) = 32,
                artefact_header(G) = ok(HeaderInfo),
                Capabilities = HeaderInfo ^ dh_capabilities,
                DefSha = HeaderInfo ^ dh_dialect_sha
            then yes else no ), string.string(HeaderG), !T, !IO),
        HeaderD = session_header(D),
        HeaderD = stream_meta(_, _, _, _, RunD, TierD),
        check_saw("ids not given are absent, and the header reports them "
            ++ "as empty",
            ( if
                run_id(D) = ok(no),
                tier_id(D) = ok(no),
                RunD = "",
                TierD = ""
            then yes else no ), string.string(HeaderD), !T, !IO),
        check("an empty id is no id",
            ( if run_id(E) = ok(no), tier_id(E) = ok(no) then yes else no ),
            !T, !IO)
    else
        check("verbs.dsc loads with each id configuration", no, !T, !IO)
    ),
    % [NLFC.1.2], [LSTR.8.5]: an id that is not well-formed UTF-8 is
    % refused as `encoding` and no session is made, as libds's
    % `ds_engine_new` refuses it with DS_ERR_ENCODING. An encoded surrogate
    % as the run id, and a lone C0 as the tier id.
    ( if
        string.from_code_unit_list_allow_ill_formed([0x72, 0xED, 0xA0, 0x80],
            IllRun),
        string.from_code_unit_list_allow_ill_formed([0xC0], IllTier)
    then
        load(Verbs, default_config ^ session_config_run_id := yes(IllRun),
            BadRun, _),
        load(Verbs, default_config ^ session_config_tier_id := yes(IllTier),
            BadTier, _),
        check_saw("a run_id or tier_id that is not well-formed UTF-8 refuses "
                ++ "the load as encoding",
            ( if
                BadRun = error(ER), error_status(ER, encoding),
                BadTier = error(ET), error_status(ET, encoding)
            then yes else no ),
            load_text(BadRun) ++ " / " ++ load_text(BadTier), !T, !IO)
    else
        check("the ill-formed ids could be built", no, !T, !IO)
    ).

%---------------------------------------------------------------------------%
% Admission
%---------------------------------------------------------------------------%

:- pred test_admission(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_admission(Verbs, !T, !IO) :-
    % verbs.ds calls a service, so its `call` setting is true, and its
    % `realtime` setting is false.
    Call = cap_call,
    Realtime = cap_realtime,
    load(Verbs, admitting(Call, admit_false_only), Refused, _),
    check_saw("a setting the configuration does not admit refuses the load "
        ++ "as bnd_dialect_mismatch",
        ( if Refused = error(status_error(bnd_dialect_mismatch, _))
          then yes else no ),
        load_text(Refused), !T, !IO),
    load(Verbs, admitting(Call, admit_true_only), TrueOnly, _),
    load(Verbs, admitting(Realtime, admit_false_only), FalseOnly, _),
    check_saw("a setting the configuration admits loads",
        ( if
            TrueOnly = ok(_),
            FalseOnly = ok(_)
        then yes else no ),
        load_text(TrueOnly) ++ ", " ++ load_text(FalseOnly), !T, !IO).

    % The default configuration, admitting only this setting of one
    % capability.
    %
:- func admitting(capability, admission) = session_config.

admitting(Capability, Admit) =
    default_config ^ session_config_admission :=
        map.singleton(Capability, Admit).

%---------------------------------------------------------------------------%
% Memory
%---------------------------------------------------------------------------%

:- pred test_memory(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_memory(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Trig", [int(1i64)], _, S0, S1),
        Facts0 = wm_facts(got(memory_usage(S0))),
        Facts1 = wm_facts(got(memory_usage(S1))),
        check_saw("memory counts a fact the session asserts",
            ( if Facts1 = Facts0 + 1 then yes else no ),
            string.format("%d then %d", [i(Facts0), i(Facts1)]), !T, !IO)
    else
        check("verbs.dsc loads for memory", no, !T, !IO)
    ).

    % The working-memory fact count of a memory report.
    %
:- func wm_facts(engine_mem) = int.

wm_facts(Mem) = Count :-
    Mem = engine_mem(Count, _, _, _, _, _, _, _, _, _, _, _, _, _, _).

%---------------------------------------------------------------------------%
% The network
%---------------------------------------------------------------------------%

:- pred test_network_reads(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_network_reads(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Trig", [int(1i64)], A, S0, S1),
        pump(_, S1, S2),
        ( if A ^ assert_step_outcome = asserted(Id) then
            Fired = got(refracted_activations(S2, yes("fire_them_all"))),
            check_saw("the match that fired is held back, naming its rule "
                ++ "and its fact",
                ( if
                    Fired = [Entry],
                    Entry = refracted_activation("fire_them_all", _, _, [Id])
                then yes else no ), string.string(Fired), !T, !IO),
            check("a rule that has not fired holds nothing back",
                ( if refracted_activations(S2, yes("warm_cache")) = ok([])
                  then yes else no ), !T, !IO),
            Trace = got(match_trace(S2, Id)),
            check_saw("a live fact's trace passes its rule's alpha node",
                ( if
                    Trace = [_ | _],
                    list.all_true(passed_step, Trace)
                then yes else no ), string.string(Trace), !T, !IO),
            retract_fact(Id, _, S2, S3),
            check("a fact no longer live traces nothing",
                ( if match_trace(S3, Id) = ok([]) then yes else no ), !T, !IO)
        else
            check("verbs.dsc asserts a Trig for the network reads", no, !T,
                !IO)
        )
    else
        check("verbs.dsc loads for the network reads", no, !T, !IO)
    ).

:- pred passed_step(trace_step::in) is semidet.

passed_step(trace_step(_, "alpha", "passed", _)).

%---------------------------------------------------------------------------%
% Schemas and services
%---------------------------------------------------------------------------%

:- pred test_program_reads(bitmap::in, bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_program_reads(Verbs, Services, !T, !IO) :-
    load(Services, default_config, LoadedS, _),
    ( if LoadedS = ok(S) then
        Declared = got(services(S)),
        check_saw("the program's services are listed, each with its "
            ++ "response schema, or none for `no response`, and its kwargs",
            ( if
                list.length(Declared) = 3,
                list.member(service_info("weather.forecast",
                    yes("ForecastReply"), [
                        service_kwarg("zone", "String", no, no,
                            no_default)]), Declared),
                list.member(service_info("light.turn_on", no, [
                        service_kwarg("entity_id", "String", no, no,
                            no_default)]), Declared)
            then yes else no ), string.string(Declared), !T, !IO),
        % In name order, as the artefact lists them.
        check_saw("a kwarg reads back required, literal and its default",
            ( if
                list.member(service_info("weather.alerts", no, [
                        service_kwarg("days", "Int", no, no,
                            default_text("3")),
                        service_kwarg("region", "String", yes, yes,
                            no_default),
                        service_kwarg("severe", "Bool", no, no,
                            default_text("true"))]), Declared)
            then yes else no ), string.string(Declared), !T, !IO)
    else
        check("services.dsc loads for its services", no, !T, !IO)
    ),
    load(Verbs, default_config, LoadedV, _),
    ( if LoadedV = ok(V0) then
        ( if search_schema(V0, "Alert", ok(Alert)) then
            AlertSlots = got(slot_names(V0, Alert)),
            check_saw("a schema's slot names are in declaration order",
                ( if AlertSlots = ["severity", "zone"] then yes else no ),
                string.string(AlertSlots), !T, !IO)
        else
            check("verbs.dsc declares Alert", no, !T, !IO)
        ),
        ( if
            search_schema(V0, "Trig", ok(Trig)),
            proto_text(Trig) = yes(Text)
        then
            check_saw("an artefact schema's .proto text is the compiler's "
                ++ "message for it",
                ( if string.sub_string_search(Text, "message Trig", _)
                  then yes else no ), Text, !T, !IO)
        else
            check("an artefact schema has .proto text", no, !T, !IO)
        ),
        ( if search_schema_source(V0, "Trig", ok(TrigLoc)) then
            check_saw("an artefact schema says where it is declared: "
                ++ "verbs.ds, line 9",
                ( if
                    TrigLoc = source_loc(yes(TrigFile), 9, TrigColumn),
                    string.suffix(TrigFile, "verbs.ds"),
                    TrigColumn >= 1,
                    lookup_schema_source(V0, "Trig") = ok(TrigLoc)
                then yes else no ), string.string(TrigLoc), !T, !IO)
        else
            check("an artefact schema has a source position", no, !T, !IO)
        ),
        % Each "no position" check first finds the schema, so a name the
        % program lacks cannot pass it.
        check("a builtin schema has no source position",
            ( if
                search_schema(V0, "ComputationError", ok(_)),
                not search_schema_source(V0, "ComputationError", _)
            then yes else no ), !T, !IO)
        % No host-registered schema: none reaches a session but its
        % artefact's ([NFCT.1.1]).
    else
        check("verbs.dsc loads for its schemas", no, !T, !IO)
    ).

    % A Json value from its text and back: the document, the canonical text,
    % and the refusals libds's parser and serialiser answer with.
    %
:- pred test_json_text(tally::in, tally::out, io::di, io::uo) is det.

test_json_text(!T, !IO) :-
    Parsed = json_from_text("{\"b\": [1, 2.5, true, null], \"a\": \"x\"}"),
    Expected = j_object(object(["a" - j_string("x"),
        "b" - j_array([j_int(1i64), j_float(2.5), j_bool(yes), j_null])])),
    check_saw("a Json text reads as its document, an Int and a Float kept "
        ++ "apart", ( if Parsed = ok(Expected) then yes else no ),
        string.string(Parsed), !T, !IO),
    Written = json_to_text(Expected),
    check_saw("a Json value's text has no whitespace and its keys in order",
        ( if Written = ok("{\"a\":\"x\",\"b\":[1,2.5,true,null]}")
          then yes else no ), string.string(Written), !T, !IO),
    check("a float JSON cannot spell is refused as json_nonfinite",
        ( if
            json_to_text(j_array([j_float(float.infinity)])) = error(Inf),
            error_status(Inf, json_nonfinite)
        then yes else no ), !T, !IO),
    check("a text with more than one document is refused as parse",
        ( if
            json_from_text("{\"a\": 1} x") = error(Trailing),
            error_status(Trailing, parse)
        then yes else no ), !T, !IO),
    check("an object that names one key twice is refused as parse",
        ( if
            json_from_text("{\"a\": 1, \"a\": 2}") = error(Repeated),
            error_status(Repeated, parse)
        then yes else no ), !T, !IO),
    % [LGRA.5.8.10]: a float literal that rounds to an infinity is
    % malformed, as libds's parser refuses it; one that rounds to the largest
    % double is not.
    check("a float literal past the double range is refused as parse",
        ( if
            json_from_text("[1.7976931348623159e308]") = error(Overflow),
            error_status(Overflow, parse)
        then yes else no ), !T, !IO),
    check("a float literal that rounds to the largest double is read",
        ( if json_from_text("1.7976931348623158e308") = ok(j_float(float.max))
          then yes else no ), !T, !IO),
    Deep = ds.json.max_depth + 1,
    Nested = string.duplicate_char('[', Deep) ++
        string.duplicate_char(']', Deep),
    check("a text nested past the depth limit is refused as json_limit",
        ( if
            json_from_text(Nested) = error(TooDeep),
            error_status(TooDeep, json_limit)
        then yes else no ), !T, !IO),
    % [LSTR.8.5]: ill-formed UTF-8 is `encoding`, checked after the
    % text limit and before the parse, as libds's `ds_json_parse` orders it.
    % The octet 0xff is both ill-formed and not JSON, so `parse` would mean
    % the check came after the parse, or never.
    check("a text that is not well-formed UTF-8 is refused as encoding",
        ( if
            string.from_code_unit_list_allow_ill_formed([0xff], Ill),
            json_from_text(Ill) = error(IllError),
            error_status(IllError, encoding)
        then yes else no ), !T, !IO),
    check("ill-formed UTF-8 inside a string value is refused as encoding",
        ( if
            string.from_code_unit_list_allow_ill_formed(
                [0x22, 0x61, 0xed, 0xa0, 0x80, 0x22], Surrogate),
            json_from_text(Surrogate) = error(SurrogateError),
            error_status(SurrogateError, encoding)
        then yes else no ), !T, !IO),
    check("ill-formed text past the text limit is refused as json_limit",
        ( if
            string.from_code_unit_list_allow_ill_formed(
                list.duplicate(ds.json.max_text_bytes + 1, 0xff), Long),
            json_from_text(Long) = error(LongError),
            error_status(LongError, json_limit)
        then yes else no ), !T, !IO).

%---------------------------------------------------------------------------%
% Recording and replay
%---------------------------------------------------------------------------%

:- pred test_recording(bitmap::in, bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_recording(Verbs, Services, !T, !IO) :-
    load(Verbs, default_config, LoadedA, _),
    load(Verbs, default_config, LoadedB, _),
    load(Services, default_config, LoadedC, _),
    ( if
        LoadedA = ok(A0),
        LoadedB = ok(B0),
        LoadedC = ok(C0)
    then
        check("a session not recording has no recording",
            ( if recording(A0) = no then yes else no ), !T, !IO),
        start_recording(A0, A1),
        check("a recording over no event has no bytes",
            ( if
                recording(A1) = yes(Empty),
                bitmap.num_bits(Empty ^ recording_bytes) = 0
            then yes else no ), !T, !IO),

        assert_fact("Trig", [int(1i64)], First, A1, A2),
        pump(_, A2, A3),
        ( if recording(A3) = yes(Recording) then
            Bytes = Recording ^ recording_bytes,
            check_saw("a recording holds the session's events, every one "
                ++ "encoded",
                ( if
                    bitmap.num_bits(Bytes) > 0,
                    Recording ^ recording_unencodable = []
                then yes else no ),
                string.string(Recording ^ recording_unencodable), !T, !IO),

            replay(Bytes, Replayed, B0, B1),
            check_saw("a replay into a fresh session reproduces the "
                ++ "recorded session's facts",
                ( if
                    Replayed ^ step_outcome = ok,
                    fact_texts(B1) = fact_texts(A3)
                then yes else no ),
                string.string(Replayed ^ step_outcome) ++ "; " ++
                    facts_text(B1), !T, !IO),
            check("...and reports what the engine derived again",
                ( if events(Replayed ^ step_reports) = [_ | _] then yes
                  else no ), !T, !IO),

            % A second assert after the clock moves: the replay delivers
            % both in one call, across the tick between them.
            advance(duration_from_ns(5_000_000_000u64), _, A3, A4),
            assert_fact("Trig", [int(2i64)], Second, A4, A5),
            ( if
                recording(A5) = yes(Crossing),
                trig_assert_clock(First ^ assert_step_reports, 1i64, Clock1),
                trig_assert_clock(Second ^ assert_step_reports, 2i64, Clock2)
            then
                replay(Crossing ^ recording_bytes, Recrossed, B0, _),
                Again = Recrossed ^ step_reports,
                check_saw("a replayed event carries the clock it was "
                    ++ "emitted at, on either side of a tick",
                    ( if
                        Clock1 \= Clock2,
                        trig_assert_clock(Again, 1i64, Clock1),
                        trig_assert_clock(Again, 2i64, Clock2)
                    then yes else no ),
                    string.string(events(Again)), !T, !IO),

                decode_stream(Crossing ^ recording_bytes, init_interns,
                    Decoded),
                check_saw("an event's seq is the engine's number for it, the "
                    ++ "seq its recording's atom carries",
                    ( if
                        Decoded = decoded(Stream),
                        Recorded = Stream ^ dsm_events,
                        trig_assert_seq(First ^ assert_step_reports, 1i64,
                            Seq1),
                        trig_assert_seq(Second ^ assert_step_reports, 2i64,
                            Seq2),
                        recorded_trig_seq(Recorded, 1i64, Seq1),
                        recorded_trig_seq(Recorded, 2i64, Seq2)
                    then yes else no ),
                    string.string(events(First ^ assert_step_reports ++
                        Second ^ assert_step_reports)), !T, !IO)
            else
                check("a recording session reports both asserts", no, !T,
                    !IO)
            ),

            replay(Bytes, Other, C0, _),
            check_saw("a recording made with another artefact is refused "
                ++ "as bnd_dsc_mismatch",
                ( if
                    Other ^ step_outcome = error(EO),
                    error_status(EO, bnd_dsc_mismatch)
                then yes else no ),
                string.string(Other ^ step_outcome), !T, !IO)
        else
            check("a session recording has a recording", no, !T, !IO)
        ),

        % Begun after the session's first event: its first atom's seq is
        % not 0.
        assert_fact("Trig", [int(1i64)], _, A0, L1),
        start_recording(L1, LR),
        assert_fact("Trig", [int(2i64)], _, LR, L2),
        ( if recording(L2) = yes(Late) then
            replay(Late ^ recording_bytes, LateReplay, B0, _),
            check_saw("a recording begun after the first event is refused "
                ++ "as fs_recording_incomplete",
                ( if
                    LateReplay ^ step_outcome = error(EL),
                    error_status(EL, fs_recording_incomplete)
                then yes else no ),
                string.string(LateReplay ^ step_outcome), !T, !IO)
        else
            check("a late recording has a recording", no, !T, !IO)
        ),

        replay(bitmap.init(0), Nothing, B0, _),
        replay(bytes_bitmap("not a recording"), Prose, B0, _),
        check_saw("no header is refused as fs_version, and bytes that are "
            ++ "not atoms as parse",
            ( if
                Nothing ^ step_outcome = error(EN),
                error_status(EN, fs_version),
                Prose ^ step_outcome = error(EP),
                error_status(EP, parse)
            then yes else no ),
            string.string(Nothing ^ step_outcome) ++ ", " ++
                string.string(Prose ^ step_outcome), !T, !IO),

        stop_recording(A3, Stopped),
        check("stop_recording ends it",
            ( if recording(Stopped) = no then yes else no ),
            !T, !IO)
    else
        check("the fixtures load for recording", no, !T, !IO)
    ).

%---------------------------------------------------------------------------%
% Atoms
%---------------------------------------------------------------------------%

:- pred test_atoms(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_atoms(Verbs, !T, !IO) :-
    Artefact = atoms(Verbs),
    check_saw("an artefact's atoms are read in order, from its DscHeader to "
        ++ "its last byte",
        ( if
            Artefact ^ atom_listing_outcome = ok,
            Artefact ^ atom_listing_atoms = [First | _],
            First ^ atom_ref = known(at_dsc_header),
            list.last(Artefact ^ atom_listing_atoms, Last),
            Last ^ atom_body_offset + Last ^ atom_body_length =
                bitmap.num_bits(Verbs) / 8
        then yes else no ),
        string.string(Artefact ^ atom_listing_outcome), !T, !IO),

    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        start_recording(S0, R0),
        assert_fact("Trig", [int(1i64)], _, R0, S1),
        ( if recording(S1) = yes(Recording) then
            Stream = atoms(Recording ^ recording_bytes),
            check_saw("a recording's atoms open with its StreamHeader",
                ( if
                    Stream ^ atom_listing_outcome = ok,
                    Stream ^ atom_listing_atoms = [Header | _],
                    Header ^ atom_ref = known(at_stream_header)
                then yes else no ),
                string.string(Stream ^ atom_listing_outcome), !T, !IO)
        else
            check("a session recording an assert has a recording", no, !T,
                !IO)
        )
    else
        check("verbs.dsc loads for its recording's atoms", no, !T, !IO)
    ),

    Prose = atoms(bytes_bitmap("not atoms")),
    check_saw("bytes that are not frames stop the walk with parse",
        ( if
            Prose ^ atom_listing_atoms = [],
            Prose ^ atom_listing_outcome = error(Error),
            error_status(Error, parse)
        then yes else no ),
        string.string(Prose ^ atom_listing_outcome), !T, !IO).

%---------------------------------------------------------------------------%
% A fact from another tier
%---------------------------------------------------------------------------%

:- pred test_external(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_external(Verbs, !T, !IO) :-
    load(Verbs, default_config, LoadedA, _),
    load(Verbs, default_config, LoadedB, _),
    ( if
        LoadedA = ok(A0),
        LoadedB = ok(B0)
    then
        % verbs.ds's rule publishes an Alert, which another tier receives.
        assert_fact("Trig", [int(1i64)], _, A0, A1),
        pump(P, A1, _),
        ( if
            list.find_first_map(published, events(P ^ pumped_reports),
                Published),
            ds.fact_external.encode_fact_external(Published, Octets)
        then
            assert_external(octets_bitmap(Octets), X, B0, B1),
            check_saw("a fact another tier published is asserted here",
                ( if
                    X ^ step_outcome = ok,
                    facts(B1) = ok(B1Facts),
                    list.member(V, B1Facts),
                    V ^ fact_view_schema = "Alert"
                then yes else no ),
                string.string(X ^ step_outcome) ++ "; " ++ facts_text(B1),
                !T, !IO)
        else
            check("verbs.dsc's publish reports its FactExternal", no, !T,
                !IO)
        ),
        assert_external(bytes_bitmap("not a fact"), Bad, B0, _),
        check_saw("bytes that are not a FactExternal are refused as parse",
            ( if
                Bad ^ step_outcome = error(EB),
                error_status(EB, parse)
            then yes else no ),
            string.string(Bad ^ step_outcome), !T, !IO)
    else
        check("verbs.dsc loads for a fact from another tier", no, !T, !IO)
    ).

    % The fact a publish event carries across. Fail for any other event.
    %
:- pred published(integrator_event::in, fact_external::out) is semidet.

published(Ev, Published) :-
    Ev ^ integrator_event_kind = action_publish(_, _, yes(Published)).

:- func octets_bitmap(list(uint8)) = bitmap.

octets_bitmap(Octets) =
        fill(Codes, 0, bitmap.init(list.length(Codes) * 8)) :-
    Codes = list.map(uint8.cast_to_int, Octets).

    % A session's facts as text, in order, ids aside.
    %
:- func fact_texts(session) = list(string).

fact_texts(S) = list.sort(list.map(view_text, got(facts(S)))).

%---------------------------------------------------------------------------%
% Facts
%---------------------------------------------------------------------------%

:- pred test_facts(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_facts(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Trig", [int(1i64)], A1, S0, S1),
        ( if A1 ^ assert_step_outcome = asserted(Id) then
            facts_after_assert(Id, A1, S1, !T, !IO)
        else
            check("a fact is asserted", no, !T, !IO)
        )
    else
        check("verbs.dsc loads for the fact tests", no, !T, !IO)
    ).

    % @spec [NFCT.2.3]
    % `assert_fact` with a reference to a retracted fact reports
    % `slot_type_mismatch` and changes nothing; the same reference is admitted
    % while its target lives, so the refusal is the target's death.
    % PATH PINNED: `assert_fact` -> `assert_values` ->
    % `ds.engine.host_assert`, then `outcome_of_assert`'s `slot_status`.
    %
:- pred test_nfct_2_3_dead_reference(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_nfct_2_3_dead_reference(Dsc, !T, !IO) :-
    load(Dsc, default_config, Loaded, _),
    ( if
        Loaded = ok(S0),
        assert_fact("Target", [int(1i64)], A1, S0, S1),
        A1 ^ assert_step_outcome = asserted(Target)
    then
        assert_fact("Holder", [int(1i64), fact_ref(Target)], Live, S1, _),
        check("a reference to a live fact of the slot's schema is admitted",
            ( if Live ^ assert_step_outcome = asserted(_) then yes else no ),
            !T, !IO),
        retract_fact(Target, _, S1, S2),
        assert_fact("Holder", [int(1i64), fact_ref(Target)], Dead, S2, S3),
        check("a reference to a retracted fact is refused as "
            ++ "slot_type_mismatch",
            ( if refused_with(Dead, slot_type_mismatch) then yes else no ),
            !T, !IO),
        check("a refused reference asserts nothing",
            ( if
                Dead ^ assert_step_reports = [],
                facts(S3) = ok(Views),
                Views = []
            then yes else no ), !T, !IO)
    else
        check("fact_ref.dsc loads and asserts a Target", no, !T, !IO)
    ).

:- pred facts_after_assert(fact_id::in, assert_step::in, session::in,
    tally::in, tally::out, io::di, io::uo) is det.

facts_after_assert(Id, A1, S1, !T, !IO) :-
    check("an asserted fact reads back by its id",
        ( if
            search_fact(S1, Id, ok(V)),
            V ^ fact_view_schema = "Trig",
            V ^ fact_view_slots = [int(1i64)]
        then yes else no ), !T, !IO),
    check("an assert reports the fact, its schema and its slots",
        ( if
            list.member(E, events(A1 ^ assert_step_reports)),
            E ^ integrator_event_kind = fact_assert(Id, "Trig", [int(1i64)])
        then yes else no ), !T, !IO),

    assert_fact("Trig", [int(1i64)], A2, S1, S2),
    check("an unchanged reassert keeps the fact and its id",
        ( if A2 ^ assert_step_outcome = unchanged(Id) then yes else no ),
        !T, !IO),
    assert_fact("Trig", [int(1i64), int(2i64)], R1, S2, _),
    check("a slot list of the wrong length is refused as inval",
        ( if refused_with(R1, inval) then yes else no ), !T, !IO),
    assert_fact("Nope", [], R2, S2, _),
    check("an unknown schema is refused as schema_unknown",
        ( if refused_with(R2, schema_unknown) then yes else no ), !T, !IO),
    assert_fact("Trig", [text("x")], R3, S2, _),
    check("a string in an Int slot is refused as slot_type_mismatch",
        ( if refused_with(R3, slot_type_mismatch) then yes else no ), !T, !IO),
    assert_fact("Trig", [float(1.0)], R4, S2, _),
    check("a float in an Int slot is refused as slot_type_mismatch",
        ( if refused_with(R4, slot_type_mismatch) then yes else no ), !T, !IO),

    % A `ttl 1_h` schema's fact: its deadline is its schema's TTL. There is no
    % per-fact override to test.
    Hour = duration_from_ns(3_600_000_000_000u64),
    assert_fact("Alert", [int(3i64), text("hall")], A3, S2, S3),
    check("a ttl schema's fact takes its schema's TTL as its deadline",
        ( if
            A3 ^ assert_step_outcome = asserted(HallId),
            search_fact(S3, HallId, ok(HallView)),
            now(S2) = ok(Now2),
            HallView ^ fact_view_deadline = yes(ds.chrono.add(Now2, Hour))
        then yes else no ), !T, !IO),

    TwoHours = duration_from_ns(7_200_000_000_000u64),
    advance(TwoHours, Adv, S3, S4),
    pump(P, S4, S5),
    check("advancing past a TTL and pumping expires the fact",
        ( if
            Adv ^ step_outcome = ok,
            P ^ pumped_outcome = ok,
            A3 ^ assert_step_outcome = asserted(Gone),
            not search_fact(S5, Gone, _)
        then yes else no ), !T, !IO),

    retract_fact(Id, Rt, S5, S6),
    check("a live fact retracts, and the retract is reported",
        ( if
            Rt ^ step_outcome = ok,
            list.member(E2, events(Rt ^ step_reports)),
            E2 ^ integrator_event_kind = fact_retract(Id),
            not search_fact(S6, Id, _)
        then yes else no ), !T, !IO),
    retract_fact(Id, Rt2, S6, _),
    check("retracting a fact that is not live is refused as not_found",
        ( if
            Rt2 ^ step_outcome = error(Err),
            error_status(Err, not_found)
        then yes else no ), !T, !IO),

    Seqs = list.map(event_seq,
        events(A1 ^ assert_step_reports ++ A2 ^ assert_step_reports ++
            A3 ^ assert_step_reports ++ Adv ^ step_reports ++
            P ^ pumped_reports ++ Rt ^ step_reports)),
    check_saw("the stream's seq rises from 0 across a session, each number "
        ++ "once",
        ( if
            Seqs = [0 | _],
            list.sort_and_remove_dups(Seqs) = Seqs
        then yes else no ), string.string(Seqs), !T, !IO).

:- pred refused_with(assert_step::in, status::in) is semidet.

refused_with(Step, Status) :-
    Step ^ assert_step_outcome = error(Err),
    error_status(Err, Status).

%---------------------------------------------------------------------------%
% Duties
%---------------------------------------------------------------------------%

:- pred test_duties(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_duties(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Trig", [int(1i64)], _, S0, S1),
        pump(P, S1, S2),
        Events = events(P ^ pumped_reports),
        Kinds = list.map(kind_name, Events),
        check("a pump succeeds",
            ( if P ^ pumped_outcome = ok then yes else no ), !T, !IO),
        check("a firing's verbs come between its begin and its end, in order",
            ( if
                list.drop_while(not_name("begin"), Kinds, ["begin" | Inside]),
                list.take_while(not_name("end"), Inside, Firing),
                list.filter(not_name("other"), Firing, Verbs0),
                Verbs0 = ["log", "emit", "publish", "call", "cache_set",
                    "cache_delete"]
            then yes else no ), !T, !IO),
        check("every event of one firing carries its timetag",
            ( if
                list.filter_map(event_timetag, Events, Timetags),
                Timetags = [First | Rest],
                list.all_true(same_timetag(First), Rest),
                list.length(Timetags) >= 3
            then yes else no ), !T, !IO),
        check("the call reports its service, correlation and typed "
            ++ "arguments",
            ( if
                list.member(E, Events),
                E ^ integrator_event_kind = action_call(Call),
                Call ^ service_call_service = "light.turn_on",
                Call ^ service_call_correlation = "corr-1",
                Call ^ service_call_args =
                    [arg("entity_id", av_string("light.foyer"))],
                Call ^ service_call_activation ^ activation_rule =
                    "fire_them_all"
            then yes else no ), !T, !IO),
        check("a publish reports its schema, its two values and the fact "
            ++ "as it crosses to another engine",
            ( if
                list.member(E3, Events),
                E3 ^ integrator_event_kind =
                    action_publish("Alert", PubValues, yes(_)),
                list.length(PubValues) = 2
            then yes else no ), !T, !IO),
        check("a rule's log is a log line, its category the rule",
            ( if
                list.member(logged(log_line(log_warning, "fire_them_all",
                    "trig 1")), P ^ pumped_reports)
            then yes else no ), !T, !IO),
        check("each stream event is counted as a metric",
            ( if
                list.member(measured(M), P ^ pumped_reports),
                M ^ m_name = "ds.recorder.events_emitted_total"
            then yes else no ), !T, !IO),
        Duties = list.map(duty_text, P ^ pumped_duties),
        Calls = list.map(call_text, P ^ pumped_calls),
        check_saw("a pump returns its duties in firing order, and the call "
            ++ "it issued",
            ( if
                Duties = ["write_cache last_alert 1 forever",
                    "remove_cache last_alert by_rule"],
                Calls = ["serve light.turn_on corr-1 entity_id=light.foyer"]
            then yes else no ),
            string.string(Duties) ++ " " ++ string.string(Calls), !T, !IO),
        check("the emit adds an Alert and the publish adds none "
            ++ "([LTIE.4.3])",
            ( if fact_count(S2) = ok(2) then yes else no ), !T, !IO),
        check("the session before a pump is untouched by it",
            ( if fact_count(S1) = ok(1) then yes else no ), !T, !IO),
        pump(Again, S1, _),
        check("a pump is a function of the session: pumping it again gives "
            ++ "the same result",
            ( if Again = P then yes else no ), !T, !IO)
    else
        check("verbs.dsc loads for the duty tests", no, !T, !IO)
    ).

:- pred not_name(string::in, string::in) is semidet.

not_name(Name, Other) :-
    Other \= Name.

:- pred same_timetag(timetag::in, timetag::in) is semidet.

same_timetag(Timetag, Timetag).

:- pred event_timetag(integrator_event::in, timetag::out) is semidet.

event_timetag(E, Timetag) :-
    K = E ^ integrator_event_kind,
    (
        K = rule_fire_begin(activation(_, Timetag))
    ;
        K = rule_fire_end(activation(_, Timetag))
    ;
        K = rule_lhs_facts(activation(_, Timetag), _)
    ;
        K = action_call(Call),
        Call ^ service_call_activation = activation(_, Timetag)
    ).

:- pred test_cache_expiry(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_cache_expiry(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Warm", [int(1i64)], _, S0, S1),
        pump(P1, S1, S2),
        advance(duration_from_ns(10_000_000_000u64), _, S2, S3),
        pump(P2, S3, _),
        Duties = list.map(duty_text, P1 ^ pumped_duties ++ P2 ^ pumped_duties),
        check_saw("a cache entry whose TTL runs out is removed as expired",
            ( if
                Duties = ["write_cache warm 2 ttl",
                    "remove_cache warm expired"]
            then yes else no ),
            string.string(Duties), !T, !IO)
    else
        check("verbs.dsc loads for the cache expiry", no, !T, !IO)
    ).

    % @spec [NSTG.2.4.2]
    % The expiry has its place among the pump's reports. One pump
    % meets an expired fact (`Brief`, 2 s), an expired cache entry (`soon`,
    % 2 s) and a rule to fire (`go`): its reports carry the fact sweep's
    % retract, then the entry's `cache_expired`, then the firing, the order
    % [NSTG.2.4.2] fixes and libds's callbacks see. The duty is handed over
    % as well, unchanged. Drives `session.pump` and the binding's split of
    % the runtime's effects into reports and duties (`from_runtime`'s
    % `convert`, `session`'s `duty_of`). One binding's pin, not a
    % ratification: the clause binds the binding class.
    %
:- pred test_cache_expiry_order(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_cache_expiry_order(Order, !T, !IO) :-
    load(Order, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Seed", [int(1i64)], _, S0, S1),
        pump(_, S1, S2),
        assert_fact("Brief", [int(1i64)], _, S2, S3),
        assert_fact("Go", [int(1i64)], _, S3, S4),
        advance(duration_from_ns(3_000_000_000u64), _, S4, S5),
        pump(P, S5, _),
        Reports = P ^ pumped_reports,
        ( if
            first_at(is_retract_report, Reports, 0, Swept),
            first_at(is_expiry_report("soon"), Reports, 0, Expired),
            first_at(is_fire_begin_report("go"), Reports, 0, Fired)
        then
            check_saw("[NSTG.2.4.2] a pump reports a cache expiry after the "
                ++ "fact sweep's retract and before the run's firing",
                ( if Swept < Expired, Expired < Fired then yes else no ),
                string.format("retract %d, expiry %d, fire_begin %d",
                    [i(Swept), i(Expired), i(Fired)]), !T, !IO)
        else
            check_saw("[NSTG.2.4.2] the pump reports the fact sweep's "
                ++ "retract, the cache expiry and the firing", no,
                string.string(Reports), !T, !IO)
        ),
        Duties = list.map(duty_text, P ^ pumped_duties),
        check_saw("and hands the host the expiry as a duty, as before",
            ( if Duties = ["remove_cache soon expired"] then yes else no ),
            string.string(Duties), !T, !IO)
    else
        check("cache_order.dsc loads", no, !T, !IO)
    ).

    % @spec [NSTG.2.4.2]
    % A host assert's own read of an expired entry hands the host its duty.
    % `112_cache_read_expiry`'s steps: `rw` writes "k" for 10 s, the
    % clock reaches the deadline with no pump, and the assert of `q` runs
    % `rq1`'s and `rq2`'s join tests, which read `cached("k")`. The first read
    % evicts it, so the ASSERT hands exactly one `remove_cache k expired`, as
    % libds's removal callback is called once from inside `ds_engine_assert`.
    % The pump after it has nothing left to remove. Drives
    % `session.assert_fact`'s `assert_step_duties` (`duty_of` over the
    % assert's effects). One binding's pin, not a ratification: the clause
    % binds the binding class.
    %
:- pred test_cache_read_expiry_duty(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_cache_read_expiry_duty(Program, !T, !IO) :-
    load(Program, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Trig", [text("w")], _, S0, S1),
        pump(P1, S1, S2),
        advance(duration_from_ns(10_000_000_000u64), _, S2, S3),
        assert_fact("Trig", [text("q")], A, S3, S4),
        pump(P2, S4, _),
        Written = list.map(duty_text, P1 ^ pumped_duties),
        check_saw("the first pump writes k, the control",
            ( if Written = ["write_cache k 7 ttl"] then yes else no ),
            string.string(Written), !T, !IO),
        Removed = list.map(duty_text, A ^ assert_step_duties),
        check_saw("[NSTG.2.4.2] the assert whose reads find k expired hands "
            ++ "the host exactly one remove_cache k expired",
            ( if Removed = ["remove_cache k expired"] then yes else no ),
            string.string(Removed), !T, !IO),
        After = list.map(duty_text, P2 ^ pumped_duties),
        check_saw("and the pump after it has nothing left to remove",
            ( if After = [] then yes else no ),
            string.string(After), !T, !IO)
    else
        check("cache_read_expiry.dsc loads", no, !T, !IO)
    ).

    % The index of the first report `P` holds of, counting from `I`.
    %
:- pred first_at(pred(report)::in(pred(in) is semidet), list(report)::in,
    int::in, int::out) is semidet.

first_at(P, [R | Rs], I, At) :-
    ( if P(R) then
        At = I
    else
        first_at(P, Rs, I + 1, At)
    ).

:- pred is_retract_report(report::in) is semidet.

is_retract_report(streamed(E)) :-
    E ^ integrator_event_kind = fact_retract(_).

:- pred is_expiry_report(string::in, report::in) is semidet.

is_expiry_report(Key, cache_expired(Key)).

:- pred is_fire_begin_report(string::in, report::in) is semidet.

is_fire_begin_report(Rule, streamed(E)) :-
    E ^ integrator_event_kind = rule_fire_begin(activation(Rule, _)).

%---------------------------------------------------------------------------%
% Services
%---------------------------------------------------------------------------%

:- pred test_services(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_services(Services, !T, !IO) :-
    load(Services, default_config, Loaded, _),
    ( if Loaded = ok(SL) then
        % The engine fills a `CallError`'s `ts` from the wall clock.
        set_wall_clock(wall_epoch, _, SL, S0),
        assert_fact("Ask", [text("hall")], _, S0, S1),

        % By hand: pump, answer, pump.
        pump(PA, S1, SA1),
        ( if PA ^ pumped_calls = [Call] then
            check("a pump hands the host the call, unanswered",
                ( if
                    call_text(Call) = "serve weather.forecast fc zone=hall",
                    not has_schema("ForecastReply", SA1)
                then yes else no ), !T, !IO),
            answer(Call, answered([text("hall"), int(35i64)]), AS, SA1, SA2),
            pump(PB, SA2, SA3),
            check_saw("an answer is asserted with the call's correlation, "
                ++ "and the next pump fires on it",
                ( if
                    AS ^ step_outcome = ok,
                    facts(SA2) = ok(SA2Facts),
                    list.member(V, SA2Facts),
                    V ^ fact_view_schema = "ForecastReply",
                    V ^ fact_view_slots =
                        [text("fc"), text("hall"), int(35i64)],
                    has_schema("Hot", SA3),
                    list.map(call_text, PB ^ pumped_calls) =
                        ["serve light.turn_on fan entity_id=light.fan"]
                then yes else no ),
                facts_text(SA3), !T, !IO)
        else
            check_saw("a pump of one Ask issues one call", no,
                string.string(PA ^ pumped_calls), !T, !IO)
        ),

        % [LSTR.8.5]: a response's or a CallError's ill-formed text is
        % refused as `encoding`: no fact enters, and no CallError stands in.
        % The control is the well-formed answer above. PATH PINNED:
        % `answer_call`, `lstr_8_5_refused`.
        ( if
            PA ^ pumped_calls = [IllCall],
            string.from_code_unit_list_allow_ill_formed([0xC0, 0xAF], Ill)
        then
            answer(IllCall, answered([text(Ill), int(35i64)]), IllA, SA1, SIA),
            answer(IllCall, call_error(Ill, "m"), IllE, SA1, SIE),
            check_saw("[LSTR.8.5] ill-formed text in an answer is refused as "
                ++ "encoding, and the session is unchanged",
                ( if
                    IllA ^ step_outcome = error(EIA),
                    error_status(EIA, encoding),
                    IllE ^ step_outcome = error(EIE),
                    error_status(EIE, encoding),
                    not has_schema("ForecastReply", SIA),
                    not has_schema("CallError", SIA),
                    not has_schema("CallError", SIE)
                then yes else no ),
                string.string(IllA ^ step_outcome) ++ "; "
                    ++ string.string(IllE ^ step_outcome), !T, !IO)
        else
            check("a pump of one Ask issues one call to refuse", no, !T, !IO)
        ),

        % Through the loop.
        pump_serving(test_serve, P, S1, S2, server(forecast(35)), H, !IO),
        check_saw("pump_serving answers each call, pumps, and serves the "
            ++ "calls an answer causes",
            ( if
                P ^ pumped_outcome = ok,
                served(H) = ["serve weather.forecast fc zone=hall",
                    "serve light.turn_on fan entity_id=light.fan"],
                has_schema("Hot", S2)
            then yes else no ),
            session_text(P ^ pumped_outcome, S2, served(H)), !T, !IO),
        check("a service declared no response asserts nothing when done",
            ( if not has_schema("CallError", S2) then yes else no ), !T, !IO),

        % Two calls with one correlation, both issued before either is
        % answered: both answers arrive, and the later replaces the earlier.
        assert_fact("Ask", [text("kitchen")], _, S1, S3),
        pump_serving(test_serve, _, S3, S4, server(forecast(20)), H3, !IO),
        Replies = list.filter(schema_is("ForecastReply"), got(facts(S4))),
        check_saw("each call with one correlation is answered, and the "
            ++ "answer asserted last is the one live",
            ( if
                list.filter(forecast_line, served(H3)) =
                    ["serve weather.forecast fc zone=hall",
                    "serve weather.forecast fc zone=kitchen"],
                Replies = [Reply],
                Reply ^ fact_view_slots =
                    [text("fc"), text("kitchen"), int(20i64)]
            then yes else no ),
            string.string(served(H3)) ++ "; " ++ facts_text(S4), !T, !IO)
    else
        check("services.dsc loads", no, !T, !IO)
    ).

:- pred test_service_failures(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_service_failures(Services, !T, !IO) :-
    load(Services, default_config, Loaded, _),
    ( if Loaded = ok(SL) then
        set_wall_clock(wall_epoch, _, SL, S0),
        assert_fact("Ask", [text("hall")], _, S0, S1),
        Answered =(pred(Mode::in, S::out, IO0::di, IO::uo) is det :-
            pump_serving(test_serve, _, S1, S, server(Mode), _, IO0, IO)),

        Answered(offer_nothing, SN, !IO),
        check_saw("a service the host does not offer is a "
            ++ "request.unsupported CallError",
            ( if failed_with(SN, "request.unsupported") then yes else no ),
            facts_text(SN), !T, !IO),
        Answered(fail_with("weather.down"), SF, !IO),
        check_saw("a service's own failure is a CallError with its code",
            ( if failed_with(SF, "weather.down") then yes else no ),
            facts_text(SF), !T, !IO),
        Answered(answer_everything, SA, !IO),
        check_saw("an answer from a service declared no response is an "
            ++ "internal.bug CallError",
            ( if failed_with(SA, "internal.bug") then yes else no ),
            facts_text(SA), !T, !IO),
        Answered(wrong_slots, SW, !IO),
        check_saw("an answer that does not fit the response schema is an "
            ++ "internal.bug CallError",
            ( if failed_with(SW, "internal.bug") then yes else no ),
            facts_text(SW), !T, !IO),

        % A mock clock's wall starts with no value, so there is no `ts` to
        % give a `CallError`.
        assert_fact("Ask", [text("hall")], _, SL, SU1),
        pump_serving(test_serve, PU, SU1, SU, server(offer_nothing), _, !IO),
        check_saw("with no wall clock no CallError is asserted, and the log "
            ++ "says why",
            ( if
                not has_schema("CallError", SU),
                list.member(logged(Line), PU ^ pumped_reports),
                Line ^ log_line_level = log_warning,
                Line ^ log_line_category = "services"
            then yes else no ),
            facts_text(SU), !T, !IO)
    else
        check("services.dsc loads for the failures", no, !T, !IO)
    ).

:- pred forecast_line(string::in) is semidet.

forecast_line(Line) :-
    string.prefix(Line, "serve weather.forecast").

    % A `Failed` fact with this code entered: the rule that reads every
    % `CallError` saw one. This and `has_schema` throw on a halted session
    % rather than fail, so `not has_schema(...)` cannot pass over one.
    %
:- pred failed_with(session::in, string::in) is semidet.

failed_with(S, Code) :-
    list.member(V, got(facts(S))),
    V ^ fact_view_schema = "Failed",
    V ^ fact_view_slots = [text(Code)].

:- pred has_schema(string::in, session::in) is semidet.

has_schema(Name, S) :-
    list.member(V, got(facts(S))),
    schema_is(Name, V).

:- pred schema_is(string::in, fact_view::in) is semidet.

schema_is(Name, V) :-
    V ^ fact_view_schema = Name.

%---------------------------------------------------------------------------%
% The clock
%---------------------------------------------------------------------------%

:- pred test_clock(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_clock(Verbs, !T, !IO) :-
    load(Verbs, default_config, LoadedM, _),
    ( if LoadedM = ok(M0) then
        set_clock(from_ns(500u64), Set, M0, M1),
        check("set_clock moves a mock clock",
            ( if
                Set ^ step_outcome = ok,
                now(M1) = ok(from_ns(500u64))
            then yes else no ), !T, !IO),
        % [NTST.3.1]: once the engine has sampled, a set below the
        % current value is refused as `state`, and the clock stays.
        pump(_, M1, M2),
        set_clock(from_ns(100u64), Back, M2, M3),
        check("set_clock going backward after a sample is refused as state",
            ( if
                Back ^ step_outcome = error(BackErr),
                error_status(BackErr, state),
                now(M3) = ok(from_ns(500u64))
            then yes else no ), !T, !IO),
        set_clock(from_ns(500u64), Same, M3, M4),
        set_clock(from_ns(900u64), Forward, M4, M5),
        check("set_clock to the current value or forward still moves it",
            ( if
                Same ^ step_outcome = ok,
                Forward ^ step_outcome = ok,
                now(M5) = ok(from_ns(900u64))
            then yes else no ), !T, !IO),
        % @spec [NTST.3.1]
        % PATH PINNED: `advance` -> `ds.engine.engine_advance_past_range`.
        set_wall_clock(int64.max_int64, _, M5, M6),
        advance(duration_from_ns(1u64), Past, M6, M7),
        check("an advance past the wall clock's range is refused as "
            ++ "time_range, and the clock stays",
            ( if
                Past ^ step_outcome = error(PastErr),
                error_status(PastErr, time_range),
                Past ^ step_reports = [],
                now(M7) = ok(from_ns(900u64))
            then yes else no ), !T, !IO)
    else
        check("verbs.dsc loads with a mock clock", no, !T, !IO)
    ),
    load(Verbs, default_config ^ session_config_clock := live_clock, LoadedL,
        _),
    ( if LoadedL = ok(S0) then
        advance(duration_from_ns(1u64), Adv, S0, _),
        check("advance on a live clock is refused as state",
            ( if
                Adv ^ step_outcome = error(Err),
                error_status(Err, state)
            then yes else no ), !T, !IO),
        % @spec [NTST.3.1]
        % PATH PINNED: `session.set_wall_clock`'s live arm, as
        % `ds_clock_wall_set` refuses it.
        set_wall_clock(wall_epoch, WallLive, S0, _),
        check("set_wall_clock on a live clock is refused as state",
            ( if
                WallLive = error(WallErr),
                error_status(WallErr, state)
            then yes else no ), !T, !IO),
        read_clock(S0, R0, !IO),
        % [RFCS.10.5]: a replay's recorded samples put the engine on
        % the mock clock, so the session is on it: `clock_mode` says so, and
        % `advance` moves it. PATH PINNED: `session.replayed`.
        load(Verbs, default_config, LoadedW, _),
        ( if
            LoadedW = ok(W0),
            start_recording(W0, W1),
            assert_fact("Trig", [int(1i64)], _, W1, W2),
            recording(W2) = yes(Made)
        then
            check("before a replay, a live session's clock_mode is live_clock",
                ( if clock_mode(S0) = ok(live_clock) then yes else no ),
                !T, !IO),
            replay(Made ^ recording_bytes, _, S0, Played),
            advance(duration_from_ns(1u64), Moved, Played, _),
            check_saw("after a replay, a live session is on the mock clock",
                ( if
                    clock_mode(Played) = ok(mock_clock),
                    Moved ^ step_outcome = ok
                then yes else no ),
                string.string(clock_mode(Played)) ++ "; "
                    ++ string.string(Moved ^ step_outcome), !T, !IO)
        else
            check("verbs.dsc records an assert", no, !T, !IO)
        ),
        % No check that a TTL expires by wall time: there is no per-fact
        % override, and `Alert`'s own TTL is an hour.
        assert_fact("Alert", [int(3i64), text("hall")], _, R0, S1),
        check("a live session's first reading anchors its clock at 0",
            ( if now(S1) = ok(from_ns(0u64)) then yes else no ), !T, !IO),
        pump(_, S1, Unread),
        check_saw("a live clock does not move between readings",
            ( if now(Unread) = ok(At), now(S1) = ok(At) then yes else no ),
            string.string(now(Unread)), !T, !IO),
        read_clock(S1, R1, !IO),
        pump(_, R1, S2),
        check("wall time moves a live session's clock at each reading",
            ( if now(S2) = ok(At2), before(from_ns(0u64), At2) then yes
              else no ), !T, !IO)
    else
        check("verbs.dsc loads with a live clock", no, !T, !IO)
    ).

%---------------------------------------------------------------------------%
% The cache seed
%---------------------------------------------------------------------------%

:- pred test_cache_seed(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_cache_seed(Verbs, !T, !IO) :-
    V = j_object(object(["on" - j_bool(yes)])),
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        cache_seed("restored", V, no, O1, S0, S1),
        cache_seed("expiring", V, yes(duration_from_ns(5_000_000_000u64)),
            O2, S1, S2),
        check("a seed before the first pump is taken",
            ( if O1 = ok, O2 = ok then yes else no ), !T, !IO),
        cache_seed("zero", V, yes(duration_from_ns(0u64)), OZ, S2, _),
        check("a seed with a zero TTL is refused as inval",
            ( if OZ = error(EZ), error_status(EZ, inval) then yes else no ),
            !T, !IO),
        pump(_, S2, S3),
        cache_seed("late", V, no, OL, S3, _),
        check("a seed after the first pump is refused as state",
            ( if OL = error(EL), error_status(EL, state) then yes else no ),
            !T, !IO),

        One = j_int(1i64),
        set_cache_cap(1, 0, Capped, S0, C0),
        cache_seed("one", One, no, C1, C0, CS1),
        cache_seed("two", One, no, C2, CS1, CS2),
        cache_seed("one", One, no, C3, CS2, _),
        check("a seed past the cache cap is refused as contract_breach",
            ( if
                Capped = ok,
                C1 = ok,
                C2 = error(E2),
                error_status(E2, contract_breach)
            then yes else no ), !T, !IO),
        check("a seed of a key already held replaces it within the cap",
            ( if C3 = ok then yes else no ), !T, !IO),
        % `warm_cache`'s write of a second key breaches the same cap,
        % and the pump returns it, as libds's does.
        assert_fact("Warm", [int(1i64)], _, CS2, W1),
        pump(WarmPump, W1, _),
        check("a rule's cache write past the cache cap makes the pump "
                ++ "contract_breach",
            ( if
                WarmPump = pumped(error(EW), _, _, _),
                error_status(EW, contract_breach)
            then yes else no ), !T, !IO),

        set_cache_cap(-1, 0, NegKeys, S0, _),
        set_cache_cap(0, -1, NegBytes, S0, _),
        set_cache_cap(4_294_967_296, 0, TooMany, S0, _),
        set_fire_budget(fire_budget(-1), NegFires, S0, _),
        check_saw("a negative bound or budget, or a key bound past 32 bits, "
            ++ "is refused as inval",
            ( if
                list.all_true(refused_inval,
                    [NegKeys, NegBytes, TooMany, NegFires])
            then yes else no ),
            string.string([NegKeys, NegBytes, TooMany, NegFires]), !T, !IO),
        load(Verbs, default_config ^ session_config_budget := fire_budget(-1),
            NegLoad, _),
        check_saw("a configuration with a negative firing limit refuses the "
            ++ "load as inval",
            ( if
                NegLoad = error(EB),
                error_status(EB, inval)
            then yes else no ), load_text(NegLoad), !T, !IO)
    else
        check("verbs.dsc loads for the seed", no, !T, !IO)
    ).

:- pred refused_inval(outcome::in) is semidet.

refused_inval(error(E)) :-
    error_status(E, inval).

%---------------------------------------------------------------------------%
% Copies
%---------------------------------------------------------------------------%

:- pred test_copy(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_copy(Verbs, !T, !IO) :-
    load(Verbs, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        set_clock(from_ns(500u64), _, S0, S1),
        assert_fact("Trig", [int(1i64)], A, S1, S2),
        assert_fact("Trig", [int(2i64)], _, S2, S3),
        Copy = S3,
        check("a copy has the same facts, ids and clock",
            ( if
                fact_count(Copy) = ok(2),
                A ^ assert_step_outcome = asserted(Id),
                search_fact(Copy, Id, ok(_)),
                now(Copy) = ok(from_ns(500u64))
            then yes else no ), !T, !IO),
        ( if A ^ assert_step_outcome = asserted(Id1) then
            retract_fact(Id1, _, Copy, Copy1),
            check("a retract on a copy leaves the original alone",
                ( if
                    not search_fact(Copy1, Id1, _),
                    search_fact(S3, Id1, ok(_))
                then yes else no ), !T, !IO),
            assert_fact("Trig", [int(3i64)], NS, S3, _),
            assert_fact("Trig", [int(3i64)], NC, Copy1, _),
            check("each side's fact ids continue from the copy",
                ( if
                    NS ^ assert_step_outcome = asserted(Next),
                    NC ^ assert_step_outcome = asserted(Next)
                then yes else no ), !T, !IO)
        else
            check("the copied session's first fact is asserted", no, !T,
                !IO)
        )
    else
        check("verbs.dsc loads for the copy", no, !T, !IO)
    ).

%---------------------------------------------------------------------------%
% Introspection
%---------------------------------------------------------------------------%

:- pred test_introspect(bitmap::in, bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_introspect(Verbs, Series, !T, !IO) :-
    load(Verbs, default_config, LoadedV, _),
    ( if LoadedV = ok(S0) then
        assert_fact("Trig", [int(1i64)], A, S0, S1),
        check("the rules are listed by name, with no cooldown",
            ( if
                rules(S1) = ok(Rules),
                list.map((func(R) = R ^ rule_info_name), Rules) =
                    ["fire_them_all", "warm_cache"],
                list.all_true(no_cooldown, Rules)
            then yes else no ), !T, !IO),
        check("a rule is found by name, and a stranger is not",
            ( if
                search_rule(S1, "fire_them_all", ok(_)),
                not search_rule(S1, "nope", _)
            then yes else no ), !T, !IO),
        ( if
            A ^ assert_step_outcome = asserted(LookedUp),
            search_fact(S1, LookedUp, FactView),
            search_schema(S1, "Trig", TrigSchema),
            search_rule(S1, "fire_them_all", RuleInfo),
            line_spans(S1) = ok([FirstSpan | _]),
            search_line_span(S1, FirstSpan ^ ls_node, SpanFound),
            search_source_file(S1, FirstSpan ^ ls_clip, FileFound)
        then
            check("each lookup_ answers what its search_ finds",
                ( if
                    lookup_fact(S1, LookedUp) = FactView,
                    lookup_schema(S1, "Trig") = TrigSchema,
                    lookup_rule(S1, "fire_them_all") = RuleInfo,
                    lookup_line_span(S1, FirstSpan ^ ls_node) = SpanFound,
                    lookup_source_file(S1, FirstSpan ^ ls_clip) = FileFound
                then yes else no ), !T, !IO)
        else
            check("verbs.dsc has a fact, schema, rule, span and source to "
                ++ "look up", no, !T, !IO)
        ),
        check("a rule says where it is declared",
            ( if
                search_rule(S1, "fire_them_all", ok(Info)),
                Info ^ rule_info_source = yes(source_loc(yes(File), Line, _)),
                string.suffix(File, "verbs.ds"),
                Line > 0
            then yes else no ), !T, !IO),
        ( if sources(S1) = ok([Src]) then
            check("the program's source is one module, with its text",
                ( if
                    string.suffix(Src ^ src_file, "verbs.ds"),
                    string.sub_string_search(Src ^ src_text,
                        "rule fire_them_all", _)
                then yes else no ), !T, !IO),
            Spans = got(line_spans(S1)),
            check("every span is in that module, from 1, and found by its "
                ++ "node",
                ( if
                    Spans = [_ | _],
                    list.all_true(
                        ( pred(Sp::in) is semidet :-
                            Sp ^ ls_clip = Src ^ src_clip,
                            Sp ^ ls_line >= 1u32,
                            Sp ^ ls_col >= 1u32,
                            search_line_span(S1, Sp ^ ls_node, ok(Found)),
                            Found ^ ls_line = Sp ^ ls_line
                        ), Spans)
                then yes else no ), !T, !IO)
        else
            check("the program's source is one module", no, !T, !IO)
        ),
        check("a fact the host asserted has no justifiers",
            ( if
                A ^ assert_step_outcome = asserted(Id),
                justifiers(S1, Id) = ok([])
            then yes else no ), !T, !IO),
        check("the artefact header carries this runtime's DS version series",
            ( if
                artefact_header(S1) = ok(Header1),
                string.prefix(Header1 ^ dh_compiler_version,
                    ds_version_series)
            then yes else no ), !T, !IO)
    else
        check("verbs.dsc loads for introspection", no, !T, !IO)
    ),

    % No public function reads a series ([NSBK.6.3]): the fixture's
    % rule reads one, and what it does is what the host sees.
    load(Series, default_config, LoadedS, _),
    ( if LoadedS = ok(P0) then
        sample_kitchen(1u64, 20.0, First, P0, P1),
        sample_kitchen(2u64, 21.0, Second, P1, _),
        check("a series is read by its rule: fire-then-sample ([LSER.8.6]) "
            ++ "reads a cold count first, and the supersede fires",
            ( if not logs_x(First), logs_x(Second) then yes else no ),
            !T, !IO),
        Duties = First ^ pumped_duties ++ Second ^ pumped_duties,
        check_saw("a series hands the host no duty",
            ( if Duties = [] then yes else no ),
            string.string(list.map(duty_text, Duties)), !T, !IO)
    else
        check("series.dsc loads", no, !T, !IO)
    ).

:- pred no_cooldown(rule_info::in) is semidet.

no_cooldown(R) :-
    R ^ rule_info_cooldown = no.

%---------------------------------------------------------------------------%
% The halt
%---------------------------------------------------------------------------%

    % @spec [NCBK.2.9]
    % A HALTED SESSION'S READS ANSWER `halted`, `mercury_ds.session`'s and
    % `mercury_ds.introspect`'s alike, and `halted` and `session_header`
    % still answer. The halt comes
    % from `verbs_short_call`, a negative fixture check.py builds from
    % `verbs` on every run with `dsc_seal.drop_call_operand`: the `log` that
    % opens `fire_them_all` has lost its last operand. The artefact loads, and
    % the action raises ARTEFACT_LIED when it runs ([RDSC.4a.9.3]). The same
    % steps and reads on `verbs`, whose session never halts, answer `ok`, so
    % a read that answered `halted` whatever the latch fails there. Drives
    % `session.reading`, `search_fact` and `search_schema`'s latch checks. One
    % binding's pin, not a ratification: the clause binds the binding class.
    %
:- pred test_halted_reads(bitmap::in, bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_halted_reads(Verbs, ShortCall, !T, !IO) :-
    load(ShortCall, default_config, LoadedH, _),
    load(Verbs, default_config, LoadedV, _),
    ( if
        LoadedH = ok(H0),
        LoadedV = ok(V0),
        lookup_schema(H0, "Trig") = ok(TrigH),
        lookup_schema(V0, "Trig") = ok(TrigV)
    then
        assert_fact("Trig", [int(1i64)], AH, H0, H1),
        assert_fact("Trig", [int(1i64)], AV, V0, V1),
        pump(PH, H1, H),
        pump(PV, V1, V),
        check_saw("[NCBK.2.9] the pump that raises the EngineError reports "
            ++ "the halt, and the latch holds ARTEFACT_LIED",
            ( if
                PH ^ pumped_outcome = error(EH),
                error_status(EH, engine_halted),
                halted(H) = yes(ds.fault.ee_expr_fault(
                    ds.fault.rf_artefact_lied))
            then yes else no ),
            string.string(PH ^ pumped_outcome) ++ "; "
                ++ string.string(halted(H)), !T, !IO),
        check_saw("[NCBK.2.9] the same pump on the session that does not "
            ++ "halt succeeds",
            ( if PV ^ pumped_outcome = ok, halted(V) = no then yes else no ),
            string.string(PV ^ pumped_outcome), !T, !IO),
        % [NCBK.2.9]: a configuration setter on a halted session is
        % refused and changes nothing; the same call on the session that did
        % not halt is the control. PATH PINNED: `refused_call` in each setter.
        set_cache_cap(1, 0, CapH, H, _),
        set_fire_budget(fire_budget(1), BudgetH, H, _),
        set_cache_cap(-1, 0, NegH, H, _),
        set_wall_clock(wall_epoch, WallH, H, _),
        check_saw("[NCBK.2.9] set_cache_cap, set_fire_budget and "
            ++ "set_wall_clock on a halted session answer engine_halted, "
            ++ "ahead of their value checks",
            ( if
                CapH = error(ECap),
                error_status(ECap, engine_halted),
                BudgetH = error(EBudget),
                error_status(EBudget, engine_halted),
                NegH = error(ENeg),
                error_status(ENeg, engine_halted),
                WallH = error(EWall),
                error_status(EWall, engine_halted)
            then yes else no ),
            string.string({CapH, BudgetH, NegH, WallH}), !T, !IO),
        set_cache_cap(1, 0, CapV, V, _),
        set_fire_budget(fire_budget(1), BudgetV, V, _),
        set_wall_clock(wall_epoch, WallV, V, _),
        check("[NCBK.2.9] the same setters on the session that did not halt "
            ++ "answer ok",
            ( if CapV = ok, BudgetV = ok, WallV = ok then yes else no ),
            !T, !IO),
        % [RFCS.6.7]: replaying a halted run reaches the recording's end,
        % leaves the session halted by the same fault, and answers `ok`, as
        % libds's replay does.
        start_recording(H0, HR0),
        assert_fact("Trig", [int(1i64)], _, HR0, HR1),
        pump(_, HR1, HR2),
        ( if recording(HR2) = yes(HRec) then
            replay(HRec ^ recording_bytes, Again, H0, HA),
            check_saw("[RFCS.6.7] a replay that reproduces a halt answers ok, "
                ++ "and the latch holds the same fault",
                ( if
                    Again ^ step_outcome = ok,
                    halted(HA) = halted(H)
                then yes else no ),
                string.string(Again ^ step_outcome) ++ "; "
                    ++ string.string(halted(HA)), !T, !IO),
            replay(HRec ^ recording_bytes, Twice, HA, _),
            check("[NCBK.2.9] a replay into a session already halted is "
                ++ "refused",
                ( if
                    Twice ^ step_outcome = error(ETwice),
                    error_status(ETwice, engine_halted)
                then yes else no ), !T, !IO)
        else
            check("verbs_short_call.dsc records its run", no, !T, !IO)
        ),
        ( if
            AH ^ assert_step_outcome = asserted(IdH),
            AV ^ assert_step_outcome = asserted(IdV)
        then
            check("[NCBK.2.9] fact_count, lookup_fact and lookup_schema "
                ++ "answer halted after the halt",
                ( if
                    fact_count(H) = halted(_),
                    lookup_fact(H, IdH) = halted(_),
                    lookup_schema(H, "Trig") = halted(_)
                then yes else no ), !T, !IO),
            check("[NCBK.2.9] every other read answers halted after the "
                ++ "halt, whatever its key",
                ( if
                    schema_names(H) = halted(_),
                    facts(H) = halted(_),
                    search_fact(H, IdH, halted(_)),
                    now(H) = halted(_),
                    clock_mode(H) = halted(_),
                    memory_usage(H) = halted(_),
                    run_id(H) = halted(_),
                    tier_id(H) = halted(_),
                    search_schema(H, "Trig", halted(_)),
                    search_schema(H, "Nope", halted(_)),
                    slot_names(H, TrigH) = halted(_)
                then yes else no ), !T, !IO),
            check("[NCBK.2.9] an engine-state read and a program read "
                ++ "answer halted after the halt",
                ( if
                    match_trace(H, IdH) = halted(_),
                    rules(H) = halted(_)
                then yes else no ), !T, !IO),
            check("[NCBK.2.9] every other introspection read answers halted "
                ++ "after the halt, whatever its key",
                ( if
                    justifiers(H, IdH) = halted(_),
                    refracted_activations(H, no) = halted(_),
                    search_rule(H, "fire_them_all", halted(_)),
                    search_rule(H, "nope", halted(_)),
                    services(H) = halted(_),
                    sources(H) = halted(_),
                    line_spans(H) = halted(_),
                    search_line_span(H, 0u32, halted(_)),
                    search_source_file(H, 0u32, halted(_)),
                    search_schema_source(H, "Trig", halted(_)),
                    artefact_header(H) = halted(_)
                then yes else no ), !T, !IO),
            check("[NCBK.2.9] session_header answers after the halt, as it "
                ++ "did before",
                ( if session_header(H) = session_header(H0) then yes
                  else no ), !T, !IO),
            check("[NCBK.2.9] the same reads on the session that did not "
                ++ "halt answer ok",
                ( if
                    fact_count(V) = ok(_),
                    lookup_fact(V, IdV) = ok(_),
                    lookup_schema(V, "Trig") = ok(_),
                    schema_names(V) = ok(_),
                    facts(V) = ok(_),
                    search_fact(V, IdV, ok(_)),
                    now(V) = ok(_),
                    clock_mode(V) = ok(_),
                    memory_usage(V) = ok(_),
                    run_id(V) = ok(_),
                    tier_id(V) = ok(_),
                    search_schema(V, "Trig", ok(_)),
                    not search_schema(V, "Nope", _),
                    slot_names(V, TrigV) = ok(_),
                    match_trace(V, IdV) = ok(_),
                    rules(V) = ok(_),
                    justifiers(V, IdV) = ok(_),
                    refracted_activations(V, no) = ok(_),
                    search_rule(V, "fire_them_all", ok(_)),
                    not search_rule(V, "nope", _),
                    services(V) = ok(_),
                    sources(V) = ok(_),
                    line_spans(V) = ok(_),
                    artefact_header(V) = ok(_)
                then yes else no ), !T, !IO),
            test_text_before_state(H, V, !T, !IO)
        else
            check("[NCBK.2.9] both sessions assert their Trig", no, !T, !IO)
        )
    else
        check("verbs.dsc and verbs_short_call.dsc load", no, !T, !IO)
    ).

    % @spec [NLFC.9.6]
    % [LSTR.8.5]: a seed given as JSON text is judged as text
    % -- its limit, its encoding, its parse -- before the engine's state, a
    % halted session and a closed seeding window included. This binding takes
    % the text apart from the session: `json_from_text` reads it, with no
    % session to ask, and `cache_seed` takes the value it gives. So a host's
    % seed from text is the two in that order, and a refusal of the text is
    % returned before any session is reached. Held here on `H`, halted, and
    % `V`, past its first stream event: each control, valid text, answers the
    % session's state; each case, the same session with the text broken,
    % answers the text. A `Json` slot is taken as a `json_term`, never as text,
    % so [NFCT.2.11]'s sentence has nothing more to reach here.
    %
:- pred test_text_before_state(session::in, session::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_text_before_state(H, V, !T, !IO) :-
    Over = "0" ++ string.duplicate_char(' ', ds.json.max_text_bytes),
    ( if
        string.from_code_unit_list_allow_ill_formed([0x22, 0xc0, 0xaf, 0x22],
            Ill),
        string.from_code_unit_list_allow_ill_formed([0x7b, 0xc0, 0xaf],
            IllMalformed)
    then
        Cases = [
            {"malformed text", "{not json", parse},
            {"ill-formed text", Ill, encoding},
            {"text over the limit", Over, json_limit},
            {"text over the limit and ill-formed",
                Ill ++ string.duplicate_char(' ', ds.json.max_text_bytes),
                json_limit},
            {"text ill-formed and malformed", IllMalformed, encoding}
        ],
        check("[NLFC.9.6] on a halted session, valid text reaches the session "
                ++ "and answers engine_halted (the control)",
            seed_from_text_is(H, "1", engine_halted), !T, !IO),
        list.foldl2(
            ( pred({Label, Text, Want}::in, T0::in, T1::out,
                    IO0::di, IO1::uo) is det :-
                check("[NLFC.9.6] on a halted session, " ++ Label
                        ++ " is refused for the text",
                    seed_from_text_is(H, Text, Want), T0, T1, IO0, IO1)
            ), Cases, !T, !IO),
        check("[NLFC.9.6] past the first stream event, valid text answers "
                ++ "state (the control)",
            seed_from_text_is(V, "1", state), !T, !IO),
        check("[NLFC.9.6] past the first stream event, malformed text is "
                ++ "refused for the text",
            seed_from_text_is(V, "{not json", parse), !T, !IO)
    else
        check("[NLFC.9.6] the ill-formed texts make Mercury strings", no,
            !T, !IO)
    ).

    % A host's seed from text, as this binding takes it: the text read, then
    % the value seeded. `yes` when the first refusal is `Want`.
    %
:- func seed_from_text_is(session, string, status) = bool.

seed_from_text_is(S, Text, Want) = Ok :-
    Parsed = json_from_text(Text),
    (
        Parsed = error(E),
        Ok = ( if error_status(E, Want) then yes else no )
    ;
        Parsed = ok(Value),
        cache_seed("k", Value, no, Outcome, S, _),
        Ok = ( if Outcome = error(E), error_status(E, Want) then yes
               else no )
    ).

    % Assert a kitchen reading at an instant and pump.
    %
:- pred sample_kitchen(uint64::in, float::in, pumped::out,
    session::in, session::out) is det.

sample_kitchen(Ns, V, P, !S) :-
    set_clock(from_ns(Ns), _, !S),
    assert_fact("Sensor", [text("kitchen"), float(V)], _, !S),
    pump(P, !S).

    % Whether a pump logged the fixture rule's "x".
    %
:- pred logs_x(pumped::in) is semidet.

logs_x(P) :-
    list.any_true(is_x_log, P ^ pumped_reports).

:- pred is_x_log(report::in) is semidet.

is_x_log(logged(L)) :-
    L ^ log_line_message = "x".

%---------------------------------------------------------------------------%
% Time zones
%---------------------------------------------------------------------------%

:- pred test_local_tz(bitmap::in, tally::in, tally::out, io::di, io::uo)
    is det.

test_local_tz(Bytes, !T, !IO) :-
    % [LTIM.10.6]-[LTIM.10.7]: a zone resolves through the
    % `TimeZoneOffset` rows the host asserts, over every instant here.
    LA = [{"America/Los_Angeles", int64.min_int64, int64.max_int64,
        -25200i64}],
    Elsewhere = [{"Europe/Paris", int64.min_int64, int64.max_int64, 3600i64}],
    % A dropped rule would pass the two refusals below for the wrong reason.
    load(Bytes, default_config, LoadedR, _),
    check("local_tz.dsc loads with its rule",
        ( if LoadedR = ok(R), search_rule(R, "zone_it", ok(_)) then yes
          else no ), !T, !IO),
    ping_seen(Bytes, LA, OkLA, SeenLA),
    check_saw("local() resolves through the session's TimeZoneOffset rows",
        ( if OkLA = yes, SeenLA = yes then yes else no ),
        string.format("ok %s, seen %s",
            [s(string.string(OkLA)), s(string.string(SeenLA))]), !T, !IO),
    ping_seen(Bytes, Elsewhere, _, SeenNo),
    check("a zone no row answers faults, and nothing enters",
        ( if SeenNo = no then yes else no ), !T, !IO),
    ping_seen(Bytes, [], _, SeenNone),
    check("with no rows local() faults, and nothing enters",
        ( if SeenNone = no then yes else no ), !T, !IO),
    % [LTIM.10.9]: a malformed row is refused with `inval`, its words libds's.
    load(Bytes, default_config, LoadedBad, _),
    ( if LoadedBad = ok(SB) then
        assert_fact("TimeZoneOffset", [text("UTC"), int(0i64), int(1i64),
            int(0i64)], Bad, SB, _),
        check("[LTIM.10.9] a TimeZoneOffset row for \"UTC\" is refused, inval",
            ( if
                Bad ^ assert_step_outcome = error(Err),
                error_status(Err, inval)
            then yes else no ), !T, !IO)
    else
        check("local_tz.dsc loads for the refusal", no, !T, !IO)
    ).

    % Load local_tz.dsc, assert these `TimeZoneOffset` rows -- (zone,
    % valid_from, valid_until, offset_s) -- and a Ping, and pump: whether the
    % pump's outcome was ok, and whether a Seen entered. The wall clock is
    % set, because `now()` reads it.
    %
:- pred ping_seen(bitmap::in, list({string, int64, int64, int64})::in,
    bool::out, bool::out) is det.

ping_seen(Bytes, Rows, Ok, Seen) :-
    load(Bytes, default_config, Loaded, _),
    ( if Loaded = ok(SL) then
        set_wall_clock(wall_epoch, _, SL, SW),
        list.foldl(
            ( pred({Zone, From, Until, Off}::in, Si::in, So::out) is det :-
                assert_fact("TimeZoneOffset", [text(Zone), int(From),
                    int(Until), int(Off)], _, Si, So) ),
            Rows, SW, S0),
        assert_fact("Ping", [int(1i64)], _, S0, S1),
        pump(P, S1, S2),
        Ok = ( if P ^ pumped_outcome = ok then yes else no ),
        Seen = ( if has_schema("Seen", S2) then yes else no )
    else
        Ok = no,
        Seen = no
    ).

%---------------------------------------------------------------------------%
% A fault's payload
%---------------------------------------------------------------------------%

:- pred test_fault_payload(bitmap::in, tally::in, tally::out,
    io::di, io::uo) is det.

test_fault_payload(Bytes, !T, !IO) :-
    load(Bytes, default_config, Loaded, _),
    ( if Loaded = ok(S0) then
        assert_fact("Reading", [int(1i64), int(0i64)], A, S0, S1),
        pump(P, S1, S2),
        ( if
            list.find_first_map(divide_by_zero_fault,
                events(P ^ pumped_reports), Info)
        then
            check("a rule-body fault names its rule and its firing",
                ( if
                    Info ^ fault_info_rule = "divide",
                    Info ^ fault_info_activation = yes(activation("divide", _))
                then yes else no ), !T, !IO),
            check("...its node, which a span maps to the rule's line",
                ( if
                    Info ^ fault_info_node = yes(Node),
                    search_line_span(S2, node_id_value(Node), ok(Span)),
                    Span ^ ls_line >= 15u32
                then yes else no ), !T, !IO),
            check("...and the fact, schema and slot it was raised over, and "
                ++ "the value's tag",
                ( if
                    A ^ assert_step_outcome = asserted(Id),
                    Info ^ fault_info_fact = yes(Id),
                    Info ^ fault_info_schema = yes("Reading"),
                    Info ^ fault_info_slot = yes("divisor"),
                    Info ^ fault_info_actual = yes("Int")
                then yes else no ), !T, !IO)
        else
            check("100 / 0 in a rule body is a divide_by_zero "
                ++ "computation_error", no, !T, !IO)
        )
    else
        check("div_zero.dsc loads", no, !T, !IO)
    ).

    % Where a divide-by-zero computation error was raised. Fail for any
    % other event.
    %
:- pred divide_by_zero_fault(integrator_event::in, fault_info::out)
    is semidet.

divide_by_zero_fault(Ev, Info) :-
    Ev ^ integrator_event_kind = computation_error(divide_by_zero, Info).

%---------------------------------------------------------------------------%
% What 1.0.0 defers
%---------------------------------------------------------------------------%

:- pred test_deferred(tally::in, tally::out, io::di, io::uo) is det.

test_deferred(!T, !IO) :-
    skip("a realtime artefact binds its contract",
        "realtime is not in 1.0.0: no v1 source compiles to a contract",
        !T, !IO).

%---------------------------------------------------------------------------%
% Pieces
%---------------------------------------------------------------------------%

:- func events(list(report)) = list(integrator_event).

events(Reports) = list.filter_map(streamed_event, Reports).

:- func streamed_event(report) = integrator_event is semidet.

streamed_event(streamed(E)) = E.

    % The clock of the first stream event that asserts a `Trig` holding
    % this value. Fail if none does.
    %
:- pred trig_assert_clock(list(report)::in, int64::in, instant::out)
    is semidet.

trig_assert_clock(Reports, Value, Clock) :-
    list.find_first_match(asserts_trig(Value), events(Reports), Event),
    Clock = Event ^ integrator_event_clock.

    % The `seq` of the first stream event that asserts a `Trig` holding
    % this value. Fail if none does.
    %
:- pred trig_assert_seq(list(report)::in, int64::in, seq::out) is semidet.

trig_assert_seq(Reports, Value, Seq) :-
    list.find_first_match(asserts_trig(Value), events(Reports), Event),
    Seq = Event ^ integrator_event_seq.

:- pred asserts_trig(int64::in, integrator_event::in) is semidet.

asserts_trig(Value, Event) :-
    Event ^ integrator_event_kind = fact_assert(_, "Trig", [int(Value)]).

    % The `seq` of the first recorded event that asserts a fact holding
    % only this value, as a `Trig` does. Fail if none does.
    %
:- pred recorded_trig_seq(list({seq, stream_event})::in, int64::in, seq::out)
    is semidet.

recorded_trig_seq(Events, Value, Seq) :-
    list.find_first_match(recorded_trig(Value), Events, {Seq, _}).

:- pred recorded_trig(int64::in, {seq, stream_event}::in) is semidet.

recorded_trig(Value, {_, se_fact_assert(_, _, [int(Value)], _)}).

:- func event_seq(integrator_event) = int.

event_seq(E) = uint64.cast_to_int(seq_value(E ^ integrator_event_seq)).

    % A firing event's short name, for the order checks.
    %
:- func kind_name(integrator_event) = string.

kind_name(E) = Name :-
    K = E ^ integrator_event_kind,
    (
        K = rule_fire_begin(_),
        Name = "begin"
    ;
        K = rule_fire_end(_),
        Name = "end"
    ;
        K = action_log(_),
        Name = "log"
    ;
        K = action_emit(_, _),
        Name = "emit"
    ;
        K = action_publish(_, _, _),
        Name = "publish"
    ;
        K = action_call(_),
        Name = "call"
    ;
        K = action_cache_set(_),
        Name = "cache_set"
    ;
        K = action_cache_delete(_),
        Name = "cache_delete"
    ;
        ( K = fact_assert(_, _, _)
        ; K = fact_retract(_)
        ; K = rule_lhs_facts(_, _)
        ; K = tick(_)
        ; K = timer_armed(_, _, _)
        ; K = type_error(_)
        ; K = computation_error(_, _)
        ; K = bounds_error(_, _)
        ; K = engine_error(_, _)
        ; K = pump
        ),
        Name = "other"
    ).

:- func bytes_bitmap(string) = bitmap.

bytes_bitmap(S) = fill(Codes, 0, bitmap.init(list.length(Codes) * 8)) :-
    string.to_utf8_code_unit_list(S, Codes).

:- func fill(list(int), int, bitmap) = bitmap.
:- mode fill(in, in, bitmap_di) = bitmap_uo is det.

fill([], _, BM) = BM.
fill([C | Cs], I, BM0) = fill(Cs, I + 1, BM0 ^ byte(I) := C).

:- pred read_bytes(string::in, maybe(bitmap)::out, io::di, io::uo) is det.

read_bytes(Path, Result, !IO) :-
    io.open_binary_input(Path, OpenRes, !IO),
    (
        OpenRes = ok(Stream),
        io.read_binary_file_as_bitmap(Stream, ReadRes, !IO),
        io.close_binary_input(Stream, !IO),
        ( if ReadRes = ok(BM) then Result = yes(BM) else Result = no )
    ;
        OpenRes = error(_),
        Result = no
    ).

:- pred check(string::in, bool::in, tally::in, tally::out, io::di, io::uo)
    is det.

check(Name, Ok, !T, !IO) :-
    (
        Ok = yes,
        io.format("PASS %s\n", [s(Name)], !IO),
        !T ^ tl_passed := !.T ^ tl_passed + 1
    ;
        Ok = no,
        io.format("FAIL %s\n", [s(Name)], !IO),
        !T ^ tl_failed := !.T ^ tl_failed + 1
    ).

    % A check that says, when it fails, what it saw.
    %
:- pred check_saw(string::in, bool::in, string::in, tally::in, tally::out,
    io::di, io::uo) is det.

check_saw(Name, Ok, Saw, !T, !IO) :-
    check(Name, Ok, !T, !IO),
    (
        Ok = no,
        io.format("    saw: %s\n", [s(Saw)], !IO)
    ;
        Ok = yes
    ).

    % A wall clock reading for the tests that need one: 2023-11-14T22:13:20Z.
    %
:- func wall_epoch = int64.

wall_epoch = 1_700_000_000_000_000_000i64.

:- func facts_text(session) = string.

facts_text(S) = Text :-
    Read = facts(S),
    (
        Read = ok(Views),
        Text = string.join_list("; ", list.map(view_text, Views))
    ;
        Read = halted(Error),
        Text = "halted: " ++ string.string(Error)
    ).

    % A read's value, for a test whose session never halts. A read that
    % answers `halted` ([NCBK.2.9]) is the test's own bug, so it throws
    % rather than fail: a failing read inside a `not` would pass.
    %
:- func got(read(T)) = T.

got(ok(Value)) = Value.
got(halted(_)) = _ :-
    unexpected($pred, "a read was refused: the session has halted").

:- func view_text(fact_view) = string.

view_text(V) = V ^ fact_view_schema ++ string.string(V ^ fact_view_slots).

:- func session_text(outcome, session, list(string)) = string.

session_text(Outcome, S, Served) =
    string.format("%s; facts %s; served %s",
        [s(string.string(Outcome)), s(facts_text(S)),
        s(string.join_list(" | ", Served))]).

    % A check that cannot run in this release, and why.
    %
:- pred skip(string::in, string::in, tally::in, tally::out, io::di, io::uo)
    is det.

skip(Name, Why, !T, !IO) :-
    io.format("SKIP %s (%s)\n", [s(Name), s(Why)], !IO),
    !T ^ tl_skipped := !.T ^ tl_skipped + 1.

%---------------------------------------------------------------------------%
